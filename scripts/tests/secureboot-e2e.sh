#!/bin/bash
# Secure Boot with Microsoft keys on x86_64 QEMU guests (emulated, so this takes ~15 minutes).
# Control: unsigned Alpine boots with Secure Boot off. Negative: it must NOT boot with Secure Boot
# on (the firmware reports Access Denied). Positive: with Secure Boot on, Debian's Microsoft-signed
# shim loads its Debian-signed GRUB and the installer menu appears.
# Screenshots land in $OUT (default /tmp) for inspection. Requires cached ISOs:
#   ~/Library/Caches/Vitrine/linux/alpine/alpine-virt-*-x86_64.iso (scripts/smoke-qemu.sh with ARCH=x86_64)
#   ~/Library/Caches/Vitrine/linux/debian/debian-*-amd64-netinst.iso (cdimage.debian.org, checked against SHA256SUMS)
set -u
source "$(dirname "$0")/lib/e2e.sh"
OUT="${OUT:-/tmp}"
ALPINE=$(e2e_iso 'alpine/alpine-virt-*-x86_64.iso')
DEBIAN=$(e2e_iso 'debian/debian-*-amd64-netinst.iso')
[ -n "$ALPINE" ] && [ -n "$DEBIAN" ] || { echo "SKIP: cached Alpine x86_64 and Debian amd64 ISOs needed"; exit 0; }
e2e_setup sb-a sb-b sb-c

run_case() { # name iso secureboot seconds
    "$BIN" create-linux "$1" --iso "$2" --backend qemu --arch x86_64 --cpus 4 --memory 2G --disk 1G >/dev/null
    "$BIN" set "$1" --secure-boot "$3" >/dev/null
    "$BIN" run "$1" >"$VITRINE_HOME/$1.log" 2>&1 &
    sleep "$4"
    "$BIN" screenshot "$1" "$OUT/vitrine-secureboot-$1.png" >/dev/null
    "$BIN" stop "$1" --force >/dev/null 2>&1
    wait
    echo "$1 ($(basename "$2"), secure boot $3): screenshot $OUT/vitrine-secureboot-$1.png"
}
run_case sb-a "$ALPINE" off 240
run_case sb-b "$ALPINE" on 240
run_case sb-c "$DEBIAN" on 300
