# SPDX-License-Identifier: MIT
"""Exercise board extension hooks, artifact inputs and upstream tracking."""
import copy
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from w132dlib import build, inputs, repository
from w132dlib.common import ROOT, output, read_json, run


class Upstreams(unittest.TestCase):
    def test_uboot_tags_are_paginated_and_numeric(self):
        def api(url):
            if 'kernel.org' in url:
                return {'releases': [{'moniker': 'stable', 'version': '7.2.10'}]}
            if '/armbian/' in url:
                return [{'tag_name': 'v26.5.1', 'draft': False, 'prerelease': False}]
            if url.endswith('page=1'):
                return [{'name': f'v2027.01-rc{i}'} for i in range(100)]
            return [{'name': name} for name in ('v2026.07', 'v2026.10', 'v2026.10.1', 'c2027.01')]

        with patch.object(inputs, 'api', side_effect=api), \
                patch.object(inputs, 'resolve_tag', return_value='b' * 40) as resolve:
            selected = inputs.upstreams()
        self.assertEqual(selected['uboot'], {'tag': 'v2026.10.1', 'commit': 'b' * 40})
        resolve.assert_any_call('u-boot/u-boot', 'v2026.10.1')

    def test_no_stable_uboot_tag_fails(self):
        def api(url):
            if 'kernel.org' in url:
                return {'releases': [{'moniker': 'stable', 'version': '7.2.10'}]}
            if '/armbian/' in url:
                return [{'tag_name': 'v26.5.1', 'draft': False, 'prerelease': False}]
            return [{'name': 'v2027.01-rc1'}]

        with patch.object(inputs, 'api', side_effect=api), self.assertRaisesRegex(ValueError, 'No official U-Boot'):
            inputs.upstreams()

    def test_uboot_only_update_is_detected_and_recorded(self):
        from test_release import lock
        current = lock()
        previous = repository.next_state({}, current, [])
        self.assertEqual(previous['channels']['stable'][0]['uboot'], current['uboot'])
        with patch.object(repository, 'remote_state', return_value=previous):
            self.assertFalse(inputs.changed(current))
            candidate = copy.deepcopy(current)
            candidate['uboot']['tag'] = 'v2027.01'
            self.assertTrue(inputs.changed(candidate))
            del previous['channels']['stable'][0]['uboot']
            self.assertTrue(inputs.changed(current))

    @unittest.skipUnless(shutil.which('dpkg'), 'dpkg version comparison is required')
    def test_upstream_regressions_and_retagging_are_rejected(self):
        from test_release import lock
        current = lock()
        previous = repository.next_state({}, current, [])
        for name, older in (('linux', 'v7.2.9'), ('armbian', 'v26.5.0'), ('uboot', 'v2026.07')):
            candidate = copy.deepcopy(current)
            candidate['version'] = '20261016.101.1'
            candidate[name]['tag'] = older
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'version regression: ' + name):
                repository.next_state(previous, candidate, [])
            candidate[name] = dict(current[name], commit='b' * 40)
            with self.subTest(retag=name), self.assertRaisesRegex(ValueError, 'different commit: ' + name):
                repository.next_state(previous, candidate, [])
        del previous['channels']['stable'][0]['uboot']
        candidate = dict(current, version='20261016.101.1')
        self.assertEqual(repository.next_state(previous, candidate, [])['channels']['stable'][0]['uboot'], current['uboot'])

    def test_uboot_release_candidates_cannot_be_locked(self):
        candidate = read_json(ROOT / 'config/sources.json')
        candidate.update(schema=1, channel='experimental', version='20261017.100.1~experimental',
                         inputs={}, project_commit='a' * 40, project_dirty=True)
        candidate['uboot']['tag'] = 'v2027.01-rc1'
        with patch.object(inputs, 'source_hashes', return_value={}), \
                patch.object(inputs, 'output', return_value='a' * 40), \
                self.assertRaisesRegex(ValueError, 'Only official U-Boot'):
            inputs.validate_lock(candidate)


