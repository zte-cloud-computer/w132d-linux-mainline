# SPDX-License-Identifier: MIT
"""Execute driver lifecycle paths with failed resources and fragmented H4 RX."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / 'userpatches/extensions/w132d/drivers/uwe5621ds/tty-sdio'


def function(source, name):
    match = re.search(r'^(?:static )?(?:unsigned int|unsigned short|int|void|bool|char\s*\*)\s*' + name + r'\([^;{]*\{', source, re.M)
    start = match.start()
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def execute(code):
    with tempfile.TemporaryDirectory(prefix='w132d-bt-') as temporary:
        source, binary = (Path(temporary) / name for name in ('check.c', 'check'))
        source.write_text(code)
        result = subprocess.run(['cc', '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function',
                                 '-pthread', str(source), '-o', str(binary)], capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)


@unittest.skipUnless(shutil.which('cc'), 'A host C compiler is required')
class BluetoothLifecycle(unittest.TestCase):
    def test_probe_failures_unwind_and_registration_has_a_ready_transport(self):
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#define OTT_UWE
#define CONFIG_TTY_OVERY_SDIO_HCI 1
#define IS_ENABLED(x) (x)
#define ENOMEM 12
#define GFP_KERNEL 0
#define MTTY_STATE_CLOSE 0
#define BT_TX_POOL_SIZE 64
#define MARLIN_BLUETOOTH 0
#define LINUX_VERSION_CODE 70000
#define KERNEL_VERSION(a,b,c) 0
#define pr_err(...) ((void)0)
struct device { void *platform_data; int kobj; };
struct platform_device { struct device dev; void *data; };
struct mtty_init_data { char *name; };
struct mtty_device { struct mtty_init_data *pdata; void *port; int state, rw_mutex,
    rx_head, bt_rx_work; void *bt_rx_workqueue; };
static struct mtty_device *mtty_dev;
static int sem_id, bt_rx_ops, bt_tx_ops, bluetooth_reset_block, bluetooth_group;
static int step, fail_at, live, channels, notifier, sysfs, sleep_ready, woble_ready, hci;
static bool fail(void) { return ++step == fail_at; }
static void *kzalloc(size_t n, int f) { (void)f; if (fail()) return NULL; live++; return calloc(1,n); }
static void kfree(void *p) { if (p) { live--; free(p); } }
static void mtty_destroy_pdata(struct mtty_init_data **p) { (void)p; }
#define atomic_set(p,v) (*(p)=(v))
#define mutex_init(p) (*(p)=1)
#define INIT_LIST_HEAD(p) (*(p)=1)
#define INIT_WORK(p,f) (*(p)=1)
static void *create_singlethread_workqueue(const char *n) { (void)n; return kzalloc(1,0); }
static void destroy_workqueue(void *p) { kfree(p); }
static void cancel_work_sync(void *p) { (void)p; }
static void sema_init(int *p, int n) { *p=n; }
static void platform_set_drvdata(struct platform_device *p, void *d) { p->data=d; }
static void *platform_get_drvdata(struct platform_device *p) { return p->data; }
static int bluesleep_init(void) { if (fail()) return -1; sleep_ready=1; return 0; }
static void bluesleep_exit(void) { assert(sleep_ready); sleep_ready=0; woble_ready=0; }
static int woble_init(void) { if (fail()) return -1; woble_ready=1; return 0; }
static int sprdwcn_bus_chn_init(int *p) {
    assert(mtty_dev && sem_id==63 && woble_ready && sleep_ready);
    if (fail()) return -1;
    int bit = p==&bt_rx_ops ? 1 : 2;
    assert(!(channels&bit)); channels|=bit; return 0;
}
static void sprdwcn_bus_chn_deinit(int *p) {
    int bit = p==&bt_rx_ops ? 1 : 2;
    assert(!hci && !notifier && (channels&bit)); channels&=~bit;
}
static int marlin_reset_callback_register(int n, int *p) {
    (void)n; (void)p; if (fail()) return -1; notifier=1; return 0;
}
static void marlin_reset_callback_unregister(int n, int *p) {
    (void)n; (void)p; assert(notifier); notifier=0;
}
static int sysfs_create_group(int *a, int *b) {
    (void)a; (void)b; if (fail()) return -1; sysfs=1; return 0;
}
static void sysfs_remove_group(int *a, int *b) { (void)a; (void)b; assert(sysfs); sysfs=0; }
static int sprd_hci_register(struct device *d) {
    (void)d; assert(channels==3 && notifier && sysfs && sleep_ready && woble_ready && sem_id==63);
    if (fail()) return -1;
    hci=1; return 0;
}
static void sprd_hci_unregister(void) {
    assert(hci && channels==3 && !notifier); hci=0;
}
static int mtty_tty_driver_init(void *p) { (void)p; abort(); }
static void mtty_tty_driver_exit(void *p) { (void)p; abort(); }
static int rfkill_bluetooth_init(void *p) { (void)p; abort(); }
static void rfkill_bluetooth_remove(void *p) { (void)p; abort(); }
'''
        source = (DRIVER / 'tty.c').read_text()
        code += function(source, 'mtty_probe')
        remove = function(source, 'mtty_remove')
        code += '\nstatic void mtty_remove(struct platform_device *pdev)\n' + remove[remove.index('{'):]
        code += r'''
int main(void) {
    for (fail_at=1; fail_at<=10; fail_at++) {
        struct platform_device p = {0};
        step=0;
        int ret=mtty_probe(&p);
        if (!ret) mtty_remove(&p);
        assert(!live && !channels && !notifier && !sysfs && !sleep_ready && !hci);
        assert(!mtty_dev && !p.data);
    }
    return 0;
}
'''
        execute(code)

    def test_failed_channel_pool_allocation_allows_a_clean_retry(self):
        source = (DRIVER.parent / 'unisocwcn/wcn_bus.c').read_text()
        code = r'''
#include <assert.h>
#include <stddef.h>
#include <stdbool.h>
#define EXPORT_SYMBOL(x)
#define WARN_ON(x) assert(!(x))
#define pr_err(...) ((void)0)
struct mchn_ops_t { int channel, hif_type, pool_size; };
struct buffer_pool_t { int unused; };
struct chn_info_t { struct mchn_ops_t *ops[32]; int callback_lock[32];
    struct buffer_pool_t pool[32]; };
static struct chn_info_t channels;
static struct chn_info_t *chn_info(void) { return &channels; }
static int alloc_error, locks;
static void mutex_init(int *p) { *p=1; }
static void mutex_lock(int *p) { assert(*p==1); *p=2; locks++; }
static void mutex_unlock(int *p) { assert(*p==2); *p=1; locks--; }
static void mutex_destroy(int *p) { assert(*p==1); *p=0; }
static int buf_pool_init(struct buffer_pool_t *p,int size,int payload) {
    (void)p; (void)size; (void)payload; return alloc_error;
}
'''
        code += function(source, 'bus_chn_init')
        code += r'''
int main(void) {
    struct mchn_ops_t ops={.channel=3,.pool_size=64};
    alloc_error=-12;
    assert(bus_chn_init(&ops,1)==-12);
    assert(!channels.ops[3] && !channels.callback_lock[3] && !locks);
    alloc_error=0;
    assert(!bus_chn_init(&ops,1));
    assert(channels.ops[3]==&ops && channels.callback_lock[3]==1 && !locks);
    return 0;
}
'''
        execute(code)

    def test_fragmented_receive_is_cleared_on_close_reset_and_unregister(self):
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
typedef uint8_t u8;
typedef struct { u8 b[6]; } bdaddr_t;
struct device { int unused; };
struct sk_buff { unsigned int len; u8 data[4096]; u8 type; };
struct hci_dev {
    void *drvdata; unsigned long flags; unsigned int quirks; int bus;
    const char *name;
    int (*open)(struct hci_dev *), (*close)(struct hci_dev *), (*flush)(struct hci_dev *),
        (*setup)(struct hci_dev *), (*send)(struct hci_dev *, struct sk_buff *);
    struct { unsigned int err_rx, byte_rx; } stat;
};
#define HCI_SDIO 1
#define HCI_RUNNING 0
#define HCI_QUIRK_NON_PERSISTENT_SETUP 1
#define HCI_EVENT_PKT 4
#define HCI_ACLDATA_PKT 2
#define HCI_SCODATA_PKT 3
#define HCI_ISODATA_PKT 5
#define HCI_EVENT_HDR_SIZE 2
#define HCI_ACL_HDR_SIZE 4
#define HCI_SCO_HDR_SIZE 3
#define HCI_ISO_HDR_SIZE 4
#define HCI_MAX_FRAME_SIZE 4096
#define GFP_ATOMIC 0
#define GFP_KERNEL 0
#define ENOMEM 12
#define MARLIN_BLUETOOTH 0
#define DEFINE_SPINLOCK(n) pthread_mutex_t n=PTHREAD_MUTEX_INITIALIZER
#define spin_lock_irqsave(p,f) do { (f)=0; pthread_mutex_lock(p); } while(0)
#define spin_unlock_irqrestore(p,f) do { (void)(f); pthread_mutex_unlock(p); } while(0)
#define bt_dev_err(...) ((void)0)
#define bt_dev_warn(...) ((void)0)
#define dev_info(...) ((void)0)
#define SET_HCIDEV_DEV(h,d) ((void)0)
#define min_t(t,a,b) ((t)(a)<(t)(b)?(t)(a):(t)(b))
#define hci_skb_pkt_type(s) ((s)->type)
#define __le16_to_cpu(n) (n)
struct hci_event_hdr { u8 evt, plen; };
struct hci_acl_hdr { uint16_t handle, dlen; };
struct hci_sco_hdr { uint16_t handle; u8 dlen; };
struct hci_iso_hdr { uint16_t handle, dlen; };
static int packets, resets, allocations, setups;
static void *kzalloc(size_t n, int flags) { (void)flags; return calloc(1,n); }
static void kfree(void *p) { free(p); }
static struct sk_buff *bt_skb_alloc(int n,int flags) { (void)n; (void)flags; allocations++; return calloc(1,sizeof(struct sk_buff)); }
static void kfree_skb(struct sk_buff *s) { if(s) { allocations--; free(s); } }
static unsigned int skb_tailroom(struct sk_buff *s) { return sizeof(s->data)-s->len; }
static void skb_put_data(struct sk_buff *s,const void *p,int n) { memcpy(s->data+s->len,p,n); s->len+=n; }
static void *hci_get_drvdata(struct hci_dev *h) { return h->drvdata; }
static void hci_set_drvdata(struct hci_dev *h,void *p) { h->drvdata=p; }
static bool test_bit(int n,unsigned long *flags) { return *flags & (1UL<<n); }
static void hci_recv_frame(struct hci_dev *h,struct sk_buff *s) { (void)h; packets++; kfree_skb(s); }
static void hci_reset_dev(struct hci_dev *h) { (void)h; resets++; }
static int start_marlin(int n) { (void)n; return 0; }
static void stop_marlin(int n) { (void)n; }
static void msleep(int n) { (void)n; }
static int sprd_hci_setup(struct hci_dev *h) { (void)h; setups++; return 0; }
static int sprd_hci_flush(struct hci_dev *h) { (void)h; return 0; }
static int sprd_hci_send(struct hci_dev *h,struct sk_buff *s) { (void)h; (void)s; return 0; }
static struct hci_dev *hci_alloc_dev(void) { return calloc(1,sizeof(struct hci_dev)); }
static void hci_free_dev(struct hci_dev *h) { free(h); }
static void hci_set_quirk(struct hci_dev *h,int q) { h->quirks|=1U<<q; }
static int hci_register_dev(struct hci_dev *h) { h->name="hci0"; return 0; }
static void hci_unregister_dev(struct hci_dev *h) { h->close(h); }
'''
        source = (DRIVER / 'hci.c').read_text()
        code += source[source.index('struct sprd_hci {'):source.index('/* ---- vendor parameter')]
        code += '\nstatic void sprd_hci_pick_bdaddr(struct sprd_hci *sh) { (void)sh; }\n'
        for name in ('sprd_hci_open', 'sprd_hci_clear_rx', 'sprd_hci_close',
                     'sprd_hci_hdr_len', 'sprd_hci_payload_len', 'sprd_hci_recv',
                     'sprd_hci_reset', 'sprd_hci_register', 'sprd_hci_unregister'):
            code += function(source, name) + '\n'
        code += r'''
static void power_on(struct hci_dev *h) {
    assert(!h->open(h)); h->flags=1;
    if (!setups || (h->quirks&(1U<<HCI_QUIRK_NON_PERSISTENT_SETUP))) h->setup(h);
}
static atomic_bool done;
static void *receive_thread(void *p) {
    (void)p; const u8 event[]={4,14,0};
    while (!atomic_load(&done)) sprd_hci_recv(event,sizeof(event));
    return NULL;
}
int main(void) {
    struct device d={0}; assert(!sprd_hci_register(&d));
    struct hci_dev *h=sprd_hci->hdev;
    power_on(h); assert(setups==1);
    const u8 first[]={4,14,2,0xaa}, last[]={0xbb}, event[]={4,14,0};
    sprd_hci_recv(first,sizeof(first)); assert(allocations==1 && !packets);
    sprd_hci_recv(last,sizeof(last)); assert(allocations==0 && packets==1);
    sprd_hci_recv(first,sizeof(first)); h->close(h); assert(!allocations);
    sprd_hci_recv(event,sizeof(event)); assert(packets==1);
    power_on(h); assert(setups==2);
    sprd_hci_recv(first,sizeof(first)); sprd_hci_reset(false);
    assert(resets==0 && !allocations);
    sprd_hci_reset(true); assert(resets==1);
    sprd_hci_recv(event,sizeof(event)); assert(packets==1);
    h->close(h); power_on(h); assert(setups==3);
    sprd_hci_recv(event,sizeof(event)); assert(packets==2);
    pthread_t thread; assert(!pthread_create(&thread,NULL,receive_thread,NULL));
    for (int i=0;i<1000;i++) { h->close(h); power_on(h); }
    sprd_hci_unregister(); atomic_store(&done,true); pthread_join(thread,NULL);
    assert(!sprd_hci && !allocations);
    sprd_hci_recv(event,sizeof(event)); sprd_hci_reset(false);
    return 0;
}
'''
        execute(code)


if __name__ == '__main__':
    unittest.main()
