# 维护备忘

## 补丁维护与防漂

自己带补丁就会漂，三层机制，第三层是唯一能真正终结漂移的：

1. **补丁维护成 git 提交**（`tools/make-patch-series.sh`）：把 `patches/` 里的源补丁 `git am` 到内核树上
   （DTS 做成最后一个提交），由 `git format-patch` 同时产出投 LKML 的补丁和 Armbian 补丁目录的内容
   （`--on-armbian`：基线是纯净内核 + Armbian 的 rockchip64 补丁栈）。rebase 到新内核时 git 直接指出哪个
   hunk 冲突。`userpatches/kernel/archive/rockchip64-7.2/w132d-0NNN-*` 是生成物，勿手改；
   `w132d-armbian-NNNN-*` 是只针对 Armbian 补丁栈的手工补丁，脚本不清理。
2. **对下一个内核干跑**（`tools/check-drift.sh 7.2.2 7.3-rc1`）：fuzz 当预警不当通过，且必须真编一次 DTB——
   只测补丁会漏掉上游 dtsi 自己变了这一类漂移（实例：主线 7.2 自带 `usb2phy` 节点，与旧 DTS 的 `u2phy`
   对不上，补丁全绿但 dtc 报 label not found）。
3. **逐个投主线**，投进一个少一个。

Armbian 构建代码里两处漂移点，补丁干跑测不出来：
- `driver_uwe5622()` 只对 `5.15 ≤ 内核 < 7.3` 加入无线驱动。edge 提到 7.3 的那天 Wi-Fi/蓝牙模块会无声消失，
  `verify-debs.sh` 查 `sprdwl_ng.ko` 在不在。
- extlinux 的生成在 `distro-agnostic.sh` 与 `partitioning.sh` 两处，`verify-image.sh` 逐行核对。

## CI 与设备更新

`build-packages.yml` 用 armbian/build 的 `main` 构建 deb 包（内核三件套、U-Boot、bsp），`push` / 每周一 /
手动触发，产物先过 `tools/verify-debs.sh`；每周与手动 `publish` 发成 GitHub Release。不产整盘镜像
（要 `--privileged`）。每次都是全新 runner、Armbian 与内核都取 HEAD，构建成功与否本身就是漂移检测。

版本号 `26.11.0-trunk.<日期>.<运行序号>`：Armbian 的 VERSION 固定不变，apt 看不到升级，要追加单调递增后缀
（经 `REVISION=` 传入）。

本板内核包与 Armbian 官方**同名**（family 共用内核），官方那份没有本板 DTB 与补丁。bsp 包带
`/etc/apt/preferences.d/w132d-kernel`，禁止从 apt.armbian.com 取这三个包；没有它，官方版本号追上来的那天
`apt upgrade` 会把设备打死。补丁进了 armbian/build 之后这条 pin 和整个自建构建都可以退役。

设备上安装顺序：dtb → image → bsp。下一步：把 Release 里的包做成签名的 apt 源。

## 提 Armbian PR 前要改的形态

- `extensions/w132d-uboot.sh` 的钩子并进 `config/boards/w132d.csc`
- `overlay/bsp-cli/` 搬到 `config/optional/boards/w132d/_packages/bsp-cli/`
- Wi-Fi 固件先投 `armbian/firmware`，板子指向包里的文件（他们不会接受构建时从第三方仓库下载）
- `custom_kernel_config__w132d` 的改动进家族共用的 `linux-rockchip64-edge.config`
- `w132d-armbian-0004`（pmdomain）改回主线语义这件事单独开 issue 说明

## 踩过的坑

- **U-Boot 别开 `CONFIG_NET`**：开了之后 Linux 起不来（U-Boot proper 活着、针孔能进 MaskROM、内核从没挂过根），
  去掉立刻正常。MAC 注入不需要它。
- **U-Boot 的 env 别放进 eMMC，除非写完整的一份**：`env_relocate()` 只在存储的 env 无效时才载入编进二进制的
  默认环境，读到一份只有 `ethaddr` 的合法 env 就没有 `bootcmd`，停在提示符；`CONFIG_ENV_APPEND` 救不了
  （它只是 `H_NOCLEAR`）。真要预置 env 用 `make u-boot-initial-env` + `mkenvimage` 写完整一份，且每次刷 U-Boot
  都得重写。
- **binman 的 `u-boot-rockchip.bin` 不能从扇区 64 一路 dd**：中间 0xff 填充到 16384，会抹掉还在的 vendor
  storage。扩展里的 `write_uboot_platform` 分两段写。
- **U-Boot DT 里 blob 版本要在 `post_family_config` 里设**：家族配置是 `${DDR_BLOB:-默认}`，
  `extension_prepare_config` 跑在其后，放那里只剩默认值。`CONFIG_OF_LIST` 要和 `DEFAULT_DEVICE_TREE` 一起改。
