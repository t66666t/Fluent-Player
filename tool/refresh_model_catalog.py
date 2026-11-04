"""Refresh explicitly reviewed model revisions; never downloads model weights.

Run from the repository root. Every downloaded file is pinned and SHA-256
verified by the app, including files fetched through automatically selected domestic mirrors.
"""
import hashlib
import json
import pathlib
import urllib.request
from refresh_asr_enhancement_catalog import DEFINITIONS, resolve
from prepare_qwen_asr_models import reviewed_catalog_entries
from prepare_cohere_asr_models import reviewed_parakeet_japanese_entry

MODELS = [
    dict(id='sensevoice-small-int8', name='SenseVoice Small', engine='sensevoice', repo='csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17', revision='2365baeacb507f821a0c8120fcee3d484dba7a07', parameters='234M', quantization='INT8 · ONNX', purpose='transcription', languages=['zh','yue','en','ja','ko'], description='普通话、粤语、英语、日语、韩语；支持自动语言识别和文本规整。', license='FunASR Model License（权重）', homepage='https://huggingface.co/FunAudioLLM/SenseVoiceSmall', suggestedRamGb=4, memoryNote='建议从 4 GB 内存设备、单任务开始；实际峰值取决于音频与运行库，需本机检查。', names=['model.int8.onnx','tokens.txt'], modelscope='burgess123/sherpa-onnx-SenseVoice-Small-onnx'),
    dict(id='dolphin-base-int8', name='Dolphin Base', engine='dolphin', repo='csukuangfj/sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02', revision='1f3a53d0ecf658f8b0974e2cfde368eee40732fa', parameters='100M', quantization='INT8 · ONNX', purpose='transcription', languages=['zh','ja','th','ru','ko','id','vi','yue','hi','ur','ms','uz','ar','fa','bn','ta','te','ug','gu','my','tl','kk','or','ne','mn','km','jv','lo','si','fil','ps','pa','kab','ba','ks','tg','su','mr','ky','az'], description='覆盖 40 种东方语言的轻量识别模型；自动识别语言，可提供 token 时间戳。不支持英语。', license='Apache-2.0', homepage='https://github.com/DataoceanAI/Dolphin', suggestedRamGb=4, memoryNote='轻量候选；建议单任务运行，时间戳粒度需结合实际分词判断。', names=['model.int8.onnx','tokens.txt'], modelscope='csukuangfj/sherpa-onnx-dolphin-base-ctc-multi-lang-int8-2025-04-02'),
    dict(id='parakeet-v3-int8', name='Parakeet TDT v3', engine='parakeet', repo='csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8', revision='2bda32ec70b097a55adaa07d9a7173915b43cc78', parameters='600M', quantization='INT8 · ONNX', purpose='transcription', languages=['bg','hr','cs','da','nl','en','et','fi','fr','de','el','hu','it','lv','lt','mt','pl','pt','ro','sk','sl','es','sv','ru','uk'], description='包含英语在内的 25 种欧洲语言；自动语言识别、标点和 token 时间戳。', license='CC-BY-4.0', homepage='https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3', suggestedRamGb=8, memoryNote='建议 8 GB 及以上设备起测；模型较大，手机使用单任务并避免同时驻留翻译模型。', names=['encoder.int8.onnx','decoder.int8.onnx','joiner.int8.onnx','tokens.txt']),
    dict(id='hy-mt2-1.8b-q4', name='混元翻译 Hy-MT2', engine='hy-mt', repo='tencent/Hy-MT2-1.8B-GGUF', revision='a0c709d9fac510f2c807aa3af52872340dc37a4a', parameters='1.8B', quantization='Q4_K_M · GGUF', purpose='translation', languages=['zh','en','fr','pt','es','ja','tr','ru','ar','ko','th','it','de','vi','ms','id','tl','hi','pl','cs','nl','km','my','fa','gu','ur','te','mr','he','bn','ta','uk','bo','kk','mn','ug','yue'], description='专用翻译模型；支持上下文与术语要求。官方称覆盖 33 种语言，并列出其他语言变体。', license='Apache-2.0', homepage='https://huggingface.co/tencent/Hy-MT2-1.8B', suggestedRamGb=8, memoryNote='建议 8 GB 及以上设备起测；1.13 GB 为文件体积，不是运行内存。默认使用短上下文和单任务。', names=['Hy-MT2-1.8B-Q4_K_M.gguf'], modelscope='Tencent-Hunyuan/Hy-MT2-1.8B-GGUF'),
    dict(id='qwen3-4b-q4', name='Qwen3 4B', engine='qwen3', repo='Qwen/Qwen3-4B-GGUF', revision='bc640142c66e1fdd12af0bd68f40445458f3869b', parameters='4B', quantization='Q4_K_M · GGUF', purpose='translation', languages=['zh','en','ja','ko','fr','de','es','ru','ar','hi','pt','it','vi','th'], description='多语言通用指令模型；字幕翻译关闭思考模式，适合较高配置设备。完整语言覆盖见官方介绍。', license='Apache-2.0', homepage='https://huggingface.co/Qwen/Qwen3-4B', suggestedRamGb=16, memoryNote='建议 16 GB 桌面设备起测；CPU 翻译可能较慢，安装后可用本机检查获得实际速度。', names=['Qwen3-4B-Q4_K_M.gguf'], modelscope='Qwen/Qwen3-4B-GGUF'),
]

