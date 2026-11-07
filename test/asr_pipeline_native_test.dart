import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/bounded_model_pipeline.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import '../tool/local_asr_probe_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('ASR_PIPELINE_NATIVE');
  const mode = String.fromEnvironment(
    'ASR_BENCHMARK_MODE',
    defaultValue: 'pipeline-auto',
  );
  test(
    'real bounded ASR pipeline throughput, resource reuse and cancellation',
    () async {
      final pipelined = mode.startsWith('pipeline');
      final gpu = mode == 'pipeline-gpu';
      final options = AsrEnhancementOptions(alwaysAlign: mode.endsWith('full'));
      final workers = <LocalAsrWorker>[];
      final phases = <String>{};
      var rss = ProcessInfo.currentRss;
      final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (ProcessInfo.currentRss > rss) rss = ProcessInfo.currentRss;
      });
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
      OrtEnv.instance.init();
      final providers = OrtEnv.instance.availableProviders();
      Future<LocalAsrWorker> start(LocalAsrStage stage) async {
        final worker = LocalAsrWorker();
        workers.add(worker);
        if (gpu && stage != LocalAsrStage.enhancement) {
          worker.configureAcceleration({
            'mode': 'gpu',
            'modelId': 'parakeet-v3-int8',
            'identity':
                'parakeet-v3-int8@2bda32ec70b097a55adaa07d9a7173915b43cc78',
            'gpuDirectory': p.absolute(
              '.artifacts/asr-gpu/models/parakeet-v3-int8-gpu',
            ),
            'gpuIdentity':
                'parakeet-v3-int8-gpu@1a468a35cbba69418f126de829e75261dea4a4e4',
            'workerExecutable': p.absolute(
              'native/asr/prebuilt/windows-x64/asr_worker.exe',
            ),
            'durationSeconds': 600.0,
            'pipeline': true,
          });
        }
        await worker.start(
          engine: 'parakeet',
          directory: p.absolute(
            '.artifacts/model-center/native/parakeet-v3-int8',
          ),
          vadPath: asrProbeVadPath(),
          language: 'en',
          threads: 2,
          libraryDirectory:
              '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
          enhancements: options,
          naturalPunctuationContext: true,
          stage: stage,
          retainModels: pipelined,
          enhancementDirectories: {
            for (final id in options.requiredModels(['en'], 'en'))
              id: p.absolute('.artifacts/model-center/enhancements/$id'),
          },
          runtimeDirectory: p.absolute('.artifacts/model-center'),
        );
        return worker;
      }

      final input = p.absolute('assets/models/asr/speech_probe.wav');
      final watch = Stopwatch()..start();
      final timings = <Map<String, Object>>[];
      final raw = <List<SubtitleItem>>[];
      try {
        final first = await start(
          pipelined ? LocalAsrStage.recognition : LocalAsrStage.complete,
        );
        final second = pipelined
            ? await start(LocalAsrStage.enhancement)
            : null;
        void phase(String name, double _, String message) {
          phases.add(name);
        }

        final List<List<SubtitleItem>> output;
        if (second == null) {
          output = [];
          for (var i = 0; i < 4; i++) {
            output.add(
              await first.recognize(
                input,
                onRecognized: (cues) async {
                  raw.add(cues);
                },
                onPhase: phase,
              ),
            );
            timings.add({'piece': i, 'finishedMs': watch.elapsedMilliseconds});
          }
        } else {
          output =
              await runBoundedModelPipeline<
                int,
                ({List<SubtitleItem> cues, TransferableTypedData audio}),
                List<SubtitleItem>
              >(
                inputs: [0, 1, 2, 3],
                produce: (i) async {
                  final cues = await first.recognize(input, onPhase: phase);
                  raw.add(cues);
                  return (cues: cues, audio: first.takePreparedAudio()!);
                },
                consume: (i, prepared) async {
                  final cues = await second.recognize(
                    input,
                    recognizedCues: prepared.cues,
                    preparedAudio: prepared.audio,
                    onPhase: phase,
                  );
                  timings.add({
                    'piece': i,
                    'finishedMs': watch.elapsedMilliseconds,
                  });
                  return cues;
                },
                dispose: (_, _) async {},
                abort: () {},
              );
        }
        watch.stop();
        final before = raw.first.map((c) => c.toTimingJson()).toList();
        final after = output.first.map((c) => c.toTimingJson()).toList();
        await File(
          '.artifacts/asr-gpu/pipeline-$mode-detail.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'raw': raw
                .map((cues) => cues.map((c) => c.toTimingJson()).toList())
                .toList(),
            'enhanced': output
                .map((cues) => cues.map((c) => c.toTimingJson()).toList())
                .toList(),
          }),
        );
        for (var i = 1; i < 4; i++) {
          if (gpu) {
            _expectEquivalentGpuCues(raw.first, raw[i]);
            _expectEquivalentGpuCues(output.first, output[i]);
          } else {
            expect(raw[i].map((c) => c.toTimingJson()).toList(), before);
            expect(output[i].map((c) => c.toTimingJson()).toList(), after);
          }
        }
        final captions = segmentAsrSubtitles(
          output.first,
          SubtitleSegmentationOptions.natural,
        );
        expect(captions, hasLength(3));
        expect(
          output.first
              .map((c) => c.text)
              .join(' ')
              .replaceAll(RegExp(r'[\p{P}\s]', unicode: true), '')
              .toLowerCase(),
          raw.first
              .map((c) => c.text)
              .join(' ')
              .replaceAll(RegExp(r'[\p{P}\s]', unicode: true), '')
              .toLowerCase(),
        );
        if (pipelined) expect(first.modelLoads, gpu ? 0 : 1);
        if (gpu) {
          expect(
            raw
                .expand((cues) => cues)
                .every((c) => c.asrInfo.backend.startsWith('GPU')),
            isTrue,
          );
        }
        await File(
          '.artifacts/model-center/asr-throughput-$mode.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'mode': mode,
            'elapsedMs': watch.elapsedMilliseconds,
            'pieces': 4,
            'sampledPeakRssBytes': rss,
            'asrModelLoads': first.modelLoads,
            'timings': timings,
            'phases': phases.toList(),
            'rawHash': sha256
                .convert(utf8.encode(jsonEncode(before)))
                .toString(),
            'outputHash': sha256
                .convert(utf8.encode(jsonEncode(after)))
                .toString(),
            'captions': captions.map((c) => c.toTimingJson()).toList(),
          }),
        );
        if (second != null && !gpu) {
          final cancel = Completer<void>();
          await expectLater(
            first.recognize(
              input,
              cancelSignal: cancel.future,
              onPhase: (_, _, _) {
                if (!cancel.isCompleted) cancel.complete();
              },
            ),
            throwsStateError,
          );
          final recovered = await first.recognize(input);
          expect(recovered, isNotEmpty);
        }
      } finally {
        timer.cancel();
        for (final worker in workers.reversed) {
          await worker.close();
        }
        expect(OrtEnv.instance.availableProviders(), providers);
        OrtEnv.instance.release();
      }
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

