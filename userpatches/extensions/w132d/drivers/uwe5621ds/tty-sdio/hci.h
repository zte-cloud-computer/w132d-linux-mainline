/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __SPRD_BT_HCI_H
#define __SPRD_BT_HCI_H

#include <linux/device.h>

#if IS_ENABLED(CONFIG_TTY_OVERY_SDIO_HCI)
int sprd_hci_register(struct device *dev);
void sprd_hci_unregister(void);
void sprd_hci_recv(const unsigned char *data, int len);
void sprd_hci_reset(void);
#else
static inline int sprd_hci_register(struct device *dev) { return -ENODEV; }
static inline void sprd_hci_unregister(void) { }
static inline void sprd_hci_recv(const unsigned char *data, int len) { }
static inline void sprd_hci_reset(void) { }
#endif

#endif
