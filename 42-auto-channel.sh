#!/usr/bin/env bash
# 自动/手动选信道（扫描 → 打分 → 切换，带白名单与失败回滚）
#
#   sudo bash 42-auto-channel.sh now [--apply]   # 评估（可选在明显更好时切换）
#   sudo bash 42-auto-channel.sh set 149 40      # 显式切到 ch149 / 40MHz
#   sudo bash 42-auto-channel.sh probe           # 实测本驱动支持哪些 信道+带宽（AP 会停 ~60s）
#   sudo bash 42-auto-channel.sh install         # 每小时自动评估（systemd timer）
#   sudo bash 42-auto-channel.sh status|uninstall
#
# 关键限制（都是实测结论）：
#   * 驱动不支持 CSA（hostapd_cli chan_switch → FAIL），切换只能重启 hostapd，
#     客户端断 5~15 秒后自动重连。
#   * 本固件 UNII-1（ch36/44/48）完全不支持，只有 ch149~161 可用 → 靠白名单约束，避免切挂。
#   * 每个候选都要先过白名单，切换后校验信道，失败自动回滚。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WIFI=wlan0
UNIT=hostapd-br0
CONF=/etc/hostapd/hostapd-br0.conf
LOG=/var/log/ap-channel.log
ALLOWED=/etc/ap-channel.allowed
STATE=/var/lib/ap-channel.last-switch
SELF=$(readlink -f "$0")
IMPROVE=${IMPROVE:-0.7}      # 新分数 < 当前*0.7 才切
MIN_GAP=${MIN_GAP:-10800}    # 两次切换最小间隔（秒）

[[ $EUID -eq 0 ]] || { echo "请用 sudo"; exit 1; }
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

cur_ch=$(sed -n 's/^channel=//p' "$CONF" | head -1)
cur_w=$(grep -q '^ieee80211ac=1' "$CONF" && echo 80 || echo 40)
cur_band=$(sed -n 's/^hw_mode=//p' "$CONF" | head -1)   # a=5G, g=2.4G

# ---------------------------------------------------------------- 扫描打分
evaluate(){
  local i
  for i in 1 2 3; do iw dev "$WIFI" scan 2>/dev/null > "/tmp/chscan.$i.txt"; sleep 1; done
  python3 - "$cur_ch" "$cur_w" "$cur_band" "$ALLOWED" <<'PYEOF'
import re, sys, glob
cur_ch, cur_w, band, allowed_file = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]

bss = {}
for fn in glob.glob('/tmp/chscan.*.txt'):
    for b in re.split(r'(?m)^BSS ', open(fn, encoding='utf-8', errors='ignore').read())[1:]:
        mac = b.split()[0]
        f = re.search(r'freq:\s*(\d+)', b)
        s = re.search(r'signal:\s*(-?[\d.]+)', b)
        w = re.search(r'channel width:\s*(\d+)', b)
        if not f:
            continue
        freq = int(f.group(1)); sig = float(s.group(1)) if s else -99.0
        width = int(w.group(1)) if w else 20
        ch = freq - 2407 if freq < 2500 else (freq - 5000) // 5
        if mac not in bss or sig > bss[mac][1]:
            bss[mac] = (ch, sig, width)

rows = [(ch, sig, w) for (ch, sig, w) in bss.values()
        if (ch < 15 and band == 'g') or (ch >= 32 and band == 'a')]

def block(ch, width):
    if width <= 20:
        return {ch}
    if width < 80:
        return {ch - 4, ch} if ch % 8 == 4 else {ch, ch + 4}
    for a in (36, 52, 100, 116, 132, 149):
        if a <= ch <= a + 12:
            return set(range(a, a + 16, 4))
    return {ch}

def score(cand, width):
    if width >= 80:
        blk = set(range(cand, cand + 16, 4))
    elif width == 40:
        blk = {cand, cand + 4}
    else:
        blk = {cand}
    tot, n = 0.0, 0
    for ch, sig, wn in rows:
        if block(ch, wn) & blk:
            tot += max(0.0, (sig + 95) / 10.0)
            n += 1
    return tot, n

allowed = []
try:
    for line in open(allowed_file):
        p = line.split()
        if len(p) == 2 and not line.startswith('#'):
            allowed.append((int(p[0]), int(p[1])))
except FileNotFoundError:
    allowed = [(cur_ch, cur_w)]

cands = [(ch, w) for ch, w in allowed
         if (ch >= 32 and band == 'a') or (ch < 15 and band == 'g')]
if not cands:
    cands = [(cur_ch, cur_w)]

res = sorted((score(ch, w)[0], ch, w, score(ch, w)[1]) for ch, w in cands)

def get(ch, w):
    for s, c, ww, n in res:
        if c == ch and ww == w:
            return s, n
    return 999.0, 0

cs, cn = get(cur_ch, cur_w)
best = res[0]
print(f"BSSCOUNT {len(rows)}")
print(f"CUR {cs:.2f} {cur_ch} {cur_w} {cn}")
print(f"BEST {best[0]:.2f} {best[1]} {best[2]} {best[3]}")
for s, c, w, n in res:
    print(f"CAND {s:.2f} {c} {w} {n}")