void _expectEquivalentGpuCues(
  List<SubtitleItem> reference,
  List<SubtitleItem> actual,
) {
  String canonical(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
  expect(
    actual.map((c) => canonical(c.text)),
    reference.map((c) => canonical(c.text)),
  );
  expect(actual.length, reference.length);
  for (var i = 0; i < actual.length; i++) {
    final cue = actual[i], before = reference[i];
    expect(cue.startTime, before.startTime);
    expect(cue.endTime, before.endTime);
    expect(cue.asrInfo.backend, before.asrInfo.backend);
    expect(cue.asrInfo.weights, before.asrInfo.weights);
    var previousStart = cue.startTime.inMicroseconds;
    for (final span in cue.timedSpans) {
      expect(
        span.startTime.inMicroseconds,
        inInclusiveRange(previousStart, cue.endTime.inMicroseconds),
      );
      expect(
        span.endTime.inMicroseconds,
        inInclusiveRange(
          span.startTime.inMicroseconds,
          cue.endTime.inMicroseconds,
        ),
      );
      expect(span.textStart, inInclusiveRange(0, cue.text.length));
      expect(span.textEnd, inInclusiveRange(span.textStart, cue.text.length));
      previousStart = span.startTime.inMicroseconds;
      final same = before.timedSpans
          .where(
            (v) => v.textStart == span.textStart && v.textEnd == span.textEnd,
          )
          .firstOrNull;
      if (same != null) {
        // TDT emits in 80 ms frames. Parallel GPU reductions can shift an
        // emission by a frame or change BPE casing without changing the words.
        expect(
          (span.startTime - same.startTime).inMicroseconds.abs(),
          lessThanOrEqualTo(160000),
        );
        expect(
          (span.endTime - same.endTime).inMicroseconds.abs(),
          lessThanOrEqualTo(160000),
        );
      }
    }
  }
}
