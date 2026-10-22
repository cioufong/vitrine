#!/bin/sh
# Installs or removes vitrine-bridged, the root LaunchDaemon that serves bridged networking to one
# user's VMs (sockets /var/run/vitrine/bridged.<interface>, owned by that user).
#
#   bridge-helper.sh install <path to vitrine-bridged> <uid>     (as root)
#   bridge-helper.sh uninstall                                   (as root)
#
# The binary is copied to a root-owned location: the daemon never runs a file the user can modify.
set -eu

LABEL=com.vitrine.bridged
DEST=/Library/PrivilegedHelperTools/vitrine-bridged
PLIST=/Library/LaunchDaemons/$LABEL.plist

[ "$(id -u)" = 0 ] || { echo "bridge-helper.sh: run as root" >&2; exit 1; }

case "${1:-}" in
install)
    src=${2:?path to vitrine-bridged}
    uid=${3:?uid}
    case "$uid" in '' | *[!0-9]* | 0) echo "bridge-helper.sh: bad uid $uid" >&2; exit 1 ;; esac
    [ -f "$src" ] || { echo "bridge-helper.sh: $src is missing" >&2; exit 1; }
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    mkdir -p /Library/PrivilegedHelperTools
    install -o root -g wheel -m 755 "$src" "$DEST"
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
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$DEST"
    rm -rf /var/run/vitrine
    echo "removed $LABEL"
    ;;
*)
    echo "usage: bridge-helper.sh install <vitrine-bridged> <uid> | uninstall" >&2
    exit 2
    ;;
esac
