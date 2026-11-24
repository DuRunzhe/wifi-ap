# 把单板 Linux 设备变成 WiFi 路由器（桥接 AP，分阶段落地）

> 脚本按能力自动探测、不写死板型：上行网卡从默认路由推断，无线能力用 `iw` / hostapd 现场实测。
> 面向 SDIO 无线网卡 + hostapd 的通用桥接方案（验证过的驱动如 `sprdwl_ng` / Unisoc UWE5622），
> 其它驱动的差异见「运行前提」「设备差异」与「排查」三节。
>
> ⚠️ **硬件前提**：部分单板**没有板载天线**，需要外接 IPEX / IPEX-1（U.FL）天线。
> 天线没接好时有效距离可能只有十几厘米，5G 更差 —— 排查任何「搜不到」之前先确认这一点。
>
> 目标：其他设备通过 WiFi 连上来 → ① 和有线设备同一个内网 + 能上外网 → ② 加网络代理 → ③ 作为**统一 WiFi 入口**，
> 让连上来的设备之间互访**不跨越主路由的多个 AP**
> 前置约束：**主路由完全不可操作**（不能改 DHCP、不能加路由、不能固定 AP 分配）

## 目录

```
wifi-ap/
├── 00-prepare.sh                # 阶段0.5：固定地址 + 开机自动运行（重启后仍生效）
├── 00-cleanup-openwrt.sh        # 阶段-1：清掉 openwrt 容器 + parent=上行网卡 的 macvlan（建桥前置）
├── 01-ap-bridge.sh              # 阶段0：桥接 AP —— 同一内网 + 外网 + 统一 WiFi 入口（核心，常开）
├── 01-verify-intrabss.sh        # 阶段0验收：证明同 AP 互访没走有线（不跨主路由）
├── 02-proxy.md                  # 阶段1：代理方案设计 + 三条可行路线 + 独立性验收
├── 03-single-ap.md              # 需求3设计：为什么独立 SSID 是关键 / 物理上限 / 排查阶梯
├── 10-proxy-gw.sh               # 阶段1：按需网关 + TPROXY 透明代理（setup/off/full-off/status）
├── mihomo-config.example.yaml   # 阶段1：mihomo 最小配置模板
├── 20-tailscale.sh              # 阶段2：虚拟局域网（本次先不做）
├── 30-router-changed.sh         # 换主路由/换网段后的一键适配
├── 40-latency.sh                # 运维：无线一跳延时/抖动/丢包体检
├── 41-channel-scan.sh           # 运维：周边信道占用扫描（AP 运行时会警告/可 --stop-ap）
├── 42-auto-channel.sh           # 运维：按实测选出可用信道/带宽白名单
├── 43-ssid-visibility.sh        # 排障：手机/电脑「搜不到 SSID」的排查阶梯 + 一键切 2.4G/5G
├── 44-firmware-powersave.sh     # 排障：固件省电压低 beacon 导致「时有时无」→ check/fix/revert
├── 50-adb-link.sh               # 运维：adb over WiFi 链路质量实测
├── 60-watchdog.sh               # 运维：驱动异常检测（TX 卡死 / 固件失联）+ 自动恢复
├── run-ap-setup.sh              # 脱离 SSH 会话启动 01-ap-bridge.sh（建桥必断连）
└── 99-revert.sh                 # 一键回滚基础层
```

## 运行前提与能力检查

换设备时**不要照抄任何人的数值，以本机实测为准**（同型号不同批次/不同系统都可能不一样）：

| 检查项 | 命令 | 期望 |
|---|---|---|
| 无线网卡存在 | `iw dev` | 列出 `wlan0`（或你的无线接口名） |
| 支持 AP 模式 | `iw list \| grep -A8 "Supported interface modes"` | 含 `* AP` |
| 同时能开几个 AP | `iw list \| grep "valid interface combinations"` | 常见为 `#{ managed, AP } <= 1`（只能一个 AP） |
| 上行网卡 | `ip route show default` | 能取到物理网卡名（脚本会自动探测，也可 `UPLINK=` 指定） |
| hostapd | `hostapd -v` | 有版本输出；注意系统自带的 `hostapd.service` 通常因缺 `DAEMON_CONF` 而起不了，本方案用独立单元 |
| 天线 | 目视 | IPEX 座已扣好、线无折断（**没接好会表现为「近距离能搜到、一两米就消失」**） |
| 驱动信息 | `readlink -f /sys/class/net/<iface>/device/driver`、`lsmod` | 确认是哪个驱动（决定后面用哪些排障脚本） |
| 代理能力（可选） | `iptables -m tproxy --help` | 支持 TPROXY / REDIRECT |

