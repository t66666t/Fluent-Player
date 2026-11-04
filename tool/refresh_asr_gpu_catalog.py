"""Refresh optional ASR float packs from immutable official export revisions."""
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
ROWS = [
    ('sensevoice-small-int8', 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
     '2365baeacb507f821a0c8120fcee3d484dba7a07', {'model.onnx': 'model.onnx'}),
    ('dolphin-base-int8', 'csukuangfj/sherpa-onnx-dolphin-base-ctc-multi-lang-2025-04-02',
     '819b6e48f032e58d7800dd1e0550411352f22d1a', {'model.onnx': 'model.onnx'}),
    ('parakeet-v3-int8', 'csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3',
     '1a468a35cbba69418f126de829e75261dea4a4e4',
     {name: name for name in ['encoder.onnx', 'encoder.weights', 'decoder.onnx', 'joiner.onnx']}),
    ('zipformer-zh-en-tiny-int8', 'csukuangfj/k2fsa-zipformer-bilingual-zh-en-t',
     'e2382758de9a0219b4efe682b95af30b399db3b8',
     {f'{name}.onnx': f'exp/32/{name}-epoch-99-avg-1.onnx' for name in ['encoder', 'decoder', 'joiner']}),
    ('whisper-large-v3-turbo-int8', 'csukuangfj/sherpa-onnx-whisper-turbo',
     '2ca6ff69fc878651b770880507669577ac41c2ff',
     {name: name for name in ['turbo-encoder.onnx', 'turbo-encoder.weights', 'turbo-decoder.onnx']}),
    ('firered-asr2-ctc-int8', 'csukuangfj2/sherpa-onnx-fire-red-asr2-ctc-zh_en-2026-02-25',
     '5816c6e906b01242cb707fd989967a8db8b2a556',
     {name: name for name in ['model.onnx', 'model.weights']}),
]

def fetch(url):
    with urlopen(url, timeout=120) as response:
        return response.read()

catalog_file = ROOT / 'assets/models/catalog.json'
catalog = json.loads(catalog_file.read_text(encoding='utf-8'))
catalog['verifiedOn'] = '2026-10-27'
catalog['models'] = [m for m in catalog['models'] if m.get('purpose') != 'acceleration']
for model_id, repo, revision, paths in ROWS:
    parent = next(m for m in catalog['models'] if m['id'] == model_id)
    metadata = json.loads(fetch(f'https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true'))
    by_path = {f['path']: f for f in metadata}
    files = []
    for filename, upstream in paths.items():
        item = by_path[upstream]
        digest = item['lfs']['oid']
        files.append(dict(name=filename, bytes=item['size'], sha256=digest, sources={
            'official': f'https://huggingface.co/{repo}/resolve/{revision}/{upstream}',
            'mirror': f'https://hf-mirror.com/{repo}/resolve/{revision}/{upstream}',
            'mirror_proxy': f'https://hf-mirror.net/{repo}/resolve/{revision}/{upstream}',
        }))
    # Each pack is independently complete. Do not depend on a different export's
    # vocabulary when float/int8 exports live in separate upstream repositories.
    for original in parent['files']:
        if original['name'] not in ['tokens.txt', 'turbo-tokens.txt', 'bpe.vocab']:
            continue
        upstream_url = original['sources']['official']
        if original['name'] == 'tokens.txt' and 'tokens.txt' in by_path:
            upstream_url = f'https://huggingface.co/{repo}/resolve/{revision}/tokens.txt'
        data = fetch(upstream_url)
        files.append(dict(name=original['name'], bytes=len(data),
                          sha256=hashlib.sha256(data).hexdigest(), sources={
            'official': upstream_url,
            'mirror': upstream_url.replace('huggingface.co', 'hf-mirror.com'),
            'mirror_proxy': upstream_url.replace('huggingface.co', 'hf-mirror.net'),
        }))
    catalog['models'].append({
        **parent, 'id': model_id + '-gpu', 'name': parent['name'] + ' GPU 可选加速包',
        'purpose': 'acceleration', 'engine': parent['engine'], 'revision': revision,
        'quantization': 'FP32 · ONNX', 'files': files,
        'description': '可选浮点识别权重；仅供同名转录模型的硬件后端使用。下载后仍须本机检查和测速，GPU 不可用时保留原 INT8 CPU 路径。',
        'memoryNote': '额外权重不替换原模型；显存和内存不足时自动使用 CPU。文件体积不等于运行内存。',
    })
catalog_file.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
for model in catalog['models']:
    if model['purpose'] == 'acceleration':
        print(model['id'], sum(f['bytes'] for f in model['files']), 'bytes')