# Reviewed additions use independent IDs/revisions. Never replace earlier rows.
MODELS.extend([
    dict(id='whisper-large-v3-turbo-int8', retired=True, name='Whisper large-v3 Turbo', engine='whisper',
         repo='csukuangfj/sherpa-onnx-whisper-turbo', revision='2ca6ff69fc878651b770880507669577ac41c2ff',
         parameters='809M', quantization='INT8 · ONNX', purpose='transcription',
         languages=['zh','en','ja','ko','yue','af','am','ar','as','az','ba','be','bg','bn','bo','br','bs','ca','cs','cy','da','de','el','es','et','eu','fa','fi','fo','fr','gl','gu','ha','haw','he','hi','hr','ht','hu','hy','id','is','it','jw','ka','kk','km','kn','la','lb','ln','lo','lt','lv','mg','mi','mk','ml','mn','mr','ms','mt','my','ne','nl','nn','no','oc','pa','pl','ps','pt','ro','ru','sa','sd','si','sk','sl','sn','so','sq','sr','su','sv','sw','ta','te','tg','th','tk','tl','tr','tt','uk','ur','uz','vi','yi','yo'],
         description='large-v3 的加速版，809M 参数；导出支持中英日韩、粤语等 100 种语言标签。使用语音分段时间轴，中/英语可选 CTC 精校；转录并翻译沿用独立字幕翻译流程。',
         license='MIT', homepage='https://huggingface.co/openai/whisper-large-v3-turbo', suggestedRamGb=8,
         memoryNote='CPU 权重约 1.04 GB；高性能设备可安装独立 FP32 GPU 包，建议 16 GB 以上内存起测。GPU 包约 3.24 GB，文件体积不等于运行内存。',
         names=['turbo-encoder.int8.onnx','turbo-decoder.int8.onnx','turbo-tokens.txt']),
    dict(id='firered-asr2-ctc-int8', retired=True, name='FireRedASR2 CTC', engine='firered2',
         repo='csukuangfj2/sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25', revision='423be1acfdc5d8aaa5a485fb6263fe4ea8570b06',
         parameters='≈0.74B（CTC 导出）', quantization='INT8 · ONNX', purpose='transcription', languages=['zh','en','yue'],
         description='2026 年 FireRedASR2 的 encoder + CTC 分支，侧重中英混合及粤语、四川话、上海话等二十多种中文方言/口音；提供 40 ms 粒度 token 起点。不是 AED/LLM 导出，不套用其质量榜单。',
         license='Apache-2.0', homepage='https://huggingface.co/FireRedTeam/FireRedASR2-AED', suggestedRamGb=8,
         memoryNote='CPU 权重约 776 MB；使用专用特征归一化与 CTC 加载器。可选 FP32 GPU 包约 2.94 GB；建议 16 GB 以上内存设备起测，内存或驱动不足时回退 CPU。',
         names=['model.int8.onnx','tokens.txt']),
])

def read(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent':'FluentPlayer-model-catalog/1'}), timeout=40) as response:
        return response.read()

def main():
    result = []
    for definition in MODELS:
        model = dict(definition)
        repo = model.pop('repo')
        names = model.pop('names')
        ms = model.pop('modelscope', None)
        info = json.loads(read(f'https://huggingface.co/api/models/{repo}/revision/{model["revision"]}?blobs=true'))
        files = {file['rfilename']: file for file in info['siblings']}
        ms_files = {}
        if ms:
            ms_info = json.loads(read(f'https://modelscope.cn/api/v1/models/{ms}/repo/files?Revision=master&Recursive=true'))
            ms_files = {item['Path']: item for item in ms_info['Data']['Files']}
        model['files'] = []
        for name in names:
            file = files[name]
            url = f'https://huggingface.co/{repo}/resolve/{model["revision"]}/{name}'
            digest = file.get('lfs', {}).get('sha256')
            if not digest:
                assert file['size'] < 2_000_000
                digest = hashlib.sha256(read(url)).hexdigest()
            sources = {
                'official': url,
                'mirror': url.replace('https://huggingface.co/', 'https://hf-mirror.com/'),
                'mirror_proxy': url.replace('https://huggingface.co/', 'https://hf-mirror.net/'),
            }
            if ms:
                remote = ms_files[name]
                assert remote['Size'] == file['size'] and remote['Sha256'] == digest, f'ModelScope differs: {ms}/{name}'
                sources['mainland'] = f'https://modelscope.cn/models/{ms}/resolve/{remote["Revision"]}/{name}'
            model['files'].append(dict(name=name, bytes=file['size'], sha256=digest, sources=sources))
        result.append(model)
    result.extend(resolve(definition) for definition in DEFINITIONS)
    result.extend(reviewed_catalog_entries())
    result.append(reviewed_parakeet_japanese_entry())
    target = pathlib.Path('assets/models/catalog.json')
    target.write_text(json.dumps({'version':1, 'verifiedOn':'2026-10-27', 'models':result}, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(f'Updated {len(result)} pinned models: {target}')

if __name__ == '__main__':
    main()
