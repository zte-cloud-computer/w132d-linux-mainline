// SPDX-License-Identifier: GPL-2.0
/*
 * Unisoc UWE5621DS (Marlin3E firmware) Bluetooth as a Bluetooth HCI device.
 *
 * The vendor design exposes the SDIO HCI channel as /dev/ttyBT0 and expects
 * userspace to push the vendor initialisation commands (pskey 0xFCA0, RF
 * parameters 0xFCA2, enable 0xFCA1) and then attach the H4 line discipline.
 * Upstream drivers for SDIO combo chips (btmtksdio, btmrvl_sdio) register an
 * hci_dev directly and do the vendor initialisation in hdev->setup(); this
 * file does the same on top of the marlin SDIO transport in tty.c, so the
 * controller shows up as hci0 as soon as the module is loaded and BlueZ needs
 * nothing board specific.
 *
 * The pskey and RF tables are the Marlin3E defaults used by the vendor
 * userspace on this class of chips; they are not per-board calibration data.
 * The firmware reports its own BD address (derived from the chip's MAC, it
 * ignores the address bytes in the pskey), so nothing has to be stored on
 * the host.  A "local-bd-address" property on the sprd,mtty node is still
 * honoured for the pskey in case a device ever comes up without one.
 */

#include <linux/delay.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/skbuff.h>
#include <linux/slab.h>
#include <net/bluetooth/bluetooth.h>
#include <net/bluetooth/hci_core.h>

#include <marlin_platform.h>
#include "tty.h"
#include "hci.h"

#define SPRD_HCI_PSKEY		0xfca0
#define SPRD_HCI_ENABLE		0xfca1
#define SPRD_HCI_RF_PARA	0xfca2

#define SPRD_PSKEY_LEN		176
#define SPRD_RF_PARA_LEN	252

struct sprd_hci {
	struct hci_dev *hdev;
	struct device *dev;
	/* RX reassembly: one HCI packet may span SDIO blocks, one block may hold several */
	struct sk_buff *rx_skb;
	unsigned int rx_hdr_len;
	unsigned int rx_want;
	bdaddr_t bdaddr;
};

static struct sprd_hci *sprd_hci;

/* ---- vendor parameter blocks ------------------------------------------- */

struct sprd_buf {
	u8 *data;
	unsigned int len;
	unsigned int cap;
	bool failed;
};

static void put_u8(struct sprd_buf *b, u8 v)
{
	if (b->len >= b->cap) {
		b->failed = true;
		return;
	}
	b->data[b->len++] = v;
}

static void put_u16(struct sprd_buf *b, u16 v)
{
	put_u8(b, v & 0xff);
	put_u8(b, v >> 8);
}

static void put_u32(struct sprd_buf *b, u32 v)
{
	put_u16(b, v & 0xffff);
	put_u16(b, v >> 16);
}

static void put_u16s(struct sprd_buf *b, const u16 *v, unsigned int n)
{
	while (n--)
		put_u16(b, *v++);
}

static void put_u32s(struct sprd_buf *b, const u32 *v, unsigned int n)
{
	while (n--)
		put_u32(b, *v++);
}

static void put_zero_u32s(struct sprd_buf *b, unsigned int n)
{
	while (n--)
		put_u32(b, 0);
}

