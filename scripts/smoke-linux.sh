#!/bin/bash
# Boots Alpine aarch64 (EFI-zboot kernel + initramfs) headless on the VZ backend and checks the serial
# console reaches Alpine's init. Exercises kernel unpacking, Linux platform, virtio-gpu, virtiofs, hvc0.
set -euo pipefail
cd "$(dirname "$0")/.."
CACHE="${VITRINE_CACHE:-$HOME/Library/Caches/Vitrine}/linux/alpine"
BASE=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/netboot
mkdir -p "$CACHE"
for f in vmlinuz-virt initramfs-virt; do
  [ -s "$CACHE/$f" ] || curl -fsSL -o "$CACHE/$f" "$BASE/$f"
done
BIN=$(./scripts/build-cli.sh debug | tail -1)
export VITRINE_HOME=$(mktemp -d)
trap 'rm -rf "$VITRINE_HOME"' EXIT
"$BIN" create-linux smoke --kernel "$CACHE/vmlinuz-virt" --initrd "$CACHE/initramfs-virt" \
  --cmdline "console=hvc0" --cpus 2 --memory 2G --disk 1G >/dev/null
"$BIN" run smoke >/dev/null 2>&1 &
LOG="$VITRINE_HOME/smoke.vitrinevm/console.log"
ok=0
for _ in $(seq 1 60); do
  if grep -q "Alpine Init" "$LOG" 2>/dev/null; then ok=1; break; fi
  sleep 1
done
"$BIN" stop smoke --force >/dev/null 2>&1 || true
wait || true
if [ "$ok" = 1 ]; then
  echo "PASS: Alpine reached init ($(grep -c '' "$LOG") console lines; $(grep -o 'virtiofs.*tag: vitrine' "$LOG" | head -1))"
else
  echo "FAIL: Alpine init not seen"; tail -20 "$LOG" || true; exit 1
fi
