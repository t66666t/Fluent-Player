"""Apple naming and packaging contract checks; no Xcode, signing or native builds."""
from contextlib import nullcontext
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tool'))
import package_apple_release as apple

EXPECTED_BUNDLE_IDENTIFIER = 'cn.teezy.fluentplayer.standard'
NAME = 'Fluent Player'


class AppleApplicationIdentityTest(unittest.TestCase):
    def info(self):
        return {'CFBundleIdentifier': EXPECTED_BUNDLE_IDENTIFIER,
                'CFBundleDisplayName': NAME, 'CFBundleName': NAME,
                'CFBundleExecutable': NAME, 'CFBundleShortVersionString': '1.0.0',
                'CFBundleVersion': '2'}

    def test_bundle_metadata_accepts_spaces_and_rejects_other_editions(self):
        apple.verify_identity(self.info())
        other = 'cn.teezy.fluentplayer.pro'
        for value in ('com.example.videoPlayerApp', other):
            with self.subTest(identity=value), self.assertRaisesRegex(ValueError, 'identity'):
                apple.verify_identity({**self.info(), 'CFBundleIdentifier': value})
        for key in ('CFBundleDisplayName', 'CFBundleName', 'CFBundleExecutable'):
            for old in ('Fluent_Player', 'fluent_player', 'Runner', 'Fluent Player Community'):
                with self.subTest(key=key, old=old), self.assertRaisesRegex(ValueError, key):
                    apple.verify_identity({**self.info(), key: old})

    def test_plists_share_display_name_and_exported_file_type(self):
        for platform in ('ios', 'macos'):
            with (ROOT / platform / 'Runner/Info.plist').open('rb') as stream:
                info = plistlib.load(stream)
            for key in ('CFBundleDisplayName', 'CFBundleName'):
                self.assertIn(info[key], (NAME, '$(PRODUCT_NAME)'))
            self.assertEqual(info['CFBundleExecutable'], '$(EXECUTABLE_NAME)')
            self.assertEqual(info['CFBundleIdentifier'], '$(PRODUCT_BUNDLE_IDENTIFIER)')
            type_id = 'cn.teezy.fluentplayer.portable-package'
            self.assertTrue(any(type_id in d['LSItemContentTypes'] for d in info['CFBundleDocumentTypes']))
            exported = next(d for d in info['UTExportedTypeDeclarations'] if d['UTTypeIdentifier'] == type_id)
            self.assertEqual(exported['UTTypeTagSpecification']['public.filename-extension'], ['fluentpack'])

    def test_products_modules_schemes_and_test_hosts_agree(self):
        for platform in ('ios', 'macos'):
            project = (ROOT / platform / 'Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
            self.assertNotIn('com.example.videoPlayerApp', project)
            self.assertNotIn('video_player_app.app', project)
            self.assertNotIn('Runner.app', project)
            self.assertEqual(project.count('Fluent Player.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Fluent Player'), 3)
            scheme = ET.parse(ROOT / platform / 'Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme')
            applications = [r.get('BuildableName') for r in scheme.iter('BuildableReference') if r.get('BlueprintName') == 'Runner']
            self.assertEqual(applications, ['Fluent Player.app'] * 4)
            if platform == 'ios':
                self.assertEqual(project.count('PRODUCT_NAME = "Fluent Player";'), 3)
                self.assertEqual(project.count('PRODUCT_MODULE_NAME = Runner;'), 3)
                self.assertEqual(project.count('PRODUCT_BUNDLE_IDENTIFIER = ' + EXPECTED_BUNDLE_IDENTIFIER + ';'), 3)
            else:
                config = (ROOT / 'macos/Runner/Configs/AppInfo.xcconfig').read_text(encoding='utf-8')
                self.assertRegex(config, r'(?m)^PRODUCT_NAME = Fluent Player$')
                self.assertRegex(config, r'(?m)^PRODUCT_MODULE_NAME = Runner$')
                self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = ' + EXPECTED_BUNDLE_IDENTIFIER, config)
        xib = (ROOT / 'macos/Runner/Base.lproj/MainMenu.xib').read_text(encoding='utf-8')
        self.assertNotIn('APP_NAME', xib)
        self.assertIn('title="Fluent Player"', xib)
        self.assertIn('customModule="Runner"', xib)

    def test_background_refresh_identifier_matches_native_and_dart(self):
        info = plistlib.loads((ROOT / 'ios/Runner/Info.plist').read_bytes())
        self.assertEqual(info['BGTaskSchedulerPermittedIdentifiers'], ['$(PRODUCT_BUNDLE_IDENTIFIER).podcasts.refresh'])
        delegate = (ROOT / 'ios/Runner/AppDelegate.swift').read_text(encoding='utf-8')
        self.assertIn('(Bundle.main.bundleIdentifier ?? "' + EXPECTED_BUNDLE_IDENTIFIER + '") + ".podcasts.refresh"', delegate)
        dart = (ROOT / 'lib/features/podcasts/podcast_background.dart').read_text(encoding='utf-8')
        self.assertIn("'$kApplicationId.podcasts.refresh'", dart)
        branding = (ROOT / 'lib/utils/app_branding.dart').read_text(encoding='utf-8')
        self.assertIn("kApplicationId = '" + EXPECTED_BUNDLE_IDENTIFIER + "';", branding)
        for source in ('ModelDownloadBridge.swift', 'MediaCacheDownloadBridge.swift'):
            text = (ROOT / 'ios/Runner' / source).read_text(encoding='utf-8')
            self.assertIn('Bundle.main.bundleIdentifier ?? "' + EXPECTED_BUNDLE_IDENTIFIER + '"', text)

    def test_default_bundle_paths_use_the_actual_product_filename(self):
        self.assertEqual(apple.default_app('macos'), apple.ROOT / 'build/macos/Build/Products/Release/Fluent Player.app')
        self.assertEqual(apple.default_app('ios'), apple.ROOT / 'build/ios/iphoneos/Fluent Player.app')

    def test_architecture_probe_preserves_executable_path_with_spaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Fluent Player.app'
            executable = app / 'Contents/MacOS/Fluent Player'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'\xcf\xfa\xed\xfe' + bytes(32))
            with patch.object(apple.subprocess, 'check_output', return_value='arm64') as lipo:
                self.assertEqual(apple.macos_architecture(app, NAME), 'arm64')
            self.assertEqual(lipo.call_args.args[0], ['lipo', '-archs', str(executable)])

    def test_packaging_preserves_spaces_as_single_command_arguments(self):
        for platform in ('ios', 'macos'):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / 'build outputs' / 'Fluent Player.app'
                info = app / ('Contents/Info.plist' if platform == 'macos' else 'Info.plist')
                info.parent.mkdir(parents=True)
                info.write_bytes(plistlib.dumps(self.info()))
                gate = patch.object(apple, 'gate_package') if hasattr(apple, 'gate_package') else nullcontext()
                with patch.object(apple, 'verify_version'), patch.object(apple, 'macos_architecture', return_value='arm64'), \
                     patch.object(apple, 'prefix', return_value='FluentPlayer-fixture-' + platform), \
                     patch.object(apple, 'write_platform_manifest'), patch.object(Path, 'symlink_to'), \
                     patch.object(apple.subprocess, 'run') as command, gate:
                    apple.package(platform, app, root / 'download outputs')
                commands = [call.args[0] for call in command.call_args_list]
                self.assertTrue(all(isinstance(c, list) for c in commands))
                self.assertTrue(any(str(app.resolve()) in c for c in commands))
                if platform == 'ios':
                    self.assertEqual(commands[0][0], 'ditto')
                    self.assertEqual(Path(commands[0][2]).name, 'Fluent Player.app')
                    self.assertEqual(Path(commands[0][2]).parent.name, 'Payload')
                    self.assertTrue(commands[1][3].endswith('-unsigned.ipa'))
                else:
                    self.assertEqual(commands[-1][0:4], ['hdiutil', 'create', '-volname', NAME])


if __name__ == '__main__':
    unittest.main()
