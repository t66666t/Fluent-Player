"""Inspect host AArch64 ELF alignment, including packaged Python extensions.

Does not install or modify the APK. Non-AArch64 DSP skeletons are reported,
not judged by the Android application process's page-size requirement.
"""
import argparse
import hashlib
import io
import json
import struct
import zipfile
from pathlib import Path


def inspect_elf(data, name):
    if not data.startswith(b'\x7fELF'):
        return None
    bits, endian = data[4], data[5]
    order = '<' if endian == 1 else '>'
    machine = struct.unpack_from(order + 'H', data, 18)[0]
    result = {'name': name, 'machine': machine, 'bits': 64 if bits == 2 else 32,
              'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)}
    if machine != 183 or bits != 2:
        result['scope'] = 'not an Android AArch64 host library'
        return result
    offset = struct.unpack_from(order + 'Q', data, 32)[0]
    size, count = struct.unpack_from(order + 'HH', data, 54)
    loads = []
    for i in range(count):
        fields = struct.unpack_from(order + 'IIQQQQQQ', data, offset + i * size)
        if fields[0] == 1:
            loads.append({'offset': fields[2], 'virtualAddress': fields[3],
                          'alignment': fields[7],
                          'congruent16k': fields[2] % 16384 == fields[3] % 16384})
    result['loads'] = loads
    result['aligned16k'] = bool(loads) and all(
        x['alignment'] >= 16384 and x['congruent16k'] for x in loads)
    return result


def audit(apk):
    libraries = []
    def visit(data, name, depth=0):
        elf = inspect_elf(data, name)
        if elf is not None:
            libraries.append(elf)
        elif depth < 4 and data.startswith(b'PK\x03\x04'):
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                for item in archive.infolist():
                    if item.is_dir() or item.file_size > 512 * 1024 * 1024:
                        continue
                    # Include .imy/.whl nested archives used by Chaquopy.
                    if item.filename.endswith(('.so', '.imy', '.whl', '.zip')):
                        visit(archive.read(item), name + '!/' + item.filename, depth + 1)
    visit(apk.read_bytes(), apk.name)
    host = [x for x in libraries if 'aligned16k' in x]
    failed = [x['name'] for x in host if not x['aligned16k']]
    return {'apk': str(apk.resolve()), 'apkSha256': hashlib.file_digest(apk.open('rb'), 'sha256').hexdigest(),
            'hostLibraries': len(host), 'otherElfFiles': len(libraries) - len(host),
            'unalignedLibraries': failed, 'allHostElfAligned16k': bool(host) and not failed,
            'runtimeTested16k': False, 'libraries': libraries}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('apk', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.apk)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k != 'libraries'}, indent=2))
