#!/bin/bash
# Cross-compiles the Linux guest agent (static; arm64 and amd64) and assembles dist/linux-agent/:
# vitrine-agent-<arch> + install.sh + systemd/XDG/udev files. Requires Go ≥ 1.21.
set -euo pipefail
cd "$(dirname "$0")/.."
GO="${GO:-go}"
OUT=dist/linux-agent
rm -rf "$OUT"
mkdir -p "$OUT"
for arch in arm64 amd64; do
  (cd guest/linux-agent && CGO_ENABLED=0 GOOS=linux GOARCH=$arch "$GO" build -trimpath -ldflags "-s -w" \
    -o "../../$OUT/vitrine-agent-$arch" ./cmd/vitrine-agent)
done
find guest/linux-agent/packaging -maxdepth 1 -type f -exec cp {} "$OUT/" \;
chmod +x "$OUT/install.sh" "$OUT"/vitrine-agent-*
echo "$PWD/$OUT"
