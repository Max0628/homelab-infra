# Homelab 架構文件

## 概覽

以單台 ThinkPad T480 為基礎，透過 KVM 虛擬化模擬多節點 Kubernetes cluster，
完整體驗 DevOps / SRE 技術棧，包含 GitLab CI/CD、GitOps、Observability。

本文件同時給人跟未來的 Claude Code session 看，目的是讓任何人（或新開的 session）
不用重新問一輪就能理解目前實際狀態、已經做過的決策、以及為什麼這樣做。

---

## 範圍與決策

這個 repo（`homelab-infra`）只負責：

- T480 host 本身的虛擬化 / 網路設定
- k8s cluster 的建立（kubeadm、CNI、storage、ingress）
- 平台服務（GitLab、ArgoCD、觀測性堆疊）的安裝與設定

以下是已經確定、之後不需要再重新討論的決策：

**claude-sentinel / daily_log 不會搬進這個 k8s cluster**

兩個都是輕量、週期性觸發的工作（見下方「Host-Native Applications」），不需要
HA / failover，目前用 user-level systemd timer + podman 跑在 T480 host 上就很穩定。
搬進 k8s 只會多出維運複雜度（尤其 daily_log 需要對 git repo 做 bind mount 寫入，
跟 k8s CronJob 的 stateless 假設不合），沒有實質好處。這兩個 repo 也刻意不會加進
自架 GitLab、不會接 GitLab CI/CD、不會進 ArgoCD 的 GitOps 迴路、不會接進
Prometheus / Loki 這套監控。維持現狀即可。

**下一個真正會用到整套 k8s + GitOps + 觀測性堆疊的專案：股票 / 總經 Dashboard**

計畫中的一個長期運行網站（即時股票 / 總體經濟資訊 + 分析，手機版面優先），會需要
長期運行的 Deployment（不是 CronJob）、資料庫、Ingress，才真正用得到這裡建好的
HA / 監控能力。這個專案還沒開始規劃技術細節，會另開一個 Claude Code session
（可能也是獨立 repo）處理，細節詳見下方「未來規劃」。

在那之前，`k8s` repo 除了一個 README 之外是空的、ArgoCD 目前沒有實際 workload
可以同步——這是預期狀態，不是漏做。

---

## 實體硬體

| 項目 | 規格 |
|------|------|
| 機器 | ThinkPad T480 |
| CPU | Intel i5-8350U（4 核 8 執行緒） |
| RAM | 62GB |
| 儲存 | 466GB NVMe SSD |
| OS | Ubuntu 24.04 LTS |
| 外部存取 | Tailscale（IP: 100.81.225.123），同時作為 subnet router |

---

## 整體架構

```
                    ┌──────────────────────────────────────────────────────┐
                    │                  ThinkPad T480                        │
                    │           i5-8350U / 62GB RAM / 466GB SSD             │
                    │                                                        │
  iPhone / Mac       │  ┌──────────────────────────────────────────────────┐ │
  (Tailscale) ────► │  │              KVM Hypervisor (libvirt/QEMU)        │ │
                    │  │                                                    │ │
                    │  │  ┌─────────────┐  ┌─────────────┐  ┌──────────┐  │ │
                    │  │  │k8s-control  │  │k8s-worker1  │  │k8s-worker│  │ │
                    │  │  │.100.10      │  │.100.11      │  │2 .100.12 │  │ │
                    │  │  │2C/4GB/50GB  │  │2C/20GB/200GB│  │2C/20GB/  │  │ │
                    │  │  │             │  │             │  │200GB     │  │ │
                    │  │  │[control     │  │[GitLab CE]  │  │[Prometh] │  │ │
                    │  │  │ plane only] │  │[GitLab      │  │[Grafana] │  │ │
                    │  │  │             │  │ Runner]     │  │[Loki]    │  │ │
                    │  │  │             │  │[ArgoCD]     │  │[AlertMgr]│  │ │
                    │  │  └─────────────┘  └─────────────┘  └──────────┘  │ │
                    │  │                                                    │ │
                    │  │         NAT Network: 192.168.100.0/24             │ │
                    │  │         MetalLB Pool: 192.168.100.200–250         │ │
                    │  └──────────────────────────────────────────────────┘ │
                    │                                                        │
                    │  Host-native apps（不在 k8s 裡，systemd --user + podman）│
                    │  [claude-sentinel]          [daily_log]                │
                    │                                                        │
                    │  Tailscale (tailscale0): 100.81.225.123               │
                    │  兼 subnet router，廣播 192.168.100.0/24 給手機/Mac     │
                    └──────────────────────────────────────────────────────┘
```

