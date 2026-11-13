#!/usr/bin/env bash
# 阶段 0：把本机变成 WiFi AP，且与有线网络「同一个内部局域网」（桥接模式）
#
#   手机A ─wifi─┐
#   手机B ─wifi─┤ [wlan0] ─ br0 ─ [eth0] ── 局域网 ── 主路由 ── 外网
#   有线设备 ───┘
#
# 三个需求一次满足：
#   1) 所有设备连到这一个 AP（换独立 SSID 名 → 主路由的 band steering 不会把它们吸走）
#   2) 同一 BSS 内设备互访由本机桥内转发，一次空口往返，不经过主路由的任何 AP
#   3) WiFi 客户端由主路由 DHCP 分配地址，与有线设备同网段
#
# 用法（PASS 必填，≥8 位）：
#   sudo -E env PASS='你的密码' bash 01-ap-bridge.sh
#   sudo -E env SSID=PiLink PASS='你的密码' BAND=5g CH=149 bash 01-ap-bridge.sh
#
# 任何一步失败会自动回滚到原始网络。
set -eEo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BR=br0
WIFI=wlan0
UPLINK=eth0
CONF=/etc/hostapd/hostapd-${BR}.conf
APLOG=/var/log/hostapd-${BR}.log
UNIT=hostapd-br0
SSID=${SSID:-PiLink}
PASS=${PASS:-}            # 必须显式提供（≥8 位），不再内置默认弱密码
BAND=${BAND:-5g}          # 5g | 2g（起不来会自动降级）
CH=${CH:-}                # 留空则 5g→149, 2g→6
GW=${GW:-}               # 留空 = 自动取当前默认路由的网关（换路由也不用改）
MAXSTA=${MAXSTA:-16}

if [[ $EUID -ne 0 ]]; then echo "请用: sudo bash $0"; exit 1; fi

# WiFi 密码强制由调用方提供，且满足 WPA2 最短长度
if [[ -z "$PASS" ]]; then
  echo "缺少 WiFi 密码。请用:" >&2
  echo "  sudo -E env PASS='你的密码' bash $0    # 或先跑 run-ap-setup.sh 'SSID' '密码'" >&2
  exit 1
