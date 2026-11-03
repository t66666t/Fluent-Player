import 'model_adapters.dart';

enum AsrAudioChannel { mix, left, right }

const currentAsrTextProcessingVersion = 2;
bool usesAsrTextProcessing(int? version) => version == 1 || version == 2;
// No longer offered by the player. Ignore these dependencies in saved jobs.
const retiredAsrModelIds = {
  'asr-speaker-segmentation-int8',
  'asr-speaker-campplus',
};

/// Frozen per task. Missing options in an old task mean its original pipeline;
/// missing preferences in the model center use the enabled defaults below.
class AsrEnhancementOptions {
  const AsrEnhancementOptions({
    this.enabled = true,
    this.denoise = true,
    this.punctuation = true,
    this.alignment = true,
    this.alwaysAlign = false,
    this.trimSilence = true,
    this.review = true,
    this.paddingMs = 160,
    this.vadThreshold = .5,
    this.minSilenceMs = 350,
    this.minSpeechMs = 180,
    this.maxSpeechMs = 12000,
    this.channel = AsrAudioChannel.mix,
    this.hotwords = '',
  });

  static const recommended = AsrEnhancementOptions();
  static const disabled = AsrEnhancementOptions(enabled: false);
  static const punctuationId = 'asr-punctuation-zh-en-int8';
  static const denoiserId = 'asr-gtcrn';
  static const alignmentEnglishId = 'asr-alignment-en-int8';
  static const alignmentChineseId = 'asr-alignment-zh-int8';
  static const alignmentQwenId = 'asr-qwen3-aligner-0.6b-f16';
  static const languageId = 'asr-language-id-voxlingua107-f16';
  static const qwenAlignmentLanguages = {
    'zh',
    'en',
    'yue',
    'fr',
    'de',
    'it',
    'ja',
    'ko',
    'pt',
    'ru',
    'es',
  };
  static bool isAlignmentModel(String id) =>
      id == alignmentChineseId ||
      id == alignmentEnglishId ||
      id == alignmentQwenId;

  final bool enabled, denoise, punctuation, alignment, trimSilence, review;
  final bool alwaysAlign;
  final int paddingMs, minSilenceMs, minSpeechMs, maxSpeechMs;
  final double vadThreshold;
  final AsrAudioChannel channel;
  final String hotwords;

  Map<String, Object> toJson() => {
    'version': 2,
    'enabled': enabled,
    'denoise': denoise,
    'punctuation': punctuation,
    'alignment': alignment,
    'alwaysAlign': alwaysAlign,
    'trimSilence': trimSilence,
    'review': review,
    'paddingMs': paddingMs,
    'vadThreshold': vadThreshold,
    'minSilenceMs': minSilenceMs,
    'minSpeechMs': minSpeechMs,
    'maxSpeechMs': maxSpeechMs,
    'channel': channel.name,
    'hotwords': hotwords,
  };

  /// Only audio preparation / native decoding settings belong to raw ASR keys.
  Map<String, Object> get audioJson => !enabled
      ? const {}
      : {
          'version': 1,
          'denoise': denoise,
          'paddingMs': paddingMs,
          'vadThreshold': vadThreshold,
          'minSilenceMs': minSilenceMs,
          'minSpeechMs': minSpeechMs,
          'maxSpeechMs': maxSpeechMs,
          'channel': channel.name,
          'hotwords': hotwords.trim(),
        };

  factory AsrEnhancementOptions.fromJson(Object? raw) {
    if (raw is! Map) return recommended;
    int number(String key, int fallback, int min, int max) =>
        ((raw[key] as num?)?.toInt() ?? fallback).clamp(min, max);
    return AsrEnhancementOptions(
      enabled: raw['enabled'] != false,
      denoise: raw['denoise'] != false,
      punctuation: raw['punctuation'] != false,
      alignment: raw['alignment'] != false,
      alwaysAlign: raw['alwaysAlign'] == true,
      trimSilence: raw['trimSilence'] != false,
      review: raw['review'] != false,
      paddingMs: number('paddingMs', 160, 0, 500),
      vadThreshold: ((raw['vadThreshold'] as num?)?.toDouble() ?? .5).clamp(
        .15,
        .85,
      ),
      minSilenceMs: number('minSilenceMs', 350, 150, 1500),
      minSpeechMs: number('minSpeechMs', 180, 100, 1000),
      maxSpeechMs: number('maxSpeechMs', 12000, 5000, 25000),
      channel: AsrAudioChannel.values.firstWhere(
        (v) => v.name == raw['channel'],
        orElse: () => AsrAudioChannel.mix,
      ),
      hotwords: (raw['hotwords'] as String? ?? '').trim(),
    );
  }

  AsrEnhancementOptions copyWith({
    bool? enabled,
    bool? denoise,
    bool? punctuation,
    bool? alignment,
    bool? alwaysAlign,
    bool? trimSilence,
    bool? review,
    int? paddingMs,
    double? vadThreshold,
    int? minSilenceMs,
    int? minSpeechMs,
    int? maxSpeechMs,
    AsrAudioChannel? channel,
    String? hotwords,
  }) => AsrEnhancementOptions(
    enabled: enabled ?? this.enabled,
    denoise: denoise ?? this.denoise,
    punctuation: punctuation ?? this.punctuation,
    alignment: alignment ?? this.alignment,
    alwaysAlign: alwaysAlign ?? this.alwaysAlign,
    trimSilence: trimSilence ?? this.trimSilence,
    review: review ?? this.review,
    paddingMs: paddingMs ?? this.paddingMs,
    vadThreshold: vadThreshold ?? this.vadThreshold,
    minSilenceMs: minSilenceMs ?? this.minSilenceMs,
    minSpeechMs: minSpeechMs ?? this.minSpeechMs,
    maxSpeechMs: maxSpeechMs ?? this.maxSpeechMs,
    channel: channel ?? this.channel,
    hotwords: hotwords ?? this.hotwords,
  );

  List<String> requiredModels(
    List<String> languages,
    String selectedLanguage, {
    int? textProcessingVersion,
    String recognitionEngine = '',
  }) {
    if (!enabled) return const [];
    selectedLanguage =
        localAsrAdapters[recognitionEngine]?.fixedLanguage ?? selectedLanguage;
    final supported = selectedLanguage == 'auto'
        ? languages
        : [selectedLanguage];
    final modern = usesAsrTextProcessing(textProcessingVersion);
    final qwen = modern && recognitionEngine == 'qwen3-asr';
    final japaneseKorean = supported.any((l) => l == 'ja' || l == 'ko');
    return [
      if (denoise) denoiserId,
      if (punctuation && supported.any((l) => l == 'zh' || l == 'en'))
        punctuationId,
      if (alignment && !qwen && supported.contains('zh')) alignmentChineseId,
      // New Qwen jobs use the existing lightweight English CTC aligner. Old
      // frozen jobs retain their Qwen-only dependencies and routing.
      if (alignment &&
          (!qwen || textProcessingVersion == 2) &&
          supported.contains('en'))
        alignmentEnglishId,
      if (alignment &&
          modern &&
          (recognitionEngine != 'parakeet-ja' || alwaysAlign) &&
          (qwen
              ? supported.any(qwenAlignmentLanguages.contains) &&
                    !(textProcessingVersion == 2 && selectedLanguage == 'en')
              : japaneseKorean))
        alignmentQwenId,
      // Bilingual/European ASR exports may omit a native language tag too.
      // Keep their existing zh/en alignment reachable without guessing script.
      if (modern && selectedLanguage == 'auto') languageId,
    ];
  }
}
