"""Xcode Runner build phase: bundle CPython stdlib, packages and signed extensions."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / 'packages/ios_ytdlp/ios/Vendor'


def install(environment=os.environ):
    app = Path(environment['CODESIGNING_FOLDER_PATH']).resolve()
    build = Path(environment['TARGET_BUILD_DIR']).resolve()
    if not app.is_relative_to(build) or app.suffix != '.app':
        raise ValueError('Unexpected application bundle destination')
    manifest = json.loads((VENDOR / 'prepared.json').read_text())
    expected = json.loads((VENDOR.parent.parent / 'runtime.lock.json').read_text())
    if manifest != expected:
        raise ValueError('iOS runtime preparation is stale; run prepare_ios_runtime.py')
    framework = VENDOR / 'Python.xcframework'
    simulator = environment.get('EFFECTIVE_PLATFORM_NAME') == '-iphonesimulator'
    platform = framework / ('ios-arm64_x86_64-simulator' if simulator else 'ios-arm64')
    stdlib = app / 'python/lib'
    stdlib.mkdir(parents=True, exist_ok=True)
    shutil.copytree(framework / 'lib', stdlib, dirs_exist_ok=True,
        ignore=shutil.ignore_patterns('libpython*.dylib', '__pycache__', 'test', 'tests', 'idlelib', 'tkinter'))
    architectures = environment.get('ARCHS', 'arm64').split()
    if environment.get('ONLY_ACTIVE_ARCH') == 'YES':
        active = environment.get('NATIVE_ARCH_ACTUAL', architectures[0])
        architectures = [active if active in architectures else architectures[0]]
    binaries = {}
    for architecture in architectures:
        source = platform / ('lib-' + architecture)
        shutil.copytree(source, stdlib, dirs_exist_ok=True,
            ignore=shutil.ignore_patterns('libpython*.dylib', '__pycache__'))
        for binary in source.rglob('*.so'):
            binaries.setdefault(binary.relative_to(source), []).append(binary)
    if len(architectures) > 1:
        for relative, slices in binaries.items():
            subprocess.run(['xcrun', 'lipo', '-create', *map(str, slices), '-output', str(stdlib / relative)], check=True)
    packages = app / 'fluent-python-packages'
    shutil.copytree(VENDOR / 'site-packages', packages, dirs_exist_ok=True,
        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    # Pod install may be cached after Python source edits. Bundle the current
    # app sources on every Xcode build rather than stale preparation copies.
    if (ROOT / 'android/app/src/main/python/yt_dlp_bridge.py').exists():
        for name in ('yt_dlp_bridge.py', 'fluent_resume.py'):
            shutil.copy2(ROOT / 'android/app/src/main/python' / name, packages / name)
        for source in (ROOT / 'packages/ios_ytdlp/python').glob('*.py'):
            shutil.copy2(source, packages / source.name)
    # CPython's AppleFrameworkLoader expects .fwork and .origin references.
    extension_root = stdlib / 'python3.13/lib-dynload'
    for binary in extension_root.rglob('*.so'):
        module = binary.name.split('.')[0]
        destination = app / 'Frameworks' / (module + '.framework')
        destination.mkdir(parents=True, exist_ok=True)
        info = {
            'CFBundleExecutable': module,
            'CFBundleIdentifier': environment.get('PRODUCT_BUNDLE_IDENTIFIER', 'com.example.video-player') + '.' + module.replace('_', '-'),
            'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': module,
            'CFBundlePackageType': 'FMWK', 'CFBundleShortVersionString': '3.13',
            'CFBundleVersion': '1', 'MinimumOSVersion': '15.1',
            'CFBundleSupportedPlatforms': ['iPhoneSimulator' if simulator else 'iPhoneOS'],
        }
        with (destination / 'Info.plist').open('wb') as sink:
            plistlib.dump(info, sink)
        shutil.copy2(binary, destination / module)
        marker = binary.with_suffix('.fwork')
        marker.write_text(str((destination / module).relative_to(app)) + '\n')
        (destination / (module + '.origin')).write_text(str(marker.relative_to(app)) + '\n')
        privacy = binary.parent / (module + '.xcprivacy')
        if privacy.exists():
            shutil.copy2(privacy, destination / 'PrivacyInfo.xcprivacy')
        binary.unlink()
        if environment.get('CODE_SIGNING_ALLOWED') != 'NO':
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', environment.get('EXPANDED_CODE_SIGN_IDENTITY') or '-',
                '--timestamp=none', '--preserve-metadata=identifier,entitlements,flags', str(destination)], check=True)
    # License records shipped alongside the bundled components.
    licenses = app / 'fluent-runtime-licenses'
    licenses.mkdir(exist_ok=True)
    shutil.copy2(VENDOR / 'LICENSE-QuickJS-NG.txt', licenses / 'LICENSE-QuickJS-NG.txt')
    shutil.copy2(framework / 'lib/python3.13/LICENSE.txt', licenses / 'LICENSE-Python.txt')
    for record in packages.glob('*.dist-info/licenses/*'):
        if record.is_file():
            shutil.copy2(record, licenses / (record.parent.parent.name + '-' + record.name))


if __name__ == '__main__':
    install()
