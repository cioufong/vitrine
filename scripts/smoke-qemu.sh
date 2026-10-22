#!/bin/bash
# QEMU backend smoke test: boots Alpine (aarch64 on HVF, or x86_64 emulated with ARCH=x86_64) from its
# ISO, waits for the login prompt via QMP screendump, then suspends to disk and resumes.
# Requires: brew install qemu
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH="${ARCH:-aarch64}"
CACHE="${VITRINE_CACHE:-$HOME/Library/Caches/Vitrine}/linux/alpine"
mkdir -p "$CACHE"
BASE="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$ARCH"
ISO=$(curl -fsSL "$BASE/latest-releases.yaml" | grep -E "file: alpine-virt-.*\.iso$" | head -1 | awk '{print $2}')
[ -s "$CACHE/$ISO" ] || curl -fsSL -o "$CACHE/$ISO" "$BASE/$ISO"
BIN=$(./scripts/build-cli.sh debug | tail -1)
export VITRINE_HOME=$(mktemp -d)
trap '"$BIN" stop smoke --force >/dev/null 2>&1 || true; rm -rf "$VITRINE_HOME"' EXIT
"$BIN" create-linux smoke --iso "$CACHE/$ISO" --backend qemu --arch "$ARCH" --cpus 2 --memory 2G --disk 1G >/dev/null

shot() { "$BIN" screenshot smoke "$VITRINE_HOME/$1.png" >/dev/null 2>&1; }
wait_running() { for _ in $(seq 1 60); do "$BIN" list | grep -q "smoke.*running" && shot probe && return 0; sleep 1; done; return 1; }

"$BIN" run smoke >"$VITRINE_HOME/run1.log" 2>&1 &
wait_running || { echo "FAIL: QEMU did not start"; cat "$VITRINE_HOME/run1.log"; exit 1; }
T=$([ "$ARCH" = x86_64 ] && echo 240 || echo 60)
sleep "$T" # let Alpine reach its login prompt (x86_64 is emulated, so slower)
shot before
"$BIN" suspend smoke
[ -s "$VITRINE_HOME/smoke.vitrinevm/state.qemusave" ] || { echo "FAIL: no saved state"; exit 1; }
wait || true
"$BIN" run smoke >"$VITRINE_HOME/run2.log" 2>&1 &
wait_running || { echo "FAIL: resume did not start"; cat "$VITRINE_HOME/run2.log"; tail -3 "$VITRINE_HOME/smoke.vitrinevm/qemu.log"; exit 1; }
shot after
[ ! -e "$VITRINE_HOME/smoke.vitrinevm/state.qemusave" ] || { echo "FAIL: state file not consumed"; exit 1; }
cp "$VITRINE_HOME/before.png" "${OUT:-/tmp}/vitrine-qemu-$ARCH-before.png"
cp "$VITRINE_HOME/after.png" "${OUT:-/tmp}/vitrine-qemu-$ARCH-after.png"
echo "PASS: QEMU $ARCH boot + suspend + resume (screenshots in ${OUT:-/tmp})"
