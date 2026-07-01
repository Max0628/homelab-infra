terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "= 0.8.3"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

resource "libvirt_pool" "homelab" {
  name = "homelab"
  type = "dir"

  target {
    path = "/var/lib/libvirt/homelab"
  }
}

resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-24.04-base.qcow2"
  pool   = libvirt_pool.homelab.name
  source = var.ubuntu_image_url
  format = "qcow2"
}

resource "libvirt_network" "k8s" {
  name      = "k8s-net"
  mode      = "nat"
  domain    = "k8s.local"
  addresses = ["192.168.100.0/24"]
  autostart = true

  dhcp {
    enabled = false
  }

  dns {
    enabled    = true
    local_only = true
  }
}

resource "libvirt_volume" "node" {
  for_each = var.nodes

  name           = "${each.key}.qcow2"
  pool           = libvirt_pool.homelab.name
  base_volume_id = libvirt_volume.ubuntu_base.id
  size           = each.value.disk_gb * 1024 * 1024 * 1024
  format         = "qcow2"
}

resource "libvirt_cloudinit_disk" "node" {
  for_each = var.nodes

  name      = "${each.key}-init.iso"
  pool      = libvirt_pool.homelab.name
  user_data = templatefile("${path.module}/cloud-init/user-data.tpl", {
    hostname = each.key
    ssh_key  = file(var.ssh_public_key_path)
  })
  network_config = templatefile("${path.module}/cloud-init/network-config.tpl", {
    ip      = each.value.ip
    gateway = var.gateway
  })
}

resource "libvirt_domain" "node" {
  for_each = var.nodes

  name   = each.key
  memory = each.value.ram_mb
  vcpu   = each.value.vcpu

  cloudinit = libvirt_cloudinit_disk.node[each.key].id

  network_interface {
    network_id     = libvirt_network.k8s.id
    hostname       = each.key
    wait_for_lease = false
  }

  disk {
    volume_id = libvirt_volume.node[each.key].id
  }

  console {
    type        = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
  }

  cpu {
    mode = "host-passthrough"
  }

  autostart = true
}
