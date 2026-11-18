#!/usr/bin/env bash
# 一键回滚：拆掉 AP / 桥 / 固定地址 / 专用服务，恢复成原来的 NetworkManager 有线连接
# 用法: sudo bash 99-revert.sh
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

[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0"; exit 1; }
log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }

log "停止并清理 AP 服务"
systemctl disable --now hostapd-br0 2>/dev/null
systemctl disable --now hostapd      2>/dev/null
systemctl unmask hostapd 2>/dev/null
systemctl disable --now fixed-ip     2>/dev/null
rm -f /etc/systemd/system/hostapd-br0.service \
      /etc/systemd/system/fixed-ip.service
sed -i '/^DAEMON_CONF=/d' /etc/default/hostapd 2>/dev/null
systemctl daemon-reload

log "恢复 NM 对 $WIFI 的管理"
rm -f /etc/NetworkManager/conf.d/99-unmanaged-wlan0.conf
systemctl reload NetworkManager 2>/dev/null

log "重置 $WIFI"
ip link set "$WIFI" down 2>/dev/null
nmcli device set "$WIFI" managed yes 2>/dev/null

log "拆桥 $BR"
nmcli con down "$BR" 2>/dev/null
nmcli con delete "$BR" 2>/dev/null
nmcli con delete "${BR}-port-${UPLINK}" 2>/dev/null

log "恢复 $UPLINK 的原有连接"
ORIG=$(nmcli -t -f NAME,DEVICE,TYPE con show | awk -F: -v d="$UPLINK" '$2==d && $3=="802-3-ethernet"{print $1; exit}')
if [[ -z "${ORIG:-}" ]]; then
  ORIG=$(nmcli -t -f NAME con show | head -1)
fi
nmcli con mod "$ORIG" connection.autoconnect yes 2>/dev/null
nmcli con up "$ORIG" 2>/dev/null
sleep 3
log "完成。当前 IP:"
ip -4 -o addr show "$UPLINK" 2>/dev/null | awk '{print "  "$2" "$4}'

# 把建桥时改挂到 br0 上的 macvlan 网络改回 eth0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  while read -r n; do
    [[ -n "$n" ]] || continue
    parent=$(docker network inspect "$n" --format '{{index .Options "parent"}}' 2>/dev/null || true)
    [[ "$parent" == "$BR" ]] || continue
    cfg=$(docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}}|{{.Gateway}}{{end}}' 2>/dev/null)
    sub=${cfg%%|*}; gw=${cfg##*|}
    conns=()
    while IFS='=' read -r c ip; do
      [[ -n "$c" ]] || continue
      conns+=("$c|${ip%%/*}")
    done < <(docker network inspect "$n" --format '{{range .Containers}}{{.Name}}={{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null)
    log "macvlan [$n] 改回 parent=$UPLINK"
    for e in "${conns[@]:-}"; do
      [[ -n "$e" ]] && docker network disconnect -f "$n" "${e%%|*}" >/dev/null 2>&1 || true
    done
    docker network rm "$n" >/dev/null 2>&1 || true
    if docker network create -d macvlan --subnet="$sub" --gateway="$gw" -o parent="$UPLINK" "$n" >/dev/null 2>&1; then
      for e in "${conns[@]:-}"; do
        [[ -n "$e" ]] || continue
        c=${e%%|*}; ip=${e##*|}
        if [[ -n "$ip" && "$ip" != "$c" ]]; then
          docker network connect --ip "$ip" "$n" "$c" >/dev/null 2>&1 || true
        else
          docker network connect "$n" "$c" >/dev/null 2>&1 || true
        fi
      done
    else
      log "重建 macvlan [$n] 失败，手动： docker network create -d macvlan --subnet=$sub --gateway=$gw -o parent=$UPLINK $n"
    fi
  done < <(docker network ls --format '{{.Name}}' --filter driver=macvlan 2>/dev/null)
fi

echo
echo "进阶1（代理）如已配置，可用: sudo bash $(dirname "$0")/10-proxy-gw.sh full-off"
