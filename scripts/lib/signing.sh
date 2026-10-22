# Code signing for Vitrine builds; sourced by scripts/build-*.sh. See docs/signing.md.
#
# Default: ad-hoc signatures with only the unrestricted entitlements, which needs no Apple account.
# To sign with your own Apple Developer team, set before building:
#   VITRINE_SIGN_IDENTITY        "Apple Development: …", "Developer ID Application: …" or the name of a
#                                self-signed code-signing certificate (hardened runtime is turned on)
#   VITRINE_PROVISIONING_PROFILE a .provisionprofile for VITRINE_BUNDLE_ID that grants the
#                                restricted entitlements below (embedded in Vitrine.app)
#   VITRINE_ENTITLEMENTS         comma-separated restricted entitlements for Vitrine.app:
#                                bridged (com.apple.vm.networking), usb (accessory-access.usb)
#   VITRINE_BUNDLE_ID            Vitrine.app's bundle identifier (must match the profile's App ID)
#   VITRINE_AGENT_SIGN_IDENTITY  identity for the macOS guest agent and its camera extension
#                                (defaults to VITRINE_SIGN_IDENTITY)
#   VITRINE_AGENT_PROVISIONING_PROFILE
#                                profile for io.github.cioufong.vitrine.agent (or your
#                                VITRINE_AGENT_BUNDLE_ID) granting com.apple.developer.system-extension.install,
#                                which the agent needs to add the Vitrine Camera in macOS guests
#   VITRINE_AGENT_EXTENSION_PROFILE
#                                profile for the camera extension (<agent bundle ID>.camera), if your team needs one
#   VITRINE_AGENT_TEAM_ID        your Team ID, when no agent profile names it
#   VITRINE_AGENT_BUNDLE_ID      the agent's bundle identifier
#   VITRINE_ADHOC_STABLE_REQUIREMENT
#                                1: ad-hoc bundles get a designated requirement of just their bundle
#                                identifier, so privacy grants survive rebuilds on a development Mac
#                                (any ad-hoc code with that identifier then inherits them)
#
# Machine-specific settings (an identity, VITRINE_ADHOC_STABLE_REQUIREMENT=1, …) can go in
# signing.local.sh at the repository root, a shell file of VAR=value lines that is sourced here and
# ignored by git. VITRINE_SIGNING_LOCAL names another file instead (scripts/tests use that).

_vitrine_local="${VITRINE_SIGNING_LOCAL-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/signing.local.sh}"
# shellcheck source=/dev/null
if [ -n "$_vitrine_local" ] && [ -f "$_vitrine_local" ]; then source "$_vitrine_local"; fi
unset _vitrine_local

SIGN_IDENTITY="${VITRINE_SIGN_IDENTITY:--}"
BUNDLE_ID="${VITRINE_BUNDLE_ID:-io.github.cioufong.vitrine.app}"
PLISTBUDDY=/usr/libexec/PlistBuddy

vitrine_adhoc() { [ "${1:-$SIGN_IDENTITY}" = "-" ]; }

# vitrine_team_id [profile]: the Team ID of a provisioning profile (default VITRINE_PROVISIONING_PROFILE), or empty.
vitrine_team_id() {
  local profile=${1-${VITRINE_PROVISIONING_PROFILE:-}}
  [ -n "$profile" ] || return 0
  security cms -D -i "$profile" | plutil -extract TeamIdentifier.0 raw -o - -
}

# vitrine_entitlements <base.entitlements> <out.plist> [restricted]
# Copies the base entitlements, adds what the hardened runtime needs for camera and microphone
# when signing with a real identity, and with "restricted" the items of VITRINE_ENTITLEMENTS.
vitrine_entitlements() {
  local base=$1 out=$2 restricted=${3:-}
  cp "$base" "$out"
  if ! vitrine_adhoc; then
    $PLISTBUDDY -c "Add :com.apple.security.device.camera bool true" "$out"
    $PLISTBUDDY -c "Add :com.apple.security.device.audio-input bool true" "$out"
  fi
  [ "$restricted" = restricted ] || return 0
  local item list
  IFS=, read -ra list <<< "${VITRINE_ENTITLEMENTS:-}"
  for item in ${list[@]+"${list[@]}"}; do # bash 3.2: an empty array is "unbound" under set -u
    case "$item" in
      bridged) $PLISTBUDDY -c "Add :com.apple.vm.networking bool true" "$out" ;;
      usb) $PLISTBUDDY -c "Add :com.apple.developer.accessory-access.usb bool true" "$out" ;;
      "") ;;
      *) echo "error: unknown VITRINE_ENTITLEMENTS item '$item' (known: bridged, usb)" >&2; return 1 ;;
    esac
  done
  if [ -n "${VITRINE_ENTITLEMENTS:-}" ]; then
    local team
    team="$(vitrine_team_id)"
    if [ -n "$team" ]; then
      $PLISTBUDDY -c "Add :com.apple.application-identifier string $team.$BUNDLE_ID" "$out"
      $PLISTBUDDY -c "Add :com.apple.developer.team-identifier string $team" "$out"
    else
      echo "warning: restricted entitlements without VITRINE_PROVISIONING_PROFILE: macOS kills Vitrine at launch" >&2
      echo "         unless the Mac runs with AMFI checks relaxed (testing only, see docs/signing.md)" >&2
    fi
  fi
}

# vitrine_sign <path> [entitlements-file] [identity] [extra codesign args…]
vitrine_sign() {
  local path=$1 ent=${2:-} identity=${3:-$SIGN_IDENTITY}
  shift $(( $# < 3 ? $# : 3 ))
  local args=(--force --sign "$identity")
  if ! vitrine_adhoc "$identity"; then
    args+=(--options runtime)
    case "$identity" in "Developer ID Application"*) args+=(--timestamp) ;; esac
  elif [ "${VITRINE_ADHOC_STABLE_REQUIREMENT:-}" = 1 ] && [ -f "$path/Contents/Info.plist" ]; then
    # Opt-in for development Macs: name only the bundle identifier as the designated requirement,
    # so camera, microphone and other privacy grants survive rebuilds. The default requirement pins
    # the exact code; an identifier alone is matched by any ad-hoc code that claims it.
    local id
    id="$($PLISTBUDDY -c "Print :CFBundleIdentifier" "$path/Contents/Info.plist")"
    args+=(-r="designated => identifier \"$id\"")
  fi
  [ -n "$ent" ] && args+=(--entitlements "$ent")
  codesign "${args[@]}" "$@" "$path"
}
