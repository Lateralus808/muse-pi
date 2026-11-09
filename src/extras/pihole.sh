#!/bin/bash
# Muse Pi extra: Pi-hole — network-wide ad and tracker blocking.
#
# Installed unattended from the official Pi-hole installer with
# DHCP_ACTIVE=false: Pi-hole's DHCP server stays OFF, so it cannot
# disturb your network. It only answers DNS for devices you point at
# this Pi (one device's DNS setting, or your router's). It changes
# nothing for anyone else.
#
# The installer generates a web admin password and prints it once in
# the output below — note it down. Admin page: http://<this-pi>/admin
set -x
STATE=/usr/local/muse-pi/state

IFACE="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)"
[ -z "$IFACE" ] && IFACE="eth0"
IP4CIDR="$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | head -n1)"
if [ -z "$IP4CIDR" ]; then
  echo "ERROR: no IPv4 address on $IFACE — connect the Pi to your network (wired is best) and try again."
  exit 1
fi

mkdir -p /etc/pihole
cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=$IFACE
IPV4_ADDRESS=$IP4CIDR
IPV6_ADDRESS=
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=1.0.0.1
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
CACHE_SIZE=10000
BLOCKING_ENABLED=true
DHCP_ACTIVE=false
EOF

curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
rc=$?
if [ $rc -ne 0 ]; then
  echo "ERROR: the Pi-hole installer failed (exit $rc) — see the output above."
  exit $rc
fi

mkdir -p "$STATE"
touch "$STATE/extra-pihole.done"
echo "Pi-hole installed (DHCP off). It now answers DNS on this Pi only;"
echo "point a device's DNS at this Pi to try it."