注意：`iw list` 在某些驱动上不返回完整信道表（`Frequencies:` 为空），**这不代表不能用**；
判断某信道是否真能用，以 `hostapd` 能否成功起在该信道为准（起不来会报 `Could not select hw_mode and channel`）。

## 设备差异：用脚本实测，不要假设

同一套脚本在不同 SoC / 驱动 / 系统上行为可能不同，**本仓库不维护具体型号的对照表**——
型号特定数据时效性差、批次差异大，请在本机用这些脚本实测：

| 现象 | 脚本 |
|---|---|
| 客户端搜不到 SSID | `43-ssid-visibility.sh`（含天线自检、频段/带宽切换） |
| 时有时无 / 偶尔才出现 | `44-firmware-powersave.sh`（固件省电导致 beacon 稀疏） |
| 连上但服务端异常、TX 卡死 | `60-watchdog.sh`（定时自检 + 恢复） |
| 信道/带宽选择 | `41-channel-scan.sh`、`42-auto-channel.sh` |
| 链路质量 | `40-latency.sh`、`50-adb-link.sh` |

已知需要分设备判断的几类：

- **软重启安全性**：有的板子 `reboot` 会黑屏，只能 `poweroff` + 拔电；先在能物理断电的前提下验证
- **空载 `tx_packets`**：很多 SDIO 驱动不把固件发出的 beacon 计入 Linux 统计，空载数值随机且无意义，**不能当判据**
- **5G AP**：有的系统/驱动 5G 能起（`state=ENABLED`）但客户端搜不到 → 用 `43` 切 2.4G 对照验证
- **固件省电**：部分驱动默认省体会压低 beacon 频率 → 用 `44` 检测与修复

## WiFi 连接信息（关键）

| 项 | 默认值 | 说明 |
|---|---|---|
| **SSID** | `PiLink` | 故意与主路由不同名，避免 band steering 把设备吸走 |
| **密码** | **必须显式指定**（≥8 位） | 脚本已无默认密码，未提供会直接报错退出 |
| 加密 | WPA2-PSK / CCMP | |
| 频段/信道 | 5GHz ch149 / VHT80 | `2.4G` 或改信道见下方 |
| 配置落盘 | `/etc/hostapd/hostapd-br0.conf` | 权限 600 |

随时查看（含二维码）：

```bash
sudo bash ~/wifi-ap/00-prepare.sh show      # SSID / 密码 / 频段 / 地址 / 已连设备数 / 二维码
```

二维码终端会直接画出来（`WIFI:T:WPA;S:...;P:...;;` 载荷，手机相机直接识别）。
若系统缺 `qrencode`，脚本会**自动 `apt-get install`**；装不上（无外网/dpkg 被占）则降级成一行文本扫码串，不报错。
不想让它装（或想保持离线）：`NO_QR=1 sudo bash ~/wifi-ap/00-prepare.sh show`。
（多数镜像已预装 `qrencode`，这层只是给重装或其它板子准备的兜底。）

修改（立即生效，已连设备会掉线重连）：

```bash
sudo bash ~/wifi-ap/00-prepare.sh set-wifi --pass 'MyStr0ngPass'    # 只改密码（≥8 位）
sudo bash ~/wifi-ap/00-prepare.sh set-wifi --ssid 'PiLink-Pro'      # 只改 SSID
sudo bash ~/wifi-ap/00-prepare.sh set-wifi --ssid 'PiLink' --pass 'MyStr0ngPass'
```

或者在首次创建时就指定（不改脚本、不存历史密码）：

```bash
sudo -E env SSID='PiLink' PASS='MyStr0ngPass' BAND=5g CH=149 bash ~/wifi-ap/01-ap-bridge.sh
```

> 密码明文只存在 `/etc/hostapd/hostapd-br0.conf`（600），不建议用 `wpa_psk` 哈希后忘记原文——
> 这类 1GB 内存的小板没必要再引入密码管理，够用即可。

## 阶段 0：桥接 AP（基础层，常开）