注意：worker 節點磁碟原本是 120GB，因為 Longhorn 容量不足，已在線上活體擴容到
200GB，詳見下方「Storage（Longhorn）」。claude-sentinel / daily_log 是跑在 T480
host 本身（不是任何一個 VM 裡面），跟 k8s cluster 完全獨立。

---

## 網路架構

```
外部裝置（iPhone / Mac）
        │
        ▼
  Tailscale VPN
  （T480 廣播 subnet route：192.168.100.0/24）
        │
        ▼
  T480 (100.81.225.123)
        │
        ▼
  MetalLB LoadBalancer
   192.168.100.200                  192.168.100.201
  （Nginx Ingress，多數服務共用）      （gitlab-shell，Git SSH port 22）
        │
        ▼
  Nginx Ingress Controller（依 hostname 分流）
        │
    ┌───┼─────────┬────────────┬───────────────┐
    ▼   ▼         ▼            ▼               ▼
 gitlab  argocd  grafana   prometheus    alertmanager
 registry
 minio
```

| 網路區段 | 用途 |
|---------|------|
| `192.168.100.0/24` | KVM NAT，VM 之間互通 |
| `192.168.100.1` | Host bridge（virbr1） |
| `192.168.100.10–12` | K8s 節點 IP |
| `192.168.100.200` | MetalLB：Nginx Ingress（GitLab web/registry/minio、ArgoCD、Grafana、Prometheus、AlertManager 共用） |
| `192.168.100.201` | MetalLB：gitlab-shell（Git SSH，需要獨立 IP，無法用 host-based ingress 分流） |
| `192.168.100.200–250` | MetalLB LoadBalancer IP pool 範圍 |
| `100.81.225.123` | T480 的 Tailscale IP，同時是 subnet router |

### 對外服務網址（nip.io）

用 nip.io 讓網域名稱直接帶 IP（`<host>.<ip>.nip.io` 會解析成 `<ip>`），不用額外管
DNS server。

| 網址 | 對應服務 |
|------|---------|
| gitlab.192.168.100.200.nip.io | GitLab 網頁 |
| registry.192.168.100.200.nip.io | GitLab Container Registry |
| minio.192.168.100.200.nip.io | GitLab 內建 MinIO（GitLab 自己用的物件儲存，跟股票 dashboard 無關） |
| gitlab.192.168.100.201.nip.io | gitlab-shell（Git SSH） |
| argocd.192.168.100.200.nip.io | ArgoCD Web UI |
| grafana.192.168.100.200.nip.io | Grafana |
| prometheus.192.168.100.200.nip.io | Prometheus |
| alertmanager.192.168.100.200.nip.io | AlertManager |

### 內部 PKI（兩層憑證鏈）

手機 / Mac 要能無警告地用 HTTPS 存取上面這些服務，用的是自建的兩層內部 Root CA，
而不是 Tailscale 原生的 TLS（後者只能簽 `*.ts.net`，覆蓋不到 nip.io 網址）：

