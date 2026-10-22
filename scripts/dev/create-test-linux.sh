#!/bin/bash
# Dev helper: one-click Debian 13 Xfce test VM with a random password for the "vitrine" account.
# Usage: scripts/dev/create-test-linux.sh <name> <password-file> [extra vitrinectl args…]
set -euo pipefail
cd "$(dirname "$0")/../.."
NAME="$1"; PWFILE="$2"; shift 2
if [ ! -s "$PWFILE" ]; then
  openssl rand -base64 18 | tr -d '/+=' | cut -c1-14 > "$PWFILE"
  chmod 600 "$PWFILE"
fi
exec .build/out/Products/Debug/vitrinectl create-linux "$NAME" --distro debian-13 --user vitrine \
  --password "$(cat "$PWFILE")" --full-name "Vitrine Test" "$@"