static unsigned int sprd_build_pskey(u8 *out, unsigned int cap, const bdaddr_t *ba)
{
	static const u8 feature_set[16] = {
		0xbf, 0xff, 0x8d, 0xfe, 0xdb, 0x3d, 0x7b, 0x87,
		0xff, 0xa7, 0xff, 0x7f, 0x00, 0xe0, 0xf7, 0x3e,
	};
	static const u16 coex_threshold[8] = {
		0x04e2, 0x1f40, 0x0020, 0x00c8, 0x0006, 0x0000, 0x0000, 0x0000,
	};
	struct sprd_buf b = { .data = out, .cap = cap };
	int i;

	put_u32(&b, 0x001f00);
	for (i = 0; i < 16; i++)
		put_u8(&b, feature_set[i]);
	for (i = 0; i < 6; i++)		/* little-endian, same order as bdaddr_t */
		put_u8(&b, ba->b[i]);
	put_u16(&b, 0x01ec);
	put_u8(&b, 1);			/* UART communication supported */
	put_u8(&b, 1);			/* CP2 log mode */
	put_u8(&b, 0xff);		/* log level */
	put_u8(&b, 0);			/* central/peripheral */
	put_u16(&b, 0xffff);		/* log mask */
	put_u8(&b, 0);			/* super SSP */
	put_u8(&b, 0);			/* common RFU byte */
	put_zero_u32s(&b, 8);		/* common, LE, LMP and LC RFU words */
	put_u16(&b, 0x0000);
	put_u16(&b, 0x1855);
	put_u16(&b, 0x0000);
	put_u16(&b, 0x1855);
	put_u8(&b, 0);			/* SCO transmit mode */
	put_u8(&b, 0);
	put_u8(&b, 0);
	put_u8(&b, 0);
	put_zero_u32s(&b, 2);
	put_u8(&b, 1);			/* standby sleep */
	put_u8(&b, 1);			/* master sleep */
	put_u8(&b, 1);			/* slave sleep */
	put_u8(&b, 0);
	put_zero_u32s(&b, 2);
	put_u32(&b, 40);		/* receive window extension */
	put_u8(&b, 6);
	put_u8(&b, 8);
	put_u8(&b, 12);
	put_u8(&b, 34);
	put_zero_u32s(&b, 2);
	put_u8(&b, 0);			/* AGC mode */
	put_u8(&b, 0xff);		/* differential/equalization */
	put_u8(&b, 0);			/* ramp mode */
	put_u8(&b, 0);
	put_zero_u32s(&b, 2);
	put_u32(&b, 0);			/* BQB mask 1 */
	put_u32(&b, 0);			/* BQB mask 2 */
	put_u16s(&b, coex_threshold, 8);
	put_zero_u32s(&b, 6);

	return b.failed ? 0 : b.len;
}

static unsigned int sprd_build_rf_para(u8 *out, unsigned int cap)
{
	static const u16 gain[6] = {
		0xe000, 0xe000, 0xe000, 0xe000, 0xe000, 0xe000,
	};
	static const u16 classic_a[10] = {
		0x4115, 0x3a15, 0x3415, 0x2e15, 0x2715,
		0x2115, 0x1715, 0x1115, 0x0b15, 0x0715,
	};
	static const u16 le_a[16] = {
		0x3b15, 0x3715, 0x3315, 0x2f15, 0x2b15, 0x2715,
		0x2315, 0x1f15, 0x1b15, 0x1715, 0x1315, 0x0f15,
		0x0b15, 0x0815, 0x0415, 0x0015,
	};
	static const u16 channel_a[8] = {
		0x1015, 0x1015, 0x1015, 0x1015, 0x1015, 0x1015, 0x1015, 0x1015,
	};
	static const u16 le_channel_a[8] = {
		0x1515, 0x1515, 0x1515, 0x1515, 0x1515, 0x1515, 0x1515, 0x1515,
	};
	static const u16 classic_b[10] = {
		0x4915, 0x4315, 0x4115, 0x3915, 0x3115,
		0x2a15, 0x2215, 0x1b15, 0x1415, 0x0e15,
	};
	static const u16 le_b[16] = {
		0x4b15, 0x4b15, 0x4b15, 0x4b15, 0x4b15, 0x4615,
		0x4015, 0x3b15, 0x3615, 0x3015, 0x2b15, 0x2615,
		0x2015, 0x1a15, 0x1415, 0x0e15,
	};
	static const u16 br_channel_b[8] = {
		0x0815, 0x0915, 0x0c15, 0x0c15, 0x0c15, 0x0c15, 0x0c15, 0x0b15,
	};
	static const u16 edr_channel_b[8] = {
		0x0a15, 0x0b15, 0x0d15, 0x0e15, 0x0e15, 0x0e15, 0x0e15, 0x0d15,
	};
	static const u16 le_channel_b[8] = {
		0x0e15, 0x0e15, 0x1115, 0x1115, 0x1115, 0x1115, 0x1115, 0x1015,
	};
	static const u32 common_rfu[5] = {
		0x555f4334, 0x55555555, 0x55555555, 0x55555555, 0x55555555,
	};
	struct sprd_buf b = { .data = out, .cap = cap };

	put_u16s(&b, gain, 6);
	put_u16s(&b, classic_a, 10);
	put_u16s(&b, le_a, 16);
	put_u16s(&b, channel_a, 8);	/* BR */
	put_u16s(&b, channel_a, 8);	/* EDR */
	put_u16s(&b, le_channel_a, 8);
	put_u16s(&b, gain, 6);
	put_u16s(&b, classic_b, 10);
	put_u16s(&b, le_b, 16);
	put_u16s(&b, br_channel_b, 8);
	put_u16s(&b, edr_channel_b, 8);
	put_u16s(&b, le_channel_b, 8);
	put_u16(&b, 0x0000);		/* fixed LE power word */
	put_u8(&b, 0xff);		/* classic power control by channel */
	put_u8(&b, 0xff);		/* LE power control by channel */
	put_u8(&b, 0x01);		/* RF switch mode */
	put_u8(&b, 0x00);		/* data capture */
	put_u8(&b, 0x00);		/* analog IQ debug */
	put_u8(&b, 0x55);		/* common RFU byte */
	put_u32s(&b, common_rfu, 5);

	return b.failed ? 0 : b.len;
}

