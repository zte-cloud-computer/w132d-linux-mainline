# W132D 刷写包

适用于 RK3528 / UWE5621DS 的 ZTE W132D。需要 Python 3.9+。Linux amd64、Linux arm64、macOS arm64 使用包内维护版 rkdeveloptool，不需要自行编译或安装另一版本。

| 文件 | 用途 |
|---|---|
| `flash-manifest.json` | 版本、布局、保留区间、组件大小和 SHA256 |
| `image-head.bin`、`image-system.bin` | 直接切取自已校验的原生 Armbian 镜像，避开设备保留区间 |
| `loader.bin` | 按锁定来源生成的 Rockchip USB loader |
| `flash.sh`、`flash.ps1`、`flash.py` | 共用的校验、模式切换、写入、完整回读逻辑 |
| `tools/<platform>/` | 对应平台二进制、来源记录、许可证和源码 |

先在 Release 页面核对下载包 SHA256，完整解压后：

```sh
chmod +x flash.sh tools/*/rkdeveloptool
./flash.sh --dry-run
# Linux needs USB access, usually through sudo
sudo ./flash.sh
# macOS
./flash.sh
```

设备断电，按住 HDMI 旁 Reset 针孔，同时上电并用数据线直连电脑，约五秒后松开。只连接一台 Rockchip 设备。脚本会确认后替换系统，保留清单中的 vendor storage / RKSS 区间；先备份个人数据和原厂恢复材料。

脚本在写入前校验引导组件的尺寸、偏移、摘要和设备容量。成功输出 `FLASH_OK` 后等待首次启动扩容。校验或回读失败会报错并停止，不会自动重启。`--verify-only` 只回读，需要本包 loader 已运行。恢复方式与完整说明见源码归档的 `docs/recovery.md`。

Windows 使用 Python 3 和兼容命令行工具：

```powershell
powershell -ExecutionPolicy Bypass -File flash.ps1 --tool C:\Tools\rkdeveloptool.exe
```

Windows USB 实机验证尚未完成。图形工具 RKDevTool 不兼容 `--tool`；不要用单一整盘文件的旧刷写命令写入这个分段包。新 GPT 在镜像末尾的备份表由 Armbian 首次启动流程移动到实际设备末尾。