```
selfsigned-bootstrap（ClusterIssuer，自簽）
        │
        ▼
homelab-root-ca（Certificate，isCA=true，RSA 2048，10 年效期）
   存在 secret: homelab-root-ca-secret（namespace: cert-manager）
        │
        ▼
homelab-ca-issuer（ClusterIssuer，type: ca）
   之後所有服務的憑證都由這裡簽發，共用同一條信任鏈
        │
    ┌───┼────────┬──────────┬──────────────┐
    ▼   ▼        ▼          ▼              ▼
 GitLab ArgoCD Grafana  Prometheus   AlertManager
```

只有 `homelab-root-ca` 這張根憑證需要手動裝進 Mac / iPhone 的信任清單。裝過一次後，
之後任何新服務只要憑證是這條鏈簽出來的，兩台裝置都會自動信任，不會再跳警告。

GitLab chart 會替 webservice / registry / minio 各自建立獨立 ingress，但共用同一個
`secretName`；如果讓 cert-manager 的 ingress-shim 自動幫每個 ingress 各建一張
Certificate，會互搶同一個 secret 互相覆蓋。因此改用一張明確宣告的多 SAN
Certificate（`gitlab-wildcard-tls`，涵蓋 gitlab / registry / minio 三個 host）取代
自動產生。

### Tailscale Subnet Router

T480 用 `tailscale up --advertise-routes=192.168.100.0/24` 廣播內部網段路由，並在
Tailscale admin console 手動核准這個 route。手機和 Mac 因此可以直接用
`192.168.100.x` 或對應的 nip.io 網址存取叢集內服務，不需要額外 VPN 設定。

libvirt 預設的 `LIBVIRT_FWI` iptables chain 只放行 RELATED,ESTABLISHED 的流量，會擋
掉從 `tailscale0` 進來的新連線，需要額外開洞，並確保 libvirtd 重啟 / 開機後仍會套用：

```bash
# /etc/libvirt/hooks/network
#!/bin/bash
if [ "$1" = "k8s-net" ] && [ "$2" = "started" ]; then
    iptables -C LIBVIRT_FWI -i tailscale0 -o virbr1 -d 192.168.100.0/24 -j ACCEPT 2>/dev/null || \
    iptables -I LIBVIRT_FWI 1 -i tailscale0 -o virbr1 -d 192.168.100.0/24 -j ACCEPT
fi
```

---

## Kubernetes Cluster

### 節點規格

| 節點 | 角色 | IP | vCPU | RAM | Disk |
|------|------|----|------|-----|------|
| k8s-control | control plane | 192.168.100.10 | 2 | 4GB | 50GB |
| k8s-worker1 | worker | 192.168.100.11 | 2 | 20GB | 200GB |
| k8s-worker2 | worker | 192.168.100.12 | 2 | 20GB | 200GB |

worker 磁碟原本各 120GB，因為 host 實際還有大量剩餘空間（466GB 中大部分未用），
在線上活體擴容到 200GB：`virsh blockresize`（qcow2 層）+ `growpart`（分割區層）+
`resize2fs`（檔案系統層），全程不停機、不影響既有資料。

### 核心元件

| 元件 | 版本 | 用途 |
|------|------|------|
| kubeadm | v1.32 | Cluster 安裝與管理 |
| Calico | - | CNI 網路插件 |
| MetalLB | v0.14.x | Bare metal LoadBalancer（L2 mode） |
| Nginx Ingress | - | HTTP/HTTPS 路由 |
| Longhorn | 1.7.2 | 分散式 block storage |
| cert-manager | - | 內部 PKI / TLS 憑證管理 |

### Storage（Longhorn）踩過的坑

- StorageClass 的 `numberOfReplicas` 預設是 3，但只有 2 個 worker 節點可排程，第三
  個副本永遠排不進去，所有 volume 會卡在 `degraded` 且不會自己好。修法：Helm 安裝
  時加 `--set persistence.defaultClassReplicaCount=2`（這個值才是動態建立 PVC 真正
  吃到的設定；`defaultSettings.defaultReplicaCount` 只影響用 Longhorn UI 手動建立
  的 volume），並手動把既有 volume 的 `spec.numberOfReplicas` patch 成 2。