```
 手机 ─wifi─ [wlan0] ┐
                     br0 ─── [上行网卡] ── 主路由网段 ── 主路由 ── 外网
 有线设备 ───────────┘
```

WiFi 客户端由**主路由 DHCP** 分配地址 → 与有线设备同网段、可互访、能上网；这块板只当"无线交换机"。

**统一入口的三个要点**（详见 `03-single-ap.md`）：

1. **SSID 用新名字**（默认 `PiLink`）→ 主路由的 band steering 不会把设备吸走，等价于"固定分配到本 AP"
2. `ap_isolate=0` → 同 AP 内设备互通
3. 同 BSS 内互访由 br0 本地转发，**不经过主路由的任何 AP**（一次空口往返）

```bash
sudo -E env PASS='你的密码' bash ~/wifi-ap/01-ap-bridge.sh
# 自定义：sudo -E env SSID=PiLink PASS='你的密码' BAND=5g CH=149 bash ~/wifi-ap/01-ap-bridge.sh
```

- 过程中上行网卡短暂断开（重建为 br0，约 5~10 秒），SSH 会自动重连
- 任何一步失败**自动回滚**
- 回滚：`sudo bash ~/wifi-ap/99-revert.sh`

### 固定地址 + 开机自启（必做，否则重启就失效）

```bash
sudo bash ~/wifi-ap/00-prepare.sh setup      # 探测空闲地址作静态别名 + 持久化配置
sudo bash ~/wifi-ap/00-prepare.sh status     # 体检（重启后再跑一遍）
```

> ⚠️ **重要：建桥会立刻断开 SSH**（上行网卡被移进 br0）。如果直接在前台跑脚本，会话一断脚本就被 SIGHUP 杀掉，
> 会留下半成品状态。脚本已内置 `trap '' HUP` + EXIT 兜底回滚，但最稳的还是脱离会话执行：
>
> ```bash
> sudo -v
> sudo -E setsid nohup env SSID='PiLink' PASS='你的密码' BAND=5g CH=149 \
>   bash ~/wifi-ap/01-ap-bridge.sh > /tmp/ap-setup.log 2>&1 < /dev/null &
> ```
>
> 断线后重新连上（IP 由主路由重新分配，可能变化），看结果：
> `cat /tmp/ap-setup.log`
>
> 或者用 systemd 瞬态单元（日志进 journal，与 SSH 完全无关）：
>
> ```bash
> sudo systemd-run --unit=ap-setup --collect \
>   --setenv=SSID=PiLink --setenv=PASS='你的密码' --setenv=BAND=5g --setenv=CH=149 \
>   /bin/bash ~/wifi-ap/01-ap-bridge.sh
> journalctl -u ap-setup -f
> ```

做四件事：

| 项 | 作用 |
|---|---|
| br0 加**静态别名**（在同一网段内从高往低用 **ARP 层**探测挑空闲地址） | DHCP 地址保留（默认路由/上游 DNS 跟随主路由），另一个固定地址作为「契约地址」给 SSH/代理客户端用 |
| `/etc/NetworkManager/conf.d/99-unmanaged-wlan0.conf` | **关键**：`nmcli device set managed no` 只是运行时，重启后 NM 会把 wlan0 抢回去、AP 直接消失 |
| 专用 `hostapd-br0.service` | 取代 Debian 的 sysv hostapd：`After=br0 设备` + `ExecStartPre` 轮询等 br0 + `Restart=always`，解决开机顺序与崩溃自愈 |
| `fixed-ip.service` | 拖底：NM 万一没把静态别名加上就补上 |

验证：

```bash
iw dev wlan0 info            # type AP
brctl show br0               # 上行网卡 + wlan0
iw dev wlan0 station dump    # 手机连上后有 STATION 记录

sudo apt install -y tcpdump
sudo bash ~/wifi-ap/01-verify-intrabss.sh <A的IP> <B的IP>   # 上行网卡抓不到 A↔B 才算达标
```

## 阶段 1：代理（可开关，不影响基础层）

**核心结论**：桥接模式下客户端流量走 L2 直接到主路由，宿主机三层拦截不到；主路由又不可改。
所以代理必须由客户端侧"把这台板设成网关"触发（或走实验性的桥层 MAC 劫持）。

```bash
sudo bash ~/wifi-ap/10-proxy-gw.sh setup --sub 'https://你的订阅链接'
```

