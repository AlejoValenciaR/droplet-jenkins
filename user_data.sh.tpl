#!/bin/bash
set -euxo pipefail

DOMAIN_NAME="${domain_name}"
JENKINS_FQDN="${jenkins_fqdn}"
MOUNT_PATH="${volume_mount_path}"
VOLUME_NAME="${volume_name}"
DOCKER_DATA_ROOT="$MOUNT_PATH/docker"
JENKINS_IMAGE_DIR="$MOUNT_PATH/jenkins-image"
JENKINS_TMP_DIR="$MOUNT_PATH/jenkins-tmp"
BOOTSTRAP_TMP_DIR="$MOUNT_PATH/bootstrap-tmp"
SWAP_FILE="$MOUNT_PATH/swap/swapfile"

export DEBIAN_FRONTEND=noninteractive

wait_for_docker_socket() {
  for i in $(seq 1 60); do
    if [ -S /var/run/docker.sock ]; then
      return 0
    fi
    sleep 1
  done

  echo "ERROR: Docker socket not found"
  return 1
}

# ----------------------------
# 1) Mount DigitalOcean Volume
# ----------------------------
VOL_DEVICE="/dev/disk/by-id/scsi-0DO_Volume_$VOLUME_NAME"

for i in $(seq 1 600); do
  if [ -b "$VOL_DEVICE" ]; then
    break
  fi
  sleep 1
done

if [ ! -b "$VOL_DEVICE" ]; then
  echo "ERROR: Volume device not found: $VOL_DEVICE"
  exit 1
fi

mkdir -p "$MOUNT_PATH"

# Format only the very first time
if ! blkid "$VOL_DEVICE" >/dev/null 2>&1; then
  mkfs.ext4 -F "$VOL_DEVICE"
fi

grep -q "$VOL_DEVICE" /etc/fstab || echo "$VOL_DEVICE $MOUNT_PATH ext4 defaults,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mount -a

resize2fs "$VOL_DEVICE" || true

mkdir -p "$MOUNT_PATH/jenkins_home"
mkdir -p "$MOUNT_PATH/ssl"
mkdir -p "$DOCKER_DATA_ROOT"
mkdir -p "$JENKINS_IMAGE_DIR"
mkdir -p "$JENKINS_TMP_DIR"
mkdir -p "$BOOTSTRAP_TMP_DIR"
mkdir -p "$(dirname "$SWAP_FILE")"
chmod 700 "$MOUNT_PATH/ssl"
chmod 1777 "$JENKINS_TMP_DIR" "$BOOTSTRAP_TMP_DIR"

# Jenkins container uses uid 1000
chown -R 1000:1000 "$MOUNT_PATH/jenkins_home"

export TMPDIR="$BOOTSTRAP_TMP_DIR"

# ----------------------------
# 2) Base packages
# ----------------------------
apt-get update
apt-get install -y ca-certificates curl gnupg nginx openssl jq rsync

# ----------------------------
# 3) Install Docker
# ----------------------------
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl stop docker.service docker.socket containerd.service || true

if [ -d /var/lib/docker ] && [ -z "$(ls -A "$DOCKER_DATA_ROOT" 2>/dev/null)" ]; then
  rsync -aHAXx --numeric-ids /var/lib/docker/ "$DOCKER_DATA_ROOT/"
fi

# BuildKit cache is disposable. Clearing it during bootstrap avoids stale
# persisted snapshots from breaking the Jenkins image rebuild on a new Droplet.
rm -rf "$DOCKER_DATA_ROOT/buildkit" "$DOCKER_DATA_ROOT/tmp"

mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<EOF
{
  "data-root": "$DOCKER_DATA_ROOT"
}
EOF

systemctl enable docker.service containerd.service
systemctl restart containerd.service
systemctl restart docker.service

wait_for_docker_socket

HOST_DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"

# Keep swap on the attached volume so the boot disk is reserved for the OS.
if swapon --show=NAME | grep -qx '/swapfile'; then
  swapoff /swapfile || true
fi
sed -i '\#^/swapfile none swap sw 0 0$#d' /etc/fstab || true
rm -f /swapfile

if ! swapon --show=NAME | grep -qx "$SWAP_FILE"; then
  if [ ! -f "$SWAP_FILE" ]; then
    fallocate -l 1G "$SWAP_FILE" || dd if=/dev/zero of="$SWAP_FILE" bs=1M count=1024
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
  fi
  swapon "$SWAP_FILE"
fi
grep -q "^$SWAP_FILE " /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab

# ----------------------------
# 4) Reuse TLS files from volume
# ----------------------------
if [ ! -f "$MOUNT_PATH/ssl/tls.key" ]; then
  openssl genrsa -out "$MOUNT_PATH/ssl/tls.key" 2048
  chmod 600 "$MOUNT_PATH/ssl/tls.key"
fi

if [ ! -f "$MOUNT_PATH/ssl/tls.crt" ]; then
  openssl req -x509 -days 30 -sha256 \
    -key "$MOUNT_PATH/ssl/tls.key" \
    -out "$MOUNT_PATH/ssl/tls.crt" \
    -subj "/CN=$DOMAIN_NAME" \
    -addext "subjectAltName=DNS:$DOMAIN_NAME,DNS:$JENKINS_FQDN"
