#!/bin/bash
# Runs in a macOS guest (vitrinectl exec): downloads the current Firefox DMG from Mozilla, installs it
# into /Applications and opens a web page in it. Prints each step's result.
set -euo pipefail
URL="${1:-https://www.wikipedia.org/}"
WORK="$(mktemp -d)"
curl -fsSL -o "$WORK/Firefox.dmg" "https://download.mozilla.org/?product=firefox-latest-ssl&os=osx&lang=en-US"
echo "downloaded $(stat -f %z "$WORK/Firefox.dmg") bytes"
MNT="$(hdiutil attach -nobrowse -readonly "$WORK/Firefox.dmg" | awk -F'\t' '/\/Volumes\// {print $NF}')"
rm -rf /Applications/Firefox.app
cp -R "$MNT/Firefox.app" /Applications/
hdiutil detach "$MNT" >/dev/null
rm -rf "$WORK"
echo "installed $(defaults read /Applications/Firefox.app/Contents/Info.plist CFBundleShortVersionString)"
codesign --verify --deep --strict /Applications/Firefox.app && echo "signature ok"
open -a /Applications/Firefox.app "$URL"
echo "opened $URL"
