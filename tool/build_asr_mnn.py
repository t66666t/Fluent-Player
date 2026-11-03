"""Explicitly build the optional pinned FP32 ASR MNN adapter, without upgrading ORT."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile

from build_ocr_acceleration import ROOT, MNN_SHA, MNN_COMMIT, fetch, prepare_source, sha

SOURCES = ['native/asr_mnn/CMakeLists.txt', 'native/asr_mnn/mnn_graph.h',
           'native/asr_mnn/mnn_graph.cpp', 'native/ocr/ocr_gpu_device.cpp',
           'native/ocr/ocr_accelerator.h', 'tool/build_asr_mnn.py', 'tool/build_ocr_acceleration.py']


def verify(directory, system=None, arch=None):
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if manifest['mnnCommit'] != MNN_COMMIT or manifest['abi'] != 1:
        raise RuntimeError('Unexpected ASR MNN runtime')
    if system and manifest['platform'] != system or arch and manifest['arch'] != arch:
        raise RuntimeError('ASR MNN platform/architecture mismatch')
    for name in SOURCES:
        if manifest['sourceHashes'].get(name) != sha(ROOT / name):
            raise RuntimeError('ASR MNN adapter needs rebuilding: ' + name)
    for name, digest in manifest['files'].items():
        file = directory / name
        if '..' in Path(name).parts or not file.resolve().is_relative_to(directory.resolve()) or sha(file) != digest:
            raise RuntimeError('ASR MNN artifact mismatch: ' + name)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['windows', 'android', 'linux', 'macos'])
    parser.add_argument('--arch', default='arm64' if platform.machine().lower() in ['arm64', 'aarch64'] else 'x64')
    parser.add_argument('--work', type=Path, default=ROOT / '.artifacts/am26')
    parser.add_argument('--dependencies', type=Path, default=ROOT / '.artifacts/om26')
    parser.add_argument('--cmake', default='cmake')
    parser.add_argument('--ndk', type=Path)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if args.platform == 'macos' and platform.system() != 'Darwin':
        parser.error('macOS builds need an Apple host')
    if args.platform == 'linux' and platform.system() != 'Linux':
        parser.error('Linux builds need a Linux host')
    if args.platform == 'android':
        args.arch = 'arm64'
    dependencies = args.dependencies.resolve()
    dependencies.mkdir(parents=True, exist_ok=True)
    archive = fetch(dependencies / 'mnn-3.6.1.tar.gz',
                    'https://github.com/alibaba/MNN/archive/refs/tags/3.6.1.tar.gz', MNN_SHA)
    source = dependencies / 'MNN-3.6.1'
    if not (source / 'CMakeLists.txt').is_file():
        with tarfile.open(archive) as package:
            package.extractall(dependencies, filter='data')
    prepare_source(source)
    source_hashes = {name: sha(ROOT / name) for name in SOURCES}
    build = args.work.resolve() / (args.platform + '-' + args.arch)
    command = [args.cmake, '-S', str(ROOT / 'native/asr_mnn'), '-B', str(build),
               '-DOCR_MNN_SOURCE=' + str(source), '-DOCR_ORT_INCLUDE=' + str(dependencies),
               '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5']
    if args.platform == 'windows':
        command += ['-A', 'ARM64' if args.arch == 'arm64' else 'x64']
    elif args.platform == 'android':
        if not args.ndk:
            parser.error('--ndk is required')
        command += ['-G', 'Ninja', '-DCMAKE_TOOLCHAIN_FILE=' + str(args.ndk.resolve() / 'build/cmake/android.toolchain.cmake'),
                    '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-24', '-DANDROID_STL=c++_static']
    elif args.platform == 'macos':
        command += ['-DCMAKE_OSX_ARCHITECTURES=' + ('arm64' if args.arch == 'arm64' else 'x86_64'),
                    '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0']
    subprocess.run(command, check=True)
    subprocess.run([args.cmake, '--build', str(build), '--config', 'Release',
                    '--target', 'fluent_asr_mnn', '--parallel', str(max(1, args.jobs))], check=True)
    if source_hashes != {name: sha(ROOT / name) for name in SOURCES}:
        raise RuntimeError('ASR MNN sources changed during compilation; rerun the build before staging')
    name = 'fluent_asr_mnn.dll' if args.platform == 'windows' else 'libfluent_asr_mnn.' + ('dylib' if args.platform == 'macos' else 'so')
    binary = build / ('bin/Release' if args.platform == 'windows' else 'lib') / name
    output = ROOT / 'native/asr_mnn/prebuilt' / args.platform / args.arch
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, output / name)
    if args.platform == 'android':
        host = 'windows-x86_64' if os.name == 'nt' else 'darwin-x86_64' if platform.system() == 'Darwin' else 'linux-x86_64'
        strip = args.ndk.resolve() / ('toolchains/llvm/prebuilt/' + host + '/bin/llvm-strip' + ('.exe' if os.name == 'nt' else ''))
        subprocess.run([str(strip), '--strip-unneeded', str(output / name)], check=True)
    for directory in [source, source / '3rd_party/flatbuffers', source / '3rd_party/protobuf', source / '3rd_party/half']:
        for file in directory.iterdir():
            if file.is_file() and file.name.upper().startswith(('LICENSE', 'NOTICE', 'COPYING')):
                shutil.copy2(file, output / (directory.name + '-' + file.name))
    notices = []
    for file in sorted((source / '3rd_party').rglob('*')):
        if file.is_file() and file.name.upper().startswith(('LICENSE', 'NOTICE', 'COPYING')):
            notices.append(str(file.relative_to(source)) + '\n' + file.read_text(encoding='utf-8', errors='replace'))
    (output / 'MNN-ThirdPartyNotices.txt').write_text('\n\n'.join(notices), encoding='utf-8')
    manifest = {'abi': 1, 'platform': args.platform, 'arch': args.arch, 'mnnCommit': MNN_COMMIT,
                'sourceHashes': source_hashes,
                'files': {file.name: sha(file) for file in output.iterdir() if file.is_file() and file.name != 'manifest.json'}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    verify(output, args.platform, args.arch)
    print('Private ASR MNN component built and verified:', output)


if __name__ == '__main__':
    main()
