# SPDX-License-Identifier: MIT
"""Check board receiver selection and repeatable microphone initialization."""
import importlib.machinery
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
from test_bluetooth_driver import function, execute

ROOT = Path(__file__).resolve().parents[1]


class Infrared(unittest.TestCase):
    def test_keymap_follows_the_board_receiver_after_numbering_changes(self):
        loader = importlib.machinery.SourceFileLoader(
            'ir_keymap', str(ROOT / 'userpatches/overlay/bsp-cli/usr/lib/w132d/ir-keymap'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        helper = importlib.util.module_from_spec(spec)
        loader.exec_module(helper)
        with tempfile.TemporaryDirectory() as temporary, patch.object(helper.subprocess, 'run') as run:
            root = Path(temporary)
            helper.load(root)
            run.assert_not_called()
            for name, driver, node in [('rc0', 'imon', 'usb-receiver'),
                                       ('rc1', 'gpio_ir_recv', 'ir-receiver')]:
                receiver = root / name
                (receiver / 'device/of_node').mkdir(parents=True)
                (receiver / 'uevent').write_text('DRV_NAME=' + driver + '\n')
                (receiver / 'device/of_node').rmdir()
                target = root / node
                target.mkdir()
                (receiver / 'device/of_node').symlink_to(target)
            helper.load(root)
            self.assertEqual(run.call_args.args[0][-2:], ['-s', 'rc1'])
            (root / 'rc1').rename(root / 'rc2')
            helper.load(root)
            self.assertEqual(run.call_args.args[0][-2:], ['-s', 'rc2'])
            self.assertEqual(run.call_count, 2)


@unittest.skipUnless(shutil.which('cc'), 'A host C compiler is required')
class Audio(unittest.TestCase):
    def test_es7202_component_reprobe_and_client_cleanup(self):
        driver = ROOT / 'userpatches/extensions/w132d/drivers/codecs'
        code = r'''
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint8_t u8;
struct i2c_client { int unused; };
struct es7202_priv { struct i2c_client *i2c; unsigned int index,pwr_vdd_voltage; };
struct snd_soc_component { struct es7202_priv *data; };
#define CONFIG_SND_SOC_ES7202_MIC_MAX_CHANNELS 2
#define printk(...) ((void)0)
static int steps,fail_at,fail_update;
#define EREMOTEIO 121
static void *snd_soc_component_get_drvdata(struct snd_soc_component *c) { return c->data; }
static int es7202_write(u8 reg,unsigned char v,struct i2c_client *c) { (void)reg;(void)v;assert(c); return ++steps==fail_at ? -EREMOTEIO : 0; }
static int es7202_update_bits(u8 reg,u8 mask,u8 value,struct i2c_client *c) { (void)reg;(void)mask;(void)value; assert(c); return fail_update ? -EREMOTEIO : 0; }
'''
        code += '#include "' + str(driver / 'es7202.h') + '"\n'
        code += 'static struct i2c_client *i2c_ctl[ADC_DEV_MAXNUM];\n'
        source = (driver / 'es7202.c').read_text()
        code += function(source, 'es7202_probe') + '\n'
        code += function(source, 'es7202_clear_client') + '\n'
        code += r'''
int main(void) {
    struct i2c_client client={0},replacement={0};
    struct es7202_priv priv={.i2c=&client,.index=0,.pwr_vdd_voltage=VDD_3V3};
    struct snd_soc_component component={.data=&priv};
    i2c_ctl[0]=&client;
    for(int n=0;n<100;n++) assert(!es7202_probe(&component));
    steps=0;assert(!es7202_probe(&component));int count=steps;
    for(fail_at=1;fail_at<=count;fail_at++) {
        steps=0;assert(es7202_probe(&component)==-EREMOTEIO && steps==fail_at);
    }
    fail_at=0;fail_update=1;assert(es7202_probe(&component)==-EREMOTEIO);
    es7202_clear_client(&priv); assert(!i2c_ctl[0]);
    i2c_ctl[0]=&replacement; es7202_clear_client(&priv); assert(i2c_ctl[0]==&replacement);
    return 0;
}
'''
        execute(code)

    def test_es7202_read_modify_write_propagates_errors_without_corrupting_registers(self):
        code = r'''
#include <assert.h>
#include <stdint.h>
#include <errno.h>
#include <stddef.h>
typedef uint8_t u8;
#define printk(...) ((void)0)
struct i2c_client { int adapter; };
static int fail_at,step,writes,short_io;
static u8 reg_value;
static int i2c_master_send(struct i2c_client *c,u8 *buf,int len) {
    (void)c;
    if(++step==fail_at) return short_io ? 0 : -EREMOTEIO;
    if(len==2) { writes++;reg_value=buf[1]; }
    return len;
}
static int i2c_master_recv(struct i2c_client *c,u8 *buf,int len) {
    (void)c;
    if(++step==fail_at) return short_io ? 0 : -EREMOTEIO;
    *buf=reg_value;return len;
}
'''
        source = (ROOT / 'userpatches/extensions/w132d/drivers/codecs/es7202.c').read_text()
        for name in ('es7202_read', 'es7202_write', 'es7202_update_bits'):
            code += function(source, name) + '\n'
        code += r'''
int main(void) {
    struct i2c_client client={.adapter=1};
    for(short_io=0;short_io<=1;short_io++) {
        for(fail_at=1;fail_at<=3;fail_at++) {
            reg_value=0xa0;step=0;writes=0;
            assert(es7202_update_bits(7,3,3,&client)==(short_io ? -EIO : -EREMOTEIO));
            assert(!writes && reg_value==0xa0 && step==fail_at);
        }
    }
    fail_at=0;step=0;assert(!es7202_update_bits(7,3,3,&client) && reg_value==0xa3 && writes==1);
    step=0;assert(!es7202_update_bits(7,3,3,&client) && writes==1 && step==2);
    assert(es7202_update_bits(7,3,3,NULL)==-ENODEV);return 0;
}
'''
        execute(code)
