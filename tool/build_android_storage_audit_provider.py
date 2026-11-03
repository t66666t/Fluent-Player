"""Build an isolated storage-test APK with Android SDK tools; never install it.

Uses only synthetic lavfi fixtures and a dedicated generated debug identity.
No Gradle, Flutter, production signing configuration or application data is read.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tool/android_storage_audit_provider'
PACKAGE = 'com.fluentplayer.audit.documents'
TARGET = 'com.example.video_player_app.sidebar_profile'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, default=Path(os.environ.get('ANDROID_HOME', str(Path(os.environ['LOCALAPPDATA']) / 'Android/sdk'))))
    parser.add_argument('--java-home', type=Path, default=Path('D:/Android Studio/jbr'))
    parser.add_argument('--build-tools', default='36.0.0')
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg'))
    parser.add_argument('--reuse-fixtures-from-apk', type=Path,
                        help='Reuse and verify exact fixture bytes and metadata from an existing audit APK; no media regeneration')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/android-release-audit-20261031/evidence/provider')
    args = parser.parse_args()
    if not args.ffmpeg and not args.reuse_fixtures_from_apk:
        parser.error('Provide an existing local FFmpeg executable with --ffmpeg')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = output / ('build-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
    work.mkdir()
    tools = args.sdk / 'build-tools' / args.build_tools
    android = args.sdk / 'platforms/android-36/android.jar'
    java = args.java_home / 'bin'
    assets = work / 'assets'; fixtures = assets / 'fixtures'; fixtures.mkdir(parents=True)
    classes = work / 'classes'; classes.mkdir()
    dex = work / 'dex'; dex.mkdir()
    env = dict(os.environ, JAVA_HOME=str(args.java_home))
    env['PATH'] = str(java) + os.pathsep + env.get('PATH', '')
    commands = []

    def run(label, command):
        command = [str(value) for value in command]
        commands.append({'label': label, 'command': command})
        result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding='utf8', errors='replace')
        (work / (label + '.log')).write_text(result.stdout, encoding='utf8')
        if result.returncode:
            raise RuntimeError(f'{label} failed ({result.returncode}); see {work / (label + ".log")}\n{result.stdout[-4000:]}')
        return result.stdout

    if args.reuse_fixtures_from_apk:
        # Copy named bytes only: never extract arbitrary paths or regenerate
        # media that would invalidate the device's existing fixture receipts.
        with zipfile.ZipFile(args.reuse_fixtures_from_apk) as previous:
            metadata_bytes = previous.read('assets/fixture-metadata.json')
            metadata = json.loads(metadata_bytes)
            names = {item['file'] for item in metadata['files']}
            if metadata.get('synthetic') is not True or metadata.get('targetPackage') != TARGET or names != {
                    'audio.mp3', 'subtitles.srt', 'video.mp4', 'video-b.mp4'}:
                raise ValueError('Reuse source is not the fixed synthetic audit fixture')
            total = 0
            for item in metadata['files']:
                data = previous.read('assets/fixtures/' + item['file'])
                total += len(data)
                if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
                    raise ValueError('Reuse source fixture bytes/hash mismatch: ' + item['file'])
                if total > 8 * 1024 * 1024:
                    raise ValueError('Synthetic fixture budget exceeded')
                (fixtures / item['file']).write_bytes(data)
            (assets / 'fixture-metadata.json').write_bytes(metadata_bytes)
    else:
        ffmpeg = [args.ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-y']
        for name, video, frequency in [('video.mp4', 'testsrc2=size=320x180:rate=24', 440),
                                       ('video-b.mp4', 'color=c=teal:size=320x180:rate=24', 880)]:
            run('fixture-' + name, ffmpeg + ['-f', 'lavfi', '-i', video, '-f', 'lavfi', '-i',
                f'sine=frequency={frequency}:sample_rate=16000', '-t', '12', '-c:v', 'libx264',
                '-preset', 'veryfast', '-crf', '32', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '32k',
                '-ac', '1', '-threads', '1', '-map_metadata', '-1', '-movflags', '+faststart', fixtures / name])
        run('fixture-audio', ffmpeg + ['-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=32000',
            '-t', '60', '-c:a', 'libmp3lame', '-b:a', '48k', '-ac', '1', '-threads', '1',
            '-map_metadata', '-1', fixtures / 'audio.mp3'])
        (fixtures / 'subtitles.srt').write_text('1\n00:00:00,200 --> 00:00:02,000\n合成存储测试 · Synthetic fixture\n\n2\n00:00:03,000 --> 00:00:05,000\nNo user data.\n', encoding='utf8')
        files = [{'file': path.name, 'bytes': path.stat().st_size, 'sha256': sha(path),
                  'durationSeconds': 12 if path.suffix == '.mp4' else 60 if path.suffix == '.mp3' else None}
                 for path in sorted(fixtures.iterdir())]
        if sum(item['bytes'] for item in files) > 8 * 1024 * 1024:
            raise ValueError('Synthetic fixture budget exceeded')
        metadata = {'synthetic': True, 'source': 'Local FFmpeg lavfi; subtitle text generated here; no external/user media',
                    'targetPackage': TARGET, 'files': files,
                    'documents': {'video': 'video.mp4', 'audio': 'audio.mp3', 'subtitles': 'subtitles.srt',
                                  'duplicate-a': 'video.mp4', 'duplicate-b': 'video-b.mp4',
                                  'denied': 'SecurityException on open', 'truncated': 'video.mp4, declared size +4096',
                                  'error': 'reliable pipe fails after 32 bytes', 'slow': 'video.mp4 in about 7 seconds'},
                    'receiverLimits': {'batchBytes': 64 * 1024 * 1024, 'retainedBytes': 256 * 1024 * 1024, 'receipts': 128}}
        (assets / 'fixture-metadata.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding='utf8')
    run('javac', [java / 'javac.exe', '-J-Duser.language=en', '-J-Duser.country=US', '-encoding', 'UTF-8', '--release', '17',
                  '-classpath', android, '-d', classes, *sorted(SOURCE.glob('*.java'))])
    run('d8', [tools / 'd8.bat', '--min-api', '24', '--lib', android, '--output', dex, *sorted(classes.rglob('*.class'))])
    resources = work / 'resources.apk'
    run('aapt2-link', [tools / 'aapt2.exe', 'link', '-o', resources, '--manifest', SOURCE / 'AndroidManifest.xml',
                     '-I', android, '-A', assets, '--min-sdk-version', '24', '--target-sdk-version', '36',
                     '--version-code', '2', '--version-name', '0.2-test'])
    unsigned = work / 'unsigned.apk'; shutil.copy2(resources, unsigned)
    with zipfile.ZipFile(unsigned, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(dex.glob('*.dex')): archive.write(path, path.name)
    aligned = work / 'aligned.apk'
    run('zipalign', [tools / 'zipalign.exe', '-f', '4', unsigned, aligned])
    # This key belongs solely to the fixture. Never read android/key.properties.
    key = output / 'fixture-debug.keystore'
    if args.reuse_fixtures_from_apk and not key.exists():
        raise ValueError('Fixture reuse requires the existing fixture debug key; do not generate a replacement identity')
    if not key.exists():
        run('debug-key', [java / 'keytool.exe', '-genkeypair', '-keystore', key, '-storepass', 'android',
                         '-keypass', 'android', '-alias', 'androiddebugkey', '-dname', 'CN=Android Debug,O=Android,C=US',
                         '-keyalg', 'RSA', '-keysize', '2048', '-validity', '3650', '-noprompt'])
    apk = output / 'fluent-storage-audit-provider.apk'
    run('sign', [tools / 'apksigner.bat', 'sign', '--ks', key, '--ks-key-alias', 'androiddebugkey',
                 '--ks-pass', 'pass:android', '--key-pass', 'pass:android', '--out', apk, aligned])
    certificate = run('verify-signature', [tools / 'apksigner.bat', 'verify', '--verbose', '--print-certs', apk])
    signer = re.search(r'certificate SHA-256 digest:\s*([0-9a-f]+)', certificate).group(1)
    if args.reuse_fixtures_from_apk:
        prior_certificate = run('verify-reuse-source-signature',
            [tools / 'apksigner.bat', 'verify', '--print-certs', args.reuse_fixtures_from_apk])
        prior_signer = re.search(r'certificate SHA-256 digest:\s*([0-9a-f]+)', prior_certificate).group(1)
        if prior_signer != signer:
            raise ValueError('Fixture debug signing identity changed')
    with zipfile.ZipFile(apk) as packaged:
        if packaged.read('assets/fixture-metadata.json') != (assets / 'fixture-metadata.json').read_bytes():
            raise ValueError('Packaged fixture metadata differs')
        for item in metadata['files']:
            data = packaged.read('assets/fixtures/' + item['file'])
            if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
                raise ValueError('Packaged fixture bytes/hash mismatch')
    badging = run('verify-badging', [tools / 'aapt2.exe', 'dump', 'badging', apk])
    manifest = run('verify-manifest', [tools / 'aapt2.exe', 'dump', 'xmltree', apk, '--file', 'AndroidManifest.xml'])
    run('verify-zipalign', [tools / 'zipalign.exe', '-c', '4', apk])
    if f"package: name='{PACKAGE}'" not in badging or "targetSdkVersion:'36'" not in badging or not re.search(r"(?:minSdkVersion|sdkVersion):'24'", badging):
        raise ValueError('Unexpected test APK identity/SDK')
    if 'application-debuggable' not in badging or 'CN=Android Debug' not in certificate:
        raise ValueError('Fixture must remain debuggable and debug-signed')
    if 'android.permission.INTERNET' in manifest or 'uses-permission' in manifest:
        raise ValueError('Fixture must request no permissions, including networking')
    result = {'status': 'built-and-verified-not-installed', 'apk': str(apk), 'apkSha256': sha(apk),
              'apkBytes': apk.stat().st_size, 'package': PACKAGE, 'authority': PACKAGE,
              'versionCode': 2, 'certificateSha256': signer,
              'receiverActions': ['SEND', 'SEND_MULTIPLE', 'VIEW'],
              'fixtureReuseSource': str(args.reuse_fixtures_from_apk) if args.reuse_fixtures_from_apk else None,
              'fixtureMetadataPreservedByteIdentical': bool(args.reuse_fixtures_from_apk),
              'minSdk': 24, 'targetSdk': 36, 'debuggable': True, 'productionKeyRead': False,
              'strictShareTarget': TARGET + '/com.example.video_player_app.MainActivity',
              'shareActivity': PACKAGE + '.AuditShareActivity', 'receiveActivity': PACKAGE + '.AuditReceiveActivity',
              'providerClass': PACKAGE + '.FixtureDocumentsProvider', 'work': str(work),
              'fixtureMetadata': metadata, 'commands': commands,
              'sourceHashes': {str(path.relative_to(ROOT)).replace('\\', '/'): sha(path)
                               for path in [*sorted(SOURCE.glob('*')), Path(__file__)] if path.is_file()},
              'limitations': ['SDK build/manifest/signature verification only; DocumentsUI, URI grants and streams need device validation by root.']}
    (output / 'provider-build-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf8')
    shutil.copy2(assets / 'fixture-metadata.json', output / 'fixture-metadata.json')
    print(json.dumps({key: result[key] for key in ['status', 'apk', 'apkSha256', 'apkBytes', 'strictShareTarget']}, indent=2))


if __name__ == '__main__':
    main()
