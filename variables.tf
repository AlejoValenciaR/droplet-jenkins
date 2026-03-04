variable "do_token" {
  type      = string
  sensitive = true
}

variable "ssh_key_name" {
  type = string
}

variable "admin_ip_cidr" {
  type        = string
  description = "Your public IP in CIDR format, e.g. 181.234.140.245/32"
}

# Optional: keep DO console working by allowlisting the console IPs you observed
variable "extra_ssh_cidrs" {
  type        = list(string)
  default     = []
  description = "Extra CIDRs allowed to SSH (optional). Example: [\"162.243.190.66/32\",\"162.243.188.66/32\"]"
}

# Your real domain (WITHOUT www)
variable "domain_name" {
  type    = string
  default = "jenkinsnauthsoftwareprivate.app"
}

# For Jenkins, I recommend "jenkins" (cleaner) but you can keep "www"
variable "jenkins_subdomain" {
  type    = string
  default = "www"
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