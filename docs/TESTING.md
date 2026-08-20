# 实机验证

## 当前验收状态

`20260820-200141` 是当前参考镜像：

```text
SHA256 852927a4226ad4940213e1a3ac63dfce900770e3742f03c5a497bf374f0684d9
大小   2,831,155,200 bytes
```

截至 2026-08-20，实机连续运行超过 2 小时未再出现固定乱码、TTL/SSH 同时失联或复位。
Wi-Fi 随后完成关联并正常工作；记录中未出现 `Unexpected interrupt latency`、
`CMD_RSP_TIMEOUT_ERROR`、`marlin_cp2_reset`、`NETDEV WATCHDOG`、Oops 或 panic。

这只能支持“当前版本没有已观察到的明显大问题”。尚未覆盖多日运行、持续高吞吐、蓝牙与
Wi-Fi 并发压力、反复 suspend/resume、异常断电、全部 HDMI EDID、所有 USB 设备或 VPU
编码/解码矩阵。

## 首次启动检查

把 `scripts/verify-w132d.sh` 放到设备并以 root 执行。它检查设备树、USB hub、DMC/红外、
Wi-Fi SDIO、蓝牙 HCI、NetworkManager、GPU/DRM、MPP 节点、网络和 eMMC。

关键人工检查：

```bash
ip link
nmcli device status
nmcli device wifi list
bluetoothctl list
lsusb
ls -la /dev/dri /dev/mpp_service 2>/dev/null
dmesg | grep -iE 'Oops|panic|watchdog|stall|RX_BOUNDS|BT_RX_BOUNDS|SITM_BOUNDS|marlin|sprdwl'
```

预期 `end0` 由 systemd-networkd 管理，在 `nmcli` 中显示 unmanaged；`wlan0` 由
NetworkManager 管理。HDMI 需在 2560x1440 显示器确认全宽输出，不应再有右侧紫色/错位区域。

## 长测建议

1. TTL 从上电前开始全程捕获，SSH 同时在线。
2. 空闲 40 分钟，覆盖原来的约 30 分钟窗口。
3. 连接 Wi-Fi 并产生实际流量，再运行至少 2 小时。
4. 加入蓝牙扫描/连接与 USB2 负载，观察是否出现边界诊断或 WCN reset。
5. 最后单独测试 suspend/resume、VPU 和异常断电，避免一次改变多个变量。

建议另开终端保存：

```bash
dmesg -w | grep --line-buffered -E \
  'RX_BOUNDS|BT_RX_BOUNDS|SITM_BOUNDS|Oops|panic|Undefined instruction|stall|watchdog|marlin|sprdwl'
```

若再次失联，保留从上电到故障后的原始 TTL，不要只截最后几行；记录 `date`、`uptime`、
Wi-Fi/蓝牙是否有负载、天线是否安装、供电方式及 HDMI/USB 连接状态。日志公开前必须删除
密码、NetworkManager profile、token、私钥及不必要的设备标识。
