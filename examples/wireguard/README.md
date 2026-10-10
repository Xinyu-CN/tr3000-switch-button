# 可选示例：拨动切换 WireGuard 全局出口

这是通用 `on` / `off` 接口的一个独立实现。主程序不加载这些文件，也不依赖 WireGuard。只有手动运行本目录的 `setup.sh`，才会修改网络、DNS 和防火墙配置。

`on`：建立 WireGuard，路由器自身和 LAN 客户端的互联网流量通过 VPN。`off`：关闭 WireGuard、恢复 WAN 出口和 WAN 提供的 DNS。

## 适用范围

- 使用 firewall4/nftables 的 OpenWrt / ImmortalWrt，单 LAN、单 dnsmasq、一个 WireGuard 对端和一个逻辑上联。
- 路由器是 LAN 的网关，VPN 服务端已经支持转发/NAT 和客户端地址。
- VPN endpoint 使用**数字 IPv4 地址**，避免启动 VPN 前还需要通过 WAN 解析域名。
- IPv4 全局出口必需；提供了 VPN IPv6 地址时可同时走 IPv6，否则 VPN 档阻断 IPv6 外网，拨回后恢复。
- 不与 PBR、mwan3、OpenClash、Passwall、其他全局 VPN 或第三方加速模块同时使用。已有多实例 DNS/自定义 dnsmasq `server` 配置时，安装器拒绝自动修改，应自行编写接入脚本适配。

全局指互联网流量。LAN 管理、WireGuard 加密传输、上联 DHCP 和必要的 IPv6 邻居发现仍按其用途直连。此示例保留更具体的本地路由，但阻断非 LAN/WG 出接口的普通流量，因此 VPN 档无法正常访问上游路由器的管理页。

## 配置示例

先安装项目主程序。路由器需有 `wireguard-tools`、WireGuard 内核支持、`firewall4` 和 `nft`。按固件包管理器安装缺失的依赖，例如：

```sh
# opkg 固件：
opkg update
opkg install kmod-wireguard wireguard-tools
# apk 固件使用：apk update && apk add kmod-wireguard wireguard-tools
```

在项目目录中执行：

```sh
cp examples/wireguard/settings.example /root/tr3000-switch-wg
chmod 600 /root/tr3000-switch-wg
vi /root/tr3000-switch-wg
```

将模板中的私钥、公钥、隧道地址、服务器 IP/端口改成自己的值。不要把真实配置提交到 Git。`203.0.113.10` 是文档占位地址，安装器会拒绝它。

| 配置 | 含义 |
| --- | --- |
| `private_key` | 客户端私钥 |
| `public_key` | 服务端公钥 |
| `preshared_key` | 可选预共享密钥 |
| `addresses` | 服务商分配的客户端隧道地址，带前缀 |
| `endpoint_host` / `endpoint_port` | 服务器数字 IPv4 和端口 |
| `tunlink` | 逻辑上联接口，例如 `wan` 或 `wwan` |
| `lan_device` | LAN 内核设备，例如 `br-lan` |
| `lan_zone` | LAN 防火墙区域，例如 `lan` |
| `dns` | VPN 内可访问的 IPv4 DNS，可为服务商内网 DNS |

建议通过 LAN 操作。准备完成后：

```sh
/etc/init.d/tr3000-switch stop
uci set tr3000-switch.main.enabled='0'
uci commit tr3000-switch
sh examples/wireguard/setup.sh /root/tr3000-switch-wg
```

安装器备份现有配置，创建专用接口 `trwg` 和 `trswitch_*` 配置段，将通用 `action` 指向 `/etc/tr3000-switch/wireguard.sh`，启用 30 秒一次的健康检查。它重载网络、重启防火墙和 DNS，但不主动建立 VPN。重复安装会被拒绝，先恢复原配置再重新配置。

启动监听后拨动：

```sh
uci set tr3000-switch.main.enabled='1'
uci commit tr3000-switch
/etc/init.d/tr3000-switch enable
/etc/init.d/tr3000-switch start
tr3000-switch status
wg show trwg
```

