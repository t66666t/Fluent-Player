"""Validate four native distribution outputs and produce one Linux manifest."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

from package_linux_release import DISTRIBUTIONS
from release_metadata import ROOT, prefix, read_version, sha, write_platform_manifest


def merge(source, destination):
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    seen, assets = set(), []
    for path in source.rglob('linux-manifest.json'):
        record = json.loads(path.read_text(encoding='utf-8'))
        distribution = record['signing'].removeprefix('not signed; ')
        if distribution not in DISTRIBUTIONS or distribution in seen:
            raise ValueError('Unexpected or duplicate Linux distribution')
        if (record.get('schema') != 1 or record['commit'] != commit or record['platform'] != 'linux' or
                record['architecture'] != 'x64' or any(record[k] != v for k, v in read_version().items())):
            raise ValueError('Linux distribution builds use different sources or versions')
        formats = set()
        for item in record['files']:
            name = item['name']
            if (Path(name).name != name or '/' in name or '\\' in name or ':' in name
                    or not name.startswith(prefix('linux', 'x64') + '-')):
                raise ValueError('Invalid Linux artifact name')
            extension = next((suffix for suffix in ('.deb', '.tar.gz')
                              if name.endswith('-' + distribution + suffix)), None)
            if extension is None or extension in formats:
                raise ValueError('Unexpected distribution filename or duplicate format')
            asset = path.parent / name
            if asset.stat().st_size != item['size'] or sha(asset) != item['sha256']:
                raise ValueError('Linux artifact checksum mismatch')
            formats.add(extension)
            assets.append(asset)
        if formats != {'.deb', '.tar.gz'}:
            raise ValueError('Distribution package is incomplete')
        seen.add(distribution)
    if seen != set(DISTRIBUTIONS):
        raise ValueError('Missing native Linux distribution builds')
    destination.mkdir(parents=True, exist_ok=False)
    for asset in assets:
        shutil.copy2(asset, destination / asset.name)
    write_platform_manifest(destination, 'linux', 'x64', 'not signed; four native distribution builds')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    merge(args.source, args.destination)
