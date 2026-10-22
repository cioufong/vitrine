#!/usr/bin/env python3
"""Key-to-pixel latency and delivered frame rate of a running guest's display, as the Mac sees it.

The guest shows scripts/bench/display-probe.html full screen in a browser. This script watches the
probe square at the top left through Vitrine's own display path and times it with one clock (the
Mac's), so guest and host clocks never need to agree:

  latency  press a key (the VM's virtual keyboard), time until the probe flips black/white
  fps      count how often the probe's grey level changes per second while the page animates it

Virtualization.framework guests: keys and samples go over the VM's control socket (`keys`,
`sample`), so Vitrine.app or `vitrinectl run` must own the VM. QEMU guests: one VNC connection to
QEMU's display socket sends the key and receives the screen updates.

  display-probe.py <vm> latency [--samples 40]
  display-probe.py <vm> fps [--seconds 10]
  [--rect X,Y,W,H]  guest pixels to watch (default 40,40,160,160, inside the probe at 1x and 2x)
"""
import argparse, json, os, random, socket, statistics, struct, subprocess, sys, threading, time

def library_root():
    home = os.environ.get("VITRINE_HOME")
    return home if home else os.path.expanduser("~/Library/Application Support/Vitrine/VMs")

def socket_directory(bundle_path):
    # VMBundle.socketDirectory: FNV-1a 64 of the bundle path, base 36, in the user's temp directory.
    h = 0xcbf29ce484222325
    for b in bundle_path.encode():
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    digits, s = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    while True:
        h, r = divmod(h, 36)
        s = digits[r] + s
        if h == 0:
            break
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    return os.path.join(tmp, "vitrine-" + s)

class ControlSocket:
    """Virtualization.framework guest: one JSON request per connection to control.sock."""
    def __init__(self, directory):
        self.path = os.path.join(directory, "control.sock")
        if not os.path.exists(self.path):
            sys.exit(f"no control socket at {self.path}: is the VM running in Vitrine?")

    def request(self, req):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.path)
        s.sendall(json.dumps(req).encode() + b"\n")
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        s.close()
        resp = json.loads(buf)
        if not resp.get("ok"):
            raise RuntimeError(resp.get("error"))
        return resp

    def press(self, key="a"):
        self.request({"op": "keys", "chords": [[key]]})

    def mean(self, rect):
        x, y, w, h = rect
        return sum(self.request({"op": "sample", "x": x, "y": y, "width": w, "height": h})["color"][:3]) / 3

