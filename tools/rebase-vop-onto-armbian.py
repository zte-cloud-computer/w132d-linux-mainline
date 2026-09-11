#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""把 RK3528 的 VOP2 支持（patches/0008）重锚到 Armbian 补丁栈之上。

用法:
  rebase-vop-onto-armbian.py <linux-tree-root>
  rebase-vop-onto-armbian.py <rockchip_drm_vop2.h> <rockchip_vop2_reg.c>

Armbian 补丁栈（rk3562-0010）引入了 RK3562 VOP2 支持，在 rockchip_drm_vop2.h 中添加了
VOP_VERSION_RK3562，并在 rockchip_vop2_reg.c 的 vop2_dt_match[] 中插入了 rk3562-vop。
本脚本将 RK3528 的 VOP2 支持重锚到包含 RK3562 的最新上游上下文。
"""
import os
import sys


def sub(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit(f"❌ {what}：期望 1 处匹配，实际 {n} 处 —— Armbian 的补丁变了")
    return text.replace(old, new)


VOP2_CODE = """
static unsigned long rk3528_set_intf_mux(struct vop2_video_port *vp, int id, u32 polflags)
{
	struct vop2 *vop2 = vp->vop2;
	unsigned long clock;
	u32 dip;

	clock = rk3568_set_intf_mux(vp, id, polflags);
	if (!clock)
		return 0;

	/* The HDMI controller samples the pixel data on the inverted dclk */
	if (id == ROCKCHIP_VOP2_EP_HDMI0) {
		dip = vop2_readl(vop2, RK3568_DSP_IF_POL);
		dip |= RK3568_DSP_IF_POL__HDMI_DCLK_POL;
		vop2_writel(vop2, RK3568_DSP_IF_POL, dip);
	}

	return clock;
}

/*
 * The overlay of the RK3528 is laid out like the RK3576 one, but the
 * port assignment and the delay of the windows live in the OVL_SYS block
 * instead of the window registers.
 */
static void rk3528_vop2_setup_overlay(struct vop2_video_port *vp)
{
	struct vop2 *vop2 = vp->vop2;
	struct drm_crtc *crtc = &vp->crtc;
	struct drm_plane *plane;
	u32 port_sel;

	vp->win_mask = 0;
	port_sel = vop2_readl(vop2, RK3528_OVL_SYS_PORT_SEL_IMD);

	drm_atomic_crtc_for_each_plane(plane, crtc) {
		struct vop2_win *win = to_vop2_win(plane);

		vp->win_mask |= BIT(win->data->phys_id);

		if (vop2_cluster_window(win))
			vop2_setup_cluster_alpha(vop2, win);

		switch (win->data->phys_id) {
		case ROCKCHIP_VOP2_CLUSTER0:
			port_sel &= ~RK3528_OVL_SYS_PORT_SEL_IMD__CLUSTER0;
			port_sel |= FIELD_PREP(RK3528_OVL_SYS_PORT_SEL_IMD__CLUSTER0, vp->id);
			vop2_writel(vop2, RK3528_OVL_SYS_CLUSTER0_CTRL, 0);
			break;
		case ROCKCHIP_VOP2_ESMART0:
			port_sel &= ~RK3528_OVL_SYS_PORT_SEL_IMD__ESMART0;
			port_sel |= FIELD_PREP(RK3528_OVL_SYS_PORT_SEL_IMD__ESMART0, vp->id);
			vop2_writel(vop2, RK3528_OVL_SYS_ESMART0_CTRL, 0);
			break;
		}
	}

	if (!vp->win_mask)
		return;

	vop2_writel(vop2, RK3528_OVL_SYS_PORT_SEL_IMD, port_sel);
	rk3576_vop2_setup_layer_mixer(vp);
	vop2_setup_alpha(vp);
}

static const struct vop2_ops rk3528_vop_ops = {
	.setup_intf_mux = rk3528_set_intf_mux,
	.setup_bg_dly = rk3576_vop2_setup_bg_dly,
	.setup_overlay = rk3528_vop2_setup_overlay,
};

static const struct vop2_video_port_data rk3528_vop_video_ports[] = {
	{
		.id = 0,
		.feature = VOP2_VP_FEATURE_OUTPUT_10BIT,
		.max_output = { 4096, 4096 },
		/* win layer_mix hdr */
		.pre_scan_max_dly = { 8, 6, 2, 0 },
		.offset = 0xc00,
		.pixel_rate = 1,
	},
};

/*
 * rk3528 vop with 1 cluster and 4 esmart win, VP0 drives HDMI and VP1 the
 * CVBS encoder. Only VP0 with Esmart0 and Cluster0 is described for now.
 *
 * AXI config::
 *
 * * Cluster0 win0: 0x2, 0x3
 * * Cluster0 win1: 0x4, 0x5
 * * Esmart0:       0x6, 0x7
 */
