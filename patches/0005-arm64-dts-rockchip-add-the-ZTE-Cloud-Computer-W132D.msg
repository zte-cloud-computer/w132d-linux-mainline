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

The display path is deliberately left out: mainline has no RK3528 VOP2
or HDMI support yet, so there is nothing for those nodes to bind to.

Tested on the board itself.
