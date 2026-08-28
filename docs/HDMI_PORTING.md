# W132D HDMI Porting Notes

This document records the RK3528 HDMI work carried out against the Linux v7.1.10
mainline tree. It is a bring-up record, not a claim that the implementation is
ready for upstream submission.

## Hardware result

The RGB888/VOP timing build was tested on a ZTE W132D with one 2560x1440
monitor at 60 Hz. The image was reported stable without the earlier whole-screen
flicker. The follow-up image removes the forced mode and the DRM console output;
that combination still needs hardware confirmation.

The following paths remain verified independently and must not regress:

- eMMC root filesystem;
- USB2 and USB3 host ports;
- integrated RMII Ethernet;
- UWE5622 Wi-Fi and Bluetooth.

3.5 mm audio and infrared are outside the adaptation scope.

## What was changed

### Board description and HPD

`board/rk3528-w132d.dts` describes a W132D-specific display graph:

- VP0 VOP output connected to the RK3528 DesignWare HDMI input;
- RK3528 INNO HDMI PHY at `0xffe00000`;
- HDMI controller at `0xff8d0000` with its second GRF/GPIO register window;
- the `dclk_vp0` pixel clock exported by the PHY;
- DDC SCL timing and `rockchip,cts-manual`;
- GPIO0_A2 as the physical HPD input, with a board-local pin group that keeps
  PA2 as GPIO while selecting the HDMI CEC/SCL/SDA pins;
- the wakeup interrupt and the VO-GRF sink-detect path.

The glue mirrors the GPIO HPD level into the RK3528 VO-GRF sink-detect bit and
generates DRM hotplug events. This was needed because the generic HDMI pinctrl
group otherwise muxed PA2 away from the GPIO consumer.

### INNO HDMI PHY

`drivers/phy-rockchip-inno-hdmi-phy.c` is a Linux v7.1.10 API adaptation of the
Rockchip INNO PHY implementation. The preparation script copies it into the
kernel tree and applies the RK3528-specific changes:

- 241.5 MHz PLL entry for 2560x1440 CVT-RB at 60 Hz;
- reset of a PHY left running by U-Boot before Linux takes ownership;
- the RK3528 PHY clock is synchronized with the VOP/HDMI modeset path.

The repository does not contain vendor boot firmware, Android images, PHY
calibration blobs, or WCN firmware.

### HDMI glue and VOP

The HDMI glue adds the RK3528 compatible match and the HPD/GRF handling to the
generic DesignWare driver. The VOP work is deliberately a compatibility layer,
not a wholesale copy of the vendor VOP3 driver:

- native `rockchip,rk3528-vop` matching in the v7.1.10 VOP2 driver;
- VP0 and Cluster0 primary-plane bring-up;
- RK3528 overlay port/layer mixer register offsets;
- RK3528 cluster format, CSC, scaler, and AXI ID fields;
- HDMI dclk polarity and single-clock ownership;
- vendor-derived VP0 delay tuple `{ 8, 6, 2, 16 }`;
- HDMI output mode `ROCKCHIP_OUT_MODE_P888` (RGB888), replacing the earlier
  forced `ROCKCHIP_OUT_MODE_AAAA` path.

The last two changes are the format/timing correction associated with the
stable 2560x1440 test result.

## Patch application

`scripts/prepare_mainline_kernel_wsl.sh` applies the patches in dependency
order. HDMI work is enabled by default and can be disabled for a control build:

```bash
export W132D_MAINLINE_DIR=/path/to/w132d-armbian-port-repo
export W132D_MAINLINE_KERNEL_DIR=/root/w132d-build/linux-v7.1.10
export W132D_ENABLE_HDMI=1
bash scripts/build_mainline_kernel_wsl.sh
```

The HDMI patch set is project-local and should be reviewed against the pinned
Linux v7.1.10 base commit before proposing any upstream submission.

## Runtime checks

Use TTL for kernel diagnostics:

```sh
cat /proc/cmdline
dmesg -wH | grep --line-buffered -iE \
  'RK3528|hdmi|drm|vop|hpd|edid|crtc|plane|phy|clk'
cat /sys/class/drm/card0-HDMI-A-1/status
cat /sys/class/drm/card0-HDMI-A-1/modes
test -s /sys/class/drm/card0-HDMI-A-1/edid && hexdump -C /sys/class/drm/card0-HDMI-A-1/edid
```

The production-oriented boot templates omit both `console=tty0` and `video=`:
kernel logs stay on `ttyS0`, and DRM may select the monitor's EDID preferred
mode. A diagnostic build can set `W132D_MAINLINE_VIDEO_ARGS` explicitly.

## Open work

- translate the remaining RK3528 VOP3 data into a complete mainline VOP model;
- validate more monitors and refresh rates;
- test HDMI hotplug, suspend/resume, and repeated power cycles;
- review PHY analog drive values and frame timing if those tests expose errors;
- separate the project-local bring-up patches into upstreamable changes.
