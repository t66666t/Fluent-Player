"""Reviewed Cohere Q8 export. Called by catalog maintenance, never at startup."""

def reviewed_cohere_catalog_entry():
    revision = '7353b6040bdc1be9e5a3823d99d5fe12afe88264'
    name = 'cohere-transcribe-03-2026-Q8_0.gguf'
    url = f'https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/resolve/{revision}/{name}'
    return dict(
        id='cohere-transcribe-03-2026-q8', name='Cohere Transcribe 2B · 日语 Q8', engine='cohere-asr',
        revision=revision, parameters='2B', quantization='Q8_0 · GGUF', purpose='transcription',
        languages=['ja'],
        description='2026 年 3 月基座的日语专用预设，固定日语提示，自动设置也按日语识别。原生 CPU 分段处理，复用共享日语分词与时间精校。动画口语仍可能漏词、漏句，不承诺最优准确率。',
        license='Apache-2.0', homepage='https://huggingface.co/CohereLabs/cohere-transcribe-03-2026',
        suggestedRamGb=8,
        memoryNote='Q8 权重约 2.41 GB；小米手机短片段独立 CPU 推理峰值约 3.34 GiB，完整流水线还需播放器及增强余量。实际准入以系统可用内存为准；识别与较大精校模型按预算交替加载。首批仅启用 CPU。',
        files=[dict(name=name, bytes=2410655232,
                    sha256='931916663432fd895423a4291a8400221802b288967ca2d435fc5e3141c9e71e',
                    sources={'official':url,'mirror':url.replace('https://huggingface.co/','https://hf-mirror.com/'),
                             'mirror_proxy':url.replace('https://huggingface.co/','https://hf-mirror.net/')})],
    )


def reviewed_parakeet_japanese_entry():
    revision = 'd9e3ba65a6579796389ea89e5939509ed257f972'
    name = 'parakeet-tdt-0.6b-ja-q8_0.gguf'
    url = f'https://huggingface.co/cstr/parakeet-tdt-0.6b-ja-GGUF/resolve/{revision}/{name}'
    return dict(
        id='parakeet-ja-0.6b-q8', name='Parakeet 0.6B · 日语 Q8', engine='parakeet-ja',
        revision=revision, parameters='0.6B', quantization='Q8_0 · GGUF', purpose='transcription', languages=['ja'],
        description='NVIDIA 日语专用 Hybrid TDT/CTC，使用 CTC 解码、短语音分段和有界漏句恢复。默认保留原音、固定日语；原生 token 时间复用日语分词与字幕流水线，无需另下大精校模型。不是 2026 年新训练基座，动画童声仍可能识别错误。',
        license='CC-BY-4.0（需署名，可商用）', homepage='https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja',
        suggestedRamGb=6, memoryNote='权重约 674 MB；原生 CPU、短语音分段识别和 CTC 时间戳。预计额外工作集约 2 GiB，按当前可用内存准入；核显、NPU不作为本版本依赖。Windows x64、Android arm64 已实测；其余平台需构建匹配组件并验证。',
        files=[dict(name=name, bytes=673554880, sha256='5a61e6c7d956c3c72a76fafcd798cac0c9ea66d0e29b3910cd04865a1e42cc17',
                    sources={'official':url,'mirror':url.replace('https://huggingface.co/','https://hf-mirror.com/'),
                             'mirror_proxy':url.replace('https://huggingface.co/','https://hf-mirror.net/')})],
    )
