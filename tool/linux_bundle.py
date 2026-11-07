"""Relocate a trusted build's ELF dependency closure, then audit its loader paths."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


# The host owns its libc, loader and graphics driver stack. Copying these from
# CI breaks Mesa/NVIDIA integration and cannot make a newer glibc run on an old OS.
HOST_LIBRARIES = re.compile(
    r'^(?:ld-linux[^/]*|lib(?:c|m|dl|pthread|rt|resolv|util|anl|nss_[^/]+|'
    r'BrokenLocale|thread_db|gcc_s|stdc\+\+|EGL|GL|GLX|GLdispatch|OpenGL|'
    r'GLESv[12]|vulkan|gbm|drm[^/]*)\.so(?:\.[^/]*)?)$')


def host_library(name):
    return bool(HOST_LIBRARIES.fullmatch(name))


def elf_files(bundle):
    for path in sorted(bundle.rglob('*')):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as source:
                if source.read(4) == b'\x7fELF':
                    yield path


def output(arguments, **kwargs):
    return subprocess.check_output(arguments, text=True, encoding='utf-8', **kwargs).strip()


def dynamic(path):
    text = output(['readelf', '-d', str(path)])
    needed = re.findall(r'\(NEEDED\).*?\[(.*?)\]', text)
    sonames = re.findall(r'\(SONAME\).*?\[(.*?)\]', text)
    return needed, sonames[0] if sonames else None


def parse_ldd(text):
    if re.search(r'=>\s+not found|version [^\n]+ not found', text):
        raise ValueError('Missing ELF dependency:\n' + text)
    return {match[1]: Path(match[2]) for match in re.finditer(
        r'^\s*(\S+)\s+=>\s+(/[^\n]+?)\s+\(0x[0-9a-fA-F]+\)', text, re.M)}


def dependencies(path, environment=None):
    if not dynamic(path)[0]:
        return {}
    return parse_ldd(output(['ldd', str(path)], env=environment))


def relative_rpath(path, bundle, *, isolated_tools=False):
    # Each dlopen'ed plugin must resolve its *own* NEEDED entries. The runner's
    # RUNPATH is not inherited by plugins. Keep worker-local libraries first.
    # A GPL CLI's private libav libraries must never share the player's libmpv
    # directory/SONAME resolution. Proprietary Linux inputs place the entire
    # CLI closure under bin/, including bin/lib/ when dynamically linked.
    private = bundle / 'bin'
    libraries = private / 'lib' if isolated_tools and path.is_relative_to(private) else bundle / 'lib'
    relative = os.path.relpath(libraries, path.parent).replace(os.sep, '/')
    return '$ORIGIN' if relative == '.' else '$ORIGIN:$ORIGIN/' + relative


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def package_owner(path):
    candidates = [path]
    if str(path).startswith('/usr/'):
        candidates.append(Path(str(path)[4:]))
    for candidate in candidates:
        result = subprocess.run(['dpkg-query', '-S', str(candidate)], text=True,
                                encoding='utf-8', capture_output=True)
        if result.returncode == 0:
            return result.stdout.splitlines()[0].split(': ', 1)[0].split(', ')[0]
    raise ValueError('No source package provenance for bundled system file: ' + str(path))


def record_copyright(bundle, source, records):
    owner = package_owner(source)
    if owner not in records:
        fields = output(['dpkg-query', '-W',
                         '-f=${binary:Package}\t${Version}\t${source:Package}\t${source:Version}', owner])
        package, version, source_name, source_version = fields.split('\t')
        records[owner] = {'package': package, 'version': version,
                          'sourcePackage': source_name, 'sourceVersion': source_version}
        copyright_file = Path('/usr/share/doc') / owner.split(':')[0] / 'copyright'
        if not copyright_file.is_file():
            raise ValueError('Missing copyright material: ' + str(copyright_file))
        destination = bundle / 'licenses/system' / owner.replace(':', '_')
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copy2(copyright_file, destination / 'copyright')
    return owner


def copy_library(source, name, bundle, records, copied):
    if Path(name).name != name or host_library(name):
        raise ValueError('Invalid private library name: ' + name)
    target = bundle / 'lib' / name
    if target.exists():
        if digest(target) != digest(source):
            raise ValueError('Conflicting libraries have the same SONAME: ' + name)
        return False
    # Copy the dereferenced bytes under the SONAME: no absolute host symlinks.
    shutil.copy2(source.resolve(), target)
    owner = record_copyright(bundle, source.resolve(), records)
    copied[name] = {'package': owner, 'sha256BeforeRelocation': digest(target)}
    return True


def system_library(soname):
    cache = output([shutil.which('ldconfig') or '/sbin/ldconfig', '-p'])
    for match in re.finditer(r'^\s*' + re.escape(soname) + r'\s+\([^\n]*x86-64[^\n]*\)\s+=>\s+(\S+)\s*$',
                             cache, re.M):
        path = Path(match[1])
        if path.is_file():
            return path
    raise ValueError('Install the required runtime library: ' + soname)


def relocate(bundle):
    bundle = bundle.resolve()
    (bundle / 'lib').mkdir(exist_ok=True)
    records, copied = {}, {}
    # mpv is also opened via Dart FFI, so it must be an explicit seed even when
    # no compiled plugin references it. Never fake an ABI .1 -> .2 symlink.
    mpv_dir = Path(output(['pkg-config', '--variable=libdir', 'mpv']))
    mpv = mpv_dir / 'libmpv.so'
    if not mpv.is_file():
        raise ValueError('Install the matching libmpv development package before packaging')
    _, mpv_soname = dynamic(mpv)
    if mpv_soname not in ('libmpv.so.1', 'libmpv.so.2'):
        raise ValueError('Unsupported libmpv SONAME: ' + str(mpv_soname))
    copy_library(mpv, mpv_soname, bundle, records, copied)
    # sqlite3 is opened by Dart FFI and has no DT_NEEDED call site.
    copy_library(system_library('libsqlite3.so.0'), 'libsqlite3.so.0', bundle, records, copied)
    sqlite_link = bundle / 'lib/libsqlite3.so'
    if not sqlite_link.exists():
        sqlite_link.symlink_to('libsqlite3.so.0')
    for binary in ('ffmpeg', 'ffprobe'):
        source = shutil.which(binary)
        if not source:
            raise ValueError('Missing required media CLI: ' + binary)
        target = bundle / 'bin' / binary
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(source, target)
        target.chmod(0o755)
        record_copyright(bundle, Path(source).resolve(), records)
    # Some native-asset installers preserve the real file but omit its SONAME
    # symlink. Repair only aliases to identical bytes, never an ABI version.
    for path in list(elf_files(bundle)):
        soname = dynamic(path)[1]
        if soname and Path(soname).name == soname:
            alias = path.parent / soname
            if alias.exists():
                if digest(alias) != digest(path):
                    raise ValueError('Conflicting private SONAME alias: ' + str(alias))
            else:
                alias.symlink_to(path.name)
    clean = os.environ.copy()
    # This environment is used only while resolving the build's dependency tree.
    # The shipped launcher does not inject it into Chrome or other child apps.
    inspected = set()
    while True:
        pending = [path for path in elf_files(bundle) if path not in inspected]
        if not pending:
            break
        for path in pending:
            inspected.add(path)
            needed, _ = dynamic(path)
            if needed:
                subprocess.run(['patchelf', '--set-rpath', relative_rpath(path, bundle), str(path)], check=True)
            clean['LD_LIBRARY_PATH'] = os.pathsep.join([str(path.parent), str(bundle / 'lib')])
            for name in needed:
                if name.startswith('libmpv.so.') and name != mpv_soname:
                    raise ValueError('media_kit and packaged mpv use different ABIs: ' + name)
            for name, source in dependencies(path, clean).items():
                # Capture the full closure before relocating private RUNPATHs
                # (PulseAudio, for example, keeps helpers in a subdirectory).
                if source.resolve().is_relative_to(bundle) or host_library(name):
                    continue
                copy_library(source, name, bundle, records, copied)
    # Patch all native assets and helpers, not just the Flutter plugin targets.
    for path in elf_files(bundle):
        needed, _ = dynamic(path)
        if needed:
            subprocess.run(['patchelf', '--set-rpath', relative_rpath(
                path, bundle), str(path)], check=True)
    manifest = {'mpvSoname': mpv_soname, 'packages': records, 'libraries': copied}
    common_licenses = Path('/usr/share/common-licenses')
    if common_licenses.is_dir():
        shutil.copytree(common_licenses, bundle / 'licenses/common-licenses', symlinks=False)
    (bundle / 'linux-runtime.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    audit(bundle)
    return manifest


def audit(bundle):
    bundle = bundle.resolve()
    clean = os.environ.copy()
    clean.pop('LD_LIBRARY_PATH', None)
    clean.pop('LD_PRELOAD', None)
    count = 0
    for path in elf_files(bundle):
        needed, _ = dynamic(path)
        if not needed:
            continue
        rpath = output(['patchelf', '--print-rpath', str(path)])
        for item in rpath.split(':'):
            if not re.fullmatch(r'\$ORIGIN(?:/[^:]*)?', item):
                raise ValueError('Non-relocatable RUNPATH: ' + str(path) + ' = ' + rpath)
            resolved = (path.parent / item.removeprefix('$ORIGIN').lstrip('/')).resolve()
            if not resolved.is_relative_to(bundle):
                raise ValueError('RUNPATH escapes application bundle: ' + str(path))
        for name, resolved in dependencies(path, clean).items():
            # ldd also prints indirect dependencies of host-owned drivers.
            # Every private object is audited separately below, so requiring
            # those host dependencies in our RUNPATH would defeat isolation.
            if name not in needed:
                continue
            if not host_library(name) and not resolved.resolve().is_relative_to(bundle):
                raise ValueError('Unbundled runtime dependency: ' + name + ' in ' + str(path))
        count += 1
    print(f'ELF audit passed: {count} dynamic objects; no CI RUNPATH or missing libraries')
    return count
