# 升级与通道

新镜像默认启用 Pages `stable`，禁用 `experimental` 并将它的 APT 优先级设为 -1。两者都验证 BSP 包附带的公钥。没有通过全部发布门禁的新候选不会进入 stable。

```sh
sudo apt update
sudo apt upgrade
sudo reboot
```

APT 更新正式版本的内核、DTB、headers、libc-dev、U-Boot 和 BSP，以及 Debian 自身的用户空间更新。它不会将整盘镜像重写到设备，也不会改变分区布局。每个正式发布镜像和该次项目包来自同一锁定版本；镜像实际安装的软件列表随 Release 提供。

内核包精确依赖相同版本的 DTB。APT pin 允许项目签名仓库的配套包，排除其他源的同类内核；不要删除该规则或手工混装内核与 DTB。

## 显式选择 experimental

```sh
sudo w132d-channel experimental
sudo apt upgrade
sudo reboot
```

实验通道以 main 推送产生的内核包为主，不保证每次同时有新镜像、U-Boot 或 BSP。实验镜像安装的版本可以比 stable 新，但默认仍只跟随 stable；需要主动执行上述命令才能持续接收 main 内核。

## 返回 stable

```sh
sudo w132d-channel stable
sudo apt upgrade
```

关闭 experimental 后不会自动降级已经安装的实验包，等待正式版追上即可。需要立即回退时显式允许降级：

```sh
sudo w132d-channel stable --downgrade
sudo reboot
```

该命令仅对已经安装的项目包选择 stable 版本，APT 会显示拟进行的事务。执行前确认稳定仓库可访问，并保留可刷写的恢复包。通道脚本会先验证源和 pin 配置；手工修改导致规则不唯一时会报错，要求先整理配置，不擅自覆盖。

BSP 的 `/etc` 配置作为 dpkg conffile 管理，升级时保留管理员修改。服务位于 `/usr/lib/systemd/system`，个性化修改使用 `/etc/systemd/system/<unit>.d/`。版本可用 `dpkg-query -W 'linux-*edge-rockchip64' 'armbian-bsp-cli-w132d-edge'` 检查。

本体系不提供旧实验镜像的源迁移。旧 GitHub Release `apt` 入口不会接收本体系的新包。
