// Invoked by test/model_runtime_native_test.dart under the Flutter runtime.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'local_asr_probe_assets.dart';

Future<Map<String, Object?>> runModelRuntimeProbe(
  List<String> args, {
  bool includeTranslation = true,
}) async {
  if (args.length < 4) {
    throw ArgumentError('modelRoot sherpaDll onnxruntimeDll [speech.wav]');
  }
  final result = <String, Object?>{};
  DynamicLibrary.open(p.absolute(args[2]));
  OrtEnv.instance.init();
  result['onnxruntime'] = OrtEnv.version;
  result['ocrProviders'] = OrtEnv.instance
      .availableProviders()
      .map((e) => e.name)
      .toList();
  final watch = Stopwatch()..start();
  final asr = <String, Object?>{};
  for (final entry in const {
    'sensevoice-small-int8': 'sensevoice',
    'dolphin-base-int8': 'dolphin',
    'parakeet-v3-int8': 'parakeet',
  }.entries) {
    final folder = p.join(p.absolute(args[0]), entry.key);
    if (!Directory(folder).existsSync()) continue;
    watch.reset();
    final worker = LocalAsrWorker();
    try {
      await worker.start(
        engine: entry.value,
        directory: folder,
        vadPath: asrProbeVadPath(modelRoot: args[0]),
        language: 'auto',
        threads: 2,
        libraryDirectory: p.dirname(p.absolute(args[1])),
      );
      final sample = entry.value == 'dolphin'
          ? p.absolute('assets/models/asr/speech_probe_zh.wav')
          : p.absolute(args[3]);
      final cues = await worker.recognize(sample);
      if (cues.isEmpty || cues.any((c) => c.endTime <= c.startTime)) {
        throw StateError('${entry.key}: no valid timed speech');
      }
      final segmented = await segmentAsrSubtitlesAsync(
        cues,
        SubtitleSegmentationOptions.short,
      );
      String plain(String value) => value.replaceAll(RegExp(r'\s+'), '');
      if (plain(segmented.map((c) => c.text).join()) !=
          plain(cues.map((c) => c.text).join())) {
        throw StateError('${entry.key}: regrouping changed recognized text');
      }
      asr[entry.key] = {
        'text': cues.map((c) => c.text).join(' '),
        'cues': cues.length,
        'segmentedCues': segmented.length,
        'segmentedPreview': segmented.map((c) => c.toTimingJson()).toList(),
        'timedTokens': cues.fold<int>(
          0,
          (total, cue) => total + cue.timedSpans.length,
        ),
        'loadAndInferMs': watch.elapsedMilliseconds,
      };
      if (entry.value == 'dolphin' &&
          !cues.any((c) => c.text.contains('测试语音'))) {
        throw StateError(
          'Dolphin did not recognize the Chinese sample: ${cues.map((c) => c.text).join(' ')}',
        );
      }
      if (entry.value == 'sensevoice') {
        result['asrText'] = cues.map((c) => c.text).join(' ');
        final cancelled = Completer<void>();
        var stopped = false;
        try {
          await worker.recognize(
            p.absolute(args[3]),
            cancelSignal: cancelled.future,
            onProgress: (_) {
              if (!cancelled.isCompleted) cancelled.complete();
            },
          );
        } on StateError {
          stopped = true;
        }
        if (!stopped) throw StateError('ASR cancellation was not observed');
        result['asrCancellation'] = true;
      }
    } finally {
      await worker.close();
    }
  }
  result['asr'] = asr;
  // Confirm the OCR environment remains usable after the ASR library loaded.
  result['ocrProvidersAfterAsr'] = OrtEnv.instance
      .availableProviders()
      .map((e) => e.name)
      .toList();
  final translations = <String, Object?>{};
  if (includeTranslation) {
    await LlamaLogging.configure(level: LlamaLogLevel.warn);
  }
  final translationModels = includeTranslation
      ? const {
          'hy-mt2-1.8b-q4': 'Hy-MT2-1.8B-Q4_K_M.gguf',
          'qwen3-4b-q4': 'Qwen3-4B-Q4_K_M.gguf',
        }
      : const <String, String>{};
  for (final entry in translationModels.entries) {
    final path = p.join(p.absolute(args[0]), entry.key, entry.value);
    if (!File(path).existsSync()) continue;
    watch.reset();
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(path)),
      params: const ModelParams(
        device: ComputeDevice.cpu,
        contextSize: 2048,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
        batchSize: 128,
        microBatchSize: 64,
      ),
    );
    try {
      final buffer = StringBuffer();
      await for (final chunk in engine.create(
        const [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: '将以下文本翻译成简体中文，只输出译文：Hello, welcome.',
          ),
        ],
        params: const GenerationParams(maxTokens: 128, temp: 0.2),
        enableThinking: false,
      )) {
        for (final choice in chunk.choices) {
          buffer.write(choice.delta.content ?? '');
        }
      }
      final text = buffer.toString().trim();
      if (!RegExp(r'[\u4e00-\u9fff]').hasMatch(text)) {
        throw StateError('Translation probe did not return Chinese: $text');
      }
      if (entry.key == 'hy-mt2-1.8b-q4') {
        result['translation'] = text;
      }
      translations[entry.key] = {
        'text': text,
        'loadAndInferMs': watch.elapsedMilliseconds,
      };
    } finally {
      await engine.dispose();
    }
  }
  result['translations'] = translations;
  result['peakRssBytes'] = ProcessInfo.maxRss;
  OrtEnv.instance.release();
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  return result;
}
