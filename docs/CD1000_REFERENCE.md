# CD1000 reference notes

The public ophub CD1000 files were reviewed as a RK3528 register and boot
layout reference. They are vendor 6.1 material and are not a drop-in W132D
device tree.

## Useful cross-checks

- eMMC is described at `ffbf0000`.
- SDIO hosts are described at `ffc10000` and `ffc20000`.
- The console UART base is `0xff9f0000`, matching W132D.
- The CD1000 boot flow loads `Image`, `uInitrd`, and a board DTB through
  U-Boot's `booti` path.

## Do not copy directly

The CD1000 DTS uses vendor bindings and board-specific GPIOs for its power,
storage, USB, wireless, and multimedia devices. In particular, its SDIO host
and wireless GPIO assignments differ from the tested W132D wiring. Copying
those nodes into the W132D mainline DTS would create a plausible-looking but
unvalidated hardware description.

The W132D mainline board file therefore keeps only the validated eMMC, UART,
RMII Ethernet, USB host, and UWE5622 SDIO paths. Any future multimedia work
must be developed separately from this clean baseline and must be based on
W132D measurements and reviewed upstream bindings.

## Source reference

The comparison used ophub/`amlogic-s9xxx-armbian` commit
`e149eed6693b7cd2920ff189060cc98e0537c719`. The repository stores only these
notes, not the CD1000 vendor image, boot blobs, or firmware.
