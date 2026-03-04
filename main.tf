locals {
  ssh_source_cidrs = concat([var.admin_ip_cidr], var.extra_ssh_cidrs)
  jenkins_fqdn     = "${var.jenkins_subdomain}.${var.domain_name}"
}

data "digitalocean_ssh_key" "this" {
  name = var.ssh_key_name
}

resource "digitalocean_droplet" "jenkins" {
  name          = var.droplet_name
  region        = var.region
  size          = var.size
  image         = var.image
  monitoring    = true
  droplet_agent = true

  ssh_keys = [data.digitalocean_ssh_key.this.id]
  tags     = ["jenkins", "terraform"]

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    domain_name    = var.domain_name
    jenkins_fqdn   = local.jenkins_fqdn
  })
}

# 1) Reserve a stable IP (free while assigned; $5/mo only if unassigned) :contentReference[oaicite:3]{index=3}
resource "digitalocean_reserved_ip" "jenkins" {
  region = var.region
}

# 2) Attach reserved IP to droplet (survives droplet rebuilds; it reattaches) :contentReference[oaicite:4]{index=4}
resource "digitalocean_reserved_ip_assignment" "jenkins" {
  ip_address = digitalocean_reserved_ip.jenkins.ip_address
  droplet_id = digitalocean_droplet.jenkins.id
}

# 3) DigitalOcean DNS zone (works only after you delegate nameservers at Name.com) :contentReference[oaicite:5]{index=5}
resource "digitalocean_domain" "this" {
  name = var.domain_name
}

# A record for root domain (@) -> Reserved IP :contentReference[oaicite:6]{index=6}
resource "digitalocean_record" "apex" {
  domain = digitalocean_domain.this.id
  type   = "A"
  name   = "@"
  value  = digitalocean_reserved_ip.jenkins.ip_address
  ttl    = 1800
}

# A record for subdomain (www or jenkins) -> Reserved IP :contentReference[oaicite:7]{index=7}
resource "digitalocean_record" "jenkins" {
  domain = digitalocean_domain.this.id
  type   = "A"
  name   = var.jenkins_subdomain
  value  = digitalocean_reserved_ip.jenkins.ip_address
  ttl    = 1800
}

resource "digitalocean_firewall" "jenkins" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.jenkins.id]

  # SSH only from you (+ optional console IPs)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = local.ssh_source_cidrs
  }

  # HTTP/HTTPS for reverse proxy
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Outbound open (common)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}