"""Rebuild the existing llama.cpp ABI on older Linux distributions.

Build-time only: no model changes, Pub-cache edits or application downloads.
The source pins match llamadart 0.15.1's v0.7.0-1 native release.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

from linux_bundle import digest, dynamic

ROOT = Path(__file__).resolve().parents[1]
NATIVE_TAG = 'v0.7.0-1'
NATIVE_COMMIT = 'daffc7fc8bdb62bbc09f723a74e761f6f32d549f'
LLAMA_COMMIT = '620d2225cc436ab0b001e3200e590e3b286ef9ab'
SHADERC_COMMIT = 'd792558a8902cb39b1c237243cc4edab226513a5'
SUBMODULES = {
    'llama.cpp': LLAMA_COMMIT,
    'Vulkan-Headers': '49f1a381e2aec33ef32adf4a377b5a39ec016ec4',
    'SPIRV-Headers': 'ad9184e76a66b1001c29db9b0a3e87f646c64de0',
}
REQUIRED = {'libllamadart.so', 'libllama.so', 'libggml-base.so',
            'libggml-cpu.so', 'libggml-vulkan.so'}
LIBRARY = re.compile(r'^(?:libggml(?:-[\w-]+)?|libllama|libllamadart|libmtmd)\.so(?:\.[\d.]+)?$')


def run(arguments, **kwargs):
    subprocess.run([str(arg) for arg in arguments], check=True, **kwargs)


def checkout(directory, repository, commit):
    if not (directory / '.git').exists():
        if directory.exists() and any(directory.iterdir()):
            raise ValueError('Refusing to overwrite a source directory: ' + str(directory))
        directory.mkdir(parents=True, exist_ok=True)
        run(['git', 'init', directory])
        run(['git', '-C', directory, 'remote', 'add', 'origin', repository])
    origin = subprocess.check_output(['git', '-C', str(directory), 'remote', 'get-url', 'origin'], text=True).strip()
    if origin != repository:
        raise ValueError('Unexpected native source repository')
    run(['git', '-C', directory, 'fetch', '--depth=1', 'origin', commit])
    run(['git', '-C', directory, 'checkout', '--detach', commit])
    actual = subprocess.check_output(['git', '-C', str(directory), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != commit:
        raise ValueError('Native source commit changed')


def elf_x64(path):
    with path.open('rb') as stream:
        header = stream.read(20)
    if header[:6] != b'\x7fELF\x02\x01' or header[18:20] != b'\x3e\x00':
        raise ValueError('Expected an x64 ELF runtime: ' + str(path))


def verify(directory):
    record = json.loads((directory / 'runtime.json').read_text(encoding='utf-8'))
    if (record.get('schema') != 1 or record.get('nativeTag') != NATIVE_TAG or
            record.get('nativeCommit') != NATIVE_COMMIT or record.get('llamaCommit') != LLAMA_COMMIT):
        raise ValueError('Native runtime does not match the existing model ABI')
    files = record.get('files', {})
    if not REQUIRED.issubset(files):
        raise ValueError('The CPU/Vulkan native runtime is incomplete')
    for name, checksum in files.items():
        if not LIBRARY.fullmatch(name) or Path(name).name != name:
            raise ValueError('Unsafe native runtime filename')
        path = directory / name
        elf_x64(path)
        if digest(path) != checksum:
            raise ValueError('Native runtime checksum mismatch: ' + name)
    return record


def exports(path):
    text = subprocess.check_output(['nm', '-D', '--defined-only', '--format=posix', str(path)], text=True)
    return {line.split()[0].split('@')[0] for line in text.splitlines()
            if line.startswith(('llamadart_', 'llama_', 'ggml_', 'mtmd_'))}


def install(app, directory):
    """Replace only a package's staging copy, after checking every ABI first."""
    app, directory = app.resolve(), directory.resolve()
    record = verify(directory)
    plan = []
    for target in app.rglob('*'):
        if not target.is_file() or not LIBRARY.fullmatch(target.name):
            continue
        replacement = directory / target.name
        if target.name not in record['files']:
            raise ValueError('Rebuilt runtime is missing a packaged backend: ' + target.name)
        if dynamic(target)[1] != dynamic(replacement)[1]:
            raise ValueError('Rebuilt runtime changed its SONAME: ' + target.name)
        missing = exports(target) - exports(replacement)
        if missing:
            raise ValueError('Rebuilt runtime lost public ABI symbols: ' + repr(sorted(missing)[:8]))
        plan.append((target, replacement))
    if not plan:
        raise ValueError('The application has no matching llama runtime to replace')
    for target, replacement in plan:
        shutil.copy2(replacement, target)
    shutil.copytree(directory / 'licenses', app / 'licenses/llamadart-linux-runtime', dirs_exist_ok=True)
    (app / 'linux-llama-runtime.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    print('Installed matching CPU/Vulkan runtime copies: ' + str(len(plan)))


def build(output, jobs):
    if sys.platform != 'linux' or platform.machine().lower() not in ('x86_64', 'amd64'):
        raise RuntimeError('Rebuild on the target Linux x64 distribution')
    lock = (ROOT / 'pubspec.lock').read_text(encoding='utf-8')
    package = re.search(r'^  llamadart:\n(.*?)(?=^  \S|\Z)', lock, re.M | re.S)
    if not package or not re.search(r'^    version: "0\.15\.1"$', package[1], re.M):
        raise ValueError('Review native source pins after changing llamadart')
    if output.exists():
        verify(output)
        print('Reusing verified Linux runtime build')
        return
    work = ROOT / '.artifacts/linux-llama-build'
    tools = work / 'tools'
    if not (tools / 'bin/python').exists():
        run([sys.executable, '-m', 'venv', tools])
    run([tools / 'bin/python', '-m', 'pip', 'install', '--index-url', 'https://pypi.org/simple', 'cmake==3.31.6'])
    env = os.environ.copy()
    env['PATH'] = str(tools / 'bin') + os.pathsep + env['PATH']
    cmake = tools / 'bin/cmake'
    shader = work / 'shaderc'
    checkout(shader, 'https://github.com/google/shaderc.git', SHADERC_COMMIT)
    run([sys.executable, shader / 'utils/git-sync-deps'], cwd=shader, env=env)
    shader_build = work / 'shaderc-build'
    run([cmake, '-S', shader, '-B', shader_build, '-G', 'Ninja',
         '-DCMAKE_BUILD_TYPE=Release', '-DSHADERC_SKIP_TESTS=ON',
         '-DSPIRV_SKIP_TESTS=ON', '-DSHADERC_SKIP_EXAMPLES=OFF'], env=env)
    run([cmake, '--build', shader_build, '--target', 'glslc', '--parallel', str(jobs)], env=env)
    glslc = shader_build / 'glslc/glslc'
    if not glslc.is_file():
        raise ValueError('The pinned shader compiler was not produced')
    env['PATH'] = str(glslc.parent) + os.pathsep + env['PATH']
    source = work / 'llamadart-native'
    checkout(source, 'https://github.com/leehack/llamadart-native.git', NATIVE_COMMIT)
    paths = ['third_party/' + name for name in SUBMODULES]
    run(['git', '-C', source, 'submodule', 'update', '--init', '--depth=1', *paths])
    for name, expected in SUBMODULES.items():
        actual = subprocess.check_output(['git', '-C', str(source / 'third_party' / name),
                                          'rev-parse', 'HEAD'], text=True).strip()
        if actual != expected:
            raise ValueError('Native submodule pin changed: ' + name)
    # Use the pinned headers with the host's ABI-compatible Vulkan loader.
    env['VULKAN_SDK'] = str(source / 'third_party/Vulkan-Headers')
    # The maintained upstream Vulkan lane includes its CPU fallback and uses
    # GGML_NATIVE=OFF. Build the same ABI, without adding CUDA or changing models.
    run([sys.executable, source / 'tools/build.py', 'linux', '--arch', 'x64',
         '--backend', 'vulkan', '--jobs', str(jobs)], cwd=source, env=env)
    output.mkdir(parents=True)
    for path in (source / 'bin/linux/x64').iterdir():
        if path.is_file() and LIBRARY.fullmatch(path.name):
            elf_x64(path)
            shutil.copy2(path, output / path.name)
    files = {path.name: digest(path) for path in output.iterdir() if path.is_file()}
    record = {'schema': 1, 'nativeTag': NATIVE_TAG, 'nativeCommit': NATIVE_COMMIT,
              'llamaCommit': LLAMA_COMMIT, 'shadercCommit': SHADERC_COMMIT,
              'glibc': platform.libc_ver()[1], 'backends': ['cpu', 'vulkan'], 'files': files}
    (output / 'runtime.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    licenses = output / 'licenses'
    licenses.mkdir()
    shutil.copy2(source / 'LICENSE', licenses / 'llamadart-native-LICENSE')
    shutil.copy2(source / 'third_party/llama.cpp/LICENSE', licenses / 'llama.cpp-LICENSE')
    verify(output)
    probe_env = env.copy()
    probe_env['LD_LIBRARY_PATH'] = str(output.resolve())
    probe_env.pop('LD_PRELOAD', None)
    run([sys.executable, '-c', 'import ctypes,sys; ctypes.CDLL(sys.argv[1]); ctypes.CDLL(sys.argv[2])',
         output / 'libllamadart.so', output / 'libggml-vulkan.so'], env=probe_env)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.artifacts/linux-llama-runtime')
    parser.add_argument('--jobs', type=int, default=2)
    arguments = parser.parse_args()
    build(arguments.output.resolve(), arguments.jobs)
