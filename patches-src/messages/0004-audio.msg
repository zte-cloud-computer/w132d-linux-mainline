ASoC: rockchip: add the RK3528 audio codec and the ES7202 PDM ADC

The RK3528 has an on-chip DAC-only audio codec ("acodec") and boards
commonly pair it with an Everest ES7202 analogue-microphone-to-PDM
bridge for capture.  Neither driver exists in mainline.

Both drivers are taken from the GPL-2.0 Rockchip BSP
(armbian/linux-rockchip, rk-6.1-rkr5).  The changes here are limited to
6.1 -> 7.x API adaptation:

  - of_gpio.h was removed in 6.15; both drivers only use the gpiod_*
    descriptor API, so include linux/gpio/consumer.h instead
  - SND_SOC_DAIFMT_CBS_CFS / CBM_CFM were dropped after 6.7; use the
    clock-provider naming (CBC_CFC / CBP_CFP)
  - platform_driver::remove returns void since 6.11

Register sequences, timings and default values are unchanged.

Tested on a ZTE Cloud Computer W132D (RK3528): 3.5 mm playback through
the on-chip codec and headset-microphone capture through the ES7202 both
work.
