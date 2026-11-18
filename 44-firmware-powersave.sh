#!/usr/bin/env bash
#=============================================================
# 44-firmware-powersave.sh — 修复「AP 明明 ENABLED，客户端却时有时无 / 搜不到」
#
# 症状（实测）：
#   hostapd state=ENABLED、桥正常、内核无错误，但空载 wlan0 的 tx_packets
#   只有 ~0.4 包/s（正常 AP 的 beacon 是 10/s）。
#   手机每个信道只停留 ~100ms，撞上 beacon 的概率约 4% → 表现为「时有时无」。
#
# 根因：
#   sprdwl_ng（Unisoc UWE5622）固件默认开启 power save，进入省电后会把
#   beacon 发送频率压到极低。关掉固件的 power save 后 tx 立刻回到 100+/s。
#
# 修复分两层（都要做）：
#   ① 模块参数 disable_powersave=1 —— 运行期生效，但固件只在「下一次 power-down 请求」采纳
#   ② 固件 ini 的 power_save_switch = 0 —— 启动时读取，彻底阻止进入省电（需重启）
#   只用 ① 时，重启后仍可能复现（实测）
#
# 适用范围：
#   只对带 disable_powersave 参数的驱动有效（sprdwl_ng）。其它驱动会明确提示不适用。
#
# 用法：
#   sudo bash 44-firmware-powersave.sh check    # 只诊断（默认）
#   sudo bash 44-firmware-powersave.sh fix      # 关省电 + 持久化（modprobe.d + systemd）
#   sudo bash 44-firmware-powersave.sh revert   # 恢复默认（省电开）
#=============================================================
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WIFI=${WIFI:-wlan0}
MODULE=${MODULE:-sprdwl_ng}
PARAM=/sys/module/$MODULE/parameters/disable_powersave
MODCONF=/etc/modprobe.d/sprdwl_ng-no-powersave.conf
UNIT=wifi-no-powersave.service
INI_BAK=/root/wifi-ini-power-save.bak

find_ini(){          # 从 dmesg 抓实际加载的 ini，退回 glob
  local p
  p=$(dmesg 2>/dev/null | sed -n 's/.*wifi ini path = //p' | tail -1)
  [[ -n "$p" && -f "$p" ]] && { echo "$p"; return; }
  ls /lib/firmware/wifi_*.ini 2>/dev/null | head -1
}
ACTION=${1:-check}

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }
ok(){ printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad(){ printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
info(){ printf '  %-28s %s\n' "$1" "$2"; }

measure(){                          # 15 秒空载 tx 速率
  local a b
  a=$(cat "/sys/class/net/$WIFI/statistics/tx_packets" 2>/dev/null || echo 0)
  sleep 15
  b=$(cat "/sys/class/net/$WIFI/statistics/tx_packets" 2>/dev/null || echo 0)
  echo $(( (b - a) / 15 ))
}

check() {
  echo "== 驱动与参数"
  if [[ ! -e "$PARAM" ]]; then
    bad "当前模块没有 disable_powersave 参数（不是 sprdwl_ng 或内核版本不同）"
    echo "    本脚本不适用；请改看 43-ssid-visibility.sh 的排查阶梯"
    return 1
  fi
  ok "找到 $PARAM"
  info "当前值" "$(cat "$PARAM")  （1=已关固件省电）"

  echo "== 空载 beacon 速率（15s 采样）"
  local rate; rate=$(measure)
  info "tx_packets/s" "$rate"
  if [[ "$rate" -ge 8 ]]; then
    ok "beacon 速率正常（≥8/s），不是省电问题"
  elif [[ "$rate" -ge 3 ]]; then
    echo "  ⚠️  偏低（3~8/s）：可尝试 fix，但收益有限"
  else
    bad "极低（${rate}/s）→ 高度怀疑固件省电压制 beacon"
    echo "     修复：sudo bash $0 fix"
  fi

  echo "== 固件 ini（power_save_switch）"
  local ini; ini=$(find_ini)
  if [[ -n "$ini" ]]; then
    info "ini 文件" "$ini"
    info "power_save_switch" "$(sed -n 's/^power_save_switch *= *//p' "$ini" | head -1)（0=关省电，重启生效）"
  else
    info "ini 文件" "未找到（跳过）"
  fi

  echo "== 持久化状态"
  [[ -f "$MODCONF" ]] && info "modprobe.d" "已配置" || info "modprobe.d" "未配置"
  systemctl is-enabled "$UNIT" >/dev/null 2>&1 \
    && info "$UNIT" "enabled/$(systemctl is-active "$UNIT" 2>/dev/null)" \
    || info "$UNIT" "未启用"
}

fix() {
  [[ -e "$PARAM" ]] || { bad "驱动没有 disable_powersave 参数，无需/无法修复"; exit 1; }
  echo "options $MODULE disable_powersave=1" > "$MODCONF"
  ok "已写 $MODCONF"

  cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=Disable $MODULE firmware power save (keep beacons at full rate)
After=network.target
Before=hostapd-br0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'p=$PARAM; for i in \$(seq 1 30); do [ -w "\$p" ] && { echo 1 > "\$p"; exit 0; }; sleep 1; done; exit 0'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT" >/dev/null 2>&1
  echo 1 > "$PARAM" 2>/dev/null || true
  ok "已启用 $UNIT 并写入参数=1（立即生效）"

  # ② 固件 ini：power_save_switch = 0（启动时读取，需重启）
  local ini; ini=$(find_ini)
  if [[ -n "$ini" ]]; then
    [[ -f "$INI_BAK" ]] || cp -a "$ini" "$INI_BAK"
    sed -i 's/^power_save_switch *= *.*/power_save_switch = 0/' "$ini"
    ok "已把 $(basename "$ini") 的 power_save_switch 设为 0（备份 $INI_BAK）"
    echo "     ⚠️ 该项需【重启】才彻底生效；重启后跑 '$0 check' 复核"
  else
    echo "  ⚠️  未找到 wifi ini，跳过第 ② 步"
  fi

  sleep 3
  local rate; rate=$(measure)
  info "修复后 tx_packets/s" "$rate"
  if [[ "$rate" -ge 8 ]]; then
    ok "beacon 速率已恢复正常"
  else
    echo "  ⚠️  仍未提升：可能本机是射频/天线问题，见 43-ssid-visibility.sh 第 4 节"
  fi
}

revert() {
  systemctl disable --now "$UNIT" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$UNIT" "$MODCONF"
  systemctl daemon-reload
  echo 0 > "$PARAM" 2>/dev/null || true
  if [[ -f "$INI_BAK" ]]; then
    local ini; ini=$(find_ini)
    [[ -n "$ini" ]] && cp -a "$INI_BAK" "$ini" && ok "已恢复固件 ini（重启后生效）"
    rm -f "$INI_BAK"
  fi
  ok "已恢复默认（省电开启）。重启后彻底回到出厂默认"
}

case "$ACTION" in
  check)  check ;;
  fix)    fix ;;
  revert) revert ;;
  *) echo "用法: sudo bash $0 {check|fix|revert}" >&2; exit 1 ;;
esac
