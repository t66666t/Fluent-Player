"""Developer-only native test assets. Not part of the application's download flow."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('models', nargs='+')
args = parser.parse_args()
catalog = json.loads((root / 'assets/models/catalog.json').read_text(encoding='utf-8'))['models']

def download(item):
    model, file = item
    folder = root / '.artifacts/asr-gpu/models' / model['id']
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / file['name']
    if target.exists() and target.stat().st_size == file['bytes']: return
    temporary = target.with_suffix(target.suffix + '.part')
    digest = hashlib.sha256()
    request = Request(file['sources']['official'], headers={'User-Agent': 'FluentPlayer-ASR-native-test'})
    with urlopen(request, timeout=180) as source, temporary.open('wb') as output:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk); output.write(chunk)
    if temporary.stat().st_size != file['bytes'] or digest.hexdigest() != file['sha256']:
        raise RuntimeError('Model download identity mismatch: ' + file['name'])
    temporary.replace(target)
    print(model['id'], file['name'], 'ready', flush=True)

work = [(model, file) for model in catalog if model['id'] in args.models for file in model['files']]
with ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(download, work))
