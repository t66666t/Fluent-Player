"""Check an existing signed APK before naming it as a public release artifact."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

from release_metadata import ROOT, prefix, read_version, write_platform_manifest


def validate_badging(badging, version):
    expected = {'name': 'cn.teezy.fluentplayer.standard', 'versionName': version['version'],
                'versionCode': str(version['buildNumber'])}
    package_line = next((line for line in badging.splitlines() if line.startswith('package:')), '')
    for key, value in expected.items():
        match = re.search(r'\b' + key + r"='([^']*)'", package_line)
        if not match or match[1] != value:
            raise ValueError('APK identity/version differs from the release source: ' + key)
    if 'application-debuggable' in badging:
        raise ValueError('Refusing to publish a debuggable APK')


def package(apk, sdk, certificate, output):
    certificate = certificate.replace(':', '').strip().lower()
    if not re.fullmatch('[0-9a-f]{64}', certificate):
        raise ValueError('Provide the SHA-256 certificate fingerprint of the existing release signing key')
    tool_dirs = [path for path in (sdk / 'build-tools').iterdir()
                 if path.is_dir() and re.fullmatch(r'\d+\.\d+\.\d+', path.name)]
    tools = max(tool_dirs, key=lambda path: tuple(map(int, path.name.split('.'))))
    signer = tools / ('apksigner.bat' if os.name == 'nt' else 'apksigner')
    signed = subprocess.check_output([str(signer), 'verify', '--print-certs', str(apk)], text=True)
    fingerprints = re.findall(r'certificate SHA-256 digest:\s*([a-fA-F0-9]+)', signed)
    if not fingerprints or {fingerprint.lower() for fingerprint in fingerprints} != {certificate}:
        raise ValueError('APK signer differs from the configured release identity')
    aapt = tools / ('aapt2.exe' if os.name == 'nt' else 'aapt2')
    validate_badging(subprocess.check_output([str(aapt), 'dump', 'badging', str(apk)], text=True), read_version())
    with zipfile.ZipFile(apk) as archive:
        arches = {name.split('/')[1] for name in archive.namelist() if name.startswith('lib/') and name.endswith('.so')}
        if arches != {'arm64-v8a'} or 'lib/arm64-v8a/libapp.so' not in archive.namelist():
            raise ValueError('APK must contain the complete ARM64 runtime')
    output.mkdir(parents=True, exist_ok=True)
    destination = output / (prefix('android', 'arm64') + '.apk')
    if destination.exists():
        raise ValueError('Versioned APK already exists; use a fresh output directory')
    shutil.copy2(apk, destination)
    write_platform_manifest(output, 'android', 'arm64', 'certificate-sha256:' + certificate)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, default=ROOT / 'build/app/outputs/flutter-apk/app-release.apk')
    parser.add_argument('--sdk', type=Path, default=os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT'))
    parser.add_argument('--certificate-sha256', default=os.environ.get('ANDROID_SIGNING_CERT_SHA256', ''))
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/android')
    args = parser.parse_args()
    if args.sdk is None:
        parser.error('Set ANDROID_HOME or pass --sdk')
    package(args.apk, args.sdk, args.certificate_sha256, args.output)
