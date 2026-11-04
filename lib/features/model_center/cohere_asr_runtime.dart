import 'dart:typed_data';

import 'qwen_asr_runtime.dart';

const cohereAsrFile = 'cohere-transcribe-03-2026-Q8_0.gguf';
const cohereAsrLanguages = {
  'en',
  'fr',
  'de',
  'es',
  'it',
  'pt',
  'nl',
  'pl',
  'el',
  'ar',
  'ja',
  'zh',
  'vi',
  'ko',
};

int cohereAudioWorkingSetBytes(int weights) =>
    weights <= 0 ? 0 : weights + 1536 * 1024 * 1024;
int parakeetJapaneseWorkingSetBytes(int weights) =>
    weights <= 0 ? 0 : weights * 2 + 768 * 1024 * 1024;

/// Enforce the decoder limit even when the VAD emits an overlong speech range.
/// Prefer an actual low-energy pause near the limit; never drop audio samples.
List<({int start, int end})> splitCohereSpeechRanges(
  List<({int start, int end})> ranges,
  Float32List audio,
) {
  final result = <({int start, int end})>[];
  const maximum = 120000; // 7.5 s, leaving room for configured VAD padding.
  for (final range in ranges) {
    var start = range.start.clamp(0, audio.length);
    final end = range.end.clamp(start, audio.length);
    while (end - start > maximum) {
      var cut = start + maximum;
      var least = double.infinity;
      for (var at = cut - 16000; at + 320 <= start + maximum; at += 320) {
        var energy = 0.0;
        for (var j = at; j < at + 320; j++) {
          energy += audio[j] * audio[j];
        }
        if (energy < least) {
          least = energy;
          cut = at + 160;
        }
      }
      result.add((start: start, end: cut));
      start = cut;
    }
    if (end > start) result.add((start: start, end: end));
  }
  return result;
}

class CohereAsrDecoder {
  CohereAsrDecoder({
    required this.model,
    required this.identity,
    required this.threads,
    required this.onLoad,
    required this.onState,
    this.executable,
    this.runtimeDirectory,
    this.kind = 'cohere-asr',
    this.component = 'cohere_asr',
    this.label = 'Cohere',
    this.nativeTokenTiming = false,
  });
  final String model, identity;
  final String? executable, runtimeDirectory;
  final String kind, component, label;
  final bool nativeTokenTiming;
  final void Function() onLoad;
  final void Function(Map<String, dynamic>) onState;
  int threads;
  int _generation = 0;
  QwenAsrRuntime? _runtime;
  bool get hasLoadedModel => _runtime?.hasLoadedModel == true;

  Future<Map<String, dynamic>> decode(
    Float32List audio,
    void Function() check, {
    required String language,
  }) async {
    final generation = _generation;
    void valid() {
      check();
      if (generation != _generation) throw StateError('转录已取消');
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        valid();
        final runtime = _runtime ??= QwenAsrRuntime(
          executable: executable,
          runtimeDirectory: runtimeDirectory,
          component: component,
          label: label,
          maximumAudioSeconds: 9,
        );
        if (!runtime.hasLoadedModel) {
          onLoad();
          await runtime.load(kind: kind, model: model, threads: threads);
          valid();
          onState({
            'backend': runtime.backend,
            'reason': '$label 原生 Q8 音频识别',
            'weights': identity,
          });
        }
        final response = await runtime.audioRequest(
          'decode',
          audio,
          valid,
          fields: {'language': language},
        );
        final result = Map<String, dynamic>.from(response['result'] as Map);
        if (result['text'] is! String ||
            result['lang'] != language ||
            !(nativeTokenTiming
                    ? const {'token', 'segment'}
                    : const {'segment'})
                .contains(result['timingKind'])) {
          throw StateError('$label 返回的识别结果无效');
        }
        return {...result, '_backend': runtime.backend, '_weights': identity};
      } catch (error) {
        await _runtime?.close();
        _runtime = null;
        valid();
        if (attempt == 1 || !isQwenWorkerUnavailable(error, label: label)) {
          rethrow;
        }
      }
    }
    throw StateError('$label 音频推理失败');
  }

  Future<void> release() async {
    _generation++;
    final runtime = _runtime;
    _runtime = null;
    await runtime?.close();
  }

  Future<void> close() => release();
}