static const struct vop2_win_data rk3528_vop_win_data[] = {
	{
		.name = "Esmart0-win0",
		.phys_id = ROCKCHIP_VOP2_ESMART0,
		.base = 0x1800,
		.possible_vp_mask = BIT(0),
		.formats = formats_rk356x_esmart,
		.nformats = ARRAY_SIZE(formats_rk356x_esmart),
		.format_modifiers = format_modifiers,
		.layer_sel_id = { 1, 0xf, 0xf, 0xf },
		.supported_rotations = DRM_MODE_REFLECT_Y,
		.type = DRM_PLANE_TYPE_PRIMARY,
		.axi_yrgb_r_id = 6,
		.axi_uv_r_id = 7,
		.max_upscale_factor = 8,
		.max_downscale_factor = 8,
	}, {
		.name = "Cluster0-win0",
		.phys_id = ROCKCHIP_VOP2_CLUSTER0,
		.base = 0x1000,
		.possible_vp_mask = BIT(0),
		.formats = formats_cluster,
		.nformats = ARRAY_SIZE(formats_cluster),
		.format_modifiers = format_modifiers,
		.layer_sel_id = { 0, 0xf, 0xf, 0xf },
		.supported_rotations = DRM_MODE_REFLECT_X | DRM_MODE_REFLECT_Y,
		.type = DRM_PLANE_TYPE_OVERLAY,
		.axi_yrgb_r_id = 2,
		.axi_uv_r_id = 3,
		.max_upscale_factor = 4,
		.max_downscale_factor = 4,
		.feature = WIN_FEATURE_CLUSTER,
	},
};

