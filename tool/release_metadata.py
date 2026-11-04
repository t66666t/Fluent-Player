"""Versioned release assets and provenance shared by local and CI packaging."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PLATFORMS = ('android', 'windows', 'macos', 'ios', 'linux')
EXTENSIONS = {
    'android': ('.apk',), 'windows': ('.exe', '.zip'),
    'macos': ('.dmg', '.zip'), 'ios': ('.ipa',), 'linux': ('.deb', '.tar.gz'),
}


def read_version():
    match = re.search(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
                      (ROOT / 'pubspec.yaml').read_text(encoding='utf-8'), re.M)
    if not match or int(match[2]) < 1:
        raise ValueError('pubspec.yaml must contain version: MAJOR.MINOR.PATCH+BUILD (BUILD > 0)')
    return {'version': match[1], 'buildNumber': int(match[2]), 'tag': 'v' + match[1]}


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def prefix(platform, architecture):
    if platform not in PLATFORMS or architecture not in ('arm64', 'x64', 'universal'):
        raise ValueError('Unsupported release platform or architecture')
    return f'FluentPlayer-{read_version()["tag"]}-{platform}-{architecture}'


def write_platform_manifest(directory, platform, architecture, signing):
    version = read_version()
    files = sorted(path for path in directory.iterdir()
                   if path.is_file() and path.name.startswith(prefix(platform, architecture))
                   and path.name.endswith(EXTENSIONS[platform]))
    for extension in EXTENSIONS[platform]:
        if not any(path.name.endswith(extension) for path in files):
            raise ValueError(f'Missing {platform} release asset: {extension}')
    if any(path.stat().st_size >= 2 * 1024**3 or path.stat().st_size == 0 for path in files):
        raise ValueError('Release assets must be non-empty and smaller than 2 GiB')
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    manifest = {
        'schema': 1, **version, 'commit': commit, 'platform': platform,
        'architecture': architecture, 'signing': signing,
        'files': [{'name': path.name, 'size': path.stat().st_size, 'sha256': sha(path)} for path in files],
    }
    manifest_path = directory / f'{platform}-manifest.json'
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (directory / f'SHA256SUMS-{platform}.txt').write_text(
        ''.join(f'{sha(path)}  {path.name}\n' for path in [*files, manifest_path]), encoding='utf-8')
    return manifest


def collect(source, output, expected, commit, notes):
    version = read_version()
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('An exact source commit is required')
    records, files = {}, {}
    for path in sorted(source.rglob('*-manifest.json')):
        record = json.loads(path.read_text(encoding='utf-8'))
        platform = record.get('platform')
        if platform not in expected or platform in records:
            raise ValueError('Unexpected or duplicate platform manifest: ' + str(platform))
        if record.get('schema') != 1 or record.get('commit') != commit or any(
                record.get(key) != value for key, value in version.items()):
            raise ValueError('Release contains mixed versions or source commits: ' + str(platform))
        expected_prefix = prefix(platform, record.get('architecture'))
        if not record.get('files'):
            raise ValueError('Empty platform manifest')
        for item in record['files']:
            name = item['name']
            if (Path(name).name != name or '/' in name or '\\' in name or ':' in name
                    or not name.startswith(expected_prefix) or not name.endswith(EXTENSIONS[platform])
                    or name in files):
                raise ValueError('Invalid or duplicate release filename')
            artifact = path.parent / name
            if (not artifact.is_file() or artifact.is_symlink()
                    or not 0 < artifact.stat().st_size < 2 * 1024**3
                    or artifact.stat().st_size != item['size'] or sha(artifact) != item['sha256']):
                raise ValueError('Release asset failed integrity verification: ' + name)
            files[name] = artifact
        for extension in EXTENSIONS[platform]:
            if not any(item['name'].endswith(extension) for item in record['files']):
                raise ValueError(f'Missing {platform} release asset: {extension}')
        records[platform] = record
    if set(records) != set(expected):
        raise ValueError('Missing platforms: ' + ', '.join(sorted(set(expected) - set(records))))
    body = notes.read_text(encoding='utf-8').strip()
    if not body or '<!-- TODO' in body:
        raise ValueError('Write release notes before preparing a release')
    # Validate everything before creating the public output directory.
    output.mkdir(parents=True, exist_ok=False)
    for name, artifact in files.items():
        shutil.copy2(artifact, output / name)
    manifest_path = output / 'release-manifest.json'
    manifest_path.write_text(json.dumps({
        'schema': 1, **version, 'commit': commit, 'platforms': records,
    }, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    checksums = [(name, sha(output / name)) for name in sorted([*files, manifest_path.name])]
    (output / 'SHA256SUMS.txt').write_text(
        ''.join(f'{digest}  {name}\n' for name, digest in checksums), encoding='utf-8')
    rows = ['| 平台 | 安装文件 |', '| --- | --- |']
    for platform, record in sorted(records.items()):
        rows.append(f'| {platform} / {record["architecture"]} | ' +
                    '、'.join('`' + item['name'] + '`' for item in record['files']) + ' |')
    if 'android' not in records:
        body += '\n\n本次草稿尚未包含 Android APK，请勿将其他版本的 APK 混入本次发布。'
    body += '\n\n## 下载文件\n\n' + '\n'.join(rows)
    body += (f'\n\n应用版本：{version["version"]}（构建号 {version["buildNumber"]}）。'
             f'源码提交：`{commit}`。\n\n'
             '下载后可使用 `SHA256SUMS.txt` 核对文件；`release-manifest.json` 记录各平台文件和来源。'
             'GitHub 自动提供的 Source code 压缩包用于查看源码，不能直接安装。\n')
    (output / 'RELEASE_NOTES.md').write_text(body, encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    metadata = sub.add_parser('version')
    metadata.add_argument('--github-output', action='store_true')
    record = sub.add_parser('record')
    record.add_argument('--directory', type=Path, required=True)
    record.add_argument('--platform', choices=PLATFORMS, required=True)
    record.add_argument('--architecture', choices=['arm64', 'x64', 'universal'], required=True)
    record.add_argument('--signing', required=True)
    assembly = sub.add_parser('collect')
    assembly.add_argument('--source', type=Path, required=True)
    assembly.add_argument('--output', type=Path, required=True)
    assembly.add_argument('--expected', nargs='+', choices=PLATFORMS, required=True)
    assembly.add_argument('--commit', required=True)
    assembly.add_argument('--notes', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'version':
        version = read_version()
        print(json.dumps(version))
        if args.github_output:
            with Path(os.environ['GITHUB_OUTPUT']).open('a', encoding='utf-8') as sink:
                for key, value in version.items():
                    sink.write(f'{key}={value}\n')
    elif args.command == 'record':
        write_platform_manifest(args.directory, args.platform, args.architecture, args.signing)
    else:
        collect(args.source, args.output, args.expected, args.commit, args.notes)


if __name__ == '__main__':
    main()
