# 日常使用

首次启动和账户设置见[安装指南](install.md)。系统为 minimal 镜像，默认不包含桌面环境。

## 网络与蓝牙

建议通过有线网络完成首次登录。检查网卡地址和无线设备状态：

```sh
ip -br address
rfkill list
bluetoothctl show
```

minimal 镜像使用 systemd-networkd，网络配置保存在 `/etc/netplan/`。Wi-Fi 和蓝牙由内核驱动及 `w132d-wireless.service` 加载。蓝牙设备通过 BlueZ 管理，使用 `bluetoothctl` 配对普通外设。

## BLE 遥控器

支持的语音遥控器通过 `w132d-ble-remote.service` 映射为输入设备。开启默认十分钟的配对窗口：

```sh
sudo w132d-ble-pair
```

按住遥控器对应的配对组合键约五秒，直至指示灯快速闪烁。命令显示实时日志；`Ctrl-C` 只退出日志查看，配对窗口继续有效。已绑定设备通常自动重连。

需要替换已有绑定时执行：

```sh
sudo w132d-ble-pair --force
```

遥控按键与语音解码是独立功能。公开镜像可接收原始语音帧，不包含私有语音解码器，也不提供开箱即用的语音识别。

## 音频

ALSA 默认播放设备为 3.5 mm 输出，默认录音设备为 ES7202 麦克风输入。查看声卡：

```sh
aplay -l
arecord -l
```

HDMI 音频需由应用选择对应声卡。板载播放卡名为 `rk3528acodec`，录音卡名为 `rockchippdmmica`，优先按名称配置，避免声卡编号变化。

可通过 `alsamixer` 调整音量和输入增益，保存设置：

```sh
sudo alsactl store
```

需要排查耳机或麦克风时，运行 `w132d-audio-test`，按提示收听左右声道并录音。

## 电源与软件待机

红外或 BLE 遥控器的电源键切换软件待机：关闭 HDMI 输出和绿色电源灯，并在电视支持时发送 CEC 待机命令。再次按电源键恢复。

软件待机期间系统继续运行，网络服务保持工作。设备不支持系统 suspend。正常关机使用：

```sh
sudo poweroff
```

## 指示灯

| 电源灯 | 含义 |
|---|---|
| 绿色常亮 | 正常运行 |
| 绿色慢闪 | 有 systemd 服务失败 |
| 红色常亮 | 启动或关机阶段 |
| 红色慢闪 | 温度告警，默认阈值 85°C |

软件待机会关闭绿色电源灯。出现异常灯态时，检查 `systemctl --failed` 和内核日志。

## 服务与配置

| 服务 | 用途 |
|---|---|
| `w132d-wireless` | 加载 Wi-Fi / 蓝牙驱动 |
| `w132d-ble-remote` | BLE 遥控器配对、重连与按键桥接 |
| `w132d-ir-keymap` | 加载红外键表 |
| `w132d-led-status` | 指示灯状态 |
| `w132d-soft-standby` | 遥控电源键和软件待机 |

查看服务和日志，例如：

```sh
systemctl status w132d-ble-remote.service
journalctl -b -u w132d-ble-remote.service
```

板级 `/etc` 配置由 dpkg 管理，升级时保留管理员修改。调整服务使用 `sudo systemctl edit <unit>` 创建覆盖配置；直接修改 `/usr/lib/systemd/system/` 下的文件会在升级时被替换。管理员禁用的板级服务会保留禁用状态。
