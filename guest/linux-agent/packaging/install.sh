#!/bin/sh
# Installs vitrine-agent as a systemd user service for every user.
# Run as the desktop user (uses sudo for system paths) or as root.
#
#   ./packaging/install.sh [path/to/vitrine-agent]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-"$here/../bin/vitrine-agent"}
if [ ! -x "$bin" ]; then
	echo "vitrine-agent binary not found at $bin (build it first, see README.md)" >&2
	exit 1
fi

if [ "$(id -u)" -eq 0 ]; then sudo=""; else sudo="sudo"; fi

$sudo install -D -m 0755 "$bin" /usr/local/bin/vitrine-agent
$sudo install -D -m 0644 "$here/vitrine-agent.service" /etc/systemd/user/vitrine-agent.service
# Desktops that never reach graphical-session.target (XFCE, MATE, LXQt...)
# start the service from XDG autostart instead.
$sudo install -D -m 0644 "$here/vitrine-agent-autostart.desktop" /etc/xdg/autostart/vitrine-agent.desktop
# QEMU backend: allow the session user to open the virtio-serial port.
$sudo install -D -m 0644 "$here/70-vitrine-agent.rules" /etc/udev/rules.d/70-vitrine-agent.rules
if command -v udevadm >/dev/null 2>&1; then
	$sudo udevadm control --reload-rules || true
	$sudo udevadm trigger --subsystem-match=virtio-ports || true
fi

# Enable for all users (works from root, unlike `systemctl --user enable`).
$sudo systemctl --global enable vitrine-agent.service

# Start it right away when run from inside a graphical session.
if [ "$(id -u)" -ne 0 ] && [ -n "${DISPLAY:-}" ]; then
	systemctl --user daemon-reload
	systemctl --user import-environment DISPLAY XAUTHORITY 2>/dev/null || systemctl --user import-environment DISPLAY
	systemctl --user restart vitrine-agent.service
	echo "vitrine-agent started; logs: journalctl --user -u vitrine-agent -f"
else
	echo "vitrine-agent installed; it starts at the next graphical login."
fi
