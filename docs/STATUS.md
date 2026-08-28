# Linux 7.1.10 stable baseline status

## Current snapshot (2026-08-23)

- The project target is a Linux v7.1.10 stable runtime; vendor SPL/U-Boot is
  retained only as a temporary private boot-chain input.
- The source baseline is stable commit
  `8d4e6356173a7b2e4a6a8ee1669060c33528fdb9`; the patch series and defconfig
  preparation complete from a clean v7.1.10 tree without fuzzy patch matches.
- eMMC, USB2, USB3, wired Ethernet, Wi-Fi, and Bluetooth are hardware-tested
  and must remain regression gates.
- eMMC HS400, TSADC thermal throttling, CPU DVFS, the Mali-450 GPU, RKVDEC,
  the analog audio path, the IR receiver, the panel LEDs, the watchdog, OP-TEE
  and ramoops are now described as well; see "Board hardware added on 7.1.10"
  below.
- HDMI is experimentally working on one 2K monitor at 2560x1440@60. The
  tested path uses the RK3528 RGB888/P888 output format and vendor-derived VP0
  delay values; multi-monitor, hotplug, suspend/resume, and long-run coverage
  remain open.
- The current boot templates keep kernel logs on TTL (`ttyS0`) and omit a
  forced `video=` mode so DRM can use EDID. This exact template combination
  still needs hardware confirmation; diagnostic mode arguments can be supplied
  with `W132D_MAINLINE_VIDEO_ARGS`.
- See `docs/HDMI_PORTING.md` for the consolidated HDMI history and known limits.

## Current snapshot (English)

- The project targets a Linux v7.1.10 stable runtime; vendor SPL/U-Boot remains
  only as a temporary private boot-chain input.
- The source baseline is stable commit
  `8d4e6356173a7b2e4a6a8ee1669060c33528fdb9`; patch and defconfig preparation
  complete from a clean v7.1.10 tree without fuzzy matches.
- eMMC, USB2, USB3, wired Ethernet, Wi-Fi, and Bluetooth are hardware-tested
  regression gates.
- eMMC HS400, TSADC thermal throttling, CPU DVFS, the Mali-450 GPU, RKVDEC,
  the analog audio path, the IR receiver, the panel LEDs, the watchdog, OP-TEE
  and ramoops are now described as well.
- HDMI is experimentally working on one 2K monitor at 2560x1440@60. The tested
  path uses RGB888/P888 output and vendor-derived VP0 delay values; multi-
  monitor, hotplug, suspend/resume, and long-run coverage remain open.
- Current boot templates keep kernel logs on TTL (`ttyS0`) and omit a forced
  `video=` mode so DRM can use EDID. This exact template combination still
  needs hardware confirmation; set `W132D_MAINLINE_VIDEO_ARGS` for diagnostics.
- See `docs/HDMI_PORTING.md` for the consolidated HDMI history and limits.

The sections below retain chronological build checkpoints from the bring-up;
later HDMI entries supersede the early baseline statements.

## Historical build checkpoint

- Linux v7.1 source commit: `8cd9520d35a6c38db6567e97dd93b1f11f185dc6`
- W132D DTB compile: passed
- ARM64 `Image` compile: passed
- Output files: `out/rk3528-w132d.dtb` (27,043 bytes) and `out/Image`
  (43,248,128 bytes)
- Artifact checks: ARM64 `Image` header `4d 5a 40 fa`; DTB magic `d0 0d fe ed`
- SHA-256: `Image` = `c81a57928c7ff17db9669c0cfb03f3a20f035e9c03ee2fef2a1ec2a33216c51f`;
  DTB = `7ccac759b9d73945fe4bbc1174d06bd544037184cff0c788c1fdcd2b8a2a52e9`
- Hardware boot test: not performed
- Armbian image: generated, not yet flashed or boot-tested
- Image: `out/images/w132d-mainline-armbian-20260821-123019-UTC+8.img`
- Image SHA-256: `f64eb6a37a702d7c428c9e22bcc4e8e380232aa31f92adab932e7fb90c3acd19`
- Image layout: GPT; vendor boot blobs at sectors 64 and 16384; 512 MiB FAT32
  bootfs at sectors 24576-1073151; ext4 rootfs from sector 1073152
- Image boot files: mainline `Image`, `rk3528-w132d.dtb`, `boot.scr`, and
  `extlinux.conf`; no initrd is required by the current defconfig
- Rootfs: copied from the existing Armbian/Debian trixie minimal build; its
  fstab was rewritten to the image root UUID and `serial-getty@ttyS0` was
  enabled for the first console test
- Offline checks: GPT verification passed; bootfs is FAT32 label `BOOTFS`;
  rootfs is ext4 label `ROOTFS` with UUID
  `b9d1a0d9-6a3b-4db8-9d7a-2b1b6c11e721`; boot files were readable from the
  bootfs image
- Bring-up finding: the first image reached the mainline kernel but the eMMC
  card was not enumerated. The log showed the RK3528 DWCMShc warning
  `Can't reduce the clock below 52MHz in HS200/HS400 mode` followed by
  `unknown-block(0,0)`. The W132D DTS now avoids HS200 and caps eMMC at 52 MHz
  until the 1.8 V regulator/DLL path is described correctly.
