import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/bounded_model_pipeline.dart';
import 'package:video_player_app/models/subtitle_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('ASR_WORKFLOW_NATIVE');
  const project = String.fromEnvironment('ASR_WORKFLOW_ROOT');
  final root = project.isEmpty ? Directory.current.path : project;
  const libraries =
      'C:/Users/11/AppData/Local/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows';
  test(
    'zero-copy native VAD preserves padded frame detection and resets between chunks',
    () async {
      DynamicLibrary.open(p.join(root, 'windows/runtime/onnxruntime.dll'));
      sherpa.initBindings(libraries);
      final vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: p.join(root, 'assets/models/asr/silero_vad.onnx'),
            minSilenceDuration: .35,
            minSpeechDuration: .18,
            maxSpeechDuration: 12,
          ),
          sampleRate: 16000,
          numThreads: 1,
        ),
        bufferSizeInSeconds: 60,
      );
      try {
        final samples = decodeModelWave(
          await File(
            p.join(root, 'assets/models/asr/speech_probe.wav'),
          ).readAsBytes(),
        );
        List<List<int>> detect(bool views) {
          vad.reset();
          final result = <List<int>>[];
          void drain() {
            while (!vad.isEmpty()) {
              final part = vad.front();
              result.add([part.start, part.samples.length]);
              vad.pop();
            }
          }

          for (var at = 0; at < samples.length; at += 512) {
            final length = (samples.length - at).clamp(0, 512);
            final block = views && length == 512
                ? Float32List.sublistView(samples, at, at + length)
                : (Float32List(512)..setRange(0, length, samples, at));
            vad.acceptWaveform(block);
            drain();
          }
          vad.flush();
          drain();
          return result;
        }

        final original = detect(false);
        expect(original, isNotEmpty);
        expect(detect(true), original);
        expect(detect(true), original);
      } finally {
        vad.free();
      }
    },
    skip: !enabled || !Platform.isWindows,
  );

  test(
    'all four ASR models retain quality with serial reuse and pipelining',
    () async {
      DynamicLibrary.open(p.join(root, 'windows/runtime/onnxruntime.dll'));
      final catalog = await loadModelCatalog();
      final records = <Map<String, Object>>[];
      for (final model in catalog.where(
        (m) => m.purpose == ModelPurpose.transcription,
      )) {
        final chinese = model.engine == 'zipformer';
        final language = chinese ? 'zh' : 'en';
        final wave = p.join(
          root,
          'assets/models/asr/${chinese ? 'speech_probe_zh.wav' : 'speech_probe.wav'}',
        );
        final directory = p.join(
          root,
          chinese
              ? '.artifacts/asr-gpu/models/${model.id}'
              : '.artifacts/model-center/native/${model.id}',
        );
        expect(await Directory(directory).exists(), isTrue, reason: model.id);
        final hashes = <String>[];
        for (final mode in [
          'release',
          'reuse',
          'pipeline',
          'denoise-pipeline',
          'adaptive-pipeline',
        ]) {
          final reuse = mode != 'release', pipeline = mode.endsWith('pipeline');
          final worker = LocalAsrWorker(libraryDirectory: libraries);
          LocalAsrWorker? post;
          final capturedAt = DateTime.now();
          final resources = mode == 'adaptive-pipeline'
              ? InferenceResourceSession(
                  InferenceResourceGovernor(
                    DeviceResourceSnapshot(
                      platform: 'windows',
                      processors: 8,
                      memoryBytes: 16 * 1073741824,
                      availableMemoryBytes: 10 * 1073741824,
                      capturedAt: capturedAt,
                    ),
                    now: () => capturedAt,
                  ),
                )
              : null;
          if (resources != null) {
            worker.configureResources(resources, modelBytes: model.bytes);
          }
          final watch = Stopwatch()..start();
          final output = <Object>[];
          final raw = <Object>[];
          final phases = <String>{};
          try {
            await worker.start(
              engine: model.engine,
              directory: directory,
              vadPath: p.join(root, 'assets/models/asr/silero_vad.onnx'),
              language: language,
              threads: 2,
              retainModels: reuse,
              stage: pipeline
                  ? LocalAsrStage.recognition
                  : LocalAsrStage.complete,
              enhancements: AsrEnhancementOptions.recommended,
              naturalPunctuationContext: true,
              enhancementDirectories: {
                for (final id
                    in AsrEnhancementOptions.recommended.requiredModels([
                      language,
                    ], language))
                  id: p.join(root, '.artifacts/model-center/enhancements/$id'),
              },
            );
            if (pipeline) {
              post = LocalAsrWorker(libraryDirectory: libraries);
              if (resources != null) post.configureResources(resources);
              await post.start(
                engine: model.engine,
                directory: directory,
                vadPath: p.join(root, 'assets/models/asr/silero_vad.onnx'),
                language: language,
                threads: 2,
                retainModels: true,
                stage: LocalAsrStage.enhancement,
                enhancements: AsrEnhancementOptions.recommended,
                naturalPunctuationContext: true,
                enhancementDirectories: {
                  for (final id
                      in AsrEnhancementOptions.recommended.requiredModels([
                        language,
                      ], language))
                    id: p.join(
                      root,
                      '.artifacts/model-center/enhancements/$id',
                    ),
                },
              );
              final side = ModelStageQueue();
              final prefetch =
                  mode == 'denoise-pipeline' || mode == 'adaptive-pipeline'
                  ? ModelStagePrefetcher<int, TransferableTypedData>(
                      inputs: [0, 1, 2, 3],
                      prepare: (id) => side.run(() async {
                        await post!.recognize(wave, prepareOnly: true);
                        return post.takePreparedAudio()!;
                      }),
                      dispose: (_) async {},
                    )
                  : null;
              try {
                final enhanced =
                    await runBoundedModelPipeline<
                      int,
                      ({List<SubtitleItem> cues, TransferableTypedData audio}),
                      List<SubtitleItem>
                    >(
                      inputs: [0, 1, 2, 3],
                      produce: (id) async {
                        final audio = await prefetch?.take(id);
                        final cues = await worker.recognize(
                          wave,
                          preparedAudio: audio,
                        );
                        raw.add(cues.map((c) => c.toTimingJson()).toList());
                        return (cues: cues, audio: worker.takePreparedAudio()!);
                      },
                      consume: (id, item) => side.run(
                        () => post!.recognize(
                          wave,
                          recognizedCues: item.cues,
                          preparedAudio: item.audio,
                          onPhase: (phase, value, message) {
                            phases.add(phase);
                          },
                        ),
                      ),
                      dispose: (_, _) async {},
                      abort: () {},
                    );
                output.addAll(
                  enhanced.map(
                    (cues) => cues.map((c) => c.toTimingJson()).toList(),
                  ),
                );
              } finally {
                await prefetch?.close();
                await side.drained;
              }
            } else {
              for (var i = 0; i < 4; i++) {
                final cues = await worker.recognize(
                  wave,
                  onRecognized: (cues) async {
                    raw.add(cues.map((c) => c.toTimingJson()).toList());
                  },
                  onPhase: (phase, value, message) {
                    phases.add(phase);
                  },
                );
                expect(cues, isNotEmpty, reason: model.id);
                output.add(cues.map((c) => c.toTimingJson()).toList());
              }
            }
            final hash = sha256
                .convert(utf8.encode(jsonEncode([raw, output])))
                .toString();
            hashes.add(hash);
            records.add({
              'model': model.id,
              'reuseModels': reuse,
              'mode': mode,
              'pieces': 4,
              'elapsedMs': watch.elapsedMilliseconds,
              'primaryLoads': worker.modelLoads,
              'outputHash': hash,
              'phases': phases.toList(),
            });
            // ignore: avoid_print
            print(
              '${model.id} $mode: ${watch.elapsedMilliseconds} ms, ${worker.modelLoads} primary loads',
            );
          } finally {
            await post?.close();
            await worker.close();
            if (resources != null) {
              expect(resources.activeThreads, 0);
              await resources.close();
            }
          }
        }
        expect(
          hashes[1],
          hashes[0],
          reason:
              '${model.id}: text, timing and metadata must remain identical',
        );
        expect(
          hashes[2],
          hashes[0],
          reason: '${model.id}: pipelined output must remain identical',
        );
        expect(
          hashes[4],
          hashes[0],
          reason:
              '${model.id}: adaptive budgets must preserve the complete result',
        );
        expect(
          hashes[3],
          hashes[0],
          reason:
              '${model.id}: independent denoising must preserve all samples and subtitle metadata',
        );
      }
      final report = File(
        p.join(root, '.artifacts/model-center/asr-adaptive-all-models.json'),
      );
      await report.writeAsString(
        const JsonEncoder.withIndent('  ').convert(records),
      );
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 15)),
  );
  test(
    'CPU tuning probes restore the owner and never replace production cues',
    () async {
      DynamicLibrary.open(p.join(root, 'windows/runtime/onnxruntime.dll'));
      final capturedAt = DateTime.now();
      final resources = InferenceResourceSession(
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: 'windows',
            processors: 8,
            memoryBytes: 16 * 1073741824,
            availableMemoryBytes: 10 * 1073741824,
            capturedAt: capturedAt,
          ),
          now: () => capturedAt,
        ),
      );
      resources.asrMaximum = 2;
      final worker = LocalAsrWorker(libraryDirectory: libraries)
        ..configureResources(resources);
      final wave = p.join(root, 'assets/models/asr/speech_probe.wav');
      try {
        await worker.start(
          engine: 'parakeet',
          directory: p.join(
            root,
            '.artifacts/model-center/native/parakeet-v3-int8',
          ),
          vadPath: p.join(root, 'assets/models/asr/silero_vad.onnx'),
          language: 'en',
          threads: 2,
          retainModels: true,
        );
        final original = await worker.recognize(wave);
        for (var i = 0; i < 2; i++) {
          final result = await worker.probeCpu(4);
          expect(result.valid, isTrue);
          expect(result.costMs, greaterThan(0));
          expect(resources.activeThreads, 0);
        }
        final after = await worker.recognize(wave);
        expect(
          after.map((c) => c.toTimingJson()).toList(),
          original.map((c) => c.toTimingJson()).toList(),
        );
        await worker.releaseIdle();
        final afterTrim = await worker.recognize(wave);
        expect(
          afterTrim.map((c) => c.toTimingJson()).toList(),
          original.map((c) => c.toTimingJson()).toList(),
        );
      } finally {
        await worker.close();
        await resources.close();
      }
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
