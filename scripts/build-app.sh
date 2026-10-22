#!/bin/bash
# Builds dist/Vitrine.app (SwiftUI app + embedded guest agent + vitrinectl + bridge helper), ad-hoc signed with the
# virtualization entitlement, or with your own identity and entitlements (scripts/lib/signing.sh, docs/signing.md).
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/signing.sh
CONFIG="${1:-release}"
./scripts/build-agent.sh "$CONFIG" >/dev/null
swift build -c "$CONFIG" --product VitrineApp
swift build -c "$CONFIG" --product vitrinectl
swift build -c "$CONFIG" --product VitrineAppProxy
swift build -c "$CONFIG" --product vitrine-bridged
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=dist/Vitrine.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/VitrineApp" "$APP/Contents/MacOS/Vitrine"
cp "$BIN/vitrinectl" "$APP/Contents/MacOS/vitrinectl"
cp "$BIN/VitrineAppProxy" "$APP/Contents/MacOS/VitrineAppProxy" # template for guest-app Dock icons/launchers
# Bridged networking: the helper is copied to a root-owned place by bridge-helper.sh when installed.
cp "$BIN/vitrine-bridged" "$APP/Contents/MacOS/vitrine-bridged"
cp Resources/bridge-helper.sh "$APP/Contents/Resources/"
cp -R dist/VitrineAgent.app "$APP/Contents/Resources/"
if ./scripts/build-linux-agent.sh >/dev/null 2>&1; then cp -R dist/linux-agent "$APP/Contents/Resources/"; else echo "warning: Linux agent build failed (Go missing?), not bundled" >&2; fi
if ./scripts/build-windows-agent.sh >/dev/null 2>&1; then cp -R dist/windows-agent "$APP/Contents/Resources/"; else echo "warning: Windows agent build failed (Go missing?), not bundled" >&2; fi
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
cp LICENSE THIRD_PARTY_NOTICES "$APP/Contents/Resources/" # licence texts for the bundled agents
# Translations: SwiftPM compiles Localizable.xcstrings into <lang>.lproj inside the target's resource
# bundle, but SwiftUI and String(localized:) look in the main bundle, so the .lproj folders go there.
# Resources/<lang>.lproj adds InfoPlist.strings (permission prompts).
for l in "$BIN"/Vitrine_VitrineApp.bundle/Contents/Resources/*.lproj "$BIN"/Vitrine_VitrineApp.bundle/*.lproj Resources/*.lproj; do
  [ -d "$l" ] || continue
  mkdir -p "$APP/Contents/Resources/$(basename "$l")"
  cp -R "$l"/ "$APP/Contents/Resources/$(basename "$l")/"
done
LOCALIZATIONS=""
for l in "$APP"/Contents/Resources/*.lproj; do
  [ -d "$l" ] && LOCALIZATIONS+="<string>$(basename "$l" .lproj)</string>"
done
VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1.0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>${LOCALIZATIONS:-<string>en</string>}</array>
  <key>CFBundleName</key><string>Vitrine</string>
  <key>CFBundleDisplayName</key><string>Vitrine</string>
  <key>CFBundleExecutable</key><string>Vitrine</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Vitrine connects to your virtual machines on their private network to install tools and transfer files.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>io.github.cioufong.vitrine.launch</string>
    <key>CFBundleURLSchemes</key><array><string>vitrine</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key><string>Lets virtual machines use your microphone when you enable it.</string>
  <key>NSCameraUsageDescription</key><string>Lets a virtual machine use your camera while you share it from the VM window.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Lets a virtual machine use your Mac's Bluetooth while you share it from the VM window.</string>
</dict>
</plist>
PLIST
ENT="$(mktemp -d)"
trap 'rm -rf "$ENT"' EXIT
# Helper tools can't carry a provisioning profile, so restricted entitlements go on the app only.
vitrine_entitlements Resources/Vitrine.entitlements "$ENT/tools.plist"
vitrine_entitlements Resources/Vitrine.entitlements "$ENT/app.plist" restricted
if [ -n "${VITRINE_PROVISIONING_PROFILE:-}" ]; then cp "$VITRINE_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"; fi
vitrine_sign "$APP/Contents/MacOS/vitrinectl" "$ENT/tools.plist"
vitrine_sign "$APP/Contents/MacOS/VitrineAppProxy"
vitrine_sign "$APP/Contents/MacOS/vitrine-bridged" "$ENT/tools.plist"
vitrine_sign "$APP" "$ENT/app.plist"
echo "$PWD/$APP"