- New image after eMMC fix:
  `out/images/w132d-mainline-armbian-20260821-133452-UTC+8.img`
- New image SHA-256:
  `0119549cf938ab0d2574a51e6ac75faff3ee82642c574a572c81cc47625c56aa`
- Armbian board metadata: draft only; `rk35xx-mainline` is not registered in an
  Armbian checkout yet
- CD1000 reference review: completed; reference DTB is vendor 6.1, not a
  drop-in mainline DTS

## Historical: 2026-08-21 HDMI pause and wireless preparation

- HDMI remains unavailable. The controller probes, but the DRM log reports
  `Cannot find any crtc or sizes` and the connector remains
  `card0-HDMI-A-1/status=disconnected`. The current VOP/HDMI/PHY compatibles
  are an experimental fallback, not native RK3528 support; HDMI work is paused.
- USB3 is confirmed working on the latest tested image.
- WiFi and Bluetooth preparation has started in `docs/WIRELESS_PORTING.md`.
  The old vendor 6.1 UWE5622 modules cannot be loaded by Linux 7.1. The next
  implementation step is an out-of-tree port of the BSP, `sprdwl_ng`, and
  `sprdbt_tty`, followed by a separately validated SDIO1/GPIO DTS change.
- No new image was generated for this documentation-only checkpoint.
- A read-only wireless staging helper is available at
  `scripts/prepare_wireless_mainline_wsl.sh`; it archives the exact research
  commits under a private WSL staging directory and leaves DTS/config/images
  untouched.

The image is an experimental bring-up artifact. It has not been tested on the
physical W132D. HDMI, USB, Wi-Fi, Bluetooth, GPU, VPU, and automatic rootfs
expansion are intentionally out of scope for this first boot test.

## Board hardware added on 7.1.10

Every item below was brought up on the physical W132D.  Register addresses,
interrupts and clock topologies come from this machine's own vendor DTB, with
the vendor BSP clock/reset IDs re-mapped onto mainline
`rockchip,rk3528-cru.h` numbering.

| Block | Kernel change | Device tree |
| --- | --- | --- |
| eMMC HS400 + CQE | `patches/rk3528-dwcmshc-hs400-7.1.patch` (RK3528 DLL taps 6/6/3) | `&sdhci` HS200/HS400/ES/`supports-cqe`, 200 MHz |
| Watchdog | none, `snps,dw-wdt` already matches | `watchdog@ffac0000` |
| TSADC + thermal zone | `patches/rk3528-tsadc-7.1.patch` | `tsadc@ffad0000`, `soc-thermal` 95/110/120 C |
| CPU DVFS | none | `vdd_cpu` PWM regulator, `cpu-supply`, four vendor OPPs from 408 MHz |
| Mali-450 | none, Lima already matches `arm,mali-450` | `vdd_logic` PWM regulator, `mali-supply`, `&gpu status = "okay"` |
| RKVDEC | `patches/rk3528-rkvdec-7.1.patch` | `video-codec@ff740000`, `iommu@ff740800`, `sram@fe480000` |
| Audio | `patches/rk3528-audio-7.1.patch` (RK3528 codec, ES7202, SAI match) | `sai@ffb90000`, `acodec@ffe10000`, `pdm@ffbb0000`, ES7202 on i2c2, two simple-audio-cards |
| IR receiver | none | `gpio-ir-receiver` on GPIO4_C6 |
| Panel LEDs | none | `gpio-leds`, modern `color`/`function` bindings |
| OP-TEE | none | `/firmware/optee` |
| Crash storage | none | `ramoops@110000`, 896 KiB |

Two constraints are easy to get wrong and are documented in the DTS itself:

- `pwm-dutycycle-range = <100 0>` is mandatory on both PWM regulators.  The
  mainline `pwm-rockchip` inverted-polarity handling runs the opposite way from
  the vendor kernel, so a verbatim copy of the vendor description maps a high
  voltage request onto a low duty cycle.
- The LED nodes must not carry a `label` property: `leds-gpio` only passes an
  fwnode to the LED core when a child has no label, and `linux,default-trigger`
  is only read from that fwnode.

## Confirmed in Linux v7.1.10

- RK3528 common device tree and pinctrl definitions
- Cortex-A53 CPU/PSCI and SCMI clock description
- RK3528 eMMC controller (`sdhci` at `ffbf0000`)
- RK3528 SDIO controllers
- RK3528 internal RMII MACPHY (`gmac0` at `ffbd0000`)
- RK3528 Mali-450 compatible GPU node and VOP2 version definitions
- CD1000 confirms the RK3528 controller address map, but not W132D wiring
- Mainline defconfig includes Lima and Rockchip DRM as modules; the RK3528 GPU
  node remains disabled in the W132D DTS pending bring-up

## Historical baseline limitations

The following list describes the initial baseline and is retained for
chronology. It is superseded by the later HDMI/VOP and wireless checkpoints.

