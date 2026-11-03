"""Explicitly build the pinned, private OCR GPU component (never at app startup)."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
MNN_VERSION = '3.6.1'
MNN_COMMIT = 'd407447ed56c4121a11ccbd266dc184ca1ead0c2'
MNN_SHA = '4b6065c4e2674318f5bf1dc75836ce4d30c17bfe598c4a1b11b7d0b2092b06e6'
ORT_SHA = '66f16d022a0d9532af73c473b002db53b3d3c46ad400bbf3e40a1e81a647b6ae'
QNN_SHA = '9a8129b7ffe52c40a8100f0e71d72c047ad0570f6e8b25fd38fd11b5021f0ec3'
HEADER_SHA = '71125e66180a991d65c9bdbad4aa20daaa1f7a48c7a5c0fa5f18f250ac839a02'
EP_HEADER_SHA = 'b92778f50c36ecdf53d0344e0129a78b306afed653f81bba8a9597e3e6e9546f'
SOURCES = ['native/ocr/CMakeLists.txt', 'native/ocr/ocr_accelerator.h',
           'native/ocr/ocr_accelerator.cpp', 'native/ocr/ocr_qnn.cpp',
           'native/ocr/ocr_gpu_device.cpp',
           'tool/build_ocr_acceleration.py']


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch(path, url, digest):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + '.download')
        urllib.request.urlretrieve(url, temporary)
        if sha(temporary) != digest:
            temporary.unlink()
            raise RuntimeError('Unexpected download hash: ' + url)
        temporary.replace(path)
    if sha(path) != digest:
        raise RuntimeError('Unexpected cached source hash: ' + str(path))
    return path


def rename_elf_soname(data, name):
    """Change only ELF64 DT_SONAME's string, keeping all offsets and code intact."""
    if data[:6] != b'\x7fELF\x02\x01':
        raise ValueError('Expected a little-endian ELF64 library')
    result = bytearray(data)
    offset = struct.unpack_from('<Q', data, 40)[0]
    size, count = struct.unpack_from('<HH', data, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * size) for i in range(count)]
    for section in sections:
        if section[1] != 6:  # SHT_DYNAMIC
            continue
        strings = sections[section[6]][4]
        for at in range(section[4], section[4] + section[5], 16):
            tag, value = struct.unpack_from('<qQ', data, at)
            if tag == 14:  # DT_SONAME
                start = strings + value
                end = data.index(b'\0', start)
                if data[start:end] != b'libonnxruntime.so':
                    raise ValueError('Unexpected private ORT SONAME')
                encoded = name.encode('ascii')
                if len(encoded) > end - start:
                    raise ValueError('Replacement SONAME is too long')
                result[start:end] = encoded + b'\0' * (end - start - len(encoded))
                return bytes(result)
    raise ValueError('Private ORT SONAME not found')


