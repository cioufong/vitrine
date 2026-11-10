#!/bin/sh
# Installs or removes vitrine-bridged, the root LaunchDaemon that serves bridged networking to one
# user's VMs (sockets /var/run/vitrine/bridged.<interface>, owned by that user).
#
#   bridge-helper.sh install <path to vitrine-bridged> <uid> <code requirement>   (as root)
#   bridge-helper.sh uninstall                                                     (as root)
#   bridge-helper.sh verify <file> <code requirement>
#   bridge-helper.sh stage <file> <directory> <code requirement>                   (tests: install's
#                                                                                   copy-and-check step)
#
# Vitrine does not run this file: BridgeHelperScript.swift carries the same text, compiled into
# Vitrine (a test keeps the two identical), and passes it to the administrator prompt. The app
# bundle is writable by its user, so nothing root runs may be read from it.
#
# The binary is copied, without following a symlink, into a fresh directory only root can enter,
# and its signature checked there against the requirement the caller built (identifier
# vitrine-bridged, its cdhash, and the caller's Team ID when it has one): the source lives in the
# user-writable app bundle, so it could change between any earlier check and the copy. The copy
# stays root-only until it passes, then becomes the installed binary. The daemon never runs a file
# the user can modify.
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

# stage <file> <directory> <requirement>: sets $staged to a verified copy of <file> in a new
# root-only directory under <directory> ($staged_dir, removed when the script exits).
stage() {
    # Advisory (the source can still change after this); the copy is what gets checked.
    if [ -L "$1" ] || [ ! -f "$1" ]; then
        echo "bridge-helper.sh: $1 is not a regular file; not installing" >&2
        exit 1
    fi
    staged_dir=$(mktemp -d "$2/.vitrine-bridged.XXXXXX")
    trap 'rm -rf "$staged_dir"' EXIT
    chmod 700 "$staged_dir"
    staged=$staged_dir/vitrine-bridged
    # -R copies a symlink as a symlink and a FIFO as a FIFO instead of following or reading them;
    # -X leaves extended attributes behind.
    cp -RX "$1" "$staged"
    if [ -L "$staged" ] || [ ! -f "$staged" ]; then
        echo "bridge-helper.sh: $1 is not a regular file; not installing" >&2
        exit 1
    fi
    chmod -N "$staged" 2>/dev/null || true
    chmod 700 "$staged"
    verify "$staged" "$3"
}

case "${1:-}" in
verify)
    verify "${2:?file}" "${3:?code requirement}"
    ;;
stage)
    stage "${2:?file}" "${3:?directory}" "${4:?code requirement}"
    trap - EXIT
    echo "$staged"
    ;;
install)
    need_root
    src=${2:?path to vitrine-bridged}
    uid=${3:?uid}
    req=${4:?code requirement}
    case "$uid" in '' | *[!0-9]* | 0) echo "bridge-helper.sh: bad uid $uid" >&2; exit 1 ;; esac
    mkdir -p /Library/PrivilegedHelperTools
    chown root:wheel /Library/PrivilegedHelperTools
    chmod 755 /Library/PrivilegedHelperTools
    stage "$src" /Library/PrivilegedHelperTools "$req"
    chown root:wheel "$staged"
    chmod 755 "$staged"
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    mv -f "$staged" "$DEST"
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
    echo "usage: bridge-helper.sh install <vitrine-bridged> <uid> <requirement> | uninstall | verify <file> <requirement> | stage <file> <dir> <requirement>" >&2
    exit 2
    ;;
esac
