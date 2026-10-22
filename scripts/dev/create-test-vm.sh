#!/bin/bash
# Dev helper: creates a macOS test VM with a random password for the "vitrine" account.
# Usage: scripts/dev/create-test-vm.sh <name> <ipsw> <password-file> [extra vitrinectl args…]
set -euo pipefail
cd "$(dirname "$0")/../.."
NAME="$1"; IPSW="$2"; PWFILE="$3"; shift 3
if [ ! -s "$PWFILE" ]; then
  openssl rand -base64 18 | tr -d '/+=' | cut -c1-14 > "$PWFILE"
  chmod 600 "$PWFILE"
fi
exec .build/out/Products/Debug/vitrinectl create "$NAME" --ipsw "$IPSW" --user vitrine --password "$(cat "$PWFILE")" \
  --full-name "Vitrine Test" "$@"
