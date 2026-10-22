#!/bin/bash
# Builds the guest agent as dist/VitrineAgent.app (an app bundle so macOS privacy prompts name it properly),
# with the "Vitrine Camera" CoreMediaIO extension inside it as a system extension.
# Ad-hoc signed by default; see scripts/lib/signing.sh and docs/signing.md to sign with your own team, which
# the camera extension needs in order to be activated in a guest.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/signing.sh
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product vitrine-agent
swift build -c "$CONFIG" --product vitrine-camera-extension
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
AGENT_ID="${VITRINE_AGENT_BUNDLE_ID:-io.github.cioufong.vitrine.agent}"
CAMERA_ID="$AGENT_ID.camera" # CameraSink derives it the same way
AGENT_IDENTITY="${VITRINE_AGENT_SIGN_IDENTITY:-$SIGN_IDENTITY}"
TEAM="${VITRINE_AGENT_TEAM_ID:-$(vitrine_team_id "${VITRINE_AGENT_PROVISIONING_PROFILE:-}")}"
VERSION=$(grep 'static let version' guest/macos-agent/Sources/GuestAgent.swift | sed -E 's/.*"(.*)".*/\1/')

OUT="${VITRINE_AGENT_OUT:-dist}" # another place, for scripts/tests
APP="$OUT/VitrineAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/vitrine-agent" "$APP/Contents/MacOS/vitrine-agent"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${AGENT_ID}</string>
  <key>CFBundleName</key><string>Vitrine Agent</string>
  <key>CFBundleDisplayName</key><string>Vitrine Agent</string>
  <key>CFBundleExecutable</key><string>vitrine-agent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Vitrine mirrors your windows to the host Mac in Coherence mode.</string>
</dict>
</plist>
PLIST

# The camera extension. Its Mach service must sit under an app group, which on macOS starts with
# the Team ID; ad-hoc builds have none, so theirs only works in guests with relaxed checks.
EXT="$APP/Contents/Library/SystemExtensions/$CAMERA_ID.systemextension"
GROUP="${TEAM:+$TEAM.}$AGENT_ID"
mkdir -p "$EXT/Contents/MacOS"
cp "$BIN/vitrine-camera-extension" "$EXT/Contents/MacOS/$CAMERA_ID"
cat > "$EXT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${CAMERA_ID}</string>
  <key>CFBundleName</key><string>Vitrine Camera</string>
  <key>CFBundleDisplayName</key><string>Vitrine Camera</string>
  <key>CFBundleExecutable</key><string>${CAMERA_ID}</string>
  <key>CFBundlePackageType</key><string>SYSX</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CMIOExtension</key>
  <dict><key>CMIOExtensionMachServiceName</key><string>${GROUP}.camera</string></dict>
  <key>NSSystemExtensionUsageDescription</key><string>Shows the host Mac's camera to apps in this virtual machine.</string>
</dict>
</plist>
PLIST

ENT="$(mktemp -d)"
trap 'rm -rf "$ENT"' EXIT
cat > "$ENT/extension.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key><array><string>${GROUP}</string></array>
</dict>
</plist>
PLIST
# Installing system extensions is a restricted entitlement: an ad-hoc agent carrying it would be
# killed at launch, so it only goes on agents signed by a team (or when asked for, for guests
# running with AMFI checks relaxed).
cat > "$ENT/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
if [ -n "$TEAM" ] || [ "${VITRINE_AGENT_SYSTEM_EXTENSION:-}" = 1 ]; then
  $PLISTBUDDY -c "Add :com.apple.developer.system-extension.install bool true" "$ENT/agent.plist"
fi
if [ -n "$TEAM" ]; then
  for pair in "agent.plist:$AGENT_ID" "extension.plist:$CAMERA_ID"; do
    $PLISTBUDDY -c "Add :com.apple.application-identifier string $TEAM.${pair#*:}" "$ENT/${pair%%:*}"
    $PLISTBUDDY -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENT/${pair%%:*}"
  done
elif ! vitrine_adhoc "$AGENT_IDENTITY"; then
  echo "warning: no VITRINE_AGENT_TEAM_ID or VITRINE_AGENT_PROVISIONING_PROFILE: the camera extension can't be activated" >&2
fi
if [ -n "${VITRINE_AGENT_PROVISIONING_PROFILE:-}" ]; then cp "$VITRINE_AGENT_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"; fi
if [ -n "${VITRINE_AGENT_EXTENSION_PROFILE:-}" ]; then cp "$VITRINE_AGENT_EXTENSION_PROFILE" "$EXT/Contents/embedded.provisionprofile"; fi

# Inside out: the extension first, then the app that seals it. Ad-hoc signatures pin the exact code,
# so the guest asks for Screen Recording and Accessibility again after an agent update, unless
# VITRINE_ADHOC_STABLE_REQUIREMENT=1 (signing.sh).
vitrine_sign "$EXT" "$ENT/extension.plist" "$AGENT_IDENTITY"
vitrine_sign "$APP" "$ENT/agent.plist" "$AGENT_IDENTITY"
echo "$(cd "$OUT" && pwd)/VitrineAgent.app"