fi
if [[ ${#PASS} -lt 8 ]]; then
  echo "WiFi 密码太短（${#PASS} 位），WPA2 要求至少 8 位。" >&2
  exit 1
fi

# 会话断开（SSH 被桥接切断）时不要跟着死，把流程跑完
trap '' HUP
DONE=0; REVERTED=0

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- 二维码
ensure_qrencode() {
  command -v qrencode >/dev/null && return 0
  [[ "${NO_QR:-0}" == 1 ]] && return 1
  command -v apt-get >/dev/null || return 1
  if command -v pgrep >/dev/null && pgrep -x dpkg >/dev/null; then
    warn "dpkg 正被占用，跳过 qrencode 安装"; return 1
  fi
  log "安装 qrencode（用于生成扫码连接的二维码）…"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1 \
     || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode >/dev/null 2>&1; }; then
    command -v qrencode >/dev/null && return 0
  fi
  warn "qrencode 安装失败（无外网或 apt 源不可用），改用文本扫码串"
  return 1
}
print_wifi_qr() {
  if [[ "${NO_QR:-0}" == 1 ]]; then printf '  扫码串: %s\n' "$1"; return; fi
  if ensure_qrencode; then qrencode -t ANSIUTF8 "$1"; else
    printf '  扫码串: %s\n' "$1"
    printf '  手动装: sudo apt install -y qrencode  /  不显示二维码: NO_QR=1\n'
  fi
}

# ---------------------------------------------------------------- 诊断
diag_bridge() {
  echo "---------- 诊断 ----------"
  echo "* nmcli device status"
  nmcli device status || true
  echo "* 连接状态"
  nmcli -t -f NAME,DEVICE,TYPE,STATE con show 2>/dev/null | grep -E "^(${BR}|${BR}-port-${UPLINK}|${ORIG_ETH}):" || true
  echo "* 从端口配置"
  nmcli -f connection.master,connection.slave-type,connection.autoconnect,connection.interface-name \
        con show "${BR}-port-${UPLINK}" 2>/dev/null || true
  echo "* br0 carrier = $(cat /sys/class/net/${BR}/carrier 2>/dev/null || echo n/a)"
  ip -d link show "$BR" 2>/dev/null | head -6 || true
  echo "* $UPLINK 上的 macvlan/ipvlan（存在就会导致 EBUSY）"
  ip -d link show type macvlan 2>/dev/null | head -6 || echo "    (无)"
  ip -d link show type ipvlan  2>/dev/null | head -6 || echo "    (无)"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "* docker macvlan 网络（parent 是 $UPLINK 的必须先拆）"
    docker network ls --filter driver=macvlan 2>/dev/null || true
  fi
  echo "* NetworkManager 最近日志"
  journalctl -u NetworkManager --since '-3min' --no-pager 2>/dev/null | tail -15 || true
  echo "--------------------------"
}

# ---------------------------------------------------------------- macvlan 处理
# eth0 上的 macvlan 会在底层设备注册 rx_handler → br_add_if() 返回 -EBUSY
# （NM 报 "Device or resource busy" / "could not be enslaved"）。
MACS=()

collect_macvlans() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 || { warn "docker 不可用，跳过 macvlan 检查"; return 0; }
  local n parent cfg sub gw eps
  while read -r n; do
    [[ -n "$n" ]] || continue
    parent=$(docker network inspect "$n" --format '{{index .Options "parent"}}' 2>/dev/null || true)
    [[ "$parent" == "$UPLINK" ]] || continue
    cfg=$(docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}}|{{.Gateway}}{{end}}' 2>/dev/null)
    sub=${cfg%%|*}; gw=${cfg##*|}
    eps=$(docker network inspect "$n" \
          --format '{{range .Containers}}{{.Name}}={{.IPv4Address}};{{end}}' 2>/dev/null \
          | sed -E 's#=[0-9./]*;#;#g; s#=;#;#g')
    MACS+=("$n|$sub|$gw|$eps")
    log "发现 macvlan 网络 [$n] parent=$UPLINK subnet=$sub 容器=${eps:-无}"
  done < <(docker network ls --format '{{.Name}}' --filter driver=macvlan 2>/dev/null)
}

release_macvlans() {
  local rec name sub gw eps ep err
  for rec in "${MACS[@]:-}"; do
    [[ -n "$rec" ]] || continue
    IFS='|' read -r name sub gw eps <<<"$rec"
    log "临时拆掉 macvlan [$name]（否则 $UPLINK 无法加入桥）"
    for ep in ${eps//;/ }; do
      [[ -n "$ep" ]] || continue
      docker network disconnect -f "$name" "${ep%%:*}" >/dev/null 2>&1 || true
    done
    if ! err=$(docker network rm "$name" 2>&1); then warn "删除 macvlan 失败: $err"; fi
  done
}

restore_macvlans() {
  local rec name sub gw eps ep c ip err
  for rec in "${MACS[@]:-}"; do
    [[ -n "$rec" ]] || continue
    IFS='|' read -r name sub gw eps <<<"$rec"
    if ! err=$(docker network create -d macvlan --subnet="$sub" --gateway="$gw" \
               -o parent="$BR" "$name" 2>&1); then
      warn "重建 macvlan [$name] 失败: $err"
      continue
    fi
    for ep in ${eps//;/ }; do
      [[ -n "$ep" ]] || continue
      c=${ep%%:*}; ip=${ep##*:}
      if [[ -n "$ip" ]]; then
        err=$(docker network connect --ip "$ip" "$name" "$c" 2>&1) \
          || warn "重连容器 $c 失败: $(echo "$err" | head -2)"
      else
        docker network connect "$name" "$c" >/dev/null 2>&1 || true
      fi
    done
    log "macvlan [$name] 已改挂到 $BR"
  done
}

# ---------------------------------------------------------------- hostapd 单元
install_unit() {
  # 与 00-prepare.sh 写的单元保持一致，避免重跑 01 时把开机顺序保障覆盖掉
  cat > /etc/systemd/system/${UNIT}.service <<EOF
[Unit]
Description=hostapd AP on $WIFI bridged to $BR
After=network-online.target sys-subsystem-net-devices-${BR}.device
Wants=network-online.target
After=NetworkManager-wait-online.service

[Service]
Type=simple
# 等 br0 出现再启动（最多 60s）
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do [ -d /sys/class/net/$BR ] && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/sbin/hostapd -f $APLOG $CONF
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  # 停掉 Debian 的 sysv hostapd，避免两个进程抢 wlan0
  systemctl disable --now hostapd.service >/dev/null 2>&1 || true
  systemctl mask hostapd.service >/dev/null 2>&1 || true
  sed -i '/^DAEMON_CONF=/d' /etc/default/hostapd 2>/dev/null || true
  systemctl enable ${UNIT}.service >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- 生成配置
# gen_conf <2g|5g> <channel> <1=VHT80|0=HT>
gen_conf() {
  local band=$1 ch=$2 ac=$3 hw ht vht=""
  if [[ "$band" == 5g ]]; then hw=a; else hw=g; fi
  if [[ "$band" == 5g && "$ac" == 1 ]]; then
    ht='[SHORT-GI-20][SHORT-GI-40][HT40+]'
    vht="ieee80211ac=1
# 不指定 vht_capab：让 hostapd 用驱动上报的 VHT 能力
# （显式写 [RX-STBC-1] 会被驱动拒绝：Configured VHT capability exceeds max value supported）
vht_oper_chwidth=1
vht_oper_centr_freq_seg0_idx=$((ch + 6))"
  elif [[ "$band" == 5g ]]; then
    ht='[SHORT-GI-20][SHORT-GI-40][HT40+]'
  else
    ht='[SHORT-GI-20][SHORT-GI-40][HT40+]'
  fi

  mkdir -p /etc/hostapd
  cat > "$CONF" <<EOF
# generated by wifi-ap/01-ap-bridge.sh  $(date '+%F %T')
interface=$WIFI
bridge=$BR
driver=nl80211
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0

ssid=$SSID
hw_mode=$hw
channel=$ch
country_code=CN
ieee80211d=1
max_num_sta=$MAXSTA

ap_isolate=0

wmm_enabled=1
uapsd_advertisement_enabled=0
dtim_period=1
beacon_int=100
ieee80211n=1
ht_capab=$ht
$vht

auth_algs=1
wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
  chmod 600 "$CONF"
}

# ---------------------------------------------------------------- 尝试启动
free_wifi() {
  ip link set "$WIFI" down 2>/dev/null || true
  if command -v rfkill >/dev/null; then rfkill unblock wifi 2>/dev/null || true; fi
  if pgrep -f "wpa_supplicant.*$WIFI" >/dev/null 2>&1; then
    warn "wpa_supplicant 仍占用 $WIFI，停掉它"
    pkill -f "wpa_supplicant.*$WIFI" 2>/dev/null || true
    sleep 1
  fi
}

try_start() {                 # 起 hostapd 并等 wlan0 变成 AP 模式
  systemctl stop ${UNIT} hostapd >/dev/null 2>&1 || true
  free_wifi
  : > "$APLOG"
  systemctl start ${UNIT} >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 20); do
    if iw dev "$WIFI" info 2>/dev/null | grep -q 'type AP'; then return 0; fi
    sleep 0.5
  done
  return 1
}

dump_ap_log() {
  echo "---------- hostapd 日志（$APLOG）----------"
  tail -30 "$APLOG" 2>/dev/null || echo "(空)"
  echo "---------- 前台再跑一次 ----------"
  systemctl stop ${UNIT} hostapd >/dev/null 2>&1 || true
  free_wifi
  timeout 6 /usr/sbin/hostapd -dd "$CONF" 2>&1 | tail -25 || true
  echo "-----------------------------------------"
}

# ---------------------------------------------------------------- 回滚
ORIG_ETH=$(nmcli -t -f NAME,DEVICE con show --active | awk -F: -v d="$UPLINK" '$2==d{print $1; exit}')
ORIG_ETH=${ORIG_ETH:-}
[[ -n "$ORIG_ETH" ]] || { warn "找不到 $UPLINK 在用的 NetworkManager 连接"; exit 1; }
log "原以太网连接: [$ORIG_ETH]"

revert() {
  trap - ERR EXIT
  REVERTED=1
  log "回滚到原始网络状态…"
  systemctl stop ${UNIT} 2>/dev/null || true
  systemctl stop hostapd 2>/dev/null || true
  sed -i '/^DAEMON_CONF=/d' /etc/default/hostapd 2>/dev/null || true
  ip link set "$WIFI" down 2>/dev/null || true
  nmcli con down "$BR" 2>/dev/null || true
  nmcli con delete "$BR" 2>/dev/null || true
  nmcli con delete "${BR}-port-${UPLINK}" 2>/dev/null || true
  nmcli con mod "$ORIG_ETH" connection.autoconnect yes 2>/dev/null || true
  nmcli con up  "$ORIG_ETH" 2>/dev/null || true
  for i in $(seq 1 20); do
    [[ -n "$(ip -4 -o addr show "$UPLINK" 2>/dev/null | awk '{print $4}')" ]] && break
    sleep 1
  done
  [[ -n "$(ip -4 -o addr show "$UPLINK" 2>/dev/null | awk '{print $4}')" ]] \
    || nmcli device connect "$UPLINK" 2>/dev/null || true
  nmcli device set "$WIFI" managed yes 2>/dev/null || true
  # 把 macvlan 改回 eth0
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local n parent cfg sub gw eps ep c ip
    while read -r n; do
      [[ -n "$n" ]] || continue
      parent=$(docker network inspect "$n" --format '{{index .Options "parent"}}' 2>/dev/null || true)
      [[ "$parent" == "$BR" ]] || continue
      cfg=$(docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}}|{{.Gateway}}{{end}}' 2>/dev/null)
      sub=${cfg%%|*}; gw=${cfg##*|}
      eps=$(docker network inspect "$n" --format '{{range .Containers}}{{.Name}}={{.IPv4Address}};{{end}}' 2>/dev/null)
      for ep in ${eps//;/ }; do
        [[ -n "$ep" ]] || continue
        docker network disconnect -f "$n" "${ep%%=*}" >/dev/null 2>&1 || true
      done
      docker network rm "$n" >/dev/null 2>&1 || true
      docker network create -d macvlan --subnet="$sub" --gateway="$gw" -o parent="$UPLINK" "$n" >/dev/null 2>&1 || true
      for ep in ${eps//;/ }; do
        [[ -n "$ep" ]] || continue
        c=${ep%%=*}; ip=${ep#*=}; ip=${ip%%/*}
        [[ -n "$ip" ]] && docker network connect --ip "$ip" "$n" "$c" >/dev/null 2>&1 || true
      done
      log "macvlan [$n] 已改回 $UPLINK"
    done < <(docker network ls --format '{{.Name}}' --filter driver=macvlan 2>/dev/null)
  fi
  log "回滚完成，IP: $(ip -4 -o addr show $UPLINK 2>/dev/null | awk '{print $4}')"
}
trap 'warn "出错，执行回滚"; revert; exit 1' ERR
DONE=0; REVERTED=0
trap 'if [[ $REVERTED -eq 0 && $DONE -eq 0 ]]; then warn "流程被中断，自动回滚"; revert; fi' EXIT

# ---------- 1 ----------
log "1/6 释放 wlan0 给 hostapd"
nmcli device set "$WIFI" managed no
free_wifi

# ---------- 2 ----------
log "2/6 创建桥 $BR 并把 $UPLINK 挂上去"
collect_macvlans
release_macvlans

nmcli con mod "$ORIG_ETH" connection.autoconnect no

for c in "$BR" "${BR}-port-${UPLINK}"; do
  if nmcli -t -f NAME con show | grep -qx "$c"; then
    log "清理残留连接: $c"
    nmcli con down "$c" >/dev/null 2>&1 || true
    nmcli con delete "$c" >/dev/null 2>&1 || true
  fi
done

nmcli con add type bridge ifname "$BR" con-name "$BR" \
      ipv4.method auto ipv6.method ignore bridge.stp no
nmcli con add type bridge-slave ifname "$UPLINK" con-name "${BR}-port-${UPLINK}" master "$BR"

log "激活从端口 ${BR}-port-${UPLINK}"
nmcli con up "${BR}-port-${UPLINK}" >/dev/null 2>&1 || true
log "激活桥 $BR"
nmcli con up "$BR" >/dev/null 2>&1 || true

log "等待 $BR 拿到 IPv4（最多 45s，中途重试一次）…"
for i in $(seq 1 45); do
  [[ -n "$(ip -4 -o addr show "$BR" 2>/dev/null | awk '{print $4}')" ]] && break
  [[ $i -eq 20 ]] && { nmcli con up "$BR" >/dev/null 2>&1 || true; }
  sleep 1
done
BR_IP=$(ip -4 -o addr show "$BR" 2>/dev/null | awk '{print $4}')
if [[ -z "$BR_IP" ]]; then
  warn "$BR 未拿到 IP"
  diag_bridge
  false
fi
log "    $BR 地址: $BR_IP"

restore_macvlans

# ---------- 3 ----------
log "3/6 安装 ${UNIT}.service 并准备 hostapd 配置"
install_unit

# ---------- 4：带降级阶梯的启动 ----------
log "4/6 启动 hostapd"
COMBOS=()
if [[ "$BAND" == 5g ]]; then
  COMBOS+=("5g:${CH:-149}:1" "5g:${CH:-149}:0" "5g:36:0")
else
  COMBOS+=("2g:${CH:-6}:0")
fi
COMBOS+=("2g:6:0")     # 最后兜底：2.4G ch6 HT

OK=0; USED=""
for combo in "${COMBOS[@]}"; do
  IFS=':' read -r b c a <<<"$combo"
  log "尝试 AP 参数: band=$b channel=$c vht=$a"
  gen_conf "$b" "$c" "$a"
  if try_start; then OK=1; USED="$combo"; break; fi
  warn "参数 $combo 起不来"
  tail -6 "$APLOG" 2>/dev/null | sed 's/^/    /'
done

if [[ $OK -ne 1 ]]; then
  warn "所有参数组合都失败"
  dump_ap_log
  false
fi
IFS=':' read -r HW_BAND CH_USE _ <<<"$USED"
[[ "$HW_BAND" == 5g ]] && HW=a || HW=g
log "AP 已启动：band=$HW_BAND channel=$CH_USE"

# ---------- 5 ----------
log "5/6 自检"
APINFO=$(iw dev "$WIFI" info 2>/dev/null || true)
[[ "$APINFO" == *"type AP"* ]] || { warn "wlan0 不是 AP 模式"; dump_ap_log; false; }
BRINFO=$(brctl show "$BR" 2>/dev/null || true)
[[ "$BRINFO" == *"$WIFI"* ]] || { warn "$WIFI 没进 $BR"; false; }
ok=0
GW=${GW:-$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')}
if [[ -z "$GW" ]]; then
  warn "拿不到默认网关，跳过网关连通性自检"
else
  for i in $(seq 1 10); do ping -c1 -W2 "$GW" >/dev/null 2>&1 && { ok=1; break; }; sleep 1; done
  [[ $ok -eq 1 ]] || { warn "桥接后 ping 不到网关 $GW"; false; }
fi

# ---------- 6 ----------
log "6/6 完成 ✅"
QR="WIFI:T:WPA;S:${SSID};P:${PASS};;"
printf '\n\033[1;36m══════════════ WiFi 关键信息（请记下/截图）══════════════\033[0m\n'
printf '  SSID      : \033[1;32m%s\033[0m\n' "$SSID"
printf '  密码      : \033[1;32m%s\033[0m\n' "$PASS"
printf '  加密      : WPA2-PSK / CCMP\n'
printf '  频段/信道 : %s / %s\n' "$([ "$HW" = a ] && echo 5GHz || echo 2.4GHz)" "$CH_USE"
printf '  桥接      : %s = %s + %s   (%s)\n' "$BR" "$UPLINK" "$WIFI" "$BR_IP"
printf '  客户端 IP : 由主路由 DHCP 分配，与本机同网段\n'
printf '  配置文件  : %s  (权限 600)\n' "$CONF"
printf '  AP 服务   : %s.service\n' "$UNIT"
printf '\033[1;36m═══════════════════════════════════════════════════════\033[0m\n'
print_wifi_qr "$QR"
echo "  改 SSID/密码: sudo bash $(dirname "$0")/00-prepare.sh set-wifi --ssid 新名 --pass 新密码"
echo "  随时查看    : sudo bash $(dirname "$0")/00-prepare.sh show"
echo
if [[ ! -f /etc/NetworkManager/conf.d/99-unmanaged-wlan0.conf ]]; then
  printf '\033[1;33m[!]\033[0m 还差「重启后自动生效」，请紧接着执行：\n'
  echo "      sudo bash $(dirname "$0")/00-prepare.sh setup"
  echo
fi
echo "  局域网互访（本机内转发，不经过主路由的任何 AP）自测："
echo "    两台设备都连上后执行： sudo bash $(dirname "$0")/01-verify-intrabss.sh <A的IP> <B的IP>"
echo "  回滚: sudo bash $(dirname "$0")/99-revert.sh"
DONE=1
trap - ERR EXIT
