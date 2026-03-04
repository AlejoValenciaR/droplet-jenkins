output "reserved_ip" {
  value = digitalocean_reserved_ip.jenkins.ip_address
}

output "jenkins_fqdn" {
  value = local.jenkins_fqdn
}

output "jenkins_http_url" {
  value = "http://${local.jenkins_fqdn}/"
}

output "jenkins_https_url" {
  value = "https://${local.jenkins_fqdn}/"
}