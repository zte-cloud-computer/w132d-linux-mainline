# 升级与通道

新安装系统默认使用签名的 stable APT 源。升级前备份应用数据和配置，并保留可用版本的完整刷写包。

## 日常升级

```sh
sudo apt update
sudo apt upgrade
sudo reboot
```

项目源提供内核、DTB、headers、libc-dev、U-Boot 和 BSP 更新；Debian 源提供用户空间软件更新。APT 升级不重写整盘镜像或改变分区布局。

内核包精确依赖同版本 DTB。镜像预置公钥和 APT pin 规则，确保安装项目源的配套包；请保留这些规则，避免混用其他来源的板级内核或 DTB。

查看已安装的项目包：

```sh
dpkg-query -W 'linux-*edge-rockchip64' 'linux-u-boot-w132d-edge' 'armbian-bsp-cli-w132d-edge'
```

## 选择通道

| 通道 | 内容 | 默认启用 |
|---|---|---|
| stable | 正式镜像及配套软件包 | 是 |
| experimental | main 构建的内核包，完整镜像按需提供 | 否 |

启用 experimental：

```sh
sudo w132d-channel experimental
sudo apt upgrade
sudo reboot
```

通道命令会更新 APT 索引。experimental 不保证每次同时提供新镜像、U-Boot 或 BSP。实验镜像默认仍跟随 stable，持续接收 main 更新需要显式切换。

## 返回 stable

```sh
sudo w132d-channel stable
sudo apt upgrade
```

切回 stable 不会自动降级已安装的实验包；可以等待正式版本追上。需要立即安装 stable 中的版本时：

```sh
sudo w132d-channel stable --downgrade
sudo reboot
```

该命令仅为已安装的项目包选择 stable 版本。确认 APT 显示的事务后继续，应用和数据不会因通道切换自动回退。手工修改过源或 pin 规则时，若脚本提示规则不唯一，请先检查配置。

## 配置保留与迁移

板级配置位于 `/etc`，升级按 dpkg 配置文件规则保留管理员修改。服务调整方式见[日常使用](usage.md#服务与配置)。

旧实验镜像和旧 Release `apt` 源需要[重新安装](install.md#旧系统迁移)。fnOS 仅提供整镜像更新，不使用上述内核 APT 升级流程。
