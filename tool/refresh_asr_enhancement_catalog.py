"""Resolve explicitly pinned ASR enhancement packs and optionally smoke weights.

No model code is downloaded or executed. All runtime files have a size and
SHA-256; ONNX conversions are linked to their original model in the catalog.
"""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request

DEFINITIONS = [
    dict(id='asr-punctuation-zh-en-int8', name='中英标点 CT-Transformer', engine='punctuation',
         repo='ranger810/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8', revision='5cccf43af83e4fc50d1d55b8410312e87709be70',
         parameters='优化导出未单列参数量', languages=['zh', 'en'], license='Apache-2.0（原始权重）',
         homepage='https://k2-fsa.github.io/sherpa/onnx/punctuation/pretrained_models.html',
         description='为缺少标点的中英文恢复标点；仅接受标点和空白变更，保留识别词与时间映射。社区副本已与官方发布文件核对。',
         files={'model.int8.onnx': 'model.int8.onnx'}, ram=4),
    dict(id='asr-gtcrn', name='轻量降噪 GTCRN', engine='denoiser',
         repo='bitsydarel/gtcrn-onnx', revision='080f79f8c66b07e655347137d734d5556117eda3',
         parameters='48.2K（含 ERB）', languages=['language-independent'], license='MIT',
         homepage='https://github.com/Xiaobin-Rong/gtcrn',
         description='16 kHz 轻量语音增强。与官方发布文件逐字节一致；保持原始采样时间轴，适用于噪声录音，可单独关闭。',
         files={'gtcrn_simple.onnx': 'model.onnx'}, ram=4),
    dict(id='asr-alignment-en-int8', name='英语时间精校 Wav2Vec2 Base', engine='ctc-alignment-en',
         repo='onnx-community/wav2vec2-base-960h-ONNX', revision='729c1a6730fb549c20a1c73a3d3f96f11020225e',
         parameters='约 94M', languages=['en'], license='Apache-2.0（原始权重）',
         homepage='https://huggingface.co/facebook/wav2vec2-base-960h',
         description='英语 CTC 声学模型的 ONNX 转换；对已有原文做 Viterbi 强制对齐，保留原文并标记低匹配片段。',
         files={'onnx/model_quantized.onnx': 'model.int8.onnx', 'vocab.json': 'vocab.json', 'preprocessor_config.json': 'preprocessor_config.json'}, ram=4),
    dict(id='asr-alignment-zh-int8', name='普通话时间精校 XLSR-53', engine='ctc-alignment-zh',
         repo='onnx-community/wav2vec2-large-xlsr-53-chinese-zh-cn-ONNX', revision='269b21c2b6ea9bebaa5d6b17bfeebf5a23beaa7b',
         parameters='约 317M', languages=['zh'], license='Apache-2.0（原始权重）',
         homepage='https://huggingface.co/jonatasgrosman/wav2vec2-large-xlsr-53-chinese-zh-cn',
         description='普通话 CTC 强制对齐；不改写识别结果。逐个短窗口执行，加载前释放识别器；不把普通话模型用于粤语或日语。',
         files={'onnx/model_quantized.onnx': 'model.int8.onnx', 'vocab.json': 'vocab.json', 'preprocessor_config.json': 'preprocessor_config.json'}, ram=6),
    dict(id='zipformer-zh-en-tiny-int8', retired=True, name='Zipformer Tiny 中英 · 热词', engine='zipformer',
         repo='csukuangfj/k2fsa-zipformer-bilingual-zh-en-t', revision='e2382758de9a0219b4efe682b95af30b399db3b8',
         parameters='Tiny · 上游未单列参数量', languages=['zh', 'en'], license='Apache-2.0',
         homepage='https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t',
         description='轻量中英流式 Transducer，用于本地文件转录；支持修改束搜索与热词。热词帮助专业名词识别，不保证一定输出指定词。',
         files={'exp/32/encoder-epoch-99-avg-1.int8.onnx':'encoder.int8.onnx', 'exp/32/decoder-epoch-99-avg-1.int8.onnx':'decoder.int8.onnx', 'exp/32/joiner-epoch-99-avg-1.int8.onnx':'joiner.int8.onnx', 'data/lang_char_bpe/tokens.txt':'tokens.txt', 'data/lang_char_bpe/bpe.vocab':'bpe.vocab'}, ram=4),
]

