arm64: dts: rockchip: add the ZTE Cloud Computer W132D

The W132D is an RK3528-based set-top box with 1 GB of DDR4, 8 GB of eMMC,
100 Mbit Ethernet, a UWE5622 SDIO Wi-Fi/Bluetooth combo, a 3.5 mm
headset jack, an infrared receiver and a bi-colour panel LED.

Describe the parts that work with mainline drivers: eMMC at HS400 with
enhanced strobe, USB 2.0 and USB 3.0 host, Ethernet, the SDIO Wi-Fi
slot, CPU and GPU DVFS with their PWM regulators, the SoC thermal zone,
the video decoder, the on-chip audio codec with the ES7202 capture path,
the infrared receiver, the panel LEDs, OP-TEE and a pstore/ramoops
region.

The display path (VOP2, DesignWare HDMI, Innosilicon PHY) and the SAI
feeding HDMI audio are described in the board file for now, together
with the other SoC blocks that rk3528.dtsi does not have yet. Hot-plug
uses the GPIO0_A2 workaround the RK3528 needs, so the HDMI pin group
keeps that pin as a GPIO.

Tested on the board itself.
