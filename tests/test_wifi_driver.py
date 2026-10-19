# SPDX-License-Identifier: MIT
"""Exercise Wi-Fi key installation and channel initialization failures."""
from pathlib import Path
import shutil
import unittest
from test_bluetooth_driver import function, execute

DRIVER = Path(__file__).resolve().parents[1] / 'userpatches/extensions/w132d/drivers/uwe5621ds/unisocwifi'


@unittest.skipUnless(shutil.which('cc'), 'A host C compiler is required')
class WifiDriver(unittest.TestCase):
    def test_cfg80211_cookies_match_firmware_notifications_and_cancellation(self):
        source = (DRIVER / 'cfg80211.c').read_text()
        callbacks = source[source.index('/* P2P related stuff */'):
                           source.index('static void sprdwl_cfg80211_mgmt_frame_register')]
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
typedef uint8_t u8;
typedef uint64_t u64;
#define KERNEL_VERSION(a,b,c) (((a)<<16)+((b)<<8)+(c))
#define GFP_KERNEL 0
#define wl_ndev_log(...) ((void)0)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
enum nl80211_channel_type { CHAN_NONE };
struct wiphy { int unused; };
struct wireless_dev { void *netdev; };
struct ieee80211_channel { int center_freq; };
struct sprdwl_vif {
    struct wireless_dev wdev; void *priv; int ctx_id;
    u64 listen_cookie; struct ieee80211_channel listen_channel;
};
struct cfg80211_mgmt_tx_params {
    struct ieee80211_channel *chan; const u8 *buf; size_t len;
    unsigned int wait; bool dont_wait_for_ack;
};
static u64 expected;
static int command_error,ready,status,tx_calls,cancels;
static int sprdwl_remain_chan(void *priv,int ctx,struct ieee80211_channel *chan,
    enum nl80211_channel_type type,unsigned int duration,u64 *cookie) {
    assert(*cookie==expected && duration==100 && chan->center_freq==2412);
    return command_error;
}
static void cfg80211_ready_on_channel(struct wireless_dev *wdev,u64 cookie,
    struct ieee80211_channel *chan,unsigned int duration,int flags) {
    assert(cookie==expected && duration==100); ready++;
}
static int sprdwl_cancel_remain_chan(void *priv,int ctx,u64 cookie) {
    assert(cookie==expected); cancels++; return 0;
}
static int ieee80211_frequency_to_channel(int freq) { assert(freq==2412); return 1; }
static void sprdwl_cfg80211_dump_frame_prot_info(int tx,int freq,const u8 *buf,size_t len) {}
static int sprdwl_tx_mgmt(void *priv,int ctx,int channel,bool no_ack,
    unsigned int wait,u64 *cookie,const u8 *buf,size_t len) {
    assert(*cookie==expected && channel==1 && len==1 && wait==50);
    tx_calls++; return command_error;
}
static void cfg80211_mgmt_tx_status(struct wireless_dev *wdev,u64 cookie,
    const u8 *buf,size_t len,bool ack,int flags) {
    assert(cookie==expected && !ack && len==1); status++;
}
'''
        code += callbacks
        code += r'''
struct callback_ops {
    int (*roc)(struct wiphy *,struct wireless_dev *,struct ieee80211_channel *,unsigned int,
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,3,0)
        u64,const u8 *);
    int (*tx)(struct wiphy *,struct wireless_dev *,struct cfg80211_mgmt_tx_params *,u64);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(7,2,0)
        u64 *,const u8 *);
    int (*tx)(struct wiphy *,struct wireless_dev *,struct cfg80211_mgmt_tx_params *,u64 *);
#else
        u64 *);
    int (*tx)(struct wiphy *,struct wireless_dev *,struct cfg80211_mgmt_tx_params *,u64 *);
