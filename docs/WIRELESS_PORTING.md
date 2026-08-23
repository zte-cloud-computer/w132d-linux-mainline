# W132D UWE5622 wireless port

The W132D uses a Unisoc UWE5622 Marlin controller. Wi-Fi and Bluetooth share
the RK3528 SDIO1 host; the Bluetooth data path is exposed as a tty by the WCN
driver and is initialized by the userspace HCI helper.

## Board wiring

| Signal | W132D connection |
| --- | --- |
| SDIO host | RK3528 `mmc@ffc20000` (`sdio1`), 4-bit, non-removable |
| WCN power/reset | GPIO3_A2 |
| SDIO data IRQ | GPIO3_A3 |
| Bluetooth enable | GPIO3_A4 |
| Bluetooth wake-host | GPIO3_C1 |

The GPIO polarity and timing in `board/rk3528-w132d.dts` are based on the
tested W132D vendor description. The CD1000 reference GPIOs must not be copied
to this board.

## Source staging

`scripts/prepare_wireless_mainline_wsl.sh` archives these exact commits into a
private staging directory and does not copy firmware:

- `KryptonLee/uwe5621ds-aml` at `0c12c46df48da9592abc7848335482e68d23e28a`;
- `CoreELEC/uwe5631-aml` at `08165b5d56f46b569ee6461d7082ff795efafb2e`.

The staging directory defaults to `/root/w132d-build/w132d-wireless-mainline`
and can be changed with `W132D_WIRELESS_STAGE`. It must remain below
`W132D_BUILD_ROOT`.

## Build order

Run the following from a root WSL2 shell after preparing the Linux v7.1 tree:

```bash
bash scripts/prepare_wireless_mainline_wsl.sh
bash scripts/build_wireless_mainline_wsl.sh
```

The build helper applies the public compatibility patches to temporary copies
of the upstream sources, then builds:

- `uwe5622_bsp_sdio.ko`;
- `sprdwl_ng.ko`;
- `sprdbt_tty.ko`;
- `w132d-btattach`.

It also builds the required Linux wireless, Bluetooth, crypto, and rfkill
modules against the same kernel `Module.symvers`.

## Image integration

The complete-image helper installs modules under
`lib/modules/<kernel-release>/updates/uwe5622`, adds the systemd wireless and
Bluetooth units, and extracts the required firmware from a user-owned Android
vendor image into a private staging directory. Firmware, calibration data,
MAC addresses, and generated modules are excluded from Git.

## Hardware acceptance

Test in this order:

1. confirm SDIO enumeration and WCN power-on in `dmesg`;
2. load the WCN and Wi-Fi modules and scan/connect;
3. load the Bluetooth tty module and start `w132d-btattach`;
4. verify a BlueZ controller and scan for nearby devices.

If SDIO timeouts or a system hang occur, stop at that stage and capture the
serial log before changing GPIO or power sequencing.
