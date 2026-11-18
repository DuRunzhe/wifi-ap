#!/usr/bin/env bash
#=============================================================
# 43-ssid-visibility.sh — 「手机/电脑搜不到 SSID」排查阶梯
#
# 为什么需要这个脚本：
#   AP 显示 state=ENABLED、桥也正常，但客户端就是扫不到，原因通常只有四类：
#     ① 5.8G（ch149~165）兼容性 —— 部分手机（尤其国行）扫不到 UNII-3；
#     ② 带宽/HT 能力 —— 2.4G 的 HT40+ 在个别驱动/固件组合下不出 SSID；
#     ③ 射频/天线 —— IPEX 天线没扣、接触不良，发射弱到只能在 10~20cm 内收到；
#     ④ 驱动限制 —— sprdwl_ng(Unisoc UWE5622) 不实现部分 nl80211 接口
#        （`iw dev wlan0 station dump`、`set txpower` 都会失败，这是正常的）。
#
# 本脚本按「代价从低到高」逐项验证，并给出可执行的下一步，不写死任何板型。
#
# 用法：
#   sudo bash 43-ssid-visibility.sh                 # 只诊断（会临时停 AP 扫描几秒）
#   sudo bash 43-ssid-visibility.sh --keep-ap       # 诊断但不扫描（AP 最稳）
#   sudo bash 43-ssid-visibility.sh --switch 2g     # 切 2.4G ch6 / HT20（最兼容）
#   sudo bash 43-ssid-visibility.sh --switch 2g 11  # 切 2.4G ch11
#   sudo bash 43-ssid-visibility.sh --switch 5g     # 切 5G ch149 / VHT80
#   sudo bash 43-ssid-visibility.sh --switch 5g 153 40
#=============================================================
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BR=${BR:-br0}
WIFI=${WIFI:-wlan0}
UNIT=${UNIT:-hostapd-br0}
CONF=${CONF:-/etc/hostapd/hostapd-${BR}.conf}

ACTION=diagnose; KEEP_AP=0; SW_BAND=""; SW_CH=""; SW_W=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-ap) KEEP_AP=1; shift ;;
    --switch)  ACTION=switch; SW_BAND=${2:-2g}; shift 2
               [[ -n "${1:-}" && "$1" != --* ]] && { SW_CH="$1"; shift; }
               [[ -n "${1:-}" && "$1" != --* ]] && { SW_W="$1";  shift; } ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "未知参数: $1（--help 看用法）" >&2; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }

