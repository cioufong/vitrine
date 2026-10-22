#!/bin/bash
# Cross-compiles the Windows guest agent (arm64 and amd64 GUI executables, pure Go) and assembles
# dist/windows-agent/: vitrine-agent-<arch>.exe + install.ps1. Requires Go ≥ 1.21.
# With zig (brew install zig) it also builds the camera media source, vitrine-camera-<arch>.dll
# (guest/windows-camera; libc++ linked statically, so it needs nothing beyond Windows itself);
# without zig the agent is built anyway, without Windows camera support.
set -euo pipefail
cd "$(dirname "$0")/.."
GO="${GO:-go}"
ZIG="${ZIG:-zig}"
OUT=dist/windows-agent
rm -rf "$OUT"
mkdir -p "$OUT"
for arch in arm64 amd64; do
  (cd guest/linux-agent && CGO_ENABLED=0 GOOS=windows GOARCH=$arch "$GO" build -trimpath \
    -ldflags "-s -w -H=windowsgui" -o "../../$OUT/vitrine-agent-$arch.exe" ./cmd/vitrine-agent)
done
cp guest/linux-agent/packaging/windows/install.ps1 "$OUT/"

if command -v "$ZIG" >/dev/null 2>&1; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  src=guest/windows-camera
  for target in aarch64:arm64 x86_64:amd64; do
    triple=${target%%:*} arch=${target##*:}
    mkdir -p "$tmp/$arch"
    # Built as vitrine-camera.dll (the name it's installed under) in a scratch directory, which
    # also catches zig's .lib/.pdb side outputs.
    if "$ZIG" c++ -target "$triple-windows-gnu" -std=c++17 -O2 -shared -s -fno-exceptions -fno-rtti \
        -Wall -Wextra -Wno-unused-parameter -o "$tmp/$arch/vitrine-camera.dll" \
        "$src/module.cpp" "$src/mediasource.cpp" "$src/frames.cpp" "$src/vitrine-camera.def" \
        -lmfplat -ladvapi32; then
      cp "$tmp/$arch/vitrine-camera.dll" "$OUT/vitrine-camera-$arch.dll"
    else
      echo "warning: building the Windows camera media source ($arch) failed; not included" >&2
    fi
  done
else
  echo "warning: zig not found; Windows camera support (vitrine-camera-<arch>.dll) not built" >&2
fi
echo "$PWD/$OUT"
