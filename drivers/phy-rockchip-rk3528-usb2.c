// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal RK3528 USB2 host PHY for W132D mainline bring-up.
 *
 * The upstream 7.1 generic Rockchip USB2 PHY driver does not yet contain
 * RK3528 register data. Keep this experiment separate from that driver.
 */

#include <linux/bitops.h>
#include <linux/clk.h>
#include <linux/clk-provider.h>
#include <linux/io.h>
#include <linux/kernel.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/phy/phy.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/reset.h>

#define RK3528_PHY_SUS_OTG 0x004c
#define RK3528_PHY_SUS_HOST 0x005c
#define RK3528_PHY_CLKOUT 0x041c
#define RK3528_PHY_OTG_TUNE 0x0030
#define RK3528_PHY_HOST_TUNE 0x0430
#define RK3528_PHY_TX_SELECT 0x0094

struct rk3528_usb2phy;

struct rk3528_usb2phy_port {
	struct rk3528_usb2phy *parent;
	unsigned int suspend_offset;
	u32 suspend_value;
};

struct rk3528_usb2phy {
	void __iomem *base;
	struct regmap *grf;
	struct clk_bulk_data *clks;
	int num_clks;
	struct reset_control *reset;
	struct phy *host;
	struct phy *otg;
	struct rk3528_usb2phy_port host_port;
	struct rk3528_usb2phy_port otg_port;
	struct clk_hw clk480m_hw;
};

static void rk3528_usb2phy_disable_clks(void *data)
{
	struct rk3528_usb2phy *phy = data;

	clk_bulk_disable_unprepare(phy->num_clks, phy->clks);
}

static void rk3528_usb2phy_update(struct rk3528_usb2phy *phy,
					  unsigned int offset, u32 mask, u32 value)
{
	u32 reg = readl(phy->base + offset);

	reg &= ~mask;
	reg |= value & mask;
	writel(reg, phy->base + offset);
}

static void rk3528_usb2phy_tune(struct rk3528_usb2phy *phy)
{
	/* Values match the vendor RK3528 USB2 PHY initialization. */
	rk3528_usb2phy_update(phy, RK3528_PHY_OTG_TUNE, BIT(2), 0);
	rk3528_usb2phy_update(phy, RK3528_PHY_HOST_TUNE, BIT(2), 0);
	rk3528_usb2phy_update(phy, RK3528_PHY_OTG_TUNE, GENMASK(6, 4), 0);
	rk3528_usb2phy_update(phy, RK3528_PHY_HOST_TUNE, GENMASK(6, 4), 0);
	rk3528_usb2phy_update(phy, RK3528_PHY_TX_SELECT, GENMASK(6, 3), 0x18);
}

static int rk3528_usb2phy_grf_write(struct rk3528_usb2phy *phy,
					     unsigned int offset, unsigned int value)
{
	/* Rockchip GRF writes carry the write-enable mask in bits 31:16. */
	return regmap_write(phy->grf, offset, (GENMASK(8, 0) << 16) | value);
}

static int rk3528_usb2phy_power_on(struct phy *generic)
{
	struct rk3528_usb2phy_port *port = phy_get_drvdata(generic);

	return rk3528_usb2phy_grf_write(port->parent, port->suspend_offset,
					   0x1d1);
}

static int rk3528_usb2phy_power_off(struct phy *generic)
{
	struct rk3528_usb2phy_port *port = phy_get_drvdata(generic);

	return rk3528_usb2phy_grf_write(port->parent, port->suspend_offset,
					   port->suspend_value);
}

static const struct phy_ops rk3528_usb2phy_ops = {
	.power_on = rk3528_usb2phy_power_on,
	.power_off = rk3528_usb2phy_power_off,
	.owner = THIS_MODULE,
};

static int rk3528_usb2phy_clk_prepare(struct clk_hw *hw)
{
	struct rk3528_usb2phy *phy = container_of(hw, struct rk3528_usb2phy,
							  clk480m_hw);

	rk3528_usb2phy_update(phy, RK3528_PHY_CLKOUT, GENMASK(7, 2), 0x9c);
	return 0;
}

static void rk3528_usb2phy_clk_unprepare(struct clk_hw *hw)
{
	struct rk3528_usb2phy *phy = container_of(hw, struct rk3528_usb2phy,
							  clk480m_hw);

	rk3528_usb2phy_update(phy, RK3528_PHY_CLKOUT, GENMASK(7, 2), 0);
}

static int rk3528_usb2phy_clk_is_prepared(struct clk_hw *hw)
{
	struct rk3528_usb2phy *phy = container_of(hw, struct rk3528_usb2phy,
							  clk480m_hw);

	return (readl(phy->base + RK3528_PHY_CLKOUT) & GENMASK(7, 2)) == 0x9c;
}

