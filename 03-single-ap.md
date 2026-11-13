# 需求3：把这台机器当成所有设备的「统一 WiFi 入口」，让局域网互访不跨主路由

## 一、你的问题在物理上是怎么产生的

主路由是「多 AP + 同一 LAN + 不固定分配（band steering / 粘连）」：

```
        ┌──── AP1 ┐
手机A ──┤         ├── 主路由交换背板 ── 手机B
        └──── AP2 ┘
   A 和 B 分在不同 AP → 每帧都要 AP→背板→AP 走一圈 → 时延抖动大、空口抢占
```

要彻底绕开这条路径，唯一办法是**让 A、B 落在同一个 BSS 里**，由一台设备在本地做 L2 转发。
这正是本方案的桥接 AP：

```
  手机A ─┐
  手机B ─┤ wlan0 ── br0 ──┬── eth0 ── 主路由（只有去外网/回有线侧的流量才走）
  手机C ─┘                 └── 同 BSS 内互访：br0 直接回发到 wlan0
```

同 BSS 内 A→B 的帧只经历 **一次上行 + 一次下行空口**，全程不落地 eth0，**主路由的任何 AP 都感知不到**。

## 二、落地这件事的三个必要条件

| # | 条件 | 为什么 | 脚本里的做法 |
|---|---|---|---|
| 1 | **换一个独立 SSID 名** | 若沿用主路由同名 SSID，客户端的 band steering / 粘连逻辑会把它吸回主路由的 AP，落到不同 AP 上照样绕远路 | 默认 `SSID=PiLink`（与主路由不同名）→ 设备只能连这一个 AP，等价于"固定分配" |
| 2 | `ap_isolate=0` | 客户端隔离一开，同 AP 设备之间直接被驱动/芯片拦掉 | 配置里显式写死 `ap_isolate=0` |
| 3 | 桥内能同端口回发 | 所有 STA 挂在同一个桥端口 `wlan0` 上，A→B 是"同端口转发"；个别驱动/内核组合会被桥丢掉 | 默认不开 hairpin；若实测不通，`bridge link set dev wlan0 hairpin on` |

> 注意：**独立 SSID 不是妥协，而是你需求的正确解法**。"AP 分配不能固定"指的是主路由的自动漫游/band steering，
> 一旦设备连到另一个 SSID，它就不会自动漫游回去 —— 这才是真正意义上的"固定"。

## 三、代价：单 BSS 的物理上限（必须知道）

本机是 **1 天线单流**（`Available Antennas: TX 0x1 RX 0x1`，`2 streams: not supported`），且所有设备共享一个信道：

| 频段/带宽 | PHY 上限 | 单向实测（约） | **同 AP 内互访**（双向占 2× 空口） |
|---|---|---|---|
| 2.4G HT40 1SS | 150 Mbps | 60–90 Mbps | **30–45 Mbps** |
| 5G VHT80 1SS | 433 Mbps | 150–200 Mbps | **70–100 Mbps** |

单 AP 内互访的每一帧都要占 **两次空口时间**（收 + 发），所以"互访吞吐 ≈ 单向吞吐的一半"是物理定律，不是调参能解决的。

因此建议：

- **用 5G**（脚本默认 `BAND=5g CH=149`，避开雷达信道；也可选 36/44/48）
- 客户端数量控制在 **8～16** 以内（`max_num_sta=16`）
- 若设备多/要求高吞吐，唯一解法是加一个 USB 无线网卡（`wlan1`）分担，或换更强硬件

## 四、已做的低延迟调优（写进 `hostapd-br0.conf`）

```conf
ap_isolate=0                     # 允许同 AP 内互访（需求前提）
wmm_enabled=1                    # 保留 WMM 优先级，语音/游戏流有 EDCA 优先
uapsd_advertisement_enabled=0    # 关 U-APSD，减少省电造成的时延抖动
dtim_period=1                    # 组播/唤醒更快（电池设备略费电，局域网更跟手）
beacon_int=100
ieee80211n=1
ht_capab=[SHORT-GI-20][SHORT-GI-40][HT40+]   # 2.4G；5G 时自动换 VHT80 配置
```

客户端侧也建议关掉省电（手机「电池优化」/笔记本 `iw dev wlan0 set power_save off`），否则延迟抖动主要来自客户端。

## 五、验证「真的没跨主路由」

需要 `tcpdump`（当前没装，宿主机有外网可以装）：

```bash
sudo apt install -y tcpdump
sudo bash ~/wifi-ap/01-verify-intrabss.sh <A的IP> <B的IP> 20
```

脚本会做四件事：

1. 打印 `iw dev wlan0 station dump`（两端都应在本 AP 的关联表里）
2. 打印 `brctl showmacs br0`（客户端 MAC 应挂在 wlan0 端口上）
3. 检查 `ap_isolate` / `bridge` / `wmm` 配置是否生效
4. 在 **eth0** 上抓 A↔B 的包 → **抓到 0 个 = 流量没离开本机** ✅

手动版（最直观）：

```bash
# 一台设备上:  ping -i 0.2 <B的IP>
# 本机上并行:  sudo tcpdump -i eth0 -n 'host <A的IP> and host <B的IP>'
#              期望：一个包都没有
# 对照实验：  sudo tcpdump -i br0 -n 'host <A> and host <B>'
#              期望：能看到 ICMP echo/request 成对出现 → 走的是桥，不是 eth0
```

## 六、排查阶梯（互 ping 不通或测出绕行时）

```bash
# 1) 确认两台设备真的都连到这里，而不是还挂在主路由的 AP 上
iw dev wlan0 station dump | grep -E '^Station|signal'

# 2) 看桥转发表：客户端 MAC 是否学在 wlan0 端口
brctl showmacs br0

# 3) 同端口转发被桥丢弃 → 打开 hairpin（hostapd 2.9 不支持 bridge_hairpin，只能手动）
sudo bridge link set dev wlan0 hairpin on

# 4) 确认没开客户端隔离
grep ap_isolate /etc/hostapd/hostapd-br0.conf     # 必须是 0
sudo systemctl restart hostapd

# 5) 最坏情况：驱动在芯片层面做了 intra-BSS 过滤 → 只能换网卡（USB 方案）
```

## 七、与其他需求的独立性

| 组件 | 与「统一入口」的关系 |
|---|---|
| 基础桥接 | 本身就是统一入口，**常开** |
| 进阶1 代理 | 只对"网关指向本机"的设备生效；关掉不影响 AP 内互访，也不影响同 BSS 转发 |
| 反例 | 若把 WiFi 改成 NAT 子网（P3 方案），同 AP 互访仍在本机，但**去有线/去主路由 AP 的设备要过 NAT**，就不再是"同一个局域网" |

## 八、还有一件无法消除的事

**广播/组播**（ARP、DHCP、mDNS/SSDP、主路由的 beacon 之外的信标）会在整个 L2 广播域泛洪，
这些帧必然会被桥发到 eth0，也会收到主路由侧广播。这是二层网络的本性，但：

- 频率低（ARP 有缓存、DHCP 只在续租）
- 影响的是"背景噪声"而不是你关心的 A↔B 数据通路

如果想进一步压低，可以在桥上加 `tc` 限速/优先级，或者干脆给这批设备一个独立 VLAN（需要交换机支持，主路由不可动时做不到）。
