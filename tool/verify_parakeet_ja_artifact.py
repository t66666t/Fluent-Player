"""Maintainer-only source, artifact and native ABI verification for Japanese Parakeet."""
import argparse
import json
from pathlib import Path
from verify_qwen_artifact import ROOT, sha


def verify(directory, platform=None, arch=None):
    directory = Path(directory).resolve()
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if platform and manifest['platform'] != platform: raise ValueError('Japanese Parakeet platform mismatch')
    if arch and manifest['arch'] != arch: raise ValueError('Japanese Parakeet architecture mismatch')
    for name, expected in manifest['sources'].items():
        file = (ROOT / name).resolve()
        if not file.is_relative_to(ROOT) or not file.is_file() or sha(file) != expected:
            raise ValueError('Japanese Parakeet component needs rebuilding: ' + name)
    for name, expected in manifest['files'].items():
        file = (directory / name).resolve()
        if not file.is_relative_to(directory) or not file.is_file() or sha(file) != expected:
            raise ValueError('Japanese Parakeet artifact mismatch: ' + name)
    if manifest['platform'] == 'windows':
        data = (directory / 'parakeet_ja_worker.exe').read_bytes(); at = int.from_bytes(data[60:64], 'little')
        if data[:2] != b'MZ' or int.from_bytes(data[at+4:at+6], 'little') != {'x64':0x8664,'arm64':0xaa64}[manifest['arch']]:
            raise ValueError('Invalid Japanese Parakeet PE architecture')
    if manifest['platform'] == 'android':
        data = (directory / 'libfluent_parakeet_ja.so').read_bytes()
        if data[:6] != b'\x7fELF\x02\x01' or int.from_bytes(data[18:20], 'little') != {'arm64':183,'x64':62}[manifest['arch']]:
            raise ValueError('Invalid Japanese Parakeet ELF architecture')
        at = int.from_bytes(data[32:40], 'little'); stride = int.from_bytes(data[54:56], 'little')
        for i in range(int.from_bytes(data[56:58], 'little')):
            entry = at+i*stride
            if int.from_bytes(data[entry:entry+4], 'little') == 1 and int.from_bytes(data[entry+48:entry+56], 'little') < 16384:
                raise ValueError('Japanese Parakeet requires Android 16 KB page alignment')
        at = int.from_bytes(data[40:48], 'little'); stride = int.from_bytes(data[58:60], 'little')
        sections = [data[at+i*stride:at+(i+1)*stride] for i in range(int.from_bytes(data[60:62], 'little'))]
        exports = set()
        for section in sections:
            if int.from_bytes(section[4:8], 'little') != 11: continue
            strings = sections[int.from_bytes(section[40:44], 'little')]; base = int.from_bytes(strings[24:32], 'little')
            start = int.from_bytes(section[24:32], 'little'); size = int.from_bytes(section[32:40], 'little')
            for symbol in range(start, start+size, 24):
                if data[symbol+4] >> 4 not in (1,2) or int.from_bytes(data[symbol+6:symbol+8], 'little') == 0: continue
                begin = base+int.from_bytes(data[symbol:symbol+4], 'little')
                exports.add(data[begin:data.index(b'\0', begin)].decode('ascii'))
        if any(name.startswith(('ggml_', 'gguf_', 'transcribe_')) for name in exports):
            raise ValueError('Japanese Parakeet exports unisolated runtime symbols')
        for operation in ('create','request','cancel','destroy'):
            if 'fluent_parakeet_ja_'+operation not in exports: raise ValueError('Missing Japanese Parakeet C ABI: '+operation)
        for operation in ('Create','Request','Cancel','Destroy'):
            if 'Java_com_example_video_1player_1app_QwenAsrService_native'+operation not in exports:
                raise ValueError('Missing Japanese Parakeet JNI: '+operation)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path); parser.add_argument('--platform'); parser.add_argument('--arch')
    args = parser.parse_args(); verify(args.directory,args.platform,args.arch)
    print('Japanese Parakeet sources, artifacts and native ABI verified.')
