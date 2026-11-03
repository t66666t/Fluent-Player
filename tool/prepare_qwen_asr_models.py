"""Explicit maintainer download of the pinned Qwen audio GGUF test weights.

Never called by the application, startup, or the normal verification suite.
Files are resumable, size checked and SHA-256 verified before publication.
"""
import argparse
import concurrent.futures
import hashlib
from pathlib import Path
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


MODELS = {
    'qwen3-asr-0.6b-f16': (
        'cstr/qwen3-asr-0.6b-GGUF', '58bd3202f835f46b24b17142cb503b0860c737a5',
        'qwen3-asr-0.6b.gguf', 1882037824,
        'fbfe8f9cd93fd788683c793ff43c9d28847003f925f37fda8b075886f315bdab'),
    'qwen3-asr-1.7b-f16': (
        'cstr/qwen3-asr-1.7b-GGUF', '674df5d44b50a63e7102a18895ed20e3f91de301',
        'qwen3-asr-1.7b-f16.gguf', 4704800576,
        'ac6c58f9cb0f2bb22290319cde01b0e25a2c1f1ee69aa2f1a9265f29a8bfc9d7'),
    'asr-qwen3-aligner-0.6b-f16': (
        'cstr/qwen3-forced-aligner-0.6b-GGUF', '1ec5110602ccab18c878ddebedab0891e290a95c',
        'qwen3-forced-aligner-0.6b-f16.gguf', 1841707200,
        '35bd243939212f675652d36de061bedf09daee9a7af2a866f47e57be148a8578'),
    'asr-language-id-voxlingua107-f16': (
        'cstr/ecapa-lid-107-GGUF', '4b58255b784cb053591bf10991ef80ff5cc032fb',
        'ecapa-lid-107-f16.gguf', 42838944,
        '59db30ba67cec2f36304f794420779c181124332246f75fc66c349f184110340'),
}

ASR_LANGUAGES = ['zh','en','yue','ar','de','fr','es','pt','id','it','ko','ru','th','vi','ja',
                 'tr','hi','ms','nl','sv','da','fi','pl','cs','fil','fa','el','hu','mk','ro']
ALIGNMENT_LANGUAGES = ['zh','en','yue','fr','de','it','ja','ko','pt','ru','es']


def reviewed_catalog_entries():
    """Reviewed exports, not an arbitrary GGUF architecture detector."""
    definitions = [
        ('qwen3-asr-0.6b-f16','Qwen3-ASR 0.6B', 'qwen3-asr','transcription',ASR_LANGUAGES,'0.6B',16,
         '官方多语言语音识别基座的 FP16 格式转换；支持中英日韩等 30 种语言，复用现有转录及文字翻译流程。',
         'https://huggingface.co/Qwen/Qwen3-ASR-0.6B'),
        ('qwen3-asr-1.7b-f16','Qwen3-ASR 1.7B', 'qwen3-asr','transcription',ASR_LANGUAGES,'1.7B',24,
         '面向较高配置设备的官方多语言识别基座 FP16 导出；支持日语、韩语和自动语言识别。',
         'https://huggingface.co/Qwen/Qwen3-ASR-1.7B'),
        ('asr-qwen3-aligner-0.6b-f16','多语言时间精校 Qwen3', 'qwen3-alignment','enhancement',ALIGNMENT_LANGUAGES,'0.6B（文本骨干）',8,
         '对已有原文进行时间精校；支持中英日韩等 11 种语言，复用现有字幕整理与翻译流程。',
         'https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B'),
        ('asr-language-id-voxlingua107-f16','共享音频语言识别 VoxLingua107', 'ecapa-language-id','enhancement',
         ['ja','ko','zh','en','multilingual'],'21M',4,
         '107 种语言的音频语言识别；只在自动语言信息不足时调用。低置信度片段保留句级时间。',
         'https://huggingface.co/speechbrain/lang-id-voxlingua107-ecapa'),
    ]
    result=[]
    for model_id,name,engine,purpose,languages,parameters,ram,description,homepage in definitions:
        repo,revision,filename,size,expected=MODELS[model_id]
        url=f'https://huggingface.co/{repo}/resolve/{revision}/{filename}'
        result.append(dict(id=model_id,name=name,engine=engine,revision=revision,parameters=parameters,
            quantization='FP16 · 音频 GGUF',purpose=purpose,languages=languages,description=description,
            license='Apache-2.0',homepage=homepage,suggestedRamGb=ram,
            memoryNote=f'建议 {ram} GB 设备起测；文件体积不等于运行内存。内存不足时识别、精校与翻译交替加载，速度和峰值以内置本机检查为准。',
            files=[dict(name=filename,bytes=size,sha256=expected,sources={
                'official':url,'mirror':url.replace('huggingface.co','hf-mirror.com'),
                'mirror_proxy':url.replace('huggingface.co','hf-mirror.net')})]))
    return result


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prepare(model_id, root):
    repo, revision, filename, size, expected = MODELS[model_id]
    target = root / model_id / filename
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.is_file() and target.stat().st_size == size and digest(target) == expected:
        print(f'{model_id}: already verified', flush=True)
        return
    partial = target.with_suffix(target.suffix + '.part')
    for attempt in range(6):
        offset = partial.stat().st_size if partial.is_file() else 0
        if offset == size:
            break
        if offset > size:
            raise RuntimeError(f'Oversized partial file: {partial}')
        # A fresh query prevents reuse of an expired Xet signed redirect.
        url = f'https://huggingface.co/{repo}/resolve/{revision}/{filename}?download=true&request={time.time_ns()}'
        request = Request(url, headers={'Range': f'bytes={offset}-'} if offset else {})
        try:
            with urlopen(request, timeout=120) as response:
                resumed = offset and response.status == 206
                if resumed and not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                    raise RuntimeError('Download resumed at an unexpected byte offset')
                with partial.open('ab' if resumed else 'wb') as output:
                    done = offset if resumed else 0
                    last = time.monotonic()
                    while block := response.read(4 * 1024 * 1024):
                        output.write(block)
                        done += len(block)
                        if done > size:
                            raise RuntimeError('Download exceeds the pinned size')
                        if time.monotonic() - last > 20:
                            print(f'{model_id}: {done / size:.0%}', flush=True)
                            last = time.monotonic()
            if partial.stat().st_size == size:
                break
        except (OSError, HTTPError) as error:
            print(f'{model_id}: attempt {attempt + 1}: {error}', flush=True)
            if attempt == 5:
                raise
            time.sleep(min(2 ** attempt, 15))
    if not partial.is_file() or partial.stat().st_size != size or digest(partial) != expected:
        raise RuntimeError(f'Weight verification failed: {model_id}')
    partial.replace(target)
    print(f'{model_id}: verified {size} bytes', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-root', type=Path, default=Path('.artifacts/model-center/native'))
    parser.add_argument('--models', nargs='+', choices=list(MODELS), default=list(MODELS))
    args = parser.parse_args()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futures = [executor.submit(prepare, model_id, args.model_root) for model_id in args.models]
        for future in futures:
            future.result()


if __name__ == '__main__':
    main()