#endif
};
static const struct callback_ops ops={sprdwl_cfg80211_remain_on_channel,sprdwl_cfg80211_mgmt_tx};
int main(void) {
    struct wiphy wiphy={0}; struct sprdwl_vif vif={0};
    struct ieee80211_channel chan={2412}; const u8 frame[]={0};
    struct cfg80211_mgmt_tx_params params={.chan=&chan,.buf=frame,.len=1,.wait=50};
    for(int i=1;i<=3;i++) {
        command_error=i==2?-5:0;
        params.dont_wait_for_ack=i==3;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,3,0)
        expected=UINT64_C(0xfedcba9876543200)+i;
        assert(ops.roc(&wiphy,&vif.wdev,&chan,100,expected,NULL)==command_error);
#else
        u64 cookie=0;
        expected=i;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,2,0)
        assert(ops.roc(&wiphy,&vif.wdev,&chan,100,&cookie,NULL)==command_error);
#else
        assert(ops.roc(&wiphy,&vif.wdev,&chan,100,&cookie)==command_error);
#endif
        assert(cookie==expected);
#endif
        assert(vif.listen_cookie==expected && vif.listen_channel.center_freq==2412);
        assert(!sprdwl_cfg80211_cancel_remain_on_channel(&wiphy,&vif.wdev,expected));
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,3,0)
        expected=UINT64_C(0xabcdef0123456700)+i;
        assert(ops.tx(&wiphy,&vif.wdev,&params,expected)==command_error);
#else
        cookie=0;
        assert(ops.tx(&wiphy,&vif.wdev,&params,&cookie)==command_error);
        assert(cookie==expected);
#endif
    }
    assert(ready==2 && cancels==3 && tx_calls==3 && status==1);
    command_error=-5; params.dont_wait_for_ack=true;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,3,0)
    assert(ops.tx(&wiphy,&vif.wdev,&params,expected)==-5);
#else
    u64 cookie=0; expected=4;
    assert(ops.tx(&wiphy,&vif.wdev,&params,&cookie)==-5 && cookie==expected);
#endif
    assert(tx_calls==4 && status==1);
    return 0;
}
'''
        for minor in (1, 2, 3):
            with self.subTest(kernel=f'7.{minor}'):
                execute(f'#define LINUX_VERSION_CODE KERNEL_VERSION(7,{minor},0)\n' + code)

    def test_igtk_is_installed_without_changing_data_ciphers(self):
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
typedef uint8_t u8;
typedef uint32_t u32;
#define wl_ndev_log(...) ((void)0)
struct sprdwl_vif { u8 prwise_crypto,grp_crypto,key[2][6][32],key_len[2][6]; void *priv; int ctx_id; };
static int installed, seen_index, seen_cipher;
static u8 sprdwl_parse_cipher(u32 c) { return c; }
static int sprdwl_add_key(void *p,int ctx,const u8 *key,int len,bool pairwise,int index,
    const u8 *seq,u8 cipher,const u8 *mac) {
    (void)p;(void)ctx;(void)key;(void)pairwise;(void)seq;(void)mac;
    assert(len==16); installed++; seen_index=index; seen_cipher=cipher; return 0;
}
'''
        code += function((DRIVER / 'cfg80211.c').read_text(), 'sprdwl_add_cipher_key')
        code += r'''
int main(void) {
    struct sprdwl_vif vif={.prwise_crypto=1,.grp_crypto=2};
    vif.key_len[0][4]=16;
    assert(!sprdwl_add_cipher_key(&vif,false,4,3,0,0));
    assert(installed==1 && seen_index==4 && seen_cipher==3);
    assert(vif.prwise_crypto==1 && vif.grp_crypto==2);
    vif.key_len[0][0]=16;
    assert(!sprdwl_add_cipher_key(&vif,false,0,4,0,0));
    assert(installed==2 && vif.prwise_crypto==1 && vif.grp_crypto==4);
    vif.key_len[1][0]=16;
    assert(!sprdwl_add_cipher_key(&vif,true,0,5,0,0));
    assert(installed==3 && vif.prwise_crypto==5 && vif.grp_crypto==4);
    return 0;
}
'''
        execute(code)

    def test_channels_are_published_after_rx_tx_and_unwind_in_reverse(self):
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define SPRDWL_HW_SDIO 1
#define SPRDWL_HW_PCIE 2
#define SPRDWL_HW_USB 3
#define MAX_CHN_NUM 16
#define EINVAL 22
struct mchn_ops_t { int channel; };
static struct mchn_ops_t sdio_hif_ops[]={{0},{1},{2},{3}},pcie_hif_ops[]={{0}},usb_hif_ops[]={{0}};
struct sprdwl_priv { int hw_type,hw_offset; void *hw_priv,*common_workq; };
struct sprdwl_intf { void *hw_intf; struct sprdwl_priv *priv; int hif_offset,fw_awake,fw_power_down; };
static struct { struct mchn_ops_t *hif_ops; unsigned int max_num,registered; void *intf; } g_intf_ops;
static unsigned int active,attempts,fail_at;
static bool ready,stopped;
static void flush_workqueue(void *p) { (void)p; }
static void sprdwl_tx_stop(struct sprdwl_intf *intf) { (void)intf; stopped=true; }
static int sprdwcn_bus_chn_init(struct mchn_ops_t *ops) {
    struct sprdwl_intf *intf=g_intf_ops.intf;
    assert(ready && intf && intf->priv->hw_priv==intf && intf->hw_intf==&g_intf_ops);
    assert(ops->channel==(int)active);
    if (++attempts==fail_at) return -12;
    active++; return 0;
}
static void sprdwcn_bus_chn_deinit(struct mchn_ops_t *ops) {
    assert(stopped && active && ops->channel==(int)active-1); active--;
}
'''
        source = (DRIVER / 'wl_intf.c').read_text()
        for name in ('sprdwl_intf_init', 'sprdwl_intf_stop', 'sprdwl_intf_start', 'sprdwl_intf_deinit'):
            code += function(source, name) + '\n'
        code += r'''
