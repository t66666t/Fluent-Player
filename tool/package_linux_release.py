"""Package an existing Linux x64 Flutter bundle. Does not compile the app."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

from release_metadata import prefix, write_platform_manifest
from linux_bundle import relocate, elf_files, dynamic

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'fluent-player'
APPLICATION_ID = 'cn.teezy.fluentplayer.standard'
MAINTAINER = 't66666t <t66666t@users.noreply.github.com>'
DISTRIBUTIONS = {
    'ubuntu-22.04': ('ubuntu', '22.04'),
    'ubuntu-24.04': ('ubuntu', '24.04'),
    'debian-12': ('debian', '12'),
    'debian-13': ('debian', '13'),
}
DESKTOP = '''[Desktop Entry]
Type=Application
Name=Fluent Player
Comment=Media player, subtitles and learning
Exec=fluent-player
Icon=fluent-player
Terminal=false
Categories=AudioVideo;Player;
StartupWMClass=cn.teezy.fluentplayer.standard
'''


def release_version(pubspec):
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$', pubspec, re.M)
    if not match:
        raise ValueError('Expected a numeric release version in pubspec.yaml')
    return match[1] + '-' + (match[2] or '1')


def distribution_id(text):
    values = dict(line.split('=', 1) for line in text.splitlines()
                  if '=' in line and not line.startswith('#'))
    identity = (values.get('ID', '').strip('"'), values.get('VERSION_ID', '').strip('"'))
    for name, supported in DISTRIBUTIONS.items():
        if identity == supported:
            return name
    raise ValueError('Build inside a supported distribution, not an ABI-compatible guess: ' + str(identity))


def validate_bundle(bundle):
    for relative in ('fluent-player', 'lib/libflutter_linux_gtk.so',
                     'lib/libapp.so', 'data/icudtl.dat', 'data/flutter_assets',
                     'resources/translation/translation_worker'):
        if not (bundle / relative).exists():
            raise ValueError('Incomplete Flutter release bundle: ' + relative)
    runner = bundle / 'fluent-player'
    with runner.open('rb') as source:
        header = source.read(20)
    if header[:6] != b'\x7fELF\x02\x01' or header[18:20] != b'\x3e\x00':
        raise ValueError('Linux packaging currently requires an x64 ELF64 runner')


def dependencies(work, app):
    # Include plugins and native assets, since the runner dlopens many of them.
    # Private libraries travel inside this same package and have no dpkg shlibs
    # records. Missing *libraries* still fail; only missing shlibs info is ignored.
    binaries = elf_files(app)
    binaries = list(binaries)
    directories = sorted({binary.parent for binary in binaries})
    result = subprocess.run([
        'dpkg-shlibdeps', '-O', '--ignore-missing-info', '-x' + PACKAGE,
        *['-l' + str(directory) for directory in directories],
        *['-e' + str(binary) for binary in binaries],
    ], cwd=work, text=True, capture_output=True)
    print(result.stderr, end='')
    result.check_returncode()
    inferred = next((line.split('=', 1)[1] for line in result.stdout.splitlines()
                     if line.startswith('shlibs:Depends=')), '')
    if not inferred:
        raise ValueError('dpkg-shlibdeps returned no system dependencies')
    # These are launched/dlopen'ed at runtime and may not appear in DT_NEEDED.
    return inferred + ', ca-certificates, xdg-utils'


def private_shlibs(app):
    # The relocated private copies belong to *this* package. Without this local
    # map dpkg-shlibdeps can reintroduce build-host package names (libmpv1,
    # libvpx7, libx265-199) even though their bytes are in /opt/fluent-player.
    rows = set()
    for path in elf_files(app / 'lib'):
        soname = dynamic(path)[1]
        if soname:
            match = re.fullmatch(r'(.+)\.so\.(.+)', soname)
            if match:
                rows.add(f'{match[1]} {match[2]} {PACKAGE}')
    return '\n'.join(sorted(rows)) + '\n'


def add_launchers(app):
    for name in ('fluent-player.sh', 'install-desktop.sh', 'README-linux.md'):
        destination = app / name
        destination.write_text((ROOT / 'packaging/linux' / name).read_text(encoding='utf-8'),
                               encoding='utf-8', newline='\n')
        if name.endswith('.sh'):
            destination.chmod(0o755)
    shutil.copy2(ROOT / 'assets/icon/fluent-player.png', app / 'fluent-player.png')
    portable_desktop = DESKTOP.replace('Exec=fluent-player', 'Exec="@APPDIR@/fluent-player.sh"')
    portable_desktop = portable_desktop.replace('Icon=fluent-player', 'Icon=@APPDIR@/fluent-player.png')
    (app / (APPLICATION_ID + '.desktop.in')).write_text(portable_desktop, encoding='utf-8')
    licenses = app / 'licenses'
    licenses.mkdir(exist_ok=True)
    for name in ('LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md', 'PRIVACY.md'):
        shutil.copy2(ROOT / name, licenses / name)


def package(bundle, output, distribution=None, llama_runtime=None):
    if os.name == 'nt' or shutil.which('dpkg-deb') is None:
        raise RuntimeError('Run Linux packaging on a Debian/Ubuntu build host')
    bundle, output = bundle.resolve(), output.resolve()
    validate_bundle(bundle)
    actual = distribution_id(Path('/etc/os-release').read_text())
    if distribution is not None and distribution != actual:
        raise ValueError('Package distribution differs from the build host')
    distribution = actual
    version = release_version((ROOT / 'pubspec.yaml').read_text(encoding='utf-8'))
    output.mkdir(parents=True, exist_ok=True)
    name = prefix('linux', 'x64') + '-' + distribution
    if any((output / (name + extension)).exists() for extension in ('.deb', '.tar.gz')):
        raise ValueError('Refusing to overwrite existing package files; use a fresh output directory')
    with tempfile.TemporaryDirectory(prefix='fluent-linux-', dir=output) as temporary:
        work = Path(temporary)
        staging = work / 'debian' / PACKAGE
        app = staging / 'opt' / PACKAGE
        shutil.copytree(bundle, app, symlinks=True)
        for path in app.rglob('*'):
            if path.is_symlink() and not path.resolve().is_relative_to(app):
                raise ValueError('External bundle symlink: ' + str(path))
        for relative in ('fluent-player',
                        'resources/translation/translation_worker'):
            (app / relative).chmod(0o755)
        if llama_runtime is not None:
            from linux_llama_runtime import install
            install(app, llama_runtime)
        runtime = relocate(app)
        add_launchers(app)
        launcher = staging / 'usr/bin' / PACKAGE
        launcher.parent.mkdir(parents=True)
        launcher.write_text(f'#!/bin/sh\nexec /opt/{PACKAGE}/fluent-player.sh "$@"\n', encoding='utf-8')
        launcher.chmod(0o755)
        desktop = staging / ('usr/share/applications/' + APPLICATION_ID + '.desktop')
        desktop.parent.mkdir(parents=True)
        desktop.write_text(DESKTOP, encoding='utf-8')
        icon = staging / f'usr/share/pixmaps/{PACKAGE}.png'
        icon.parent.mkdir(parents=True)
        shutil.copy2(ROOT / 'assets/icon/fluent-player.png', icon)
        licenses = staging / 'usr/share/doc' / PACKAGE
        licenses.mkdir(parents=True)
        shutil.copy2(app / 'README-linux.md', licenses / 'README-linux.md')
        # dpkg-shlibdeps expects source metadata, even for a binary-only package.
        (work / 'debian/control').write_text(
            f'Source: {PACKAGE}\nSection: video\nPriority: optional\n'
            f'Maintainer: {MAINTAINER}\n\n'
            f'Package: {PACKAGE}\nArchitecture: amd64\n'
            'Description: Cross-platform media player\n', encoding='utf-8')
        (work / 'debian/shlibs.local').write_text(private_shlibs(app), encoding='utf-8')
        control = staging / 'DEBIAN/control'
        control.parent.mkdir()
        depends = dependencies(work, app)
        size = sum(path.stat().st_size for path in staging.rglob('*')
                   if path.is_file() and not path.is_symlink())
        control.write_text(
            f'Package: {PACKAGE}\nVersion: {version}\nArchitecture: amd64\n'
            'Section: video\nPriority: optional\n'
            f'Maintainer: {MAINTAINER}\n'
            f'Installed-Size: {(size + 1023) // 1024}\nDepends: {depends}\n'
            'Recommends: gnome-keyring, dbus-user-session, libgl1-mesa-dri\n'
            f'X-Fluent-Distribution: {distribution}\n'
            'Description: Fluent Player media player, subtitles and learning\n', encoding='utf-8')
        deb = output / (name + '.deb')
        subprocess.run(['dpkg-deb', '--build', '--root-owner-group', str(staging), str(deb)], check=True)
        # Keep the entire bundle, including helpers and native asset libraries.
        portable = output / (name + '.tar.gz')
        with tarfile.open(portable, 'w:gz') as archive:
            archive.add(app, arcname=PACKAGE)
        write_platform_manifest(output, 'linux', 'x64', 'not signed; ' + distribution)
        print('Bundled mpv ABI: ' + runtime['mpvSoname'])
        print(f'Packaged Linux x64 release in {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, default=ROOT / 'build/linux/x64/release/bundle')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/linux')
    parser.add_argument('--distribution', choices=DISTRIBUTIONS)
    parser.add_argument('--llama-runtime', type=Path,
                        help='Verified matching runtime rebuilt on the target distribution')
    args = parser.parse_args()
    package(args.bundle, args.output, args.distribution, args.llama_runtime)