def read(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent':'FluentPlayer-model-review/1'}), timeout=90) as response:
        return response.read()

def resolve(definition):
    d = dict(definition)
    repo, names, ram = d.pop('repo'), d.pop('files'), d.pop('ram')
    info = json.loads(read(f'https://huggingface.co/api/models/{repo}/revision/{d["revision"]}?blobs=true'))
    assert info['sha'].startswith(d['revision'])
    d['revision'] = info['sha']
    files = {f['rfilename']:f for f in info['siblings']}
    d.update(purpose='transcription' if d['engine']=='zipformer' else 'enhancement',
             quantization='FP32 · ONNX' if d['engine'] in ['denoiser'] else 'INT8 · ONNX',
             suggestedRamGb=ram, memoryNote=f'建议 {ram} GB 设备起测；CPU 串行执行，文件体积不等于运行内存。', files=[])
    for remote, local in names.items():
        meta=files[remote]
        url=f'https://huggingface.co/{repo}/resolve/{d["revision"]}/{remote}'
        digest=meta.get('lfs',{}).get('sha256')
        if digest is None:
            assert meta['size'] < 1_000_000
            digest=hashlib.sha256(read(url)).hexdigest()
        sources={'official':url, 'mirror':url.replace('huggingface.co','hf-mirror.com'), 'mirror_proxy':url.replace('huggingface.co','hf-mirror.net')}
        if d['engine']=='denoiser':
            assert digest=='e77603ac0c23dac3227dd2d7135b3a585cbee2679048aecfa886657d3ae1b534'
            sources['upstream']='https://github.com/k2-fsa/sherpa-onnx/releases/download/speech-enhancement-models/gtcrn_simple.onnx'
        d['files'].append(dict(name=local, bytes=meta['size'], sha256=digest, sources=sources))
    return d

def download(model):
    folder=Path('.artifacts/model-center/enhancements')/model['id']
    folder.mkdir(parents=True,exist_ok=True)
    for meta in model['files']:
        target=folder/meta['name']
        if target.exists() and hashlib.file_digest(target.open('rb'),'sha256').hexdigest()==meta['sha256']: continue
        seeds={'asr-punctuation-zh-en-int8':'punct.int8.onnx','asr-gtcrn':'gtcrn_simple.onnx'}
        seed=folder.parent/seeds.get(model['id'],'no-seed')
        if seed.exists() and hashlib.file_digest(seed.open('rb'),'sha256').hexdigest()==meta['sha256']:
            shutil.copyfile(seed,target)
        else:
            with urllib.request.urlopen(meta['sources']['official'],timeout=180) as response, target.with_suffix('.partial').open('wb') as out:
                while chunk:=response.read(1024*1024): out.write(chunk)
            target.with_suffix('.partial').replace(target)
        assert target.stat().st_size==meta['bytes']
        assert hashlib.file_digest(target.open('rb'),'sha256').hexdigest()==meta['sha256']
    print(f'Verified {model["id"]}',flush=True)

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--download',action='store_true'); args=parser.parse_args()
    with concurrent.futures.ThreadPoolExecutor(max_workers=7) as pool: additions=list(pool.map(resolve,DEFINITIONS))
    target=Path('assets/models/catalog.json'); catalog=json.loads(target.read_text(encoding='utf-8'))
    ids={m['id'] for m in additions} | {'asr-speaker-segmentation-int8', 'asr-speaker-campplus'}
    catalog['models']=[m for m in catalog['models'] if m['id'] not in ids]+additions
    target.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'Pinned {len(additions)} ASR/ enhancement packs',flush=True)
    if args.download:
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool: list(pool.map(download,[m for m in additions if not m.get('retired')]))

if __name__=='__main__': main()
