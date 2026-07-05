# 操作指令參考

這份補充 `ARCHITECTURE.md`，只放「手動操作時會用到的指令」，不重複解釋架構或決策
原因（那些在 `ARCHITECTURE.md`）。所有指令都是實際在這個 cluster 上驗證過的。

---

## SSH 進節點

三個節點都是同一組帳號密鑰：

| 節點 | IP |
|------|-----|
| k8s-control | 192.168.100.10 |
| k8s-worker1 | 192.168.100.11 |
| k8s-worker2 | 192.168.100.12 |

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.100.10   # k8s-control
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.100.11   # k8s-worker1
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.100.12   # k8s-worker2
```

---

## kubectl

**重要**：T480 本機預設的 `~/.kube/config` 是舊的 minikube 殘留設定（指向一個已經沒
在跑的 `127.0.0.1:45135` proxy），跟這個 kubeadm cluster 完全無關。直接下
`kubectl` 不指定 `KUBECONFIG` 會連線失敗，不要覆蓋這個檔案，避免更混亂。

真正的 kubeconfig 在 k8s-control 節點上的 `/home/ubuntu/.kube/config`。

**方法一：SSH 進 k8s-control 直接下指令**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@192.168.100.10
kubectl get nodes
```

**方法二：本機直接下 kubectl（已經設好，不用每次 SSH）**

已經把節點上的 kubeconfig 複製到本機 `~/.kube/homelab-config`（server IP
`192.168.100.10` 本機可以直接連到，不用改內容），用法：

```bash
export KUBECONFIG=~/.kube/homelab-config
kubectl get nodes
```

要長期方便可以加進 `~/.bashrc`（目前還沒加，要自己加）：

```bash
alias k='KUBECONFIG=~/.kube/homelab-config kubectl'
```

如果之後重新 kubeadm init 或憑證輪替，這份本機複製的 kubeconfig 會失效，要重新
`scp ubuntu@192.168.100.10:/home/ubuntu/.kube/config ~/.kube/homelab-config`。

---

## Helm

目前實際裝的 release（`helm list -A`，跑在 k8s-control 上）：

| Release | Namespace | Chart |
|---------|-----------|-------|
| argocd | argocd | argo-cd-10.1.0 |
| cert-manager | cert-manager | cert-manager-v1.16.2 |
| gitlab | gitlab | gitlab-9.11.7 |
| gitlab-runner | gitlab-runner | gitlab-runner-0.90.1 |
| ingress-nginx | ingress-nginx | ingress-nginx-4.15.1 |
| kube-prometheus-stack | monitoring | kube-prometheus-stack-87.6.0 |
| loki | monitoring | loki-7.0.0 |
| longhorn | longhorn-system | longhorn-1.7.2 |
| promtail | monitoring | promtail-6.17.1 |

（MetalLB 不在這張表裡，因為是用 `kubectl apply` 裝官方 manifest，不是 Helm。）

常用操作：

```bash
helm list -A                                  # 看全部 release
helm get values <release> -n <namespace>      # 看目前生效的 values
helm status <release> -n <namespace>          # 看安裝狀態
helm history <release> -n <namespace>         # 看版本歷史
helm rollback <release> <revision> -n <namespace>   # 回滾
```

改設定重新套用：

```bash
helm upgrade <release> <chart> -n <namespace> -f /path/to/values.yml
```

**注意**：GitLab 那次踩過的坑——`--reuse-values` 只會「合併」新舊值，如果你是要
**移除**某個 key（例如拿掉某個 annotation），`--reuse-values` 不會讓移除生效，
必須帶完整的 values file 重新 apply，不能只帶差異。

---

## Terraform

在 `terraform/` 目錄下執行：

```bash
cd terraform
terraform plan      # 看變更
terraform apply     # 套用變更
```

`terraform destroy` 會整組 VM 砍掉重練，非必要不要跑。

---

## Ansible

在 `ansible/` 目錄下執行：

```bash
cd ansible
ansible all -i inventory/hosts.yml -m ping              # 測試連線
ansible-playbook -i inventory/hosts.yml playbooks/<name>.yml
ansible-playbook -i inventory/hosts.yml playbooks/<name>.yml --limit k8s-worker1  # 只對單一節點跑
```

---

## virsh / VM 管理

VM 是跑在 T480 host 本身（不用 SSH，直接在 host 上下指令）：

```bash
virsh list --all                    # 列出所有 VM 及狀態
virsh start k8s-worker1             # 開機
virsh shutdown k8s-worker1          # 正常關機
virsh destroy k8s-worker1           # 強制關機（等同拔電源，非必要不要用）
virsh console k8s-worker1           # 進 console（Ctrl+] 離開）
virsh dominfo k8s-worker1           # 看 VM 詳細資訊（vCPU/記憶體/狀態）
virsh domblklist k8s-worker1        # 看掛載的磁碟
```

