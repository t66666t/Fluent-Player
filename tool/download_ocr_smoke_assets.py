"""Download fixed OCR components for the native validation suite, never install them."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.artifacts/ocr-upgrade/models')
    parser.add_argument('--ids', nargs='*')
    args = parser.parse_args()
    root = Path(args.root)
    catalog = json.loads(Path('assets/models/ocr_catalog.json').read_text(encoding='utf-8'))
    models = [m for m in catalog['components'] if m['engine'] == 'ppocr' and (not args.ids or m['id'] in args.ids)]

    def fetch(job):
        model, spec = job
        target = root / model['id'] / spec['name']
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == spec['sha256']:
            return str(target)
        partial = target.with_suffix(target.suffix + '.part')
        last = None
        for source in ['mainland', 'official', 'mirror_proxy', 'mirror']:
            for attempt in range(3):
                try:
                    offset = partial.stat().st_size if partial.exists() else 0
                    request = urllib.request.Request(spec['sources'][source], headers={
                        'User-Agent': 'FluentPlayer-OCR-validation/1', 'Accept-Encoding': 'identity',
                        **({'Range': f'bytes={offset}-'} if offset else {})})
                    with urllib.request.urlopen(request, timeout=25) as response:
                        if response.status == 200:
                            offset = 0
                        with partial.open('ab' if offset else 'wb') as sink:
                            while True:
                                chunk = response.read(65536)
                                if not chunk:
                                    break
                                sink.write(chunk)
                    if partial.stat().st_size != spec['bytes']:
                        raise ValueError('incomplete download')
                    if hashlib.sha256(partial.read_bytes()).hexdigest() != spec['sha256']:
                        partial.unlink()
                        raise ValueError('wrong model hash')
                    partial.replace(target)
                    return str(target)
                except Exception as error:
                    last = error
        raise RuntimeError(f'{model["id"]}/{spec["name"]}: {last}')

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for path in pool.map(fetch, [(m, f) for m in models for f in m['files']]):
            print(path, flush=True)


if __name__ == '__main__':
    main()
