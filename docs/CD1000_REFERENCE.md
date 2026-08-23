# CD1000 参考说明

我们审阅了公开的 ophub CD1000 文件，将其作为 RK3528 寄存器和启动布局参考。它们属于 vendor 6.1 材料，不能直接作为 W132D 设备树使用。

## 可用于交叉检查的内容

- eMMC 描述在 `ffbf0000`。
- SDIO 主机描述在 `ffc10000` 和 `ffc20000`。
- 控制台 UART 基地址是 `0xff9f0000`，与 W132D 一致。
- CD1000 启动流程通过 U-Boot 的 `booti` 路径加载 `Image`、`uInitrd` 和板级 DTB。

## 不要直接复制

CD1000 DTS 使用 vendor binding，并为电源、存储、USB、无线和多媒体设备定义了板级 GPIO。尤其是其 SDIO 主机和无线 GPIO 分配与已测试的 W132D 接线不同。把这些节点复制到 W132D 主线 DTS 中，可能得到看似合理但未经验证的硬件描述。

因此，W132D 主线板级文件只保留已验证的 eMMC、UART、RMII 网口、USB 主机和 UWE5622 SDIO 路径。任何未来多媒体工作都必须脱离这个干净基线单独开发，并以 W132D 实测结果和已审阅的上游 binding 为基础。

## 来源参考

对照使用的是 ophub/`amlogic-s9xxx-armbian` 提交 `e149eed6693b7cd2920ff189060cc98e0537c719`。本仓库只保存这些说明，不保存 CD1000 vendor 镜像、启动 blob 或固件。

---

# CD1000 Reference Notes

The public ophub CD1000 files were reviewed as a RK3528 register and boot layout reference. They are vendor 6.1 material and are not a drop-in W132D device tree.

## Useful Cross-Checks

- eMMC is described at `ffbf0000`.
- SDIO hosts are described at `ffc10000` and `ffc20000`.
- The console UART base is `0xff9f0000`, matching W132D.
- The CD1000 boot flow loads `Image`, `uInitrd`, and a board DTB through U-Boot's `booti` path.

## Do Not Copy Directly

The CD1000 DTS uses vendor bindings and board-specific GPIOs for its power, storage, USB, wireless, and multimedia devices. In particular, its SDIO host and wireless GPIO assignments differ from the tested W132D wiring. Copying those nodes into the W132D mainline DTS would create a plausible-looking but unvalidated hardware description.

The W132D mainline board file therefore keeps only the validated eMMC, UART, RMII Ethernet, USB host, and UWE5622 SDIO paths. Any future multimedia work must be developed separately from this clean baseline and must be based on W132D measurements and reviewed upstream bindings.

## Source Reference

The comparison used ophub/`amlogic-s9xxx-armbian` commit `e149eed6693b7cd2920ff189060cc98e0537c719`. The repository stores only these notes, not the CD1000 vendor image, boot blobs, or firmware.
