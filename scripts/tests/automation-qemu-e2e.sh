#!/bin/bash
# Screenshots, typing and clicks on a QEMU guest (the QMP path of `vitrinectl screenshot|keys|click`
# and the MCP tools): boots the cached Alpine aarch64 ISO, types at its login prompt and clicks
# (QEMU's USB tablet). Screenshots
# land in $OUT (default /tmp). Requires ~/Library/Caches/Vitrine/linux/alpine/alpine-virt-*-aarch64.iso.
set -u
source "$(dirname "$0")/lib/e2e.sh"
OUT="${OUT:-/tmp}"
ISO=$(e2e_iso 'alpine/alpine-virt-*-aarch64.iso')
[ -n "$ISO" ] || { echo "SKIP: cached Alpine aarch64 ISO needed (scripts/smoke-qemu.sh)"; exit 0; }
e2e_setup auto-q
"$BIN" create-linux auto-q --iso "$ISO" --backend qemu --cpus 2 --memory 2G --disk 1G >/dev/null || exit 1
"$BIN" run auto-q >"$VITRINE_HOME/run.log" 2>&1 &
sleep 40
fail=0
# Echoed at the login prompt (no Return): shifted and unshifted characters must come out exactly.
"$BIN" keys auto-q --combo ret >/dev/null && sleep 1
"$BIN" keys auto-q --text 'Hello-VITRINE_42$(*)~"q"' >/dev/null && sleep 2
"$BIN" screenshot auto-q "$OUT/vitrine-automation-qemu.png" || fail=1
"$BIN" click auto-q 10 10 >/dev/null || { echo "FAIL click"; fail=1; }
"$BIN" click auto-q 10 10 --button right --clicks 2 >/dev/null || { echo "FAIL right double click"; fail=1; }
"$BIN" click auto-q 99999 10 >/dev/null 2>&1 && { echo "FAIL out-of-range click accepted"; fail=1; }
"$BIN" keys auto-q --combo ctrl+bogus >/dev/null 2>&1 && { echo "FAIL unknown key accepted"; fail=1; }
echo "screenshot: $OUT/vitrine-automation-qemu.png (the last login prompt should read Hello-VITRINE_42\$(*)~\"q\")"
exit $fail
