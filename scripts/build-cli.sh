#!/bin/bash
# Builds vitrinectl and signs it with the virtualization entitlement (ad-hoc unless
# VITRINE_SIGN_IDENTITY is set; see scripts/lib/signing.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/signing.sh
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product vitrinectl
BIN="$(swift build -c "$CONFIG" --show-bin-path)/vitrinectl"
ENT="$(mktemp)"
trap 'rm -f "$ENT"' EXIT
vitrine_entitlements Resources/Vitrine.entitlements "$ENT"
vitrine_sign "$BIN" "$ENT"
echo "$BIN"
