"""Build the private Qwen audio runtime without replacing existing runtimes.

Run explicitly on the target host. Rust is a maintainer build dependency only.
Examples:
  python tool/build_qwen_asr.py --platform windows --backend cpu --cargo <cargo.exe>
  python tool/build_qwen_asr.py --platform windows --backend vulkan --cmake-arg=-DVulkan_GLSLC_EXECUTABLE=<glslc.exe>
  python tool/build_qwen_asr.py --platform android --ndk <ndk> --arch arm64
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
from urllib.request import urlopen
import zipfile

from prepare_qwen_native import prepare
from qwen_licenses import collect as collect_licenses

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'native/qwen_asr'
LOCK = json.loads((NATIVE / 'runtime.lock.json').read_text(encoding='utf-8'))


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


@contextmanager
def source_lock(path):
    with path.open('a+b') as stream:
        stream.write(b'0'); stream.flush(); stream.seek(0)
        if os.name == 'nt':
            import msvcrt
            while True:
                try:
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    time.sleep(.2)
        else:
            import fcntl
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == 'nt': msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else: fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def inputs():
    paths = [p for p in NATIVE.rglob('*') if p.is_file() and 'prebuilt' not in p.parts and 'target' not in p.parts]
    paths += [ROOT / 'tool/build_qwen_asr.py', ROOT / 'tool/prepare_qwen_native.py', ROOT / 'tool/qwen_licenses.py']
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(paths)}


def archive(deps, name, entry):
    target = deps / (name + '.zip')
    if not target.exists() or sha(target) != entry['sha256']:
        partial = target.with_suffix('.part')
        with urlopen(entry['url'], timeout=180) as source, partial.open('wb') as output:
            shutil.copyfileobj(source, output)
        if sha(partial) != entry['sha256']:
            raise ValueError(f'Unexpected {name} archive hash')
        partial.replace(target)
    return target


def extract(path, parent):
    with zipfile.ZipFile(path) as package:
        folder = package.namelist()[0].split('/')[0]
        resolved = parent.resolve()
        for entry in package.infolist():
            if not (parent / entry.filename).resolve().is_relative_to(resolved):
                raise ValueError('Invalid source archive path')
        # Python's zip extractor otherwise hits MAX_PATH on upstream notices.
        destination = str(resolved)
        if os.name == 'nt' and not destination.startswith('\\\\?\\'):
            destination = '\\\\?\\' + destination
        package.extractall(destination)
    return parent / folder


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True, choices=['windows', 'linux', 'macos', 'android', 'ios'])
    parser.add_argument('--arch', choices=['x64', 'arm64'])
    parser.add_argument('--backend', choices=['cpu', 'vulkan', 'cuda', 'metal'], default='cpu')
    parser.add_argument('--cmake')
    parser.add_argument('--cargo')
    parser.add_argument('--ndk', type=Path)
    parser.add_argument('--runtime-dir', action='append', type=Path, default=[],
                        help='Private CUDA runtime directories to bundle, never a system driver')
    parser.add_argument('--ios-simulator', action='store_true')
    parser.add_argument('--cmake-arg', action='append', default=[])
    parser.add_argument('--parallel', default='8')
    args = parser.parse_args()
    arch = args.arch or ('arm64' if args.platform in ('android','ios') or platform.machine().lower() in ('arm64','aarch64') else 'x64')
    if args.platform in ('macos','ios') and sys.platform != 'darwin': parser.error('Apple builds require an Apple host')
    if args.backend == 'metal' and args.platform not in ('macos','ios'): parser.error('Metal requires Apple')
    if args.backend == 'cuda' and args.platform not in ('windows','linux'): parser.error('CUDA is a desktop backend')
    work = ROOT / '.artifacts/qwen-integration'
    deps = work / 'deps'
    deps.mkdir(parents=True, exist_ok=True)
    patch_id = sha(ROOT / 'tool/prepare_qwen_native.py')[:16]
    sources = work / ('source-' + patch_id)
    ready = sources / 'prepared.json'
    with source_lock(work / ('prepare-' + patch_id + '.lock')):
        if not ready.exists():
            sources.mkdir(parents=True, exist_ok=True)
            source = extract(archive(deps, 'crispasr', LOCK['crispasr']), sources)
            ggml = extract(archive(deps, 'ggml', LOCK['ggml']), sources)
            prepare(source, ggml, sources / 'symbols.h')
            ready.write_text(json.dumps({'source':str(source),'ggml':str(ggml)}), encoding='utf-8')
    prepared = json.loads(ready.read_text(encoding='utf-8'))
    json_header = deps / 'json.hpp'
    json_sha = '9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6'
    if not json_header.exists() or sha(json_header) != json_sha:
        with urlopen('https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp',timeout=90) as response:
            json_header.write_bytes(response.read())
        if sha(json_header) != json_sha: raise ValueError('Unexpected JSON header hash')
    cargo = args.cargo or shutil.which('cargo')
    local_cargo = work / 'rust/cargo/bin/cargo.exe'
    if not cargo and local_cargo.exists(): cargo = str(local_cargo)
    if not cargo: parser.error('Rust 1.88+ is required for maintainer builds; provide --cargo')
    env = dict(os.environ)
    if Path(cargo).resolve() == local_cargo.resolve():
        env['CARGO_HOME'] = str(work / 'rust/cargo')
        env['RUSTUP_HOME'] = str(work / 'rust/rustup')
        env['PATH'] = str(local_cargo.parent) + os.pathsep + env.get('PATH','')
    if args.platform == 'windows':
        env['RUSTFLAGS'] = env.get('RUSTFLAGS','') + ' -Ctarget-feature=+crt-static'
    triples = {'windows': 'aarch64-pc-windows-msvc' if arch=='arm64' else 'x86_64-pc-windows-msvc',
               'linux': 'aarch64-unknown-linux-gnu' if arch=='arm64' else 'x86_64-unknown-linux-gnu',
               'macos': 'aarch64-apple-darwin' if arch=='arm64' else 'x86_64-apple-darwin',
               'android':'aarch64-linux-android' if arch=='arm64' else 'x86_64-linux-android',
               'ios': ('aarch64-apple-ios-sim' if arch=='arm64' else 'x86_64-apple-ios') if args.ios_simulator else 'aarch64-apple-ios'}
    triple = triples[args.platform]
    if args.platform == 'android':
        if not args.ndk: parser.error('Android requires --ndk')
        host = 'windows-x86_64' if os.name=='nt' else 'darwin-x86_64' if sys.platform=='darwin' else 'linux-x86_64'
        toolchain = args.ndk / 'toolchains/llvm/prebuilt' / host / 'bin'
        compiler = toolchain / (('aarch64-linux-android' if arch=='arm64' else 'x86_64-linux-android') + '24-clang' + ('.cmd' if os.name=='nt' else ''))
        env['CARGO_TARGET_'+triple.upper().replace('-','_')+'_LINKER'] = str(compiler)
        env['CC_'+triple.replace('-','_')] = str(compiler)
    target_dir = work / 'text-target'
    env['CARGO_TARGET_DIR'] = str(target_dir)
    cargo_command = [cargo,'build','--release','--target',triple,'--manifest-path',str(NATIVE/'text/Cargo.toml')]
    if (NATIVE/'text/Cargo.lock').exists(): cargo_command += ['--locked']
    subprocess.run(cargo_command,env=env,check=True,cwd=ROOT)
    lindera_zip = archive(deps, 'lindera', LOCK['lindera'])
    text_notices = collect_licenses(cargo, env, NATIVE, target_dir, triple, LOCK, sha, lindera_zip)
    text_lib = target_dir / triple / 'release' / ('fluent_asr_text.lib' if args.platform=='windows' else 'libfluent_asr_text.a')
    cmake = args.cmake or shutil.which('cmake')
    if not cmake and os.name=='nt':
        cmake = next((str(p) for p in Path('D:/Microsoft Visual Studio').glob('*/**/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe')),None)
    if not cmake: parser.error('CMake 3.24+ is required')
    source_hashes = inputs()
    build_id = hashlib.sha256(json.dumps({'sources':source_hashes,'pins':LOCK,'backend':args.backend,'platform':args.platform,'arch':arch,'cmakeArguments':args.cmake_arg},sort_keys=True).encode()).hexdigest()
    build = work / f'build-{args.platform}-{arch}-{args.backend}-{patch_id[:8]}{"-sim" if args.ios_simulator else ""}'
    configure = [cmake,'-S',str(NATIVE),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release',
                 '-DQWEN_SOURCE='+prepared['source'],'-DQWEN_GGML_SOURCE='+prepared['ggml'],
                 '-DQWEN_TEXT_LIBRARY='+str(text_lib),'-DQWEN_JSON_INCLUDE='+str(deps),
                 '-DQWEN_SYMBOL_PREFIX_HEADER='+str(sources/'symbols.h'),'-DQWEN_BUILD_ID='+build_id,
                 '-DGGML_VULKAN='+('ON' if args.backend=='vulkan' else 'OFF'),
                 '-DGGML_CUDA='+('ON' if args.backend=='cuda' else 'OFF'),
                 '-DGGML_METAL='+('ON' if args.backend=='metal' else 'OFF')]
    if args.platform=='windows': configure += ['-A','ARM64' if arch=='arm64' else 'x64']
    if args.platform=='android':
        configure += ['-DCMAKE_TOOLCHAIN_FILE='+str(args.ndk/'build/cmake/android.toolchain.cmake'),'-DANDROID_ABI='+('arm64-v8a' if arch=='arm64' else 'x86_64'),'-DANDROID_PLATFORM=24']
        configure += ['-G','Ninja']
        if os.name == 'nt' and not shutil.which('ninja'):
            ninja = Path(cmake).parent.parent.parent/'Ninja/ninja.exe'
            if ninja.exists(): configure += ['-DCMAKE_MAKE_PROGRAM='+str(ninja)]
    if args.platform in ('macos','ios'):
        configure += ['-DCMAKE_OSX_ARCHITECTURES='+('arm64' if arch=='arm64' else 'x86_64')]
    if args.platform=='ios': configure += ['-DCMAKE_SYSTEM_NAME=iOS','-DCMAKE_OSX_SYSROOT='+('iphonesimulator' if args.ios_simulator else 'iphoneos')]
    configure += args.cmake_arg
    subprocess.run(configure,check=True)
    targets = ['fluent_qwen_asr' if args.platform in ('android','ios') else 'qwen_asr_worker']
    if args.platform not in ('android','ios'):
        targets += ['ggml-cpu-x64','ggml-cpu-haswell','ggml-cpu-alderlake'] if arch=='x64' else ['ggml-cpu']
        if args.backend!='cpu': targets += ['ggml-'+args.backend]
    subprocess.run([cmake,'--build',str(build),'--config','Release','--parallel',args.parallel,'--target',*targets],check=True)
    stage = NATIVE/'prebuilt'/f'{args.platform}-{arch}{"-sim" if args.ios_simulator else ""}'
    stage.mkdir(parents=True,exist_ok=True)
    files=[]
    if args.platform=='windows': files = list(build.rglob('*.dll')) + [next(build.rglob('qwen_asr_worker.exe'))]
    elif args.platform=='ios':
        merged = build/'libfluent_qwen_asr_combined.a'
        archives = [str(p) for p in build.rglob('*.a') if p != merged]
        subprocess.run(['xcrun','libtool','-static','-o',str(merged),*archives,str(text_lib)],check=True)
        files=[merged]
    else:
        files=[p for p in build.rglob('*') if p.is_file() and (re.search(r'\.so(?:\.\d+)*$',p.name) or p.name.endswith('.dylib') or p.name=='qwen_asr_worker')]
    if args.backend == 'cuda':
        runtime_files=[]
        for directory in args.runtime_dir:
            runtime_files += [p for p in directory.iterdir() if p.is_file() and
                              p.name.lower().startswith(('cudart', 'cublas', 'libcudart', 'libcublas'))
                              and (p.suffix == '.dll' or '.so' in p.name)]
        if args.platform == 'windows' and not any(p.name.lower().startswith('cublaslt') for p in runtime_files):
            parser.error('Provide the redistributable CUDA runtime closure using --runtime-dir (no user Toolkit required)')
        files += runtime_files
    manifest_files={}
    previous=json.loads((stage/'manifest.json').read_text(encoding='utf-8')) if (stage/'manifest.json').exists() else {}
    for file in files:
        target=stage/file.name
        temporary=target.with_suffix(target.suffix+'.tmp')
        shutil.copy2(file,temporary)
        temporary.replace(target)
        manifest_files[target.name]=sha(target)
    licenses=stage/'licenses'
    licenses.mkdir(exist_ok=True)
    for name,path in [('CrispASR-MIT.txt',Path(prepared['source'])/'LICENSE'),('ggml-MIT.txt',Path(prepared['ggml'])/'LICENSE'),('Apache-2.0.txt',ROOT/'assets/licenses/Apache-2.0.txt')]:
        shutil.copy2(path,licenses/name)
    json_license = deps/'nlohmann-json-LICENSE.MIT'
    if not json_license.exists():
        with urlopen('https://raw.githubusercontent.com/nlohmann/json/v3.11.3/LICENSE.MIT',timeout=90) as response:
            json_license.write_bytes(response.read())
    shutil.copy2(json_license, licenses/'nlohmann-json-MIT.txt')
    (licenses/'Text-processing-notices.txt').write_text(text_notices,encoding='utf-8')
    for file in licenses.iterdir():
        manifest_files[file.relative_to(stage).as_posix()]=sha(file)
    for name in previous.get('files',{}):
        if name not in manifest_files:
            obsolete=(stage/name).resolve()
            if not obsolete.is_relative_to(stage.resolve()): raise ValueError('Invalid previous Qwen receipt path')
            obsolete.unlink(missing_ok=True)
    manifest={'version':1,'platform':args.platform,'arch':arch,'backend':args.backend,'build':build_id,
              'sources':source_hashes,'pins':LOCK,'files':manifest_files,'textProcessingVersion':1,
              'rustTarget':triple,'cmakeArguments':args.cmake_arg,'batchSize':1}
    (stage/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print('Qwen audio runtime staged:',stage,flush=True)


if __name__=='__main__': main()
