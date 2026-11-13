# 把 Orange Pi Zero 2 变成 WiFi 路由器（分阶段落地）

> 目标：其他设备通过 WiFi 连上来 → ① 和有线设备同一个内网 + 能上外网 → ② 加网络代理 → ③ 作为**统一 WiFi 入口**，
> 让连上来的设备之间互访**不跨越主路由的多个 AP**
> 前置约束：**主路由完全不可操作**（不能改 DHCP、不能加路由、不能固定 AP 分配）

## 目录

```
wifi-ap/
├── 00-prepare.sh                # 阶段0.5：固定地址 + 开机自动运行（重启后仍生效）
├── 00-cleanup-openwrt.sh        # 阶段-1：清掉 openwrt 容器 + parent=eth0 的 macvlan（建桥前置）
├── 01-ap-bridge.sh              # 阶段0：桥接 AP —— 同一内网 + 外网 + 统一 WiFi 入口（核心，常开）
├── 01-verify-intrabss.sh        # 阶段0验收：证明同 AP 互访没走 eth0（不跨主路由）
├── 02-proxy.md                  # 阶段1：代理方案设计 + 三条可行路线 + 独立性验收
├── 03-single-ap.md              # 需求3设计：为什么独立 SSID 是关键 / 物理上限 / 排查阶梯
├── 10-proxy-gw.sh               # 阶段1：按需网关 + TPROXY 透明代理（setup/off/full-off/status）
├── mihomo-config.example.yaml   # 阶段1：mihomo 最小配置模板
├── 20-tailscale.sh              # 阶段2：虚拟局域网（本次先不做）
├── 30-router-changed.sh         # 换主路由/换网段后的一键适配
├── 40-latency.sh                # 运维：无线一跳延时/抖动/丢包体检
├── 41-channel-scan.sh           # 运维：周边信道占用扫描
├── 42-auto-channel.sh           # 运维：按实测选出可用信道/带宽白名单
├── 50-adb-link.sh               # 运维：adb over WiFi 链路质量实测
├── run-ap-setup.sh              # 脱离 SSH 会话启动 01-ap-bridge.sh（建桥必断连）
└── 99-revert.sh                 # 一键回滚基础层
```

## 本机能力（已实测）

| 项 | 结论 |
|---|---|
| 无线网卡 | `wlan0` = Unisoc UWE5622（`sprdwl_ng`），**支持 AP 模式**，2.4G 全信道 + 5G 36~165 |
| **只能开 1 个 AP** | `valid interface combinations: #{ managed, AP } <= 1` → 双 SSID 在本硬件上不可行 |
| hostapd | 已装 2.9，但 `/etc/default/hostapd` 没有 `DAEMON_CONF` → 服务"启动"了其实没跑 |
| 旧配置 bug | `/etc/hostapd.conf` 里是 `interface=p2p-dev-wlan0`（P2P 口，不能做 AP）→ 本方案另写配置，不动它 |
| 有线 | `eth0` 由主路由 DHCP 分配，与 WiFi 客户端同网段，NetworkManager 管理 |
| 代理能力 | `iptables 1.8.7(nft) + xt_TPROXY + xt_REDIRECT` 齐备，GitHub 可达 |
| 内核模块 | `tun` 已加载，`wireguard=m`；USB 无线网卡可用 `r8188eu / rtl8192cu / rtl8xxxu` |

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
（本机现已预装 `qrencode 4.1.1`，这层只是给重装/其他板子准备的兜底。）

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
> 本机只有 981MB 内存，没有强需求就不必引入额外密码管理。

## 阶段 0：桥接 AP（基础层，常开）

```
 手机 ─wifi─ [wlan0] ┐
                     br0 ─── [eth0] ── 主路由网段 ── 主路由 ── 外网
 有线设备 ───────────┘
```

WiFi 客户端由**主路由 DHCP** 分配地址 → 与有线设备同网段、可互访、能上网；本机只当"无线交换机"。

**统一入口的三个要点**（详见 `03-single-ap.md`）：

1. **SSID 用新名字**（默认 `PiLink`）→ 主路由的 band steering 不会把设备吸走，等价于"固定分配到本 AP"
2. `ap_isolate=0` → 同 AP 内设备互通
3. 同 BSS 内互访由 br0 本地转发，**不经过主路由的任何 AP**（一次空口往返）