int main(void) {
    for (fail_at=1;fail_at<=5;fail_at++) {
        struct sprdwl_priv priv={.hw_type=SPRDWL_HW_SDIO};
        struct sprdwl_intf intf={0}; attempts=0; ready=false; stopped=false;
        assert(!sprdwl_intf_init(&priv,&intf)); assert(!active && !attempts);
        ready=true;
        int ret=sprdwl_intf_start(&intf);
        if (fail_at<=4) assert(ret==-12 && !active && !g_intf_ops.registered);
        else assert(!ret && active==4);
        if (ret) assert(stopped);
        sprdwl_tx_stop(&intf);
        sprdwl_intf_deinit(&intf);
        assert(!active && !intf.hw_intf && !g_intf_ops.intf);
    }
    return 0;
}
'''
        execute(code)

    def test_tx_allocation_and_error_pointer_failures_are_reported(self):
        code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
typedef uint8_t u8;
#define GFP_KERNEL 0
#define ENOMEM 12
#define SPRDWL_MODE_MAX 3
#define MAX_COLOR_BIT 4
#define SPRDWL_MODE_NONE 0
#define HANG_RECOVERY_END 1
#define SPRDWL_TX_CMD_TIMEOUT 1000
#define SPRDWL_TX_DATA_TIMEOUT 1000
#define SPRDWL_TX_MSG_CMD_NUM 10
#define SPRDWL_TX_QOS_POOL_SIZE 10
#define wl_err(...) ((void)0)
#define msecs_to_jiffies(x) (x)
#define IS_ERR(p) ((intptr_t)(p)<0)
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define kthread_create(fn,data,name) create_thread()
struct tx_t { int unused; };
struct sprdwl_intf { void *sprdwl_tx; };
struct sprdwl_tx_msg {
    int lock,cmd_timeout,data_timeout,flow0,flow1,flow2,tx_list_cmd,tx_list_qos_pool;
    struct tx_t *tx_list[SPRDWL_MODE_MAX]; void *tx_thread;
    struct sprdwl_intf *intf; int tx_completed,hang_recovery_status;
    struct { int mode,color_bit,flow; } flow_ctrl[MAX_COLOR_BIT];
};
static int fail_at,step,live;
static bool fail(void) { return ++step==fail_at; }
static void *kzalloc(size_t n,int flags) { (void)flags; if(fail()) return NULL; live++; return calloc(1,n); }
static void kfree(void *p) { if(p) { live--;free(p); } }
static int sprdwl_msg_init(int n,int *list) { (void)n; if(fail()) return -12; *list=1;live++; return 0; }
static void sprdwl_msg_deinit(int *list) { assert(*list); *list=0; live--; }
static void *create_thread(void) { if(fail()) return (void *)(intptr_t)-11; live++; return (void *)1; }
#define spin_lock_init(p) (*(p)=0)
#define atomic_set(p,v) (*(p)=(v))
#define init_completion(p) (*(p)=0)
#define complete(p) (*(p)=1)
static void qos_init(struct tx_t *p) { (void)p; }
static void sprdwl_init_xmit_list(void *p) { (void)p; }
static void wake_up_process(void *p) { assert(p==(void *)1); }
'''
        code += function((DRIVER / 'tx_msg.c').read_text(), 'sprdwl_tx_init')
        code += r'''
int main(void) {
    for(fail_at=1;fail_at<=8;fail_at++) {
        step=0; struct sprdwl_intf intf={0}; int ret=sprdwl_tx_init(&intf);
        if(fail_at<=7) {
            assert(ret<0 && !live && !intf.sprdwl_tx);
            if(fail_at==7) assert(ret==-11);
        } else {
            assert(!ret); struct sprdwl_tx_msg *tx=intf.sprdwl_tx;
            for(int i=0;i<SPRDWL_MODE_MAX;i++) kfree(tx->tx_list[i]);
            sprdwl_msg_deinit(&tx->tx_list_cmd); sprdwl_msg_deinit(&tx->tx_list_qos_pool);
            live--; kfree(tx); assert(!live);
        }
    }
    return 0;
}
'''
        execute(code)

    def test_connection_events_reject_every_truncated_prefix_and_oversized_ie(self):
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef int8_t s8;
#define ETH_ALEN 6
#define SPRDWL_CONNECT_SUCCESS 0
#define SPRDWL_ROAM_SUCCESS 2
#define SPRDWL_CONNECT_FAILED 1
#define WLAN_STATUS_UNSPECIFIED_FAILURE 1
#define le16_to_cpu(x) (x)
struct sprdwl_vif { int unused; };
struct sprdwl_connect_info { u8 status;u8 *bssid;u8 channel;s8 signal;
    u8 *bea_ie;u16 bea_ie_len;u8 *req_ie;u16 req_ie_len;u8 *resp_ie;u16 resp_ie_len; };
