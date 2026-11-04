import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
// Inspect the pinned C API's TDT durations, omitted from its public wrapper.
// ignore: implementation_imports
import 'package:sherpa_onnx/src/sherpa_onnx_bindings.dart' as bindings;

import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/model_token_timing.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import '../tool/local_asr_probe_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PARAKEET_NATIVE');
  test(
    'real Parakeet TDT durations retain every English word for regrouping',
    () async {
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
      OrtEnv.instance.init();
      sherpa.initBindings(
        '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
      );
      final folder = p.absolute(
        '.artifacts/model-center/native/parakeet-v3-int8',
      );
      final model = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            tokens: p.join(folder, 'tokens.txt'),
            numThreads: 2,
            debug: false,
            provider: 'cpu',
            modelType: 'nemo_transducer',
            transducer: sherpa.OfflineTransducerModelConfig(
              encoder: p.join(folder, 'encoder.int8.onnx'),
              decoder: p.join(folder, 'decoder.int8.onnx'),
              joiner: p.join(folder, 'joiner.int8.onnx'),
            ),
          ),
        ),
      );
      final stream = model.createStream();
      try {
        final samples = decodeModelWave(
          await File('assets/models/asr/speech_probe.wav').readAsBytes(),
        );
        stream.acceptWaveform(samples: samples, sampleRate: 16000);
        model.decode(stream);
        final ptr = bindings.SherpaOnnxBindings.getOfflineStreamResultAsJson!
            .call(stream.ptr);
        Map<String, dynamic> raw;
        try {
          raw = Map<String, dynamic>.from(
            jsonDecode(ptr.cast<Utf8>().toDartString()) as Map,
          );
        } finally {
          bindings.SherpaOnnxBindings.destroyOfflineStreamResultJson!.call(ptr);
        }
        final starts = (raw['timestamps'] as List)
            .map((e) => (e as num).toDouble())
            .toList();
        final durations = (raw['durations'] as List? ?? const [])
            .map((e) => (e as num).toDouble())
            .toList();
        final text = raw['text'] as String;
        final cue = SubtitleItem(
          index: 1,
          startTime: Duration.zero,
          endTime: Duration(
            microseconds: (samples.length / 16000 * 1000000).round(),
          ),
          text: text,
          timedSpans: alignModelTokens(
            text: text,
            tokens: List<String>.from(raw['tokens'] as List),
            starts: starts,
            ends: durations.isEmpty
                ? null
                : [
                    for (var i = 0; i < starts.length; i++)
                      starts[i] + durations[i],
                  ],
            cueEnd: samples.length / 16000,
          ),
        );
        final segmented = segmentAsrSubtitles([
          cue,
        ], SubtitleSegmentationOptions.natural);
        final data = {
          'raw': raw,
          'zeroDurations': durations.where((d) => d == 0).length,
          'nativeCue': cue.toTimingJson(),
          'segmented': segmented.map((c) => c.toTimingJson()).toList(),
        };
        await File(
          '.artifacts/model-center/parakeet-segmentation-native.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
        expect(durations.where((d) => d == 0), isNotEmpty);
        expect(cue.timedSpans.length, (raw['tokens'] as List).length);
        expect(segmented.map((c) => c.text), [
          'And so, my fellow Americans,',
          'ask not what your country can do for you.',
          'Ask what you can do for your country.',
        ]);
        expect(
          segmented.map((c) => c.text).join(' ').replaceAll(RegExp(r'\s+'), ''),
          text.replaceAll(RegExp(r'\s+'), ''),
        );
      } finally {
        stream.free();
        model.free();
        OrtEnv.instance.release();
      }
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'default Parakeet enhancements and VAD produce readable natural captions',
    () async {
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
      final worker = LocalAsrWorker();
      final watch = Stopwatch()..start();
      final phases = <String>{};
      var raw = <SubtitleItem>[];
      try {
        await worker.start(
          engine: 'parakeet',
          directory: p.absolute(
            '.artifacts/model-center/native/parakeet-v3-int8',
          ),
          vadPath: asrProbeVadPath(),
          language: 'auto',
          threads: 2,
          libraryDirectory:
              '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
          enhancements: const AsrEnhancementOptions(),
          naturalPunctuationContext: true,
          enhancementDirectories: {
            for (final id in const AsrEnhancementOptions().requiredModels([
              'en',
            ], 'auto'))
              id: p.absolute('.artifacts/model-center/enhancements/$id'),
          },
          runtimeDirectory: p.absolute('.artifacts/model-center'),
        );
        final enhanced = await worker.recognize(
          p.absolute('assets/models/asr/speech_probe.wav'),
          onRecognized: (cues) async {
            raw = cues;
          },
          onPhase: (phase, _, _) {
            phases.add(phase);
          },
        );
        final segmented = segmentAsrSubtitles(
          enhanced,
          SubtitleSegmentationOptions.natural,
        );
        watch.stop();
        await File(
          '.artifacts/model-center/parakeet-default-pipeline-native.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'elapsedMs': watch.elapsedMilliseconds,
            'phases': phases.toList(),
            'raw': raw.map((c) => c.toTimingJson()).toList(),
            'enhanced': enhanced.map((c) => c.toTimingJson()).toList(),
            'segmented': segmented.map((c) => c.toTimingJson()).toList(),
          }),
        );
        expect(raw, isNotEmpty);
        expect(phases, containsAll(['denoising', 'refining']));
        expect(phases, isNot(contains('aligning')));
        expect(raw.every(hasUsableAsrTiming), isTrue);
        expect(phases, isNot(contains('diarizing')));
        expect(segmented.length, greaterThan(1));
        expect(
          segmented.every(
            (c) => c.endTime - c.startTime >= const Duration(milliseconds: 800),
          ),
          isTrue,
        );
        expect(
          segmented.every(
            (c) =>
                c.endTime - c.startTime <= const Duration(milliseconds: 7200),
          ),
          isTrue,
        );
        expect(segmented.every((c) => c.asrInfo.speaker.isEmpty), isTrue);
        String lexical(List<SubtitleItem> cues) => cues
            .map((c) => c.text)
            .join(' ')
            .replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '')
            .toLowerCase();
        expect(lexical(segmented), lexical(raw));
      } finally {
        await worker.close();
      }
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
