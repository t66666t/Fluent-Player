import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import '../tool/local_asr_probe_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('ASR_ACCEL_NATIVE');
  const benchmark = bool.fromEnvironment('ASR_ACCEL_BENCHMARK');
  const benchmarkOnly = bool.fromEnvironment('ASR_ACCEL_BENCHMARK_ONLY');
  const onlyModel = String.fromEnvironment('ASR_ACCEL_MODEL');
  const unicodeModels = String.fromEnvironment('ASR_ACCEL_UNICODE_MODELS');
  const workerExecutable = String.fromEnvironment(
    'ASR_ACCEL_WORKER',
    defaultValue: 'native/asr/prebuilt/windows-x64/asr_worker.exe',
  );
  test(
    'real CPU/GPU models, child failure, cancellation and retained metadata',
    () async {
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
      final catalog = await loadModelCatalog();
      final root = Directory(p.absolute('.artifacts/asr-gpu/native-runtime'));
      await root.create(recursive: true);
      final records = <Map<String, dynamic>>[];
      for (final model in catalog.where(
        (m) =>
            m.purpose == ModelPurpose.transcription &&
            (onlyModel.isEmpty || m.id == onlyModel),
      )) {
        final cpuDirectory = model.engine == 'zipformer'
            ? p.absolute('.artifacts/asr-gpu/models/${model.id}')
            : p.absolute('.artifacts/model-center/native/${model.id}');
        final asset =
            model.languages.contains('en') && model.engine != 'zipformer'
            ? 'assets/models/asr/speech_probe.wav'
            : 'assets/models/asr/speech_probe_zh.wav';
        final source = await rootBundle.load(asset);
        final wave = File(p.join(root.path, '${model.id}.wav'));
        await wave.writeAsBytes(
          source.buffer.asUint8List(source.offsetInBytes, source.lengthInBytes),
        );
        final pack = catalog.singleWhere(
          (m) => m.id == asrAccelerationPackId(model.id),
        );
        final states = <Map<String, dynamic>>[];
        final runs = <Map<String, dynamic>>[];
        Future<(List<SubtitleItem>, int)> run(
          String mode, {
          bool measure = false,
          bool kill = false,
          bool hotwords = false,
          bool cancelDuringLoad = false,
        }) async {
          final worker = LocalAsrWorker(
            libraryDirectory:
                '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
          );
          var killed = false;
          final cancellation = Completer<void>();
          worker.configureAcceleration(
            {
              'mode': mode,
              'benchmark': measure,
              'modelId': model.id,
              'identity': model.identity,
              'durationSeconds': 600.0,
              'pipeline': true,
              'decoding': hotwords ? 'FLUENT PLAYER' : '',
              'gpuDirectory': p.absolute(
                unicodeModels.isEmpty
                    ? '.artifacts/asr-gpu/models/${pack.id}'
                    : p.join(unicodeModels, pack.id),
              ),
              'gpuIdentity': pack.identity,
              'workerExecutable': p.absolute(workerExecutable),
            },
            onState: (state) {
              states.add(state);
              if (cancelDuringLoad &&
                  !cancellation.isCompleted &&
                  '${state['reason']}'.startsWith('正在加载并验证')) {
                cancellation.complete();
              }
              if (kill &&
                  !killed &&
                  '${state['backend']}'.startsWith('GPU') &&
                  state['processId'] is int) {
                killed = Process.killPid(state['processId'] as int);
              }
            },
          );
          final watch = Stopwatch()..start();
          try {
            await worker.start(
              engine: model.engine,
              directory: cpuDirectory,
              vadPath: asrProbeVadPath(),
              language: 'auto',
              threads: 2,
              stage: LocalAsrStage.recognition,
              retainModels: true,
              runtimeDirectory: unicodeModels.isEmpty
                  ? root.path
                  : p.join(p.absolute(unicodeModels), '运行缓存'),
              enhancements: hotwords
                  ? const AsrEnhancementOptions(
                      denoise: false,
                      alignment: false,
                      punctuation: false,
                      trimSilence: false,
                      review: false,
                      hotwords: 'FLUENT PLAYER',
                    )
                  : AsrEnhancementOptions.disabled,
            );
            if (cancelDuringLoad) {
              await expectLater(
                worker.recognize(wave.path, cancelSignal: cancellation.future),
                throwsStateError,
              );
              expect(
                worker.modelLoads,
                0,
                reason: 'Cancellation must not start the CPU recognizer',
              );
              return (<SubtitleItem>[], watch.elapsedMilliseconds);
            }
            var output = await worker.recognize(wave.path, probe: measure);
            final cold = watch.elapsedMilliseconds;
            if (kill) {
              expect(output, isNotEmpty);
              if (model.engine == 'sensevoice') {
                expect(
                  output.any((c) => c.asrInfo.backend.startsWith('GPU')),
                  isTrue,
                );
                expect(output.any((c) => c.asrInfo.backend == 'CPU'), isTrue);
              }
              expect(output.map((c) => c.index).toSet().length, output.length);
              output = await worker.recognize(wave.path);
            } else if (!measure && !hotwords) {
              final stable = Stopwatch()..start();
              final repeated = await worker.recognize(wave.path);
              final repeatedJson = repeated
                  .map((c) => c.toTimingJson())
                  .toList();
              final originalJson = output.map((c) => c.toTimingJson()).toList();
              var maximumSpanDriftUs = 0;
              if (model.engine == 'parakeet' &&
                  mode == 'gpu' &&
                  repeated.every(
                    (c) => c.asrInfo.backend.toLowerCase().contains('directml'),
                  )) {
                // The shipped TDT encoder metadata has subsampling_factor=8
                // with a 10 ms feature hop. DirectML repeated FP32 duration
                // logits can select an adjacent frame. Check a strict one-frame
                // word boundary bound; text, sentence bounds and all other
                // metadata must still match exactly. Never alter app output.
                expect(repeatedJson, hasLength(originalJson.length));
                for (var i = 0; i < originalJson.length; i++) {
                  final expectedSpans =
                      (originalJson[i]['spans'] as List?) ?? [];
                  final actualSpans = (repeatedJson[i]['spans'] as List?) ?? [];
                  expect(actualSpans, hasLength(expectedSpans.length));
                  for (var j = 0; j < expectedSpans.length; j++) {
                    for (final key in ['startUs', 'endUs']) {
                      final expected = expectedSpans[j][key] as int;
                      final actual = actualSpans[j][key] as int;
                      final drift = (actual - expected).abs();
                      maximumSpanDriftUs = math.max(maximumSpanDriftUs, drift);
                      expect(
                        drift,
                        lessThanOrEqualTo(80000),
                        reason:
                            'Parakeet DirectML word boundary drift exceeds one encoder frame',
                      );
                      actualSpans[j][key] = expected;
                    }
                  }
                }
              }
              expect(
                repeatedJson,
                originalJson,
                reason:
                    '${model.id} $mode repeat must retain subtitle metadata',
              );
              runs.add({
                'mode': mode,
                'coldTotalMs': cold,
                'steadyTotalMs': stable.elapsedMilliseconds,
                'maximumWordBoundaryDriftUs': maximumSpanDriftUs,
              });
            }
            if (!measure) expect(output, isNotEmpty);
            if (kill) expect(killed, isTrue);
            return (output, cold);
          } finally {
            await worker.close();
          }
        }

        if (benchmarkOnly) {
          final measured = await run('auto', measure: true);
          records.add({
            'model': model.id,
            'elapsedMs': measured.$2,
            'states': states,
          });
          await wave.delete();
          await File(
            p.join(root.path, 'calibration.json'),
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(records));
          continue;
        }
        final cpu = await run('cpu');
        final gpu = await run('gpu');
        await File(p.join(root.path, '${model.id}-last.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'cpu': cpu.$1.map((c) => c.toTimingJson()).toList(),
            'gpu': gpu.$1.map((c) => c.toTimingJson()).toList(),
            'states': states,
          }),
        );
        expect(
          gpu.$1.every((c) => c.asrInfo.backend.startsWith('GPU')),
          isTrue,
          reason:
              '${model.id} must prove actual GPU execution, rather than silently passing on CPU',
        );
        final comparison =
            model.engine == 'zipformer' &&
                gpu.$1.every((c) => c.asrInfo.weights == pack.identity)
            ? await _zipformerFloatReference(
                wave,
                p.absolute('.artifacts/asr-gpu/models/${pack.id}'),
                gpu.$1,
              )
            : cpu.$1.map((c) => c.text).join(' ');
        expect(
          asrProbeAgrees(comparison, gpu.$1.map((c) => c.text).join(' ')),
          isTrue,
          reason:
              'GPU must agree with the corresponding floating export; INT8 quantization may change text',
        );
        if (model.engine == 'parakeet' ||
            model.engine == 'zipformer' ||
            model.engine == 'firered2') {
          expect(gpu.$1.any((c) => c.timedSpans.isNotEmpty), isTrue);
        }
        if (model.engine == 'sensevoice' ||
            model.engine == 'dolphin' ||
            model.engine == 'zipformer' ||
            model.engine == 'whisper' ||
            model.engine == 'firered2') {
          final fallback = await run('gpu', kill: true);
          expect(fallback.$1.any((c) => c.asrInfo.backend == 'CPU'), isTrue);
          expect(
            asrProbeAgrees(
              cpu.$1.map((c) => c.text).join(' '),
              fallback.$1.map((c) => c.text).join(' '),
            ),
            isTrue,
          );
        }
        if (model.engine == 'zipformer') {
          final hotwords = await run('gpu', hotwords: true);
          expect(
            hotwords.$1.every((c) => c.asrInfo.backend.startsWith('GPU')),
            isTrue,
          );
          expect(hotwords.$1.any((c) => c.timedSpans.isNotEmpty), isTrue);
        }
        if (model.engine == 'dolphin' ||
            model.engine == 'whisper' ||
            model.engine == 'firered2') {
          await run('gpu', cancelDuringLoad: true);
        }
        if (benchmark) await run('auto', measure: true);
        records.add({
          'model': model.id,
          'cpuTotalMs': cpu.$2,
          'gpuTotalMs': gpu.$2,
          'cpuText': cpu.$1.map((c) => c.text).join(' '),
          'gpuText': gpu.$1.map((c) => c.text).join(' '),
          'qualityReference': comparison,
          'runs': runs,
          'states': states,
          'cues': gpu.$1.map((c) => c.toTimingJson()).toList(),
        });
        await wave.delete();
        await File(
          p.join(root.path, 'verification.json'),
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(records));
      }
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

/// Compare the same export when the optional FP32 pack differs from INT8.
/// This also checks that streaming state/tail handling matches the CPU runtime.
Future<String> _zipformerFloatReference(
  File wave,
  String directory,
  List<SubtitleItem> cues,
) async {
  sherpa.initBindings(
    '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
  );
  final samples = decodeModelWave(await wave.readAsBytes());
  final recognizer = sherpa.OnlineRecognizer(
    sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        tokens: p.join(directory, 'tokens.txt'),
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: p.join(directory, 'encoder.onnx'),
          decoder: p.join(directory, 'decoder.onnx'),
          joiner: p.join(directory, 'joiner.onnx'),
        ),
        modelingUnit: 'cjkchar+bpe',
        bpeVocab: p.join(directory, 'bpe.vocab'),
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
      enableEndpoint: false,
    ),
  );
  final result = <String>[];
  try {
    for (final cue in cues) {
      final begin = cue.startTime.inMicroseconds * 16000 ~/ 1000000;
      final end = cue.endTime.inMicroseconds * 16000 ~/ 1000000;
      final stream = recognizer.createStream();
      void drain() {
        while (recognizer.isReady(stream)) {
          recognizer.decode(stream);
        }
      }

      try {
        for (var at = begin; at < end; at += 5120) {
          stream.acceptWaveform(
            samples: Float32List.fromList(
              samples.sublist(at, math.min(at + 5120, end)),
            ),
            sampleRate: 16000,
          );
          drain();
        }
        stream.acceptWaveform(samples: Float32List(4800), sampleRate: 16000);
        stream.inputFinished();
        drain();
        result.add(recognizer.getResult(stream).text);
      } finally {
        stream.free();
      }
    }
  } finally {
    recognizer.free();
  }
  return result.join(' ');
}
