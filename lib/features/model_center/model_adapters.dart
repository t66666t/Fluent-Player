/// Shared family contracts. Catalog additions reuse an existing family; a new
/// family needs a verified loader and subtitle/timestamp contract first.
enum LocalAsrArchitecture {
  senseVoice,
  dolphin,
  parakeetTdt,
  zipformerStreaming,
  whisper,
  fireRed2Ctc,
  qwen3Asr,
  cohereAsr,
  parakeetJapanese,
}

class LocalAsrAdapter {
  const LocalAsrAdapter({
    required this.architecture,
    required this.files,
    this.gpuFiles = const [],
    this.tokenTiming,
    this.supportsHotwords = false,
    this.windowsNativeWorker = false,
    this.sharedCpuGpuWeights = false,
    this.fixedLanguage,
  });
  final LocalAsrArchitecture architecture;
  final List<String> files;
  final List<String> gpuFiles;
  final String? tokenTiming;
  final bool supportsHotwords;
  final bool windowsNativeWorker;
  final bool sharedCpuGpuWeights;
  final String? fixedLanguage;
  bool get streaming => architecture == LocalAsrArchitecture.zipformerStreaming;
  bool get nativeWorker =>
      architecture == LocalAsrArchitecture.fireRed2Ctc ||
      architecture == LocalAsrArchitecture.qwen3Asr ||
      architecture == LocalAsrArchitecture.cohereAsr ||
      architecture == LocalAsrArchitecture.parakeetJapanese;
}

const localAsrAdapters = <String, LocalAsrAdapter>{
  'parakeet-ja': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.parakeetJapanese,
    files: ['parakeet-tdt-0.6b-ja-q8_0.gguf'],
    tokenTiming: 'parakeet-ja-ctc-80ms-gap-recovery-v1',
    fixedLanguage: 'ja',
  ),
  'cohere-asr': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.cohereAsr,
    files: ['cohere-transcribe-03-2026-Q8_0.gguf'],
    tokenTiming: 'vad-segment-cohere-v1',
    fixedLanguage: 'ja',
  ),
  'qwen3-asr': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.qwen3Asr,
    files: [], // Exactly one of the family-specific audio GGUFs is required.
    supportsHotwords: true,
    sharedCpuGpuWeights: true,
    tokenTiming: 'vad-segment-qwen3-v1',
  ),
  'sensevoice': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.senseVoice,
    files: ['model.int8.onnx', 'tokens.txt'],
    gpuFiles: ['model.onnx', 'tokens.txt'],
  ),
  'dolphin': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.dolphin,
    files: ['model.int8.onnx', 'tokens.txt'],
    gpuFiles: ['model.onnx', 'tokens.txt'],
  ),
  'parakeet': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.parakeetTdt,
    files: [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'joiner.int8.onnx',
      'tokens.txt',
    ],
    tokenTiming: 'tdt-frame-groups-v2',
    gpuFiles: ['encoder.onnx', 'decoder.onnx', 'joiner.onnx', 'tokens.txt'],
  ),
  'zipformer': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.zipformerStreaming,
    supportsHotwords: true,
    gpuFiles: [
      'encoder.onnx',
      'decoder.onnx',
      'joiner.onnx',
      'tokens.txt',
      'bpe.vocab',
    ],
    files: [
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'joiner.int8.onnx',
      'tokens.txt',
      'bpe.vocab',
    ],
  ),
  'whisper': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.whisper,
    windowsNativeWorker: true,
    files: [
      'turbo-encoder.int8.onnx',
      'turbo-decoder.int8.onnx',
      'turbo-tokens.txt',
    ],
    gpuFiles: [
      'turbo-encoder.onnx',
      'turbo-encoder.weights',
      'turbo-decoder.onnx',
      'turbo-tokens.txt',
    ],
  ),
  'firered2': LocalAsrAdapter(
    architecture: LocalAsrArchitecture.fireRed2Ctc,
    files: ['model.int8.onnx', 'tokens.txt'],
    gpuFiles: ['model.onnx', 'model.weights', 'tokens.txt'],
    tokenTiming: 'ctc-40ms-v1',
  ),
};

const qwenAsrWeightFiles = ['qwen3-asr-0.6b.gguf', 'qwen3-asr-1.7b-f16.gguf'];

LocalAsrAdapter localAsrAdapter(String engine) =>
    localAsrAdapters[engine] ??
    (throw ArgumentError.value(engine, 'engine', '未接入的本地转录引擎'));

/// Preserve the original task JSON and all accepted checkpoint keys.
String? legacyAsrTokenTiming(String modelId) =>
    modelId == 'parakeet-v3-int8' ? 'tdt-frame-groups-v2' : null;

/// New IDs inherit the family's timing format; existing IDs need no new field.
String? asrTokenTimingOverride(String modelId, String engine) {
  final timing = localAsrAdapters[engine]?.tokenTiming;
  return timing == legacyAsrTokenTiming(modelId) ? null : timing;
}

/// Explicit checks must use speech supported by the selected recognizer.
String localAsrProbeAsset(
  String engine,
  List<String> languages, {
  String language = 'auto',
}) => localAsrAdapters[engine]?.fixedLanguage == 'ja'
    ? 'assets/models/asr/speech_probe_ja.wav'
    : languages.contains('en') && !const ['zh', 'yue'].contains(language)
    ? 'assets/models/asr/speech_probe.wav'
    : 'assets/models/asr/speech_probe_zh.wav';

enum LocalTranslationPrompt { hyMt, generic }

const localTranslationAdapters = <String, LocalTranslationPrompt>{
  'hy-mt': LocalTranslationPrompt.hyMt,
  'qwen3': LocalTranslationPrompt.generic,
};

bool localTranslationUsesEnglishPrompt(String engine, String targetLanguage) =>
    localTranslationAdapters[engine] != LocalTranslationPrompt.hyMt ||
    !targetLanguage.startsWith('zh');
