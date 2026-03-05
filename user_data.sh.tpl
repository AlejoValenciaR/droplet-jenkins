#!/bin/bash
set -euxo pipefail

DOMAIN_NAME="${domain_name}"
JENKINS_FQDN="${jenkins_fqdn}"
MOUNT_PATH="${volume_mount_path}"
VOLUME_NAME="${volume_name}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg nginx openssl jq

# ----------------------------
# 1) Mount DigitalOcean Volume
# ----------------------------
VOL_DEVICE="/dev/disk/by-id/scsi-0DO_Volume_$VOLUME_NAME"

for i in $(seq 1 180); do
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

mkdir -p "$MOUNT_PATH/jenkins_home"
mkdir -p "$MOUNT_PATH/ssl"
chmod 700 "$MOUNT_PATH/ssl"

# Jenkins container uses uid 1000
chown -R 1000:1000 "$MOUNT_PATH/jenkins_home"

# ----------------------------
# 2) Install Docker (host)
# ----------------------------
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# small swap for tiny Droplets
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# ----------------------------
# 3) Reuse TLS files from volume (self-signed if missing)
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
# 4) Build Jenkins image WITH Terraform + Git + SSH + plugins
# ----------------------------
mkdir -p /opt/jenkins-image

cat >/opt/jenkins-image/Dockerfile <<'DOCKERFILE'
FROM jenkins/jenkins:lts-jdk21

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release unzip \
    git openssh-client jq \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI inside Jenkins container (optional but useful later)
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
 && chmod a+r /etc/apt/keyrings/docker.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update && apt-get install -y docker-ce-cli \
 && rm -rf /var/lib/apt/lists/*

# Terraform (HashiCorp repo)
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg \
 && chmod a+r /etc/apt/keyrings/hashicorp.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(. /etc/os-release && echo $VERSION_CODENAME) main" > /etc/apt/sources.list.d/hashicorp.list \
 && apt-get update && apt-get install -y terraform \
 && rm -rf /var/lib/apt/lists/*

# Pipeline + Git + GitHub webhook + credentials binding
RUN jenkins-plugin-cli --plugins \
  "workflow-aggregator" \
  "git" \
  "github" \
  "credentials-binding"

USER jenkins
DOCKERFILE

# Build only if the image doesn't exist yet
if ! docker image inspect jenkins-terraform:latest >/dev/null 2>&1; then
  docker build -t jenkins-terraform:latest /opt/jenkins-image
fi

# ----------------------------
# 5) Set Jenkins URL automatically (important for GitHub webhooks)
# ----------------------------
mkdir -p "$MOUNT_PATH/jenkins_home/init.groovy.d"

cat >"$MOUNT_PATH/jenkins_home/init.groovy.d/01-jenkins-url.groovy" <<EOF
import jenkins.model.JenkinsLocationConfiguration
def jlc = JenkinsLocationConfiguration.get()
jlc.setUrl("https://$JENKINS_FQDN/")
jlc.save()
EOF

chown -R 1000:1000 "$MOUNT_PATH/jenkins_home/init.groovy.d"

# ----------------------------
# 6) Run Jenkins with persistent home (and optional docker socket)
# ----------------------------
DOCKER_GID="$(getent group docker | cut -d: -f3 || true)"
if [ -z "$DOCKER_GID" ]; then
  DOCKER_GID="999"
fi

docker rm -f jenkins || true

docker run -d \
  --name jenkins \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -p 127.0.0.1:50000:50000 \
  --group-add "$DOCKER_GID" \
  -v "$MOUNT_PATH/jenkins_home:/var/jenkins_home" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jenkins-terraform:latest

# ----------------------------
# 7) Nginx reverse proxy (webhooks + UI + websockets)
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

# ----------------------------
# 8) Quick sanity logs (optional)
# ----------------------------
docker logs --tail=50 jenkins || true