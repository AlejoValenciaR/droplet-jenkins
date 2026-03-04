output "droplet_ip" {
  value = digitalocean_droplet.jenkins.ipv4_address
}

output "jenkins_url" {
  value = "http://${digitalocean_droplet.jenkins.ipv4_address}:8080"
}