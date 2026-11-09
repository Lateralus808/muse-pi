#!/bin/bash
# Muse Pi extra: Uptime Kuma — a status board that watches your other
# computers and services and shows whether they are up.
#
# Installs Docker (apt), then runs Uptime Kuma as a container with
# restart policy "unless-stopped" on port 3001. Data lives in
# ~@USERNAME@/uptime-kuma. Open http://<this-pi>:3001 and create its
# admin account there — that account is separate from everything else.
set -x
export DEBIAN_FRONTEND=noninteractive
STATE=/usr/local/muse-pi/state
PI_USER="@USERNAME@"
PI_HOME="/home/$PI_USER"

apt-get update
apt-get install -y docker.io || { echo "ERROR: docker install failed"; exit 1; }
systemctl enable --now docker || true
usermod -aG docker "$PI_USER" || true
for i in $(seq 1 15); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon did not start"; exit 1; }

install -d -o "$PI_USER" -g "$PI_USER" "$PI_HOME/uptime-kuma" || true
if docker inspect uptime-kuma >/dev/null 2>&1; then
  docker start uptime-kuma || true
else
  docker pull louislam/uptime-kuma:1 || { echo "ERROR: image pull failed"; exit 1; }
  docker run -d --name uptime-kuma --restart unless-stopped \
    -p 3001:3001 -v "$PI_HOME/uptime-kuma:/app/data" \
    louislam/uptime-kuma:1 || { echo "ERROR: container start failed"; exit 1; }
fi

mkdir -p "$STATE"
touch "$STATE/extra-uptime-kuma.done"
echo "Uptime Kuma is running on port 3001."
