#!/bin/bash
set -euxo pipefail

DOMAIN_NAME="${domain_name}"
JENKINS_FQDN="${jenkins_fqdn}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y ca-certificates curl gnupg nginx openssl

# ---- Docker install (official repo) ----
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# Small swap (optional but helpful on tiny droplets)
fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# ---- Jenkins (only on localhost) ----
docker volume create jenkins-data || true

docker rm -f jenkins || true
docker run -d \
  --name jenkins \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -v jenkins-data:/var/jenkins_home \
  jenkins/jenkins:lts-jdk21

# ---- TLS key + CSR (for Name.com) ----
mkdir -p /etc/ssl/jenkins
chmod 700 /etc/ssl/jenkins

# Generate private key once
if [ ! -f /etc/ssl/jenkins/tls.key ]; then
  openssl genrsa -out /etc/ssl/jenkins/tls.key 2048
  chmod 600 /etc/ssl/jenkins/tls.key
fi

# CSR with SAN (www + apex)
openssl req -new \
  -key /etc/ssl/jenkins/tls.key \
  -out /etc/ssl/jenkins/tls.csr \
  -subj "/C=CO/ST=Valle del Cauca/L=Cali/O=Jenkins/OU=CI/CD/CN=$JENKINS_FQDN" \
  -addext "subjectAltName=DNS:$JENKINS_FQDN,DNS:$DOMAIN_NAME"

# Temporary self-signed cert so Nginx can start on 443 now (replace later with Name.com cert)
openssl req -x509 -days 30 -sha256 \
  -key /etc/ssl/jenkins/tls.key \
  -out /etc/ssl/jenkins/tls.crt \
  -subj "/CN=$JENKINS_FQDN" \
  -addext "subjectAltName=DNS:$JENKINS_FQDN,DNS:$DOMAIN_NAME"

# ---- Nginx reverse proxy for Jenkins ----
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

  location / {
    proxy_pass http://127.0.0.1:8080;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
  }
}
NGINX

# Replace placeholders
sed -i "s/JENKINS_FQDN/$JENKINS_FQDN/g" /etc/nginx/sites-available/jenkins
sed -i "s/DOMAIN_NAME/$DOMAIN_NAME/g" /etc/nginx/sites-available/jenkins

rm -f /etc/nginx/sites-enabled/default || true
ln -sf /etc/nginx/sites-available/jenkins /etc/nginx/sites-enabled/jenkins

nginx -t
systemctl reload nginx