## 路由、DNS 与掉线行为

- IPv4 使用两条 `/1` 路由覆盖 WAN 的 `/0`，避免默认路由 metric 相同导致选路不确定。IPv6 按配置使用同样的办法。
- netifd 为服务器保留通过 `tunlink` 到达的主机路由，防止 WireGuard 套进自己的隧道。`trwg` 关闭后，netifd 移除它的路由。
- dnsmasq 使用 `/tmp/tr3000-switch-wireguard/resolv.conf`：VPN 档写入 VPN DNS，普通档复制 WAN 自动 DNS，普通档健康检查会刷新 DHCP 更新后的 DNS，最多约 30 秒延迟。
- `on` 先安装独立 nftables 出口限制，再启动接口并等待握手。没有握手也不会自动恢复 WAN；保留限制并重试。拨回 `off` 先关闭接口，确认设备消失，再恢复 DNS、解除限制。
- 此示例关闭软件/硬件流量卸载，避免旧连接绕过转发链检查；该设置在普通档也保持关闭，可能影响直连性能。安装前配置保存在备份中。
- 切换出口后，已有 TCP/QUIC 会话可能需要应用重新连接。

普通 firewall4 reload/restart 不删除独立的 `inet tr3000_switch` 表。手动执行 `nft flush ruleset`、`fw4 flush` 或第三方插件清空规则不属于保证范围，健康检查只能随后恢复。

这是运行期的掉线保护，**不保证从上电第一包开始就阻断 WAN**：监听服务首次识别档位并安装规则前存在启动窗口。系统时钟还需正确，否则 WireGuard 握手可能失败。首次启用前请完成时间同步。

服务停止/崩溃不会自动执行 `off`；已建立的 VPN/限制保留。恢复直连：

```sh
/etc/init.d/tr3000-switch stop
tr3000-switch run off
```

若接入脚本已损坏，可通过 LAN 手动 `ifdown trwg`，确认接口消失后删除 `inet tr3000_switch` 表，再按下文恢复 DNS/配置。

## 恢复安装前配置

备份目录记录在 `/etc/tr3000-switch/backup-path`，含完整的 `network`、`firewall`、`dhcp` 和主程序配置。如果安装后还修改过网络配置，先对比备份并合并，避免覆盖后续修改。确认需要恢复整份快照时：

```sh
/etc/init.d/tr3000-switch disable
/etc/init.d/tr3000-switch stop
tr3000-switch run off
backup_dir="$(cat /etc/tr3000-switch/backup-path)"
for package in network firewall dhcp tr3000-switch; do
    uci -q revert "$package"
    cp "$backup_dir/$package" "/etc/config/$package"
done
uci -q revert tr3000-switch-wireguard
rm -f /etc/config/tr3000-switch-wireguard
ubus call network reload
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
```

备份保留不删。此后可使用其他通用接入脚本，或返回根目录执行 `sh uninstall.sh`。

## 实机验收

自动测试使用模拟网络命令，并不等于实机通过。首次使用应检查：

1. 两档分别运行 `tr3000-switch status`；`wg show trwg` 的握手和计数是否更新。
2. `ip -4 route get 1.1.1.1` 是否在 VPN 档选择 `trwg`，服务器 IP 是否仍选择上联。
3. 在 LAN 客户端检查公网出口和 DNS；IPv6 应使用 VPN 出口或无法联网，不能从 WAN 绕过。
4. VPN 档断开服务端/上联，确认普通互联网访问失败；拨回后恢复直连和 DNS。
5. 两档分别重启，检查最终档位；测试上联 DHCP 续租以及 firewall4 重载。

实现参考：[OpenWrt WireGuard netifd 协议](https://github.com/openwrt/openwrt/blob/openwrt-24.10/package/network/utils/wireguard-tools/files/wireguard.sh)、[dnsmasq 启动脚本](https://github.com/openwrt/openwrt/blob/openwrt-24.10/package/network/services/dnsmasq/files/dnsmasq.init)、[firewall4 表管理](https://github.com/openwrt/firewall4/blob/master/root/sbin/fw4)。
