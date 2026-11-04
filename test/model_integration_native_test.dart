import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'support/prepared_local_models.dart';
import '../tool/local_asr_probe_assets.dart';

class _NativeCenter extends ModelCenterService with PreparedLocalModels {
  _NativeCenter(this.weightsRoot, {required super.storage});
  final String weightsRoot;
  @override
  Future<void> initialize() async {}
  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) => action(artifact(id)!, Directory(p.join(weightsRoot, id)));
  @override
  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => action(
    artifact(spec.profile.model)!,
    Directory(p.join(weightsRoot, spec.profile.model)),
    const {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('MODEL_INTEGRATION_MODEL_ROOT');
  final enabled = root.isNotEmpty && Platform.isWindows;
  final records = <String, Object?>{};
  late String libraries;

  setUpAll(() async {
    if (!enabled) return;
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
    await LlamaLogging.configure(level: LlamaLogLevel.warn);
  });
  tearDownAll(() async {
    if (!enabled) return;
    final report = File(
      const String.fromEnvironment(
        'MODEL_INTEGRATION_REPORT',
        defaultValue: '.artifacts/model-integration/native-results.json',
      ),
    );
    await report.parent.create(recursive: true);
    await report.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(records)}\n',
    );
  });

  test(
    'all catalog ASR families execute real recognition and retain timed cues',
    () async {
      for (final model in (await loadModelCatalog()).where(
        (m) => m.purpose == ModelPurpose.transcription,
      )) {
        final worker = LocalAsrWorker(
          libraryDirectory: libraries,
          qwenWorkerExecutable: p.absolute(
            'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',
          ),
          cohereWorkerExecutable: p.absolute(
            'native/cohere_asr/prebuilt/windows-x64/cohere_asr_worker.exe',
          ),
          parakeetJapaneseWorkerExecutable: p.absolute(
            'native/parakeet_ja/prebuilt/windows-x64/parakeet_ja_worker.exe',
          ),
          nativeWorkerExecutable: p.absolute(
            'native/asr/prebuilt/windows-x64/asr_worker.exe',
          ),
        );
        final chinese =
            !model.languages.contains('en') || model.engine == 'zipformer';
        final wave = p.absolute(
          localAsrProbeAsset(
            model.engine,
            model.languages,
            language: chinese ? 'zh' : 'en',
          ),
        );
        try {
          await worker.start(
            engine: model.engine,
            directory: p.join(root, model.id),
            vadPath: asrProbeVadPath(),
            language:
                localAsrAdapters[model.engine]?.fixedLanguage ??
                (chinese ? 'zh' : 'en'),
            threads: 2,
          );
          final cues = await worker.recognize(wave);
          expect(cues, isNotEmpty, reason: model.id);
          expect(
            cues.every((c) => c.endTime > c.startTime && c.text.isNotEmpty),
            isTrue,
          );
          final replay = await worker.recognize(wave);
          expect(
            replay.map((c) => c.toTimingJson()).toList(),
            cues.map((c) => c.toTimingJson()).toList(),
            reason: model.id,
          );
          records[model.id] = cues.map((c) => c.toTimingJson()).toList();
        } finally {
          await worker.close();
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  for (final asrModelId in ['sensevoice-small-int8', 'parakeet-ja-0.6b-q8']) {
    test(
      '$asrModelId production transcription and local translation preserve timings and resume without new inference',
      () async {
        SharedPreferences.setMockInitialValues({});
        final temp = await Directory.systemTemp.createTemp(
          'model-integration-native-',
        );
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
        final center = _NativeCenter(root, storage: storage)
          ..catalog = await loadModelCatalog();
        final model = center.artifact(asrModelId)!;
        final language = localAsrAdapters[model.engine]?.fixedLanguage ?? 'en';
        final source = p.absolute(
          localAsrProbeAsset(model.engine, model.languages, language: language),
        );
        final duration = Duration(
          microseconds:
              decodeModelWave(await File(source).readAsBytes()).length *
              1000000 ~/
              16000,
        );
        final profile = ModelServiceProfile(
          id: 'native-asr',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
        );
        center.profiles[profile.id] = profile;
        center.asrProfileId = profile.id;
        center.asrEnhancements = AsrEnhancementOptions.disabled;
        center.asrCpuThreads = 2;
        center.asrAccelerationOptions[model.id] = AsrAcceleration.cpu;
        await center.selectAsrLanguage(language);
        final spec = center.transcriptionConfiguration;
        expect(spec.profile.language, language);
        try {
          for (final translation in center.catalog.where(
            (m) => m.purpose == ModelPurpose.translation,
          )) {
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
                threads: 2,
                batchSize: 4,
              ),
            );
            var preparations = 0, inferences = 0;
            final translator = LocalSubtitleTranslator(center: center);
            final runner = ModelTranscriptionRunner(
              center: center,
              createLocalWorker: () => LocalAsrWorker(
                libraryDirectory: libraries,
                parakeetJapaneseWorkerExecutable: p.absolute(
                  'native/parakeet_ja/prebuilt/windows-x64/parakeet_ja_worker.exe',
                ),
              ),
              loadDeviceInfo: () async => const ModelDeviceInfo(
                memoryBytes: 8 * 1073741824,
                availableMemoryBytes: 4 * 1073741824,
                processors: 4,
              ),
            );
            final outputs = <String>[];
            Future<List<Map<String, dynamic>>> run() async => (await runner.run(
              spec: spec,
              sourceIdentity: 'native-integration-${translation.id}',
              duration: duration,
              serializeConsumer: true,
              consumerModelBytes: translation.bytes,
              onProgress: (_) {},
              prepareAudio: (_, _, _, _) async {
                preparations++;
                final copied = await File(
                  source,
                ).copy(p.join(temp.path, 'sample-$preparations.wav'));
                return copied.path;
              },
              onStableBatch: (batch) async {
                outputs.addAll(
                  await translator.translate(
                    texts: batch.cues.map((c) => c.text).toList(),
                    sourceLanguage: language,
                    targetLanguage: 'zh-CN',
                    targetLabel: '简体中文',
                    specification: translationSpec,
                    reservation: batch.reservation,
                    checkpointScope:
                        'native-${translation.id}-${batch.processedThrough.inMilliseconds}',
                    onProgress: (_) {},
                    onMetrics: (m) => inferences += m.requests,
                  ),
                );
              },
            )).map((c) => c.toTimingJson()).toList();
            final result = await run();
            expect(result, isNotEmpty);
            expect(outputs, hasLength(result.length));
            expect(
              outputs.every((s) => RegExp(r'[\u4e00-\u9fff]').hasMatch(s)),
              isTrue,
            );
            final before = (preparations, inferences);
            final firstOutputs = List<String>.of(outputs);
            outputs.clear();
            expect(await run(), result);
            expect((preparations, inferences), before);
            expect(outputs, firstOutputs);
            records['workflow:$asrModelId:${translation.id}'] = {
              'source': result,
              'translations': firstOutputs,
              'audioPreparations': preparations,
              'inferenceRequests': inferences,
              'resumedWithoutInference': true,
            };
          }
        } finally {
          await center.shutdown();
          center.dispose();
          await temp.delete(recursive: true);
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 8)),
    );
  }
}
