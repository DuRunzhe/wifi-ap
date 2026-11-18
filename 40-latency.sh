#!/usr/bin/env bash
# WiFi 延时体检：测「无线一跳」延时/抖动/丢包，并与有线/外网基线对比
#
# 用法：
#   sudo bash 40-latency.sh              # 用已知 IP 的 WiFi 客户端测
#   sudo bash 40-latency.sh --sweep      # 先扫一遍同网段（会干扰测量，仅首次建档用）
#   sudo bash 40-latency.sh --ping <客户端A> <客户端B>
#
# 说明：本机是 AP 本身，"本机 → 客户端"= 一个无线跳；
#       "客户端 → 客户端" = 两个无线跳，延时约等于这里数字的 1.5~2 倍。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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
INET=${INET:-223.5.5.5}
SWEEP=0
IPS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sweep) SWEEP=1; shift ;;
    --ping)  shift; while [[ $# -gt 0 && "$1" != --* ]]; do IPS+=("$1"); shift; done ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 [--sweep] [--ping IP...]"; exit 1; }

log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

port_no(){ cat /sys/class/net/${BR}/brif/${WIFI}/port_no 2>/dev/null; }
wifi_macs(){
  local pn dec
  pn=$(port_no); [[ -n "$pn" ]] || return 0
  dec=$((pn))
  brctl showmacs "$BR" 2>/dev/null | awk -v p="$dec" -v s="$(cat /sys/class/net/$WIFI/address)" \
      -v b="$(cat /sys/class/net/$BR/address)" 'NR>1 && $1==p && $2!=s && $2!=b && $3=="no"{print $2}'
}

stat_line(){ awk '/^ *wlan0:/{printf "  rx: %s pkts / %s errs / %s drop   tx: %s pkts / %s errs / %s drop\n", $3,$4,$5,$11,$12,$13}' /proc/net/dev; }

echo "===== 0. 环境 ====="
ip -4 -o addr show "$BR" 2>/dev/null | awk '{print "  "$BR": "$4}'
echo "  SSID/模式: $(iw dev "$WIFI" info 2>/dev/null | awk '/ssid/{s=$2}/type/{t=$2}END{print s" / "t}')"
echo "  上传口 $UPLINK: $(cat /sys/class/net/$UPLINK/operstate 2>/dev/null || echo 未知) / $(cat /sys/class/net/$UPLINK/speed 2>/dev/null || echo '?')Mbps"
echo "  已连 WiFi 客户端: $(wifi_macs | wc -l)"
echo "  无线计数（测前）:"; stat_line

# ---------- 收集客户端 IP ----------
if [[ ${#IPS[@]} -eq 0 ]]; then
  if [[ $SWEEP -eq 1 ]]; then
    log "扫描同网段补全 IP↔MAC（会短暂干扰测量）"
    base=$(ip -4 -o addr show "$BR" 2>/dev/null | awk 'NR==1{split($4,a,"/"); split(a[1],o,"."); print o[1]"."o[2]"."o[3]}')
    for i in $(seq 2 254); do ping -c1 -W1 "$base.$i" >/dev/null 2>&1 & done; wait
    sleep 2
  fi
  for m in $(wifi_macs); do
    ip=$(ip neigh show dev "$BR" | awk -v m="$m" '$3==m{print $1; exit}')
    [[ -n "$ip" ]] && IPS+=("$ip")
  done
fi

# ---------- 统计函数 ----------
pingsum(){   # $1=ip $2=count $3=interval $4=size
  local out
  out=$(ping -c "$2" -i "$3" -s "${4:-56}" -W 2 "$1" 2>/dev/null | tail -2)
  local loss rtt_min rtt_avg rtt_max rtt_mdev
  loss=$(echo "$out" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
  read -r rtt_min rtt_avg rtt_max rtt_mdev < <(echo "$out" | sed -n 's#.*= \([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\).*#\1 \2 \3 \4#p')
  printf '%-16s %6s %8s %8s %8s %8s %7s\n' "$1" "${loss:-100}" "${rtt_min:--}" "${rtt_avg:--}" "${rtt_max:--}" "${rtt_mdev:--}" "$2"
}

hdr(){ printf '%-16s %6s %8s %8s %8s %8s %7s\n' "目标" "丢包%" "min" "avg" "max" "抖动" "包数"; }

echo
echo "===== 1. 有线 / 外网基线 ====="
hdr
pingsum "$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')" 10 1 56 || true
pingsum "$INET" 10 0.5 56 || true

echo
echo "===== 2. 无线一跳（本机 AP → 客户端）====="
if [[ ${#IPS[@]} -eq 0 ]]; then
  echo "  没有已知的 WiFi 客户端 IP；用 --sweep 先扫一遍，或 --ping 指定"
else
  hdr
  for ip in "${IPS[@]}"; do
    printf '  -- 密集 0.2s × 40（客户端被唤醒后的真实延时）\n'
    pingsum "$ip" 40 0.2 56
    printf '  -- 稀疏 1s × 15（体现省电唤醒抖动）\n'
    pingsum "$ip" 15 1 56
    printf '  -- 大包 1400B × 10\n'
    pingsum "$ip" 10 0.5 1400
  done
fi

echo
echo "===== 3. 无线计数（测后，看有没有重传/丢弃）====="
stat_line
journalctl -u hostapd-br0 -b --no-pager 2>/dev/null | tail -5 | sed 's/^/  /'

cat <<'EOF'

===== 怎么看 =====
  无线一跳    avg < 10ms、抖动 < 5ms、丢包 0        → 很好
              avg 10~25ms 或抖动 5~15ms           → 一般（省电/空口竞争）
              avg > 25ms 或丢包 > 1%              → 偏差，需要处理
  客户端↔客户端 约等于上面数值的 1.5~2 倍（两个无线跳）

  常见改善手段：
   1) 走 5GHz（2.4G 干扰多，抖动明显更大）：sudo bash run-ap-setup.sh SSID 密码 5g 149
   2) 调宽带宽/换干净信道：CH=36 / 44 / 149 都试一遍，看哪个 avg/抖动最低
   3) 手机侧关掉「Wi-Fi 省电 / 智能省电 / 自动切换移动数据」
   4) 让手机别用随机 MAC（部分机型随机 MAC 会反复重连，日志里能看到 disassociated）
   5) 有线侧广播太多会占空口：本机 tx_packets 远大于 rx 就是被泛洪了
EOF
