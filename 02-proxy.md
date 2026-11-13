# 进阶1：网络代理（与基础功能完全独立）

## 一、先摆清楚三个硬约束（都实测过）

| # | 约束 | 影响 |
|---|---|---|
| 1 | **主路由不可操作** → 改不了 DHCP 的 option 3/6，也关不掉它的 DHCP | 「本机下发网关」这条路作废；不能用 DHCP 让全屋自动走代理 |
| 2 | 驱动 `valid interface combinations: #{ managed, AP } <= 1` → **只能开 1 个 AP 接口** | 「双 SSID：一个直连 + 一个代理」作废 |
| 3 | 桥接模式下客户端流量是 **L2 交换**过去的（目的 MAC 是主路由），不进本机三层 | 不把本机设成网关，宿主机上任何 iptables/TPROXY 规则都是空跑 |

结论：在不碰主路由的前提下，想让代理和基础功能彼此独立，只有两条路：

- **A（推荐）客户端按需指网关** —— 只影响你手动配置的设备，零风险，可随时进出
- **B（实验性）桥层按 MAC 劫持** —— 全自动、无感，但属于"选择性单点故障"，需谨慎

---

## 二、目标架构（正交两层）

```
                    ┌──────────────── 基础层（常开，与代理无关）────────────────┐
  手机(自动IP) ─wifi─ [wlan0] ─ br0 ─ [eth0] ─ 主路由网段 ─ 主路由 ─ 外网
                    └──────────────────────────────────────────────────────────┘

  手机(网关=<本机>) ─wifi─ [wlan0] ─ br0 ─ 本机三层 ─┬─ TPROXY ─ mihomo ─ 外网
                                     └──────────────────────┴─ 其余转发(SNAT) ─ 主路由
                    └─────────────── 进阶1（可开关，互不影响基础）───────────────┘
```

- 基础层：客户端网关 = 主路由，流量根本不经过本机三层 → **代理挂掉/关掉，基础层零影响**
- 进阶1：只有"网关指向本机 br0 地址"的设备会进入 TPROXY；关掉后这些设备改回"自动"即可
- 本机同时是 **L2 网桥** 和 **L3 网关**，两者互不干扰

> 为什么必须 SNAT：客户端和你本机在同一网段。若不 SNAT，回包由主路由直接按 ARP 发给客户端，
> 绕过本机 → 连接一对一不通。所以 `POSTROUTING -o eth0 -i br0 -s <局域网网段> -j MASQUERADE` 是必需的。

---

## 三、A 方案：按需网关 + TPROXY（推荐，已写好脚本）

```bash
# 首次：自动下载 mihomo(arm64) + 生成配置 + 装服务 + 下发规则
sudo bash ~/wifi-ap/10-proxy-gw.sh setup --sub 'https://你的订阅链接'

# 已有 /etc/mihomo/config.yaml 时
sudo bash ~/wifi-ap/10-proxy-gw.sh setup

# 日常开关
sudo bash ~/wifi-ap/10-proxy-gw.sh off        # 只停代理，改网关的设备仍有网
sudo bash ~/wifi-ap/10-proxy-gw.sh full-off   # 全部拆除，回到纯净桥接
sudo bash ~/wifi-ap/10-proxy-gw.sh status
```

客户端设置（iOS/Android/Windows 都支持在该 SSID 上设静态 IP）：

```
IP       <网段>.<空闲地址>   （同网段随便一个空闲地址）
掩码      255.255.255.0
网关      <本机 br0 地址>   ← 关键（00-prepare.sh show 可查）
DNS       <本机 br0 地址>
```

想取消：把该 SSID 的 IP 设回「自动」→ 立刻回到基础层的直连。

脚本做了什么：

| 组件 | 作用 |
|---|---|
| `mihomo.service` | 代理主体，`tproxy-port: 7895` + `dns.listen: 0.0.0.0:1053` |
| `proxy-gw.service` (oneshot) | 开机自动下发/清理 netfilter 规则 |
| mangle `PI_TPROXY` 链 | 只匹配 `-i br0 -s <局域网网段>`，内网/保留地址 RETURN，其余 TPROXY 到 7895 |
| nat PREROUTING | 客户端 53 端口 → DNAT 到本机 1053（DNS 也走代理） |
| nat POSTROUTING | `-i br0 -o eth0` MASQUERADE（同网段必需） |
| ip rule/table 100 | `fwmark 1 → local default dev lo`（TPROXY 标准配套） |

> ⚠️ **安全提示**：生成的配置把 `bind-address` 绑定到 br0 的局域网地址（不是 `*`），
> 但 `allow-lan` 下的 `7890` 是**无鉴权**的 HTTP/SOCKS 混合端口，同网段任何设备都能直接拿它当代理。
> 家庭内网可接受；宿舍/办公等不可信网段请取消配置里的 `authentication` 注释，改成 `"user:pass"`。
> `external-controller` 已固定绑 `127.0.0.1:9090`，不对外暴露。

验证：

```bash
sudo bash ~/wifi-ap/10-proxy-gw.sh status
# 客户端上：
curl -s https://www.cloudflare.com/cdn-cgi/trace | grep -E 'ip=|loc='
```

---

## 四、备选：用已有的 OpenWrt 容器当旁路由