class Extension(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='w132d-extension-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.candidate = read_json(ROOT / 'config/sources.json')
        self.candidate.update(version='20261017.100.1', source_date_epoch=1000000000, inputs={'board': 'digest'})
        self.userpatches = build.stage(self.candidate, self.root, {})
        self.extension = self.userpatches / 'extensions/w132d'

    def hook(self, script, **env):
        return output(['bash', '-e', '-o', 'pipefail', '-c',
                       'exit_with_error() { echo "$*" >&2; exit 1; }; '
                       'source "$USERPATCHES_PATH/extensions/w132d/w132d.sh"; ' + script],
                      env=dict(os.environ, USERPATCHES_PATH=str(self.userpatches), **env))

    def test_native_board_settings_select_locked_sources(self):
        settings = self.hook('post_family_config__w132d; '
                             'printf "%s\\n" "$KERNELBRANCH" "$BOOTBRANCH" "$BOOTPATCHDIR" '
                             '"$CPUMIN" "$CPUMAX" "$GOVERNOR" "$CPUFREQUTILS_ENABLE"')
        self.assertEqual(settings.splitlines(), ['commit:' + self.candidate['linux']['commit'],
                                                'commit:' + self.candidate['uboot']['commit'],
                                                'w132d', '408000', '2016000', 'schedutil', 'false'])
        self.assertTrue(list((self.userpatches / 'u-boot/w132d').glob('*.patch')))
        self.assertFalse((self.userpatches / 'overlay/bsp-cli/etc/default/cpufrequtils').exists())

    def test_firmware_and_board_changes_invalidate_bootloader_and_bsp(self):
        def cache_hooks():
            return self.hook('declare -f pre_config_uboot_target__w132d_content_hash; '
                             'declare -f post_family_tweaks_bsp__w132d_content_hash').split('post_family_tweaks_bsp', 1)

        original = cache_hooks()
        self.candidate['version'] = '20261018.101.1'
        build.stage(self.candidate, self.root, {})
        self.assertEqual(original, cache_hooks())
        for field, value in (('blobs', {'ddr': {'sha256': 'new-firmware'}}),
                             ('inputs', {'board': 'new-source'})):
            with self.subTest(field=field):
                self.candidate[field] = value
                build.stage(self.candidate, self.root, {})
                changed = cache_hooks()
                self.assertTrue(all(a != b for a, b in zip(original, changed)))
                original = changed

    @unittest.skipUnless(shutil.which('rsync') and shutil.which('dpkg-deb'), 'BSP packaging tools are required')
    def test_bsp_owns_only_its_board_configuration(self):
        destination = self.root / 'bsp'
        (destination / 'DEBIAN').mkdir(parents=True)
        (destination / 'etc').mkdir()
        (destination / 'etc/armbian-release').write_text('BOARD=w132d\n')
        conffiles = destination / 'DEBIAN/conffiles'
        conffiles.write_text('/etc/upstream.conf\n')
        (destination / 'etc/upstream.conf').touch()
        (self.extension / 'inputs/wcn').write_bytes(b'firmware fixture')
        self.hook('artifact_package_hook_helper_board_side_functions() { :; }; '
                  'postinst_functions=(); postrm_functions=(); post_family_tweaks_bsp__w132d',
                  destination=str(destination))
        owned = set(conffiles.read_text().splitlines())
        self.assertIn('/etc/upstream.conf', owned)
        self.assertNotIn('/etc/armbian-release', owned)
        self.assertNotIn('/etc/default/cpufrequtils', owned)
        for config in (self.userpatches / 'overlay/bsp-cli/etc').rglob('*'):
            if config.is_file():
                self.assertIn('/etc/' + str(config.relative_to(self.userpatches / 'overlay/bsp-cli/etc')), owned)
        (destination / 'DEBIAN/control').write_text(
            'Package: w132d-bsp-test\nVersion: 1\nArchitecture: all\n'
            'Maintainer: Test <test@example.invalid>\nDescription: BSP fixture\n')
        package = self.root / 'bsp.deb'
        run(['dpkg-deb', '--root-owner-group', '--build', destination, package], stdout=subprocess.DEVNULL)
        if os.geteuid() == 0:
            device = self.root / 'device'
            (device / 'var/lib/dpkg').mkdir(parents=True)
            (device / 'var/lib/dpkg/status').touch()
            (device / 'etc/default').mkdir(parents=True)
            cpufreq = device / 'etc/default/cpufrequtils'
            cpufreq.write_text('GOVERNOR=schedutil\n')
            run(['dpkg', '--root=' + str(device), '--install', package], input='', text=True,
                stdout=subprocess.DEVNULL)
            self.assertEqual(cpufreq.read_text(), 'GOVERNOR=schedutil\n')

    def test_kernel_overlay_commit_is_reproducible(self):
        tree = self.root / 'kernel'
        tree.mkdir()
        run(['git', 'init', '-q', tree])
        for relative in ('drivers/net/wireless/Kconfig', 'drivers/net/wireless/Makefile',
                         'sound/soc/codecs/Kconfig', 'sound/soc/codecs/Makefile',
                         'arch/arm64/boot/dts/rockchip/Makefile', 'Documentation/devicetree/bindings/fixture'):
            target = tree / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('# fixture\n')
        (tree / 'Makefile').write_text('VERSION = 7\n')
        run(['git', '-C', tree, 'add', '.'])
        run(['git', '-C', tree, '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
             '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'])
        base = output(['git', '-C', tree, 'rev-parse', 'HEAD'])
        patches = self.userpatches / 'kernel/w132d'
        shutil.rmtree(patches)
        patches.mkdir()
        (patches / 'fixture.patch').write_text(
            'diff --git a/Makefile b/Makefile\n--- a/Makefile\n+++ b/Makefile\n'
            '@@ -1 +1 @@\n-VERSION = 7\n+VERSION = 8\n')
        results = []
        for inherited_date in ('@1100000000 +0000', '@1200000000 +0000'):
            run(['git', '-C', tree, 'reset', '--hard', base], stdout=subprocess.DEVNULL)
            run(['git', '-C', tree, 'clean', '-fd'], stdout=subprocess.DEVNULL)
            result = self.hook('W132D_LINUX_SHA="$fixture_base"; kernel_copy_extra_sources__w132d; '
                               'git -C "$kernel_work_dir" show -s --format=%H:%at:%ct',
                               kernel_work_dir=str(tree), fixture_base=base,
                               GIT_AUTHOR_DATE=inherited_date, GIT_COMMITTER_DATE=inherited_date)
            results.append(result)
        self.assertEqual(results[0], results[1])
        self.assertTrue(results[0].endswith(':1000000000:1000000000'))


if __name__ == '__main__':
    unittest.main()
