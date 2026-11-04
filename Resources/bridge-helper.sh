#!/bin/sh
# Installs or removes vitrine-bridged, the root LaunchDaemon that serves bridged networking to one
# user's VMs (sockets /var/run/vitrine/bridged.<interface>, owned by that user).
#
#   bridge-helper.sh install <path to vitrine-bridged> <uid> <code requirement>   (as root)
#   bridge-helper.sh uninstall                                                     (as root)
#   bridge-helper.sh verify <file> <code requirement>
#
# The binary is copied to a root-owned location first and its signature checked there, against the
# requirement the caller built (its cdhash, and the caller's Team ID when it has one): the source
# lives in the user-writable app bundle, so it could change between any earlier check and the copy.
# The daemon never runs a file the user can modify.
set -eu

LABEL=com.vitrine.bridged
DEST=/Library/PrivilegedHelperTools/vitrine-bridged
PLIST=/Library/LaunchDaemons/$LABEL.plist

need_root() { [ "$(id -u)" = 0 ] || { echo "bridge-helper.sh: run as root" >&2; exit 1; }; }

verify() { # file requirement
    /usr/bin/codesign --verify --strict -R="$2" "$1" || {
        echo "bridge-helper.sh: $1 is not the vitrine-bridged this Vitrine was built with; not installing" >&2
        return 1
    }
}

case "${1:-}" in
verify)
    verify "${2:?file}" "${3:?code requirement}"
    ;;
install)
    need_root
    src=${2:?path to vitrine-bridged}
    uid=${3:?uid}
    req=${4:?code requirement}
    case "$uid" in '' | *[!0-9]* | 0) echo "bridge-helper.sh: bad uid $uid" >&2; exit 1 ;; esac
    [ -f "$src" ] || { echo "bridge-helper.sh: $src is missing" >&2; exit 1; }
    mkdir -p /Library/PrivilegedHelperTools
    chown root:wheel /Library/PrivilegedHelperTools
    chmod 755 /Library/PrivilegedHelperTools
    staged=$(mktemp /Library/PrivilegedHelperTools/.vitrine-bridged.XXXXXX)
    trap 'rm -f "$staged"' EXIT
    cp "$src" "$staged"
    chown root:wheel "$staged"
    chmod 755 "$staged"
    verify "$staged" "$req"
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    mv -f "$staged" "$DEST"
    trap - EXIT
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST</string>
        <string>--user</string>
        <string>$uid</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/vitrine-bridged.log</string>
    <key>StandardErrorPath</key><string>/var/log/vitrine-bridged.log</string>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"
    launchctl bootstrap system "$PLIST"
    echo "installed $LABEL for uid $uid"
    ;;
uninstall)
    need_root
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$DEST"
    rm -rf /var/run/vitrine
    echo "removed $LABEL"
    ;;
*)
    echo "usage: bridge-helper.sh install <vitrine-bridged> <uid> <requirement> | uninstall | verify <file> <requirement>" >&2
    exit 2
    ;;
esac