static unsigned int reports;
static u8 expected_status;
static const u8 *begin,*end;
static void sprdwl_report_connection(struct sprdwl_vif *vif,struct sprdwl_connect_info *i,u8 reason) {
    (void)vif;reports++;assert(i->status==expected_status);
    if(expected_status==SPRDWL_CONNECT_SUCCESS) {
        assert(!reason && i->bssid>=begin && i->bssid+6<=end);
        assert(i->req_ie>=begin && i->req_ie+i->req_ie_len<=end);
        assert(i->resp_ie>=begin && i->resp_ie+i->resp_ie_len<=end);
        assert(i->bea_ie>=begin && i->bea_ie+i->bea_ie_len<=end);
    } else { assert(reason && !i->bssid && !i->req_ie && !i->resp_ie && !i->bea_ie); }
}
'''
        code += function((DRIVER / 'cmdevt.c').read_text(), 'sprdwl_event_connect')
        code += r'''
int main(void) {
    const u8 event[]={0,1,2,3,4,5,6,1,(-50)&255,2,0,0xaa,0xbb,2,0,0xcc,0xdd,2,0,0xee,0xff};
    long page=sysconf(_SC_PAGESIZE);
    u8 *map=mmap(NULL,page*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    assert(map!=MAP_FAILED && !mprotect(map+page,page,PROT_NONE));
    for(size_t n=0;n<=sizeof(event);n++) {
        u8 *data=map+page-n;memcpy(data,event,n);begin=data;end=data+n;
        expected_status=n==sizeof(event)?SPRDWL_CONNECT_SUCCESS:SPRDWL_CONNECT_FAILED;
        sprdwl_event_connect(NULL,data,n);
    }
    for(int k=9;k<=17;k+=4) {
        u8 *data=map+page-sizeof(event);memcpy(data,event,sizeof(event));data[k]=255;
        expected_status=SPRDWL_CONNECT_FAILED;sprdwl_event_connect(NULL,data,sizeof(event));
    }
    assert(reports==sizeof(event)+4);munmap(map,page*2);return 0;
}
'''
        execute(code)

    def test_command_lengths_use_received_bytes_instead_of_adma_capacity(self):
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/mman.h>
#include <unistd.h>
typedef uint16_t u16;
#define le16_to_cpu(x) (x)
#define SPRDWL_HW_SDIO 1
#define SPRDWL_HW_PCIE 2
#define min_t(t,a,b) ((t)(a)<(t)(b)?(t)(a):(t)(b))
struct sprdwl_priv { int hw_type; };
struct sprdwl_intf { struct sprdwl_priv *priv; };
struct sdiohal_puh { unsigned int len; };
struct sprdwl_cmd_hdr { uint8_t common;uint8_t cmd;u16 plen;uint32_t mstime; };
'''
        code += function((DRIVER / 'cmdevt.c').read_text(), 'sprdwl_rx_cmd_length_valid')
        code += function((DRIVER / 'wl_intf.c').read_text(), 'sprdwl_rx_payload_len')
        code += r'''
int main(void) {
    long page=sysconf(_SC_PAGESIZE);
    void *guard=mmap(NULL,page,PROT_NONE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    assert(guard!=MAP_FAILED);
    for(int n=-1;n<(int)sizeof(struct sprdwl_cmd_hdr);n++)
        assert(!sprdwl_rx_cmd_length_valid(guard,n));
    struct sprdwl_cmd_hdr hdr={.plen=8};
    assert(sprdwl_rx_cmd_length_valid(&hdr,8));hdr.plen=7;
    assert(!sprdwl_rx_cmd_length_valid(&hdr,100));hdr.plen=20;
    assert(!sprdwl_rx_cmd_length_valid(&hdr,8));assert(sprdwl_rx_cmd_length_valid(&hdr,20));
    struct sprdwl_priv priv={.hw_type=SPRDWL_HW_SDIO};
    struct sprdwl_intf intf={.priv=&priv};struct sdiohal_puh puh={.len=20};
    assert(sprdwl_rx_payload_len(&intf,&puh,16384)==20);
    assert(sprdwl_rx_payload_len(&intf,&puh,10)==10);
    assert(!sprdwl_rx_payload_len(&intf,NULL,20));
    priv.hw_type=SPRDWL_HW_PCIE;assert(sprdwl_rx_payload_len(&intf,&puh,80)==80);
    munmap(guard,page);return 0;
}
'''
        execute(code)

    def test_tx_returns_finish_inside_the_callback(self):
        code = r'''
#include <assert.h>
struct mbuf_t { int unused; };
struct sprdwl_pop_work { int chn;void *head,*tail;int num; };
static struct mbuf_t mbuf;
static int returns;
static void sprdwl_handle_pop_list(void *data) {
    struct sprdwl_pop_work *p=data;
    assert(p->chn==10 && p->head==&mbuf && p->tail==&mbuf && p->num==1);returns++;
}
'''
        code += function((DRIVER / 'wl_intf.c').read_text(), 'sprdwl_add_topop_list')
        code += r'''
int main(void) {
    for(int n=0;n<100;n++) {
        assert(!sprdwl_add_topop_list(10,&mbuf,&mbuf,1));assert(returns==n+1);
    }
    return 0;
}
'''
        execute(code)

    def test_management_registration_applies_each_changed_interface_subtype(self):
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#define BIT(n) (1UL<<(n))
#define SPRDWL_MODE_NONE 0
#define SPRDWL_WORK_REG_MGMT 7
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
struct wiphy { int unused; };
struct wireless_dev { int unused; };
struct mgmt_frame_regs { uint32_t global_stypes,interface_stypes; };
struct sprdwl_vif { struct wireless_dev wdev;unsigned long mgmt_reg;int mode;void *priv; };
struct sprdwl_work { struct sprdwl_vif *vif;int id;unsigned char data[]; };
struct sprdwl_reg_mgmt { uint16_t type;bool reg; };
static bool test_bit(unsigned int n,unsigned long *p) { return !!(*p&BIT(n)); }
static void set_bit(unsigned int n,unsigned long *p) { *p|=BIT(n); }
static void clear_bit(unsigned int n,unsigned long *p) { *p&=~BIT(n); }
static int queued,fail_alloc;
static struct sprdwl_reg_mgmt seen[16];
static struct sprdwl_work *sprdwl_alloc_work(size_t n) {
    if(fail_alloc) return NULL;
    return calloc(1,sizeof(struct sprdwl_work)+n);
}
static void sprdwl_queue_work(void *priv,struct sprdwl_work *w) {
    (void)priv;assert(w->vif && w->id==SPRDWL_WORK_REG_MGMT);
    seen[queued++]=*(struct sprdwl_reg_mgmt *)w->data;free(w);
}
'''
        code += function((DRIVER / 'cfg80211.c').read_text(), 'sprdwl_cfg80211_mgmt_frame_register')
        code += r'''
int main(void) {
    struct sprdwl_vif vif={.mode=1};
    struct mgmt_frame_regs upd={.global_stypes=0xffff,.interface_stypes=BIT(4)|BIT(13)};
    sprdwl_cfg80211_mgmt_frame_register(NULL,&vif.wdev,&upd);
    assert(queued==2 && vif.mgmt_reg==(BIT(4)|BIT(13)));
    assert(seen[0].type==0x40 && seen[0].reg && seen[1].type==0xd0 && seen[1].reg);
    sprdwl_cfg80211_mgmt_frame_register(NULL,&vif.wdev,&upd);assert(queued==2);
    upd.interface_stypes=BIT(11)|BIT(13);
    sprdwl_cfg80211_mgmt_frame_register(NULL,&vif.wdev,&upd);
    assert(queued==4 && vif.mgmt_reg==(BIT(11)|BIT(13)));
    assert(seen[2].type==0x40 && !seen[2].reg && seen[3].type==0xb0 && seen[3].reg);
    fail_alloc=1;upd.interface_stypes=0;
    sprdwl_cfg80211_mgmt_frame_register(NULL,&vif.wdev,&upd);
    assert(queued==4 && vif.mgmt_reg==(BIT(11)|BIT(13)));
    fail_alloc=0;sprdwl_cfg80211_mgmt_frame_register(NULL,&vif.wdev,&upd);
    assert(queued==6 && !vif.mgmt_reg && !seen[4].reg && !seen[5].reg);
    return 0;
}
'''
        execute(code)

    def test_management_logging_bounds_short_frames_and_vendor_subtype_indices(self):
        source = (DRIVER / 'cfg80211.c').read_text()
        code = r'''
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define IEEE80211_FCTL_FTYPE 0x0c
#define IEEE80211_FCTL_STYPE 0xf0
#define IEEE80211_FTYPE_MGMT 0
static char last[256];
static int logs;
static void capture(const char *p) { assert(strlen(p)<sizeof(last));strcpy(last,p);logs++; }
#define wl_debug(fmt,p,...) capture(p)
'''
        code += source[source.index('static char type_name[16][32]'):
                       source.index('void sprdwl_cfg80211_dump_frame_prot_info(')]
        code += function(source, 'sprdwl_cfg80211_dump_frame_prot_info')
        code += r'''
int main(void) {
    long page=sysconf(_SC_PAGESIZE);
    unsigned char *map=mmap(NULL,page*2,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
    assert(map!=MAP_FAILED && !mprotect(map+page,page,PROT_NONE));
    for(int n=0;n<=31;n++) {
        unsigned char *p=map+page-n;memset(p,0,n);
        if(n) p[0]=0xd0;
        if(n>24) p[24]=4;
        if(n>30) p[30]=255;
        sprdwl_cfg80211_dump_frame_prot_info(0,0,p,n);
    }
    assert(logs==8 && strstr(last,"Unknown ACTION"));
    unsigned char *p=map+page-31;p[24]=0x7f;p[30]=255;
    sprdwl_cfg80211_dump_frame_prot_info(0,0,p,31);assert(strstr(last,"Unknown ACTION"));
    p[30]=0;sprdwl_cfg80211_dump_frame_prot_info(0,0,p,31);assert(strstr(last,"Notice of Absence"));
    munmap(map,page*2);return 0;
}
'''
        execute(code)
