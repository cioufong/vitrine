#!/bin/bash
# End-to-end check of virtio-9p shared folders and the serial console on the QEMU backend: boots
# Alpine (aarch64, HVF) from its ISO in a throwaway library, logs in on the serial console, mounts
# the share by its tag, copies a file the Mac wrote into a new file in the share and checks it on
# the Mac. Requires: brew install qemu, and a cached Alpine ISO (scripts/smoke-qemu.sh fetches it).
set -euo pipefail
source "$(dirname "$0")/lib/e2e.sh"
ARCH=aarch64
ISO=$(e2e_iso "alpine/alpine-virt-*-$ARCH.iso")
[ -n "$ISO" ] || { echo "SKIP: no cached Alpine ISO (run scripts/smoke-qemu.sh once)"; exit 0; }
e2e_setup ninep
SHARE=$(mktemp -d)
E2E_CLEANUP="$SHARE"
echo "hello from the mac $RANDOM" > "$SHARE/host.txt"
"$BIN" create-linux ninep --iso "$ISO" --backend qemu --arch "$ARCH" --cpus 2 --memory 2G --disk 1G >/dev/null
"$BIN" share add ninep "$SHARE" --as "Mac Files" >/dev/null
"$BIN" set ninep --gdb 23946 >/dev/null

"$BIN" run ninep >"$VITRINE_HOME/run.log" 2>&1 &
for _ in $(seq 1 60); do "$BIN" list | grep -q "ninep.*running" && break; sleep 1; done
con() { "$BIN" console ninep "$@"; }
con --send '\n' --expect 'login:' --timeout 90 >/dev/null || { echo "FAIL: no login prompt on the serial console"; exit 1; }
con --send 'root\n' --expect '(Password:|# )' --timeout 15 >/dev/null
con --send '\n' --expect '# ' --timeout 15 >/dev/null || { echo "FAIL: could not log in on the serial console"; exit 1; }
echo "PASS: serial console login"
con --send 'mkdir -p /mnt/t && mount -t 9p -o trans=virtio,version=9p2000.L Mac_Files /mnt/t && cp /mnt/t/host.txt /mnt/t/guest.txt && sync && echo NINEP-$((40+2)) || echo NINEP-$((40+3))\n' \
    --expect 'NINEP-4[23]' --timeout 30 > "$VITRINE_HOME/mount.out" || { echo "FAIL: mount/copy in the guest"; con --send '\n' --timeout 2; exit 1; }
grep -q "NINEP-42" "$VITRINE_HOME/mount.out" || { echo "FAIL: mount/copy failed in the guest:"; tail -5 "$VITRINE_HOME/mount.out"; exit 1; }
if cmp -s "$SHARE/host.txt" "$SHARE/guest.txt"; then
    echo "PASS: 9p share mounted by tag, read and written from the guest"
else
    echo "FAIL: guest.txt missing or different on the Mac"; exit 1
fi
# Last: a GDB client connecting halts the guest vCPUs (normal gdbstub behaviour).
nc -z 127.0.0.1 23946 >/dev/null 2>&1 && echo "PASS: GDB stub listening on 127.0.0.1:23946" || { echo "FAIL: no GDB stub"; exit 1; }
