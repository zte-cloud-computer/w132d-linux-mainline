# W132D USB 刷写包

适用于 RK3528 / UWE5621DS 的 ZTE W132D。刷写会替换系统和分区表，请先备份数据并保存原厂恢复材料。

## 准备

主机需要 Python 3.9+。Linux amd64、Linux arm64、macOS arm64 使用包内 rkdeveloptool。先核对同一 Release 的 `SHA256SUMS` 中 `w132d-flash.zip` 摘要，再完整解压。

| 文件 | 用途 |
|---|---|
| `flash-manifest.json` | 版本、布局、保留区间、组件大小和摘要 |
| `image-head.bin`、`image-system.bin` | 按设备保留区间拆分的镜像 |
| `loader.bin` | 发布配套 USB loader |
| `flash.sh`、`flash.ps1`、`flash.py` | 刷写入口 |
| `tools/<platform>/` | 平台工具、来源记录、许可证和源码 |

在解压目录执行：

```sh
chmod +x flash.sh tools/*/rkdeveloptool
./flash.sh --dry-run
```

`FLASH_DRY_RUN_OK` 表示文件检查通过，不访问 USB。

## 刷写

1. 设备断电，按住 HDMI 旁 Reset 针孔按键。
2. 保持按住，接通电源并用 USB 数据线直连电脑，约五秒后松开。只连接一台 Rockchip 设备。
3. 执行对应平台命令，按提示输入 `yes`。

```sh
# Linux
sudo ./flash.sh
# macOS
./flash.sh
```

脚本自动处理 Loader / MaskROM，加载配套 loader 后写入并完整回读，保留 vendor storage / RKSS 区间。出现 `FLASH_OK` 后设备自动重启；首次启动保持供电，等待分区扩容和账户初始化。

失败时不会自动重启。检查连接和供电后重新进入下载模式，使用同一完整包重试。请使用配套脚本处理分段镜像。

## 只读回读

```sh
sudo ./flash.sh --verify-only
```

仅比较已写入数据，不写入或重启。需要本包 loader 已在设备上运行；该选项不会切换模式或加载 loader。

## Windows

需自行准备 Python 3.9+、Rockchip USB 驱动及兼容的命令行 `rkdeveloptool.exe`。该路径尚未确认实机兼容性。

```powershell
powershell -ExecutionPolicy Bypass -File flash.ps1 --dry-run --tool C:\Tools\rkdeveloptool.exe
powershell -ExecutionPolicy Bypass -File flash.ps1 --tool C:\Tools\rkdeveloptool.exe
```

图形版 RKDevTool 无法作为 `--tool` 使用。

完整安装与故障说明见[项目文档](https://github.com/zte-cloud-computer/w132d-linux-mainline#文档)，与版本对应的文档包含在 Release 源码归档中。
