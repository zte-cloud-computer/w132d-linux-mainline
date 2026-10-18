# SPDX-License-Identifier: MIT
"""Check SDIO batch handling, cancellation and legacy Bluetooth framing."""
from pathlib import Path
import shutil
import unittest
from test_bluetooth_driver import function, execute

DRIVER = Path(__file__).resolve().parents[1] / 'userpatches/extensions/w132d/drivers/uwe5621ds'


@unittest.skipUnless(shutil.which('cc'), 'A host C compiler is required')
class TransportDriver(unittest.TestCase):
    def test_hci_batch_keeps_all_blocks_and_unsigned_lengths(self):
        code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
typedef uint8_t u8;
#define BT_SDIO_HEAD_LEN 4
struct mbuf_t { char *buf; unsigned int len; struct mbuf_t *next; };
static unsigned int calls;
static const unsigned int lengths[]={256,513};
static void sprd_hci_recv(const unsigned char *data,int len) {
    assert(calls<2 && len==(int)lengths[calls] && data[0]==0xaa+calls); calls++;
}
'''
        code += function((DRIVER / 'tty-sdio/tty.c').read_text(), 'mtty_hci_rx')
        code += r'''
int main(void) {
    struct mbuf_t blocks[2]={0};
    for(int i=0;i<2;i++) {
        unsigned int len=lengths[i];
        blocks[i].buf=calloc(1,len+4); blocks[i].len=len;
        blocks[i].buf[0]=(len&1)<<7; blocks[i].buf[1]=(len>>1)&0xff;
        blocks[i].buf[2]=(len>>9)&0x7f; blocks[i].buf[4]=0xaa+i;
    }
    blocks[0].next=&blocks[1]; mtty_hci_rx(blocks,2); assert(calls==2);
    blocks[0].len=1; mtty_hci_rx(blocks,1); assert(calls==2);
    free(blocks[0].buf); free(blocks[1].buf); return 0;
}
'''
        execute(code)

    def test_woble_parser_drops_short_and_unrelated_events(self):
        code = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#define HCI_EVT 4
#define BT_HCI_EVT_CMD_COMPLETE 14
#define BT_HCI_EVT_CMD_STATUS 15
static struct { unsigned short opcode; int wait; } hci_cmd;
static void up(int *p) { (*p)++; }
'''
        code += function((DRIVER / 'tty-sdio/woble.c').read_text(), 'woble_data_recv')
        code += r'''
int main(void) {
    const unsigned char event[]={4,14,4,1,0x09,0xfd,0};
    hci_cmd.opcode=0xfd09;
    assert(woble_data_recv(NULL,0)==-1);
    for(int n=0;n<7;n++) assert(woble_data_recv(event,n)==-1);
    assert(!hci_cmd.wait && !woble_data_recv(event,7) && hci_cmd.wait==1);
    const unsigned char le[]={4,0x3e,1,0};
    assert(woble_data_recv(le,4)==-1 && hci_cmd.wait==1);
    const unsigned char batch[]={4,0xff,1,0,4,15,4,0,1,0x09,0xfd};
    assert(!woble_data_recv(batch,sizeof(batch)) && hci_cmd.wait==2);
    return 0;
}
'''
        execute(code)

    def test_cancel_tx_preserves_other_channels_and_returns_all_owned_nodes(self):
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#define SDIO_CHN_TX_NUM 16
#define DEFINE_MUTEX(n) int n
struct sdio_puh_t { int type,subtype; };
struct mbuf_t { char *buf; struct mbuf_t *next; };
struct mchn_ops_t { int channel; int (*pop_link)(int,struct mbuf_t *,struct mbuf_t *,int); };
struct sdiohal_data_t { int tx_spinlock,tx_mbuf_num; struct {
    struct mbuf_t *mbuf_head,*mbuf_tail; int node_num;
} tx_list_head; };
static struct sdiohal_data_t sdio;
static int returned,mutex_held,spin_held;
static struct sdiohal_data_t *sdiohal_get_data(void) { return &sdio; }
static void mutex_lock(int *p) { (void)p; assert(!mutex_held);mutex_held=1; }
static void mutex_unlock(int *p) { (void)p;assert(mutex_held);mutex_held=0; }
static void spin_lock_bh(int *p) { (void)p;assert(!spin_held);spin_held=1; }
static void spin_unlock_bh(int *p) { (void)p;assert(spin_held);spin_held=0; }
static void sdiohal_atomic_sub(int n,int *p) { *p-=n; }
static int sdiohal_hwtype_to_channel(int inout,int type,int sub) { (void)inout;(void)sub;return type; }
static int pop(int channel,struct mbuf_t *head,struct mbuf_t *tail,int num) {
    assert(mutex_held && !spin_held && !tail->next);
    struct mbuf_t *node=head; int seen=0;
    while(node) { assert(((struct sdio_puh_t *)node->buf)->type==channel);seen++;node=node->next; }
    assert(seen==num); returned+=num; return 0;
}
'''
        source = (DRIVER / 'unisocwcn/sdio/sdiohal_tx.c').read_text()
        code += source[source.index('static DEFINE_MUTEX('):source.index('void sdiohal_tx_flush_channel')]
        code += function(source, 'sdiohal_tx_flush_channel')
        code += r'''
