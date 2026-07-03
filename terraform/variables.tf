variable "ubuntu_image_url" {
  description = "Ubuntu 24.04 cloud image URL"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for VM access"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "gateway" {
  description = "Default gateway for k8s network"
  type        = string
  default     = "192.168.100.1"
}

variable "nodes" {
  description = "k8s node definitions"
  type = map(object({
    vcpu    = number
    ram_mb  = number
    disk_gb = number
    ip      = string
  }))
  default = {
    "k8s-control" = {
      vcpu    = 2
      ram_mb  = 4096
      disk_gb = 50
      ip      = "192.168.100.10"
    }
    "k8s-worker1" = {
      vcpu    = 2
      ram_mb  = 20480
      disk_gb = 200
      ip      = "192.168.100.11"
    }
    "k8s-worker2" = {
      vcpu    = 2
      ram_mb  = 20480
      disk_gb = 200
      ip      = "192.168.100.12"
    }
  }
}