hr(){ printf '%.0s─' {1..64}; echo; }
sec(){ echo; hr; echo "  $*"; hr; }
ok(){ printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad(){ printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
info(){ printf '  %-30s %s\n' "$1" "$2"; }
st(){ hostapd_cli -i "$WIFI" status 2>/dev/null; }
sv(){ echo "$(st)" | sed -n "s/^$1=//p" | head -1; }
# hostapd 的 ssid/bssid 是带下标的（ssid[0]=...），单独取
sv_idx(){ echo "$(st)" | sed -n "s/^$1\[0\]=//p" | head -1; }

# ---------------------------------------------------------------- 切换频段
apply() {
  local band=$1 ch=$2 w=$3 orig
  orig=$(mktemp); cp -a "$CONF" "$orig"
  local pass ssid
  ssid=$(sed -n 's/^ssid=//p' "$CONF" | head -1)
  pass=$(sed -n 's/^wpa_passphrase=//p' "$CONF" | head -1)
  [[ -n "$ssid" && -n "$pass" ]] || { bad "读不到 $CONF 里的 ssid/wpa_passphrase"; exit 1; }

  {
    echo "# 由 wifi-ap/43-ssid-visibility.sh 生成 $(date '+%F %T')"
    echo "interface=$WIFI"
    echo "bridge=$BR"
    echo "driver=nl80211"
    echo "ctrl_interface=/var/run/hostapd"
    echo "ctrl_interface_group=0"
    echo
    echo "ssid=$ssid"
    if [[ "$band" == 2g ]]; then
      echo "hw_mode=g"; echo "channel=$ch"
      echo "ieee80211d=0"; echo "ieee80211n=1"
      # 2.4G 默认 HT20：兼容性优先
      if [[ "$w" == 40 ]]; then echo "ht_capab=[SHORT-GI-20][SHORT-GI-40][HT40+]"
      else echo "ht_capab=[SHORT-GI-20]"; fi
    else
      echo "hw_mode=a"; echo "channel=$ch"
      echo "ieee80211d=0"; echo "ieee80211n=1"
      if [[ "$w" == 80 ]]; then
        echo "ht_capab=[SHORT-GI-20][SHORT-GI-40][HT40+]"
        echo "ieee80211ac=1"; echo "vht_oper_chwidth=1"
        echo "vht_oper_centr_freq_seg0_idx=$((ch + 6))"
      elif [[ "$w" == 40 ]]; then
        echo "ht_capab=[SHORT-GI-20][SHORT-GI-40][HT40+]"
      else
        # 20MHz：不要声明 HT40 能力，否则 hostapd 仍会按 40MHz 起
        echo "ht_capab=[SHORT-GI-20]"
      fi
    fi
    echo
    echo "country_code=CN"
    echo "max_num_sta=16"
    echo "ap_isolate=0"
    echo "wmm_enabled=1"
    echo "uapsd_advertisement_enabled=0"
    echo "dtim_period=1"
    echo "beacon_int=100"
    echo "auth_algs=1"
    echo "wpa=2"
    echo "wpa_passphrase=$pass"
    echo "wpa_keymgmt=WPA-PSK"
    echo "wpa_key_mgmt=WPA-PSK"
    echo "rsn_pairwise=CCMP"
  } > "$CONF"
  sed -i '/^wpa_keymgmt=/d' "$CONF"
  chmod 600 "$CONF"

  echo "  切换: band=$band ch=$ch ${w:+width=$w}"
  systemctl restart "$UNIT" >/dev/null 2>&1
  local i
  for i in $(seq 1 25); do [[ -n "$(sv state)" ]] && break; sleep 1; done
  if [[ "$(sv state)" == ENABLED ]]; then
    ok "已生效: state=ENABLED freq=$(sv freq) channel=$(sv channel)"
    echo "     SSID=$ssid  密码见 $CONF"
  else
    bad "切换失败，回滚"
    cp -a "$orig" "$CONF"; systemctl restart "$UNIT" >/dev/null 2>&1; sleep 6
    echo "     回滚后: state=$(sv state)"
    return 1
  fi
}

# ---------------------------------------------------------------- 诊断
diagnose() {
  sec "1. 当前 AP 状态"
  if ! systemctl is-active --quiet "$UNIT"; then
    bad "$UNIT 没在运行：sudo systemctl start $UNIT"
    return 1
  fi
  info "state"     "$(sv state)"
  info "ssid"      "$(sv_idx ssid)"
  info "bssid"     "$(sv_idx bssid)"
  info "freq/ch"   "$(sv freq) / ch$(sv channel)"
  info "hw_mode"   "$(sv hw_mode)   （a=5G  g=2.4G）"
  info "带宽线索"  "ieee80211n=$(sv ieee80211n) ieee80211ac=$(sv ieee80211ac) secondary_channel=$(sv secondary_channel)"
  info "max_txpower" "$(sv max_txpower)"
  info "已连客户端" "$(hostapd_cli -i "$WIFI" all_sta 2>/dev/null | grep -c AUTHORIZED)"

  sec "2. 接口 / 桥 / rfkill"
  ip -br link show "$WIFI" 2>/dev/null | sed 's/^/  /'
  iw dev "$WIFI" info 2>/dev/null | sed -n 's/^/  /p' | sed 's/^  \t/    /'
  local brif; brif=$(ls /sys/class/net/$BR/brif 2>/dev/null | tr '\n' ' ')
  info "$BR 成员" "${brif:-无}"
  [[ "$brif" == *"$WIFI"* ]] || bad "$WIFI 不在桥里：sudo systemctl restart $UNIT"
  rfkill list 2>/dev/null | grep -A2 -i wireless | sed 's/^/  /'

  sec "3. 射频线索（不必全绿，但要会读）"
  info "rx_packets" "$(cat /sys/class/net/$WIFI/statistics/rx_packets 2>/dev/null)"
  info "tx_packets" "$(cat /sys/class/net/$WIFI/statistics/tx_packets 2>/dev/null)"
  echo "  说明："
  echo "    · tx_packets 空载增速因芯片而异（Zero2≈10/s，Zero3≈1/s），不是故障"
  echo "    · 驱动若不实现 station dump / set txpower，会报 Operation not supported，正常"
  echo "    · rx_packets 长期为 0 + 扫描 0 个 BSS → 优先怀疑天线（IPEX 是否扣好）"

  if [[ $KEEP_AP -eq 0 ]]; then
    sec "4. 扫描周边 BSS（临时停 AP 约 5 秒）"
    systemctl stop "$UNIT" >/dev/null 2>&1
    ip link set "$WIFI" up 2>/dev/null
    local scan_out n
    scan_out=$(timeout 25 iw dev "$WIFI" scan 2>&1)
    n=$(echo "$scan_out" | grep -c '^BSS')
    # 扫描完立刻把 AP 拉回来
    ip link set "$WIFI" master "$BR" 2>/dev/null
    systemctl start "$UNIT" >/dev/null 2>&1
    sleep 4
    info "扫到 BSS 数" "$n"
    if [[ $n -eq 0 ]]; then
      bad "一个都扫不到 → 接收链路基本是聋的"
      echo "      → 检查 IPEX 天线是否扣在板上 WiFi 座上（这是最常见原因）"
      echo "      → 换个位置/贴近路由器再试；仍为 0 则基本可判定射频/天线问题"
    else
      ok "接收正常（扫到 $n 个），问题在发射侧或客户端侧"
      echo "$scan_out" | grep -E '^(BSS|SSID)' | head -20 | sed 's/^/     /'
    fi
    info "AP 已恢复" "$(sv state)"
  else
    sec "4. 扫描：已跳过（--keep-ap）"
  fi

  sec "5. 结论与建议（按顺序试）"
  local ch; ch=$(sv channel)
  if [[ "$ch" -ge 149 ]] 2>/dev/null; then
    echo "  ① 当前在 5.8G（ch$ch = UNII-3）：部分手机/国行设备扫不到这个频段"
    echo "     先切 2.4G 验证：  sudo bash $0 --switch 2g"
  else
    echo "  ① 当前在 2.4G ch$ch：兼容性最好，若仍搜不到见 ③"
  fi
  echo "  ①.5 「时有时无」→ 先查固件省电：sudo bash 44-firmware-powersave.sh check"
  echo "  ② 2.4G 仍然不行 → 降带宽：  sudo bash $0 --switch 2g 6 20"
  echo "  ③ 两个频段都搜不到 → 几乎确定是天线/射频：检查 IPEX 天线、换天线、贴近 10cm 试"
  echo "  ④ 客户端能连但上不了网 → 看桥转发：sudo bash 01-verify-intrabss.sh"
}

case "$ACTION" in
  switch)
    case "$SW_BAND" in
      2g|2.4g) apply 2g "${SW_CH:-6}"  "${SW_W:-20}" ;;
      5g)       apply 5g "${SW_CH:-149}" "${SW_W:-80}" ;;
      *) echo "--switch 只接受 2g / 5g" >&2; exit 1 ;;
    esac
    ;;
  diagnose) diagnose ;;
esac