Storage pool 名稱是 `homelab`，network 名稱是 `k8s-net`：

```bash
virsh pool-list --all
virsh net-list --all
virsh net-dhcp-leases k8s-net       # 看目前 DHCP 租約
```

---

## 各服務網址與登入資訊

| 服務 | 網址 |
|------|------|
| GitLab | https://gitlab.192.168.100.200.nip.io |
| GitLab Container Registry | https://registry.192.168.100.200.nip.io |
| ArgoCD | https://argocd.192.168.100.200.nip.io |
| Grafana | https://grafana.192.168.100.200.nip.io |
| Prometheus | https://prometheus.192.168.100.200.nip.io |
| AlertManager | https://alertmanager.192.168.100.200.nip.io |

取密碼指令（在 k8s-control 上跑，或本機用 `KUBECONFIG=~/.kube/homelab-config`）：

```bash
# GitLab root 密碼
kubectl get secret gitlab-root-password -n gitlab -o jsonpath='{.data.password}' | base64 -d; echo

# ArgoCD admin 密碼
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo

# Grafana admin 密碼
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

GitLab 帳號是 `root`；ArgoCD 帳號是 `admin`；Grafana 帳號是 `admin`。

---

## Longhorn UI

Longhorn 沒有設 ingress（只有內部服務），要用 port-forward 存取：

```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```

然後瀏覽器開 `http://localhost:8080`（如果是在 k8s-control 上跑這行，要嘛在節點
本機瀏覽，要嘛從本機再開一條 SSH port-forward：
`ssh -i ~/.ssh/id_ed25519 -L 8080:localhost:8080 ubuntu@192.168.100.10`，跑完上面
的 kubectl port-forward 後在本機瀏覽器開 `localhost:8080`）。

檢查 volume 健康狀態也可以直接下指令，不用開 UI：

```bash
kubectl get volumes.longhorn.io -n longhorn-system
```

---

## Tailscale

```bash
tailscale status                    # 看目前連線的裝置
tailscale status --json | grep -A3 AllowedIPs   # 看廣播的路由有沒有生效
sudo tailscale up --advertise-routes=192.168.100.0/24   # 重新廣播路由（如果不小心關掉）
```

Route 核准要到 Tailscale admin console 手動按（廣播不會自動生效）。

---

## Host-native Apps（claude-sentinel / daily_log）

這兩個不在 k8s 裡，是 T480 host 上的 **user-level** systemd timer（注意都要加
`--user`，不加會找不到）：

```bash
systemctl --user list-timers                          # 看排程
systemctl --user status claude-sentinel.service        # 看單次執行狀態
systemctl --user status daily-log-sync.service
journalctl --user -u claude-sentinel.service -f        # 即時看 log
journalctl --user -u daily-log-sync.service --since today

systemctl --user start claude-sentinel.service          # 手動立即觸發一次（不等排程）
systemctl --user start daily-log-sync.service

systemctl --user restart claude-sentinel.timer          # 重啟排程本身
```

---

## 磁碟擴容流程（備忘）

之前 worker 節點從 120GB 擴到 200GB 用的完整流程，不停機、不影響既有資料。之後如果
容量又不夠，照抄這個順序（`<vm>` 換成實際 VM 名稱，`<size>` 換成目標大小）：

```bash
# 1. qcow2 檔案本身的大小（在 T480 host 上執行）
virsh blockresize <vm> /path/to/disk.qcow2 <size>G

# 2. 分割區大小（進 VM 裡，SSH 進去執行）
ssh -i ~/.ssh/id_ed25519 ubuntu@<vm-ip>
sudo growpart /dev/vda 1        # 分割區編號依實際情況調整

# 3. 檔案系統大小（同樣在 VM 裡）
sudo resize2fs /dev/vda1

# 4. 確認
df -h /
```

擴完之後記得回 `terraform/variables.tf` 把對應節點的 `disk_gb` 改成新的數字，
`terraform plan` 應該顯示 `No changes`（代表 state 跟實際狀態一致），再 commit。

---

## 操作提醒

- `systemctl` 不加 `--user` 會找不到 claude-sentinel / daily_log 的 unit（這兩個是
  user-level，不是 system-level）。
- Longhorn UI 沒有 ingress，只能 port-forward，見上面「Longhorn UI」章節。

實際發生過的問題（症狀/原因/解法）都整理到 `TROUBLESHOOTING.md` 了，這裡不重複。
