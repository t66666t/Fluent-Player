"""Package a built community Apple bundle; this does not sign or publish it."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

from release_metadata import ROOT, prefix, read_version, write_platform_manifest

DISPLAY_NAME = 'Fluent Player'
BUNDLE_IDENTIFIER = 'cn.teezy.fluentplayer.standard'
MACHO = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe',
         b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def default_app(platform):
    folder = 'build/macos/Build/Products/Release' if platform == 'macos' else 'build/ios/iphoneos'
    return ROOT / folder / (DISPLAY_NAME + '.app')


def verify_identity(info):
    if info.get('CFBundleIdentifier') != BUNDLE_IDENTIFIER:
        raise ValueError('App bundle identity differs from this edition; rebuild the current source')
    for key in ('CFBundleDisplayName', 'CFBundleName', 'CFBundleExecutable'):
        if info.get(key) != DISPLAY_NAME:
            raise ValueError('App bundle name differs from the release source: ' + key)


def verify_version(info):
    current = read_version()
    if (info.get('CFBundleShortVersionString') != current['version']
            or str(info.get('CFBundleVersion')) != str(current['buildNumber'])):
        raise ValueError('App bundle version differs from pubspec.yaml; rebuild the current source')


def macos_architecture(app, executable):
    candidates = [app / 'Contents/MacOS' / executable]
    frameworks = app / 'Contents/Frameworks'
    if frameworks.exists():
        candidates.extend(p for p in frameworks.rglob('*') if p.is_file() and not p.is_symlink())
    common = {'arm64', 'x86_64'}
    checked = 0
    for path in candidates:
        with path.open('rb') as source:
            if source.read(4) not in MACHO:
                continue
        architectures = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
        common.intersection_update(architectures)
        checked += 1
    if not checked or not common:
        raise ValueError('App and framework architectures do not have a compatible slice')
    return 'universal' if len(common) == 2 else ('arm64' if 'arm64' in common else 'x64')


def package(platform, app, output):
    app = app.resolve()
    output = output.resolve()
    with (app / ('Contents/Info.plist' if platform == 'macos' else 'Info.plist')).open('rb') as source:
        info = plistlib.load(source)
    verify_identity(info)
    verify_version(info)
    architecture = macos_architecture(app, info['CFBundleExecutable']) if platform == 'macos' else 'arm64'
    output.mkdir(parents=True, exist_ok=True)
    name = prefix(platform, architecture)
    with tempfile.TemporaryDirectory(prefix='fluent-community-apple-') as temporary:
        staging = Path(temporary)
        if platform == 'macos':
            subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent',
                            str(app), str(output / (name + '.zip'))], check=True)
            subprocess.run(['ditto', str(app), str(staging / app.name)], check=True)
            (staging / 'Applications').symlink_to('/Applications')
            subprocess.run(['hdiutil', 'create', '-volname', DISPLAY_NAME,
                            '-srcfolder', str(staging), '-ov', '-format', 'UDZO',
                            str(output / (name + '.dmg'))], check=True)
        else:
            payload = staging / 'Payload'
            payload.mkdir()
            subprocess.run(['ditto', str(app), str(payload / app.name)], check=True)
            subprocess.run(['zip', '-qry', '--symlinks', str(output / (name + '-unsigned.ipa')),
                            'Payload'], cwd=staging, check=True)
    write_platform_manifest(output, platform, architecture,
                            'ad-hoc; not notarized' if platform == 'macos' else 'unsigned')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos', 'ios'])
    parser.add_argument('--app', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    package(args.platform, args.app or default_app(args.platform),
            args.output or ROOT / 'dist' / args.platform)
