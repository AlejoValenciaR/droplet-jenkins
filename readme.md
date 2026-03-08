# Jenkins Terraform DigitalOcean

This repository manages DigitalOcean resources with Terraform and deploys a Jenkins controller on DigitalOcean.

The Jenkins controller container is built during droplet provisioning from [user_data.sh.tpl](user_data.sh.tpl). It now includes these job-level CLI dependencies:

- `terraform`
- `aws`
- `az`
- `docker`
- `kubectl`
- `sed`

`docker` is available to Jenkins jobs because the controller container mounts the host Docker socket at `/var/run/docker.sock`.

After changing `user_data.sh.tpl`, reprovision the droplet so cloud-init rebuilds the Jenkins image with the new tools.