```bash
sudo -E env PASS='你的密码' bash ~/wifi-ap/01-ap-bridge.sh
# 自定义：sudo -E env SSID=PiLink PASS='你的密码' BAND=5g CH=149 bash ~/wifi-ap/01-ap-bridge.sh
```

- 过程中 eth0 短暂断开（重建为 br0，约 5~10 秒），SSH 会自动重连
- 任何一步失败**自动回滚**
- 回滚：`sudo bash ~/wifi-ap/99-revert.sh`

### 固定地址 + 开机自启（必做，否则重启就失效）

```bash
sudo bash ~/wifi-ap/00-prepare.sh setup      # 探测空闲地址作静态别名 + 持久化配置
sudo bash ~/wifi-ap/00-prepare.sh status     # 体检（重启后再跑一遍）
```

> ⚠️ **重要：建桥会立刻断开 SSH**（eth0 被移进 br0）。如果直接在前台跑脚本，会话一断脚本就被 SIGHUP 杀掉，
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
brctl show br0               # wlan0 + eth0
iw dev wlan0 station dump    # 手机连上后有 STATION 记录

sudo apt install -y tcpdump
sudo bash ~/wifi-ap/01-verify-intrabss.sh <A的IP> <B的IP>   # eth0 抓不到 A↔B 才算达标
```

## 阶段 1：代理（可开关，不影响基础层）

**核心结论**：桥接模式下客户端流量走 L2 直接到主路由，宿主机三层拦截不到；主路由又不可改。
所以代理必须由客户端侧"把本机设成网关"触发（或走实验性的桥层 MAC 劫持）。

```bash
sudo bash ~/wifi-ap/10-proxy-gw.sh setup --sub 'https://你的订阅链接'
```

然后在那台设备的 WiFi 设置里：网关/DNS = 本机的 `br0` 地址（用 `00-prepare.sh show` 查看）。
不改的设备继续直连主路由，与代理完全无关。详见 `02-proxy.md`。

| 场景 | 结果 |
|---|---|
| 只跑基础层 | 手机自动 IP，直连，能上网、能访问内网 |
| 进阶1 开 | 设了网关的设备走 TPROXY 代理 |
| 进阶1 关（`off`） | 设了网关的设备仍有网（也可改回自动），其他设备全程无感 |
| 全拆（`full-off`） | 回到纯净桥接 |

## 物理上限提醒

本机是 **1 天线单流**、单 BSS 共享空口：5G VHT80 单向约 150–200Mbps，**同 AP 内互访约 70–100Mbps**（互访每帧占 2× 空口）。
客户端建议 ≤ 8–16；嫌慢只能加 USB 网卡（内核已带 `r8188eu / rtl8192cu / rtl8xxxu`）或换硬件。

## 阶段 2：虚拟局域网（暂缓）

```bash
sudo bash ~/wifi-ap/20-tailscale.sh     # 通告所在局域网网段（脚本自动探测），需在后台批准路由
```

## 更换主路由会怎样

AP 本身（hostapd + br0）**不依赖主路由**：换路由后 SSID 照样广播、设备之间照样互访（纯 L2）。
会变的只有下面四样：

| 依赖 | 换路由后的表现 | 处理 |
|---|---|---|
| DHCP（给 WiFi 客户端发 IP） | 新路由正常就自动跟随；若新路由是桥接/纯 AP 模式不发 DHCP → 客户端拿 169.254，需在本机跑 dnsmasq | `30-router-changed.sh` 会明确提示 |
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

0. `00-cleanup-openwrt.sh --backup` → 清掉 openwrt 容器与 `parent=eth0` 的 macvlan（否则 `br0` 无法组装）
1. `01-ap-bridge.sh` → 手机连上、拿到主路由网段的地址、能上网（基础层验收）
2. `00-prepare.sh setup` → 固定地址 + 开机自启（**必须做**）
3. `sudo reboot` → 重启后 `00-prepare.sh status` 全绿、手机自动重连（验证自动配置）
4. `10-proxy-gw.sh setup --sub ...` → 只让一台设备改网关试代理（进阶1 验收）
5. 两边分别 `off` / `on` 各测一次，确认互不影响
6. 满意后再考虑实验性全自动劫持、或加 USB 网卡做真隔离
