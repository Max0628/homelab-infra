# Troubleshooting

每一條盡量照這個格式寫：**症狀 → 原因 → 解法 → 狀態**。狀態欄要老實標
`已解決` / `Workaround（未根治）` / `待處理`，不要為了好看寫成都已解決。

---

## Kubernetes 排程 / 資源

### vCPU 調太低導致 CPU request 超賣（OutOfcpu / Pending / CrashLoopBackOff）

**症狀**：把三個節點（k8s-control、worker1、worker2）的 vCPU 從 2 調到 1 之後，
大量 pod 卡住：`longhorn-system` 的 instance-manager 直接 `OutOfcpu`，
`gitlab-sidekiq` 卡 `Pending`，`gitlab-registry` 進入 `CrashLoopBackOff`，
Prometheus / Grafana / AlertManager 卡在 `Init`。

**原因**：`kubectl describe node` 顯示三個節點的 CPU **request**（不是實際使用
率）都逼近或超過 100% allocatable：

```
k8s-control:  1100m 已請求 / 1000m 可分配  → 110%（還沒放任何 app workload）
k8s-worker1:   925m 已請求 / 1000m 可分配  → 92%
k8s-worker2:   970m 已請求 / 1000m 可分配  → 97%
```

k8s 排程是用 pod 宣告的 `resources.requests.cpu` 做 admission 檢查，跟實際會用
多少 CPU 無關。control-plane 本身（kube-apiserver + etcd + scheduler +
controller-manager + kube-proxy + calico-node）的 request 加總就已經超過
1000m，代表 1 vCPU 連叢集自己的地基都放不下，不是「workload 太肥」而已。

**解法**：把三台的 `vcpu` 從 `variables.tf` 改回 `2`，`terraform apply` 讓
libvirt domain destroy + recreate（改 `vcpu` 這個屬性在這個 provider 版本
`dmacvicar/libvirt = 0.8.3` 底下是 ForceNew，必須整個重建，不是單純 reboot）。

**狀態**：已解決。省電/降溫的需求後來改在 host 層用 TLP 處理，跟 k8s 的 vCPU
帳本完全脫鉤，見下面「Host 電源管理」。

---

## 網路（Tailscale / libvirt / MetalLB）

### Mac 經 Tailscale 連 k8s VIP 出現 `ERR_CONNECTION_REFUSED`

**症狀**：Mac（Chrome 或 curl 都一樣）連
`https://<service>.192.168.100.200.nip.io` 直接被拒絕，且失敗得很快
（~200ms，不是 timeout）。發生在當天做完好幾輪 terraform VM destroy + recreate
之後。

**排除過程**（記錄下來避免下次繞遠路）：

1. 一開始懷疑 MetalLB speaker 在節點抖動時重新 GARP，導致 Mac ARP cache 中毒。
   但 `sudo arp -d 192.168.100.200` 在 Mac 上顯示 `cannot locate`——**這條路一開
   始就不成立**：Mac 是透過 Tailscale subnet route（`utun0`）連進
   `192.168.100.0/24`，不在同一個 L2 網段，本來就不會有這個 IP 的 ARP 紀錄。
2. 從 T480 host 本機直接 `curl` 同一個 VIP：成功（`302`，1.7s）。代表 k8s /
   ingress / MetalLB 本身健康，問題出在「host 本機發起連線」跟「從 Mac 經
   Tailscale 轉進來的連線」這兩條路徑的差異上。
3. `tailscale status` 兩邊都是 `active; direct`，Mac 的 route table 也確實有
   `utun0` 這條 route——隧道和路由都沒問題。
4. Mac 直接 `curl -v`（跳過 Chrome）：一樣 `Connection refused`，199ms 內被拒
   絕——確認跟 Chrome 無關，是純網路層問題，而且反應快到像是被主動 REJECT，不
   是封包被默默丟棄。
5. `sudo iptables -L LIBVIRT_FWI -n -v` 查到關鍵：

   ```
   1. ACCEPT  *→virbr1  ...  ctstate RELATED,ESTABLISHED
   2. REJECT  *→virbr1  0.0.0.0/0  (無條件全擋)         ← 問題在這條
   3. ACCEPT  *→virbr0  ...  ctstate RELATED,ESTABLISHED
   4. REJECT  *→virbr0  ...
   5. ACCEPT  tailscale0→virbr1  192.168.100.0/24         ← 這條規則排太後面
   ```

