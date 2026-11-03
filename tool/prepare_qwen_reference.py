"""Download pinned official weights explicitly, for developer parity checks only."""
import json
import hashlib
import shutil
import sys
from pathlib import Path
from urllib.request import urlopen, build_opener, ProxyHandler, Request
from urllib.parse import quote, urlparse
import prepare_qwen_asr_models as exports
from prepare_qwen_asr_models import MODELS, prepare

if '--direct' in sys.argv:
    # Developer-only opt-in, scoped to this process; no system proxy changes.
    urlopen = build_opener(ProxyHandler({})).open
    exports.urlopen = urlopen
if '--modelscope' in sys.argv:
    def official_modelscope(request, **kwargs):
        url = request.full_url
        parts = urlparse(url).path.strip('/').split('/')
        repository = '/'.join(parts[:2])
        filename = '/'.join(parts[4:])
        url = f'https://modelscope.cn/api/v1/models/{repository}/repo?Revision=master&FilePath={quote(filename)}'
        return urlopen(Request(url, headers=dict(request.header_items())), **kwargs)
    # Same official tensors: every safetensors file still must match the pinned
    # Hugging Face LFS SHA-256 before being accepted as a reference.
    exports.urlopen = official_modelscope

ROOT = Path(__file__).resolve().parents[1] / '.artifacts/qwen-integration/reference'
PINS = {
    'Qwen/Qwen3-ASR-0.6B': '5eb144179a02acc5e5ba31e748d22b0cf3e303b0',
    'Qwen/Qwen3-ASR-1.7B': '7278e1e70fe206f11671096ffdd38061171dd6e5',
    'Qwen/Qwen3-ForcedAligner-0.6B': 'c7cbfc2048c462b0d63a45797104fc9db3ad62b7',
}
ROOT.mkdir(parents=True, exist_ok=True)
manifest = json.loads((ROOT/'models.json').read_text(encoding='utf-8')) if (ROOT/'models.json').exists() else {}
for model, revision in PINS.items():
    if model in manifest and manifest[model]['revision'] == revision:
        continue
    path = ROOT/'official'/model.split('/')[1]
    path.mkdir(parents=True, exist_ok=True)
    cache = ROOT/'hf'/('models--'+model.replace('/', '--'))
    with urlopen(f'https://huggingface.co/api/models/{model}/tree/{revision}?recursive=true',timeout=90) as response:
        files = json.load(response)
    for item in files:
        name = item['path']
        if item['type'] != 'file' or not (name.endswith(('.json','.txt','.safetensors')) or name == 'LICENSE'):
            continue
        target = path/name
        cached = cache/'snapshots'/revision/name
        if not target.exists() and cached.is_file() and cached.stat().st_size == item['size']:
            shutil.copy2(cached, target)
        if item.get('lfs'):
            expected = item['lfs']['oid']
            partial = target.with_suffix(target.suffix+'.part')
            old = next((cache/'blobs').glob(expected+'.*.incomplete'),None)
            if old and not partial.exists() and not target.exists():
                shutil.copy2(old, partial)
            key = model.split('/')[1]
            MODELS[key] = (model, revision, name, item['size'], expected)
            prepare(key, path.parent)
        elif not target.is_file():
            request = Request(f'https://huggingface.co/{model}/resolve/{revision}/{name}')
            reader = official_modelscope if '--modelscope' in sys.argv else urlopen
            with reader(request,timeout=90) as response:
                target.write_bytes(response.read())
        if target.stat().st_size != item['size']:
            raise ValueError('Incomplete official reference: '+name)
        if not item.get('lfs') and item.get('oid'):
            content=target.read_bytes()
            if hashlib.sha1(f'blob {len(content)}\0'.encode()+content).hexdigest() != item['oid']:
                raise ValueError('Official reference small-file revision mismatch: '+name)
    manifest[model] = {'revision': revision, 'path': str(path)}
    (ROOT/'models.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print('Prepared official reference', model, flush=True)
