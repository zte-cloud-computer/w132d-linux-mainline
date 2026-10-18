# SPDX-License-Identifier: MIT
"""Exercise the shared shell/PowerShell transaction without accessing USB."""
import importlib.util
import hashlib
import io
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
MASKROM = 'DevNo=1 Vid=0x2207,Pid=0x350c,LocationID=4 Maskrom\n'


class Clock:
    def __init__(self):
        self.now = 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


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


class FakeDevice(flash.Device):
    def __init__(self, directory, corrupt=False, download_mode='loader'):
        super().__init__('/unused')
        self.root = Path(directory)
        self.calls = []
        self.corrupt = corrupt
        self.mode = 'loader'
        self.ready = True
        self.download_mode = download_mode

    def run(self, *args, live=False, timeout=flash.COMMAND_TIMEOUT):
        self.calls.append(args)
        if args[0] == 'ld':
            return 'DevNo=1 Vid=0x2207,Pid=0x350c,LocationID=4 ' + self.mode.title()
        if args == ('rd', '3'):
            self.mode, self.ready = 'maskrom', False
        if args[0] == 'db':
            self.mode, self.ready = self.download_mode, True
            return 'Downloading bootloader succeeded.\n'
        if args[0] == 'rl':
            name, start = ('head.bin', 0) if args[1] < 4 else ('system.bin', 4)
            with (self.root / name).open('rb') as source:
                source.seek((args[1] - start) * 512)
                data = source.read(args[2] * 512)
            if self.corrupt:
                data = b'X' + data[1:]
            Path(args[3]).write_bytes(data)
        if args[0] == 'rfi':
            if not self.ready:
                raise RuntimeError('Read Flash Info quit, creating comm object failed!')
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

    def test_other_chip_or_missing_usb_identity_rejected_before_download(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture(temp)
            for listing in (MASKROM.replace('0x350c', '0x330c'), 'DevNo=1 Maskrom\n'):
                with self.subTest(listing=listing), patch.object(flash.Device, 'run', return_value=listing) as run:
                    with self.assertRaisesRegex(RuntimeError, 'RK3528'):
                        flash.main([temp, '--yes', '--tool', sys.executable])
                    self.assertEqual([call.args for call in run.call_args_list], [('ld',)])

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
            self.assertTrue(all(c[0] in ('ld', 'rfi', 'rl') for c in device.calls))

    def test_storage_and_full_readback_work_with_maskrom_descriptor(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = fixture(temp)
            device = FakeDevice(temp, download_mode='maskrom')
            device.mode, device.ready = 'maskrom', False
            flash.flash(temp, manifest, device)
            self.assertEqual(device.calls[0], ('ld',))
            self.assertEqual(device.calls[1][0], 'db')
            self.assertEqual(device.calls[-1], ('rd',))
            self.assertEqual(sum(c[0] == 'wl' for c in device.calls), 2)
            self.assertEqual(sum(c[0] == 'rl' for c in device.calls), 2)
            device.calls.clear()
            flash.flash(temp, manifest, device, verify_only=True)
            self.assertTrue(all(c[0] in ('ld', 'rfi', 'rl') for c in device.calls))

    def test_storage_polling_handles_usb_gap_and_transient_comm_failure(self):
        device = flash.Device('/unused')
        info = 'Flash Size: 61472768 Sectors\n'
        replies = ['', MASKROM, RuntimeError('creating comm object failed'), MASKROM, info]
        with patch.object(device, 'run', side_effect=replies) as run, patch.object(flash.time, 'sleep'):
            self.assertEqual(device.wait_storage(), info)
        self.assertEqual([call.args for call in run.call_args_list], [('ld',), ('ld',), ('rfi',), ('ld',), ('rfi',)])

    def test_mode_wait_uses_one_usb_listing_per_attempt(self):
        device = flash.Device('/unused')
        with patch.object(device, 'run', side_effect=['', MASKROM]) as run, patch.object(flash.time, 'sleep'):
            device.wait('maskrom')
        self.assertEqual(run.call_count, 2)

    def test_multiple_devices_during_storage_polling_fail_before_probe(self):
        device = flash.Device('/unused')
        with patch.object(device, 'run', return_value='DevNo=1 Maskrom\nDevNo=2 Loader\n') as run:
            with self.assertRaisesRegex(RuntimeError, 'exactly one'):
                device.wait_storage()
        run.assert_called_once_with('ld', timeout=5)

    def test_loader_not_ready_reports_last_state_without_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = fixture(temp)
            device = FakeDevice(temp, download_mode='maskrom')
            original = device.run

            def fail_probe(*args, **kwargs):
                if args[0] == 'rfi':
                    raise RuntimeError('Read Flash Info quit, creating comm object failed!')
                return original(*args, **kwargs)

            clock = Clock()
            with patch.object(device, 'run', side_effect=fail_probe), \
                    patch.object(flash.time, 'monotonic', clock.monotonic), patch.object(flash.time, 'sleep', clock.sleep):
                with self.assertRaisesRegex(RuntimeError, 'no image data was written') as error:
                    flash.flash(temp, manifest, device)
            self.assertIn('Maskrom', str(error.exception))
            self.assertIn('creating comm object failed', str(error.exception))
            self.assertFalse(any(c[0] in ('wl', 'rl') or c == ('rd',) for c in device.calls))

    def test_probe_timeout_is_bounded_and_reported(self):
        device = flash.Device('/unused')
        clock = Clock()

        def probe(*args, timeout):
            if args[0] == 'ld':
                return MASKROM
            clock.now += timeout
            raise RuntimeError('rkdeveloptool rfi timed out')

        with patch.object(device, 'run', side_effect=probe) as run, \
                patch.object(flash.time, 'monotonic', clock.monotonic), patch.object(flash.time, 'sleep', clock.sleep):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                device.wait_storage()
        self.assertEqual(clock.now, 60)
        self.assertTrue(all(0 < call.kwargs['timeout'] <= flash.PROBE_TIMEOUT for call in run.call_args_list))

    def test_mode_wait_has_a_deadline_even_when_enumeration_stalls(self):
        device = flash.Device('/unused')
        clock = Clock()

        def scan(*args, timeout):
            clock.now += timeout
            raise RuntimeError('rkdeveloptool ld timed out')

        with patch.object(device, 'run', side_effect=scan), patch.object(flash.time, 'monotonic', clock.monotonic), \
                patch.object(flash.time, 'sleep', clock.sleep):
            with self.assertRaisesRegex(RuntimeError, 'did not enter maskrom'):
                device.wait('maskrom')
        self.assertEqual(clock.now, 20)

    def test_native_progress_reaches_terminal_before_tool_exits(self):
        with tempfile.TemporaryDirectory() as temp:
            ack = Path(temp) / 'ack'
            script = '''
from pathlib import Path
import sys, time
print('Write LBA from file (25%)', flush=True)
for attempt in range(100):
    if Path(sys.argv[1]).exists():
        break
    time.sleep(0.02)
else:
    sys.exit(1)
print('Write LBA from file (100%)', flush=True)
'''
            runner = "import runpy, sys; device = runpy.run_path(sys.argv[1])['Device'](sys.executable); " \
                     "device.run('-u', '-c', sys.argv[2], sys.argv[3], live=True, timeout=5)"
            with subprocess.Popen([sys.executable, '-c', runner, str(ROOT / 'flash/flash.py'), script, str(ack)],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as process:
                self.assertEqual(process.stdout.readline().strip(), 'Write LBA from file (25%)')
                ack.touch()
                output, _ = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, output)
                self.assertIn('100%', output)

    def test_real_command_timeouts_apply_to_captured_and_live_output(self):
        script = "import time; print('Waiting for USB', flush=True); time.sleep(30)"
        for live in (False, True):
            with self.subTest(live=live):
                with self.assertRaisesRegex(RuntimeError, 'timed out after 1 seconds') as error:
                    flash.Device(sys.executable).run('-c', script, live=live, timeout=1)
                if not live:
                    self.assertIn('Waiting for USB', str(error.exception))

    def test_tool_failure_reports_command_exit_status_and_output(self):
        script = "print('Read LBA failed!'); raise SystemExit(7)"
        for live in (False, True):
            with self.subTest(live=live):
                with self.assertRaisesRegex(RuntimeError, 'failed \\(exit 7\\)') as error:
                    flash.Device(sys.executable).run('-c', script, live=live)
                if not live:
                    self.assertIn('Read LBA failed!', str(error.exception))

    def test_command_failure_and_interruption_prevent_reboot(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = fixture(temp)
            for command, error in [('db', RuntimeError), ('wl', RuntimeError), ('rl', RuntimeError), ('wl', KeyboardInterrupt)]:
                with self.subTest(command=command, error=error):
                    device = FakeDevice(temp)
                    original = device.run

                    def fail(*args, **kwargs):
                        if args[0] == command:
                            raise error('interrupted')
                        return original(*args, **kwargs)

                    with patch.object(device, 'run', side_effect=fail):
                        with self.assertRaises(error):
                            flash.flash(temp, manifest, device)
                    self.assertNotIn(('rd',), device.calls)
                    if command in ('db', 'wl'):
                        self.assertFalse(any(call[0] == 'rl' for call in device.calls))
                    if command == 'db':
                        self.assertFalse(any(call[0] in ('wl', 'rl') for call in device.calls))

    def test_verification_progress_never_completes_on_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = fixture(temp)
            output = io.StringIO()
            with patch.object(flash.sys, 'stdout', output):
                with self.assertRaisesRegex(RuntimeError, 'Readback mismatch'):
                    flash.flash(temp, manifest, FakeDevice(temp, corrupt=True))
            lines = [line for line in output.getvalue().splitlines() if line.startswith('Verifying')]
            self.assertTrue(lines)
            self.assertFalse(any('100%' in line for line in lines))

    def test_verification_progress_tracks_compared_chunks(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = fixture(temp)
            path = Path(temp) / 'system.bin'
            path.write_bytes(b'B' * (32 * 1024**2))
            manifest['segments'][1].update(size=path.stat().st_size, sha256=flash.digest(path))
            manifest['image_size'] = 2048 + path.stat().st_size
            device = FakeDevice(temp)
            output = io.StringIO()
            original = device.run
            with patch.object(flash.sys, 'stdout', output), patch.object(device, 'run', side_effect=
                    lambda *a, **kw: 'Flash Size: 100000 Sectors' if a[0] == 'rfi' else original(*a, **kw)):
                flash.flash(temp, manifest, device, verify_only=True)
            self.assertEqual([call[1:3] for call in device.calls if call[0] == 'rl'],
                             [(0, 2), (4, 32768), (32772, 32768)])
            lines = [line for line in output.getvalue().splitlines() if line.startswith('Verifying system.bin')]
            self.assertEqual(len(lines), 3)
            self.assertIn('50%', lines[1])
            self.assertIn('16.0/32.0 MiB', lines[1])
            self.assertIn('100%', lines[2])

    def test_progress_handles_terminal_and_redirected_output(self):
        for terminal in (True, False):
            output = io.StringIO()
            with patch.object(output, 'isatty', return_value=terminal), patch.object(flash.sys, 'stdout', output):
                with flash.Progress('Verifying system.bin', 100) as progress:
                    for done in range(1, 101):
                        progress.update(done)
            text = output.getvalue()
            self.assertIn('100%', text)
            self.assertEqual('\r' in text, terminal)
            if not terminal:
                self.assertEqual(len(text.splitlines()), 11)

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
                with patch.object(device, 'run', side_effect=lambda *a, **kw: response if a[0] == 'rfi' else original(*a, **kw)):
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
                self.assertIn('Checking bundle artifacts', result.stdout)
                self.assertNotIn('Bundle checks passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
