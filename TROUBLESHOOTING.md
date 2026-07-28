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

<a name="storage-longhorn"></a>
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

### 舊 snapshot 沒清，讓 volume 實際磁碟佔用超過邏輯容量（>100%）

**症狀**：`longhorn_volume_actual_size_bytes / longhorn_volume_capacity_bytes`
算出來超過 100%（實測抓到 112.6%），比「快滿了」更怪——邏輯上一個 20Gi 的
volume 不應該用超過 20Gi。

**排查過程**：這次抓到的是 Prometheus 自己的資料庫 volume。一開始懷疑是不是
`add-platform-observability`/`add-business-metrics-and-alerting` 這兩個
change 新增大量指標（active target 28→41、series 73845→93244）把 Prometheus
自己的磁碟撐爆——但查 Prometheus 自己回報的 `prometheus_tsdb_storage_blocks_bytes`
只有 5.87GB（20Gi 的 27%），跟 Longhorn 回報的 112.6% 完全對不起來，代表問題
不在 Prometheus 這邊。

**原因**：直接查 Longhorn 自己的 CRD 才找到——

```bash
kubectl get volumes.longhorn.io <vol> -n longhorn-system -o jsonpath='{.status.actualSize}{"\n"}{.spec.size}{"\n"}'
kubectl get snapshots.longhorn.io -n longhorn-system | grep <vol>
```

`spec.size` 確實是 20GiB，但 `status.actualSize` 是 22.5GiB——多出來的差額
對應到一個**建立於 23 天前、之後從未清理過的 snapshot**（約 4GB）。Longhorn
的 snapshot 是 block-level 的歷史快照，即使 live 資料已經因為 Prometheus 的
15 天 retention 而輪替掉舊資料，舊 snapshot 仍然佔著那些歷史 block 不放，
造成實際磁碟佔用比邏輯容量高。

**解法**：確認不再需要這個 snapshot 後刪除即可釋放空間：

```bash
kubectl delete snapshots.longhorn.io -n longhorn-system <snapshot-name>
```

**狀態**：已定位根因，尚未清理（是否保留歷史快照屬於維運判斷，留給使用者
決定）。這是 `add-business-metrics-and-alerting` 新增的
`HomelabLonghornVolumeUsageHigh` 告警上線後幾分鐘內就抓到的第一個真實案例。

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

**2026-07-29 更新：同一個坑又踩了一次**，這次是 `kube-prometheus-stack-values.yml`
——從檔案裡拿掉一個壞掉的 `alertmanager.config` 區塊後，用 `--reuse-values` 重新
`helm upgrade`，結果壞掉的舊設定還在（因為 `--reuse-values` 拿舊值當底疊加新檔案，
不會因為新檔案沒有某個 key 就讓它消失）。修法跟上面完全一樣：改用讀出目前實際值
（這裡是 `grafana.adminPassword`）再明確 `--set` 回去，取代 `--reuse-values`，
不再依賴這個 flag 的合併行為。**這條本來就記錄過，這次是同一個錯誤犯了第二次**
——之後改動任何用 `--reuse-values` 或類似「部分更新」邏輯的 playbook 前，先回來看
這一段。見 `ansible/playbooks/update-prometheus-scrape-config.yml` 的修正。

---

<a name="job-radar-silent-failure"></a>
## job-radar 告警 Runbook

以下對應 `k8s` repo `apps/job-radar/prometheus-rules.yaml` 與
`platform/prometheus-rules.yaml` 裡各條告警的 `runbook_url`。

### JobRadarSourceSilent：某來源 6 小時內發現 0 筆新職缺

**這是「回 200 但沒有資料」的靜默失敗**，所有基礎設施層指標（pod 健康、CPU、
consumer lag）都會顯示正常，只有這條業務層告警看得到。

1. 先查 Loki（`{namespace="job-radar",app="collector"}`）確認最近幾輪掃描的
   結構化 log，看 `ScanService` 記的 `pages=` `jobsDiscovered=` 是否確實是 0
2. 直接呼叫來源平台的 API（見 `docs/source-api-notes.md` 記錄的實際端點）確認
   回應格式是否改變、或者是不是被 Cloudflare/WAF 擋掉但仍回 200
3. 檢查 `search_queries` 表對應這個 source 的設定是否被意外改壞（關鍵字、篩選
   條件）
4. 如果排除以上都正常，等下一輪掃描；若持續超過 12 小時，視為平台端真的改版，
   走 `add-multi-source-*` 的既有模式評估修復

<a name="job-radar-scan-failures"></a>
### JobRadarScanSuccessRateLow：過去 24 小時掃描成功率低於 95%（SLO-2）

1. 查 collector 的結構化 log，`ScanService.runScan` 失敗時會記
   `log.error("Scan failed source=... keyword=...", e)`，直接看 exception
   訊息
