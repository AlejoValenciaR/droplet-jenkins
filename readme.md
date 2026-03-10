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

Runtime persistence:

- Jenkins state lives on the attached volume under `/mnt/persist/jenkins_home`, so jobs, credentials, plugins, secrets, and SSH material survive Droplet replacement.
- Docker now stores its full `data-root` on the attached volume under `/mnt/persist/docker`, so images, containers, and named volumes created by Jenkins jobs also survive Droplet replacement.
- Jenkins container `/tmp`, the Jenkins image build context, and the swap file are also placed on the attached volume so the 10 GB boot disk is left for Ubuntu itself.
- The volume is protected with Terraform `prevent_destroy`, and its name is now configured independently from the Droplet name so VM replacement does not imply data-volume replacement.
- If you are migrating an already-running Droplet that still uses `/var/lib/docker` on the boot disk, run [`scripts/migrate_docker_to_volume.sh`](scripts/migrate_docker_to_volume.sh) on that Droplet before applying a Terraform change that recreates it. That one-time step copies the existing Docker state onto the attached volume first.
