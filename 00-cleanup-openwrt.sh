#!/usr/bin/env bash
# 清理会阻塞桥接的 openwrt 容器 + macvlan 网络
#
# 为什么必须清：macvlan 会在底层设备（eth0）注册 rx_handler，
# 而 br_add_if() 里的 netdev_rx_handler_register() 遇到已占用会返回 -EBUSY，
# 于是 NetworkManager 报 "Device or resource busy / could not be enslaved"，
# br0 永远没有 carrier、拿不到 IP。
#
# 本脚本做的事（幂等，可反复跑）：
#   1) 可选 --backup：把容器提交成 openwrt:backup-<时间> 镜像（可写层才几 MB）
#   2) 停掉并删除 openwrt 容器（镜像保留，随时能用 docker run 重建）
#   3) 删除 parent=eth0 的 docker macvlan 网络
#   4) 校验：不再有 macvlan 残留
#
# 用法：
#   sudo bash 00-cleanup-openwrt.sh             # 直接清
#   sudo bash 00-cleanup-openwrt.sh --backup    # 先备份成镜像再清
#
# 之后要恢复 OpenWrt（进阶1 用，注意 parent 已改成 br0）：
#   docker run -d --name openwrt --network macnet --privileged --restart always \
#     sulinggg/openwrt:armv8 /sbin/init
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

C=openwrt
# 探测上行网卡：默认路由所在接口；若路由在桥上，则取该桥的第一个物理 port
_detect_uplink(){
  local d
  d=$(ip route show default 2>/dev/null | awk '{print $5}' | grep -vE '^(veth|docker|virbr|tun|tap|wg)' | head -1)
  if [[ ${d:-} == br* && -d /sys/class/net/$d/brif ]]; then
    ls /sys/class/net/$d/brif 2>/dev/null | grep -vE '^(veth|tap|tun|wg|wlan|p2p)' | head -1
  else
    printf '%s' "${d:-}"
  fi
}
PARENT=${PARENT:-$(_detect_uplink)}
[[ -n $PARENT ]] || { echo "无法自动探测上行网卡，请用 PARENT=<网卡名> 指定" >&2; exit 1; }
BR=${BR:-br0}
BACKUP=0
[[ "${1:-}" == "--backup" ]] && BACKUP=1

[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 [--backup]"; exit 1; }
log(){ printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

command -v docker >/dev/null || { warn "没有 docker"; exit 1; }
docker info >/dev/null 2>&1 || { warn "docker 守护进程不可用"; exit 1; }

# ---------- 0. 先看一眼现场 ----------
echo "===== 清理前 ====="
docker ps -a --filter "name=^${C}$" --format '  容器: {{.Names}}  {{.Status}}  image={{.Image}}' || true
docker network ls --filter driver=macvlan --format '  macvlan 网络: {{.Name}}' || true
ip -d link show type macvlan 2>/dev/null | grep -E '^[0-9]+:' | sed 's/^/  宿主 macvlan: /' || true
echo

# ---------- 1. 备份容器 ----------
if [[ $BACKUP -eq 1 ]] && docker inspect "$C" >/dev/null 2>&1; then
  TAG="${C}:backup-$(date +%Y%m%d-%H%M)"
  log "提交备份镜像 $TAG"
  docker commit "$C" "$TAG" >/dev/null && ok "已备份: $TAG" || warn "备份失败（继续）"
fi

# ---------- 2. 删容器 ----------
if docker inspect "$C" >/dev/null 2>&1; then
  log "停止并删除容器 $C"
  docker stop -t 10 "$C" >/dev/null 2>&1 || true
  docker rm -f "$C" >/dev/null 2>&1 && ok "容器已删除（镜像保留）" || warn "删除容器失败"
else
  ok "容器 $C 不存在，跳过"
fi

# ---------- 3. 删 parent=eth0 的 macvlan 网络 ----------
while read -r n; do
  [[ -n "$n" ]] || continue
  p=$(docker network inspect "$n" --format '{{index .Options "parent"}}' 2>/dev/null || true)
  if [[ "$p" != "$PARENT" && "$p" != "$BR" ]]; then
    warn "跳过 macvlan [$n]（parent=$p，不是 $PARENT/$BR）"
    continue
  fi
  log "删除 macvlan 网络 [$n]"
  for c in $(docker network inspect "$n" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
    docker network disconnect -f "$n" "$c" >/dev/null 2>&1 || true
  done
  docker network rm "$n" >/dev/null 2>&1 && ok "已删除 [$n]" || warn "删除 [$n] 失败"
done < <(docker network ls --format '{{.Name}}' --filter driver=macvlan 2>/dev/null)

# ---------- 4. 校验 ----------
echo
echo "===== 清理后 ====="
LEFT_NET=$(docker network ls --format '{{.Name}}' --filter driver=macvlan 2>/dev/null | wc -l)
LEFT_LNK=$(ip -d link show type macvlan 2>/dev/null | grep -cE '^[0-9]+:' || true)
printf '  docker macvlan 网络剩余: %s\n' "$LEFT_NET"
printf '  宿主 macvlan 接口剩余 : %s\n' "$LEFT_LNK"
printf '  %s 的 rx_handler 占用  : %s\n' "$PARENT" "$([[ $LEFT_LNK -eq 0 && $LEFT_NET -eq 0 ]] && echo '已释放 → 可以建桥' || echo '仍有占用')"
echo
echo "  保留的镜像（以后重建 openwrt 用）:"
docker images --format '    {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -i openwrt || echo "    (无)"
echo
echo "下一步："
echo "  sudo -E env SSID='PiLink' PASS='你的密码' bash $(dirname "$(readlink -f "$0")")/01-ap-bridge.sh"