/* ---- BD address -------------------------------------------------------- */

static void sprd_hci_pick_bdaddr(struct sprd_hci *sh)
{
	struct device_node *np;
	const u8 *prop;
	int len, i;

	np = of_find_compatible_node(NULL, NULL, "sprd,mtty");
	if (!np)
		return;
	prop = of_get_property(np, "local-bd-address", &len);
	if (prop && len == 6) {
		/* DT property is big-endian (as printed), bdaddr_t is little-endian */
		for (i = 0; i < 6; i++)
			sh->bdaddr.b[i] = prop[5 - i];
		dev_info(sh->dev, "pskey BD address from DT: %pMR\n", &sh->bdaddr);
	}
	of_node_put(np);
}

/* ---- hci_dev ops ------------------------------------------------------- */

static int sprd_hci_vendor_cmd(struct hci_dev *hdev, u16 opcode, const void *param, u8 plen)
{
	struct sk_buff *skb;
	u8 status;

	skb = __hci_cmd_sync(hdev, opcode, plen, param, HCI_INIT_TIMEOUT);
	if (IS_ERR(skb)) {
		bt_dev_err(hdev, "vendor command 0x%04x failed (%ld)", opcode, PTR_ERR(skb));
		return PTR_ERR(skb);
	}
	status = skb->len ? skb->data[0] : 0;
	kfree_skb(skb);
	if (status) {
		bt_dev_err(hdev, "vendor command 0x%04x status 0x%02x", opcode, status);
		return -EIO;
	}
	return 0;
}