**原因**：`/etc/libvirt/hooks/network` 這個 hook 會在 `k8s-net` 網路啟動時插入
第 5 條規則，放行 `tailscale0 → virbr1` 的新連線。但 iptables 由上到下比對、
比到第一條符合的規則就停止，第 2 條「無條件 REJECT 所有進 virbr1 的非
established 流量」排在第 5 條之前，導致從 Mac 經 tailscale0 進來的新連線永遠在
第 2 條就被擋下，回 `icmp-port-unreachable`，根本輪不到第 5 條生效。判斷是當天
多輪 terraform VM destroy + recreate 期間，libvirt 重新生成了它自己管理的
RELATED/ESTABLISHED + REJECT 那組規則，把原本排在前面的自訂規則擠到了最後面。

**解法**：

```bash
sudo iptables -I LIBVIRT_FWI 1 -i tailscale0 -o virbr1 -d 192.168.100.0/24 -j ACCEPT
```

用 `-I ... 1` 插到最前面，比第 2 條 REJECT 先比對到。下完之後 Mac 端立即恢復
正常。

**狀態**：**Workaround，未根治**。這條規則只在當前 iptables runtime state 生
效，沒有寫回任何持久化機制。如果之後 host 重開機、或又對 VM 做
destroy + recreate 導致 libvirt 重新生成這個 chain，這條手動插入的規則順序很可
能又被擠到後面、問題重演。待辦：確認 `/etc/libvirt/hooks/network` 的邏輯有沒有
處理「規則已存在但順序不對」的情況（目前只用 `iptables -C ... || iptables -I
... 1` 檢查規則存不存在，不檢查順序），或考慮改成每次都無條件 `-I` 插入到最前
面、不做存在性檢查。

---

## Storage（Longhorn）

### `numberOfReplicas` 預設 3，但只有 2 個 worker 節點可排程

**症狀**：所有 Longhorn volume 卡在 `degraded`，不會自己好。

**原因**：StorageClass 的 `numberOfReplicas` 預設是 3，但 cluster 只有 2 個
worker 節點可排程（control-plane 有 taint），第三個副本永遠排不進去。

**解法**：Helm 安裝時加 `--set persistence.defaultClassReplicaCount=2`（這個值
才是動態建立 PVC 真正吃到的設定；`defaultSettings.defaultReplicaCount` 只影響
用 Longhorn UI 手動建立的 volume），並手動把既有 volume 的
`spec.numberOfReplicas` patch 成 2。

**狀態**：已解決。

### `storageReserved` 預設過於保守

**症狀**：Longhorn 可用容量比實際磁碟小很多。

**原因**：每顆磁碟的 `storageReserved` 自動計算出來大約 34.6GB，預留過多。

**解法**：手動把 `storageReserved` 降到 10GB。

**狀態**：已解決。

### Worker 磁碟太小（120GB），一度靠調鬆 over-provisioning 設定頂著

**症狀**：磁碟快滿，Longhorn 開始因為容量不足產生告警/限制。

**原因**：worker 節點磁碟原本各只有 120GB，根本容量不夠。

**解法（過程）**：曾經暫時調整過 `storage-minimal-available-percentage`（降到
10%）、`storage-over-provisioning-percentage`（取消 overcommit 限制）當作止血，
後來真正解決根本原因——worker 磁碟用 `virsh blockresize`（qcow2 層）+
`growpart`（分割區層）+ `resize2fs`（檔案系統層）三步驟線上活體擴容到
200GB，全程不停機、不影響既有資料——之後就把這兩個設定都改回預設值（25%、
100%），不需要繼續頂著。

**狀態**：已解決，根本原因（容量）已排除，暫時性設定已還原。

---

## Host 電源管理（TLP）

### 設定檔用了舊版 key 名稱，TLP 1.6.1 不認得

**症狀**：部署 TLP drop-in 設定後，`CPU_HWP_ON_AC` 這個值看起來沒有生效
（`tlp-stat -c` 抓不到這個 key）。

