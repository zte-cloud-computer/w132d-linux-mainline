# W132D 主线状态

## 本快照范围

本分支记录硬件验证阶段之后的 Linux v7.1 主线 bring-up。目标是在暂时保留已验证 vendor SPL/U-Boot 作为启动链的前提下，替代 vendor 内核。

本快照刻意禁用了显示路径。显示移植已暂停，其实验代码、补丁、设备树节点和启动参数均不属于 `main`。

## 硬件矩阵

| 设备 | 结果 | 备注 |
| --- | --- | --- |
| eMMC | 通过 | 3.3 V MMC High-Speed 模式，限制为 52 MHz |
| USB2 | 通过 | GM8220S hub 复位保持 deasserted |
| USB3 | 通过 | 仅主机模式的 DWC3 路径，使用 RK3528 combo PHY |
| 有线网口 | 通过 | RK3528 集成 RMII MACPHY |
| Wi-Fi | 通过 | UWE5622 经 SDIO1，扫描和连接均已测试 |
| 蓝牙 | 通过 | UWE5622 tty-over-SDIO 加用户态 HCI 配置 |
| 3.5mm 音频 | 放弃 | 不再计划适配 |
| 红外 | 放弃 | 不再计划适配 |
| 显示输出 | 延后 | 在有审查过的 RK3528 主线方案前保持禁用 |

## 主线文件

- `board/rk3528-w132d.dts` 只描述已验证的存储、网络、USB、控制台和无线路径。
- `scripts/prepare_mainline_kernel_wsl.sh` 应用 USB 修复、更新蓝牙命令兼容性，并禁用显示相关内核选项。
- `scripts/build_wireless_mainline_wsl.sh` 针对 Linux v7.1 构建 WCN、Wi-Fi、蓝牙和 HCI 辅助组件。
- `scripts/assemble_mainline_image_wsl.sh` 使用私有启动/rootfs/固件输入创建完整镜像，不导出原始分区。

## 已知边界

- 未包含主线 U-Boot 支持；已验证的 vendor 启动 blob 仍是私有构建输入。
- 不再分发 UWE5622 固件和校准数据。
- 3.5mm 音频和红外明确不在项目范围内。
- Git 中不提交镜像。硬件测试必须使用本地组装镜像和正常 RKDevTool 流程。

## 重新验证清单

内核或 DTS 变更后，按以下顺序测试：

1. 串口控制台和 eMMC 根文件系统；
2. USB2 和 USB3 枚举；
3. 有线网口链路和 DHCP；
4. Wi-Fi 扫描和连接；
5. 蓝牙控制器创建和发现设备。

显示移植暂停期间，不要向本分支添加显示节点或启动模式。显示工作应从单独的实验分支或本地研究历史继续。

---

# W132D Mainline Status

## Scope of This Snapshot

This branch records the Linux v7.1 mainline bring-up after the hardware validation pass. The goal is to replace the vendor kernel while retaining the verified vendor SPL/U-Boot temporarily as the boot chain.

The display path is deliberately disabled in this snapshot. Display porting is paused and its experimental code, patches, device-tree nodes, and boot arguments are not part of `main`.

## Hardware Matrix

| Device | Result | Notes |
| --- | --- | --- |
| eMMC | Pass | 3.3 V MMC High-Speed mode, capped at 52 MHz |
| USB2 | Pass | GM8220S hub reset held deasserted |
| USB3 | Pass | Host-only DWC3 path with RK3528 combo PHY |
| Wired Ethernet | Pass | RK3528 integrated RMII MACPHY |
| Wi-Fi | Pass | UWE5622 over SDIO1; scan and connection tested |
| Bluetooth | Pass | UWE5622 tty-over-SDIO plus userspace HCI setup |
| 3.5 mm audio | Dropped | No further adaptation planned |
| Infrared | Dropped | No further adaptation planned |
| Display output | Deferred | Disabled until a reviewed RK3528 mainline path exists |

## Mainline Files

- `board/rk3528-w132d.dts` describes only the validated storage, network, USB, console, and wireless paths.
- `scripts/prepare_mainline_kernel_wsl.sh` applies the USB fixes, updates the Bluetooth command compatibility, and disables display-related kernel options.
- `scripts/build_wireless_mainline_wsl.sh` builds the WCN, Wi-Fi, Bluetooth, and HCI helper components against Linux v7.1.
- `scripts/assemble_mainline_image_wsl.sh` creates a complete image from private boot/rootfs/firmware inputs; it does not export raw partitions.

## Known Boundaries

- Mainline U-Boot support is not included; verified vendor boot blobs remain private build inputs.
- UWE5622 firmware and calibration data are not redistributed.
- 3.5 mm audio and infrared are intentionally outside the project scope.
- No image is committed to Git. Hardware testing must use a locally assembled image and the normal RKDevTool workflow.

## Revalidation Checklist

After a kernel or DTS change, test in this order:

1. serial console and eMMC rootfs;
2. USB2 and USB3 enumeration;
3. wired Ethernet link and DHCP;
4. Wi-Fi scan and connection;
5. Bluetooth controller creation and discovery.

Do not add display nodes or boot modes to this branch while the display port is paused. Continue the display work from a separate experimental branch or from the local research history.
