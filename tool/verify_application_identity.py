"""Check cross-platform application identity and naming without building or device IO."""
from pathlib import Path
import plistlib
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def verify(root=ROOT):
    community = (root / 'community-contracts.json').is_file()
    appid = 'cn.teezy.fluentplayer.' + ('standard' if community else 'pro')
    name = 'Fluent Player' if community else 'Fluent Player Pro'
    company = 'Teezy Community' if community else 'Teezy'
    binary = 'fluent-player' if community else 'fluent-player-pro'
    errors = []

    def text(path):
        return (root / path).read_text(encoding='utf-8')

    def check(condition, message):
        if not condition:
            errors.append(message)

    gradle = text('android/app/build.gradle.kts')
    check(re.search(r'^        applicationId = "' + re.escape(appid) + '"$', gradle, re.M), 'Android applicationId')
    android = '{http://schemas.android.com/apk/res/android}'
    manifest = ET.parse(root / 'android/app/src/main/AndroidManifest.xml').getroot()
    check(manifest.find('application').get(android + 'label') == name, 'Android display name')
    check('${applicationId}.fileprovider' in text('android/app/src/main/AndroidManifest.xml'), 'Android provider isolation')

    check('set(BINARY_NAME "' + binary + '")' in text('windows/CMakeLists.txt'), 'Windows executable target')
    resources = text('windows/runner/Runner.rc')
    for key, expected in [('CompanyName', company), ('ProductName', name),
                          ('FileDescription', name), ('OriginalFilename', binary + '.exe')]:
        check(re.search(r'VALUE "' + key + r'", "' + re.escape(expected) + '"', resources), 'Windows ' + key)
    check('L"' + appid + '"' in text('windows/runner/desktop_app_identity.h'), 'Windows Shell app ID')
    installer = text('packaging/windows/fluent-player.iss')
    check('AppName=' + name + '\n' in installer, 'Windows installer display name')
    check('AppUserModelID: "' + appid + '"' in installer, 'Windows shortcut app ID')
    check('Filename: "{app}\\' + binary + '.exe"' in installer, 'Windows installer executable')
    check('DefaultDirName={localappdata}\\Programs\\' + name + '\n' in installer,
          'Windows installation isolation')
    check('UsePreviousAppDir=no\n' in installer, 'Windows previous installation directory isolation')
    other_binary = 'fluent-player-pro' if community else 'fluent-player'
    check('#define EditionRunner "' + binary + '.exe"' in installer and
          '#define OtherEditionRunner "' + other_binary + '.exe"' in installer and
          '#define EditionCompany "' + company + '"' in installer and
          '#define EditionProduct "' + name + '"' in installer and
          '#include "edition_guard.iss"' in installer, 'Windows installation identity guard')
    guard = text('packaging/windows/edition_guard.iss')
    check('function PrepareToInstall(var NeedsRestart: Boolean): String;' in guard and
          "ExtendedProperty('System.Company')" in guard and
          "ExtendedProperty('System.Software.ProductName')" in guard,
          'Windows pre-install runtime identity check')

    for platform in ('ios', 'macos'):
        with (root / platform / 'Runner/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        check(info.get('CFBundleDisplayName', info.get('CFBundleName')) in (name, '$(PRODUCT_NAME)'), platform + ' display name')
    appinfo = text('macos/Runner/Configs/AppInfo.xcconfig')
    check('PRODUCT_BUNDLE_IDENTIFIER = ' + appid + '\n' in appinfo, 'macOS bundle ID')
    check('PRODUCT_NAME = ' + name + '\n' in appinfo, 'macOS product name')
    ios_project = text('ios/Runner.xcodeproj/project.pbxproj')
    check(re.search(r'PRODUCT_BUNDLE_IDENTIFIER = "?' + re.escape(appid) + r'"?;', ios_project), 'iOS bundle ID')
    check('PRODUCT_NAME = "' + name + '";' in ios_project, 'iOS product name')

    linux = text('linux/CMakeLists.txt')
    check('set(APPLICATION_ID "' + appid + '")' in linux, 'Linux application ID')
    check('set(BINARY_NAME "' + binary + '")' in linux, 'Linux executable target')
    branding = text('lib/utils/app_branding.dart')
    check("const kApplicationId = '" + appid + "';" in branding, 'Dart application ID')
    check("const kAppDisplayName = '" + name + "';" in branding, 'Dart display name')
    check('const linuxApplicationId = kApplicationId;' in text('lib/platform/linux_application_identity.dart'), 'Linux storage ID')
    check('kAppDataFolderName = kApplicationId;' in text('lib/utils/app_data_paths.dart'), 'Dart data identity')
    check("title: 'Fluent_Player'" not in text('lib/main.dart'), 'Flutter fallback display name')
    check(re.fullmatch(r'[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+', appid) is not None, 'Portable identifier syntax')
    if errors:
        raise ValueError('Application identity mismatch: ' + ', '.join(errors))
    return appid


if __name__ == '__main__':
    try:
        print('Application names, package IDs and packaging entry points: passed (' + verify() + ')')
    except (ValueError, OSError, ET.ParseError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