然后在那台设备的 WiFi 设置里：网关/DNS = 这台板的 `br0` 地址（用 `00-prepare.sh show` 查看）。
不改的设备继续直连主路由，与代理完全无关。详见 `02-proxy.md`。

| 场景 | 结果 |
|---|---|
| 只跑基础层 | 手机自动 IP，直连，能上网、能访问内网 |
| 进阶1 开 | 设了网关的设备走 TPROXY 代理 |
| 进阶1 关（`off`） | 设了网关的设备仍有网（也可改回自动），其他设备全程无感 |
| 全拆（`full-off`） | 回到纯净桥接 |

## 物理上限提醒

单天线单流的板子，单 BSS 共享空口，实际能力大约是：

| 频段/带宽 | 单向 | 同 AP 内互访（每帧占 2× 空口） |
|---|---|---|
| 2.4G HT20 1SS | 60–90 Mbps | 约为单向一半 |
| 5G VHT80 1SS | 150–200 Mbps | 约为单向一半 |

具体数值以 `40-latency.sh` / 实测 `iperf3` 为准。客户端建议 ≤ 8–16；嫌慢只能加 USB 网卡
（内核常带 `r8188eu / rtl8192cu / rtl8xxxu`）或换硬件。

## AP 起来了但设备连不上？按这个顺序排查

顺序按「实测命中率」排列，先看日志能省很多时间：

```bash
tail -f /var/log/hostapd-br0.log      # 一边排查一边看
iw dev wlan0 info                     # 应有 ssid / type AP / channel
```

### 0. 先确认「天线 + 距离」（命中率最高，且不用改任何东西）

**判断方法**：把手机贴着板子（10cm 内）扫一次。

| 结果 | 结论 |
|---|---|
| 10cm 能搜到、2m 左右就没了 | **天线没接好 / 线断了** → 检查 IPEX 座是否扣到位、换根天线 |
| 10cm 也搜不到 | 继续往下看（固件省电 / 频段 / 驱动） |

不少单板没有板载天线，这是「信号弱」最常见的原因，也是很多「时好时坏」假象的来源。

### 1. 「时有时无」——查固件省电

`hostapd` 明明 `state=ENABLED`、天线也正常，手机却时有时无：

```bash
sudo bash ~/wifi-ap/44-firmware-powersave.sh check   # 看修复是否已应用
sudo bash ~/wifi-ap/44-firmware-powersave.sh fix     # 关省电（模块参数 + 固件 ini，需重启）
```

`sprdwl_ng` 默认 `power_save_switch=2` 时 beacon 会变稀疏；手机每个信道只停约 100ms，
命中率下降，表现就是「偶尔能看到、连上也不稳」。

### 2. 搜不到 SSID

```bash
sudo bash ~/wifi-ap/43-ssid-visibility.sh              # 一键诊断：状态/桥/rfkill/周边扫描/射频线索
sudo bash ~/wifi-ap/43-ssid-visibility.sh --switch 2g  # 切 2.4G ch6 / HT20（最兼容）
sudo bash ~/wifi-ap/43-ssid-visibility.sh --switch 5g  # 切 5G ch149 / VHT80（吞吐优先）
```

优先级（天线已排除的前提下）：

1. **5.8G 兼容性** —— 5G ch149 属 UNII-3，部分手机/网卡扫不到；切 2.4G 立刻可见
2. **带宽** —— 2.4G 的 HT40+ 在个别驱动/固件组合下不出 SSID；HT20 最稳
3. **固件省电** —— 见第 1 节
4. **系统/驱动差异** —— 例如某些系统上 5G AP 起得来但客户端搜不到（见兼容性表，目前尚无定论，需接好天线后复测）

### 3. 能搜到但连不上 / 反复提示密码错误

日志里如果刷这几行：

```
wlan0: AP-STA-POSSIBLE-PSK-MISMATCH <MAC>
wlan0: STA <MAC> IEEE 802.11: disassociated
```

这是 **4 次握手 PSK 不匹配**，99% 是设备端保存了旧的（错误）密码记录，每次自动重连都用旧凭据：

1. 在设备上**「忘记此网络 / 删除网络」**
2. 再重新连接（扫码最省事）

```bash
# 生成连接二维码
qrencode -t ANSIUTF8 "WIFI:T:WPA;S:<SSID>;P:<密码>;;"
```

### 4. 连上了但没网 / 拿不到 IP

