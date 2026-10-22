# Vitrine guest agent (Linux and Windows)

`vitrine-agent` runs inside a Linux (aarch64) guest with an X11 desktop
(Debian, Fedora, Ubuntu… with XFCE, MATE, GNOME on Xorg, KDE on X11, etc.) and
speaks Vitrine's host ⇄ guest protocol. With it the macOS host can:

- show every guest window as its own macOS window (**Coherence**),
- inject mouse and keyboard input,
- sync the clipboard (UTF-8 text and PNG images, both directions).

The same code base also builds a Windows 10/11 agent (arm64 and amd64), see
[Windows guests](#windows-guests).

It is a single static Go binary with no cgo and no runtime dependencies beyond
a running X server. Dependencies: [`jezek/xgb`](https://github.com/jezek/xgb)
(BSD-3-Clause) and `golang.org/x/sys` (BSD-3-Clause).

## How it works

```
 macOS host (Vitrine.app)                       Linux guest
 ───────────────────────     vsock :0x5153     ─────────────────────────────
 AgentChannel  ◀──────────── or virtio-serial ──▶ vitrine-agent ──▶ X server
                                                   ├ capture  (XDamage + MIT-SHM)
                                                   ├ windows  (EWMH + QueryTree)
                                                   ├ input    (XTEST)
                                                   └ clipboard (CLIPBOARD selection)
```

**Wire protocol** — identical to `Sources/VitrineAgentProtocol/Protocol.swift`:
`u32 LE length` (type byte + payload) · `u8 type` · payload, at most 64 MiB.
Control messages are JSON (Swift `Codable` key names, `Data` as base64);
frames, input and ping/pong are packed little-endian binary. On connect the
agent sends `hello` then `displayInfo`, answers `ping` with `pong`, and mirrors
important events as `log` messages. The `protocol` package's golden tests are
byte-for-byte outputs of the Swift encoder.

**Capture** — the agent streams dirty rectangles of the *whole screen* (root
window); the host crops individual windows itself. Dirty regions come from
XDamage (`ReportLevelNonEmpty`, then `Subtract` + `XFixesFetchRegion`); pixels
are read with MIT-SHM `ShmGetImage` (falling back to core `GetImage`). 32-bpp
BGRX is converted to opaque BGRA. Regions are coalesced, split into ≤ 8 MiB
bands and capped at the host's `maxFPS`. If more than 48 MiB is queued for the
host, damage keeps accumulating and is sent once the queue drains. The first
frame after enabling Coherence, and after any screen size change (RandR), is
the full screen, preceded by a fresh `displayInfo`. Without XDamage the agent
falls back to diffing 64×64 tiles of a full grab five times a second.

**Windows** — polled every ~33 ms and sent only when changed. Managed clients
come from `_NET_CLIENT_LIST`; ordering comes from the root's real stacking
order (`QueryTree`), so mapped override-redirect popups (menus, tooltips,
dropdowns) are interleaved correctly, front-to-back. Each window reports its
X client id, `_NET_WM_PID`, `WM_CLASS` class (as `appName`), `_NET_WM_NAME`/
`WM_NAME`, and the geometry of its *WM frame* so titlebars are mirrored. For
client-side-decorated windows without a WM frame, `_GTK_FRAME_EXTENTS` shadows
are trimmed. Kinds: override-redirect and MENU/POPUP_MENU/DROPDOWN_MENU/
TOOLTIP/NOTIFICATION/COMBO/DND → `menu`; DIALOG/UTILITY/TOOLBAR/SPLASH →
`panel`; DESKTOP/DOCK and hidden (minimized) windows are excluded. Popups that
carry no pid/class inherit them from the focused window.

**Window actions** use EWMH: `_NET_ACTIVE_WINDOW` (focus, also restores a
minimized window), `_NET_CLOSE_WINDOW`, `WM_CHANGE_STATE` → Iconic (minimize),
`_NET_WM_STATE` maximized toggle (zoom), `_NET_MOVERESIZE_WINDOW` with
NorthWest gravity (move/resize, frame-inclusive; maximized windows are
unmaximized first). Plain `ConfigureWindow` is the fallback.

**Input** — XTEST fake events. Pointer coordinates are guest points × scale.
Scroll maps to buttons 4/5/6/7 (positive `scrollDY` = up, positive `scrollDX`
= left, as in AppKit); precise (trackpad) deltas emit one click per 10 px.
Keys arrive as macOS virtual key codes (`kVK_*`) and go through a full table
to evdev codes (X keycode = evdev + 8): letters, digits, punctuation, F1–F20,
arrows, editing keys, keypad, JIS keys and modifiers (⌘ → Super_L, ⌥ → Alt_L,
⌃ → Control_L, ⇧ → Shift_L; `--command-key=ctrl` makes ⌘ act as Control so Mac
shortcuts work). Held modifiers are reconciled with each event's flag mask and
released when the host disconnects. When the host sends key code 0 with text
other than "a" (or "A" with Shift/Caps Lock) — emoji picker, text expanders,
automation — and no ⌘/⌃, the text is typed by keysym. Characters the current
layout lacks are bound to one of up to 8 spare keycodes, reused
least-recently-used first and never restored. After each rebinding the agent
waits for the server and gives clients 30 ms to pick up the new keymap. All
key injection is serialized. Every key event waits for a round trip to the
server and is spaced at least 4 ms after the previous one, because GTK
dropped characters when key-code-path and keysym-path keys arrived in a fast
burst.

**Display size** — virtio-gpu reports a host-requested size as a new
preferred mode (hotplug + EDID), but Xorg desktops such as Xfce don't apply
it themselves. The agent watches RandR (screen/CRTC/output change events,
debounced 300 ms, plus a 2 s poll). When a connected output's preferred mode
(the first one listed) changes, or the output is unlit, the agent applies it
in-process: it grows the screen, then sets the CRTC to that mode at 0,0 with
normal rotation, then shrinks the screen to fit. If that fails it runs
`xrandr --output NAME --auto`. At agent start it also applies the preferred
mode if the current size differs. After that, a mode the user picks in the
desktop's display settings is left alone until the host asks for a new size.
The capture loop then sends a fresh `displayInfo` and a full frame. Disable
all of this with `--no-auto-resize`.

**Clipboard** — the agent owns a hidden window on its own X connection, takes
`CLIPBOARD` ownership for host content (offering `UTF8_STRING`,
`text/plain;charset=utf-8`, `STRING`, `TEXT`, `image/png`, `TARGETS`,
`TIMESTAMP`) and watches ownership changes with XFixes (or by polling). Large
transfers use the ICCCM `INCR` protocol in both directions. A content
fingerprint of the last applied/sent clipboard suppresses echo loops.

## Transports

Selection order: `--unix PATH` > `--tcp ADDR` > `--serial PATH` > automatic
(Windows: automatic = virtio-serial `\\.\Global\org.vitrine.agent.0` only; it
waits for the port rather than falling back to TCP, which guest programs could
reach through QEMU user networking — use `--tcp` explicitly if you must).

| Mode | When | Behaviour |
|---|---|---|
| vsock | Apple Virtualization.framework (`VZVirtioSocketDevice`) | listens on `AF_VSOCK` port `0x5153`, `VMADDR_CID_ANY`; the host connects. A new connection replaces the old one. |
| virtio-serial | QEMU backend (port `org.vitrine.agent.0`) | opens `/dev/virtio-ports/org.vitrine.agent.0` as an already-connected stream. The port has no connect signal, so the agent sends `hello` + `displayInfo` on every open, re-sends them whenever the host says `hello`, and on EOF/EIO (host detached) reopens with a 250 ms – 2 s backoff. |
| virtio-serial (Windows) | QEMU backend with the Red Hat VirtIO Serial driver (vioser) | opens `\\.\Global\org.vitrine.agent.0` overlapped (concurrent read/write) with share mode 0, so no other process can open it meanwhile; same announce/reopen behaviour as on Linux (a read error or empty read counts as detached). No token: only QEMU drives the other end. The TCP listener is not opened. |
| TCP | Windows guests on QEMU (user-net `hostfwd`) without the port, explicitly | `--tcp 0.0.0.0:20819` (never automatic). Only peers from 10.0.2.2 are accepted and the host must present the SMBIOS token — but guest programs can reach the host's forwarded port as 10.0.2.2 and read SMBIOS, so this is weaker than virtio-serial. |
| Unix socket | tests / development | `--unix /tmp/vitrine.sock` |

Automatic mode uses the virtio-serial port if
`/dev/virtio-ports/org.vitrine.agent.0` exists, and vsock otherwise. (Checking
the port first is deliberate: `AF_VSOCK` binds succeed even in guests without
a vsock device, which would leave the agent unreachable under QEMU.)

## Build

Requires Go 1.21+.

```sh
cd guest/linux-agent
go test ./...                       # unit tests; run on macOS too (X11 code is build-tagged)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o bin/vitrine-agent ./cmd/vitrine-agent
```

## Install (in the guest)

Copy `bin/vitrine-agent` and the `packaging/` directory into the guest, then
run as the desktop user:

```sh
./packaging/install.sh bin/vitrine-agent
```

This installs:

- `/usr/local/bin/vitrine-agent`
- `/etc/systemd/user/vitrine-agent.service` — a systemd **user** service
  (`After=graphical-session.target`, `Restart=on-failure`), enabled for all
  users with `systemctl --global enable`
- `/etc/xdg/autostart/vitrine-agent.desktop` — imports `DISPLAY`/`XAUTHORITY`
  into the user manager and starts the service at login (needed on desktops
  that never reach `graphical-session.target`, e.g. XFCE)
- `/etc/udev/rules.d/70-vitrine-agent.rules` — lets the logged-in user open the
  QEMU virtio-serial port (it is root-only by default)

Manual control:

```sh
systemctl --user status vitrine-agent
journalctl --user -u vitrine-agent -f
```

Flags: `--unix PATH`, `--tcp ADDR`, `--serial PATH`, `--port N` (vsock),
`--display :0`, `--scale N` (0 = auto), `--command-key super|ctrl`,
`--no-auto-resize` (don't follow the host's display size), `--log FILE`,
`--verbose`, `--version`.

## Requirements and limitations

- An **X11 session** (`DISPLAY` set). **Wayland is not supported** yet; on
  GNOME/KDE pick the "on Xorg"/"X11" session at the login screen.
- XTEST (input), XFixes (clipboard notifications, region fetch), DAMAGE and
  MIT-SHM (efficient capture) — all standard in Xorg. Without DAMAGE/MIT-SHM
  capture still works, just less efficiently.
- 24/32-bit TrueColor root visual (the default everywhere).
- RandR 1.2+ for following the host display size (the `xrandr` binary is only
  needed for the fallback path).
- HiDPI: if `Xft.dpi` ≥ 192 the agent reports scale 2 and points = pixels / 2;
  override with `--scale`.
- With a compositing window manager everything still works because the whole
  root is captured, but disabling compositing reduces damage traffic.
- The kernel needs the virtio vsock transport (`vmw_vsock_virtio_transport`,
  autoloaded by stock distro kernels when the device is present).

## Windows guests

Windows 10/11 guests run on Vitrine's QEMU backend. The agent uses the
virtio-serial port **`\\.\Global\org.vitrine.agent.0`** (vioser driver) when
it exists. Otherwise (older VMs, no vioser) it listens on **TCP
`0.0.0.0:20819`** (0x5153), which the host reaches through QEMU user-net
`hostfwd=tcp:127.0.0.1:<port>-:20819`. The log says which one was chosen. Same
protocol, one host connection at a time. It must run in the interactive user session (a logon scheduled task),
not as a service: capture, input and the clipboard are per session.

```sh
CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build -ldflags=-H=windowsgui -o bin/vitrine-agent-windows-arm64.exe ./cmd/vitrine-agent
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags=-H=windowsgui -o bin/vitrine-agent-windows-amd64.exe ./cmd/vitrine-agent
```

`-H=windowsgui` avoids a console window; logs go to
`%LOCALAPPDATA%\Vitrine\vitrine-agent.log` (`--log -` for stderr). Install
from an elevated PowerShell in the guest:

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\install.ps1 -Exe .\vitrine-agent-windows-arm64.exe
```

This copies the exe to `C:\Program Files\Vitrine\vitrine-agent.exe`, adds an
inbound firewall rule for TCP 20819, registers the logon task "Vitrine Agent"
(BUILTIN\Users, restarts on failure) and starts it. `-Elevated` runs it with
the administrator's full token so it can also drive elevated windows (UIPI
blocks injected input into higher-integrity windows otherwise).

How the backend works (`win/`, pure Go via `golang.org/x/sys/windows`, no cgo):

- **DPI** — `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` so every
  coordinate is physical pixels; `scale = GetDpiForSystem() / 96`,
  points = pixels / scale, origin = top-left of the virtual screen.
- **Windows** — `EnumWindows` (z-order, front-to-back), keeping visible,
  non-minimized, non-cloaked (`DWMWA_CLOAKED`), non-empty, on-screen top-level
  windows; the taskbar, desktop (`Shell_TrayWnd`, `Shell_SecondaryTrayWnd`,
  `Progman`, `WorkerW`), menu shadows (`SysShadow`), click-through overlays
  and the agent itself are dropped. Frame = `DWMWA_EXTENDED_FRAME_BOUNDS`.
  `#32768` menus, tooltips, WinUI popups and `WS_EX_TOOLWINDOW` → `menu`;
  owned windows → `panel`; topmost → layer 3. `appName` = image base name
  without `.exe` (`QueryFullProcessImageNameW`).
- **Capture** — GDI `BitBlt(SRCCOPY|CAPTUREBLT)` of the whole virtual screen
  into a top-down 32-bit DIB section, 64×64 tile diff against the previous
  grab, opaque BGRA, same banding / back-pressure / full-frame-first rules as
  Linux, at most `min(maxFPS, 30)` grabs per second. The secure desktop (UAC,
  lock screen) cannot be captured; the stream resumes afterwards.
- **Input** — `SendInput`: absolute `MOVE|ABSOLUTE|VIRTUALDESK` normalized to
  0..65535, buttons, `WHEEL`/`HWHEEL` (120 per line; trackpad: 1 notch per
  10 pt). Keys use PC set-1 scancodes (`KEYEVENTF_SCANCODE`, plus
  `KEYEVENTF_EXTENDEDKEY` for E0 keys), ported from `XTScancodes.swift`.
  ⌘ → Ctrl by default (`--command-key=win` for the Windows key), ⌥ → Alt.
  Synthesized text is sent as `KEYEVENTF_UNICODE` per UTF-16 unit.
- **Window actions** — focus (`SetForegroundWindow`, falling back to
  `AttachThreadInput`), close (`WM_CLOSE`), minimize / zoom (`ShowWindowAsync`),
  move / resize (`SetWindowPos`, keeping the invisible resize borders).
- **Clipboard** — a message-only window with `AddClipboardFormatListener`
  on its own thread. `CF_UNICODETEXT` ⇄ text; the registered `PNG` format ⇄
  PNG (reading falls back to `CF_DIBV5`/`CF_DIB` → PNG; writing adds
  `CF_DIBV5` for apps that don't read PNG). Echo suppression as on Linux.
- **Hello.os** — `Windows <product> <display version> (build N.UBR)` from
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` (Windows 11 still
  says "Windows 10" in `ProductName`; builds ≥ 22000 are reported as 11).

## Layout

| Path | Contents |
|---|---|
| `cmd/vitrine-agent` | flags, transport selection, accept / serial loops |
| `protocol` | message types, codec, stream deframer (mirrors the Swift package) |
| `agent` | connection handling, dispatch, Coherence / window-list loops (platform independent) |
| `transport` | vsock and virtio-serial (Linux), TCP and Unix-socket listeners |
| `x11` | X11 backend: capture, windows, actions, input, clipboard, RandR |
| `win` | Windows backend: GDI capture, EnumWindows/DWM, SendInput, clipboard |
| `screen` | dirty-region bookkeeping, banding, pixel conversion |
| `keymap` | `kVK_*` → evdev/X11 table, modifier flags, Unicode → keysym |
| `packaging` | systemd user unit, autostart entry, udev rule, installer; `windows/install.ps1` |
