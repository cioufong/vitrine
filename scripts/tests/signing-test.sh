#!/bin/bash
# Checks scripts/lib/signing.sh: which entitlements each signing setup produces, that signing a
# throwaway binary ad-hoc works, and which designated requirement ad-hoc bundles get. Needs no
# Apple account.
set -u
cd "$(dirname "$0")/../.."
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
has() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1; } # plutil reads dots as a key path
dr() { codesign -d -r- "$1" 2>&1; } # the designated requirement
# This checkout's signing.local.sh (or an exported opt-in) would change what is checked here.
export VITRINE_SIGNING_LOCAL="$T/no-local-settings.sh"
unset VITRINE_ADHOC_STABLE_REQUIREMENT

(unset VITRINE_SIGN_IDENTITY VITRINE_ENTITLEMENTS; source scripts/lib/signing.sh
 vitrine_entitlements Resources/Vitrine.entitlements "$T/adhoc.plist" restricted)
check "ad-hoc keeps the base entitlements only" \
  'has "$T/adhoc.plist" com.apple.security.virtualization && ! has "$T/adhoc.plist" com.apple.security.device.camera'

(VITRINE_SIGN_IDENTITY="Apple Development: Test" VITRINE_ENTITLEMENTS=bridged,usb
 source scripts/lib/signing.sh
 vitrine_entitlements Resources/Vitrine.entitlements "$T/full.plist" restricted 2>"$T/warn"
 vitrine_entitlements Resources/Vitrine.entitlements "$T/tools.plist")
check "a real identity adds camera and microphone for the hardened runtime" \
  'has "$T/full.plist" com.apple.security.device.camera && has "$T/full.plist" com.apple.security.device.audio-input'
check "bridged and usb map to their entitlements" \
  'has "$T/full.plist" com.apple.vm.networking && has "$T/full.plist" com.apple.developer.accessory-access.usb'
check "helper tools never get restricted entitlements" '! has "$T/tools.plist" com.apple.vm.networking'
check "restricted entitlements without a profile warn" 'grep -q "AMFI" "$T/warn"'

(VITRINE_ENTITLEMENTS=bogus; source scripts/lib/signing.sh
 vitrine_entitlements Resources/Vitrine.entitlements "$T/bad.plist" restricted 2>/dev/null)
rc=$?
check "an unknown entitlement name is an error" '[ $rc -ne 0 ]'

cp /usr/bin/true "$T/tool"
(unset VITRINE_SIGN_IDENTITY; source scripts/lib/signing.sh; vitrine_sign "$T/tool" "$T/adhoc.plist")
check "ad-hoc signing with entitlements" \
  'codesign -d --entitlements - "$T/tool" 2>/dev/null | grep -q com.apple.security.virtualization'

# Designated requirements of ad-hoc bundles: by default the exact code (cdhash); with the opt-in,
# only the bundle identifier. The opt-in also works from a local settings file.
bundle() {
  mkdir -p "$T/$1/Contents/MacOS"
  cp /usr/bin/true "$T/$1/Contents/MacOS/x"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.dr" -c "Add :CFBundleExecutable string x" \
    "$T/$1/Contents/Info.plist" >/dev/null
}
bundle Default.app; bundle Stable.app; bundle Local.app
(source scripts/lib/signing.sh; vitrine_sign "$T/Default.app")
check "ad-hoc bundles keep the hash-bound designated requirement" 'dr "$T/Default.app" | grep -q cdhash'
(VITRINE_ADHOC_STABLE_REQUIREMENT=1; source scripts/lib/signing.sh; vitrine_sign "$T/Stable.app")
check "VITRINE_ADHOC_STABLE_REQUIREMENT=1 names only the bundle identifier" \
  'dr "$T/Stable.app" | grep -q "designated => identifier \"com.example.dr\"$" && ! dr "$T/Stable.app" | grep -q cdhash'
echo 'VITRINE_ADHOC_STABLE_REQUIREMENT=1' > "$T/local.sh"
(VITRINE_SIGNING_LOCAL="$T/local.sh"; source scripts/lib/signing.sh; vitrine_sign "$T/Local.app")
check "signing.local.sh settings apply" 'dr "$T/Local.app" | grep -q "identifier \"com.example.dr\"$"'

# The guest agent with its camera extension (debug build, into $T).
ext() { echo "$1/VitrineAgent.app/Contents/Library/SystemExtensions/io.github.cioufong.vitrine.agent.camera.systemextension"; }
agent_ent() { codesign -d --entitlements - --xml "$1/VitrineAgent.app" 2>/dev/null > "$1/agent-ent.plist"; }
ext_ent() { codesign -d --entitlements - --xml "$(ext "$1")" 2>/dev/null > "$1/ext-ent.plist"; }
(unset VITRINE_SIGN_IDENTITY VITRINE_AGENT_SIGN_IDENTITY VITRINE_AGENT_TEAM_ID VITRINE_AGENT_PROVISIONING_PROFILE
 VITRINE_AGENT_OUT="$T/a1" ./scripts/build-agent.sh debug >/dev/null 2>&1)
agent_ent "$T/a1"; ext_ent "$T/a1"
check "ad-hoc agent: verifies, extension inside, no restricted entitlement" \
  'codesign --verify --strict --deep "$T/a1/VitrineAgent.app" 2>/dev/null && [ -d "$(ext "$T/a1")" ] &&
   ! has "$T/a1/agent-ent.plist" com.apple.developer.system-extension.install'
check "ad-hoc camera extension: SYSX, sandboxed, Mach service under its app group" \
  '[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "$(ext "$T/a1")/Contents/Info.plist")" = SYSX ] &&
   has "$T/a1/ext-ent.plist" com.apple.security.app-sandbox &&
   [ "$(/usr/libexec/PlistBuddy -c "Print :CMIOExtension:CMIOExtensionMachServiceName" "$(ext "$T/a1")/Contents/Info.plist")" = io.github.cioufong.vitrine.agent.camera ]'
check "ad-hoc agent and extension: hash-bound designated requirements" \
  'dr "$T/a1/VitrineAgent.app" | grep -q cdhash && dr "$(ext "$T/a1")" | grep -q cdhash'
(unset VITRINE_SIGN_IDENTITY VITRINE_AGENT_SIGN_IDENTITY VITRINE_AGENT_PROVISIONING_PROFILE
 VITRINE_ADHOC_STABLE_REQUIREMENT=1 VITRINE_AGENT_TEAM_ID=ABCDE12345 VITRINE_AGENT_OUT="$T/a2" ./scripts/build-agent.sh debug >/dev/null 2>&1)
check "VITRINE_ADHOC_STABLE_REQUIREMENT=1: agent and extension named by bundle identifier" \
  'dr "$T/a2/VitrineAgent.app" | grep -q "identifier \"io.github.cioufong.vitrine.agent\"$" &&
   dr "$(ext "$T/a2")" | grep -q "identifier \"io.github.cioufong.vitrine.agent.camera\"$"'
agent_ent "$T/a2"; ext_ent "$T/a2"
check "with a Team ID: install entitlement, team-prefixed app group and Mach service" \
  'has "$T/a2/agent-ent.plist" com.apple.developer.system-extension.install &&
   [ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups:0" "$T/a2/ext-ent.plist")" = ABCDE12345.io.github.cioufong.vitrine.agent ] &&
   [ "$(/usr/libexec/PlistBuddy -c "Print :CMIOExtension:CMIOExtensionMachServiceName" "$(ext "$T/a2")/Contents/Info.plist")" = ABCDE12345.io.github.cioufong.vitrine.agent.camera ]'

exit $fail
