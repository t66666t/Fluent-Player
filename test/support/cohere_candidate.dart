// Development comparison only; intentionally absent from the selectable catalog.
import 'package:video_player_app/features/model_center/model_catalog.dart';

ModelArtifact cohereComparisonCandidate() => ModelArtifact.fromJson({
  "id": "cohere-transcribe-03-2026-q8",
  "name": "Cohere Transcribe 2B · 日语 Q8",
  "engine": "cohere-asr",
  "revision": "7353b6040bdc1be9e5a3823d99d5fe12afe88264",
  "parameters": "2B",
  "quantization": "Q8_0 · GGUF",
  "purpose": "transcription",
  "languages": ["ja"],
  "description":
      "2026 年 3 月基座的日语专用预设，固定日语提示，自动设置也按日语识别。原生 CPU 分段处理，复用共享日语分词与时间精校。动画口语仍可能漏词、漏句，不承诺最优准确率。",
  "license": "Apache-2.0",
  "homepage": "https://huggingface.co/CohereLabs/cohere-transcribe-03-2026",
  "suggestedRamGb": 8,
  "memoryNote":
      "Q8 权重约 2.41 GB；小米手机短片段独立 CPU 推理峰值约 3.34 GiB，完整流水线还需播放器及增强余量。实际准入以系统可用内存为准；识别与较大精校模型按预算交替加载。首批仅启用 CPU。",
  "files": [
    {
      "name": "cohere-transcribe-03-2026-Q8_0.gguf",
      "bytes": 2410655232,
      "sha256":
          "931916663432fd895423a4291a8400221802b288967ca2d435fc5e3141c9e71e",
      "sources": {
        "official":
            "https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/resolve/7353b6040bdc1be9e5a3823d99d5fe12afe88264/cohere-transcribe-03-2026-Q8_0.gguf",
        "mirror":
            "https://hf-mirror.com/handy-computer/cohere-transcribe-03-2026-gguf/resolve/7353b6040bdc1be9e5a3823d99d5fe12afe88264/cohere-transcribe-03-2026-Q8_0.gguf",
        "mirror_proxy":
            "https://hf-mirror.net/handy-computer/cohere-transcribe-03-2026-gguf/resolve/7353b6040bdc1be9e5a3823d99d5fe12afe88264/cohere-transcribe-03-2026-Q8_0.gguf",
      },
    },
  ],
});
