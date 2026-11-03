import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/services/app_storage_service.dart';

const _ids = ['whisper-large-v3-turbo-int8', 'firered-asr2-ctc-int8'];
const _root = String.fromEnvironment(
  'MODEL_INTEGRATION_MODEL_ROOT',
  defaultValue: '.artifacts/model-center/native',
);
const _samples = String.fromEnvironment('NEW_ASR_SAMPLES');
const _enabled = bool.fromEnvironment('NEW_ASR_NATIVE');
const _gpu = bool.fromEnvironment('NEW_ASR_GPU');
const _workerPath = 'native/asr/prebuilt/windows-x64/asr_worker.exe';

class _Center extends ModelCenterService {
  _Center({required super.storage});
  @override
  Future<void> initialize() async {}
  @override
  bool installed(String id) {
    final model = artifact(id);
    if (model == null) return false;
    final directory = switch (model.purpose) {
      ModelPurpose.enhancement => p.absolute(
        '.artifacts/model-center/enhancements',
        id,
      ),
      ModelPurpose.acceleration => p.absolute('.artifacts/asr-gpu/models', id),
      _ => p.absolute(_root, id),
    };
    return model.files.every((entry) {
      final file = File(p.join(directory, entry.name));
      return file.existsSync() && file.lengthSync() == entry.bytes;
    });
  }

  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) => action(artifact(id)!, Directory(p.absolute(_root, id)));
  @override
  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => action(
    artifact(spec.profile.model)!,
    Directory(p.absolute(_root, spec.profile.model)),
    {
      for (final id in spec.enhancementModels.keys)
        id: p.absolute('.artifacts/model-center/enhancements', id),
      for (final id in spec.asrAccelerationModels.keys)
        id: p.absolute('.artifacts/asr-gpu/models', id),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{};
  late String libraries;
  LocalAsrWorker worker() => LocalAsrWorker(
    libraryDirectory: libraries,
    nativeWorkerExecutable: p.absolute(_workerPath),
  );
  setUpAll(() async {
    if (!_enabled || !Platform.isWindows) return;
    DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
    final config =
        jsonDecode(await File('.dart_tool/package_config.json').readAsString())
            as Map;
    final package = (config['packages'] as List).cast<Map>().singleWhere(
      (m) => m['name'] == 'sherpa_onnx_windows',
    );
    libraries = p.join(
      File(
        '.dart_tool/package_config.json',
      ).absolute.uri.resolve(package['rootUri'] as String).toFilePath(),
      'windows',
    );
  });
  tearDownAll(() async {
    if (!_enabled || !Platform.isWindows) return;
    final target = File(
      const String.fromEnvironment(
        'NEW_ASR_REPORT',
        defaultValue: '.artifacts/model-integration/new-asr-native.json',
      ),
    );
    await target.parent.create(recursive: true);
    await target.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  });

  test(
    'native CPU cancellation releases files and a fresh owner can recognize',
    () async {
      for (final id in _ids) {
        final model = (await loadModelCatalog(
          includeRetired: true,
        )).singleWhere((m) => m.id == id);
        final directory = await Directory.systemTemp.createTemp(
          'new-asr-cpu-cancel-',
        );
        final cancellation = Completer<void>();
        Future<void> start(LocalAsrWorker recognizer) => recognizer.start(
          engine: model.engine,
          directory: p.absolute(_root, id),
          vadPath: p.absolute('assets/models/asr/silero_vad.onnx'),
          language: 'en',
          threads: 4,
          runtimeDirectory: directory.path,
          enhancements: AsrEnhancementOptions.disabled,
        );
        final first = worker();
        try {
          await start(first);
          await expectLater(
            first.recognize(
              p.absolute('assets/models/asr/speech_probe.wav'),
              cancelSignal: cancellation.future,
              onPhase: (phase, _, _) {
                if (phase == 'loading' && !cancellation.isCompleted) {
                  cancellation.complete();
                }
              },
            ),
            throwsStateError,
          );
          expect(cancellation.isCompleted, isTrue);
        } finally {
          await first.close();
        }
        expect(await directory.list().toList(), isEmpty);
        final next = worker();
        try {
          await start(next);
          final cues = await next.recognize(
            p.absolute('assets/models/asr/speech_probe.wav'),
          );
          expect(cues, isNotEmpty);
          report['nativeCpuCancellation:$id'] = {
            'reloaded': true,
            'cues': cues.map((c) => c.toTimingJson()).toList(),
          };
        } finally {
          await next.close();
          expect(await directory.list().toList(), isEmpty);
          await directory.delete();
        }
      }
    },
    skip: !_enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'new models recognize representative languages with repeatable cue timing',
    () async {
      for (final model in (await loadModelCatalog(
        includeRetired: true,
      )).where((m) => _ids.contains(m.id))) {
        for (final language in [
          'zh',
          'en',
          if (_samples.isNotEmpty && model.engine == 'whisper') ...[
            'ja',
            'ko',
            'yue',
          ],
        ]) {
          final recognizer = worker();
          try {
            final source = _samples.isEmpty
                ? p.absolute(
                    'assets/models/asr/speech_probe${language == 'zh' ? '_zh' : ''}.wav',
                  )
                : p.absolute(_samples, '$language.wav');
            await recognizer.start(
              engine: model.engine,
              directory: p.absolute(_root, model.id),
              vadPath: p.absolute('assets/models/asr/silero_vad.onnx'),
              language: language,
              threads: 4,
              retainModels: true,
              enhancements: AsrEnhancementOptions.disabled,
            );
            final watch = Stopwatch()..start();
            final cues = await recognizer.recognize(source);
            final coldMs = watch.elapsedMilliseconds;
            expect(cues, isNotEmpty, reason: '${model.id}:$language');
            final pattern = switch (language) {
              'ja' => RegExp(r'[\u3040-\u30ff]'),
              'ko' => RegExp(r'[\uac00-\ud7af]'),
              'zh' || 'yue' => RegExp(r'[\u4e00-\u9fff]'),
              _ => RegExp('[A-Za-z]'),
            };
            expect(pattern.hasMatch(cues.map((c) => c.text).join()), isTrue);
            expect(cues.every((c) => c.endTime > c.startTime), isTrue);
            watch.reset();
            final repeat = await recognizer.recognize(source);
            expect(
              repeat.map((c) => c.toTimingJson()).toList(),
              cues.map((c) => c.toTimingJson()).toList(),
            );
            report['language:${model.id}:$language'] = {
              'coldMs': coldMs,
              'steadyMs': watch.elapsedMilliseconds,
              'cues': cues.map((c) => c.toTimingJson()).toList(),
            };
          } finally {
            await recognizer.close();
          }
        }
      }
    },
    skip: !_enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'new models reuse production enhancement, pipeline, both GGUF translators and completed checkpoints',
    () async {
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp('new-asr-workflows-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(temp.path, 'support')),
          documents: Directory(p.join(temp.path, 'documents')),
          defaultData: Directory(p.join(temp.path, 'data')),
          executable: Directory(p.join(temp.path, 'executable')),
        ),
      );
      await storage.initialize();
      final center = _Center(storage: storage)
        ..catalog = await loadModelCatalog(includeRetired: true);
      final source = p.absolute('assets/models/asr/speech_probe.wav');
      final duration = Duration(
        microseconds:
            decodeModelWave(await File(source).readAsBytes()).length *
            1000000 ~/
            16000,
      );
      try {
        for (final id in _ids) {
          final model = center.artifact(id)!;
          for (final mode in [
            AsrExecutionMode.lowMemory,
            AsrExecutionMode.pipeline,
          ]) {
            for (final translation in center.catalog.where(
              (m) => m.purpose == ModelPurpose.translation,
            )) {
              final key = '$id:${mode.name}:${translation.id}';
              final options = AsrEnhancementOptions.recommended;
              final pack = center.artifact('$id-gpu')!;
              final spec = ModelJobSpec(
                profile: ModelServiceProfile(
                  id: 'local:$id',
                  name: model.name,
                  kind: TranscriptionServiceKind.local,
                  model: id,
                  language: 'en',
                ),
                artifactIdentity: model.identity,
                threads: 4,
                asrTokenTiming: asrTokenTimingOverride(id, model.engine),
                asrExecution: mode,
                asrEnhancements: options,
                enhancementModels: {
                  for (final component in options.requiredModels(
                    model.languages,
                    'en',
                  ))
                    component: center.artifact(component)!.identity,
                },
                asrAcceleration: _gpu
                    ? AsrAcceleration.gpu
                    : AsrAcceleration.cpu,
                asrAccelerationModels: {if (_gpu) pack.id: pack.identity},
              );
              final translationSpec = ModelJobSpec(
                profile: ModelServiceProfile(
                  id: translation.id,
                  name: translation.name,
                  kind: TranscriptionServiceKind.local,
                  model: translation.id,
                ),
                artifactIdentity: translation.identity,
                translation: const LocalTranslationOptions(
                  acceleration: TranslationAcceleration.cpu,
                  threads: 4,
                  batchSize: 4,
                ),
              );
              var preparations = 0, inferences = 0;
              final translator = LocalSubtitleTranslator(center: center);
              final runner = ModelTranscriptionRunner(
                center: center,
                createLocalWorker: worker,
                loadDeviceInfo: () async => const ModelDeviceInfo(
                  memoryBytes: 32 * 1073741824,
                  availableMemoryBytes: 16 * 1073741824,
                  processors: 16,
                ),
              );
              final outputs = <String>[];
              final modes = <String>{};
              Future<List<Map<String, dynamic>>> run() async =>
                  (await runner.run(
                    spec: spec,
                    sourceIdentity: 'new-native-$key',
                    duration: duration,
                    serializeConsumer: true,
                    consumerModelBytes: translation.bytes,
                    onProgress: (progress) {
                      if (progress.local != null) {
                        modes.add(
                          progress.local!.pipeline ? 'pipeline' : 'lowMemory',
                        );
                      }
                    },
                    prepareAudio: (_, _, _, _) async {
                      preparations++;
                      return (await File(source).copy(
                        p.join(temp.path, 'sample-$preparations.wav'),
                      )).path;
                    },
                    onStableBatch: (batch) async {
                      outputs.addAll(
                        await translator.translate(
                          texts: batch.cues.map((c) => c.text).toList(),
                          sourceLanguage: 'en',
                          targetLanguage: 'zh-CN',
                          targetLabel: '简体中文',
                          specification: translationSpec,
                          reservation: batch.reservation,
                          checkpointScope:
                              '$key:${batch.processedThrough.inMilliseconds}',
                          onProgress: (_) {},
                          onMetrics: (metrics) =>
                              inferences += metrics.requests,
                        ),
                      );
                    },
                  )).map((c) => c.toTimingJson()).toList();
              final watch = Stopwatch()..start();
              final result = await run();
              expect(result, isNotEmpty);
              if (_gpu) {
                expect(
                  result.every(
                    (cue) =>
                        '${(cue['asr'] as Map?)?['backend']}'.startsWith('GPU'),
                  ),
                  isTrue,
                  reason: 'Production pipeline must actually use GPU for $key',
                );
              }
              expect(outputs, hasLength(result.length));
              expect(
                outputs.every((s) => RegExp(r'[\u4e00-\u9fff]').hasMatch(s)),
                isTrue,
              );
              final counts = (preparations, inferences);
              final firstOutputs = List<String>.of(outputs);
              outputs.clear();
              expect(await run(), result);
              expect((preparations, inferences), counts);
              expect(outputs, firstOutputs);
              report[key] = {
                'source': result,
                'translations': firstOutputs,
                'elapsedMs': watch.elapsedMilliseconds,
                'audioPreparations': preparations,
                'inferenceRequests': inferences,
                'modes': modes.toList(),
                'resumedWithoutInference': true,
              };
              // ignore: avoid_print
              print('Verified $key');
            }
          }
        }
      } finally {
        await center.shutdown();
        center.dispose();
        await temp.delete(recursive: true);
      }
    },
    skip: !_enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 20)),
  );
  test(
    'recognized Japanese and Korean subtitles use both GGUF translators',
    () async {
      const saved = String.fromEnvironment('NEW_ASR_RECOGNITION_REPORT');
      final recognitions = saved.isEmpty
          ? report
          : jsonDecode(await File(saved).readAsString()) as Map;
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp('new-asr-language-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(temp.path, 'support')),
          documents: Directory(p.join(temp.path, 'documents')),
          defaultData: Directory(p.join(temp.path, 'data')),
          executable: Directory(p.join(temp.path, 'executable')),
        ),
      );
      await storage.initialize();
      final center = _Center(storage: storage)
        ..catalog = await loadModelCatalog(includeRetired: true);
      try {
        // Use real Japanese/Korean recognition from the first test as translator
        // input. This exercises both existing GGUF prompt/streaming paths.
        for (final language in ['ja', 'ko']) {
          final recognition =
              recognitions['language:whisper-large-v3-turbo-int8:$language']
                  as Map?;
          expect(
            recognition,
            isNotNull,
            reason: 'Missing recognized $language sample',
          );
          final texts = (recognition!['cues'] as List)
              .cast<Map>()
              .map((c) => c['t'] as String)
              .toList();
          for (final translation in center.catalog.where(
            (m) => m.purpose == ModelPurpose.translation,
          )) {
            final spec = ModelJobSpec(
              profile: ModelServiceProfile(
                id: translation.id,
                name: translation.name,
                kind: TranscriptionServiceKind.local,
                model: translation.id,
              ),
              artifactIdentity: translation.identity,
              translation: const LocalTranslationOptions(
                acceleration: TranslationAcceleration.cpu,
                threads: 4,
              ),
            );
            final translated = await LocalSubtitleTranslator(center: center)
                .translate(
                  texts: texts,
                  sourceLanguage: language,
                  targetLanguage: 'zh-CN',
                  targetLabel: '简体中文',
                  specification: spec,
                  onProgress: (_) {},
                  checkpointScope: 'new-native-$language:${translation.id}',
                );
            report['translation:$language:${translation.id}'] = {
              'source': texts,
              'output': translated,
            };
            expect(translated, hasLength(texts.length));
            expect(
              translated.every((s) => RegExp(r'[\u4e00-\u9fff]').hasMatch(s)),
              isTrue,
              reason: '$language:${translation.id}: $translated',
            );
            expect(translated, isNot(texts));
          }
        }
      } finally {
        await center.shutdown();
        center.dispose();
        await temp.delete(recursive: true);
      }
    },
    skip:
        !_enabled ||
        !Platform.isWindows ||
        (_samples.isEmpty &&
            const String.fromEnvironment('NEW_ASR_RECOGNITION_REPORT').isEmpty),
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
