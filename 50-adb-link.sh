#!/usr/bin/env bash
# ADB over WiFi 链路质量体检（针对 adb shell / install / scrcpy 这类交互与吞吐场景）
#
# 用法：
#   sudo bash 50-adb-link.sh --ip <手机地址>
#   sudo bash 50-adb-link.sh --ip <手机地址> --port 5555
#   sudo bash 50-adb-link.sh --ip <手机地址> --apk /path/app.apk   # 顺带测 install 用时
#
# 说明：本机是 AP。测「本机 → 手机」= 一个无线跳。
#       若你的 adb 主机是另一台有线 PC，路径 = 有线 + 一个无线跳；两台都在本 AP 上则只是两个无线跳。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BR=br0; WIFI=wlan0
IP=""; PORT=5555; APK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip) IP="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --apk) APK="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 --ip <手机IP> [--port 5555] [--apk x.apk]"; exit 1; }
[[ -n "$IP" ]] || { echo "缺少 --ip"; exit 1; }

log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
row(){ printf '  %-26s %-10s %-8s %-8s %-8s %-8s\n' "$@"; }

echo "===== 1. 拓扑前置条件（adb over WiFi 的硬要求）====="
echo -n "  ap_isolate              : "; grep -h '^ap_isolate=' /etc/hostapd/hostapd-${BR}.conf 2>/dev/null | cut -d= -f2 || echo "?"
MAC=$(ip neigh show dev "$BR" | awk -v ip="$IP" '$1==ip{print $3; exit}')
echo "  $IP 的 MAC              : ${MAC:-（邻居表里没有，先 ping 一下）}"
if [[ -n "$MAC" ]]; then
  PN=$(cat /sys/class/net/${BR}/brif/${WIFI}/port_no 2>/dev/null)
  if [[ -n "$PN" ]] && brctl showmacs "$BR" 2>/dev/null | awk -v p="$((PN))" -v m="$MAC" '$1==p && $2==m{found=1} END{exit !found}'; then
    echo "  该 MAC 是否挂在本 AP    : 是（走无线，符合预期）"
  else
    echo "  该 MAC 是否挂在本 AP    : 否（可能连的是主路由的 AP，或不在桥里）"
  fi
fi
echo -n "  两端是否同网段          : "; a=$(ip -4 -o addr show "$BR" | awk 'NR==1{split($4,x,"/"); split(x[1],o,"."); print o[1]"."o[2]"."o[3]}'); b=$(echo "$IP" | awk -F. '{print $1"."$2"."$3}'); [[ "$a" == "$b" ]] && echo "是（$a.0/24）" || echo "否（本机 $a.0/24，目标 $b.0/24）"

echo
echo "===== 2. 延时/抖动/丢包（ICMP 代理指标）====="
row "场景" "丢包%" "min" "avg" "max" "抖动"
sum(){ local out loss mn av mx md; out=$(ping -c "$2" -i "$3" -W2 "$IP" 2>/dev/null | tail -2)
  loss=$(echo "$out" | sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p')
  read -r mn av mx md < <(echo "$out" | sed -n 's#.*= \([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\)/\([0-9.]*\).*#\1 \2 \3 \4#p')
  printf '  %-26s %-10s %-8s %-8s %-8s %-8s\n' "$1" "${loss:-100}" "${mn:--}" "${av:--}" "${mx:--}" "${md:--}"; }
sum "密集 0.2s x100（adb 传输期）" 100 0.2
sum "稀疏 1s x30（adb 空闲期/省电）" 30 1

echo
echo "===== 3. MTU / 分片（影响 adb push/pull）====="
for sz in 1472 1400; do
  printf '  DF %-5s : ' "$sz"; ping -c2 -W2 -M 'do' -s "$sz" "$IP" >/dev/null 2>&1 && echo "通过" || echo "不通"
done
echo "  wlan0 MTU: $(cat /sys/class/net/$WIFI/mtu)   br0 MTU: $(cat /sys/class/net/$BR/mtu)"

echo
echo "===== 4. TCP 层（真实 adb 连接）====="
if ! command -v adb >/dev/null; then
  echo "  未安装 adb；如需实测：sudo apt install -y adb  然后重跑"
else
  adb connect "$IP:$PORT" >/dev/null 2>&1 || true
  sleep 1
  if adb devices | awk -v d="$IP:$PORT" '$1==d{found=1} END{exit !found}'; then
    echo "  adb 已连接: $IP:$PORT"
    T0=$(date +%s%N)
    for _ in $(seq 1 10); do adb -s "$IP:$PORT" shell true >/dev/null 2>&1; done
    T1=$(date +%s%N)
    awk -v a="$T0" -v b="$T1" 'BEGIN{printf "  adb shell true x10 : %.1f ms/次\n", (b-a)/1000000/10}'
    echo "  TCP 重传/分段（连接建立后）:"
    nstat -az 2>/dev/null | grep -E 'TcpRetransSegs|TcpOutSegs|TcpExtTCPLostRetransmit' | sed 's/^/    /'
    echo "  连接详情（RTT/拥塞窗口/重传）:"
    ss -tin 2>/dev/null | grep -A1 ":5555\|:$PORT" | head -6 | sed 's/^/    /'
    if [[ -n "$APK" && -f "$APK" ]]; then
      echo "  安装 $APK …"
      t0=$(date +%s%N)
      adb -s "$IP:$PORT" install -r "$APK" >/dev/null 2>&1 && ok=1 || ok=0
      t1=$(date +%s%N)
      awk -v a="$t0" -v b="$t1" -v s="$ok" 'BEGIN{printf "  adb install 用时  : %.1f s (%s)\n", (b-a)/1e9, (s?"成功":"失败")}'
    fi
  else
    echo "  adb 连接不上 $IP:$PORT —— 手机上需要开启「无线调试」/「USB调试(tcpip)」并同意授权"
  fi
fi

cat <<'EOF'

===== 判定（针对 adb）=====
  丢包        必须 0%      ← 有任何丢包，adb install/pull 会卡顿甚至失败
  avg 延时    < 15ms 良好  ← adb shell 输入感接近本地
  抖动 mdev   < 8ms  良好  ← 抖动大 => 逐键输入卡顿、scrcpy 花屏
  max         < 50ms 良好  ← 出现 100ms+ 尖刺 => 手机省电在反复挂起
  MTU 1472    通过         ← 否则大文件传输容易分片/重传

===== 针对性优化 =====
 1) 手机侧：关「Wi-Fi 省电/智能省电」、关「随机 MAC」、别锁屏（锁屏会挂起 adbd）
 2) 手机侧：把「无线调试」的电池优化设为无限制
 3) 保持连接活跃（消掉 100~150ms 尖刺）：
      ping -i 2 <手机IP> >/dev/null &     # 或 adb shell 里常驻 logcat
 4) 有 root 的手机可以直接关省电：
      adb shell "iw wlan0 set power_save off"
 5) adb 主机尽量有线接到同一交换机；若也在本 AP 上，则是两个无线跳，延时约 x2
 6) 走 5GHz（2.4G 抖动通常是 5G 的 2~3 倍）
EOF
