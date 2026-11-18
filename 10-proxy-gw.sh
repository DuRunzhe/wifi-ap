#!/usr/bin/env bash
# 进阶1：把本机变成「按需网关 + 透明代理」——与基础桥接完全独立
#
#   基础（一直开着）：手机 ⇄ br0 ⇄ 主路由 .254，网关是主路由，直连，跟代理无关
#   进阶1（可选开关）：手机把「网关/DNS」改成本机 br0 地址 → 经过本机 → TPROXY 透明代理
#                     不改的设备完全不受影响；关掉进阶1，改回「自动」就恢复直连
#
# 为什么必须「客户端改网关」：桥接模式下客户端流量是 L2 交换过去的，目的 MAC 是主路由，
# 不进本机三层协议栈；主路由又不可操作（改不了 DHCP option 3/6），所以只能由客户端侧指定。
#
# 用法：
#   sudo bash 10-proxy-gw.sh setup --sub 'https://你的订阅链接'   # 首次：装 mihomo + 起服务 + 下发规则
#   sudo bash 10-proxy-gw.sh setup                                # 已有 /etc/mihomo/config.yaml
#   sudo bash 10-proxy-gw.sh off                                  # 停代理，保留转发（改网关的客户端仍有网）
#   sudo bash 10-proxy-gw.sh full-off                             # 全部拆除，回到纯净桥接
#   sudo bash 10-proxy-gw.sh status
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

LAN=br0
# 探测上行网卡：默认路由所在接口；若路由在桥上，则取该桥的第一个物理 port
# （兼容 eth0 / end0 / enp1s0；排除 br/veth/docker/tun/wlan 等虚拟或无线接口）
_detect_uplink(){
  local d
  d=$(ip route show default 2>/dev/null | awk '{print $5}' | grep -vE '^(veth|docker|virbr|tun|tap|wg)' | head -1)
  if [[ ${d:-} == br* && -d /sys/class/net/$d/brif ]]; then
    ls /sys/class/net/$d/brif 2>/dev/null | grep -vE '^(veth|tap|tun|wg|wlan|p2p)' | head -1
  else
    printf '%s' "${d:-}"
  fi
}
WAN=${WAN:-$(_detect_uplink)}
if [[ -z $WAN ]]; then
  echo "无法自动探测上行网卡（默认路由缺失），请用 WAN=<网卡名> 显式指定" >&2
  exit 1
fi
# 留空则自动从当前默认路由推导（换主路由/换网段后不用改脚本）
NET=${NET:-}
LOCAL_IP=${LOCAL_IP:-}
TPORT=7895
DNSPORT=1053
MARK=1
TABLE=100
CHAIN=PI_TPROXY
MIHOMO_CONF=/etc/mihomo/config.yaml
MIHOMO_BIN=/usr/local/bin/mihomo
SUB=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sub)  SUB="$2"; shift 2 ;;
    --ip)   LOCAL_IP="$2"; shift 2 ;;
    --net)  NET="$2"; shift 2 ;;
    --lan)  LAN="$2"; shift 2 ;;
    --wan)  WAN="$2"; shift 2 ;;
    setup|off|full-off|status|apply-rules) ACTION="$1"; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
