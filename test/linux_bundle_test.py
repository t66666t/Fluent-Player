"""Loader and ABI regressions, with tiny fixtures (no application builds)."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tool'))
import linux_bundle as bundle
from configure_linux_plugins import configure


class LinuxBundleTests(unittest.TestCase):
    def test_missing_transitive_dependency_is_not_ignored(self):
        with self.assertRaisesRegex(ValueError, 'Missing ELF dependency'):
            bundle.parse_ldd('libmpv.so.1 => not found\n')
        self.assertEqual(bundle.parse_ldd('libmpv.so.2 => /app with spaces/lib/libmpv.so.2 (0x1234)'),
                         {'libmpv.so.2': Path('/app with spaces/lib/libmpv.so.2')})

    def test_codec_libraries_are_private_but_drivers_and_glibc_are_host_owned(self):
        for name in ('libmpv.so.1', 'libmpv.so.2', 'libavcodec.so.58', 'libavcodec.so.61', 'libx265.so.215'):
            self.assertFalse(bundle.host_library(name), name)
        for name in ('libc.so.6', 'ld-linux-x86-64.so.2', 'libstdc++.so.6', 'libGLX.so.0', 'libdrm_amdgpu.so.1'):
            self.assertTrue(bundle.host_library(name), name)

    def test_plugin_and_sidecar_each_resolve_their_own_libraries(self):
        app = Path('/application')
        self.assertEqual(bundle.relative_rpath(app / 'lib/plugin.so', app), '$ORIGIN')
        self.assertEqual(bundle.relative_rpath(app / 'video_player_app', app), '$ORIGIN:$ORIGIN/lib')
        self.assertEqual(bundle.relative_rpath(app / 'resources/translation/worker', app),
                         '$ORIGIN:$ORIGIN/../../lib')

    def test_same_soname_with_different_bytes_is_never_silently_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            (app / 'lib').mkdir()
            target = app / 'lib/libmpv.so.2'
            target.write_bytes(b'one ABI implementation')
            source = app / 'another-build.so'
            source.write_bytes(b'another implementation')
            with self.assertRaisesRegex(ValueError, 'Conflicting libraries'):
                bundle.copy_library(source, target.name, app, {}, {})
            self.assertEqual(target.read_bytes(), b'one ABI implementation')

    def test_loader_audit_rejects_ci_absolute_runpath(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            path = app / 'plugin.so'
            path.write_bytes(b'\x7fELF' + bytes(20))
            with patch.object(bundle, 'dynamic', return_value=(['libc.so.6'], None)), \
                 patch.object(bundle, 'output', return_value='/home/runner/work/project/linux/flutter/ephemeral'):
                with self.assertRaisesRegex(ValueError, 'Non-relocatable'):
                    bundle.audit(app)

    def test_driver_dependencies_stay_host_owned_but_direct_private_libraries_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary)
            (app / 'plugin.so').write_bytes(b'\x7fELF' + bytes(20))
            closure = {'libGL.so.1': Path('/host/libGL.so.1'),
                       'libexpat.so.1': Path('/host/libexpat.so.1')}
            with patch.object(bundle, 'output', return_value='$ORIGIN'), \
                 patch.object(bundle, 'dependencies', return_value=closure):
                with patch.object(bundle, 'dynamic', return_value=(['libGL.so.1'], None)):
                    self.assertEqual(bundle.audit(app), 1)
                with patch.object(bundle, 'dynamic', return_value=(['libexpat.so.1'], None)):
                    with self.assertRaisesRegex(ValueError, 'Unbundled runtime dependency'):
                        bundle.audit(app)

    def test_relocation_collects_mpv_transitive_libraries_and_media_clis(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, system = root / 'app', root / 'system'
            (app / 'lib').mkdir(parents=True)
            system.mkdir()
            for path in [app / 'lib/plugin.so', system / 'libmpv.so', system / 'libavcodec.so.58',
                         system / 'libavutil.so.56', system / 'libpulse.so.0',
                         system / 'libpulsecommon-17.0.so', system / 'libsqlite3.so.0',
                         system / 'ffmpeg', system / 'ffprobe']:
                path.write_bytes(b'\x7fELF' + path.name.encode())

            def dynamic(path):
                name = path.name
                if name in ('libmpv.so', 'libmpv.so.1'):
                    return ['libavcodec.so.58', 'libpulse.so.0'], 'libmpv.so.1'
                if name == 'libavcodec.so.58':
                    return ['libavutil.so.56'], name
                if name == 'libpulse.so.0':
                    return ['libpulsecommon-17.0.so'], name
                return [], name if name.startswith('lib') else None

            def dependencies(path, environment):
                found = {name: system / name for name in dynamic(path)[0]}
                if path.name == 'libmpv.so.1':
                    found['libpulsecommon-17.0.so'] = system / 'libpulsecommon-17.0.so'
                if path.name == 'libpulse.so.0':
                    self.assertTrue((app / 'lib/libpulsecommon-17.0.so').exists(),
                                    'Collect private transitive libraries before replacing their original RUNPATH')
                return found

            with patch.object(bundle, 'output', return_value=str(system)), \
                 patch.object(bundle, 'system_library', return_value=system / 'libsqlite3.so.0'), \
                 patch.object(bundle, 'dynamic', side_effect=dynamic), \
                 patch.object(bundle, 'dependencies', side_effect=dependencies), \
                 patch.object(bundle, 'record_copyright', return_value='fixture-package'), \
                 patch.object(bundle.shutil, 'which', side_effect=lambda name: str(system / name)), \
                 patch.object(bundle.subprocess, 'run'), patch.object(bundle, 'audit'):
                manifest = bundle.relocate(app)
            self.assertEqual(manifest['mpvSoname'], 'libmpv.so.1')
            for name in ('libmpv.so.1', 'libavcodec.so.58', 'libavutil.so.56',
                         'libpulse.so.0', 'libpulsecommon-17.0.so', 'libsqlite3.so.0'):
                self.assertTrue((app / 'lib' / name).is_file(), name)
            self.assertTrue((app / 'bin/ffmpeg').is_file())
            self.assertTrue((app / 'bin/ffprobe').is_file())

    def test_cli_plugin_configuration_keeps_flutter_output_untouched(self):
        source = Path(__file__).resolve().parents[1] / 'linux/flutter'
        originals = {name: (source / name).read_bytes() for name in
                     ('generated_plugins.cmake', 'generated_plugin_registrant.cc')}
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            configure(source, destination)
            for path in destination.iterdir():
                self.assertNotIn('ffmpeg_kit_flutter_new', path.read_text())
            self.assertIn('media_kit_video', (destination / 'plugins.cmake').read_text())
        for name, content in originals.items():
            self.assertEqual((source / name).read_bytes(), content)


if __name__ == '__main__':
    unittest.main()
