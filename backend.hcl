endpoints = {
  s3 = "https://nyc3.digitaloceanspaces.com"
}

bucket = "alejo-tfstate-jenkins"
key    = "jenkins-do/terraform.tfstate"

region = "us-east-1"

skip_credentials_validation = true
skip_requesting_account_id  = true
skip_metadata_api_check     = true
skip_region_validation      = true
skip_s3_checksum            = true

use_lockfile = true