# SPDX-License-Identifier: MIT
"""Exercise actual firmware ownership, packed-image bounds and short reads."""
from pathlib import Path
import shutil
import unittest
from test_bluetooth_driver import function, execute

SOURCE = (Path(__file__).resolve().parents[1] /
          'userpatches/extensions/w132d/drivers/uwe5621ds/unisocwcn/platform/wcn_boot.c').read_text()


def firmware_harness():
    code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
typedef uint8_t u8;
#define U32_MAX UINT32_MAX
#define GFP_KERNEL 0
#define FIRMWARE_MAX_SIZE 40
#define WCN_FW_MAX_PATH_NUM 2
#define WCN_FW_NAME "wcnmodem.bin"
#define IMG_HEAD_MAGIC "WCNM"
#define IMG_HEAD_MAGIC_COMBINE "WCNE"
#define WCN_INFO(...) ((void)0)
#define WCN_DEBUG(...) ((void)0)
#define WCN_ERR(...) ((void)0)
#define max_t(t,a,b) ((t)(a)>(t)(b)?(t)(a):(t)(b))
#define bin_magic_is(data,magic) (!memcmp(data,magic,4))
#define marlin_fw_get_img_count(data) (((struct head *)(data))->img_count)
#define marlin_firmware_get_combin_info(data) ((struct combin_img_info *)((data)+sizeof(struct head)))
static char functionmask[8], BTWF_FIRMWARE_PATH[100];
static const char *wcn_fw_path[]={"/one/","/two/"};
struct firmware { size_t size; const u8 *data; };
static struct { int is_btwf_in_sysfs,first_power_on_flag;
    struct { size_t size; void *data; } firmware; } device;
static __typeof__(device) *marlin_dev=&device;
static int descriptors, buffers, refs, fail_alloc, request_error, path_calls;
static unsigned char image[128];
static size_t image_size;
static size_t reload_offset, reload_size;
static void *kzalloc(size_t n,int gfp) {
    (void)gfp; if (fail_alloc==1) return NULL; descriptors++; return calloc(1,n);
}
static void kfree(void *p) { if(p) { assert(descriptors>0); descriptors--;free(p); } }
static void *vmalloc(size_t n) { if(fail_alloc==2) return NULL; buffers++;return malloc(n); }
static void vfree(const void *p) { if(p) { assert(buffers>0);buffers--;free((void *)p); } }
static int request_firmware(const struct firmware **fw,const char *name,void *dev) {
    static struct firmware f;
    (void)name;(void)dev; if(request_error) return request_error;
    f.size=image_size;f.data=image;refs++;*fw=&f;return 0;
}
static void release_firmware(const void *p) { assert(p && refs>0); refs--; }
static const void *load_firmware_data_path(const char *path,size_t offset,size_t size,size_t *loaded) {
    (void)path;path_calls++;
    if(offset>image_size || !image_size) return NULL;
    if(loaded) { size=size < image_size-offset ? size : image_size-offset; *loaded=size; }
    else { reload_offset=offset;reload_size=size; if(size>image_size-offset) return NULL; }
    void *p=vmalloc(size);if(p) memcpy(p,image+offset,size);return p;
}
'''
    code += SOURCE[SOURCE.index('struct head {'):SOURCE.index('/* get wcn module')]
    code += SOURCE[SOURCE.index('enum marlin_firmware_source {'):
                   SOURCE.index('/* this function __must__')]
    code += r'''
static const struct imageinfo *marlin_judge_images(const unsigned char *data) {
    return (const struct imageinfo *)(data+sizeof(struct head));
}
'''
    for name in ('marlin_request_firmware', 'marlin_firmware_parse_image', 'marlin_release_firmware'):
        code += function(SOURCE, name) + '\n'
    return code


@unittest.skipUnless(shutil.which('cc'), 'A host C compiler is required')
class FirmwareDriver(unittest.TestCase):
    def test_failures_and_borrowed_backups_have_balanced_ownership(self):
        code = firmware_harness() + r'''
int main(void) {
    struct marlin_firmware *fw=(void *)1;
    memset(image,0x55,sizeof(image));image_size=64;device.first_power_on_flag=1;
    fail_alloc=1;assert(marlin_request_firmware(&fw)==-ENOMEM && !fw && !descriptors);
    fail_alloc=0;request_error=-ENOENT;
    assert(marlin_request_firmware(&fw)==-ENOENT && !fw && !descriptors && !refs);
    device.is_btwf_in_sysfs=0;request_error=0;fail_alloc=2;
    assert(marlin_request_firmware(&fw)==-ENOMEM && !fw && !descriptors && !refs && !buffers);
    fail_alloc=0;assert(!marlin_request_firmware(&fw));
    assert(refs==1 && descriptors==1 && buffers==1);
    void *backup=device.firmware.data;
    marlin_release_firmware(fw);assert(!refs && !descriptors && buffers==1);
    device.first_power_on_flag=0;
    assert(!marlin_request_firmware(&fw) && fw->data==backup);
    marlin_release_firmware(fw);assert(!descriptors && buffers==1);
    vfree(backup);device.firmware.data=NULL;
    device.is_btwf_in_sysfs=1;image_size=0;
    assert(marlin_request_firmware(&fw)==-ENOENT && !fw && !descriptors && !buffers);
    assert(path_calls==WCN_FW_MAX_PATH_NUM);
    image_size=4;assert(marlin_request_firmware(&fw)==-EINVAL && !fw && !descriptors && !buffers);
    image_size=25;assert(!marlin_request_firmware(&fw) && fw->size==25);
    marlin_release_firmware(fw);assert(!buffers && !descriptors);
    return 0;
}
'''
        execute(code)

    def test_packed_bounds_unsorted_images_and_masked_reload(self):
        code = firmware_harness() + r'''
