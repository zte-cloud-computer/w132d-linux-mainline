# SPDX-License-Identifier: MIT
"""Protect the hardware behavior retained from main during packaging changes."""
import ast
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from w132dlib import images
from w132dlib.common import ROOT, read_json, run


class BluetoothReadiness(unittest.TestCase):
    def setUp(self):
        self.props = Mock()
        self.props.Get.return_value = True
        fake_dbus = types.SimpleNamespace(SystemBus=Mock(), Interface=Mock(return_value=self.props),
                                          Boolean=bool, DBusException=RuntimeError)
        loader = importlib.machinery.SourceFileLoader('smp', str(ROOT / 'userpatches/overlay/bsp-cli/usr/lib/w132d/bt-smp-ensure'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        with patch.dict(sys.modules, dbus=fake_dbus):
            self.smp = importlib.util.module_from_spec(spec)
            loader.exec_module(self.smp)
        sleep = patch.object(self.smp.time, 'sleep')
        self.sleep = sleep.start()
        self.addCleanup(sleep.stop)

    def power_changes(self):
        return [call.args[2] for call in self.props.Set.call_args_list]

    def test_healthy_controller_does_not_cycle_power(self):
        with patch.object(self.smp, 'smp_registered', return_value=True):
            self.smp.ensure()
        self.assertEqual(self.power_changes(), [True])

    def test_missing_smp_channel_gets_one_recovery(self):
        with patch.object(self.smp, 'smp_registered', side_effect=[False, True]):
            self.smp.ensure()
        self.assertEqual(self.power_changes(), [True, False, True])
        self.assertEqual([call.args[0] for call in self.sleep.call_args_list], [2, 3])

    def test_unrecoverable_smp_channel_blocks_the_bridge(self):
        with patch.object(self.smp, 'smp_registered', return_value=False), \
                self.assertRaisesRegex(RuntimeError, 'refusing to start'):
            self.smp.ensure()
        self.assertEqual(self.power_changes(), [True, False, True])

    def test_smp_debugfs_checks_the_cid_column(self):
        with tempfile.TemporaryDirectory() as temporary:
            channels = Path(temporary) / 'l2cap'
            channels.write_text('ptr 0 0 0 0 0 0x0004 0x0006\n')
            self.assertFalse(self.smp.smp_registered(channels))
            channels.write_text('ptr 0 0 0 0 0 0x0006 0x0000\n')
            self.assertTrue(self.smp.smp_registered(channels))
            channels.unlink()
            with self.assertRaisesRegex(RuntimeError, 'Cannot verify'):
                self.smp.smp_registered(channels)


class Voice(unittest.TestCase):
    def test_new_recording_keeps_the_main_retention_limit_and_private_decoder(self):
        source = ROOT / 'userpatches/overlay/bsp-cli/usr/lib/w132d/ble-remote.py'
        parsed = ast.parse(source.read_text())
        names = {'ICODEC', 'ICOLIB', 'VOICE_WAV_KEEP'}
        definitions = [node for node in parsed.body if
                       isinstance(node, ast.FunctionDef) and node.name in {'prune_voice_wavs', 'voice_open'}
                       or isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id in names for t in node.targets)]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index in range(20):
                wav = root / f'w132d-voice-{index:02}.wav'
                wav.touch()
                os.utime(wav, (index + 1, index + 1))
            unrelated = root / 'other.wav'
            unrelated.touch()
            def launch(args, **kwargs):
                self.assertEqual(args[:2], ['/usr/local/bin/icodec', '/usr/local/lib/w132d/libicocodec.patched.so'])
                (root / Path(args[2]).name).touch()
                return Mock()
            namespace = {'os': os, 'time': time, 'subprocess': types.SimpleNamespace(Popen=launch, PIPE=-1),
                         'VOICE_WAV_DIR': str(root), 'voice': {'proc': None, 'codec_failed': False}, 'log': lambda *args: None}
            exec(compile(ast.Module(body=definitions, type_ignores=[]), str(source), 'exec'), namespace)
            namespace['voice_open']()
            self.assertEqual(len(list(root.glob('w132d-voice-*.wav'))), 20)
            self.assertFalse((root / 'w132d-voice-00.wav').exists())
            self.assertTrue(unrelated.exists())


@unittest.skipUnless(shutil.which('cc'), 'A C compiler is required')
class LinkPolicy(unittest.TestCase):
    def test_marlin_einval_fallback_preserves_other_hci_errors(self):
        patch_text = (ROOT / 'userpatches/kernel/w132d/0005-bluetooth-marlin3e.patch').read_text()
        section = patch_text.split('+++ b/net/bluetooth/hci_sync.c\n', 1)[1]
        function = '\n'.join(line[1:] for line in section.splitlines() if line.startswith((' ', '+')))
        function = function.split('\n}', 1)[0] + '\n}'
        harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
typedef unsigned short u16;
struct hci_dev { unsigned char commands[6]; bool quirk; };
struct hci_cp_write_def_link_policy { u16 policy; };
#define HCI_QUIRK_BROKEN_PARK_LINK_POLICY 1
#define HCI_LP_RSWITCH 1
#define HCI_LP_HOLD 2
#define HCI_LP_SNIFF 4
#define HCI_LP_PARK 8
#define HCI_OP_WRITE_DEF_LINK_POLICY 0x080f
#define HCI_CMD_TIMEOUT 1
#define cpu_to_le16(value) (value)
#define lmp_rswitch_capable(dev) true
#define lmp_hold_capable(dev) true
#define lmp_sniff_capable(dev) true
#define lmp_park_capable(dev) true
#define hci_test_quirk(dev, quirk_id) ((dev)->quirk)
#define bt_dev_warn(...) ((void)0)
static int response, last_policy;
static int __hci_cmd_sync_status(struct hci_dev *dev, int opcode, int size,
                                 struct hci_cp_write_def_link_policy *cp, int timeout)
{ last_policy = cp->policy; return response; }
FUNCTION
int main(void) {
    struct hci_dev dev = { .commands = {0,0,0,0,0,0x10}, .quirk = true };
    response = -EINVAL;
    assert(hci_setup_link_policy_sync(&dev) == 0);
    assert(last_policy == 7);
    dev.quirk = false;
    assert(hci_setup_link_policy_sync(&dev) == -EINVAL);
    assert(last_policy == 15);
    dev.quirk = true;
    response = -ETIMEDOUT;
    assert(hci_setup_link_policy_sync(&dev) == -ETIMEDOUT);
    response = 0;
    assert(hci_setup_link_policy_sync(&dev) == 0);
    dev.commands[5] = 0;
    response = -EIO;
    assert(hci_setup_link_policy_sync(&dev) == 0);
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'policy.c'
            source.write_text(harness.replace('FUNCTION', function))
            binary = Path(temporary) / 'policy'
            run(['cc', '-std=c99', source, '-o', binary])
            run([binary])


class ImageChecks(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    @unittest.skipUnless(shutil.which('sgdisk') and shutil.which('sfdisk'), 'GPT tools are required')
    def test_native_gpt_requires_boot_flag_and_empty_reserved_storage(self):
        image = self.root / 'native.img'
        with image.open('wb') as stream:
            stream.truncate(600 * 1024**2)
        run(['sgdisk', '--clear', '--new=1:32768:+512M', '--typecode=1:0700',
             '--attributes=1:set:2', '--new=2:0:0', '--typecode=2:8300', image], stdout=subprocess.DEVNULL)
        lock = read_json(ROOT / 'config/sources.json')
        with patch.object(images, 'mounted', side_effect=RuntimeError('rootfs stage reached')):
            with self.assertRaisesRegex(RuntimeError, 'rootfs stage reached'):
                images.verify_image(image, lock, self.root)
            reserved = lock['layout']['reserved_start_sector'] * 512
            with image.open('r+b') as stream:
                stream.seek(reserved)
                stream.write(b'private device data')
            with self.assertRaisesRegex(ValueError, 'vendor storage / RKSS'):
                images.verify_image(image, lock, self.root)
            with image.open('r+b') as stream:
                stream.seek(reserved)
                stream.write(bytes(19))
            run(['sgdisk', '--attributes=1:clear:2', image], stdout=subprocess.DEVNULL)
            with self.assertRaisesRegex(ValueError, 'not marked bootable'):
                images.verify_image(image, lock, self.root)

    def test_extlinux_checks_kernel_directive_and_all_boot_inputs(self):
        boot = self.root / 'boot'
        (boot / 'extlinux').mkdir(parents=True)
        config = boot / 'extlinux/extlinux.conf'
        text = 'LABEL W132D\n  KERNEL /Image\n  INITRD /uInitrd\n  FDT /rk3528-w132d.dtb\n  APPEND root=UUID=test console=ttyS0,115200\n'
        config.write_text(text)
        for name in ('Image', 'uInitrd', 'rk3528-w132d.dtb'):
            (boot / name).touch()
        images.check_extlinux(boot)
        (boot / 'Image').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing extlinux KERNEL'):
            images.check_extlinux(boot)
        (boot / 'Image').touch()
        for before, after, message in (('  INITRD /uInitrd\n', '', 'missing a kernel, initrd or DTB'),
                                       ('root=UUID=test', '', 'persistent root device'),
                                       ('console=ttyS0,115200', '', 'UART0 console')):
            with self.subTest(message=message):
                config.write_text(text.replace(before, after))
                with self.assertRaisesRegex(ValueError, message):
                    images.check_extlinux(boot)

    def test_runtime_checks_firmware_links_executables_and_console(self):
        shutil.copytree(ROOT / 'userpatches/overlay/bsp-cli', self.root, dirs_exist_ok=True, symlinks=True)
        for name in ('sbin/modprobe', 'usr/bin/python3', 'usr/bin/ir-keytable', 'usr/libexec/bluetooth/bluetoothd'):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.touch(mode=0o755)
        for module in ('dbus', 'gi'):
            (self.root / 'usr/lib/python3/dist-packages' / module).mkdir(parents=True)
        getty = self.root / 'etc/systemd/system/getty.target.wants'
        getty.mkdir(parents=True)
        (getty / 'serial-getty@ttyS0.service').symlink_to('/usr/lib/systemd/system/serial-getty@.service')
        images.check_board_runtime(self.root)
        firmware = self.root / 'usr/lib/firmware/wifi_56630001_3ant.ini'
        firmware.unlink()
        firmware.symlink_to('missing.ini')
        with self.assertRaisesRegex(ValueError, 'broken symlink'):
            images.check_board_runtime(self.root)
        firmware.unlink()
        firmware.symlink_to('uwe5622/wifi_56630001_3ant.ini')
        (self.root / 'usr/bin/python3').chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'Missing service executable'):
            images.check_board_runtime(self.root)
        (self.root / 'usr/bin/python3').chmod(0o755)
        (getty / 'serial-getty@ttyS2.service').symlink_to('missing.service')
        with self.assertRaisesRegex(ValueError, 'Unexpected UART2'):
            images.check_board_runtime(self.root)


if __name__ == '__main__':
    unittest.main()
