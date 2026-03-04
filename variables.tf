variable "do_token" {
  type      = string
  sensitive = true
}

variable "ssh_key_name" {
  type = string
}

variable "admin_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR format, for example 203.0.113.10/32"
}

variable "droplet_name" {
  type    = string
  default = "jenkins-do"
}

variable "region" {
  type    = string
  default = "nyc1"
}

variable "size" {
  type    = string
  default = "s-1vcpu-512mb-10gb"
}

variable "image" {
  type    = string
  default = "ubuntu-24-04-x64"
}