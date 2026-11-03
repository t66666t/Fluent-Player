"""Build and stage the private ASR accelerator; never alter the Pub cache.

Windows: python tool/build_asr_accelerator.py --platform windows
Other hosts: pass --ort-root containing include/ and lib/ for the matching
ORT build. Android additionally needs --ndk; its ORT is 1.23.2 from the same
Maven AAR as OCR. iOS is built only on Apple hosts and remains validation-gated.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
from urllib.request import urlopen
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--platform', choices=['windows', 'linux', 'macos', 'android', 'ios'], required=True)
parser.add_argument('--arch')
parser.add_argument('--ort-root', type=Path)
parser.add_argument('--ndk', type=Path)
parser.add_argument('--cmake')
parser.add_argument('--parallel', default='8')
parser.add_argument('--build-dir', type=Path)
parser.add_argument('--ios-simulator', action='store_true')
args = parser.parse_args()
if args.arch is None:
    args.arch = 'arm64' if args.platform in ['android', 'ios'] or platform.machine().lower() in ['arm64', 'aarch64'] else 'x64'
deps = ROOT / '.artifacts/asr-gpu/deps'
deps.mkdir(parents=True, exist_ok=True)

def sha(file):
    with file.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def stage_file(source, destination):
    """Publish a complete artifact; never truncate a DLL being verified/read."""
    if destination.is_file() and sha(source) == sha(destination):
        return
    temporary = destination.with_name(destination.name + f'.{os.getpid()}.tmp')
    try:
        shutil.copy2(source, temporary)
        temporary.replace(destination)
    finally:
        if temporary.exists(): temporary.unlink()

def download(name, url, digest):
    file = deps / name
    if not file.exists() or sha(file) != digest:
        temporary = file.with_suffix(file.suffix + '.part')
        with urlopen(url, timeout=180) as source, temporary.open('wb') as target:
            shutil.copyfileobj(source, target)
        if sha(temporary) != digest:
            raise RuntimeError('Unexpected dependency SHA-256: ' + name)
        temporary.replace(file)
    return file

source_zip = download('sherpa-onnx-v1.12.12.zip',
    'https://github.com/k2-fsa/sherpa-onnx/archive/refs/tags/v1.12.12.zip',
    '2ea3f9ff855c59ccbcb9ee71574452b4f0463a7708930321bb6993259c35919b')
source = deps / 'sherpa-onnx-1.12.12'
if not source.exists():
    with zipfile.ZipFile(source_zip) as archive: archive.extractall(deps)
download('json.hpp', 'https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp',
         '9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6')
ort_zip = download('ort-dml-1.21.0.zip',
    'https://www.nuget.org/api/v2/package/Microsoft.ML.OnnxRuntime.DirectML/1.21.0',
    '12bed6e1e870f30e0150e039ebb6853da32eba381eda1c373faeeb17168785e6')
if not (deps / 'ort-dml/build/native/include/onnxruntime_c_api.h').exists():
    with zipfile.ZipFile(ort_zip) as archive: archive.extractall(deps / 'ort-dml')
headers = deps / 'ort-dml/build/native/include'
if args.platform == 'windows':
    ort = deps / 'ort-dml/runtimes' / ('win-arm64' if args.arch == 'arm64' else 'win-x64') / 'native'
    library = ort / 'onnxruntime.lib'
    directml = download('directml-1.15.4.zip',
        'https://www.nuget.org/api/v2/package/Microsoft.AI.DirectML/1.15.4',
        '4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9')
    if not (deps / 'directml-1.15.4/bin/x64-win/DirectML.dll').exists():
        with zipfile.ZipFile(directml) as archive: archive.extractall(deps / 'directml-1.15.4')
elif args.platform == 'android' and args.ort_root is None:
    aar = download('ort-android-1.23.2.zip',
        'https://repo.maven.apache.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.23.2/onnxruntime-android-1.23.2.aar',
        '82048d1f462218adae4ba76477089ab0ba76093d84f733540066db1a8ba6b827')
    if not (deps / 'ort-android/jni').exists():
        with zipfile.ZipFile(aar) as archive: archive.extractall(deps / 'ort-android')
    ort = deps / 'ort-android/jni' / ('arm64-v8a' if args.arch == 'arm64' else 'x86_64')
    library = ort / 'libonnxruntime.so'
else:
    if args.ort_root is None:
        parser.error('--ort-root is required for this platform; CPU packaging remains available without it')
    ort = args.ort_root.resolve() / 'lib'
    api_header = args.ort_root / 'include/onnxruntime_c_api.h'
    if api_header.exists() and api_header.stat().st_size > 1000: headers = args.ort_root / 'include'
    candidates = list(ort.glob('libonnxruntime*'))
    library = next((file for file in candidates if file.name in ['libonnxruntime.so', 'libonnxruntime.dylib', 'libonnxruntime.a']), None)
    if library is None: raise RuntimeError('Matching ORT library missing in ' + str(ort))
if not library.exists(): raise RuntimeError('Matching ORT architecture is unavailable: ' + str(library))
cmake = args.cmake or shutil.which('cmake')
if not cmake and os.name == 'nt':
    matches = list(Path('D:/Microsoft Visual Studio').glob('*/**/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'))
    if matches: cmake = str(matches[0])
if not cmake: raise RuntimeError('CMake 3.24 or newer is required')
build = args.build_dir.resolve() if args.build_dir else ROOT / (f'.artifacts/asr-gpu/build-{args.platform}-{args.arch}' +
    ('-simulator' if args.platform == 'ios' and args.ios_simulator else ''))
configure = [cmake, '-S', str(ROOT / 'native/asr'), '-B', str(build),
    '-DSHERPA_SOURCE_DIR=' + str(source), '-DASR_ORT_INCLUDE=' + str(headers),
    '-DASR_ORT_LIBRARY=' + str(library), '-DASR_JSON_INCLUDE=' + str(deps),
    '-DPython3_EXECUTABLE=' + os.sys.executable, '-DCMAKE_BUILD_TYPE=Release']
if args.platform == 'windows': configure += ['-A', 'ARM64' if args.arch == 'arm64' else 'x64']
if args.platform == 'android':
    if not args.ndk: parser.error('--ndk is required for Android')
    ninja = shutil.which('ninja')
    if not ninja and os.name == 'nt':
        candidates = [Path(cmake).parent.parent.parent / 'Ninja/ninja.exe']
        sdk = Path(os.environ.get('ANDROID_SDK_ROOT', str(Path(os.environ['LOCALAPPDATA']) / 'Android/sdk')))
        candidates += list(sdk.glob('cmake/*/bin/ninja.exe'))
        ninja = next((str(file) for file in candidates if file.exists()), None)
    if ninja: configure += ['-DCMAKE_MAKE_PROGRAM=' + ninja]
    configure += ['-G', 'Ninja', '-DCMAKE_TOOLCHAIN_FILE=' + str(args.ndk / 'build/cmake/android.toolchain.cmake'),
                  '-DANDROID_ABI=' + ('arm64-v8a' if args.arch == 'arm64' else 'x86_64'),
                  '-DANDROID_PLATFORM=android-24', '-DANDROID_STL=c++_static']
if args.platform == 'macos':
    configure += ['-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0', '-DCMAKE_OSX_ARCHITECTURES=' +
                  ('arm64;x86_64' if args.arch == 'universal2' else 'arm64' if args.arch == 'arm64' else 'x86_64')]
if args.platform == 'ios':
    if platform.system() != 'Darwin': parser.error('iOS requires an Apple host with Xcode')
    configure += ['-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_DEPLOYMENT_TARGET=16.4',
                  '-DCMAKE_OSX_SYSROOT=' + ('iphonesimulator' if args.ios_simulator else 'iphoneos'),
                  '-DCMAKE_OSX_ARCHITECTURES=' + ('arm64;x86_64' if args.arch == 'universal2' else
                    'arm64' if args.arch == 'arm64' else 'x86_64')]
subprocess.run(configure, check=True, cwd=ROOT)
target = 'fluent_asr_accel' if args.platform in ['android', 'ios'] else 'asr_worker'
subprocess.run([cmake, '--build', str(build), '--config', 'Release', '--target', target,
                '--parallel', args.parallel], check=True, cwd=ROOT)
if args.platform == 'android':
    output = ROOT / 'native/asr/prebuilt/android' / ('arm64-v8a' if args.arch == 'arm64' else 'x86_64')
elif args.platform == 'ios':
    output = ROOT / ('native/asr/prebuilt/ios-simulator' if args.ios_simulator else 'native/asr/prebuilt/ios-arm64')
else: output = ROOT / f'native/asr/prebuilt/{args.platform}-{args.arch}'
output.mkdir(parents=True, exist_ok=True)
filename = 'asr_worker.exe' if args.platform == 'windows' else 'asr_worker'
if args.platform in ['android', 'ios']: filename = 'libfluent_asr_accel.so' if args.platform == 'android' else 'libfluent_asr_accel.a'
built = next((file for file in build.rglob(filename) if file.is_file()), None)
if built is None: raise RuntimeError('Native build output missing')
if args.platform == 'ios':
    # One static sherpa archive, with NO second ORT embedded. CocoaPods resolves
    # its undefined OrtGetApiBase against onnxruntime-objc/c 1.23.0, also used by OCR.
    archives = sorted({file.resolve() for file in build.rglob('*.a')
                       if 'onnxruntime' not in file.name and file.name != 'libfluent_asr_combined.a'})
    merged = build / 'libfluent_asr_combined.a'
    subprocess.run(['xcrun', 'libtool', '-static', '-o', str(merged), *map(str, archives)], check=True)
    defined = subprocess.check_output(['xcrun', 'nm', '-gU', str(merged)], text=True)
    if '_OrtGetApiBase' in defined: raise RuntimeError('iOS archive embeds an ORT copy; refusing to stage')
    if '_FluentAsrRequest' not in defined or '_SherpaOnnxCreateOfflineRecognizer' not in defined:
        raise RuntimeError('iOS archive is missing required FFI exports')
    symbols = sorted(set(re.findall(r'\b(?:_SherpaOnnx[A-Za-z0-9_]+|_FluentAsr(?:Request|Free))\b', defined)))
    (output / 'ffi-symbols.txt').write_text('\n'.join(symbols) + '\n', encoding='utf-8')
    shutil.copy2(merged, output / filename)
else: stage_file(built, output / filename)
if args.platform not in ['android', 'ios']:
    for file in ort.iterdir():
        if file.is_file() and (file.suffix in ['.dll', '.dylib'] or '.so' in file.name):
            stage_file(file, output / file.name)
    (output / filename).chmod(0o755)
if args.platform == 'windows':
    stage_file(deps / 'directml-1.15.4/bin' / ('arm64-win' if args.arch == 'arm64' else 'x64-win') / 'DirectML.dll', output / 'DirectML.dll')
notices = []
for label, directory in [('sherpa-onnx 1.12.12', source), ('ONNX Runtime', deps / 'ort-dml'),
                         *([('DirectML 1.15.4', deps / 'directml-1.15.4')] if args.platform == 'windows' else []),
                         *[(p.name, p) for p in (build / '_deps').glob('*-src')]]:
    for file in sorted(directory.iterdir()):
        if file.is_file() and file.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE', 'THIRDPARTYNOTICES')):
            notices.append(label + ' / ' + file.name + '\n' + file.read_text(encoding='utf-8', errors='replace'))
notices.append('nlohmann/json 3.11.3 — Copyright (c) 2013-2023 Niels Lohmann\n'
               'MIT License\n\nPermission is hereby granted, free of charge, to any person obtaining a copy '
               'of this software and associated documentation files (the "Software"), to deal in the Software '
               'without restriction, including without limitation the rights to use, copy, modify, merge, publish, '
               'distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the '
               'Software is furnished to do so, subject to the following conditions:\n\nThe above copyright '
               'notice and this permission notice shall be included in all copies or substantial portions of the '
               'Software.\n\nTHE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, '
               'INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE '
               'AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, '
               'DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, '
               'OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.')
(output / 'LICENSE').write_text((source / 'LICENSE').read_text(encoding='utf-8'), encoding='utf-8')
(output / 'ThirdPartyNotices.txt').write_text('\n\n'.join(notices), encoding='utf-8')
mnn_sources = None
if args.platform in ['windows', 'android', 'linux', 'macos']:
    from build_asr_mnn import verify as verify_mnn
    mnn = ROOT / 'native/asr_mnn/prebuilt' / args.platform / args.arch
    if (mnn / 'manifest.json').is_file():
        mnn_manifest = verify_mnn(mnn, args.platform, args.arch)
        for name in mnn_manifest['files']:
            stage_file(mnn / name, output / name)
        stage_file(mnn / 'manifest.json', output / 'mnn-manifest.json')
        mnn_sources = mnn_manifest['sourceHashes']
manifest = {'version': 1, 'sherpa': '1.12.12', 'platform': args.platform, 'arch': args.arch,
            'files': {file.name: sha(file) for file in output.iterdir() if file.is_file() and file.name != 'manifest.json'},
            'sourceHashes': {str(file.relative_to(ROOT)).replace('\\', '/'): sha(file) for file in [
                ROOT / 'native/asr/asr_accelerator.cpp', ROOT / 'native/asr/firered_ctc.h', ROOT / 'native/asr/session_options.inc',
                ROOT / 'native/asr/fluent_asr_observer.h', ROOT / 'native/asr/CMakeLists.txt',
                ROOT / 'native/asr/mnn_session.h', ROOT / 'native/asr_mnn/mnn_graph.h',
                ROOT / 'tool/prepare_asr_native.py']}}
if mnn_sources is not None: manifest['mnnSourceHashes'] = mnn_sources
if args.platform == 'ios': manifest.update(ort='1.23.0', ortLinkage='external-app')
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print('Staged:', output)