PYEOF
}

# ---------------------------------------------------------------- 切换
apply_channel(){   # $1=ch $2=width
  local ch=$1 w=$2 old i
  old=$(mktemp); cp -a "$CONF" "$old"
  cp -a "$CONF" "${CONF}.bak-$(date +%H%M)"
  sed -i "/^channel=/d" "$CONF"; sed -i "1i channel=$ch" "$CONF"
  sed -i "/^ieee80211ac=/d;/^vht_oper_chwidth=/d;/^vht_oper_centr_freq_seg0_idx=/d" "$CONF"
  if [[ "$cur_band" == a && "$w" == 80 ]]; then
    printf 'ieee80211ac=1\nvht_oper_chwidth=1\nvht_oper_centr_freq_seg0_idx=%d\n' $((ch + 6)) >> "$CONF"
  elif [[ "$w" == 40 ]]; then
    sed -i "s/^ht_capab=.*/ht_capab=[SHORT-GI-20][SHORT-GI-40][HT40+]/" "$CONF"
  fi

  systemctl restart "$UNIT"
  local st=""
  for i in $(seq 1 25); do
    st=$(hostapd_cli -i "$WIFI" status 2>/dev/null | grep -E '^channel=' || true)
    [[ -n "$st" ]] && break
    sleep 1
  done
  if [[ "$st" != "channel=$ch" ]]; then
    log "❌ 切换失败（hostapd 未运行在 ch$ch），自动回滚"
    cp -a "$old" "$CONF"; systemctl restart "$UNIT"; sleep 6
    log "   回滚结果: $(hostapd_cli -i "$WIFI" status 2>/dev/null | grep -E '^channel=')"
    return 1
  fi
  echo "实际生效: $(hostapd_cli -i "$WIFI" status 2>/dev/null | grep -E '^(channel|secondary_channel|vht_oper_centr_freq_seg0_idx)=' | tr '\n' ' ')"
  echo "已连客户端: $(hostapd_cli -i "$WIFI" all_sta 2>/dev/null | grep -c AUTHORIZED) 台"
}

