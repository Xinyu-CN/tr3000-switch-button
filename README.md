# TR3000 Switch Button

Cudy TR3000 物理拨动开关控制器，适用于 OpenWrt / ImmortalWrt。

程序读取开关档位，通过向自定义脚本传入 `on` / `off` 控制 VPN、Wi-Fi、广告过滤、LED 等服务，支持去抖、失败重试和状态查询。默认动作脚本仅记录日志。

项目采用源码安装，通过命令行和 UCI 配置，要求固件提供相应的 GPIO 或按钮事件接口。WireGuard 接入方式见 [可选示例](examples/wireguard/README.md)。

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

将项目目录复制到路由器，以下以路由器 LAN 地址 `192.168.1.1` 为例：

```sh
scp -r tr3000-switch-button root@192.168.1.1:/root/
ssh root@192.168.1.1
cd /root/tr3000-switch-button
sh install.sh
```

路由器未安装 SFTP 时，可使用 `scp -O -r ...`。

安装脚本检查 TR3000 板型、OpenWrt 环境和必要命令；保留已有配置和动作脚本，不自动启动服务。已经启用的 `slide-switch` 或已有 `/etc/rc.button/BTN_0` 需要先处理，避免一个开关执行两套操作。

编辑路由器上的 `/etc/tr3000-switch/action.sh`，配置档位对应的操作后启用服务：

```sh
chmod 700 /etc/tr3000-switch/action.sh
uci set tr3000-switch.main.enabled='1'
uci commit tr3000-switch
/etc/init.d/tr3000-switch enable
/etc/init.d/tr3000-switch start
tr3000-switch status
```

## 通用接入接口

配置项 `action` 指定**可执行文件的绝对路径**。动作脚本示例：

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

将 `my-service` 替换为目标服务，也可在分支中调用多个命令或脚本。默认模板见 [examples/action.sh](examples/action.sh)。

| 输入 | 含义 |
| --- | --- |
| 第一个参数 `on` / `off` | 应当应用的目标档位 |
| `TR3000_SWITCH_STATE` | 同样是目标档位 |
| `TR3000_SWITCH_PREVIOUS` | 上次成功应用的档位；首次为 `unknown` |
| 返回码 `0` | 动作成功 |
| 非零返回码 / 超时 | 动作失败，记录日志并按当前档位重试 |

脚本以 root 执行，需满足**幂等性**：重复调用 `on` 保持开启，重复调用 `off` 保持关闭。脚本应在动作完成后退出，避免后台进程持续修改状态。执行中的动作不会因拨动而强制取消，响应时间取决于动作耗时和超时设置。

更换动作脚本：

```sh
uci set tr3000-switch.main.action='/etc/tr3000-switch/my-action.sh'
uci commit tr3000-switch
/etc/init.d/tr3000-switch restart
```

健康检查默认关闭。将 `check_interval` 设为大于 0 的秒数后，脚本需支持 `脚本 check on` 和 `脚本 check off`；返回非零会触发重新应用档位。健康检查调用设置 `TR3000_SWITCH_STATE`，不提供 `TR3000_SWITCH_PREVIOUS`。

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

对调物理开关的两档映射：

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

显示 `physical=unknown` 时，可拨动开关检查按钮事件，并通过 `diagnose` 查看 GPIO 和日志。缺少 debugfs 且未收到按钮事件时，程序保持等待；启动时识别当前档位需要固件提供可用的 GPIO 读取接口。

## 卸载与升级

```sh
sh uninstall.sh
```

卸载会停止监听、调用当前脚本 `off`，再删除程序文件，保留配置和用户脚本。使用 WireGuard 示例时先按它的文档恢复网络配置。

升级时重新运行 `install.sh`，安装器会停止监听并保留配置和动作脚本，完成后手动启动服务。系统刷机或 sysupgrade 后需重新安装。