static const struct vop2_data rk3528_vop = {
	.version = VOP_VERSION_RK3528,
	.nr_vps = 1,
	.max_input = { 4096, 4096 },
	.max_output = { 4096, 4096 },
	.vp = rk3528_vop_video_ports,
	.win = rk3528_vop_win_data,
	.win_size = ARRAY_SIZE(rk3528_vop_win_data),
	.cluster_reg = rk3576_vop_cluster_regs,
	.nr_cluster_regs = ARRAY_SIZE(rk3576_vop_cluster_regs),
	.smart_reg = rk3568_vop_smart_regs,
	.nr_smart_regs = ARRAY_SIZE(rk3568_vop_smart_regs),
	.ops = &rk3528_vop_ops,
	.soc_id = 3528,
};
"""


def rebase_vop(h_path, c_path):
    with open(h_path, encoding="utf-8") as f:
        orig_h = f.read()

    with open(c_path, encoding="utf-8") as f:
        orig_c = f.read()

    # 1. 内存中变换 rockchip_drm_vop2.h
    new_h = orig_h
    h_already_ok = (
        "VOP_VERSION_RK3528\tVOP2_VERSION(0x50, 0x17, 0x4334)" in new_h
        and "RK3528_OVL_SYS_PORT_SEL_IMD" in new_h
        and "RK3568_DSP_IF_POL__HDMI_DCLK_POL" in new_h
        and "RK3528_OVL_SYS_PORT_SEL_IMD__ESMART0" in new_h
    )

    if not h_already_ok:
        # 版本号：若带有旧版 0x1263 则更新为硬件读数 0x4334，否则注入
        if "#define VOP_VERSION_RK3528\tVOP2_VERSION(0x50, 0x17, 0x1263)" in new_h:
            new_h = new_h.replace(
                "#define VOP_VERSION_RK3528\tVOP2_VERSION(0x50, 0x17, 0x1263)",
                "#define VOP_VERSION_RK3528\tVOP2_VERSION(0x50, 0x17, 0x4334)",
            )
        elif "#define VOP_VERSION_RK3528\tVOP2_VERSION(0x50, 0x17, 0x4334)" not in new_h:
            anchor_3562 = "#define VOP_VERSION_RK3562\tVOP2_VERSION(0x50, 0x17, 0x4350)"
            anchor_mainline = "#define VOP_VERSION_RK3576\tVOP2_VERSION(0x50, 0x19, 0x9765)"
            if anchor_3562 in new_h:
                new_h = sub(new_h, anchor_3562, "#define VOP_VERSION_RK3528\tVOP2_VERSION(0x50, 0x17, 0x4334)\n" + anchor_3562, "注入 VOP_VERSION_RK3528")
            elif anchor_mainline in new_h:
                new_h = sub(new_h, anchor_mainline, "#define VOP_VERSION_RK3528\tVOP2_VERSION(0x50, 0x17, 0x4334)\n" + anchor_mainline, "注入 VOP_VERSION_RK3528")
            else:
                sys.exit("❌ 注入 VOP_VERSION_RK3528 失败：未找到 RK3562 或 RK3576 版本宏锚点")

        # 寄存器定义
        if "#define RK3528_OVL_SYS_PORT_SEL_IMD" not in new_h:
            old_reg = "#define RK3576_SYS_EXTRA_ALPHA_CTRL\t\t0x500\n"
            new_reg = (
                old_reg +
                "#define RK3528_OVL_SYS_PORT_SEL_IMD\t\t0x504\n"
                "#define RK3528_OVL_SYS_CLUSTER0_CTRL\t\t0x510\n"
                "#define RK3528_OVL_SYS_ESMART0_CTRL\t\t0x520\n"
            )
            new_h = sub(new_h, old_reg, new_reg, "注入 RK3528 OVL_SYS 寄存器宏")

        # HDMI DCLK 极性定义
        if "#define RK3568_DSP_IF_POL__HDMI_DCLK_POL" not in new_h:
            old_pol = "#define RK3568_DSP_IF_POL__HDMI_PIN_POL\t\t\tGENMASK(7, 4)\n"
            new_pol = old_pol + "#define RK3568_DSP_IF_POL__HDMI_DCLK_POL\t\tBIT(7)\n"
            new_h = sub(new_h, old_pol, new_pol, "注入 HDMI_DCLK_POL 宏")

        # 位域定义
        if "#define RK3528_OVL_SYS_PORT_SEL_IMD__ESMART0" not in new_h:
            old_inv = "#define POLFLAG_DCLK_INV\tBIT(3)\n"
            new_inv = (
                old_inv + "\n"
                "#define RK3528_OVL_SYS_PORT_SEL_IMD__ESMART0\t\tGENMASK(17, 16)\n"
                "#define RK3528_OVL_SYS_PORT_SEL_IMD__CLUSTER0\t\tGENMASK(1, 0)\n"
                "#define RK3528_OVL_SYS_CLUSTER0_CTRL__DLY_NUM\t\tGENMASK(15, 0)\n"
                "#define RK3528_OVL_SYS_ESMART0_CTRL__DLY_NUM\t\tGENMASK(7, 0)\n"
            )
            new_h = sub(new_h, old_inv, new_inv, "注入 RK3528 OVL_SYS 位域宏")

    # 2. 内存中变换 rockchip_vop2_reg.c
    new_c = orig_c
    ops_present = "rk3528_vop_ops" in new_c
    match_present = "rockchip,rk3528-vop" in new_c

    if not ops_present:
        anchor_ops = """static const struct vop2_ops rk3588_vop_ops = {
\t.setup_intf_mux = rk3588_set_intf_mux,
\t.setup_bg_dly = rk3568_vop2_setup_bg_dly,
\t.setup_overlay = rk3568_vop2_setup_overlay,
};
"""
        new_c = sub(new_c, anchor_ops, anchor_ops + VOP2_CODE, "注入 rk3528 VOP2 函数及结构体")

    if not match_present:
        anchor_match_3562 = '\t{\n\t\t.compatible = "rockchip,rk3562-vop",'
        anchor_match_3566 = '\t{\n\t\t.compatible = "rockchip,rk3566-vop",'
        replacement_entry = '\t{\n\t\t.compatible = "rockchip,rk3528-vop",\n\t\t.data = &rk3528_vop,\n\t}, {\n'
        if anchor_match_3562 in new_c:
            new_c = sub(new_c, anchor_match_3562, replacement_entry + '\t\t.compatible = "rockchip,rk3562-vop",', "注入 rockchip,rk3528-vop compatible 条目")
        elif anchor_match_3566 in new_c:
            new_c = sub(new_c, anchor_match_3566, replacement_entry + '\t\t.compatible = "rockchip,rk3566-vop",', "注入 rockchip,rk3528-vop compatible 条目（主线基线）")
        else:
            sys.exit("❌ 注入 rockchip,rk3528-vop compatible 条目失败：未找到 RK3562 或 RK3566 of_device_id 锚点")

    # 3. 校验并统一写回（保证原子性，任何前序失败绝不写入磁盘）
    if new_h == orig_h and new_c == orig_c:
        print("  ✅ vop2：RK3528 驱动代码与 compatible 条目均已在位")
        return

    if new_h != orig_h:
        with open(h_path, "w", encoding="utf-8") as f:
            f.write(new_h)
    if new_c != orig_c:
        with open(c_path, "w", encoding="utf-8") as f:
            f.write(new_c)

    print("  ✅ vop2：改动已叠到 Armbian 补丁栈之上")


def main():
    if len(sys.argv) == 2:
        root = sys.argv[1]
        if os.path.isdir(root):
            h_path = os.path.join(root, "drivers/gpu/drm/rockchip/rockchip_drm_vop2.h")
            c_path = os.path.join(root, "drivers/gpu/drm/rockchip/rockchip_vop2_reg.c")
        else:
            sys.exit(f"❌ 路径不是目录：{root}")
    elif len(sys.argv) == 3:
        h_path = sys.argv[1]
        c_path = sys.argv[2]
    else:
        sys.exit(f"用法: {sys.argv[0]} <linux-tree-root> 或 <rockchip_drm_vop2.h> <rockchip_vop2_reg.c>")

    if not os.path.isfile(h_path):
        sys.exit(f"❌ 找不到文件：{h_path}")
    if not os.path.isfile(c_path):
        sys.exit(f"❌ 找不到文件：{c_path}")

    rebase_vop(h_path, c_path)


if __name__ == "__main__":
    main()
