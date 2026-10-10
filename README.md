# TR3000 Switch Button

Cudy TR3000 的通用物理拨动开关控制器，面向 OpenWrt / ImmortalWrt。

主程序只负责识别档位、去抖、执行动作和失败重试。**你提供一个脚本，程序向它传入 `on` / `off`**；可以接入 VPN、Wi-Fi、广告过滤、LED 或自己的服务。默认示例只写日志，不修改网络。

WireGuard 是 [独立的可选接入示例](examples/wireguard/README.md)，不是主程序的依赖。本项目提供源码安装，不包含 LuCI 页面，也不是 Cudy 原厂固件插件。

## 工作方式

```text
物理拨动开关 ── GPIO 实际档位 / BTN_0 事件 ── 去抖与串行执行
                                                   │
                                  /etc/tr3000-switch/action.sh on
                                  /etc/tr3000-switch/action.sh off
```

- 启动时读取当前 GPIO 档位；默认每秒采样一次，连续两次相同才执行。
- 优先按 GPIO consumer 名 `mode` 读取 `/sys/kernel/debug/gpio`，不写死 GPIO 编号；按钮事件作为备用输入。
- 每次启动会应用一次当前档位；档位不变不重复执行成功的动作。
- 动作失败默认 30 秒后重试；默认 30 秒超时；动作串行执行，快速拨动最终应用最新的稳定档位。
- 运行状态放在 `/tmp`，拨动时不反复写闪存。
- 支持反转档位、命令行覆盖以及可选的接入脚本健康检查。

## 安装

将整个目录复制到路由器，例如在电脑执行（按实际 LAN 地址修改）：

```sh
scp -r tr3000-switch-button root@192.168.1.1:/root/
ssh root@192.168.1.1
cd /root/tr3000-switch-button
sh install.sh
```

如果较新的 `scp` 提示路由器没有 SFTP，可以改用 `scp -O -r ...`。

安装脚本检查 TR3000 板型、OpenWrt 环境和必要命令；保留已有配置和动作脚本，不自动启动服务。已经启用的 `slide-switch` 或已有 `/etc/rc.button/BTN_0` 需要先处理，避免一个开关执行两套操作。

编辑路由器上的 `/etc/tr3000-switch/action.sh`，然后启动：

```sh
chmod 700 /etc/tr3000-switch/action.sh
uci set tr3000-switch.main.enabled='1'
uci commit tr3000-switch
/etc/init.d/tr3000-switch enable
/etc/init.d/tr3000-switch start
tr3000-switch status
```

## 通用接入接口

配置项 `action` 是**可执行文件的绝对路径**，不是一串 shell 命令。例如：

```sh
#!/bin/sh
case "$1" in
    on)
        /etc/init.d/my-service start
        ;;
    off)
        /etc/init.d/my-service stop
        ;;
    *) exit 2 ;;
esac
```

上面的 `my-service` 替换成自己的服务或命令；也可以在分支中调用多个脚本。默认模板见 [examples/action.sh](examples/action.sh)。

| 输入 | 含义 |
| --- | --- |
| 第一个参数 `on` / `off` | 应当应用的目标档位 |
| `TR3000_SWITCH_STATE` | 同样是目标档位 |
| `TR3000_SWITCH_PREVIOUS` | 上次成功应用的档位；首次为 `unknown` |
| 返回码 `0` | 动作成功 |
| 非零返回码 / 超时 | 动作失败，记录日志并按当前档位重试 |

脚本以 root 执行，需要**幂等**：重复 `on` 应保持开启，重复 `off` 应保持关闭；不要写成每次调用都反转状态。脚本应在动作完成后退出，不要在后台留下持续修改状态的进程。执行中的动作不会因拨动而强制取消，因此最长响应时间还取决于动作耗时/超时。

如需换一个接入脚本：

```sh
uci set tr3000-switch.main.action='/etc/tr3000-switch/my-action.sh'
uci commit tr3000-switch
/etc/init.d/tr3000-switch restart
```