# ---------------------------------------------------------------- probe
do_probe(){
  local orig; orig=$(mktemp); cp -a "$CONF" "$orig"
  local pass; pass=$(sed -n 's/^wpa_passphrase=//p' "$CONF")
  : > "$ALLOWED"
  echo "# 本驱动实测可用的信道/带宽（$(date '+%F %T') 自动生成）" >> "$ALLOWED"
  local combos="36:80 36:40 36:20 40:40 44:40 44:20 48:40 48:20 149:80 149:40 149:20 153:40 157:40 157:20 161:20 165:20"
  for combo in $combos; do
    local ch=${combo%%:*} w=${combo##*:}
    local f="/tmp/probe-$ch-$w.conf"
    { echo "interface=$WIFI"; echo "bridge=br0"; echo "driver=nl80211"
      echo "ctrl_interface=/var/run/hostapd"; echo "ssid=PROBE"; echo "hw_mode=a"
      echo "channel=$ch"; echo "country_code=CN"; echo "ieee80211d=1"
      echo "auth_algs=1"; echo "wpa=2"; echo "wpa_passphrase=$pass"
      echo "wpa_key_mgmt=WPA-PSK"; echo "rsn_pairwise=CCMP"
      echo "ieee80211n=1"; echo "ht_capab=[SHORT-GI-20][SHORT-GI-40][HT40+]"
      [[ $w == 80 ]] && { echo "ieee80211ac=1"; echo "vht_oper_chwidth=1"; echo "vht_oper_centr_freq_seg0_idx=$((ch+6))"; }
    } > "$f"
    systemctl stop "$UNIT" >/dev/null 2>&1; pkill -x hostapd 2>/dev/null; sleep 0.5
    ip link set "$WIFI" down 2>/dev/null
    hostapd -dd "$f" > "/tmp/probe-$ch-$w.log" 2>&1 &
    local pid=$! ok=0 i real=0 st=""
    # 必须看到日志里的 AP-ENABLED，才说明真正开始 beacon（iw 的 type AP 在接口 down 后仍然为真）
    for i in $(seq 1 16); do grep -q 'AP-ENABLED' "/tmp/probe-$ch-$w.log" 2>/dev/null && { ok=1; break; }; sleep 0.5; done
    real=0
    if [[ $ok == 1 ]]; then
      # 以 hostapd 运行状态为准（日志里的 HT40 行只表示“尝试”，不代表被驱动接受）
      st=$(hostapd_cli -p /var/run/hostapd -i "$WIFI" status 2>/dev/null)
      if echo "$st" | grep -q '^vht_oper_centr_freq_seg0_idx='; then real=80
      elif echo "$st" | grep -qE '^secondary_channel=[13]'; then real=40
      else real=20; fi
    fi
    if [[ $ok == 1 && $real == $w ]]; then echo "$ch $w" >> "$ALLOWED"; printf '  ch%-4s 请求 %-3sMHz  实际 %-3sMHz ✅\n' "$ch" "$w" "$real"
    elif [[ $ok == 1 ]]; then printf '  ch%-4s 请求 %-3sMHz  实际 %-3sMHz ⚠️ 不匹配，不收录\n' "$ch" "$w" "$real"
    else printf '  ch%-4s 请求 %-3sMHz  ❌ 起不来\n' "$ch" "$w"; fi
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    ip link set "$WIFI" down 2>/dev/null
  done
  cp -a "$orig" "$CONF"; systemctl start "$UNIT" >/dev/null 2>&1; sleep 6
  log "白名单已写入 $ALLOWED；AP 已恢复: $(hostapd_cli -i "$WIFI" status 2>/dev/null | grep -E '^channel=')"
}

case "${1:-now}" in
  now)
    out=$(evaluate)
    echo "$out" | grep '^CAND' | awk '{printf "  候选 ch%-4s %-3sMHz  分数 %-6s 重叠邻居 %s\n", $3, $4, $2, $5}'
    cs=$(echo "$out" | awk '/^CUR/{print $2}');  bs=$(echo "$out" | awk '/^BEST/{print $2}')
    bc=$(echo "$out" | awk '/^BEST/{print $3}'); bw=$(echo "$out" | awk '/^BEST/{print $4}')
    n=$(echo "$out" | awk '/^BSSCOUNT/{print $2}')
    log "扫描 ${n} 个 BSS；当前 ch${cur_ch}/${cur_w}MHz 分数 ${cs}；最优 ch${bc}/${bw}MHz 分数 ${bs}"
    if [[ "$bc" == "$cur_ch" && "$bw" == "$cur_w" ]]; then log "已在最优，保持。"; exit 0; fi
    if awk -v b="$bs" -v c="$cs" -v r="$IMPROVE" 'BEGIN{exit !(b < c*r)}'; then
      if [[ "${2:-}" == "--apply" ]]; then
        last=$(cat "$STATE" 2>/dev/null || echo 0); now=$(date +%s)
        if (( now - last < MIN_GAP )); then
          log "改善明显，但距上次切换仅 $(( (now-last)/60 )) 分钟（阈值 $((MIN_GAP/60))），跳过。"; exit 0
        fi
        log "切换：ch${cur_ch}/${cur_w} → ch${bc}/${bw}"
        if apply_channel "$bc" "$bw" | tee -a "$LOG"; then echo "$now" > "$STATE"; fi
      else
        log "建议切到 ch${bc}/${bw}MHz（加 --apply 才执行）"
      fi
    else
      log "改善不足 30%，保持 ch${cur_ch}。"
    fi
    ;;
  set)
    tch=${2:-}; tw=${3:-}
    [[ -n "$tch" && -n "$tw" ]] || { echo "用法: sudo bash $0 set <信道> <20|40|80>"; exit 1; }
    if [[ -s $ALLOWED ]] && ! grep -qx "$tch $tw" "$ALLOWED"; then
      log "❌ ch$tch/${tw}MHz 不在白名单 $ALLOWED 中，拒绝执行"; exit 1
    fi
    log "显式切换：ch$cur_ch/$cur_w → ch$tch/$tw"
    apply_channel "$tch" "$tw" | tee -a "$LOG" && echo "$(date +%s)" > "$STATE"
    ;;
  probe) do_probe ;;
  install)
    mkdir -p /var/lib
    cat > /etc/systemd/system/ap-auto-channel.service <<EOF
[Unit]
Description=AP auto channel evaluation
After=network-online.target hostapd-br0.service
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF now --apply
EOF
    cat > /etc/systemd/system/ap-auto-channel.timer <<'EOF'
[Unit]
Description=Hourly AP channel evaluation
[Timer]
OnBootSec=10min
OnUnitActiveSec=60min
AccuracySec=5min
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload; systemctl enable --now ap-auto-channel.timer
    log "已安装 timer（每小时评估一次，日志 $LOG）"
    systemctl list-timers ap-auto-channel.timer --no-pager | head -3
    ;;
  status)
    systemctl is-enabled ap-auto-channel.timer 2>/dev/null || echo "timer 未安装"
    systemctl list-timers ap-auto-channel.timer --no-pager 2>/dev/null | head -3
    echo "--- 白名单 ---"; cat "$ALLOWED" 2>/dev/null || echo "(未生成，建议先跑 probe)"
    echo "--- 最近日志 ---"; tail -12 "$LOG" 2>/dev/null || echo "(暂无)"
    ;;
  uninstall)
    systemctl disable --now ap-auto-channel.timer 2>/dev/null
    rm -f /etc/systemd/system/ap-auto-channel.service /etc/systemd/system/ap-auto-channel.timer
    systemctl daemon-reload; log "已卸载 timer"
    ;;
  *) echo "用法: sudo bash $0 {now [--apply]|set <ch> <w>|probe|install|status|uninstall}"; exit 1 ;;
esac
