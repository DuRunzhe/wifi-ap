#!/usr/bin/env bash
# UWE5622（sprdwl_ng）AP 看门狗：检测驱动 TX 队列卡死并自动恢复
#
# 背景（实测）：
#   该驱动在 AP 模式下长时间运行后会出现
#     sprdwl:tx timeout / sprdwl:TID=BE, timeout!
#   随后持续
#     sprdwl_start_xmit drop msg due to TX Err
#   beacon 与 probe response 发不出去 —— 表现为「AP 还在，但设备搜不到 / 连不上」。
#   重启 hostapd 通常不够（卡在驱动层），需要重启整机或重载驱动。
#
# 用法：
#   sudo bash 60-watchdog.sh install     # 安装 systemd timer（默认每 5 分钟自检）
#   sudo bash 60-watchdog.sh check       # 手动跑一次判定（timer 调用的就是它）
#   sudo bash 60-watchdog.sh status      # 最近一次判定 / 历史动作 / timer 状态
#   sudo bash 60-watchdog.sh uninstall   # 卸载
#
# 调参（install 时写入 unit 的 Environment=）：
#   INTERVAL=300       检查间隔（秒）
#   MAX_TXERR=3        单个周期内 TX Err 新增超过该值算异常
#   MIN_TXP_RATIO=5    每秒 tx_packets 低于该值算 beacon 可疑（正常 beacon 10/s）
#   COOLDOWN=1800      两次自动恢复动作的最小间隔（秒）
#   REBOOT_ON_FAIL=0   重启 hostapd 仍异常时是否重启整机（默认 0=只记录并告警）
                   ⚠️ 部分板子（Orange Pi Zero 2 等）软重启会黑屏、必须断电冷启动，
                      这种情况下开启本项会让设备彻底失联，请保持 0。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BR=br0
WIFI=wlan0
UNIT=hostapd-${BR}
STATE_DIR=/var/lib/wifi-ap-watchdog
STATE=$STATE_DIR/state
LOG=$STATE_DIR/watchdog.log   # 放 /var/lib：/var/log 在部分 Orange Pi 镜像上是 zram，重启会丢
INSTALL_PATH=/usr/local/lib/wifi-ap/watchdog.sh
SELF=$(readlink -f "$0")

INTERVAL=${INTERVAL:-300}
MAX_TXERR=${MAX_TXERR:-3}
MIN_TXP_RATIO=${MIN_TXP_RATIO:-5}
COOLDOWN=${COOLDOWN:-1800}
REBOOT_ON_FAIL=${REBOOT_ON_FAIL:-0}   # 默认 0：软重启不安全的板子（如 Orange Pi Zero 2）不应被自动重启
LOG_MAX=1048576   # 1MB 截断

ACTION=${1:-check}
[[ $EUID -eq 0 ]] || { echo "请用: sudo bash $0 $ACTION"; exit 1; }

log(){ ensure_log; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; logger -t wifi-ap-watchdog "$*" 2>/dev/null || true; }
say(){ printf '%s\n' "$*"; }