- 每顆磁碟的 `storageReserved` 手動從自動計算的 ~34.6GB 降到 10GB，讓 Longhorn 可用
  更多實際容量。
- `storage-minimal-available-percentage`、`storage-over-provisioning-percentage`
  一度分別調整過（10%、取消 overcommit 限制），後來 worker 磁碟從 120GB 擴到
  200GB、根本原因（容量太小）解決後，兩個設定都改回預設值（25%、100%）。

---

## Platform Services

### GitLab CE（worker1）

- Helm chart 版本鎖定在 9.11.7（GitLab CE 18.11），因為 chart v10+ 要求外接
  PostgreSQL / Redis / MinIO；這個規模用內建的 bundled 服務就夠，不需要外部依賴。
- 包含 Container Registry、內建 MinIO（GitLab 自己用的物件儲存）。
- GitLab Runner 用 Kubernetes executor；runner 註冊 token 不進版控，只在
  `helm install/upgrade` 時用 `--set runnerToken=...` 帶入。
- gitlab-shell（Git SSH）獨立開一個 LoadBalancer Service，拿到獨立 IP
  （192.168.100.201），因為 SSH 是原始 TCP port 22，無法像 HTTP 一樣靠 ingress 的
  hostname 分流。
- `k8s` repo 設定了 GitLab 到 GitHub 的自動 push mirror：GitLab 是主要來源，GitHub
  是備份。

### ArgoCD（worker1）

- GitOps CD 工具，監控 `k8s` repo（root Application 名稱 `k8s-gitops`），
  `prune: true` + `selfHeal: true`，任何 drift 會自動修正回 git 定義的狀態。
- 有 Web UI，可從手機查看部署狀態。
- `k8s` repo 目前除了 README 之外沒有其他 manifest，所以 ArgoCD 現在沒有實際
  workload 在跑，等股票 dashboard 專案上線才會真正派上用場。

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

| 工具 | 版本 | 用途 |
|------|------|------|
| Prometheus | kube-prometheus-stack chart 87.6.0 | Metrics 收集與儲存（retention 15 天） |
| AlertManager | 同上 bundle | 告警規則與通知（Discord） |
| Grafana | 同上 bundle | Dashboard 視覺化，已接上 Prometheus + Loki 兩個 datasource |
| Loki | chart 7.0.0 | Log 收集與查詢，SingleBinary 部署模式、storage 用 filesystem |
| Promtail | chart 6.17.1 | Log 收集 agent（每個節點的 DaemonSet） |

**為什麼是 Loki 不是 ELK**：Loki 對目前這種規模的 k8s log（namespace 數量少、log
量小）已經夠用，設定和資源消耗都比 ELK 輕很多。ELK（Elasticsearch / Logstash /
Kibana）的優勢是大規模全文搜尋和複雜聚合分析，這個專案用不到，等以後真的在工作中
遇到大規模 log 需求再學。Loki 選 SingleBinary 模式（不是 microservices 模式）、
storage 選 filesystem（不是 S3-compatible object storage），都是因為規模小、沒有
HA 需求，選最簡單的設定就好。

---

## Host-Native Applications（不進 k8s）

`claude-sentinel` 和 `daily_log` 刻意留在 T480 host 上，用 user-level systemd
timer + podman（rootless）執行。**不會**搬進 k8s、**不會**接 GitLab CI/CD、**不會**
進 ArgoCD 的 GitOps 迴路、**不會**接進 Prometheus / Loki 這套監控。原因見前面
「範圍與決策」。

| Timer | 排程 | 說明 |
|-------|------|------|
| `claude-sentinel.timer` | 每 3 分鐘 | 查詢 Claude Pro 用量，內部邏輯約每 20 分鐘送一次 Discord 通知 |
| `daily-log-sync.timer` | 每 30 分鐘 | 把 Discord 訊息同步進 `daily_log` repo 的 log 檔案（直接 bind mount 整個 repo 寫入） |
| `daily-log-analysis-weekly.timer` | 每週一 02:00 | 產生週報分析 |
| `daily-log-analysis-monthly.timer` | 每月 1 號 02:00 | 產生月報分析 |

