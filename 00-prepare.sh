#!/usr/bin/env bash
# 阶段 0.5：让"固定 IP + AP 自动运行"在重启后依然成立
#
#   在 01-ap-bridge.sh 之后跑（也允许先跑，缺 br0 的部分会提示重跑）。
#
# 做四件事：
#   1) 探测一个空闲地址，作为 br0 的「静态别名」（DHCP 地址保留，默认路由/上游 DNS 仍跟随主路由）
#   2) 让 NetworkManager 永久不再接管 wlan0（否则重启后 NM 会把 hostapd 踢掉）
#   3) 用专用 hostapd-br0.service 取代 Debian 的 sysv hostapd 服务：
#      Type=simple + After=br0 设备 + ExecStartPre 轮询等 br0 + Restart=always
#   4) 提供 status 子命令，重启后跑一遍就能确认全部就位
#
# 用法：
#   sudo bash 00-prepare.sh setup            # 自动探测空闲地址
#   sudo bash 00-prepare.sh setup --ip <网段>.<地址>
#   sudo bash 00-prepare.sh status
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BR=br0
WIFI=wlan0
CONF=/etc/hostapd/hostapd-${BR}.conf
FIXED=""
ACTION=""

SW_SSID=""
SW_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    setup|status|show|set-wifi) ACTION="$1"; shift ;;
    --ip)   FIXED="$2"; shift 2 ;;
    --ssid) SW_SSID="$2"; shift 2 ;;
    --pass) SW_PASS="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
