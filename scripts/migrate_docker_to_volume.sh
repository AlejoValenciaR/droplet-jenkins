#!/bin/bash
set -euxo pipefail

MOUNT_PATH="${1:-/mnt/persist}"
DOCKER_DATA_ROOT="$MOUNT_PATH/docker"
SWAP_FILE="$MOUNT_PATH/swap/swapfile"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root."
  exit 1
fi

if ! mountpoint -q "$MOUNT_PATH"; then
  echo "Volume mount path is not mounted: $MOUNT_PATH"
  exit 1
fi

apt-get update
apt-get install -y rsync

mkdir -p "$DOCKER_DATA_ROOT"
mkdir -p "$(dirname "$SWAP_FILE")"

systemctl stop jenkins || true
docker stop jenkins || true
systemctl stop docker.service docker.socket containerd.service || true

if [ -d /var/lib/docker ]; then
  rsync -aHAXx --numeric-ids /var/lib/docker/ "$DOCKER_DATA_ROOT/"
fi

mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<EOF
{
  "data-root": "$DOCKER_DATA_ROOT"
}
EOF

if swapon --show=NAME | grep -qx '/swapfile'; then
  swapoff /swapfile || true
  sed -i '\#^/swapfile none swap sw 0 0$#d' /etc/fstab || true
  rm -f /swapfile
fi

if [ ! -f "$SWAP_FILE" ]; then
  fallocate -l 1G "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=1024
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
fi

grep -q "^$SWAP_FILE " /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
swapon "$SWAP_FILE"

systemctl enable docker.service containerd.service
systemctl restart containerd.service
systemctl restart docker.service

if docker ps -a --format '{{.Names}}' | grep -qx 'jenkins'; then
  docker start jenkins || true
fi