int main(void) {
    struct marlin_firmware *fw;
    device.is_btwf_in_sysfs=1;image_size=64;
    memset(image,0x55,sizeof(image));memset(image,0,8);
    struct head *h=(void *)(image+8);memcpy(h->magic,"WCNM",4);h->img_count=1;
    struct imageinfo *i=(void *)(h+1);i->offset=24;i->size=32;
    assert(!marlin_request_firmware(&fw));assert(fw->size==32 && fw->file_offset==8);
    assert(!marlin_firmware_parse_image(fw));
    assert(reload_offset==32 && reload_size==32 && fw->size==32 && fw->data[0]==0x55);
    marlin_release_firmware(fw);assert(!buffers && !descriptors);
    struct marlin_firmware borrowed={.data=(u8 *)h,.size=56};
    for(size_t n=0;n<24;n++) {
        borrowed.size=n;assert(marlin_firmware_parse_image(&borrowed)==-EINVAL);
    }
    borrowed.size=56;h->img_count=0;assert(marlin_firmware_parse_image(&borrowed)==-EINVAL);
    h->img_count=UINT32_MAX;assert(marlin_firmware_parse_image(&borrowed)==-EINVAL);
    h->img_count=1;i->offset=UINT32_MAX-1;i->size=8;
    assert(marlin_firmware_parse_image(&borrowed)==-EINVAL);
    i->offset=24;i->size=33;assert(marlin_firmware_parse_image(&borrowed)==-EINVAL);
    i->offset=20;i->size=4;assert(marlin_firmware_parse_image(&borrowed)==-EINVAL);
    memset(image,0,sizeof(image));h=(void *)image;memcpy(h->magic,"WCNE",4);h->img_count=2;
    struct combin_img_info *c=(void *)(h+1);c[0].offset=64;c[0].size=16;
    c[1].offset=36;c[1].size=8;
    borrowed.data=image;borrowed.size=128;
    assert(!marlin_firmware_parse_image(&borrowed) && borrowed.size==80);
    c[0].offset=UINT32_MAX-2;c[0].size=8;borrowed.size=128;
    assert(marlin_firmware_parse_image(&borrowed)==-EINVAL);
    return 0;
}
'''
        execute(code)

    def test_file_reader_rejects_io_errors_and_incomplete_exact_reads(self):
        code = r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <errno.h>
#define KERNEL_VERSION(a,b,c) ((a)*10000+(b)*100+(c))
#define LINUX_VERSION_CODE KERNEL_VERSION(7,2,10)
#define IS_ERR(p) ((long)(p)<0)
#define O_RDONLY 0
struct file { int unused; };
static struct file file;
static int live,opens,fail_read;
static size_t file_size;
static void ssleep(int n) { (void)n; }
static struct file *filp_open(const char *p,int flags,int mode) {
    (void)p;(void)flags;(void)mode;opens++;return &file;
}
static void fput(struct file *f) { assert(f==&file);opens--; }
static void *vmalloc(size_t n) { live++;return malloc(n); }
static void vfree(void *p) { live--;free(p); }
static ssize_t kernel_read(struct file *f,char *buf,size_t n,loff_t *offset) {
    (void)f;if(fail_read && *offset>=2) return -EIO;
    if((size_t)*offset>=file_size) return 0;
    if(n>2) n=2;
    if(n>file_size-*offset) n=file_size-*offset;
    memset(buf,0x55,n);*offset+=n;return n;
}
'''
        code += function(SOURCE, 'load_firmware_data_path')
        code += r'''
int main(void) {
    size_t size=0;file_size=5;
    char *p=load_firmware_data_path("file",0,8,&size);
    assert(p && size==5 && !opens && live==1 && p[4]==0x55);vfree(p);
    assert(!load_firmware_data_path("file",0,8,NULL) && !opens && !live);
    fail_read=1;assert(!load_firmware_data_path("file",0,8,&size) && !opens && !live && !size);
    fail_read=0;file_size=0;assert(!load_firmware_data_path("file",0,8,&size) && !live && !opens);
    return 0;
}
'''
        execute(code)
