#!/bin/sh
# Opens the Muse Pi setup wizard in the default browser.
#
#   open-wizard.sh               — always open (desktop icon)
#   open-wizard.sh --if-pending  — open only while first-time setup is
#                                  unfinished (desktop autostart entry)
URL="http://127.0.0.1:8977/"
FLAG=/usr/local/muse-pi/state/setup-pending

if [ "$1" = "--if-pending" ] && [ ! -f "$FLAG" ]; then
  exit 0
fi

if ! curl -fs --max-time 2 "$URL" >/dev/null 2>&1; then
  # The wizard service is not running — after setup it switches itself
  # off. Bring it back with a graphical sudo prompt so the owner can
  # re-run setup at any time.
  if command -v pkexec >/dev/null 2>&1; then
    pkexec systemctl start muse-pi-wizard.service 2>/dev/null || true
    sleep 1
  fi
fi

xdg-open "$URL" >/dev/null 2>&1 &
exit 0
