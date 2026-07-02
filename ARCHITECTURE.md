# Homelab 架構文件

## 概覽

以單台 ThinkPad T480 為基礎，透過 KVM 虛擬化模擬多節點 Kubernetes cluster，
完整體驗 DevOps / SRE 技術棧，包含 GitLab CI/CD、GitOps、Observability。

---

## 實體硬體

| 項目 | 規格 |
|------|------|
| 機器 | ThinkPad T480 |
| CPU | Intel i5-8350U（4 核 8 執行緒） |
| RAM | 62GB |
| 儲存 | 466GB NVMe SSD |
| OS | Ubuntu 24.04 LTS |
| 外部存取 | Tailscale（IP: 100.81.225.123） |

---

## 整體架構

```
                    ┌──────────────────────────────────────────────────────┐
                    │                  ThinkPad T480                        │
                    │           i5-8350U / 62GB RAM / 466GB SSD             │
                    │                                                        │
  iPhone            │  ┌──────────────────────────────────────────────────┐ │
  (Tailscale) ────► │  │              KVM Hypervisor (libvirt/QEMU)        │ │
                    │  │                                                    │ │
                    │  │  ┌─────────────┐  ┌─────────────┐  ┌──────────┐  │ │
                    │  │  │k8s-control  │  │k8s-worker1  │  │k8s-worker│  │ │
                    │  │  │.100.10      │  │.100.11      │  │2 .100.12 │  │ │
                    │  │  │2C/4GB/50GB  │  │2C/20GB/120GB│  │2C/20GB/  │  │ │
                    │  │  │             │  │             │  │120GB     │  │ │
                    │  │  │[control     │  │[GitLab CE]  │  │[Prometh] │  │ │
                    │  │  │ plane only] │  │[GitLab      │  │[Grafana] │  │ │
                    │  │  │             │  │ Runner]     │  │[Loki]    │  │ │
                    │  │  │             │  │[ArgoCD]     │  │[AlertMgr]│  │ │
                    │  │  │             │  │[sentinel]   │  │          │  │ │
                    │  │  │             │  │[daily_log]  │  │          │  │ │
                    │  │  └─────────────┘  └─────────────┘  └──────────┘  │ │
                    │  │                                                    │ │
                    │  │         NAT Network: 192.168.100.0/24             │ │
                    │  │         MetalLB Pool: 192.168.100.200–250         │ │
                    │  └──────────────────────────────────────────────────┘ │
                    │                                                        │
                    │  Tailscale Interface (tailscale0): 100.81.225.123     │
                    └──────────────────────────────────────────────────────┘
```

---

## 網路架構

```
外部流量（手機 / 其他裝置）
        │
        ▼
  Tailscale VPN
        │
        ▼
  T480 (100.81.225.123)
        │
        ▼
  MetalLB LoadBalancer (192.168.100.200+)
        │
        ▼
  Nginx Ingress Controller
        │
    ┌───┴──────────────────┐
    ▼                      ▼
gitlab.ts.net         grafana.ts.net
    │                      │
    ▼                      ▼
GitLab CE Pod         Grafana Pod
```

| 網路區段 | 用途 |
|---------|------|
| `192.168.100.0/24` | KVM NAT，VM 之間互通 |
| `192.168.100.1` | Host bridge（virbr1） |
| `192.168.100.10–12` | K8s 節點 IP |
| `192.168.100.200–250` | MetalLB LoadBalancer IP pool |
| `100.81.225.123` | Tailscale，外部裝置存取入口 |

外部 domain 使用 Tailscale MagicDNS，格式：`*.tailXXXX.ts.net`，
TLS 由 Tailscale 自動簽發，無需手動管理憑證。

---

## Kubernetes Cluster

### 節點規格

| 節點 | 角色 | IP | vCPU | RAM | Disk |
|------|------|----|------|-----|------|
| k8s-control | control plane | 192.168.100.10 | 2 | 4GB | 50GB |
| k8s-worker1 | worker | 192.168.100.11 | 2 | 20GB | 120GB |
| k8s-worker2 | worker | 192.168.100.12 | 2 | 20GB | 120GB |

### 核心元件

| 元件 | 用途 |
|------|------|
| kubeadm | Cluster 安裝與管理 |
| Calico | CNI 網路插件 |
| MetalLB | Bare metal LoadBalancer |
| Nginx Ingress | HTTP/HTTPS 路由 |
| Longhorn | 分散式 block storage |
| cert-manager | TLS 憑證管理（內部用） |

