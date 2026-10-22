#!/bin/bash
# End-to-end check of QEMU networking options on Alpine (aarch64, HVF): a TCP port forward from
# the Mac reaches a server in the guest, and host-only mode stops the guest reaching the internet
# while the forward keeps working. Driven over the serial console. Requires: brew install qemu and
# a cached Alpine ISO (scripts/smoke-qemu.sh fetches it).
set -euo pipefail
source "$(dirname "$0")/lib/e2e.sh"
ISO=$(e2e_iso 'alpine/alpine-virt-*-aarch64.iso')
[ -n "$ISO" ] || { echo "SKIP: no cached Alpine ISO (run scripts/smoke-qemu.sh once)"; exit 0; }
e2e_setup net
PORT=$((20000 + RANDOM % 20000))
"$BIN" create-linux net --iso "$ISO" --backend qemu --arch aarch64 --cpus 2 --memory 2G --disk 1G >/dev/null
"$BIN" port add net "$PORT:8000" >/dev/null
con() { "$BIN" console net "$@"; }

boot() {
    "$BIN" run net >"$VITRINE_HOME/run.log" 2>&1 &
    for _ in $(seq 1 60); do "$BIN" list | grep -q "net.*running" && break; sleep 1; done
    con --send '\n' --expect 'login:' --timeout 90 >/dev/null || { echo "FAIL: no login prompt"; exit 1; }
    con --send 'root\n' --expect '(Password:|# )' --timeout 15 >/dev/null
    con --send '\n' --expect '# ' --timeout 15 >/dev/null
    # A one-line server on guest port 8000 (busybox nc), answering every connection.
    con --send 'ip link set eth0 up; udhcpc -q -i eth0 >/dev/null 2>&1; (while true; do echo FWD-$((6*7)) | nc -l -p 8000; done) >/dev/null 2>&1 &\n' --timeout 8 >/dev/null || true
}

check_forward() {
    for _ in $(seq 1 10); do
        if [ "$(nc -w 3 127.0.0.1 "$PORT" </dev/null 2>/dev/null | tr -d '\r\n')" = "FWD-42" ]; then return 0; fi
        sleep 2
    done
    return 1
}

guest_ok() { # prints NET-42 when the guest command succeeds, NET-43 when it doesn't
    con --send "$1 >/dev/null 2>&1 && echo NET-\$((40+2)) || echo NET-\$((40+3))\n" \
        --expect 'NET-4[23]' --timeout 25 | grep -o 'NET-4[23]' | tail -1
}
# By address, so the check doesn't depend on DNS (example.com's server, which answers 200 by name).
EXAMPLE_IP=$(dig +short example.com A | grep -E '^[0-9.]+$' | head -1)
internet() { guest_ok "wget -q -T 8 -O /dev/null --header 'Host: example.com' http://${EXAMPLE_IP:-104.20.23.154}/"; }

boot
check_forward && echo "PASS: NAT: Mac 127.0.0.1:$PORT reaches guest port 8000" || { echo "FAIL: port forward (NAT)"; exit 1; }
[ "$(internet)" = "NET-42" ] && echo "PASS: NAT: guest reaches the internet" || { echo "FAIL: no internet under NAT"; exit 1; }
# libslirp needs an IPv4 resolver among the Mac's first three (docs/networking.md), so this only warns.
[ "$(guest_ok 'nslookup example.com 10.0.2.3')" = "NET-42" ] && echo "PASS: NAT: guest DNS (10.0.2.3)" \
    || echo "WARN: NAT: guest DNS 10.0.2.3 failed; is an IPv4 resolver among the Mac's first three? (docs/networking.md)"
"$BIN" stop net >/dev/null; wait || true

"$BIN" set net --network host-only >/dev/null
boot
check_forward && echo "PASS: host-only: port forward still works" || { echo "FAIL: port forward (host-only)"; exit 1; }
[ "$(internet)" = "NET-43" ] && echo "PASS: host-only: guest cannot reach the internet" || { echo "FAIL: host-only guest reached the internet"; exit 1; }