int main(void) {
    struct sdio_puh_t headers[]={{3,0},{5,0},{3,0},{5,0},{3,0}};
    struct mbuf_t nodes[5];
    for(int i=0;i<5;i++) { nodes[i].buf=(char *)&headers[i]; nodes[i].next=i<4?&nodes[i+1]:NULL; }
    sdio.tx_list_head.mbuf_head=nodes; sdio.tx_list_head.mbuf_tail=&nodes[4];
    sdio.tx_list_head.node_num=sdio.tx_mbuf_num=5;
    struct mchn_ops_t ops={.channel=3,.pop_link=pop};
    sdiohal_tx_flush_channel(&ops);
    assert(returned==3 && sdio.tx_mbuf_num==2 && sdio.tx_list_head.node_num==2);
    assert(sdio.tx_list_head.mbuf_head==&nodes[1] && nodes[1].next==&nodes[3]);
    assert(sdio.tx_list_head.mbuf_tail==&nodes[3] && !nodes[3].next);
    ops.channel=5; sdiohal_tx_flush_channel(&ops);
    assert(returned==5 && !sdio.tx_list_head.mbuf_head && !sdio.tx_list_head.mbuf_tail);
    assert(!sdio.tx_mbuf_num && !sdio.tx_list_head.node_num);
    sdiohal_tx_flush_channel(&ops); assert(returned==5);
    return 0;
}
'''
        execute(code)

    def test_reset_unregister_waits_for_the_running_owner(self):
        code = r'''
#include <assert.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <unistd.h>
typedef void (*marlin_reset_callback)(void *);
static marlin_reset_callback marlin_reset_func;
static void *marlin_callback_para;
static pthread_mutex_t marlin_reset_lock=PTHREAD_MUTEX_INITIALIZER;
#define mutex_lock(p) pthread_mutex_lock(p)
#define mutex_unlock(p) pthread_mutex_unlock(p)
static atomic_bool entered,released,unregistering,unregistered;
static int owner;
static void callback(void *p) {
    assert(p==&owner);atomic_store(&entered,true);
    while(!atomic_load(&released)) usleep(1000);
    assert(!atomic_load(&unregistered));
}
'''
        source = (DRIVER / 'unisocwcn/platform/wcn_boot.c').read_text()
        for name in ('marlin_reset_register_notify', 'marlin_reset_unregister_notify', 'marlin_reset_notify'):
            code += function(source, name) + '\n'
        code += r'''
static void *run_callback(void *p) { (void)p;marlin_reset_notify();return NULL; }
static void *unregister_callback(void *p) {
    (void)p;atomic_store(&unregistering,true);
    marlin_reset_unregister_notify();atomic_store(&unregistered,true);return NULL;
}
int main(void) {
    pthread_t call,remove;
    assert(!marlin_reset_register_notify(callback,&owner));
    assert(!pthread_create(&call,NULL,run_callback,NULL));
    while(!atomic_load(&entered)) usleep(1000);
    assert(!pthread_create(&remove,NULL,unregister_callback,NULL));
    while(!atomic_load(&unregistering)) usleep(1000);
    usleep(10000);assert(!atomic_load(&unregistered));
    atomic_store(&released,true);pthread_join(call,NULL);pthread_join(remove,NULL);
    assert(atomic_load(&unregistered) && !marlin_reset_func && !marlin_callback_para);
    marlin_reset_notify();return 0;
}
'''
        execute(code)

    def test_sdio_parser_skips_unknown_channels_and_bounds_the_actual_buffer(self):
        code = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#define SDIOHAL_ALIGN_4BYTE(n) (((n)+3)&~3)
#define SDIO_PUB_HEADER_SIZE 4
#define SDIO_CHANNEL_NUM 32
#define MAX_PAC_SIZE 2048
struct sdio_puh_t { unsigned int pad:6,check_sum:1,len:16,eof:1,subtype:4,type:4; };
struct mbuf_t { unsigned char *buf;int len; };
struct sdiohal_list_t { struct mbuf_t *mbuf_head,*mbuf_tail;int node_num; };
struct sdiohal_data_t { int rx_packer_cnt;struct { int pagecnt_bias; } frag_ctl; };
static struct sdiohal_data_t state;
static struct mbuf_t node;
static struct sdiohal_data_t *sdiohal_get_data(void) { return &state; }
static int sdiohal_hwtype_to_channel(int dir,int type,int subtype) {
    (void)dir;(void)subtype;return type==1?3:32;
}
static struct sdiohal_list_t *sdiohal_get_rx_mbuf_node(int num) {
    assert(num==1);struct sdiohal_list_t *p=calloc(1,sizeof(*p));p->mbuf_tail=&node;return p;
}
static void sdiohal_data_list_assignment(struct mbuf_t *m,struct sdio_puh_t *p,int ch) {
    assert(m->len==4 && m->buf==(unsigned char *)p && ch==3);
}
#define kfree(p) free(p)
'''
        code += function((DRIVER / 'unisocwcn/sdio/sdiohal_rx.c').read_text(), 'sdiohal_rx_buf_parser')
        code += r'''
int main(void) {
    unsigned int words[4]={0};
    struct sdio_puh_t *unknown=(void *)words,*good=(void *)(words+2);
    unknown->type=2;unknown->len=4;good->type=1;good->len=4;
    assert(!sdiohal_rx_buf_parser((char *)words,8,sizeof(words)) && state.rx_packer_cnt==1);
    unknown->len=0;assert(sdiohal_rx_buf_parser((char *)words,4,sizeof(words))==-EINVAL);
    unknown->len=4;assert(sdiohal_rx_buf_parser((char *)words,8,3)==-EINVAL);
    assert(sdiohal_rx_buf_parser((char *)words,8,7)==-EINVAL);
    assert(sdiohal_rx_buf_parser((char *)words,1000,sizeof(words))==-EINVAL);
    assert(state.rx_packer_cnt==2);return 0;
}
'''
        execute(code)