這兩個 repo（`claude-sentinel` 公開、`daily_log` 私有）都只放在 GitHub，不會加進
自架 GitLab。

---

## CI/CD 流程

以下是設計給未來 workload（例如股票 dashboard）用的流程，目前 `k8s` repo 是空的，
還沒有任何 app 真正走過整條路徑。

```
開發者 push code
        │
        ▼
  GitLab（self-hosted）
        │
        ├──── mirror ────► GitHub（備份）
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
homelab-infra/    ← 本 repo（私有，GitHub only）
├── terraform/    ← KVM VM 定義（Terraform + libvirt）
├── ansible/      ← OS 設定、kubeadm 安裝、平台服務 Helm values（Ansible）
└── ARCHITECTURE.md

k8s/              ← GitOps repo（私有，GitLab 為主、GitHub 為 mirror）
└── README.md     ← 目前唯一內容；apps/、platform/ 之後依實際需要才建立，
                     不預先建空目錄

claude-sentinel/  ← App code（公開）GitHub only，host-native，不進 k8s/GitLab
daily_log/        ← App code（私有）GitHub only，host-native，不進 k8s/GitLab
```

### Repo 同步策略

| Repo | 可見性 | 主要來源 | Mirror | 備註 |
|------|--------|---------|--------|------|
| homelab-infra | 私有 | GitHub | 無 | 沒有 GitLab 版本：這是 bootstrap GitLab 本身的 repo，放不進它自己建立的 GitLab（雞生蛋問題），也不需要 CI/CD |
| k8s | 私有 | GitLab（自架） | GitHub | ArgoCD 直接盯 GitLab；GitHub 是備份 |
| claude-sentinel | 公開 | GitHub | 無 | 刻意不進 GitLab，host-native app |
| daily_log | 私有 | GitHub | 無 | 刻意不進 GitLab，host-native app |

---

## 未來規劃：股票 / 總經 Dashboard

- 長期運行的網站，即時彙整股票 + 總體經濟資訊，含分析功能，手機版面優先。
- 會需要：長期運行的 Deployment（不是 CronJob）、資料庫、Ingress、有意義的
  monitoring / alerting。
- 會是第一個真正需要、也真正用到這整套 k8s + GitOps + 觀測性堆疊的 workload。
- 尚未規劃技術細節（資料來源、分析方式、技術棧、即時性需求都還沒定案），會另開一個
  Claude Code session（可能也是獨立 repo）處理。
- 技術棧定案、有實際 code 之後，才會在 `k8s` repo 底下建立對應的 manifest，讓
  ArgoCD 開始同步。

---

## 建置順序

```
Phase 1  Terraform 建立 KVM VM                    完成
Phase 2  Ansible 安裝 kubeadm cluster              完成
Phase 3  安裝 Calico / MetalLB / Nginx Ingress     完成
Phase 4  安裝 Longhorn storage                     完成
Phase 5  安裝 GitLab CE + Runner                   完成
Phase 6  安裝 ArgoCD，建立 k8s repo，打通 GitOps 迴路  完成
Phase 7  安裝 Prometheus + Grafana + Loki + Promtail  完成
Phase 8  遷移 claude-sentinel / daily_log 到 k8s    取消（永久留在 host，見「範圍與決策」）
Phase 9  對外 HTTPS 存取                           完成（nip.io + 自建兩層 PKI + Tailscale subnet router，
                                                    非原先設想的 Tailscale 原生 TLS）
Phase 10 GitHub mirror                             完成（僅 k8s repo；其餘三個 repo 維持 GitHub-only）
(未排入 Phase)  股票 / 總經 Dashboard 專案          另開 session 規劃，見「未來規劃」
```