static int sprd_hci_setup(struct hci_dev *hdev)
{
	struct sprd_hci *sh = hci_get_drvdata(hdev);
	static const u8 enable[3] = { 0x00, 0x00, 0x01 };	/* dual mode, enable */
	u8 *pskey, *rf;
	unsigned int pskey_len, rf_len;
	int ret;

	if (wcn_get_chip_model() != WCN_CHIP_MARLIN3E)
		return -ENODEV;
	hci_set_quirk(hdev, HCI_QUIRK_BROKEN_PARK_LINK_POLICY);

	pskey = kmalloc(SPRD_PSKEY_LEN, GFP_KERNEL);
	rf = kmalloc(SPRD_RF_PARA_LEN, GFP_KERNEL);
	if (!pskey || !rf) {
		ret = -ENOMEM;
		goto out;
	}

	pskey_len = sprd_build_pskey(pskey, SPRD_PSKEY_LEN, &sh->bdaddr);
	rf_len = sprd_build_rf_para(rf, SPRD_RF_PARA_LEN);
	if (pskey_len != SPRD_PSKEY_LEN || rf_len != SPRD_RF_PARA_LEN) {
		bt_dev_err(hdev, "bad vendor parameter sizes %u/%u", pskey_len, rf_len);
		ret = -EINVAL;
		goto out;
	}

	ret = sprd_hci_vendor_cmd(hdev, SPRD_HCI_PSKEY, pskey, pskey_len);
	if (ret)
		goto out;
	ret = sprd_hci_vendor_cmd(hdev, SPRD_HCI_RF_PARA, rf, rf_len);
	if (ret)
		goto out;
	ret = sprd_hci_vendor_cmd(hdev, SPRD_HCI_ENABLE, enable, sizeof(enable));
	if (ret)
		goto out;

	bt_dev_info(hdev, "Marlin3E initialised");
out:
	kfree(pskey);
	kfree(rf);
	return ret;
}

static int sprd_hci_open(struct hci_dev *hdev)
{
	int ret;

	ret = start_marlin(MARLIN_BLUETOOTH);
	if (ret) {
		bt_dev_err(hdev, "start_marlin failed (%d)", ret);
		return ret;
	}
	/* the vendor userspace waits before the first command after power on */
	msleep(200);
	return 0;
}

static int sprd_hci_close(struct hci_dev *hdev)
{
	struct sprd_hci *sh = hci_get_drvdata(hdev);

	stop_marlin(MARLIN_BLUETOOTH);
	kfree_skb(sh->rx_skb);
	sh->rx_skb = NULL;
	return 0;
}

static int sprd_hci_flush(struct hci_dev *hdev)
{
	return 0;
}