和 A 方案是**二选一**（都是"客户端指网关"的思路），差别在代理脑子放在哪：

| | 宿主机 mihomo（A） | 容器 OpenClash/PassWall |
|---|---|---|
| 内存占用 | ~60–120MB | ~250–400MB（981MB 的板子要掂量） |
| 配置界面 | 只有 RESTful(9090) / yaml | 有 LuCI，订阅管理方便 |
| 前置工作 | 开箱即用 | 要先修 macvlan 网段 + 补 wan 口 + 宿主 shim |
| 故障面 | 小 | 多一层 docker/macvlan |

要走路这条，先重建容器网络（**parent 必须是 `br0`，不能是 `eth0`**，否则会和桥抢 rx_handler → EBUSY）：

```bash
# 0) 先清掉旧容器与 parent=eth0 的 macnet
sudo bash ~/wifi-ap/00-cleanup-openwrt.sh --backup

# 1) 在 br0 上重建 macvlan，并以固定 IP 启动容器
docker network create -d macvlan --subnet=<局域网网段> \
       --gateway=<主路由地址> -o parent=br0 macnet
docker run -d --name openwrt --network macnet --privileged \
       --restart always sulinggg/openwrt:armv8 /sbin/init
docker network connect --ip <网段>.<旁路由地址> macnet openwrt
docker exec openwrt sh -c '
  uci set network.lan.ipaddr=<网段>.<旁路由地址>
  uci set network.lan.gateway=<主路由地址>
  uci set network.lan.dns=<主路由地址>
  uci commit network; /etc/init.d/network restart'
# 宿主机访问容器（macvlan 默认隔离）
sudo ip link add macshim link eth0 type macvlan mode bridge
sudo ip addr add <网段>.<shim地址>/32 dev macshim
sudo ip link set macshim up
sudo ip route add <网段>.<旁路由地址>/32 dev macshim
```

之后客户端网关/DNS 填旁路由地址，在 LuCI 里配 OpenClash 即可。
容器停了只影响这些客户端，基础层照旧。

---

## 五、B 方案（实验性）：桥层按 MAC 劫持，全自动无感

原理：本机是那座"桥"，用 ebtables 的 `broute` 把指定设备的帧从 L2 转发**踢进本机三层**，
再用 nat REDIRECT 送给 mihomo 的 `redir-port`。已经在跑 mihomo 的前提下：

```bash
# 1) mihomo 配置里加 redir-port: 7893（auth-free 模式）
# 2) 只劫持某一台设备的 TCP（按 MAC，可精确到某台电视/盒子）
sudo ebtables -t broute -A BROUTING -p IPv4 -s AA:BB:CC:DD:EE:FF \
     --ip-proto tcp -j redirect --redirect-target DROP
# 3) 落地的流量交给 mihomo
sudo iptables -t nat -A PREROUTING -i br0 -p tcp -j REDIRECT --to-ports 7893
# 4) 该设备 DNS
sudo ebtables -t broute -A BROUTING -p IPv4 -s AA:BB:CC:DD:EE:FF \
     --ip-proto udp --ip-dport 53 -j redirect --redirect-target DROP
sudo iptables -t nat -A PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 1053
```

一键回退（**推荐写成脚本放着，出事第一秒执行**）：

```bash
sudo ebtables -t broute -F
sudo iptables -t nat -D PREROUTING -i br0 -p tcp -j REDIRECT --to-ports 7893
sudo iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 1053
```

风险（这就是为什么默认不推荐）：

- 被劫持的设备在代理进程挂掉时**直接断网**（其他设备不受影响）—— 属于"择性单点故障"
- ebtables broute 会让这些帧不再走硬件/内核桥转发，**吞吐下降**
- 与 `br_netfilter`、docker、vlan 混用容易互相打架，排障成本高

如果你要"全自动又要稳"，正确做法是加第二块无线网卡（见下）。

---

## 六、可选硬件升级：加一个 USB 无线网卡 → 双 SSID 真隔离

驱动只能开 1 个 AP，但**每个 phy 可以各开 1 个**。内核已经自带这些模块：

```
r8188eu.ko      RTL8188EU   (~¥15-25)
rtl8192cu.ko    RTL8192CU
rtl8xxxu.ko     RTL8188/8192 系列通用
rtl8189es/fs.ko 板载/SDIO 款
```

插上后：`wlan1` 专做「代理 SSID + 独立子网 10.10.0.0/24 + NAT + 透明代理」，
`wlan0` 保持桥接直连。两个 SSID 完全物理独立，关掉代理 SSID 对基础层零影响 —— 这才是最干净的方案。

---

## 七、独立性验收清单

| 场景 | 期望 | 验证 |
|---|---|---|
| 只跑基础层 | 手机自动 IP 拿到主路由网段地址，能上网、能访问内网设备 | `iw dev wlan0 station dump`，手机 `ip a` |
| 进阶1 开着 | 设了网关的设备出口 IP 变化 | `curl -s ifconfig.me` |
| 进阶1 关掉 | 设了网关的设备仍有网（还能顺手改回自动），其他设备全程无感 | `10-proxy-gw.sh off` 后两边分别测 |
| 进阶1 崩溃 | 基础层完全无感 | `systemctl stop mihomo` 后测其他设备 |
| 全拆 | 回到纯净桥接 | `10-proxy-gw.sh full-off` |