class VNC:
    """QEMU guest: RFB 3.8 over QEMU's display socket (shared, so the app's own viewer stays connected)."""
    def __init__(self, directory, rect):
        path = os.path.join(directory, "vnc.sock")
        if not os.path.exists(path):
            sys.exit(f"no VNC socket at {path}: is the QEMU guest running?")
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.rect = rect
        version = self.read(12)
        self.s.sendall(b"RFB 003.008\n")
        types = self.read(self.read(1)[0])
        if 1 not in types:
            sys.exit(f"VNC server wants authentication ({list(types)})")
        self.s.sendall(b"\x01")
        if struct.unpack(">I", self.read(4))[0] != 0:
            sys.exit("VNC security handshake failed")
        self.s.sendall(b"\x01")  # ClientInit: shared
        self.width, self.height = struct.unpack(">HH", self.read(4))
        self.read(16)
        self.read(struct.unpack(">I", self.read(4))[0])
        # 32 bpp, depth 24, little endian, true colour, BGRX.
        self.s.sendall(struct.pack(">BxxxBBBBHHHBBBxxx", 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
        self.s.sendall(struct.pack(">BxHi", 2, 1, 0))  # SetEncodings: raw
        self.last = None

    def read(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise EOFError("VNC connection closed")
            buf += chunk
        return buf

    def request(self, incremental):
        x, y, w, h = self.rect
        self.s.sendall(struct.pack(">BBHHHH", 3, 1 if incremental else 0, x, y, w, h))

    def next_update(self, timeout):
        """Mean grey level of the watched rect from the next framebuffer update, or None on timeout."""
        self.s.settimeout(timeout)
        try:
            while True:
                kind = self.read(1)[0]
                if kind == 0:
                    self.read(1)
                    total, count = 0, 0
                    for _ in range(struct.unpack(">H", self.read(2))[0]):
                        rx, ry, rw, rh, enc = struct.unpack(">HHHHi", self.read(12))
                        if enc != 0:
                            sys.exit(f"unexpected VNC encoding {enc}")
                        data = self.read(rw * rh * 4)
                        total += sum(data[0::4]) + sum(data[1::4]) + sum(data[2::4])
                        count += rw * rh * 3
                    self.s.settimeout(None)
                    return total / count if count else None
                elif kind == 2:
                    continue
                elif kind == 3:
                    self.read(3)
                    self.read(struct.unpack(">I", self.read(4))[0])
                elif kind == 1:
                    self.read(3)
                    self.read(struct.unpack(">H", self.read(2))[0] * 6)
                else:
                    sys.exit(f"unexpected VNC message {kind}")
        except socket.timeout:
            self.s.settimeout(None)
            return None

    def press(self, key="a"):
        sym = ord(key)
        self.s.sendall(struct.pack(">BBxxI", 4, 1, sym) + struct.pack(">BBxxI", 4, 0, sym))

    def mean(self, rect=None):
        self.request(False)
        return self.next_update(5)

def percentile(values, p):
    v = sorted(values)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]

def summary(name, values):
    if not values:
        return f"{name}: no samples"
    return (f"{name}: n={len(values)} median {statistics.median(values):.1f} ms, p95 {percentile(values, 95):.1f} ms, "
            f"min {min(values):.1f}, max {max(values):.1f}")

def latency_vz(ctl, rect, samples):
    results, missed, sample_times = [], 0, []
    for i in range(samples):
        time.sleep(random.uniform(0.25, 0.6))
        before = ctl.mean(rect)
        t0 = time.perf_counter()
        threading.Thread(target=ctl.press, daemon=True).start()
        while True:
            s0 = time.perf_counter()
            now = ctl.mean(rect)
            t = time.perf_counter()
            sample_times.append((t - s0) * 1000)
            if abs(now - before) > 100:
                results.append((t - t0) * 1000)
                break
            if t - t0 > 2:
                missed += 1
                break
    return results, missed, sample_times

def latency_vnc(vnc, samples):
    results, missed = [], 0
    vnc.mean()
    for i in range(samples):
        time.sleep(random.uniform(0.25, 0.6))
        before = vnc.mean()
        vnc.request(True)
        t0 = time.perf_counter()
        vnc.press()
        while True:
            m = vnc.next_update(2 - (time.perf_counter() - t0))
            t = time.perf_counter()
            if m is not None and abs(m - before) > 100:
                results.append((t - t0) * 1000)
                break
            if m is None or t - t0 > 2:
                missed += 1
                break
            vnc.request(True)
    return results, missed

def fps_vz(ctl, rect, seconds):
    changes, polls, last, t_end = 0, 0, None, time.perf_counter() + seconds
    while time.perf_counter() < t_end:
        m = round(ctl.mean(rect))
        polls += 1
        if last is not None and abs(m - last) > 10:
            changes += 1
        last = m
    return changes / seconds, polls / seconds

def fps_vnc(vnc, seconds):
    changes, updates, last = 0, 0, vnc.mean()
    t_end = time.perf_counter() + seconds
    vnc.request(True)
    while time.perf_counter() < t_end:
        m = vnc.next_update(max(0.01, t_end - time.perf_counter()))
        if m is None:
            break
        updates += 1
        if abs(m - last) > 10:
            changes += 1
        last = m
        vnc.request(True)
    return changes / seconds, updates / seconds

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("vm")
    ap.add_argument("mode", choices=["latency", "fps"])
    ap.add_argument("--samples", type=int, default=40)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--rect", default="40,40,160,160")
    a = ap.parse_args()
    rect = tuple(int(v) for v in a.rect.split(","))
    bundle = os.path.join(library_root(), a.vm + ".vitrinevm")
    config = json.load(open(os.path.join(bundle, "config.json")))
    directory = socket_directory(bundle)
    qemu = config.get("backend") == "qemu"
    print(f"{a.vm}: {'QEMU (VNC)' if qemu else 'Virtualization.framework (control socket)'}, watching {rect}")
    if a.mode == "latency":
        if qemu:
            results, missed = latency_vnc(VNC(directory, rect), a.samples)
            print(summary("key → pixel", results), f"missed {missed}")
        else:
            results, missed, polls = latency_vz(ControlSocket(directory), rect, a.samples)
            print(summary("key → pixel", results), f"missed {missed}")
            print(summary("one sample (resolution)", polls))
    else:
        if qemu:
            fps, rate = fps_vnc(VNC(directory, rect), a.seconds)
            print(f"probe changes seen: {fps:.1f}/s (VNC updates received: {rate:.1f}/s)")
        else:
            fps, rate = fps_vz(ControlSocket(directory), rect, a.seconds)
            print(f"probe changes seen: {fps:.1f}/s (samples taken: {rate:.1f}/s)")

if __name__ == "__main__":
    main()
