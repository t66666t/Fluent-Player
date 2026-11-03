"""Explicitly build the pinned, private Cohere audio component (no app runtime upgrades)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
from urllib.request import urlopen
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'native/cohere_asr'
LOCK = json.loads((NATIVE / 'runtime.lock.json').read_text(encoding='utf-8'))


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inputs():
    paths = [p for p in NATIVE.rglob('*') if p.is_file() and 'prebuilt' not in p.parts]
    paths += [ROOT / 'tool/build_cohere_asr.py']
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(paths)}


def download(path, entry):
    if not path.exists() or sha(path) != entry['sha256']:
        temporary = path.with_suffix('.part')
        with urlopen(entry['url'], timeout=120) as source, temporary.open('wb') as output:
            shutil.copyfileobj(source, output)
        if sha(temporary) != entry['sha256']:
            raise ValueError('Pinned Cohere dependency hash mismatch: ' + path.name)
        temporary.replace(path)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['windows', 'linux', 'macos', 'android', 'ios'])
    parser.add_argument('--arch', choices=['x64', 'arm64'])
    parser.add_argument('--ndk', type=Path)
    parser.add_argument('--cmake')
    parser.add_argument('--parallel', default='8')
    parser.add_argument('--cmake-arg', action='append', default=[])
    parser.add_argument('--ios-simulator', action='store_true')
    args = parser.parse_args()
    arch = args.arch or ('arm64' if args.platform in ('android', 'ios') or platform.machine().lower() in ('arm64', 'aarch64') else 'x64')
    if args.platform in ('macos', 'ios') and sys.platform != 'darwin':
        parser.error('Apple builds require an Apple host')
    work = ROOT / '.artifacts/cohere-integration'
    deps = work / 'deps'; deps.mkdir(parents=True, exist_ok=True)
    archive = download(deps / 'transcribe-source.zip', LOCK['transcribe'])
    sources = work / 'source'
    source = sources / ('transcribe.cpp-' + LOCK['transcribe']['revision'])
    if not source.exists():
        with zipfile.ZipFile(archive) as package:
            for name in package.namelist():
                if not (sources / name).resolve().is_relative_to(sources.resolve()):
                    raise ValueError('Invalid source archive path')
            package.extractall(sources)
    download(deps / 'json.hpp', LOCK['json'])
    json_license = download(deps / 'nlohmann-json-MIT.txt', LOCK['jsonLicense'])
    symbols = work / 'symbols.h'
    identifiers = set()
    for directory in [source / 'ggml', source / 'include', source / 'src']:
        for file in directory.rglob('*'):
            if file.suffix in ('.h', '.hpp', '.c', '.cpp', '.m', '.mm'):
                identifiers.update(re.findall(r'\b(?:ggml|gguf|transcribe)_[A-Za-z0-9_]+\b', file.read_text(encoding='utf-8', errors='ignore')))
    symbols.write_text('#pragma once\n' + ''.join(f'#define {name} fluent_cohere_{name}\n' for name in sorted(identifiers)), encoding='utf-8')
    cmake = args.cmake or shutil.which('cmake')
    if not cmake and os.name == 'nt':
        cmake = next((str(p) for p in Path('D:/Microsoft Visual Studio').glob('*/**/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe')), None)
    if not cmake:
        parser.error('CMake 3.22+ is required')
    source_hashes = inputs()
    build_id = hashlib.sha256(json.dumps({'sources': source_hashes, 'pins': LOCK, 'platform': args.platform, 'arch': arch, 'iosSimulator': args.ios_simulator, 'cmakeArguments': args.cmake_arg}, sort_keys=True).encode()).hexdigest()
    suffix = '-sim' if args.ios_simulator else ''
    build = work / f'build-{args.platform}-{arch}{suffix}'
    configure = [cmake, '-S', str(NATIVE), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
                 '-DCOHERE_SOURCE=' + str(source), '-DCOHERE_JSON_INCLUDE=' + str(deps),
                 '-DCOHERE_SYMBOL_PREFIX_HEADER=' + str(symbols), '-DCOHERE_BUILD_ID=' + build_id]
    if args.platform == 'windows':
        configure += ['-A', 'ARM64' if arch == 'arm64' else 'x64']
    elif args.platform == 'android':
        if not args.ndk:
            parser.error('Android requires --ndk')
        configure += ['-G', 'Ninja', '-DCMAKE_TOOLCHAIN_FILE=' + str(args.ndk / 'build/cmake/android.toolchain.cmake'),
                      '-DANDROID_ABI=' + ('arm64-v8a' if arch == 'arm64' else 'x86_64'), '-DANDROID_PLATFORM=24', '-DANDROID_STL=c++_static']
        if os.name == 'nt' and not shutil.which('ninja'):
            ninja = Path(cmake).parent.parent.parent / 'Ninja/ninja.exe'
            if not ninja.exists():
                ninja = args.ndk.parent.parent / 'cmake/3.22.1/bin/ninja.exe'
            configure += ['-DCMAKE_MAKE_PROGRAM=' + str(ninja)]
        if arch == 'arm64':
            configure += ['-DGGML_CPU_ARM_ARCH=armv8-a']
    if args.platform in ('macos', 'ios'):
        configure += ['-DCMAKE_OSX_ARCHITECTURES=' + ('arm64' if arch == 'arm64' else 'x86_64')]
    if args.platform == 'ios':
        configure += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT=' + ('iphonesimulator' if args.ios_simulator else 'iphoneos')]
    configure += args.cmake_arg
    subprocess.run(configure, check=True)
    targets = ['fluent_cohere_asr' if args.platform in ('android', 'ios') else 'cohere_asr_worker']
    if args.platform not in ('android', 'ios'):
        targets += ['ggml-cpu-x64', 'ggml-cpu-haswell', 'ggml-cpu-alderlake'] if arch == 'x64' else ['ggml-cpu']
    subprocess.run([cmake, '--build', str(build), '--config', 'Release', '--parallel', args.parallel, '--target', *targets], check=True)
    stage = NATIVE / 'prebuilt' / f'{args.platform}-{arch}{suffix}'; stage.mkdir(parents=True, exist_ok=True)
    if args.platform == 'windows':
        files = list(build.rglob('*.dll')) + [next(build.rglob('cohere_asr_worker.exe'))]
    elif args.platform == 'ios':
        combined = build / 'libfluent_cohere_asr_combined.a'
        subprocess.run(['xcrun', 'libtool', '-static', '-o', str(combined), *[str(p) for p in build.rglob('*.a') if p != combined]], check=True)
        files = [combined]
    else:
        files = [p for p in build.rglob('*') if p.is_file() and (re.search(r'\.so(?:\.\d+)*$', p.name) or p.name.endswith('.dylib') or p.name == 'cohere_asr_worker')]
    manifest_files = {}
    for file in files:
        destination = stage / file.name
        shutil.copy2(file, destination)
        manifest_files[destination.name] = sha(destination)
    for file in source.rglob('*'):
        if file.is_file() and (file.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE'))):
            destination = stage / 'licenses/transcribe' / file.relative_to(source)
            destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(file, destination)
            manifest_files[destination.relative_to(stage).as_posix()] = sha(destination)
    for name, file in [('Fluent-Player-MIT.txt', NATIVE/'LICENSE'), ('Apache-2.0.txt', ROOT / 'assets/licenses/Apache-2.0.txt'), ('nlohmann-json-MIT.txt', json_license)]:
        if not file.exists():
            raise ValueError('Missing license: ' + name)
        destination = stage / 'licenses' / name
        destination.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(file, destination)
        manifest_files[destination.relative_to(stage).as_posix()] = sha(destination)
    manifest = {'version': 1, 'platform': args.platform, 'arch': arch, 'backend': 'cpu', 'build': build_id,
                'sources': source_hashes, 'pins': LOCK, 'files': manifest_files, 'batchSize': 1, 'maxSpeechSeconds': 8,
                'cmakeArguments': args.cmake_arg}
    (stage / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print('Cohere audio runtime staged:', stage, flush=True)


if __name__ == '__main__': main()
