#!/bin/bash
# libvirt network hook：允許 Tailscale subnet route 的流量轉發進 k8s-net (virbr1)。
#
# 背景：libvirt 為 NAT network 自動產生的 LIBVIRT_FWI chain 只允許
# RELATED,ESTABLISHED 的回應封包進入，會 REJECT 所有從其他介面
# （例如 tailscale0）發起的新連線。這個 hook 在 k8s-net 每次啟動時
# （開機、libvirtd 重啟、network 重啟）補上一條 ACCEPT 規則。
#
# 安裝方式（需 root）：
#   sudo cp libvirt-tailscale-forward-hook.sh /etc/libvirt/hooks/network
#   sudo chmod +x /etc/libvirt/hooks/network

if [ "$1" = "k8s-net" ] && [ "$2" = "started" ]; then
    iptables -C LIBVIRT_FWI -i tailscale0 -o virbr1 -d 192.168.100.0/24 -j ACCEPT 2>/dev/null || \
    iptables -I LIBVIRT_FWI 1 -i tailscale0 -o virbr1 -d 192.168.100.0/24 -j ACCEPT
fi
