#!/usr/bin/env bash
# 脱离 SSH 会话执行 01-ap-bridge.sh（建桥会立刻切断连接，前台跑必被 SIGHUP 打死）
#
# 用法：
#   sudo bash run-ap-setup.sh 'PiLink' '你的密码' [5g|2g] [信道]
#   sudo bash run-ap-setup.sh 'PiLink' '你的密码' 5g 149
#
# 跟踪进度：
#   tail -f /var/log/ap-setup-run.log
#   journalctl -u ap-setup -f
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SSID=${1:-PiLink}
PASS=${2:-}
BAND=${3:-5g}
CH=${4:-}
LOG=/var/log/ap-setup-run.log
SELF_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SCRIPT="$SELF_DIR/01-ap-bridge.sh"

if [[ $EUID -ne 0 ]]; then
  echo "请用: sudo bash $0 [SSID] [密码] [5g|2g] [信道]"
  exit 1
fi
if [[ -z "$PASS" ]]; then
  echo "缺少 WiFi 密码。用法: sudo bash $0 [SSID] [密码] [5g|2g] [信道]"
  exit 1
fi
[[ -f "$SCRIPT" ]] || { echo "找不到 $SCRIPT"; exit 1; }

install -m 644 /dev/null "$LOG" 2>/dev/null || : > "$LOG"
# 让调用者（而非 root）也能直接 cat 日志
[[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]] && chown "$SUDO_USER" "$LOG" 2>/dev/null || chmod 644 "$LOG" 2>/dev/null
echo "===== $(date '+%F %T')  启动 AP 配置: SSID=$SSID BAND=$BAND CH=${CH:-默认} =====" >> "$LOG"

if command -v systemd-run >/dev/null 2>&1; then
  systemctl reset-failed ap-setup >/dev/null 2>&1 || true
  systemd-run --unit=ap-setup --collect \
      --setenv=SSID="$SSID" --setenv=PASS="$PASS" --setenv=BAND="$BAND" --setenv=CH="${CH:-149}" \
      --property=StandardOutput=append:"$LOG" \
      --property=StandardError=append:"$LOG" \
      /bin/bash "$SCRIPT"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "[!] systemd-run 提交失败 (rc=$rc)"
    exit $rc
  fi
  echo
  echo "✅ 已提交为 systemd 瞬态单元 ap-setup（与 SSH 无关，断线也会跑完）"
  echo "   跟踪: tail -f $LOG"
  echo "   或:   journalctl -u ap-setup -f"
  echo
  echo "   连接断开是正常的（eth0 被移进 br0），40~60 秒后重连，IP 由主路由重新分配，可能变化"
else
  setsid nohup env SSID="$SSID" PASS="$PASS" BAND="$BAND" CH="${CH:-149}" \
      /bin/bash "$SCRIPT" >>"$LOG" 2>&1 </dev/null &
  echo "✅ 已后台启动 (setsid+nohup)，跟踪: tail -f $LOG"
fi