ACTION=${ACTION:-status}
[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 $ACTION"; exit 1; }

log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# 缺 qrencode 就自动装（NO_QR=1 可跳过；装不上不报错，降级为文本扫码串）
ensure_qrencode() {
  command -v qrencode >/dev/null && return 0
  [[ "${NO_QR:-0}" == 1 ]] && return 1
  command -v apt-get >/dev/null || return 1
  if command -v pgrep >/dev/null && pgrep -x dpkg >/dev/null; then
    warn "dpkg 正被占用，跳过 qrencode 安装"
    return 1
  fi
  log "安装 qrencode（用于生成扫码连接的二维码）…"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 \
     || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1; }; then
    command -v qrencode >/dev/null && return 0
  fi
  warn "qrencode 安装失败（无外网或 apt 源不可用），改用文本扫码串"
  return 1
}
ok(){ printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
no(){ printf '\033[1;31m  ✗\033[0m %s\n' "$*"; }

# 客户端计数：这块 Unisoc 驱动不支持 station dump（返回空），只能数桥转发表里 wlan0 端口的 MAC
wifi_client_count() {
  local pn dec self brm n
  pn=$(cat /sys/class/net/${BR}/brif/${WIFI}/port_no 2>/dev/null) || pn=""
  if [[ -z "$pn" ]]; then
    n=$(iw dev "$WIFI" station dump 2>/dev/null | grep -c '^Station' || true)
    echo "${n:-0}"; return
  fi
  dec=$((pn))
  self=$(cat /sys/class/net/${WIFI}/address 2>/dev/null)
  brm=$(cat /sys/class/net/${BR}/address 2>/dev/null)
  brctl showmacs "$BR" 2>/dev/null \
    | awk -v p="$dec" -v s="$self" -v b="$brm" \
        'NR>1 && $1==p && $2!=s && $2!=b && $3=="no"{n++} END{print n+0}'
}

wifi_client_list() {                     # MAC 与老化时间（秒）
  local pn dec self brm
  pn=$(cat /sys/class/net/${BR}/brif/${WIFI}/port_no 2>/dev/null) || { echo "(该驱动不支持 station dump)"; return; }
  dec=$((pn))
  self=$(cat /sys/class/net/${WIFI}/address 2>/dev/null)
  brm=$(cat /sys/class/net/${BR}/address 2>/dev/null)
  brctl showmacs "$BR" 2>/dev/null \
    | awk -v p="$dec" -v s="$self" -v b="$brm" \
        'NR>1 && $1==p && $2!=s && $2!=b && $3=="no"{printf "    %s  age=%.1fs\n", $2, $4}'
}

# ---------------------------------------------------------------- 地址探测
# 返回 0 = 该地址已被【别的设备】占用（自己 br0 上的地址不算占用）
ip_in_use() {                       # $1 = ip
  local ip=$1 own mac m
  own=$(cat /sys/class/net/${BR}/address 2>/dev/null | tr 'A-Z' 'a-z')
  if command -v arping >/dev/null 2>&1; then
    # ARP 层探测：比 ping 可靠（有的设备不回 ICMP，但一定回 ARP）
    while read -r mac; do
      [[ -z "$mac" ]] && continue
      m=$(echo "$mac" | tr 'A-Z' 'a-z')
      [[ "$m" == "$own" ]] && continue          # 自己回说明是自己的地址
      return 0                                   # 别的 MAC 在回 => 冲突
    done < <(arping -D -c 2 -w 2 -I "$BR" "$ip" 2>/dev/null \
             | sed -n 's/.*\[\([0-9A-Fa-f:]*\)\].*/\1/p')
    return 1
  fi
  ip neigh show | awk -v i="$ip" '$1==i{found=1} END{exit !found}' && return 0
  ping -c1 -W1 "$ip" >/dev/null 2>&1 && return 0
  return 1
}

pick_ip() {
  if [[ -n "$FIXED" ]]; then
    ip_in_use "$FIXED" && { warn "$FIXED 已被其他设备占用，换一个"; exit 1; }
    echo "$FIXED"; return
  fi
  local base=$1 n cand
  # 从高往低找：高位地址落在 DHCP 池的概率最小
  for n in 253 252 251 250 249 248 247 246 245 244 243 242 241 240; do
    cand="${base%.*}.${n}"
    if ! ip_in_use "$cand"; then echo "$cand"; return; fi
  done
  warn "没找到空闲地址，请用 --ip 手动指定"; exit 1
}

# ---------------------------------------------------------------- 关键信息展示
show_wifi() {
  local ssid pass band ch sec
  if [[ -r $CONF ]]; then
    ssid=$(sed -n 's/^ssid=//p' "$CONF" | head -1)
    pass=$(sed -n 's/^wpa_passphrase=//p' "$CONF" | head -1)
    band=$(sed -n 's/^hw_mode=//p' "$CONF" | head -1)
    ch=$(sed -n 's/^channel=//p' "$CONF" | head -1)
    sec=$(sed -n 's/^wpa=//p' "$CONF" | head -1)
    if [[ "$sec" == 2 ]]; then sec="WPA2-PSK/CCMP"; fi
  else
    ssid="(未生成，先跑 01-ap-bridge.sh)"; pass="-"; band="-"; ch="-"; sec="-"
  fi
  local addrs
  addrs=$(ip -4 -o addr show "$BR" 2>/dev/null | awk '{printf "%s  ", $4}')
  local sta
  sta=$(wifi_client_count)
  sta=${sta:-0}

  printf '\n\033[1;36m══════════════ WiFi 关键信息 ══════════════\033[0m\n'
  printf '  SSID      : \033[1;32m%s\033[0m\n' "$ssid"
  printf '  密码      : \033[1;32m%s\033[0m\n' "$pass"
  printf '  加密      : %s\n' "$sec"
  printf '  频段/信道 : %s / %s\n' "$([ "$band" = a ] && echo 5GHz || echo 2.4GHz)" "$ch"
  printf '  本机地址  : %s\n' "${addrs:-（br0 还没有地址）}"
  printf '  已连设备  : %s 台\n' "$sta"
  printf '  配置文件  : %s\n' "$CONF"
  printf '\033[1;36m═══════════════════════════════════════════\033[0m\n'

  # 手机扫码直连（缺 qrencode 时自动装，装不上降级为文本串）
  if [[ -n "$ssid" && -n "$pass" && "$pass" != "-" ]]; then
    local qr="WIFI:T:WPA;S:${ssid};P:${pass};;"
    echo "  扫码连 WiFi："
    if [[ "${NO_QR:-0}" == 1 ]]; then
      echo "  扫码串: $qr"
    elif ensure_qrencode; then
      qrencode -t ANSIUTF8 "$qr"
    else
      echo "  扫码串: $qr"
      echo "  手动装: sudo apt install -y qrencode  /  不显示二维码: NO_QR=1"
    fi
  fi
  echo "  改 SSID: sudo bash $(readlink -f "$0") set-wifi --ssid 新名字"
  echo "  改密码: sudo bash $(readlink -f "$0") set-wifi --pass 新密码（≥8 位）"
  echo
}

# ---------------------------------------------------------------- 改 SSID/密码
do_set_wifi() {
  [[ -r $CONF ]] || { warn "还没有 $CONF，先跑 01-ap-bridge.sh"; exit 1; }
  [[ -n "$SW_SSID$SW_PASS" ]] || { warn "至少给一个 --ssid 或 --pass"; exit 1; }
  if [[ -n "$SW_PASS" && ${#SW_PASS} -lt 8 ]]; then
    warn "WPA2 密码至少 8 位（当前 ${#SW_PASS} 位）"; exit 1
  fi

  local old_ssid
  old_ssid=$(sed -n 's/^ssid=//p' "$CONF" | head -1)

  if [[ -n "$SW_SSID" ]]; then
    if grep -q '^ssid=' "$CONF"; then
      sed -i "s|^ssid=.*|ssid=$SW_SSID|" "$CONF"
    else
      echo "ssid=$SW_SSID" >> "$CONF"
    fi
    log "SSID: $old_ssid → $SW_SSID"
  fi
  if [[ -n "$SW_PASS" ]]; then
    if grep -q '^wpa_passphrase=' "$CONF"; then
      sed -i "s|^wpa_passphrase=.*|wpa_passphrase=$SW_PASS|" "$CONF"
    else
      echo "wpa_passphrase=$SW_PASS" >> "$CONF"
    fi
    log "密码已更新（旧密码立即失效，所有设备需重新输入）"
  fi
  chmod 600 "$CONF"

  log "重启 AP…"
  systemctl restart hostapd-br0 2>/dev/null || systemctl restart hostapd 2>/dev/null || true
  sleep 3
  systemctl is-active --quiet hostapd-br0 || systemctl is-active --quiet hostapd \
    || { warn "AP 重启失败：journalctl -u hostapd-br0 -n 30"; exit 1; }
  show_wifi
}

# ---------------------------------------------------------------- setup
do_setup() {
  # 1) 固定地址
  local cidr base fixed
  base=$(ip -4 -o addr show "$BR" 2>/dev/null | awk 'NR==1{sub(/\/.*/,"",$4); print $4}')
  if [[ -z "$base" ]]; then
    base=$(ip -4 -o addr show eth0 2>/dev/null | awk 'NR==1{sub(/\/.*/,"",$4); print $4}')
  fi
  [[ -n "$base" ]] || { warn "拿不到网段，先跑 01-ap-bridge.sh"; exit 1; }
  fixed=$(pick_ip "$base")
  cidr="${fixed}/24"
  log "静态别名地址: $cidr"

  if nmcli -t -f NAME con show | grep -qx "$BR"; then
    nmcli con mod "$BR" ipv4.addresses "$cidr"
    nmcli con up "$BR" >/dev/null 2>&1 || true
    sleep 2
    ok "已写入 br0 profile 的 ipv4.addresses（DHCP 地址同时保留）"
  else
    warn "还没有 $BR 连接（先跑 01-ap-bridge.sh，再重跑本脚本）；地址稍后补"
  fi

  # 兜底 oneshot：NM 万一没加上就补上
  cat > /etc/systemd/system/fixed-ip.service <<EOF
[Unit]
Description=Ensure static alias $cidr on $BR
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# 等 br0 真的出现（否则开机时序会失败）
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do ip link show $BR >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
ExecStart=/bin/sh -c 'ip -4 addr show $BR 2>/dev/null | grep -qw "$fixed" || ip addr add $cidr dev $BR || true'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now fixed-ip.service >/dev/null 2>&1 || true
  ok "fixed-ip.service 已启用（兜底）"

  # 2) wlan0 永久 unmanaged —— 这条不做，重启后 NM 会抢走 wlan0
  cat > /etc/NetworkManager/conf.d/99-unmanaged-wlan0.conf <<EOF
# 由 wifi-ap/00-prepare.sh 生成：wlan0 交给 hostapd，NM 不要接管
[keyfile]
unmanaged-devices=interface-name:$WIFI;interface-name:p2p-dev-$WIFI
EOF
  systemctl reload NetworkManager 2>/dev/null || true
  ok "NM 已永久放开 $WIFI（/etc/NetworkManager/conf.d/99-unmanaged-wlan0.conf）"

  # 3) 专用 hostapd 单元，解决开机顺序 + 崩溃自愈
  cat > /etc/systemd/system/hostapd-br0.service <<EOF
[Unit]
Description=hostapd AP on $WIFI bridged to $BR
After=network-online.target sys-subsystem-net-devices-${BR}.device
Wants=network-online.target
# 确保不早于 NM 建桥
After=NetworkManager-wait-online.service

[Service]
Type=simple
# 等 br0 出现再启动（最多 60s）
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do [ -d /sys/class/net/$BR ] && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/sbin/hostapd -f /var/log/hostapd-$BR.log $CONF
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl disable --now hostapd.service >/dev/null 2>&1 || true
  systemctl mask hostapd.service >/dev/null 2>&1 || true
  sed -i '/^DAEMON_CONF=/d' /etc/default/hostapd 2>/dev/null || true
  systemctl enable hostapd-br0.service >/dev/null 2>&1
  systemctl restart hostapd-br0.service
  sleep 3
  systemctl is-active --quiet hostapd-br0.service \
    && ok "hostapd-br0.service 已接管（sysv hostapd 已停用）" \
    || { no "hostapd-br0 启动失败"; journalctl -u hostapd-br0 -n 20 --no-pager; }

  # 4) 结果
  echo
  log "固定地址（写进你的设备配置和文档里）: $fixed"
  log "SSH / 代理客户端网关都用这个地址"
  show_wifi
  log "现在可以 reboot 验证了；重启后执行: sudo bash $0 status"
}

# ---------------------------------------------------------------- status
do_status() {
  show_wifi
  echo "===== 地址 ====="
  ip -4 -o addr show "$BR" 2>/dev/null | awk '{printf "  %-6s %-16s\n",$2,$4}' || no "$BR 不存在"
  echo "  默认路由: $(ip route | awk '/^default/{print $3" via "$5}' | head -1)"
  echo
  echo "===== 固定地址冲突自检（ARP 层）====="
  if command -v arping >/dev/null 2>&1; then
    local own a ip m bad=0
    own=$(cat /sys/class/net/${BR}/address 2>/dev/null | tr 'A-Z' 'a-z')
    while read -r a; do
      [[ -n "$a" ]] || continue
      ip=${a%/*}
      while read -r m; do
        [[ -z "$m" ]] && continue
        m=$(echo "$m" | tr 'A-Z' 'a-z')
        [[ "$m" == "$own" ]] && continue
        no "$ip 存在冲突！另一台设备 MAC=$m 也在用这个地址"
        bad=1
      done < <(arping -D -c 2 -w 2 -I "$BR" "$ip" 2>/dev/null | sed -n 's/.*\[\([0-9A-Fa-f:]*\)\].*/\1/p')
    done < <(ip -4 -o addr show "$BR" 2>/dev/null | awk '{print $4}')
    [[ $bad -eq 0 ]] && ok "br0 上所有地址均无冲突"
    [[ $bad -eq 1 ]] && echo "   处理: sudo bash $0 setup --ip x.x.x.250（换一个空闲地址）"
  else
    echo "  (未安装 arping，跳过；apt install -y iputils-arping)"
  fi

  echo
  echo "===== NetworkManager ====="
  nmcli -t -f NAME,DEVICE,AUTOCONNECT con show 2>/dev/null | grep -E "$BR|$WIFI" || true
  nmcli device status 2>/dev/null | grep -E "$WIFI|$BR" || true
  [[ -f /etc/NetworkManager/conf.d/99-unmanaged-wlan0.conf ]] \
    && ok "wlan0 unmanaged 配置存在（重启后 NM 不会抢走）" \
    || no "缺 /etc/NetworkManager/conf.d/99-unmanaged-wlan0.conf → 重启后 AP 会被 NM 踢掉"
  echo
  echo "===== AP ====="
  systemctl is-enabled hostapd-br0.service >/dev/null 2>&1 && ok "hostapd-br0 已 enable（开机自启）" || no "hostapd-br0 未 enable"
  systemctl is-active  hostapd-br0.service >/dev/null 2>&1 && ok "hostapd-br0 运行中"            || no "hostapd-br0 未运行"

  # sysv hostapd：看真实状态而不是 is-active（init 脚本跑完就退也会显示 active (exited)）
  local en hp
  en=$(systemctl is-enabled hostapd.service 2>/dev/null | tail -1) || true
  case "$en" in
    masked)   ok "sysv hostapd 已 mask（永远不会启动）" ;;
    disabled) ok "sysv hostapd 已 disabled" ;;
    enabled)  no "sysv hostapd 仍 enabled，建议: sudo systemctl mask hostapd" ;;
    *)        ok "sysv hostapd 状态: ${en:-未知}" ;;
  esac
  hp=$(pgrep -x hostapd 2>/dev/null | wc -l)
  if [[ $hp -le 1 ]]; then
    ok "hostapd 进程数: $hp"
  else
    no "有 $hp 个 hostapd 进程，可能互抢 wlan0: $(pgrep -a hostapd | tr '\n' ' ')"
  fi
  pgrep -a hostapd 2>/dev/null | grep -q "hostapd-${BR}.conf" && ok "hostapd 用的是 $CONF"
  iw dev "$WIFI" info 2>/dev/null | grep -q 'type AP' && ok "wlan0 = AP 模式" || no "wlan0 不是 AP"
  echo "  已连客户端: $(wifi_client_count)"
  wifi_client_list
  echo
  echo "===== 桥 ====="
  brctl show "$BR" 2>/dev/null | sed 's/^/  /' || no "无 $BR"
  echo
  echo "===== 固定地址兜底 ====="
  systemctl is-enabled fixed-ip.service >/dev/null 2>&1 && ok "fixed-ip.service 已 enable" || no "fixed-ip.service 未 enable"
  echo
  echo "===== 进阶1（可选） ====="
  printf "  mihomo    : %s\n" "$(systemctl is-active mihomo 2>/dev/null || true)"
  printf "  proxy-gw  : %s\n" "$(systemctl is-active proxy-gw 2>/dev/null || true)"
  echo
  echo "===== 历史（hostapd 崩溃/重启）====="
  journalctl -u hostapd-br0 -n 5 --no-pager 2>/dev/null | sed 's/^/  /' || true
}

case "$ACTION" in
  setup)    do_setup ;;
  status)   do_status ;;
  show)     show_wifi ;;
  set-wifi) do_set_wifi ;;
  *) echo "用法: sudo bash $0 {setup [--ip x.x.x.x]|status|show|set-wifi [--ssid 名字] [--pass 密码]}"; exit 1 ;;
esac