WiFi 客户端 IP 由**主路由 DHCP** 分配（桥接模式）。排查：

```bash
ip neigh show dev br0            # 看客户端是否从主路由拿到了地址
brctl show br0                   # wlan0 必须在 br0 里
ip -4 addr show br0              # br0 自身有地址
ping -c3 <主路由网关>            # br0 到主路由是否通
```

`brctl show br0` 里**看不到 wlan0** 是最常见问题：`nmcli con up br0` 重建桥时
会把 wlan0 挤出去，`systemctl restart hostapd-br0` 即可让它重新入桥。

若主路由 DHCP 池耗尽或设了 MAC 白名单，客户端就拿不到地址（此场景主路由不可操作时无解，
只能改用 NAT 模式）。

## 驱动稳定性（Unisoc UWE5622 / `sprdwl_ng` 已知问题，必读）

> 以下都是 `sprdwl_ng` 这个 SDIO 驱动的特性；换用其它驱动（`rtl8xxxu`、`r8188eu` 等 USB 网卡）不受影响。

`sprdwl_ng` 驱动长时间运行后可能 **TX 队列卡死**（出现时间因负载/批次而异，无法给出统一时长）：

```
dmesg:
  sprdwl:tx timeout drop num:0, l_num:31, maxnum:20000
  sprdwl:TID=BE, timeout!
  unisoc_wifi wlan0: sprdwl_start_xmit drop msg due to TX Err   ← 之后持续报
```

**表现**：`hostapd` 仍是 `state=ENABLED`、`iw dev wlan0 info` 仍是 `type AP`，
但 **beacon 和 probe response 发不出去** → 手机/电脑搜不到 SSID（或能连但极不稳定）。

**为什么重启 hostapd 没用**：卡点在驱动层，`systemctl restart hostapd-br0` 后
TX Err 会继续增长；需要**重载驱动模块**（`rmmod sprdwl_ng && modprobe sprdwl_ng`）才能恢复。

> ⚠️ **`reboot` 前先确认本板软重启是否安全**。有的板子 `systemctl reboot` 会黑屏无输出、网络不通，
> 必须**断电冷启动**。这类板子上不要把「重启整机」当作恢复手段，
> 否则会把「WiFi 不可用」升级成「整机失联、只能人工断电」。

**判定方法**（不用猜）：

```bash
# ① 有客户端时：tx_packets 应明显增长（无客户端时它基本不涨，属正常，不能据此判断故障）
a=$(cat /sys/class/net/wlan0/statistics/tx_packets); sleep 5
b=$(cat /sys/class/net/wlan0/statistics/tx_packets); echo "+$((b-a)) 包/5s"

# ② TX 卡死计数（持续增长即可确认）
dmesg | grep -c 'TX Err'

# ③ 最可靠的判据是「客户端实测」：能否搜到、能否连上、连上后能否持续收发
```

**自动化：`60-watchdog.sh`**

```bash
sudo bash ~/wifi-ap/60-watchdog.sh install     # 装 systemd timer（每 5 分钟自检）
sudo bash ~/wifi-ap/60-watchdog.sh status      # 看最近判定 / 历史动作
```

判定条件（连续 2 次确认才动作，默认冷却 30 分钟）：

| 指标 | 阈值 | 是否触发恢复 |
|---|---|---|
| `hostapd` state | 非 `ENABLED` | ✅ 硬信号 |
| `wlan0` 模式 | 非 `type AP` | ✅ 硬信号 |
| `tx_packets` 增速 | 有客户端时 < 1/s | ✅ 硬信号（**空载不判**：很多 SDIO 驱动不统计固件 beacon，空载数值随机且无意义） |
| 固件报错单周期新增 | > 3 | ✅ `beacon failed` / `start_ap failed` / `SYNC CMD ERROR` / `SYNC_VERSION]timeout` |
| `TX Err` 单周期新增 | > 3 | ❌ 只写日志告警（驱动会长期低频报它，当触发条件会周期性误重启） |

恢复阶梯：`restart hostapd-br0` 并复测 → 仍异常则**重载驱动模块** → 仍异常则写告警并通知
（`REBOOT_ON_FAIL` **默认 0**；软重启不安全的板子请保持 0，见下方说明）。

其他缓解：定时重载驱动、或把 AP 降到 HT40 降低 TX 压力。