**原因**：`CPU_HWP_ON_AC` 是舊版 TLP 的 key 名稱，這台裝的 TLP 1.6.1 用的是
`CPU_ENERGY_PERF_POLICY_ON_AC`（可從 `/etc/tlp.conf` 的預設值註解確認）。

**解法**：把 `ansible/files/tlp/50-homelab.conf` 裡的 key 改成
`CPU_ENERGY_PERF_POLICY_ON_AC=balance_power`。

**狀態**：已解決。

### EPP 設定改對 key 之後仍然不生效（TLP 本身的限制）

**症狀**：key 名稱修正後，`energy_performance_preference` 這個 sysfs 值還是
停在 `balance_performance`，沒有變成設定檔裡指定的 `balance_power`。

**診斷**：手動 `echo balance_power | sudo tee
/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference` 之後用
`cat` 確認，**寫入是穩定生效的**，代表 kernel/硬體完全沒問題；問題在 TLP 自己
執行 `tlp start` 時沒有正確把這個設定套用到 sysfs（`TLP_DEBUG="cpu" tlp
start` 也沒有任何相關 debug log，怀疑是這個版本對 HWP-active 模式 CPU 處理
EPP 的已知限制或 bug）。`CPU_BOOST_ON_AC`（關 turbo）和
`CPU_SCALING_GOVERNOR_ON_AC`（powersave）這兩個影響最大的設定，TLP 本身套用
正常，只有 EPP 這個設定受影響。

**解法**：另外寫一個 systemd oneshot service
（`ansible/files/tlp/homelab-cpu-epp.service`），開機時對所有 CPU 核心的
`energy_performance_preference` 直接寫入 `balance_power`，`After=tlp.service`
確保排在 TLP 之後、蓋過它的（無效的）設定。一樣由 `install-tlp.yml` 佈署。

**狀態**：Workaround，繞過而非根治 TLP 本身的問題，但效果穩定、開機自動套用。

---

## kubectl / 工具存取

### 本機 `~/.kube/config` 是舊 minikube 殘留設定

**症狀**：直接下 `kubectl` 指令（不指定 KUBECONFIG）出現
`dial tcp 127.0.0.1:45135: connect: connection refused`。

**原因**：T480 本機的 `~/.kube/config` 是很久以前裝 minikube 留下的 context，
指向一個早就沒在跑的本機 proxy port（`127.0.0.1:45135`），跟現在這個 kubeadm
cluster 完全無關。minikube 本身的 profile 狀態也顯示異常（`unknown state`）。

**解法（分兩步）**：

1. 短期：`export KUBECONFIG=~/.kube/homelab-config`（這份是從 k8s-control 節點
   `/home/ubuntu/.kube/config` 複製過來的正確 kubeconfig）。
2. 徹底處理：確認不再需要 minikube 後，`minikube delete --all --purge` 整個移
   除，並把 `~/.kube/homelab-config` 複製成 `~/.kube/config`，讓預設路徑直接指
   向正確的 cluster，不用每次手動 export。

**狀態**：已解決。

### Helm `--reuse-values` 只會合併不會刪除 key

**症狀**：想拿掉 GitLab values 裡某個既有的 key/annotation，用
`--reuse-values` + 新的 `--set` 更新後，舊的 key 還在，沒有真的被移除。

**原因**：`--reuse-values` 的行為是「合併」舊值和新值，不會因為新的 values 沒
帶某個 key 就把它刪掉。

**解法**：要移除設定必須帶**完整的 values file** 重新 `helm upgrade`，不能只
帶差異部分。

**狀態**：已知限制，操作時注意，非 bug。

---

## 待清理（小事，尚未處理）

### `kube-system` 裡有孤兒 coredns pod

`coredns-668d6bf9bc-svpv6` 卡在 `ContainerStatusUnknown`，是 control-plane 那
次 VM destroy + recreate 留下的孤兒 pod 物件（新 VM 的 kubelet 不認得舊的
container runtime 狀態）。跟任何目前的服務問題無關，純粹是殘留物件，之後找時間
清掉即可：

```bash
kubectl delete pod -n kube-system coredns-668d6bf9bc-svpv6
```

**狀態**：待處理（優先度低，不影響任何服務，deployment 會自動維持正確的
replica 數量）。
