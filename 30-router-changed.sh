#!/usr/bin/env bash
# 主路由更换 / 网段变化后的一键适配
#
# 换主路由时，AP 本身（hostapd + br0）一定还在广播、设备之间照样互访（纯 L2，不依赖路由）。
# 需要重新对齐的只有三样：
#   1) 固定地址（旧网段的静态别名会变成死地址）
#   2) 代理规则里的网段/本机地址（进阶1）
#   3) Tailscale 通告的网段（阶段2）
#
# 用法：
#   sudo bash 30-router-changed.sh            # 自动检测并适配
#   sudo bash 30-router-changed.sh --dry-run  # 只看会做什么
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BR=br0
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1
[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 [--dry-run]"; exit 1; }

log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
run(){ if [[ $DRY -eq 1 ]]; then echo "   [dry] $*"; else eval "$@"; fi; }

net_of(){ echo "$1" | awk -F. '{print $1"."$2"."$3}'; }

echo "===== 现状 ====="
ip -4 -o addr show "$BR" 2>/dev/null | awk '{print "  br0: "$4}'
GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
echo "  默认网关: ${GW:-（无）}"
echo "  DNS: $(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"
echo

# ---------- 1. 重新获取 DHCP ----------
if [[ -n "${GW:-}" ]]; then
  log "1/5 重新获取租约（新路由可能换了网段）"
  run "nmcli con up $BR >/dev/null 2>&1 || true"
  sleep 3
else
  warn "1/5 当前没有默认路由，先检查网线 / 新路由是否已就绪"
fi
ip -4 -o addr show "$BR" 2>/dev/null | awk '{print "  现在: "$4}'

# ---------- 2. 推导新网段 ----------
GW=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
SRC=""
if [[ -n "${GW:-}" ]]; then
  SRC=$(ip route get "$GW" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
fi
[[ -z "${SRC:-}" ]] && SRC=$(ip -4 -o addr show "$BR" 2>/dev/null | awk 'NR==1{split($4,a,"/"); print a[1]}')
if [[ -z "${SRC:-}" ]]; then
  warn "拿不到任何 IPv4 —— 新路由很可能【不提供 DHCP】（桥接/纯 AP 模式）"
  cat <<'EOF'
   两种解法：
   a) 让上游设备给 DHCP（把新路由改成"路由模式"或关掉它的 AP 模式）
   b) 让本机发 DHCP：在 br0 上跑 dnsmasq，下发本机为网关/ DNS
      （注意：必须先关掉其它 DHCP 服务器，否则会抢答）
        sudo apt install -y dnsmasq
        # /etc/dnsmasq.d/br0.conf
        interface=br0
        bind-dynamic
        dhcp-range=<网段>.100,<网段>.199,12h
        然后 sudo systemctl restart dnsmasq
EOF
  exit 1
fi
NEWBASE=$(net_of "$SRC")
log "2/5 当前网段: $NEWBASE.0/24（本机 $SRC）"

# ---------- 3. 清理旧网段的静态别名 ----------
log "3/5 清理不属于 $NEWBASE.0/24 的地址"
STALE=()
while read -r a; do
  [[ -n "$a" ]] || continue
  ip=${a%/*}
  [[ "$(net_of "$ip")" == "$NEWBASE" ]] && continue
  STALE+=("$a")
done < <(ip -4 -o addr show "$BR" 2>/dev/null | awk '{print $4}')

if [[ ${#STALE[@]} -eq 0 ]]; then
  echo "   没有需要清理的残留地址"
else
  for a in "${STALE[@]}"; do
    echo "   删除旧地址 $a"
    run "ip addr del $a dev $BR 2>/dev/null || true"
  done
  # NM profile 里的旧静态地址也要清掉，否则重启后又回来
  run "nmcli con mod $BR ipv4.addresses '' >/dev/null 2>&1 || true"
fi

# ---------- 4. 重新计算固定别名 ----------
log "4/5 重新计算固定地址（复用 00-prepare.sh）"
SELF_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
if [[ -x "$SELF_DIR/00-prepare.sh" ]] || [[ -f "$SELF_DIR/00-prepare.sh" ]]; then
  if [[ $DRY -eq 1 ]]; then
    echo "   [dry] bash $SELF_DIR/00-prepare.sh setup"
  else
    bash "$SELF_DIR/00-prepare.sh" setup | sed 's/^/   /'
  fi
else
  warn "找不到 00-prepare.sh，跳过"
fi

# ---------- 5. 代理 / 组网 ----------
log "5/5 其他组件"
if systemctl list-unit-files 2>/dev/null | grep -q '^proxy-gw.service'; then
  echo "   检测到进阶1 代理，按新网段重下规则"
  run "bash $SELF_DIR/10-proxy-gw.sh setup >/dev/null 2>&1 || true"
else
  echo "   未启用进阶1 代理，跳过"
fi

if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  warn "Tailscale 通告的网段需要手动更新："
  echo "     sudo tailscale up --advertise-routes=$NEWBASE.0/24 --snat-subnet-routes"
  echo "     并到 Tailscale 后台重新批准该路由"
fi

echo
echo "===== 完成 ====="
ip -4 -o addr show "$BR" 2>/dev/null | awk '{print "  br0: "$4}'
echo "  网关: $(ip route | awk '/^default/{print $3; exit}')"
echo "  AP  : $(iw dev wlan0 info 2>/dev/null | awk '/ssid/{print "SSID="$2}') / $(iw dev wlan0 info 2>/dev/null | awk '/type/{print $2}')"
PN=$(cat /sys/class/net/$BR/brif/wlan0/port_no 2>/dev/null)
WCNT=0
if [[ -n "$PN" ]]; then
  WCNT=$(brctl showmacs "$BR" 2>/dev/null \
    | awk -v p="$((PN))" -v s="$(cat /sys/class/net/wlan0/address)" -v b="$(cat /sys/class/net/$BR/address)" \
        'NR>1 && $1==p && $2!=s && $2!=b && $3=="no"{n++} END{print n+0}')
fi
echo "  客户端数: $WCNT"
echo
echo "提醒："
echo "  * 固定地址可能变化，SSH 请用上面 br0 的第二个地址"
echo "  * 如果新路由的 DHCP 池包含这个固定地址，改用: sudo bash 00-prepare.sh setup --ip $NEWBASE.250"