ACTION=${ACTION:-status}
[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 $ACTION"; exit 1; }

# ---- 自动推导网段 / 本机地址（换主路由后无需改脚本）----
derive_net() {
  local gw src
  gw=$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')
  if [[ -n "${gw:-}" ]]; then
    src=$(ip route get "$gw" 2>/dev/null \
          | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi
  [[ -z "${src:-}" ]] && src=$(ip -4 -o addr show "$LAN" 2>/dev/null \
          | awk 'NR==1{split($4,a,"/"); print a[1]}')
  [[ -z "$LOCAL_IP" && -n "${src:-}" ]] && LOCAL_IP=$src
  if [[ -z "$NET" && -n "${src:-}" ]]; then
    NET=$(echo "$src" | awk -F. '{print $1"."$2"."$3".0/24"}')
  fi
}
if [[ -z "$NET" || -z "$LOCAL_IP" ]]; then derive_net; fi
if [[ -z "$NET" || -z "$LOCAL_IP" ]]; then
  echo "无法推导网段/本机地址，请用 --net x.x.x.0/24 --ip x.x.x.y 指定"
  exit 1
fi

log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- 规则
apply_rules() {
  log "开启 IP 转发"
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-proxy-gw.conf
  sysctl -q -w net.ipv4.ip_forward=1

  log "TPROXY 链（只命中「把本机当网关」的客户端）"
  iptables -t mangle -N $CHAIN 2>/dev/null || true
  iptables -t mangle -F $CHAIN
  for d in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 \
           192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    iptables -t mangle -A $CHAIN -d $d -j RETURN
  done
  iptables -t mangle -A $CHAIN -p tcp -j TPROXY --on-port $TPORT --tproxy-mark $MARK
  iptables -t mangle -A $CHAIN -p udp -j TPROXY --on-port $TPORT --tproxy-mark $MARK
  iptables -t mangle -C PREROUTING -i $LAN -s $NET -j $CHAIN 2>/dev/null \
    || iptables -t mangle -A PREROUTING -i $LAN -s $NET -j $CHAIN

  log "策略路由表 $TABLE"
  ip rule list | grep -qw "fwmark 0x${MARK} lookup ${TABLE}" \
    || ip rule add fwmark $MARK lookup $TABLE
  ip route replace local 0.0.0.0/0 dev lo table $TABLE

  log "DNS 劫持到 mihomo(:$DNSPORT)"
  iptables -t nat -C PREROUTING -i $LAN -s $NET -p udp --dport 53 \
      -j DNAT --to-destination $LOCAL_IP:$DNSPORT 2>/dev/null \
    || iptables -t nat -A PREROUTING -i $LAN -s $NET -p udp --dport 53 \
      -j DNAT --to-destination $LOCAL_IP:$DNSPORT
  iptables -t nat -C PREROUTING -i $LAN -s $NET -p tcp --dport 53 \
      -j DNAT --to-destination $LOCAL_IP:$DNSPORT 2>/dev/null \
    || iptables -t nat -A PREROUTING -i $LAN -s $NET -p tcp --dport 53 \
      -j DNAT --to-destination $LOCAL_IP:$DNSPORT

  log "转发 + SNAT（客户端和主路由同网段，不做 SNAT 回包会绕过本机）"
  iptables -t nat -C POSTROUTING -o $WAN -i $LAN -s $NET -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o $WAN -i $LAN -s $NET -j MASQUERADE
  iptables -C FORWARD -i $LAN -o $WAN -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i $LAN -o $WAN -j ACCEPT
  iptables -C FORWARD -i $WAN -o $LAN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i $WAN -o $LAN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  log "规则就绪 ✅"
}

off_rules() {
  log "撤掉 TPROXY / DNS 劫持（保留转发，改网关的客户端仍有网）"
  iptables -t mangle -D PREROUTING -i $LAN -s $NET -j $CHAIN 2>/dev/null || true
  iptables -t mangle -F $CHAIN 2>/dev/null || true
  iptables -t mangle -X $CHAIN 2>/dev/null || true
  iptables -t nat -D PREROUTING -i $LAN -s $NET -p udp --dport 53 -j DNAT --to-destination $LOCAL_IP:$DNSPORT 2>/dev/null || true
  iptables -t nat -D PREROUTING -i $LAN -s $NET -p tcp --dport 53 -j DNAT --to-destination $LOCAL_IP:$DNSPORT 2>/dev/null || true
}

full_off() {
  log "完全拆除"
  systemctl disable --now mihomo 2>/dev/null || true
  systemctl disable --now proxy-gw 2>/dev/null || true
  off_rules
  iptables -t nat -D POSTROUTING -o $WAN -i $LAN -s $NET -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i $LAN -o $WAN -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i $WAN -o $LAN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  ip rule del fwmark $MARK lookup $TABLE 2>/dev/null || true
  ip route flush table $TABLE 2>/dev/null || true
  rm -f /etc/systemd/system/proxy-gw.service /etc/sysctl.d/99-proxy-gw.conf
  systemctl daemon-reload
  log "已回到纯净桥接状态"
}

install_mihomo() {
  [[ -x $MIHOMO_BIN ]] && { log "mihomo 已安装: $($MIHOMO_BIN -v 2>/dev/null || echo ?)"; return; }
  log "下载 mihomo (linux-arm64)"
  local url
  url=$(curl -fsSL https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | tr ',' '\n' | grep -o 'https://[^"]*mihomo-linux-arm64-v[0-9.]*\.gz' | head -1)
  [[ -n "$url" ]] || { warn "取不到下载地址"; exit 1; }
  curl -fsSL "$url" | gunzip -c > "$MIHOMO_BIN"
  chmod +x "$MIHOMO_BIN"
  log "已装: $($MIHOMO_BIN -v)"
}

write_config() {
  [[ -f $MIHOMO_CONF ]] && { log "沿用已有配置 $MIHOMO_CONF"; return; }
  [[ -n "$SUB" ]] || {
    warn "没有 $MIHOMO_CONF，也没给 --sub"
    echo "可参考模板: $(dirname "$0")/mihomo-config.example.yaml"
    exit 1
  }
  log "生成 $MIHOMO_CONF（tproxy-port=$TPORT, dns=:$DNSPORT）"
  mkdir -p /etc/mihomo
  cat > "$MIHOMO_CONF" <<EOF
# 只监听局域网（br0）地址：不给 tailscale / usb0 / docker 等其它网卡开放代理端口
mixed-port: 7890
tproxy-port: $TPORT
allow-lan: true
bind-address: '$LOCAL_IP'
# ⚠️ allow-lan 下 7890 端口无鉴权，同网段任何人都能当代理用。
# 需要在多用户/不可信局域网部署时取消下面注释（mihomo 1.18+）：
# authentication:
#   - "user:pass"
mode: rule
log-level: info
ipv6: false
external-controller: 127.0.0.1:9090

dns:
  enable: true
  listen: 0.0.0.0:$DNSPORT
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - 'time.*.com'
    - 'ntp.*.com'
    - 'localhost.ptlogin2.qq.com'
    - '+.msftconnecttest.com'
    - '+.msftncsi.com'
    - '+.srv.nintendo.net'
    - '+.stun.playstation.net'
  nameserver:
    - 223.5.5.5
    - 119.29.29.29
  fallback:
    - https://1.1.1.1/dns-query
    - tls://8.8.4.4:853

proxy-providers:
  sub:
    type: http
    url: "$SUB"
    path: ./providers/sub.yaml
    interval: 86400
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: PROXY
    type: select
    use: [sub]
  - name: AUTO
    type: url-test
    use: [sub]
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50

rules:
  - DOMAIN-SUFFIX,lan,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
EOF
}

write_units() {
  log "写 systemd 服务"
  cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo (clash.meta) transparent proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$MIHOMO_BIN -d /etc/mihomo -f $MIHOMO_CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/proxy-gw.service <<EOF
[Unit]
Description=proxy-gw netfilter rules (TPROXY) for $NET
After=network-online.target mihomo.service
Wants=network-online.target
Requires=mihomo.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env bash $(readlink -f "$0") apply-rules
ExecStop=/usr/bin/env bash $(readlink -f "$0") off

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

case "$ACTION" in
  setup)
    install_mihomo
    write_config
    write_units
    apply_rules
    systemctl enable --now mihomo
    systemctl enable --now proxy-gw
    sleep 2
    systemctl is-active --quiet mihomo || { warn "mihomo 没起来"; journalctl -u mihomo -n 20 --no-pager; exit 1; }
    echo
    echo "✅ 进阶1 已就绪。现在在手机/电脑上把 WiFi 的 IP 设为静态："
    echo "     IP      <网段>.<2xx>（同网段任意空闲地址）"
    echo "     子网掩码 255.255.255.0"
    echo "     网关    $LOCAL_IP     ← 关键，指向本机才会被代理"
    echo "     DNS     $LOCAL_IP"
    echo
    echo "   不改网关的设备继续直连主路由 —— 与基础功能完全独立。"
    echo "   检查: sudo bash $0 status"
    echo "   关闭: sudo bash $0 off    (保留上网)   |   sudo bash $0 full-off"
    ;;
  off)
    systemctl disable --now proxy-gw 2>/dev/null || true
    systemctl disable --now mihomo 2>/dev/null || true
    off_rules
    log "透明代理已关闭；把网关改回「自动」即恢复原来的直连方式"
    ;;
  full-off) full_off ;;
  apply-rules) apply_rules ;;
  status)
    echo "--- mihomo ---";      systemctl is-active mihomo 2>/dev/null || true
    echo "--- proxy-gw ---";    systemctl is-active proxy-gw 2>/dev/null || true
    echo "--- ip rule ---";     ip rule list | grep -w "$TABLE" || echo "(无策略路由)"
    echo "--- tproxy 链 ---";   iptables -t mangle -S $CHAIN 2>/dev/null || echo "(无)"
    echo "--- 转发/SNAT ---";   iptables -t nat -S POSTROUTING | grep -w MASQUERADE || echo "(无)"
    echo "--- 当前活跃连接 ---"; ss -tnp 2>/dev/null | grep -E ":(7890|$TPORT)" | head -5 || true
    ;;
  *) echo "用法: sudo bash $0 {setup [--sub URL]|off|full-off|status}"; exit 1 ;;
esac
