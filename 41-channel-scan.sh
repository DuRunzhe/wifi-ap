#!/usr/bin/env bash
# 扫描周边 AP 并给信道打分，推荐最优信道（AP 不用停，扫描可在 AP 运行时进行）
#
# 用法：
#   sudo bash 41-channel-scan.sh                 # 只扫描 + 推荐
#   sudo bash 41-channel-scan.sh --apply 36      # 应用到 ch36（自动选 80MHz/@5G）
#   sudo bash 41-channel-scan.sh --apply 36 40   # 指定带宽 40MHz
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WIFI=wlan0; UNIT=hostapd-br0; CONF=/etc/hostapd/hostapd-br0.conf
APPLY=""; WIDTH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY="$2"; shift 2; [[ -n "${1:-}" && "$1" != --* ]] && { WIDTH="$1"; shift; } ;;
    *) echo "未知参数 $1"; exit 1 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "请用 sudo"; exit 1; }

iw dev $WIFI scan 2>/dev/null > /tmp/chscan.txt
python3 - "$WIDTH" <<'PY'
import re, sys, collections
txt=open('/tmp/chscan.txt',encoding='utf-8',errors='ignore').read()
bss=[b for b in re.split(r'(?m)^BSS ', txt)[1:]]
rows=[]
for b in bss:
    f=re.search(r'freq:\s*(\d+)', b); s=re.search(r'signal:\s*(-?[\d.]+)', b)
    w=re.search(r'channel width:\s*(\d+)', b); ss=re.search(r'SSID:\s*(.*)', b)
    if not f: continue
    freq=int(f.group(1)); sig=float(s.group(1)) if s else -99
    width=int(w.group(1)) if w else 20
    ch = 14 if freq==2484 else (freq-2407 if freq<2500 else (freq-5000)//5)
    rows.append(dict(f=freq,ch=ch,sig=sig,width=width,ssid=(ss.group(1).strip() if ss else '')))

def block(prim,width):
    if width<=20: return {prim}
    if width<80:
        return {prim-4,prim} if prim%8==4 else {prim,prim+4}
    for a in (36,52,100,116,132,149):
        if a<=prim<=a+12: return set(range(a,a+16,4))
    return {prim}

def score(cand,width):
    blk = block(cand,width) if width>=40 else {cand}
    if width>=80:
        for a in (36,52,100,116,132,149):
            if a<=cand<=a+12: blk=set(range(a,a+16,4)); break
    elif width==40:
        blk={cand,cand+4} if cand%8!=4 else {cand-4,cand}
    tot=0.0; det=[]
    for r in rows:
        if r['ch'] in (0,): continue
        nb=block(r['ch'],r['width'])
        if nb & blk:
            w=max(0.0,(r['sig']+95)/10.0)
            tot+=w; det.append((r['sig'],r['ch'],r['ssid'][:20],r['width']))
    return tot,det,blk

print(f"扫描到 {len(rows)} 个 BSS\n")
cands=[]
for ch in (1,6,11):
    for w in (20,40): cands.append(('2.4G',ch,w))
for ch in (36,40,44,48,149,153,157,161,165):
    for w in (20,40,80):
        if w==80 and ch not in (36,149): continue
        cands.append(('5G',ch,w))
res=[]; details={}
for band,ch,w in cands:
    s,det,blk=score(ch,w)
    res.append((s,band,ch,w,sorted(blk)))
res.sort(key=lambda x:(x[0], -x[3]))
print("排名  频段  主信道 带宽    干扰分  占用子信道        重叠邻居")
for i,(s,band,ch,w,blk) in enumerate(res[:12],1):
    print(f"{i:>3}   {band:<5} ch{ch:<4} {w:>3}MHz {s:>7.1f}  {str(blk):<18} ", end='')
    _,det,_=score(ch,w)
    print(f"{len(det)} 个（最强 {max(d[0] for d in det) if det else 0:.0f}dBm）")
cur=[l for l in open('/etc/hostapd/hostapd-br0.conf') if l.startswith('channel=')]
print(f"\n当前使用: {cur[0].strip() if cur else '?'}   （分数越低越好）")
PY

if [[ -n "$APPLY" ]]; then
  if [[ -z "$WIDTH" ]]; then
    if [[ "$APPLY" == 36 ]]; then WIDTH=80; else WIDTH=40; fi
  fi
  echo
  echo ">>> 应用到 ch$APPLY / ${WIDTH}MHz"
  cp -a "$CONF" "${CONF}.bak-$(date +%H%M)"
  sed -i "/^channel=/d" "$CONF"; sed -i "1i channel=$APPLY" "$CONF"
  if [[ "$APPLY" -gt 14 ]]; then
    sed -i "s/^hw_mode=.*/hw_mode=a/" "$CONF"
  else
    sed -i "s/^hw_mode=.*/hw_mode=g/" "$CONF"
  fi
  sed -i "/^ieee80211ac=/d;/^vht_oper_chwidth=/d;/^vht_oper_centr_freq_seg0_idx=/d" "$CONF"
  if [[ "$WIDTH" == 80 ]]; then
    printf 'ieee80211ac=1\nvht_oper_chwidth=1\nvht_oper_centr_freq_seg0_idx=%d\n' $((APPLY+6)) >> "$CONF"
  elif [[ "$WIDTH" == 40 ]]; then
    sed -i "s/^ht_capab=.*/ht_capab=[SHORT-GI-20][SHORT-GI-40][HT40+]/" "$CONF"
  fi
  systemctl restart "$UNIT"; sleep 5
  echo "  生效: $(hostapd_cli -i $WIFI status 2>/dev/null | grep -E '^(channel|secondary_channel|vht_oper_centr_freq_seg0_idx)=' | tr '\n' ' ')"
  echo "  客户端: $(hostapd_cli -i $WIFI all_sta 2>/dev/null | grep -c AUTHORIZED) 台（会短暂重连）"
  echo "  回退: sudo cp ${CONF}.bak-* $CONF && sudo systemctl restart $UNIT"
fi
