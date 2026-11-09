#!/bin/bash
# Muse Pi extra: Syncthing — private folder synchronisation between
# this Pi and your other computers. No cloud account.
#
# Installed from apt and enabled as a user service for @USERNAME@ with
# linger on, so it starts at boot. Web GUI on port 8384 (this Pi only
# until you change its settings), sync traffic on port 22000.
set -x
export DEBIAN_FRONTEND=noninteractive
STATE=/usr/local/muse-pi/state
PI_USER="@USERNAME@"

apt-get update
apt-get install -y syncthing || { echo "ERROR: syncthing install failed"; exit 1; }

loginctl enable-linger "$PI_USER" || true
TUID="$(id -u "$PI_USER")"
OK=0
if runuser -u "$PI_USER" -- env XDG_RUNTIME_DIR="/run/user/$TUID" systemctl --user enable syncthing.service; then
  echo "syncthing: user service enabled"
  OK=1
elif runuser -u "$PI_USER" -- env XDG_RUNTIME_DIR="/run/user/$TUID" systemctl --user enable "syncthing@$PI_USER.service"; then
  echo "syncthing: user template service enabled"
  OK=1
elif systemctl enable "syncthing@$PI_USER.service"; then
  echo "syncthing: system template instance enabled (fallback)"
  OK=1
fi
[ "$OK" -eq 1 ] || { echo "ERROR: could not enable the syncthing service in any form"; exit 1; }

mkdir -p "$STATE"
touch "$STATE/extra-syncthing.done"
echo "Syncthing installed and set to start at boot (web GUI: port 8384)."
