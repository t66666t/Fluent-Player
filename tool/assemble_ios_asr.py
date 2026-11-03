"""Assemble the two Apple-built static ASR slices without embedding ONNX Runtime.

Run on macOS after build_asr_accelerator.py --platform ios for device arm64
and again with --ios-simulator --arch universal2 in a separate build directory.
"""
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ['native/asr/asr_accelerator.cpp', 'native/asr/firered_ctc.h', 'native/asr/session_options.inc',
           'native/asr/fluent_asr_observer.h', 'native/asr/CMakeLists.txt', 'tool/prepare_asr_native.py']


def sha(file):
    with file.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(directory):
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('sherpa') != '1.12.12' or manifest.get('ort') != '1.23.0' or manifest.get('ortLinkage') != 'external-app':
        raise RuntimeError('The unified iOS archive must use the existing ORT 1.23.0 pod')
    for name in SOURCES:
        if manifest['sourceHashes'].get(name) != sha(ROOT / name):
            raise RuntimeError('Rebuild stale iOS ASR sources: ' + name)
    for name, digest in manifest['files'].items():
        file = (directory / name).resolve()
        if not file.is_relative_to(directory.resolve()) or sha(file) != digest:
            raise RuntimeError('Invalid iOS ASR artifact: ' + name)
    if not (directory / 'ffi-symbols.txt').is_file():
        raise RuntimeError('Missing iOS static FFI retention symbols; rebuild the archive')
    return manifest


if __name__ == '__main__':
    if platform.system() != 'Darwin': raise SystemExit('An Apple host and Xcode are required')
    device, simulator = [ROOT / 'native/asr/prebuilt' / name for name in ['ios-arm64', 'ios-simulator']]
    manifest = verify(device)
    verify(simulator)
    if (device / 'ffi-symbols.txt').read_bytes() != (simulator / 'ffi-symbols.txt').read_bytes():
        raise RuntimeError('Device/simulator ASR FFI exports do not match')
    output = ROOT / 'native/asr/prebuilt/ios-unified'
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='asr-ios-') as temporary:
        framework = Path(temporary) / 'FluentAsr.xcframework'
        subprocess.run(['xcodebuild', '-create-xcframework',
            '-library', str(device / 'libfluent_asr_accel.a'),
            '-library', str(simulator / 'libfluent_asr_accel.a'), '-output', str(framework)], check=True)
        destination = output / framework.name
        if destination.exists():
            # A fixed, tool-owned staging directory, never application/user data.
            if not destination.resolve().is_relative_to(output.resolve()): raise RuntimeError('Unsafe staging path')
            shutil.rmtree(destination)
        shutil.copytree(framework, destination)
    for name in ['LICENSE', 'ThirdPartyNotices.txt', 'ffi-symbols.txt']: shutil.copy2(device / name, output / name)
    manifest.update(arch='universal2', files={str(file.relative_to(output)): sha(file)
        for file in output.rglob('*') if file.is_file() and file.name != 'manifest.json'})
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print('Unified ASR archive ready; CoreML remains disabled until signed device validation is recorded.')
