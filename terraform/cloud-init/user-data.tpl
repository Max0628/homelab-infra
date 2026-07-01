#cloud-config
hostname: ${hostname}
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: ubuntu
    ssh_authorized_keys:
      - ${ssh_key}

package_update: true
packages:
  - qemu-guest-agent
  - curl
  - apt-transport-https
  - ca-certificates

runcmd:
  - systemctl enable --now qemu-guest-agent