### 🔴 不要改 CPU governor / 限制 max_freq（SDIO 网卡）

> 适用于 `sprdwl_ng` 这类 **SDIO** 无线网卡；USB 网卡不受此限制。

`sprdwl_ng` 走 **SDIO** 总线，对 CPU/SDIO 时钟分频很敏感。**运行中改变 governor 或限制最大频率**
可能立即触发下面这类错误：

```
unisoc_wifi wlan0: sprdwl_change_beacon failed
unisoc_wifi wlan0: sprdwl_cfg80211_start_ap failed to start AP!
sprdwl:[WIFI_CMD_SYNC_VERSION]timeout
sprdwl:SYNC CMD ERROR!!
```

后果：AP 再也起不来，`rmmod`/`modprobe` 重载驱动也救不回（固件侧已失联），
**只能断电冷启动**。

结论：

- 保持系统默认的 governor 与频率范围，不要为了降温/省电去改
- 降温请走硬件路线（加散热片），不要牺牲 CPU 频率
- 有的平台无线设备的 `power/runtime_status` 是 `unsupported`（不支持 runtime PM），
  这种设备**不要往里写值**，写了也无效果甚至可能引入副作用

检查当前是否符合：

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # 保持系统默认（不同平台默认值不同）
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq   # 不要人为限制
```

## 阶段 2：虚拟局域网（暂缓）

```bash
sudo bash ~/wifi-ap/20-tailscale.sh     # 通告所在局域网网段（脚本自动探测），需在后台批准路由
```

## 更换主路由会怎样

AP 本身（hostapd + br0）**不依赖主路由**：换路由后 SSID 照样广播、设备之间照样互访（纯 L2）。
会变的只有下面四样：

| 依赖 | 换路由后的表现 | 处理 |
|---|---|---|
| DHCP（给 WiFi 客户端发 IP） | 新路由正常就自动跟随；若新路由是桥接/纯 AP 模式不发 DHCP → 客户端拿 169.254，需在这块板上跑 dnsmasq | `30-router-changed.sh` 会明确提示 |
| 默认网关 | `ipv4.method auto` 自动跟随 | 无需动作 |
| 固定静态别名 | 换了网段就变死地址 | `30-router-changed.sh` 自动迁移 |
| 进阶1 代理规则 / Tailscale 网段 | 旧网段失效 | 前者自动重下，后者会给出手动命令 |

三种情形：

```bash
# A. 新路由同网段同网关 → 什么都不用做
# B. 新路由换了网段（比如 192.168.100.0/24）→ 一条命令搞定
sudo bash ~/wifi-ap/30-router-changed.sh --dry-run   # 先看要做什么
sudo bash ~/wifi-ap/30-router-changed.sh             # 执行
# C. 新路由不提供 DHCP → 脚本会检测到并打印在 br0 上启 dnsmasq 的做法
```

注意：固定地址可能变化，换完后 `SSH` 请用 `br0` 上的新地址；若新路由 DHCP 池包含该地址，
用 `sudo bash ~/wifi-ap/00-prepare.sh setup --ip <新网段>.250` 换一个。

## 推荐执行顺序

0. `00-cleanup-openwrt.sh --backup` → 清掉 openwrt 容器与 `parent=<上行网卡>` 的 macvlan（否则 `br0` 无法组装）
1. `01-ap-bridge.sh` → 手机连上、拿到主路由网段的地址、能上网（基础层验收）
   - 搜不到 SSID：`43-ssid-visibility.sh --switch 2g`（最兼容）
   - 时有时无：`44-firmware-powersave.sh fix`（关固件省电）
2. `00-prepare.sh setup` → 固定地址 + 开机自启（**必须做**）
3. 重启验证 → 重启后 `00-prepare.sh status` 全绿、手机自动重连
   - **先确认本板软重启是否安全**：不安全就 `sudo poweroff` 后拔电源、等 10 秒再上电
   - 确认安全（重启后能自动回网）才可以 `sudo reboot`
4. `60-watchdog.sh install` → 装 timer，长期运行兜底（TX 队列卡死 / 固件失联自动恢复）
5. `10-proxy-gw.sh setup --sub ...` → 只让一台设备改网关试代理（进阶1 验收）
6. 两边分别 `off` / `on` 各测一次，确认互不影响
7. 满意后再考虑实验性全自动劫持、或加 USB 网卡做真隔离
