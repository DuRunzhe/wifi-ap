#!/usr/bin/env bash
# 验证「同一 AP 内两台设备互访，流量没有离开本机（不跨主路由）」
#
# 用法：
#   sudo bash 01-verify-intrabss.sh <设备A的IP> <设备B的IP> [监听秒数]
#   例: sudo bash 01-verify-intrabss.sh <手机A地址> <手机B地址> 20
#
# 原理：两设备互访的帧如果被桥正确转发，只会在 wlan0 与 br0 之间打转，
#       eth0 上抓不到它们之间的包；同时 iw 能看到两端都在本 AP 的关联表里。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

A=${1:?需要 A 的 IP}
B=${2:?需要 B 的 IP}
SECS=${3:-20}
BR=br0
WIFI=wlan0
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
UPLINK=${UPLINK:-$(_detect_uplink)}
if [[ -z $UPLINK ]]; then
  echo "无法自动探测上行网卡（默认路由缺失），请用 UPLINK=<网卡名> 显式指定" >&2
  exit 1
fi

[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 <A-IP> <B-IP> [秒]"; exit 1; }
log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

echo "===== 1. 关联状态 ====="
iw dev "$WIFI" info 2>/dev/null | sed -n '1,6p'
echo "--- 当前 WiFi 客户端（从桥转发表统计，本驱动不支持 station dump）---"
PN=$(cat /sys/class/net/${BR}/brif/${WIFI}/port_no 2>/dev/null)
if [[ -n "$PN" ]]; then
  DEC=$((PN)); SELF=$(cat /sys/class/net/${WIFI}/address); BRM=$(cat /sys/class/net/${BR}/address)
  brctl showmacs "$BR" 2>/dev/null \
    | awk -v p="$DEC" -v s="$SELF" -v b="$BRM" \
        'NR>1 && $1==p && $2!=s && $2!=b && $3=="no"{printf "    %s  age=%.1fs\n", $2, $4}'
else
  echo "    (拿不到 $BR 端口信息)"
fi
echo "--- 桥转发表（客户端 MAC 应挂在 $WIFI 上）---"
brctl showmacs "$BR" 2>/dev/null | head -20

echo
echo "===== 2. hostapd 关键配置确认 ====="
CFG=/etc/hostapd/hostapd-${BR}.conf
grep -E '^(ap_isolate|bridge|wmm_enabled|dtim_period|uapsd_advertisement_enabled)' "$CFG" 2>/dev/null \
  || echo "(读不到 $CFG)"

echo
echo "===== 3. 桥端口 hairpin 状态 ====="
bridge link show dev "$WIFI" 2>/dev/null || echo "(bridge 工具不可用)"

echo
log "4. 现在请在 A($A) 上执行:  ping -i 0.2 $B"
log "   本机同时抓 ${SECS}s：$UPLINK（期望 0 个 ICMP）与 $BR（期望很多，证明走了桥）"
if ! command -v tcpdump >/dev/null; then
  echo "(没有 tcpdump：sudo apt install -y tcpdump 后重跑)"
  echo "  手动验证: sudo tcpdump -i $UPLINK -n 'icmp and host $A and host $B'   然后从 A ping B"
exit 0
fi

TMP=$(mktemp -d)
timeout "$SECS" tcpdump -i "$UPLINK" -n "icmp and host $A and host $B" > "$TMP/eth.txt" 2>/dev/null &
P1=$!
timeout "$SECS" tcpdump -i "$BR"     -n "icmp and host $A and host $B" > "$TMP/br.txt"  2>/dev/null &
P2=$!
timeout "$SECS" tcpdump -i "$UPLINK" -n "arp and host $A and host $B" > "$TMP/arp.txt" 2>/dev/null &
P3=$!
wait $P1 $P2 $P3 2>/dev/null || true

ETH=$(grep -c 'ICMP echo' "$TMP/eth.txt" 2>/dev/null || true); ETH=${ETH:-0}
BRC=$(grep -c 'ICMP echo' "$TMP/br.txt"  2>/dev/null || true); BRC=${BRC:-0}
ARP=$(grep -c 'ARP'       "$TMP/arp.txt" 2>/dev/null || true); ARP=${ARP:-0}
rm -rf "$TMP"

echo
echo "  $BR  上看到的 A↔B ICMP 包 : $BRC"
echo "  $UPLINK 上看到的 A↔B ICMP 包 : $ETH"
echo "  $UPLINK 上看到的 A↔B ARP 广播 : $ARP   （ARP 泛洪属正常二层行为）"
echo
if [[ "$BRC" -eq 0 && "$ETH" -eq 0 ]]; then
  printf '\033[1;33m[!]\033[0m 两边都没抓到 ICMP —— A↔B 根本没通，或没在 A 上 ping\n'
  echo "  排查: brctl showmacs $BR  /  ping 是否真的在跑"
elif [[ "$ETH" -eq 0 ]]; then
  printf '\033[1;32m✅ 达标\033[0m：%s 个 ICMP 全在本机桥内转发，%s 上一个都没漏 → 没跨主路由\n' "$BRC" "$UPLINK"
elif [[ "$ETH" -lt $((BRC / 4)) ]]; then
  printf '\033[1;33m[~]\033[0m 少量绕行（%s/%s）；多为主机 ARP/重连/漫游抖动，可跟提“是否稳定”' "$ETH" "$BRC"
else
  printf '\033[1;31m✗ 不达标\033[0m：%s 个 ICMP 走了 %s（本机只看到 %s 个），流量确实经过主路由\n' "$ETH" "$UPLINK" "$BRC"
  echo "  排查："
  echo "   1) 两台设备都连到本 AP 了吗？  brctl showmacs $BR"
  echo "   2) 是否被主路由 AP 抢走（同 SSID 时会）→ 用独立 SSID 名"
  echo "   3) 同 AP 客户端互访绕行 → sudo bridge link set dev $WIFI hairpin on"
  echo "   4) 确认 ap_isolate=0 并已重启 hostapd"
fi

echo
log "5. 顺带看空口质量（A↔B 互 ping 时执行）"
echo "=== 客户端链路质量（station dump 仅部分驱动支持，空也正常）==="
iw dev "$WIFI" station dump 2>/dev/null | grep -E '^Station|signal:|bitrate' | head -20 || true
