"""Validate package inputs and dependency discovery without building installers."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))
spec = importlib.util.spec_from_file_location(
    'package_linux_release', Path(__file__).resolve().parents[1] / 'tool/package_linux_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class LinuxReleasePackageTests(unittest.TestCase):
    def fixture(self, directory):
        bundle = Path(directory) / 'bundle'
        for relative in ('fluent-player', 'lib/libflutter_linux_gtk.so',
                         'lib/libapp.so', 'data/icudtl.dat',
                         'resources/translation/translation_worker'):
            path = bundle / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'\x7fELF\x02\x01' + bytes(12) + b'\x3e\x00')
        (bundle / 'data/flutter_assets').mkdir()
        return bundle

    def test_rejects_missing_helper_instead_of_shipping_partial_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.fixture(temporary)
            release.validate_bundle(bundle)
            (bundle / 'resources/translation/translation_worker').unlink()
            with self.assertRaisesRegex(ValueError, 'translation_worker'):
                release.validate_bundle(bundle)

    def test_rejects_foreign_runner_architecture(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.fixture(temporary)
            (bundle / 'fluent-player').write_bytes(
                b'\x7fELF\x02\x01' + bytes(12) + b'\xb7\x00')
            with self.assertRaisesRegex(ValueError, 'x64 ELF64'):
                release.validate_bundle(bundle)

    def test_dependency_scan_includes_plugins_and_isolated_helpers(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.fixture(temporary)
            (bundle / 'data/icudtl.dat').write_bytes(b'non-ELF asset')
            result = subprocess.CompletedProcess([], 0, 'shlibs:Depends=libc6 (>= 2.35), libstdc++6\n', '')
            with patch.object(release.subprocess, 'run', return_value=result) as run:
                depends = release.dependencies(Path(temporary), bundle)
            arguments = run.call_args.args[0]
            for relative in ('fluent-player', 'lib/libapp.so',
                             'resources/translation/translation_worker'):
                self.assertIn('-e' + str(bundle / relative), arguments)
            self.assertNotIn('-e' + str(bundle / 'data/icudtl.dat'), arguments)
            self.assertIn('libc6', depends)
            self.assertNotIn('libmpv1', depends)
            self.assertNotIn('ffmpeg', depends)
            self.assertNotIn('libsqlite3-0', depends)
            self.assertIn('ca-certificates', depends)

    def test_empty_dependency_scan_is_an_error(self):
        result = subprocess.CompletedProcess([], 0, '', '')
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.fixture(temporary)
            with patch.object(release.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(ValueError, 'no system dependencies'):
                    release.dependencies(Path(temporary), bundle)

    def test_distribution_names_require_the_real_build_host(self):
        self.assertEqual(release.distribution_id('ID=debian\nVERSION_ID="13"\n'), 'debian-13')
        self.assertEqual(release.distribution_id('ID=ubuntu\nVERSION_ID="24.04"\n'), 'ubuntu-24.04')
        with self.assertRaisesRegex(ValueError, 'supported distribution'):
            release.distribution_id('ID=arch\nVERSION_ID=rolling\n')

    def test_private_shlibs_prevents_host_codec_package_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.fixture(temporary)
            with patch.object(release, 'dynamic', return_value=([], 'libmpv.so.2')):
                mapping = release.private_shlibs(bundle)
            self.assertIn('libmpv 2 fluent-player', mapping)
            self.assertNotIn('libmpv1', mapping)

    def test_portable_payload_has_launchers_desktop_documentation_and_licenses(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = self.fixture(temporary)
            release.add_launchers(bundle)
            for name in ('fluent-player.sh', 'install-desktop.sh', 'README-linux.md',
                         'cn.teezy.fluentplayer.standard.desktop.in', 'fluent-player.png', 'licenses/LICENSE'):
                self.assertTrue((bundle / name).is_file(), name)
            wrapper = (bundle / 'fluent-player.sh').read_text()
            self.assertIn('LIBMPV_LIBRARY_PATH', wrapper)
            self.assertNotIn('export LD_LIBRARY_PATH', wrapper)


if __name__ == '__main__':
    unittest.main()
