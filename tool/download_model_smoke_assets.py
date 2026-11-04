"""Fetch pinned test models into .artifacts, verifying every file.

This is an opt-in developer probe, not an application download implementation.
The default probe uses approximately 1.4 GB of disk space.
"""
import argparse
import hashlib
import json
import pathlib
import urllib.request

def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            sha.update(chunk)
    return sha.hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', default='.artifacts/model-center/native')
    parser.add_argument('--ids', nargs='+', default=['sensevoice-small-int8', 'hy-mt2-1.8b-q4'])
    args = parser.parse_args()
    root = pathlib.Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=True)
    catalog = json.loads(pathlib.Path('assets/models/catalog.json').read_text(encoding='utf-8'))
    dependencies = json.loads(pathlib.Path('assets/models/asr_dependencies.json').read_text(encoding='utf-8'))
    ids = set(args.ids)
    if any(m['id'] in ids and m['purpose'] == 'transcription' for m in catalog['models']):
        ids.add('silero-vad-16k')
    unknown = ids - {m['id'] for m in catalog['models'] + dependencies['models']}
    if unknown:
        parser.error('Unknown model IDs: ' + ', '.join(sorted(unknown)))
    for model in dependencies['models'] + catalog['models']:
        if model['id'] not in ids:
            continue
        folder = root / model['id']
        folder.mkdir(exist_ok=True)
        for item in model['files']:
            target = folder / item['name']
            if target.exists() and target.stat().st_size == item['bytes'] and digest(target) == item['sha256']:
                print(f'Already verified: {target.name}', flush=True)
                continue
            sources = item['sources']
            urls = [sources[key] for key in ['mainland', 'official', 'mirror', 'upstream'] if key in sources]
            success = False
            for url in urls:
                try:
                    print(f'Downloading {model["id"]}/{target.name}', flush=True)
                    req = urllib.request.Request(url, headers={'User-Agent': 'FluentPlayer-runtime-probe/1'})
                    with urllib.request.urlopen(req, timeout=60) as response, target.open('wb') as file:
                        received = 0
                        mark = 0
                        while chunk := response.read(1024 * 1024):
                            file.write(chunk)
                            received += len(chunk)
                            if received - mark > 64 * 1024 * 1024:
                                print(f'  {received // 1048576} / {item["bytes"] // 1048576} MiB', flush=True)
                                mark = received
                    if target.stat().st_size != item['bytes'] or digest(target) != item['sha256']:
                        raise ValueError('SHA-256 or size mismatch')
                    success = True
                    print(f'Verified {target.name}', flush=True)
                    break
                except Exception as error:
                    print(f'Source failed: {error}', flush=True)
            if not success:
                raise RuntimeError(f'No verified source for {target.name}')
    print(root, flush=True)

if __name__ == '__main__':
    main()