2. 常見原因：來源平台限速（429，`YouratorListScraper`/`CakeResumeListScraper`
   的 `jobradar_scrape_retry_total` 應該同時會升高）、平台改版、網路問題
3. 這條是 warning 不是 critical——95% 門檻本身就預留給外部平台的正常波動，
   持續違反才需要介入，單次觸發可以先觀察

<a name="job-radar-dlq"></a>
### JobRadarDlqNotEmpty：DLQ topic 有訊息（critical）

**代表資料正在遺失中，優先權最高。**

1. `kubectl exec -n job-radar kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh
   --bootstrap-server localhost:9092 --topic <topic> --from-beginning
   --max-messages 5 --property print.headers=true` 直接看訊息的
   `kafka_dlt-exception-message` header，通常就是根因
2. **這個告警真實抓到過一次**：`jobs.events.dlq` 從 2026-07-22 左右開始累積，
   一路到 207 筆都沒人發現，直到這條告警上線。根因是 `job-radar-discord`
   這個 SealedSecret 解出來的值是字面上的 `"REPLACE_ME"`
   （`secrets.example.yaml` 的 placeholder，從未被換成真的 webhook URL），
   `DiscordNotifier` 對非法 URL 拋 `IllegalArgumentException: URI is not
   absolute`。檢查方式：
   ```bash
   kubectl get secret job-radar-discord -n job-radar -o jsonpath='{.data.webhook-url}' | base64 -d
   ```
   如果印出來是 `REPLACE_ME`，就是這個問題——建立真的 Discord webhook，
   比照 `apps/job-radar/discord-sealed-secret.yaml` 的做法重新 seal 一份
3. 確認根因並修好後，DLQ 裡的訊息預設**不會自動重放**——需要手動把訊息從
   `<topic>.dlq` 重新 produce 回 `<topic>`，或評估是否可以放棄那批訊息
   （取決於資料的時效性）

<a name="job-radar-pipeline-latency"></a>
### JobRadarPipelineLatencySLOBurnFast / Slow：SLO-1 pipeline 延遲燃燒過快

pipeline 正常是秒級（三跳 Kafka + 一次 HTTP），觸發代表真的塞住了：

1. 先查 broker 端 consumer lag（`JobRadarConsumerLagGrowing` 是否也同時觸發）
2. 查 Discord API 是否被限流（`jobradar_notification_total{result="failure"}`
   是否升高、worker log 是否有 429 from discord.com）
3. 查 collector 端是否被來源平台限速拖慢發現速度

<a name="job-radar-discord-notification-failures"></a>
### JobRadarNotificationFailureRateHigh：Discord 推播失敗率 > 10%

跟 `JobRadarDlqNotEmpty` 經常一起觸發（見上面 DLQ 那條的真實案例），先查
webhook URL 是否還有效，再查 Discord API 本身狀態。

<a name="job-radar-consumer-lag"></a>
### JobRadarConsumerLagGrowing：consumer lag 持續增長

用的是 broker 端數據（kafka-exporter），不是 worker 自己回報的——worker 完全
掛掉時也會觸發（client 端的 lag 指標在目前的程式碼結構下其實完全不存在，見
`add-platform-observability` 的實測記錄）。先確認 worker pod 是否還在跑：

```bash
kubectl get pods -n job-radar -l app=worker
kubectl logs -n job-radar -l app=worker --tail=50
```

<a name="job-radar-postgres-connections"></a>
### JobRadarPostgresConnectionsHigh：連線數超過 80%

`postgres` 的資源預算是 500m CPU / 512Mi，連線池設定不當很容易撞到這個上限。
檢查 collector/worker/api 三個服務的 `spring.datasource.hikari` 設定，確認
連線池大小總和沒有超過 `pg_settings_max_connections`。

<a name="homelab-cert-expiring"></a>
### HomelabCertificateExpiringSoon：憑證 30 天內到期

cert-manager 應該會自動續期，這條是保險。查
`kubectl get certificate -A` 確認對應憑證的 `READY`/`RENEWAL TIME` 狀態，
`kubectl describe certificate <name> -n <ns>` 看續期有沒有報錯。

<a name="homelab-argocd-outofsync"></a>
### HomelabArgoCDAppOutOfSync：ArgoCD app 持續 OutOfSync 超過 15 分鐘

`kubectl get application k8s-gitops -n argocd -o jsonpath='{.status.resources
[?(@.status=="OutOfSync")]}'` 找出哪個資源不同步，確認是有人手動改了叢集
（`selfHeal: true` 應該會自動修正回去，如果沒有代表 selfHeal 本身出問題）
還是 sync 本身持續失敗（查 ArgoCD UI 的 sync 錯誤訊息）。

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