static unsigned long rk3528_usb2phy_clk_recalc_rate(struct clk_hw *hw,
							    unsigned long parent_rate)
{
	return 480000000;
}

static const struct clk_ops rk3528_usb2phy_clk_ops = {
	.prepare = rk3528_usb2phy_clk_prepare,
	.unprepare = rk3528_usb2phy_clk_unprepare,
	.is_prepared = rk3528_usb2phy_clk_is_prepared,
	.recalc_rate = rk3528_usb2phy_clk_recalc_rate,
};

static int rk3528_usb2phy_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *child_np;
	struct rk3528_usb2phy *phy;
	struct phy_provider *provider;
	struct resource *res;
	struct clk_init_data init = {};
	int ret;

	phy = devm_kzalloc(dev, sizeof(*phy), GFP_KERNEL);
	if (!phy)
		return -ENOMEM;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	phy->base = devm_ioremap_resource(dev, res);
	if (IS_ERR(phy->base))
		return PTR_ERR(phy->base);

	phy->grf = syscon_regmap_lookup_by_phandle(dev->of_node,
						  "rockchip,usbgrf");
	if (IS_ERR(phy->grf))
		return dev_err_probe(dev, PTR_ERR(phy->grf),
				     "failed to locate RK3528 GRF\n");

	phy->num_clks = devm_clk_bulk_get_all(dev, &phy->clks);
	if (phy->num_clks < 0)
		return dev_err_probe(dev, phy->num_clks,
				     "failed to get PHY clocks\n");
	ret = clk_bulk_prepare_enable(phy->num_clks, phy->clks);
	if (ret)
		return dev_err_probe(dev, ret, "failed to enable PHY clocks\n");
	ret = devm_add_action_or_reset(dev, rk3528_usb2phy_disable_clks, phy);
	if (ret)
		return ret;

	phy->reset = devm_reset_control_get_optional_exclusive(dev, "phy");
	if (IS_ERR(phy->reset))
		return PTR_ERR(phy->reset);
	if (phy->reset) {
		ret = reset_control_deassert(phy->reset);
		if (ret)
			return ret;
	}

	rk3528_usb2phy_tune(phy);
	init.name = "clk_usbphy_480m";
	init.ops = &rk3528_usb2phy_clk_ops;
	phy->clk480m_hw.init = &init;
	ret = devm_clk_hw_register(dev, &phy->clk480m_hw);
	if (ret)
		return ret;
	ret = devm_of_clk_add_hw_provider(dev, of_clk_hw_simple_get,
					  &phy->clk480m_hw);
	if (ret)
		return ret;

	child_np = of_get_child_by_name(dev->of_node, "host-port");
	if (!child_np)
		return dev_err_probe(dev, -ENODEV, "missing host-port\n");
	phy->host = devm_phy_create(dev, child_np, &rk3528_usb2phy_ops);
	of_node_put(child_np);
	if (IS_ERR(phy->host))
		return PTR_ERR(phy->host);
	phy->host_port.parent = phy;
	phy->host_port.suspend_offset = RK3528_PHY_SUS_HOST;
	phy->host_port.suspend_value = 0x1d2;
	phy_set_drvdata(phy->host, &phy->host_port);

	child_np = of_get_child_by_name(dev->of_node, "otg-port");
	if (!child_np)
		return dev_err_probe(dev, -ENODEV, "missing otg-port\n");
	phy->otg = devm_phy_create(dev, child_np, &rk3528_usb2phy_ops);
	of_node_put(child_np);
	if (IS_ERR(phy->otg))
		return PTR_ERR(phy->otg);
	phy->otg_port.parent = phy;
	phy->otg_port.suspend_offset = RK3528_PHY_SUS_OTG;
	phy->otg_port.suspend_value = 0;
	phy_set_drvdata(phy->otg, &phy->otg_port);

	provider = devm_of_phy_provider_register(dev, of_phy_simple_xlate);
	return PTR_ERR_OR_ZERO(provider);
}

static const struct of_device_id rk3528_usb2phy_of_match[] = {
	{ .compatible = "zte,rk3528-usb2phy" },
	{ }
};
MODULE_DEVICE_TABLE(of, rk3528_usb2phy_of_match);

static struct platform_driver rk3528_usb2phy_driver = {
	.probe = rk3528_usb2phy_probe,
	.driver = {
		.name = "zte-rk3528-usb2phy",
		.of_match_table = rk3528_usb2phy_of_match,
	},
};
module_platform_driver(rk3528_usb2phy_driver);

MODULE_DESCRIPTION("W132D RK3528 USB2 host PHY bring-up driver");
MODULE_LICENSE("GPL");