可选健康检查：将 `check_interval` 设为大于 0 的秒数，脚本还需支持 `脚本 check on` 和 `脚本 check off`。返回非零会触发重新应用档位。默认关闭，普通接入只实现 `on` / `off` 即可。健康检查调用设置 `TR3000_SWITCH_STATE`，不提供 `TR3000_SWITCH_PREVIOUS`。

## 配置与调试

配置在 `/etc/config/tr3000-switch`：

| 配置 | 默认 | 用途 |
| --- | --- | --- |
| `enabled` | `0` | 启用控制器 |
| `action` | `/etc/tr3000-switch/action.sh` | 通用接入脚本 |
| `button` | `BTN_0` | 按钮事件名称 |
| `gpio_label` | `mode` | debugfs 的 GPIO consumer 名 |
| `invert` | `0` | 设为 `1` 对调两档 |
| `poll_seconds` | `1` | 采样间隔 |
| `stable_samples` | `2` | 去抖要求的连续采样次数 |
| `retry_seconds` | `30` | 失败重试间隔 |
| `action_timeout` | `30` | 单次脚本执行时间上限 |
| `check_interval` | `0` | 健康检查间隔；`0` 表示关闭 |

如果物理左右方向与预期相反：

```sh
uci set tr3000-switch.main.invert='1'
uci commit tr3000-switch
/etc/init.d/tr3000-switch restart
```

常用命令：

```sh
tr3000-switch status       # 当前档位、目标档位、上次成功档位和执行状态
tr3000-switch diagnose     # 板型、GPIO、程序日志
logread -e tr3000-switch

tr3000-switch on           # 临时强制 on，需要服务运行
tr3000-switch off          # 临时强制 off
tr3000-switch auto         # 恢复跟随物理档位

/etc/init.d/tr3000-switch stop
tr3000-switch run on       # 服务停止时，同步测试接入脚本
tr3000-switch run off
```

`on` / `off` 命令是异步请求，以 `status=ready` 且 `applied` 为目标档位确认成功。命令行覆盖持续到 `auto` 或路由器重启；仅重启服务不会清除覆盖。

停止监听服务不会自动运行 `off`，也不会撤销用户脚本产生的效果。需要关闭时，先停止服务再执行 `tr3000-switch run off`。切换接入脚本前，应先完成原脚本的清理。

如果显示 `physical=unknown`：先拨动一次检查事件是否到达；若仍不可用，查看 `diagnose`。缺少 debugfs 且没有收到事件时，程序等待而不猜测档位。这类固件无法保证启动即识别当前档位，需要根据实际内核修正 GPIO/事件支持。

## 卸载与升级

```sh
sh uninstall.sh
```

卸载会停止监听、调用当前脚本 `off`，再删除程序文件，保留配置和用户脚本。使用 WireGuard 示例时先按它的文档恢复网络配置。

升级本项目可重新运行 `install.sh`，它会停止监听并保留配置/接入脚本，完成后手动启动服务。系统刷机/sysupgrade 后应重新安装，不保证自定义程序被固件保留。

## 验证范围

本地自动测试覆盖档位解析、反转、事件备用输入、去抖、重复事件、失败重试、串行执行及通用接入调用；WireGuard 示例还包含失败时保留阻断规则和恢复顺序的模拟测试。

```sh
python3 -m unittest discover -s tests -v
# 在装有 BusyBox 的 Linux 上测试目标 shell：
TEST_SHELL='busybox ash' python3 -m unittest discover -s tests -v
```

尚未在你的 TR3000 上实机验证；路由器不需要安装 Python。支持目标是具备这些 GPIO/按钮接口的 OpenWrt / ImmortalWrt，原厂固件另需适配。

实现参考：[OpenWrt TR3000 设备树](https://github.com/openwrt/openwrt/blob/main/target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dtsi)、[GPIO 按钮驱动](https://github.com/openwrt/openwrt/blob/main/package/kernel/gpio-button-hotplug/src/gpio-button-hotplug.c)、[procd 按钮分发](https://github.com/openwrt/openwrt/blob/openwrt-24.10/package/system/procd/files/hotplug.json)。