- **"内核有没有挂过根"的无串口判据**：`dd skip=1073154 count=2`（p3 的 ext4 超级块）与镜像比，一样就是没挂过。
- **Wi-Fi 固件**：Armbian 包自带的 `wcnmodem-38222.bin`（W21.03.3）扫描正常但一关联就 CP2 断言；旁边的
  `wcnmodem.bin` 是 SC2355 的；出厂 W25.45.3 在新驱动上其实是好的，但没有公开来源。测吞吐要 `--interface wlan0`
  绑接口并用接口字节计数证明，否则测的是百兆有线。
- **bsp 包的 deb 缓存**：`output/packages-hashed/` 里的旧包会被复用，改了 overlay 要删 `armbian-bsp-cli-w132d*`。
- **`custom_kernel_config` 钩子**要在 `.config` 存在性检查之前追加 `kernel_config_modifying_hashes`，否则内核永远不重编。
- **构建容器里没有 `strings` / `xxd`**：校验脚本用 `grep -a` 和 `od`。
- **rkdeveloptool `db` 在 Loader 模式下会被拒**，只有 MaskROM 才需要；原厂 loader 大批量读写后会崩成 Maskrom。
- **RK3528 的 VOP IOMMU 寄存器被 VOP 自动门控挡住**：`SYS_AUTO_GATING_CTRL`（0xff840008）复位值 0x9fffffff，
  这时读 0xff847e00（vop_mmu）总线直接卡死（CPU 对 NMI 都不响应，只有硬件看门狗能救）。而 IOMMU 是通过
  device link 在 VOP 驱动 probe **之前**被 runtime resume 的，所以驱动没有机会先清门控。厂商内核用私有属性
  `rockchip,disable-device-link-resume` 绕开，主线没有对应物 —— 板级 DTS 里 VOP 干脆不挂 IOMMU，扫描输出走 CMA
  （128 MB，1440p 一帧 14.7 MB）。VOP 版本寄存器实测 0x50174334，厂商头文件里的 0x1263 是错的。
- **没有串口时怎么抓"加载驱动就挂死"**：systemd 已把 DesignWare 看门狗设为 89 s，硬挂后自动复位且 DRAM 保留，
  `console=ttyS0` 之外 ramoops 也注册成 console，所以复位后 `/sys/fs/pstore/console-ramoops-0` 就是上一次的完整
  内核输出；先 `echo 8 > /proc/sys/kernel/printk`、给 `drivers/base/dd.c`、`component.c`、`base/power/*` 开
  dyndbg，再 `echo MARK > /dev/kmsg` 后 modprobe，就能看到卡在哪个设备的哪一步。排查期间把内建驱动改成模块
  （`custom_kernel_config`）并用 `/etc/modprobe.d` 黑名单，开机永远安全，一次挂死只损失一次 SSH。
- **MaskROM 会话下设备是离线的**（网线要拔），扫段扫不到不代表没开机；面板绿灯慢闪 = 用户态在跑、有单元失败。
  bootfs 是 FAT，`rkdeveloptool rl 24576 1048576` 读回后用 mtools 改 `extlinux.conf` / 换 DTB 再 `wl` 回去，
  不用重刷整盘；rootfs 用 `debugfs -c` 只读取证（头 4 GiB 就够拿到 /etc 和 journal）。
- **HDMI 音频要把 SAI3 的时隙钉成 32 位**：DesignWare HDMI 的 I2S 接收器要 64×fs 的位时钟，而主线 rockchip_sai
  默认把时隙宽度收成采样宽度，16 位素材就变成 32×fs，驱动侧全部正常（流在跑、N/CTS 对、EDID 有音频）但电视静音；
  32 位素材能响就是这个原因。板级 DTS 的 `hdmi_sound` cpu 节点加 `dai-tdm-slot-num = <2>; dai-tdm-slot-width = <32>;`。
  排查时别被 `MC_CLKDIS` 骗：AUDCLK 是 bit3（0x08），bit2 是 PREP 时钟。
- **unisocwifi 的密钥槽只有 4 个，但路由器开 PMF 时 IGTK 装在 index 4**：原驱动直接越界写进 key_len/mgmt_reg，
  表现为 FORTIFY 的 `field-spanning write ... (size 0)` 告警；只加边界检查会让每次 PMF 关联在组握手阶段断开
  （`GROUP_HANDSHAKE -> DISCONNECTED`），必须把槽扩到 6 个（w132d-armbian-0006）。
- **在 Wi‑Fi 会话里别跑 `wpa_cli reassociate`**：这台路由器会回 ASSOC_REJECT，之后 wpa_supplicant 退避几十分钟，
  没有有线就只能断电。
- **别把旧 Image 和新模块混装**：同版本号（7.2.3-edge-rockchip64）但不同构建的 Image 与 `/lib/modules`
  混用时所有模块 `Invalid argument`，sshd 也起不来；`dpkg -i` 时 glob 匹配到多个 deb 会按字母序装、后者覆盖前者。
