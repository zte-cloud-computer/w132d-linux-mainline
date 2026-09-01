media: rkvdec: add RK3528 support

The RK3528 ships the VDPU382 decoder.  Rockchip's own BSP drives it with
the same dev_ops, trans_info and hw_info as the RK3588's VDPU381: the
register count (279), enable register (10), format register (9) and
return-status register (224) all match field for field.  The only
difference in the BSP is hw_ops->reset, which exists for the BSP's
multi-core scheduling; the mainline driver has no reset_control at all.

Point the RK3528 compatible at the existing vdpu381 variant.

Tested on a ZTE Cloud Computer W132D (RK3528): H.264 and HEVC decode
produce frame-for-frame identical output to software decoding.