def verify(directory, system=None, arch=None):
    directory = Path(directory).resolve()
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if manifest['mnn'] != MNN_VERSION or manifest['mnnCommit'] != MNN_COMMIT:
        raise RuntimeError('Unexpected OCR native runtime version')
    if (system and manifest['platform'] != system) or (arch and manifest['arch'] != arch):
        raise RuntimeError('OCR native platform/architecture mismatch')
    for name in SOURCES:
        if manifest['sourceHashes'].get(name) != sha(ROOT / name):
            raise RuntimeError('Rebuild the OCR GPU component after changing: ' + name)
    if not manifest['files']:
        raise RuntimeError('Empty OCR GPU component')
    for name, digest in manifest['files'].items():
        file = (directory / name).resolve()
        if not file.is_relative_to(directory) or sha(file) != digest:
            raise RuntimeError('Invalid OCR GPU artifact: ' + name)
    if manifest['platform'] == 'windows':
        data = (directory / 'fluent_ocr_accel.dll').read_bytes()
        at = struct.unpack_from('<I', data, 60)[0]
        expected = 0xAA64 if manifest['arch'] == 'arm64' else 0x8664
        if data[:2] != b'MZ' or data[at:at + 4] != b'PE\0\0' or struct.unpack_from('<H', data, at + 4)[0] != expected:
            raise RuntimeError('OCR GPU DLL has the wrong architecture')
    elif manifest['platform'] in ['android', 'linux']:
        data = (directory / 'libfluent_ocr_accel.so').read_bytes()
        expected = 183 if manifest['arch'] == 'arm64' else 62
        if data[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', data, 18)[0] != expected:
            raise RuntimeError('OCR GPU ELF has the wrong architecture')
        if manifest['platform'] == 'android':
            offset = struct.unpack_from('<Q', data, 32)[0]
            size, count = struct.unpack_from('<HH', data, 54)
            for i in range(count):
                segment = struct.unpack_from('<IIQQQQQQ', data, offset + i * size)
                if segment[0] == 1 and segment[-1] < 16384:
                    raise RuntimeError('OCR GPU library must support Android 16 KB pages')
    return manifest


def stage_qnn(work, output):
    maven = 'https://repo.maven.apache.org/maven2/'
    runtime = fetch(work / 'ort-qnn-1.23.2.aar', maven +
        'com/microsoft/onnxruntime/onnxruntime-android-qnn/1.23.2/onnxruntime-android-qnn-1.23.2.aar', ORT_SHA)
    qnn = fetch(work / 'qnn-runtime-2.37.1.aar', maven +
        'com/qualcomm/qti/qnn-runtime/2.37.1/qnn-runtime-2.37.1.aar', QNN_SHA)
    with zipfile.ZipFile(runtime) as archive:
        source = archive.read('jni/arm64-v8a/libonnxruntime.so')
        (output / 'libocr_qnn.so').write_bytes(rename_elf_soname(source, 'libocr_qnn.so'))
        notices = [n for n in archive.namelist() if n.lower().endswith(('license', 'notices.txt', 'license.txt'))]
        for i, name in enumerate(notices):
            (output / f'ORT-QNN-{i}-{Path(name).name}').write_bytes(archive.read(name))
    with zipfile.ZipFile(qnn) as archive:
        for name in archive.namelist():
            if name.startswith('jni/arm64-v8a/') and name.endswith('.so'):
                # Include the complete pinned architecture set, including v79
                # for SM8750. Drivers choose the matching stub; no SoC guessing.
                (output / Path(name).name).write_bytes(archive.read(name))
        for name in ['NOTICE.txt', 'LICENSE.pdf']:
            (output / ('QNN-' + name)).write_bytes(archive.read(name))
    for name, digest in [
        ('LICENSE', '2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c'),
        ('ThirdPartyNotices.txt', 'e9e90971a8e75a9a8ac0c6412e29c1202d079998389915aa485f46c816c3b4cc')]:
        file = fetch(work / 'ort' / name,
            'https://raw.githubusercontent.com/microsoft/onnxruntime/v1.23.2/' + name, digest)
        shutil.copy2(file, output / ('ORT-QNN-' + name))


def prepare_source(source):
    # Apply only deterministic path fixes to the generated source copy. UTF-8
    # model directories must work on Windows accounts containing CJK characters.
    file = source / 'source/core/FileLoader.cpp'
    original = file.read_text(encoding='utf-8')
    patched = original.replace('MultiByteToWideChar(CP_ACP,', 'MultiByteToWideChar(CP_UTF8,')
    patched = patched.replace('wFilename, sizeof(wFilename))', 'wFilename, sizeof(wFilename) / sizeof(wFilename[0]))')
    if patched != original:
        file.write_text(patched, encoding='utf-8')
    file = source / 'source/backend/vulkan/runtime/vulkan_wrapper.cpp'
    original = file.read_text(encoding='utf-8')
    patched = re.sub(r'(?:"libvulkan\.so\.1",\s*)*"libvulkan\.so",',
                     '"libvulkan.so.1", "libvulkan.so",', original)
    if patched != original:
        file.write_text(patched, encoding='utf-8')
    file = source / 'source/backend/opencl/CMakeLists.txt'
    original = file.read_text(encoding='utf-8')
    patched = original.replace(
        'if(${CMAKE_SYSTEM_NAME} MATCHES "Windows" OR ${CMAKE_SYSTEM_NAME} MATCHES "Linux" OR MNN_SUPPORT_INTEL_SUBGROUP)',
        'if(MNN_SUPPORT_INTEL_SUBGROUP)')
    if patched != original:
        file.write_text(patched, encoding='utf-8')
    file = source / 'source/backend/opencl/core/runtime/OpenCLWrapper.cpp'
    original = file.read_text(encoding='utf-8')
    patched = re.sub(r'(?:"libOpenCL\.so\.1",\s*)*"/usr/lib/libOpenCL\.so",',
                     '"libOpenCL.so.1", "/usr/lib/libOpenCL.so",', original)
    if patched != original:
        file.write_text(patched, encoding='utf-8')
    for relative, replacements in {
        'tools/converter/source/onnx/OnnxUtils.cpp': [
            ('std::ifstream fs(filepath,', 'std::ifstream fs(std::filesystem::u8path(filepath),')],
        'tools/converter/source/common/writeFb.cpp': [
            ('std::ofstream output(config.MNNModel,', 'std::ofstream output(std::filesystem::u8path(config.MNNModel),'),
            ('std::ofstream output(filename.c_str(),', 'std::ofstream output(std::filesystem::u8path(filename),')],
    }.items():
        file = source / relative
        original = file.read_text(encoding='utf-8')
        patched = original
        for old, new in replacements:
            patched = patched.replace(old, new)
        if patched != original:
            file.write_text('#include <filesystem>\n' + patched, encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['windows', 'android', 'linux', 'macos', 'ios'])
    parser.add_argument('--arch', default='arm64' if platform.machine().lower() in ['arm64', 'aarch64'] else 'x64')
    parser.add_argument('--work', type=Path, default=ROOT / '.artifacts/ocr-native')
    parser.add_argument('--cmake', default='cmake')
    parser.add_argument('--ndk', type=Path)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--configure-only', action='store_true')
    args = parser.parse_args()
    if args.platform in ['ios', 'macos'] and platform.system() != 'Darwin':
        raise SystemExit('Apple builds require macOS and the matching Xcode SDKs.')
    if args.platform == 'linux' and platform.system() != 'Linux':
        raise SystemExit('Linux builds require a Linux host and its native compiler.')
    if args.platform in ['android', 'ios']:
        args.arch = 'arm64'
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    archive = fetch(work / 'mnn-3.6.1.tar.gz',
        'https://github.com/alibaba/MNN/archive/refs/tags/3.6.1.tar.gz', MNN_SHA)
    source = work / 'MNN-3.6.1'
    if not (source / 'CMakeLists.txt').exists():
        with tarfile.open(archive) as compressed:
            compressed.extractall(work, filter='data')
    prepare_source(source)
    header = fetch(work / 'ort/onnxruntime_c_api.h',
        'https://raw.githubusercontent.com/microsoft/onnxruntime/v1.23.2/include/onnxruntime/core/session/onnxruntime_c_api.h', HEADER_SHA)
    fetch(work / 'ort/onnxruntime_ep_c_api.h',
        'https://raw.githubusercontent.com/microsoft/onnxruntime/v1.23.2/include/onnxruntime/core/session/onnxruntime_ep_c_api.h', EP_HEADER_SHA)
    build = work / ('w' if args.platform == 'windows' else args.platform + '-' + args.arch)
    command = [args.cmake, '-S', str(ROOT / 'native/ocr'), '-B', str(build),
        '-DOCR_MNN_SOURCE=' + str(source), '-DOCR_ORT_INCLUDE=' + str(header.parent),
        '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5']
    if args.platform == 'windows':
        command += ['-A', 'ARM64' if args.arch == 'arm64' else 'x64']
    elif args.platform == 'android':
        if not args.ndk:
            raise SystemExit('--ndk is required for the Android cross-build')
        command += ['-G', 'Ninja', '-DCMAKE_TOOLCHAIN_FILE=' + str(args.ndk.resolve() / 'build/cmake/android.toolchain.cmake'),
            '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-24', '-DANDROID_STL=c++_static']
    elif args.platform in ['ios', 'macos']:
        command += ['-DCMAKE_OSX_ARCHITECTURES=' + ('arm64' if args.arch == 'arm64' else 'x86_64')]
        if args.platform == 'ios':
            command += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0']
    subprocess.run(command, check=True)
    if args.configure_only:
        return
    subprocess.run([args.cmake, '--build', str(build), '--config', 'Release',
        '--target', 'fluent_ocr_accel', '--parallel', str(max(1, args.jobs))], check=True)
    output = ROOT / 'native/ocr/prebuilt' / args.platform / args.arch
    output.mkdir(parents=True, exist_ok=True)
    if args.platform == 'windows':
        library = build / 'bin/Release/fluent_ocr_accel.dll'
    elif args.platform == 'ios':
        library = build / 'lib/FluentOcrAcceleration.framework'
    else:
        library = build / ('lib/libfluent_ocr_accel.' + ('dylib' if args.platform == 'macos' else 'so'))
    if args.platform == 'ios':
        # Device-only frameworks must not break simulator builds. Build both
        # simulator architectures and combine them into a proper XCFramework.
        simulator_frameworks = []
        for architecture in ['arm64', 'x86_64']:
            simulator = work / ('ios-simulator-' + architecture)
            subprocess.run([args.cmake, '-S', str(ROOT / 'native/ocr'), '-B', str(simulator),
                '-DOCR_MNN_SOURCE=' + str(source), '-DOCR_ORT_INCLUDE=' + str(header.parent),
                '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
                '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT=iphonesimulator',
                '-DCMAKE_OSX_ARCHITECTURES=' + architecture, '-DCMAKE_OSX_DEPLOYMENT_TARGET=16.4'], check=True)
            subprocess.run([args.cmake, '--build', str(simulator), '--config', 'Release',
                '--target', 'fluent_ocr_accel', '--parallel', str(max(1, args.jobs))], check=True)
            simulator_frameworks.append(simulator / 'lib/FluentOcrAcceleration.framework')
        combined = work / 'ios-simulator-universal/FluentOcrAcceleration.framework'
        shutil.copytree(simulator_frameworks[0], combined, dirs_exist_ok=True)
        subprocess.run(['lipo', '-create', *[str(f / 'FluentOcrAcceleration') for f in simulator_frameworks],
            '-output', str(combined / 'FluentOcrAcceleration')], check=True)
        # xcodebuild requires a new output path; use a fresh build-owned folder.
        import tempfile
        with tempfile.TemporaryDirectory(prefix='ocr-xcframework-', dir=work) as folder:
            framework = Path(folder) / 'FluentOcrAcceleration.xcframework'
            subprocess.run(['xcodebuild', '-create-xcframework', '-framework', str(library),
                '-framework', str(combined), '-output', str(framework)], check=True)
            shutil.copytree(framework, output / framework.name, dirs_exist_ok=True)
    elif library.is_dir():
        shutil.copytree(library, output / library.name, dirs_exist_ok=True)
    else:
        shutil.copy2(library, output / library.name)
    if args.platform == 'android':
        llvm = args.ndk.resolve() / 'toolchains/llvm/prebuilt' / (
            'windows-x86_64' if os.name == 'nt' else 'darwin-x86_64' if platform.system() == 'Darwin' else 'linux-x86_64') / 'bin'
        strip = llvm / ('llvm-strip.exe' if os.name == 'nt' else 'llvm-strip')
        subprocess.run([str(strip), '--strip-unneeded', str(output / library.name)], check=True)
    for relative, name in [('LICENSE.txt', 'MNN-LICENSE'), ('3rd_party/protobuf/LICENSE', 'Protobuf-LICENSE'),
                           ('3rd_party/flatbuffers/LICENSE.txt', 'Flatbuffers-LICENSE')]:
        shutil.copy2(source / relative, output / name)
    # Keep upstream and bundled dependency notices beside the private runtime.
    # Collection is build-time only and never scans the user's model folders.
    for file in (source / '3rd_party').rglob('*'):
        if file.is_file() and file.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
            target = output / 'ThirdPartyLicenses' / file.relative_to(source / '3rd_party')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
    if args.platform == 'android':
        stage_qnn(work, output)
    manifest = {'platform': args.platform, 'arch': args.arch, 'mnn': MNN_VERSION, 'mnnCommit': MNN_COMMIT,
        'ortQnn': '1.23.2' if args.platform == 'android' else None,
        'qnn': '2.37.1' if args.platform == 'android' else None,
        'sourceHashes': {name: sha(ROOT / name) for name in SOURCES},
        'files': {file.relative_to(output).as_posix(): sha(file)
            for file in sorted(output.rglob('*')) if file.is_file() and file.name != 'manifest.json'}}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    verify(output, args.platform, args.arch)
    print('Private OCR acceleration component built and verified:', output)


if __name__ == '__main__':
    main()
