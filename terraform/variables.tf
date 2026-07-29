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
      # 2026-07-29：2→3。host 是 i5-8350U（4 核 8 執行緒），三台 VM 原本
      # 2+2+2=6，host 自己（+ TLP + claude-sentinel/daily_log + KVM/QEMU
      # 排程開銷）留 2 個執行緒。這次只加 worker1 一台到 3（總和 2+3+2=7），
      # 刻意不三台一起加，host 至少留 1 個執行緒，避免被榨乾反過來拖慢所有 VM。
      # TLP 的降頻設定（關 turbo、powersave governor）獨立於這個維度之上，
      # 加 vCPU 不會讓實體頻率超出 TLP 訂的天花板，只是給 guest 排程器多一個
      # 邏輯執行單位可用。
      vcpu    = 3
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
