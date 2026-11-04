"""Validate a staged native component without loading it into the player."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['native/asr/asr_accelerator.cpp', 'native/asr/firered_ctc.h', 'native/asr/session_options.inc',
           'native/asr/fluent_asr_observer.h', 'native/asr/CMakeLists.txt', 'tool/prepare_asr_native.py',
           'native/asr/mnn_session.h', 'native/asr_mnn/mnn_graph.h']


def sha(file):
    with file.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify_binary(file, system, machine):
    data = file.read_bytes()
    if system == 'windows':
        if len(data) < 64 or data[:2] != b'MZ':
            raise RuntimeError('Not a PE binary: ' + file.name)
        at = struct.unpack_from('<I', data, 60)[0]
        if at + 6 > len(data) or data[at:at + 4] != b'PE\0\0' or struct.unpack_from('<H', data, at + 4)[0] != {'x64': 0x8664, 'arm64': 0xaa64}[machine]:
            raise RuntimeError('Wrong PE architecture: ' + file.name)
    elif system in ['linux', 'android']:
        if len(data) < 64 or data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != {'x64': 62, 'arm64': 183}[machine]:
            raise RuntimeError('Wrong ELF architecture: ' + file.name)
        if system == 'android':
            start = struct.unpack_from('<Q', data, 32)[0]
            stride, count = struct.unpack_from('<HH', data, 54)
            if stride < 56 or start + stride * count > len(data):
                raise RuntimeError('Invalid ELF program headers: ' + file.name)
            loads = [struct.unpack_from('<IIQQQQQQ', data, start + stride * i)
                     for i in range(count)
                     if struct.unpack_from('<I', data, start + stride * i)[0] == 1]
            if not loads or any(header[7] < 16384 for header in loads):
                raise RuntimeError('Android ASR requires 16 KB page alignment: ' + file.name)


def verify(directory, platform=None, arch=None):
    directory = directory.resolve()
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('sherpa') != '1.12.12' or (platform and manifest.get('platform') != platform):
        raise RuntimeError('Mismatched ASR runtime/platform')
    if arch and manifest.get('arch') not in [arch, 'universal2']:
        raise RuntimeError('Mismatched ASR architecture')
    if any('asr_mnn' in name for name in manifest.get('files', {})) and not manifest.get('mnnSourceHashes'):
        raise RuntimeError('Missing ASR MNN source manifest')
    for name in SOURCES:
        if manifest['sourceHashes'].get(name) != sha(ROOT / name):
            raise RuntimeError('Native sources changed; rebuild the ASR component: ' + name)
    for name, digest in manifest.get('mnnSourceHashes', {}).items():
        if not (ROOT / name).resolve().is_relative_to(ROOT) or sha(ROOT / name) != digest:
            raise RuntimeError('Rebuild the ASR MNN adapter: ' + name)
    if not manifest.get('files'): raise RuntimeError('Empty ASR component manifest')
    for name, digest in manifest['files'].items():
        file = (directory / name).resolve()
        if not file.is_relative_to(directory) or sha(file) != digest:
            raise RuntimeError('Invalid native ASR file: ' + name)
    system = manifest['platform']
    machine = manifest['arch']
    if system in ['windows', 'linux', 'android']:
        for name in manifest['files']:
            if name.endswith(('.dll', '.exe', '.so')) or name == 'asr_worker':
                verify_binary(directory / name, system, machine)
    elif system == 'ios' and (manifest.get('ort') != '1.23.0' or manifest.get('ortLinkage') != 'external-app'):
        raise RuntimeError('iOS must link to the existing application ORT 1.23.0')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--platform')
    parser.add_argument('--arch')
    args = parser.parse_args()
    verify(args.directory, args.platform, args.arch)
    print('ASR native artifact verified:', args.directory)
