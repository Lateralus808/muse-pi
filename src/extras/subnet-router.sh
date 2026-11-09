#!/bin/bash
# Muse Pi extra: Tailscale subnet router.
#
# Turns on persistent IP forwarding so this Pi can forward Tailscale
# traffic to the rest of your home network. That is ALL this script
# does on the Pi — no route is advertised and nothing is shared until
# you take the two steps below, and the second one is your approval
# in your own Tailscale account.
set -x
STATE=/usr/local/muse-pi/state

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-tailscale-router.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale-router.conf || true

mkdir -p "$STATE"
touch "$STATE/extra-subnet-router.done"

cat <<'MSG'

IP forwarding is ON. Two steps remain, and only you can do them:

  1. Advertise your home network's route from this Pi (replace the
     range with your own if it differs — most home networks are
     192.168.1.0/24 or 192.168.0.0/24):

         sudo tailscale up --advertise-routes=192.168.1.0/24

  2. In the Tailscale admin console (Machines page), open this Pi and
     approve the advertised subnet route.

Until step 2, nothing about your network is visible to your tailnet.
MSG