# /var/log 在部分 Orange Pi 镜像上是 zram（orangepi-ramlog），
# 开机早期可能尚未就绪；先确保文件可写，避免日志写入报错。
ensure_log(){
  if [[ ! -w $LOG ]]; then
    mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
    : > "$LOG" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- 状态
LAST_TXERR=0; LAST_TXP=0; LAST_TS=0; LAST_ACTION=0; BAD_STREAK=0; INIT=0
load_state(){
  # shellcheck disable=SC1090
  [[ -r $STATE ]] && source "$STATE" 2>/dev/null
  : "${LAST_TXERR:=0}" "${LAST_TXP:=0}" "${LAST_TS:=0}" "${LAST_ACTION:=0}" "${BAD_STREAK:=0}"
}
save_state(){
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf 'LAST_TXERR=%s\nLAST_TXP=%s\nLAST_TS=%s\nLAST_ACTION=%s\nBAD_STREAK=%s\n' \
    "$1" "$2" "$3" "$4" "$5" > "$STATE" 2>/dev/null || true
}

rotate_log(){
  local sz
  sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [[ ${sz:-0} -gt $LOG_MAX ]]; then
    tail -c $((LOG_MAX / 2)) "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    log "日志超过 1MB，已截断保留后半段"
  fi
}

# ---------------------------------------------------------------- 采集
metric_txerr(){
  # TX 队列卡死 + 固件通信失联（后者在部分固件上只报 beacon/start_ap 失败，不报 TX Err）
  dmesg 2>/dev/null | grep -cE \
    "TX Err|beacon failed|start_ap failed|SYNC CMD ERROR|SYNC_VERSION\]timeout" || true
}
metric_txp(){   cat "/sys/class/net/$WIFI/statistics/tx_packets" 2>/dev/null || echo 0; }
metric_sta(){   hostapd_cli -i "$WIFI" all_sta 2>/dev/null | grep -cE '^[0-9a-f]{2}:' || true; }
metric_state(){ hostapd_cli -i "$WIFI" status 2>/dev/null | sed -n 's/^state=//p'; }

# 当前是否满足"健康"条件；不健康时把原因写进 REASONS
# TX Err 只作为辅助证据：驱动偶发报错并不影响 beacon，单独触发会误重启；
# 真正的硬故障信号是「服务异常 / 非 AP 模式 / tx_packets 停涨」。
REASONS=()
TXRERR_NOTE=""
evaluate(){
  local state txerr txp now delta_t per_sec txerr_delta
  REASONS=()
  TXRERR_NOTE=""
  now=$(date +%s)
  load_state
  txerr=$(metric_txerr)
  txp=$(metric_txp)
  state=$(metric_state)

  # dmesg 环形缓冲轮转 / 驱动重置 → 计数会变小，重置基线避免误判
  [[ ${txerr:-0} -lt $LAST_TXERR ]] && LAST_TXERR=0
  [[ ${txp:-0} -lt $LAST_TXP ]] && LAST_TXP=0

  # 首次运行（或 state 被清）：只建基线，不下判断
  if [[ $LAST_TS -eq 0 ]]; then
    CUR_TXERR=$txerr; CUR_TXP=$txp; CUR_NOW=$now
    CUR_PER_SEC=0; CUR_STA=$(metric_sta)
    INIT=1
    return 0
  fi
  INIT=0

  delta_t=$(( now - LAST_TS ))
  [[ $delta_t -lt 1 ]] && delta_t=$INTERVAL
  # 长期未跑（timer 被停过）时，按一个周期估算，避免增速被稀释成 0
  [[ $delta_t -gt $(( INTERVAL * 3 )) ]] && delta_t=$INTERVAL
  per_sec=$(( (txp - LAST_TXP) / delta_t ))

  [[ $state == ENABLED ]] || REASONS+=("hostapd state=${state:-未知}")
  iw dev "$WIFI" info 2>/dev/null | grep -q 'type AP' || REASONS+=("$WIFI 不是 AP 模式")
  [[ $per_sec -lt $MIN_TXP_RATIO ]] && REASONS+=("tx_packets ${per_sec}/s < ${MIN_TXP_RATIO}/s（beacon 疑似停发）")

  txerr_delta=$(( txerr - LAST_TXERR ))
  [[ $txerr_delta -gt $MAX_TXERR ]] && TXRERR_NOTE="TX Err 本周期新增 $txerr_delta（仅告警；beacon 正常时不动作）"

  CUR_TXERR=$txerr; CUR_TXP=$txp; CUR_NOW=$now; CUR_PER_SEC=$per_sec; CUR_STA=$(metric_sta)
  (( ${#REASONS[@]} == 0 ))
}

show_metrics(){
  say "  tx_packets/s : ${CUR_PER_SEC:-?}（正常 beacon ≈10）"
  say "  TX Err 累计  : ${CUR_TXERR:-?}（本周期新增 $(( ${CUR_TXERR:-0} - LAST_TXERR ))）"
  say "  hostapd state: $(metric_state || true)"
  say "  已连客户端   : ${CUR_STA:-0}"
  [[ -n ${TXRERR_NOTE:-} ]] && say "  ⚠️  ${TXRERR_NOTE}"
}

# ---------------------------------------------------------------- 动作
recover(){
  local why="$1"
  log "判定异常：$why"

  if [[ $LAST_ACTION -gt 0 && $(( CUR_NOW - LAST_ACTION )) -lt $COOLDOWN ]]; then
    log "冷却中（距上次动作 $(( CUR_NOW - LAST_ACTION ))s < ${COOLDOWN}s），本轮只记录不动作"
    return 0
  fi

  log "第 1 步：重启 $UNIT"
  systemctl restart "$UNIT" 2>&1 | tail -2 | while read -r l; do log "  $l"; done
  sleep 20

  # 复测：只看 beacon 是否恢复
  local p1 p2 per
  p1=$(metric_txp); sleep 10; p2=$(metric_txp); per=$(( (p2 - p1) / 10 ))
  if [[ $per -ge $MIN_TXP_RATIO && $(metric_state) == ENABLED ]]; then
    log "重启 hostapd 后已恢复（tx_packets ${per}/s）"
    save_state "$(metric_txerr)" "$(metric_txp)" "$(date +%s)" "$CUR_NOW" 0
    return 0
  fi
  log "重启 hostapd 无效（tx_packets ${per}/s），判定为驱动层卡死"

  if [[ $REBOOT_ON_FAIL == 1 ]]; then
    log "第 2 步：重启整机（记录后执行）"
    save_state "$(metric_txerr)" "$(metric_txp)" "$(date +%s)" "$CUR_NOW" 0
    sync
    ( sleep 3; systemctl reboot ) >/dev/null 2>&1 &
  else
    log "REBOOT_ON_FAIL=0，跳过重启整机；请人工介入"
    save_state "$(metric_txerr)" "$(metric_txp)" "$(date +%s)" "$CUR_NOW" 0
  fi
}

# ---------------------------------------------------------------- 子命令
do_check(){
  ensure_log
  rotate_log
  if evaluate; then
    if [[ ${INIT:-0} -eq 1 ]]; then
      save_state "$CUR_TXERR" "$CUR_TXP" "$CUR_NOW" "$LAST_ACTION" 0
      say "首次运行，已记录基线（TX Err=$CUR_TXERR, tx_packets=$CUR_TXP），下个周期开始判定"
      exit 0
    fi
    # 健康：清零连续异常计数
    if [[ $BAD_STREAK -ne 0 ]]; then
      log "恢复正常（此前连续异常 $BAD_STREAK 次）"
    fi
    save_state "$CUR_TXERR" "$CUR_TXP" "$CUR_NOW" "$LAST_ACTION" 0
    if [[ -n ${TXRERR_NOTE:-} ]]; then
      log "健康，但 $TXRERR_NOTE"
    fi
    say "OK：tx_packets ${CUR_PER_SEC}/s，TX Err 累计 ${CUR_TXERR}，客户端 ${CUR_STA}"
    [[ -n ${TXRERR_NOTE:-} ]] && say "  ⚠️  ${TXRERR_NOTE}"
    exit 0
  fi

  local why
  why=$(IFS='；'; echo "${REASONS[*]}")
  BAD_STREAK=$(( BAD_STREAK + 1 ))
  say "异常（连续第 ${BAD_STREAK} 次）：$why"
  show_metrics
  log "检测异常（连续第 ${BAD_STREAK} 次）：$why"

  if [[ $BAD_STREAK -lt 2 ]]; then
    save_state "$CUR_TXERR" "$CUR_TXP" "$CUR_NOW" "$LAST_ACTION" "$BAD_STREAK"
    say "首次异常，等待下一周期确认（避免瞬时抖动误判）"
    exit 1
  fi

  recover "$why"
  save_state "$(metric_txerr)" "$(metric_txp)" "$(date +%s)" "$CUR_NOW" 0
  exit 1
}

do_status(){
  ensure_log
  echo "===== 计时器 ====="
  systemctl is-enabled wifi-ap-watchdog.timer 2>/dev/null || echo "未安装"
  systemctl is-active wifi-ap-watchdog.timer 2>/dev/null || true
  systemctl list-timers wifi-ap-watchdog.timer --no-pager 2>/dev/null | head -3
  echo
  echo "===== 上次状态快照 ====="
  if [[ -r $STATE ]]; then
    load_state
    echo "  TX Err 基线   : $LAST_TXERR"
    echo "  tx_packets 基线: $LAST_TXP"
    echo "  上次检查      : $([ "$LAST_TS" -gt 0 ] && date -d "@$LAST_TS" '+%F %T' || echo 从未)"
    echo "  上次动作      : $([ "$LAST_ACTION" -gt 0 ] && date -d "@$LAST_ACTION" '+%F %T' || echo 无)"
    echo "  连续异常      : $BAD_STREAK"
  else
    echo "  还没有状态文件（尚未运行过 check）"
  fi
  echo
  echo "===== 实时判定 ====="
  load_state
  if evaluate; then
    if [[ ${INIT:-0} -eq 1 ]]; then
      echo "  ℹ️  还没有基线，下次 check（或 timer 首次运行）会建基线"
    else
      echo "  ✅ 当前健康"
    fi
  else
    echo "  ⚠️  当前异常：$(IFS='；'; echo "${REASONS[*]}")"
  fi
  show_metrics
  echo
  echo "===== 最近日志 ====="
  tail -20 "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  无日志"
}

do_install(){
  ensure_log
  install -d -m 755 /usr/local/lib/wifi-ap
  install -m 755 "$SELF" "$INSTALL_PATH"
  install -m 644 /dev/null "$LOG" 2>/dev/null || : > "$LOG"

  cat > /etc/systemd/system/wifi-ap-watchdog.service <<EOF
[Unit]
Description=wifi-ap watchdog (detect UWE5622 TX queue stuck)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=INTERVAL=$INTERVAL MAX_TXERR=$MAX_TXERR MIN_TXP_RATIO=$MIN_TXP_RATIO COOLDOWN=$COOLDOWN REBOOT_ON_FAIL=$REBOOT_ON_FAIL
ExecStart=/bin/bash $INSTALL_PATH check
SuccessExitStatus=1
TimeoutStartSec=180
EOF

  cat > /etc/systemd/system/wifi-ap-watchdog.timer <<EOF
[Unit]
Description=Run wifi-ap watchdog every ${INTERVAL}s

[Timer]
OnBootSec=180
OnUnitActiveSec=$INTERVAL
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now wifi-ap-watchdog.timer >/dev/null 2>&1
  log "已安装：timer 每 ${INTERVAL}s 自检；硬信号（hostapd 非 ENABLED / 非 AP / tx_packets<${MIN_TXP_RATIO}/s）连续 2 次触发恢复，冷却 ${COOLDOWN}s，REBOOT_ON_FAIL=${REBOOT_ON_FAIL}"
  say "✅ 已安装并启动 wifi-ap-watchdog.timer"
  say "  脚本位置: $INSTALL_PATH"
  say "  检查间隔: ${INTERVAL}s   冷却: ${COOLDOWN}s   失败后重启整机: ${REBOOT_ON_FAIL}"
  say "  看状态:   sudo bash $SELF status"
  say "  看日志:   tail -f $LOG   /  journalctl -t wifi-ap-watchdog"
}

do_uninstall(){
  systemctl disable --now wifi-ap-watchdog.timer >/dev/null 2>&1 || true
  systemctl stop wifi-ap-watchdog.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/wifi-ap-watchdog.service /etc/systemd/system/wifi-ap-watchdog.timer
  systemctl daemon-reload
  log "已卸载 timer 与 service（保留 $LOG 与 $STATE_DIR）"
  say "✅ 已卸载（脚本 $INSTALL_PATH、状态 $STATE_DIR、日志 $LOG 保留，可手动删）"
}

case "$ACTION" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  check)     do_check ;;
  status)    do_status ;;
  *) echo "用法: sudo bash $0 {install|check|status|uninstall}"; exit 1 ;;
esac