- W132D board DTS (mainline baseline exists, hardware validation pending)
- W132D-specific power/reset GPIO definitions
- HDMI/VOP2 board wiring for this device
- RK3528 VOP2/HDMI mainline binding and glue support (generic DRM code exists,
  but RK3528 is absent from the v7.1.10 match tables)
- USB host controller nodes for this RK3528 v7.1.10 DTS baseline
- Unisoc UWE5622 SDIO/WCN support in mainline
- W132D mainline U-Boot support

The pending hardware validation and peripheral support items are independent
blockers. A mainline kernel DTB can be
compiled before they are solved, but a successful DTB build must not be
described as a usable desktop image.

## Initial hardware assumptions (historical)

The first DTS uses only facts already observed on the vendor image:

- 2 GiB RAM
- eMMC on `sdhci`, 8-bit, non-removable, 1.8 V HS200
- UART0 at `ttyS0`, 115200 baud
- on-chip RMII MACPHY on `gmac0`

The initial DTS leaves Wi-Fi, Bluetooth, HDMI, USB, infrared, and dynamic DDR
scaling out of the description until there is a mainline binding and a board
measurement to support them.

## HDMI porting checkpoint (2026-08-22)

- The project now carries a RK3528 INNO HDMI PHY backport and a minimal RK3528 DesignWare HDMI glue match.
- The adapted PHY, glue, DTB, and ARM64 Image compile successfully.
- Mainline 7.1 uses the older VOP2 data model and lacks RK3528 register/window/VP descriptors. Vendor 6.1 uses a newer VOP3 data model, so this remains the main blocker before CRTC/HPD/EDID hardware testing.

## HDMI/VOP minimal descriptor checkpoint (2026-08-22)

- Added `patches/rk3528-vop2-minimal-7.1.patch` and applied it from the mainline preparation script.
- Mainline VOP2 now has a `rockchip,rk3528-vop` match with one VP0 and one Cluster0 primary plane. This removes the previous RK3568-only fallback and is intended to establish a native RK3528 CRTC bring-up path.
- The descriptor is intentionally incomplete. RK3528 OVL system/port mux registers, ESMART windows, HDR, VP1, and final clock/timing behavior still require translation from the vendor reference.
- The current experimental ops write the RK3528 overlay mux at `0x504` and VP0 background delay at `0x670`; this is enough to test the CRTC path but is not yet a complete modeset implementation.
- `out/Image` and `out/rk3528-w132d.dtb` compile successfully. No complete image was generated in this checkpoint.
- Hardware validation required: confirm CRTC/connector creation first; then test HPD/EDID and modes in the order 1920x1080@60, 2560x1440, hotplug.

Current tested hardware scope remains: USB2, USB3, wired Ethernet, WiFi, and Bluetooth pass. 3.5 mm audio and infrared are abandoned. The project target is to replace the vendor kernel with a mainline kernel; vendor SPL/U-Boot may remain temporarily as the boot chain.

## HDMI resource-description retry (2026-08-22)

- The hotplug capture showed that HDMI and VOP components bound, but no HPD or
  EDID event appeared and the connector stayed disconnected.
- The W132D DTS now also describes the RK3528 vendor-reference HDMI resources:
  the second HDMI register window, the wakeup interrupt, the `dclk_vp0`
  pixel-clock input, DDC SCL timing, and `rockchip,cts-manual`. The VOP node
  includes the RK3528 ACM register window as a third resource.
- Recompiled `out/Image` and `out/rk3528-w132d.dtb` successfully and assembled
  the complete test image:
  `out/images/w132d-mainline-armbian-20260822-124755-UTC+8.img`.
- This is a targeted hardware test only. It does not prove HDMI output is
  fixed; the next test should capture connector status and live HPD/EDID logs
  while inserting and removing the cable.

## HDMI RGB888 and VP0-delay experiment (2026-08-23)

- The accepted no-HDMI image is retained as the control baseline.
- The HDMI path now follows the vendor RK3528 output format (`P888`/RGB888)
  instead of the earlier forced `AAAA` mode.
- The RK3528 vendor VP0 delay tuple is carried into the mainline descriptor as
  `{ 8, 6, 2, 16 }` (window, layer mix, HDR mix, combined pre-scan delay).
- Complete test image:
  `out/images/w132d-mainline-armbian-hdmi-rgb888-20260823-120428-UTC+8.img`.
- This image is an HDMI pipeline-format/timing experiment at 2560x1440@60;
  it does not change the verified USB, Ethernet, Wi-Fi, or Bluetooth paths.

## HDMI EDID and serial-console image (2026-08-23)

- Removed `console=tty0`, so kernel logs are routed only to the TTL console.
  The userspace tty1 login service remains enabled.
- Removed the default `video=` mode override; DRM now chooses the mode from
  the connected display's EDID unless a diagnostic build explicitly supplies
  `W132D_MAINLINE_VIDEO_ARGS`.
- Complete image:
  `out/images/w132d-mainline-armbian-hdmi-edid-serial-20260823-122700-UTC+8.img`.
- Historical images are no longer deleted by the assembly script.