static int sprd_hci_send(struct hci_dev *hdev, struct sk_buff *skb)
{
	u8 *buf;
	int ret;

	buf = kmalloc(skb->len + 1, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;
	buf[0] = hci_skb_pkt_type(skb);
	memcpy(buf + 1, skb->data, skb->len);

	ret = marlin_sdio_write(buf, skb->len + 1);
	kfree(buf);
	if (ret < 0) {
		hdev->stat.err_tx++;
		return ret;
	}

	switch (hci_skb_pkt_type(skb)) {
	case HCI_COMMAND_PKT:
		hdev->stat.cmd_tx++;
		break;
	case HCI_ACLDATA_PKT:
		hdev->stat.acl_tx++;
		break;
	case HCI_SCODATA_PKT:
		hdev->stat.sco_tx++;
		break;
	}
	hdev->stat.byte_tx += skb->len;
	kfree_skb(skb);
	return 0;
}

/* ---- RX: H4 stream from the SDIO block(s) ------------------------------ */

static unsigned int sprd_hci_hdr_len(u8 type)
{
	switch (type) {
	case HCI_EVENT_PKT:
		return HCI_EVENT_HDR_SIZE;
	case HCI_ACLDATA_PKT:
		return HCI_ACL_HDR_SIZE;
	case HCI_SCODATA_PKT:
		return HCI_SCO_HDR_SIZE;
	case HCI_ISODATA_PKT:
		return HCI_ISO_HDR_SIZE;
	default:
		return 0;
	}
}

static unsigned int sprd_hci_payload_len(struct sk_buff *skb)
{
	switch (hci_skb_pkt_type(skb)) {
	case HCI_EVENT_PKT:
		return ((struct hci_event_hdr *)skb->data)->plen;
	case HCI_ACLDATA_PKT:
		return __le16_to_cpu(((struct hci_acl_hdr *)skb->data)->dlen);
	case HCI_SCODATA_PKT:
		return ((struct hci_sco_hdr *)skb->data)->dlen;
	case HCI_ISODATA_PKT:
		return __le16_to_cpu(((struct hci_iso_hdr *)skb->data)->dlen) & 0x3fff;
	default:
		return 0;
	}
}

void sprd_hci_recv(const unsigned char *data, int len)
{
	struct sprd_hci *sh = READ_ONCE(sprd_hci);
	struct hci_dev *hdev;

	if (!sh || !sh->hdev)
		return;
	hdev = sh->hdev;
	if (!test_bit(HCI_RUNNING, &hdev->flags))
		return;

	while (len > 0) {
		unsigned int n;

		if (!sh->rx_skb) {
			u8 type = *data++;

			len--;
			sh->rx_hdr_len = sprd_hci_hdr_len(type);
			if (!sh->rx_hdr_len) {
				hdev->stat.err_rx++;
				continue;	/* resynchronise on the next byte */
			}
			sh->rx_skb = bt_skb_alloc(HCI_MAX_FRAME_SIZE, GFP_ATOMIC);
			if (!sh->rx_skb) {
				hdev->stat.err_rx++;
				return;
			}
			hci_skb_pkt_type(sh->rx_skb) = type;
			sh->rx_want = sh->rx_hdr_len;
		}

		n = min_t(unsigned int, len, sh->rx_want - sh->rx_skb->len);
		if (n > skb_tailroom(sh->rx_skb)) {
			hdev->stat.err_rx++;
			kfree_skb(sh->rx_skb);
			sh->rx_skb = NULL;
			return;
		}
		skb_put_data(sh->rx_skb, data, n);
		data += n;
		len -= n;

		if (sh->rx_skb->len == sh->rx_hdr_len && sh->rx_want == sh->rx_hdr_len)
			sh->rx_want = sh->rx_hdr_len + sprd_hci_payload_len(sh->rx_skb);

		if (sh->rx_skb->len == sh->rx_want) {
			hdev->stat.byte_rx += sh->rx_skb->len;
			hci_recv_frame(hdev, sh->rx_skb);
			sh->rx_skb = NULL;
		}
	}
}

void sprd_hci_reset(void)
{
	struct sprd_hci *sh = READ_ONCE(sprd_hci);

	if (sh && sh->hdev) {
		bt_dev_warn(sh->hdev, "CP2 reset, resetting HCI device");
		hci_reset_dev(sh->hdev);
	}
}

/* ---- registration ------------------------------------------------------ */

int sprd_hci_register(struct device *dev)
{
	struct sprd_hci *sh;
	struct hci_dev *hdev;
	int ret;

	sh = kzalloc(sizeof(*sh), GFP_KERNEL);
	if (!sh)
		return -ENOMEM;
	sh->dev = dev;
	sprd_hci_pick_bdaddr(sh);

	hdev = hci_alloc_dev();
	if (!hdev) {
		kfree(sh);
		return -ENOMEM;
	}
	hdev->bus = HCI_SDIO;
	hci_set_drvdata(hdev, sh);
	SET_HCIDEV_DEV(hdev, dev);
	hdev->open = sprd_hci_open;
	hdev->close = sprd_hci_close;
	hdev->flush = sprd_hci_flush;
	hdev->setup = sprd_hci_setup;
	hdev->send = sprd_hci_send;
	sh->hdev = hdev;

	WRITE_ONCE(sprd_hci, sh);
	ret = hci_register_dev(hdev);
	if (ret) {
		WRITE_ONCE(sprd_hci, NULL);
		hci_free_dev(hdev);
		kfree(sh);
		return ret;
	}
	dev_info(dev, "registered %s on the marlin SDIO HCI channel\n", hdev->name);
	return 0;
}

void sprd_hci_unregister(void)
{
	struct sprd_hci *sh = sprd_hci;

	if (!sh)
		return;
	WRITE_ONCE(sprd_hci, NULL);
	hci_unregister_dev(sh->hdev);
	hci_free_dev(sh->hdev);
	kfree_skb(sh->rx_skb);
	kfree(sh);
}
