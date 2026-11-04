"""Prepare pinned runtime inputs from their original publishers before building.

The community source includes an OFL CJK UI face. No downloader runtime is prepared.
Nothing in this script runs in the shipped application.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import sys
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'tool/release_assets.lock.json'
CACHE = ROOT / '.artifacts/release-inputs'


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, expected):
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / (expected + '-' + url.rsplit('/', 1)[1])
    if path.exists() and sha(path) == expected:
        return path
    temporary = path.with_suffix(path.suffix + '.partial')
    request = urllib.request.Request(url, headers={'User-Agent': 'FluentPlayer-build/1.0'})
    with urllib.request.urlopen(request, timeout=90) as source, temporary.open('wb') as sink:
        shutil.copyfileobj(source, sink)
    if sha(temporary) != expected:
        temporary.unlink()
        raise RuntimeError('Publisher input changed; update the reviewed lock: ' + url)
    temporary.replace(path)
    return path


def install(source, relative, expected=None):
    destination = ROOT / relative
    if expected and destination.exists() and sha(destination) == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + '.prepared')
    shutil.copyfile(source, temporary)
    if expected and sha(temporary) != expected:
        temporary.unlink()
        raise RuntimeError('Prepared input checksum mismatch: ' + relative)
    temporary.replace(destination)
    if destination.suffix != '.exe' and 'binaries' in destination.parts:
        destination.chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['host', 'all', 'windows', 'macos', 'linux', 'android', 'ios'], default='host')
    parser.add_argument('--fonts-only', action='store_true')
    args = parser.parse_args()
    if args.platform == 'host':
        args.platform = {'win32': 'windows', 'darwin': 'macos'}.get(sys.platform, 'linux')
    lock = json.loads(LOCK.read_text(encoding='utf-8'))
    if args.fonts_only:
        return
    if args.platform in ['all', 'windows'] and 'windowsFfmpeg' in lock:
        spec = lock['windowsFfmpeg']
        archive = download(spec['url'], spec['sha256'])
        with zipfile.ZipFile(archive) as source:
            for member, relative in spec['files'].items():
                path = ROOT / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                data = source.read(member)
                if path.exists() and hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(data).digest():
                    continue
                temporary = path.with_name(path.name + '.prepared')
                temporary.write_bytes(data)
                temporary.replace(path)
    if args.platform in ['all', 'windows']:
        spec = lock['windowsOnnxRuntime']
        destination = ROOT / spec['path']
        if not destination.exists() or sha(destination) != spec['fileSha256']:
            archive = download(spec['url'], spec['sha256'])
            with zipfile.ZipFile(archive) as source:
                data = source.read(spec['member'])
            if hashlib.sha256(data).hexdigest() != spec['fileSha256']:
                raise RuntimeError('ONNX Runtime input checksum mismatch')
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_suffix('.dll.prepared')
            temporary.write_bytes(data)
            temporary.replace(destination)


if __name__ == '__main__':
    main()
