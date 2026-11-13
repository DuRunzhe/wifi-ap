#!/usr/bin/env bash
# 阶段 2：组建虚拟局域网（把整个局域网网段接入你的私有网络，随时随地上门）
# 默认用 Tailscale，最省事；想自建/不用第三方可换 ZeroTier（脚本末尾有说明）。
#
#   sudo bash 20-tailscale.sh                 # 自动探测 br0 所在网段
#   sudo bash 20-tailscale.sh <网段>/24       # 手动指定
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BR=br0
# 默认取 br0 上的网段（/24）；探测不到时要求显式传入
detect_route() {
  local a
  a=$(ip -4 -o addr show "$BR" 2>/dev/null | awk 'NR==1{split($4,x,"/"); print x[1]}')
  [[ -n "$a" ]] || return 1
  printf '%s\n' "$a" | awk -F. '{printf "%s.%s.%s.0/24\n",$1,$2,$3}'
}
ROUTE=${1:-}
if [[ -z "$ROUTE" ]]; then
  ROUTE=$(detect_route) || { echo "探测不到 $BR 的网段，请手动指定: sudo bash $0 <网段>/24"; exit 1; }
fi
[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 [网段]"; exit 1; }

log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

log "开启 IP 转发"
cat > /etc/sysctl.d/99-tailscale.conf <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -q --system

if ! command -v tailscale >/dev/null; then
  log "安装 Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi

log "以子网路由器身份上线（需要浏览器登录授权）"
# --snat-subnet-routes 默认 true：本机只是 L2 成员、不是网关时，靠 SNAT 让外部设备访问内网设备
tailscale up --advertise-routes="$ROUTE" --snat-subnet-routes --accept-routes

log "状态"
tailscale status || true
echo
cat <<EOF

✅ 还需最后一步（在 Tailscale 管理后台）：
   Machines → 本机 → Edit route settings → 勾选 $ROUTE → Save

验证（在外部网络的一台设备上）：
   ping <本机 br0 地址>
   ping <主路由地址>

想同时把本机当「出口节点」让外网流量走这里：
   sudo tailscale up --advertise-routes=$ROUTE --advertise-exit-node --snat-subnet-routes
   （同样要去后台批准 exit node）

换成 ZeroTier：
   curl -s https://install.zerotier.com | sudo bash
   sudo zerotier-cli join <你的网络ID>
   # 后台里勾选 Managed Routes: $ROUTE via <本机 zerotier IP>
EOF
