# SPDX-License-Identifier: MIT
"""Exercise the shared shell/PowerShell transaction without accessing USB."""
import importlib.util
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('w132d_flash', ROOT / 'flash/flash.py')
flash = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flash)


def fixture(root):
    root = Path(root)
    (root / 'head.bin').write_bytes(b'A' * 1024)
    (root / 'system.bin').write_bytes(b'B' * 1024)
    (root / 'loader.bin').write_bytes(b'loader')
    manifest = {'schema': 1, 'sector_size': 512, 'preserve_sectors': [2, 4],
                'image_size': 3072,
                'layout': {'idbloader_sector': 1, 'uboot_sector': 4, 'partition_offset_mib': 1},
                'boot_components': {
                    'idbloader.img': {'sector': 1, 'size': 400, 'sha256': hashlib.sha256(b'A' * 400).hexdigest()},
                    'u-boot.itb': {'sector': 4, 'size': 512, 'sha256': hashlib.sha256(b'B' * 512).hexdigest()}},
                'segments': [{'file': name, 'size': (root / name).stat().st_size,
                              'sha256': flash.digest(root / name), 'sector': sector}
                             for name, sector in [('head.bin', 0), ('system.bin', 4)]],
                'loader': {'file': 'loader.bin', 'sha256': flash.digest(root / 'loader.bin')}, 'tools': {}}
    (root / 'flash-manifest.json').write_text(json.dumps(manifest))
    return manifest


class FakeDevice:
    def __init__(self, directory, corrupt=False):
        self.root = Path(directory)
        self.calls = []
        self.corrupt = corrupt

    def one(self):
        return 'loader'

    def wait(self, mode):
        self.calls.append(('wait', mode))

    def run(self, *args):
        self.calls.append(args)
        if args[0] == 'rl':
            name = 'head.bin' if args[1] == 0 else 'system.bin'
            data = (self.root / name).read_bytes()
            if self.corrupt:
                data = b'X' + data[1:]
            Path(args[3]).write_bytes(data)
        if args[0] == 'rfi':
            return 'Flash Size: 6 Sectors\n'
        return ''


class FlashTests(unittest.TestCase):
    def test_corruption_rejected_before_usb_access(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fixture(root)
            (root / 'system.bin').write_bytes(b'corrupted')
            with patch.object(flash.subprocess, 'run') as usb:
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    flash.main([temp, '--yes', '--tool', sys.executable])
                usb.assert_not_called()

    def test_path_escape_and_reserved_sectors_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = fixture(root)
            manifest['segments'][1]['sector'] = 2
            (root / 'flash-manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'reserved'):
                flash.validate(root)
            with self.assertRaisesRegex(ValueError, 'unsafe'):
                flash.contained(root, '../missing.bin')

    def test_multiple_devices_rejected(self):
        device = flash.Device('/unused')
        with patch.object(device, 'run', return_value='DevNo=1 Mode=Loader\nDevNo=2 Mode=Maskrom\n'):
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                device.one()

    def test_readback_failure_never_reboots(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = fixture(temp)
            device = FakeDevice(temp, corrupt=True)
            with self.assertRaisesRegex(RuntimeError, 'NOT been rebooted'):
                flash.flash(temp, manifest, device)
            self.assertNotIn(('rd',), device.calls)
            self.assertIn(('rd', '3'), device.calls)

    def test_all_segments_verified_before_reboot_and_verify_only_never_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = fixture(temp)
            device = FakeDevice(temp)
            flash.flash(temp, manifest, device)
            self.assertEqual(device.calls[-1], ('rd',))
            self.assertEqual([c[0] for c in device.calls].count('rl'), 2)
            device = FakeDevice(temp)
            flash.flash(temp, manifest, device, verify_only=True)
            self.assertTrue(all(c[0] in ('rfi', 'rl') for c in device.calls))

    def test_boot_component_bounds_and_bytes_are_checked(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manifest = fixture(root)
            manifest['boot_components']['idbloader.img']['size'] = 513
            (root / 'flash-manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'layout bounds'):
                flash.validate(root)
            manifest = fixture(root)
            manifest['boot_components']['u-boot.itb']['sha256'] = '0' * 64
            (root / 'flash-manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'component checksum'):
                flash.validate(root)

    def test_device_capacity_is_checked_before_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = fixture(temp)
            for response in ('Flash Size: 5 Sectors\n', 'Unknown capacity'):
                device = FakeDevice(temp)
                original = device.run
                with patch.object(device, 'run', side_effect=lambda *a: response if a[0] == 'rfi' else original(*a)):
                    with self.assertRaisesRegex(RuntimeError, 'capacity'):
                        flash.flash(temp, manifest, device)
                self.assertFalse(any(c[0] in ('wl', 'rl') for c in device.calls))

    def test_native_platform_selection(self):
        for system, arch, expected in [('Linux', 'x86_64', 'linux-amd64'), ('Linux', 'aarch64', 'linux-arm64'), ('Darwin', 'arm64', 'macos-arm64')]:
            with patch.object(flash.platform, 'system', return_value=system), patch.object(flash.platform, 'machine', return_value=arch):
                self.assertEqual(flash.native_platform(), expected)

    def test_available_launchers_share_dry_run_and_error_behavior(self):
        commands = [[sys.executable, str(ROOT / 'flash/flash.py')]]
        if sys.platform != 'win32' and shutil.which('bash'):
            commands.append(['bash', str(ROOT / 'flash/flash.sh')])
        if shutil.which('pwsh'):
            commands.append(['pwsh', '-NoProfile', '-File', str(ROOT / 'flash/flash.ps1')])
        with tempfile.TemporaryDirectory() as temp:
            fixture(temp)
            for command in commands:
                args = [*command, temp, '--dry-run', '--tool', sys.executable]
                result = subprocess.run(args, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('FLASH_DRY_RUN_OK', result.stdout)
            (Path(temp) / 'loader.bin').write_bytes(b'bad')
            for command in commands:
                result = subprocess.run([*command, temp, '--dry-run', '--tool', sys.executable], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Loader checksum mismatch', result.stderr)


if __name__ == '__main__':
    unittest.main()