---

## Platform Services

### GitLab CE（worker1）
- 自架 Git server，為所有 repo 的主要來源
- 包含 Container Registry，存放 Docker image
- GitLab CI 執行 pipeline
- GitLab Runner 以 Kubernetes executor 運行在 worker 節點

### ArgoCD（worker1）
- GitOps CD 工具
- 監控 `k8s` repo，自動將 cluster 狀態同步至 git 定義的狀態
- 有 Web UI，可從手機查看部署狀態

### Observability Stack（worker2）

```
應用程式 / 系統
      │
   ┌──┴──────────────────┐
   │                     │
Promtail             Prometheus
（收集 log）          （收集 metrics）
   │                     │
   ▼                     ▼
 Loki               AlertManager
（log 儲存）         （告警路由）
   │                     │
   └──────┬──────────────┘
          ▼
       Grafana
   （統一視覺化 UI）
```

| 工具 | 用途 |
|------|------|
| Prometheus | Metrics 收集與儲存 |
| AlertManager | 告警規則與通知（Discord） |
| Grafana | Dashboard 視覺化 |
| Loki | Log 收集與查詢 |
| Promtail | Log 收集 agent（每個節點） |

---

## Application Services

| 服務 | 類型 | 節點 | 說明 |
|------|------|------|------|
| claude-sentinel | CronJob | worker1 | 每 3 分鐘查詢 Claude Pro 用量，每 20 分鐘送 Discord |
| daily_log | CronJob / Deployment | worker1 | 每日紀錄 |

---

## CI/CD 流程

```
開發者 push code
        │
        ▼
  GitLab（self-hosted）
        │
        ├──── mirror ────► GitHub（備份 / 公開）
        │
        ▼
  GitLab CI Pipeline
        │
    ┌───┴────────────────┐
    ▼                    ▼
  build image         run tests
    │
    ▼
  push to GitLab
  Container Registry
    │
    ▼
  update image tag
  in `k8s` repo
        │
        ▼
     ArgoCD
  偵測 k8s repo 變更
        │
        ▼
  自動 sync 到 cluster
        │
        ▼
  新版本上線
```

---

## GitOps 原則

- `k8s` repo 是 cluster 的唯一真相來源（Source of Truth）
- 任何服務的變更都必須透過 git push，不允許直接 `kubectl apply`
- ArgoCD 持續監控，確保 cluster 狀態與 git 一致
- Rollback = `git revert` + push

---

## Repo 結構

```
homelab-infra/    ← 本 repo（私有）
├── terraform/    ← KVM VM 定義（Terraform + libvirt）
├── ansible/      ← OS 設定、kubeadm 安裝（Ansible）
└── ARCHITECTURE.md

k8s/              ← GitOps repo（私有）ArgoCD 監控此 repo
├── apps/
│   ├── claude-sentinel/
│   │   ├── base/
│   │   └── overlays/
│   └── daily-log/
│       ├── base/
│       └── overlays/
└── platform/
    ├── gitlab/
    ├── argocd/
    ├── prometheus/
    ├── grafana/
    ├── loki/
    └── ingress/

claude-sentinel/  ← App code（公開）GitHub + GitLab
daily_log/        ← App code（私有）GitLab only + GitHub mirror
```

### Repo 同步策略

| Repo | 可見性 | GitLab（主） | GitHub（mirror） |
|------|--------|-------------|-----------------|
| homelab-infra | 私有 | ✅ | ✅ |
| k8s | 私有 | ✅ | ✅ |
| claude-sentinel | 公開 | ✅ | ✅ |
| daily_log | 私有 | ✅ | ✅ |

GitLab 為主要來源，所有 CI/CD 在 GitLab 上執行。
GitHub 為 mirror，push 到 GitLab 後自動同步。

---

## 建置順序

```
Phase 1  Terraform 建立 KVM VM        ✅ 完成
Phase 2  Ansible 安裝 kubeadm cluster  ← 目前
Phase 3  安裝 Calico / MetalLB / Nginx Ingress
Phase 4  安裝 Longhorn storage
Phase 5  安裝 GitLab CE + Runner
Phase 6  安裝 ArgoCD，建立 k8s repo
Phase 7  安裝 Prometheus + Grafana + Loki
Phase 8  遷移 claude-sentinel / daily_log 到 k8s
Phase 9  設定 Tailscale HTTPS + domain
Phase 10 設定 GitHub mirror
```
