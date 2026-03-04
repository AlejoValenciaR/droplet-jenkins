data "digitalocean_ssh_key" "this" {
  name = var.ssh_key_name
}

resource "digitalocean_droplet" "jenkins" {
  name       = var.droplet_name
  region     = var.region
  size       = var.size
  image      = var.image
  monitoring = true

  ssh_keys = [data.digitalocean_ssh_key.this.id]
  tags     = ["jenkins", "terraform"]

  user_data = templatefile("${path.module}/user_data.sh.tpl", {})
}

resource "digitalocean_firewall" "jenkins" {
  name        = "${var.droplet_name}-fw"
  droplet_ids = [digitalocean_droplet.jenkins.id]

  inbound_rule {
    protocol   = "tcp"
    port_range = "22"
    source_addresses = [
      "181.234.140.245/32",
      "162.243.190.66/32",
      "162.243.188.66/32"
    ]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "8080"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

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