fi

if [ ! -f "$MOUNT_PATH/ssl/tls.csr" ]; then
  openssl req -new \
    -key "$MOUNT_PATH/ssl/tls.key" \
    -out "$MOUNT_PATH/ssl/tls.csr" \
    -subj "/C=CO/ST=Valle del Cauca/L=Cali/O=Jenkins/OU=CI/CD/CN=$DOMAIN_NAME" \
    -addext "subjectAltName=DNS:$DOMAIN_NAME,DNS:$JENKINS_FQDN"
fi

mkdir -p /etc/ssl/jenkins
ln -sf "$MOUNT_PATH/ssl/tls.key" /etc/ssl/jenkins/tls.key
ln -sf "$MOUNT_PATH/ssl/tls.crt" /etc/ssl/jenkins/tls.crt
ln -sf "$MOUNT_PATH/ssl/tls.csr" /etc/ssl/jenkins/tls.csr

# ----------------------------
# 5) Build Jenkins image WITH Terraform + CLIs + Linux agent tools + plugins (OOM fix)
# ----------------------------
cat >"$JENKINS_IMAGE_DIR/Dockerfile" <<'DOCKERFILE'
FROM jenkins/jenkins:lts-jdk21

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash ca-certificates curl gnupg lsb-release sshpass unzip \
    git openssh-client jq sed \
  && rm -rf /var/lib/apt/lists/*

# Terraform, Docker CLI, kubectl, and Azure CLI
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg \
 && chmod a+r /etc/apt/keyrings/hashicorp.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/hashicorp.list \
 && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list \
 && curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
 && chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /" > /etc/apt/sources.list.d/kubernetes.list \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
 && chmod a+r /etc/apt/keyrings/microsoft.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ bookworm main" > /etc/apt/sources.list.d/azure-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends terraform docker-ce-cli kubectl azure-cli \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2
RUN arch="$(uname -m)" \
 && case "$arch" in x86_64|aarch64) ;; *) echo "Unsupported arch: $arch"; exit 1 ;; esac \
 && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$${arch}.zip" -o /tmp/awscliv2.zip \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscliv2.zip

# IMPORTANT: increase heap for jenkins-plugin-cli so it doesn't crash on small droplets
ENV JAVA_TOOL_OPTIONS="-Xmx768m -XX:+UseSerialGC"

RUN jenkins-plugin-cli --plugins \
  "workflow-aggregator" \
  "git" \
  "github" \
  "credentials-binding"

USER jenkins
DOCKERFILE

if ! docker build --pull --no-cache --progress=plain -t jenkins-terraform:latest "$JENKINS_IMAGE_DIR"; then
  echo "Initial Jenkins image build failed. Resetting persisted BuildKit cache and retrying once."
  systemctl stop docker.service docker.socket containerd.service || true
  rm -rf "$DOCKER_DATA_ROOT/buildkit" "$DOCKER_DATA_ROOT/tmp"
  systemctl start containerd.service
  systemctl start docker.service
  wait_for_docker_socket
  HOST_DOCKER_GID="$(stat -c '%g' /var/run/docker.sock)"
  docker build --pull --no-cache --progress=plain -t jenkins-terraform:latest "$JENKINS_IMAGE_DIR"
fi

# ----------------------------
# 6) Run Jenkins with persistent home (limit JVM for runtime)
# ----------------------------
docker rm -f jenkins || true
docker run -d \
  --name jenkins \
  --restart unless-stopped \
  --group-add "$HOST_DOCKER_GID" \
  -p 127.0.0.1:8080:8080 \
  -p 127.0.0.1:50000:50000 \
  -e JAVA_OPTS="-Xms256m -Xmx512m -XX:+UseSerialGC -Djava.io.tmpdir=/tmp" \
  -e TMPDIR=/tmp \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$MOUNT_PATH/jenkins_home:/var/jenkins_home" \
  -v "$JENKINS_TMP_DIR:/tmp" \
  jenkins-terraform:latest

# ----------------------------
# 7) Nginx reverse proxy
# ----------------------------
cat >/etc/nginx/sites-available/jenkins <<'NGINX'
map $http_upgrade $connection_upgrade {
  default upgrade;
  '' close;
}

server {
  listen 80;
  server_name JENKINS_FQDN DOMAIN_NAME;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl http2;
  server_name JENKINS_FQDN DOMAIN_NAME;

  ssl_certificate     /etc/ssl/jenkins/tls.crt;
  ssl_certificate_key /etc/ssl/jenkins/tls.key;

  client_max_body_size 20m;

  location / {
    proxy_pass http://127.0.0.1:8080;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;

    proxy_read_timeout 300;
    proxy_send_timeout 300;
    proxy_buffering off;
  }
}
NGINX

sed -i "s/JENKINS_FQDN/$JENKINS_FQDN/g" /etc/nginx/sites-available/jenkins
sed -i "s/DOMAIN_NAME/$DOMAIN_NAME/g" /etc/nginx/sites-available/jenkins

rm -f /etc/nginx/sites-enabled/default || true
ln -sf /etc/nginx/sites-available/jenkins /etc/nginx/sites-enabled/jenkins

nginx -t
systemctl reload nginx

docker ps || true
docker logs --tail=80 jenkins || true
