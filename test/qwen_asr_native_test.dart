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
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/services/app_storage_service.dart';

class _Center extends ModelCenterService {
  _Center(this.root, {required super.storage});
  final String root;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> prepareAsrEnhancements(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) async {}
  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) => action(artifact(id)!, Directory(p.join(root, id)));
  @override
  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => action(
    artifact(spec.profile.model)!,
    Directory(p.join(root, spec.profile.model)),
    {for (final id in spec.enhancementModels.keys) id: p.join(root, id)},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('QWEN_NATIVE_MODEL_ROOT');
  final enabled = Platform.isWindows && root.isNotEmpty;
  late String libraries;
  final executable = p.absolute(
    'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',
  );
  final samples = p.absolute('.artifacts/new-asr-20261027/samples');
  final receipts = <String, Object?>{};
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
  });
  tearDownAll(() async {
    if (enabled) {
      await File(
        '.artifacts/qwen-integration/native-workflow.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(receipts));
    }
  });

  test(
    'Windows real Qwen and old Japanese/Korean models share tokenization and valid alignment',
    () async {
      for (final id in [
        'qwen3-asr-0.6b-f16',
        'qwen3-asr-1.7b-f16',
        'sensevoice-small-int8',
      ]) {
        final engine = id.startsWith('qwen') ? 'qwen3-asr' : 'sensevoice';
        for (final language in ['ja', 'ko']) {
          final worker = LocalAsrWorker(
            libraryDirectory: libraries,
            qwenWorkerExecutable: executable,
            nativeWorkerExecutable: p.absolute(
              'native/asr/prebuilt/windows-x64/asr_worker.exe',
            ),
          );
          try {
            await worker.start(
              engine: engine,
              directory: p.join(root, id),
              vadPath: p.absolute('assets/models/asr/silero_vad.onnx'),
              language: 'auto',
              threads: 4,
              textProcessingVersion: 1,
              enhancements: const AsrEnhancementOptions(
                denoise: false,
                punctuation: false,
                trimSilence: false,
                alwaysAlign: true,
              ),
              enhancementDirectories: {
                for (final enhancement in [
                  AsrEnhancementOptions.alignmentQwenId,
                  AsrEnhancementOptions.languageId,
                ])
                  enhancement: p.join(root, enhancement),
              },
            );
            final cues = await worker.recognize(
              p.join(samples, '$language.wav'),
            );
            expect(cues, isNotEmpty, reason: '$id/$language');
            for (final cue in cues) {
              expect(cue.asrInfo.language, language);
              expect(cue.asrInfo.wordBoundaries, isNotEmpty);
              if (cue.timedSpans.isEmpty) {
                expect(cue.asrInfo.reviewReason, contains('保留原始时间轴'));
              }
              expect(
                cue.timedSpans.every(
                  (s) =>
                      (s.role == 'aligned' || s.role == 'token') &&
                      s.textEnd <= cue.text.length &&
                      s.endTime > s.startTime,
                ),
                isTrue,
              );
            }
            receipts['$id/$language'] = cues
                .map((c) => c.toTimingJson())
                .toList();
          } finally {
            await worker.close();
          }
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 6)),
  );

  test(
    'Qwen cancellation discards in-flight decode and a new owner can resume',
    () async {
      final worker = LocalAsrWorker(
        libraryDirectory: libraries,
        qwenWorkerExecutable: executable,
      );
      final cancel = Completer<void>();
      try {
        await worker.start(
          engine: 'qwen3-asr',
          directory: p.join(root, 'qwen3-asr-1.7b-f16'),
          vadPath: p.absolute('assets/models/asr/silero_vad.onnx'),
          language: 'ja',
          threads: 4,
        );
        final future = worker.recognize(
          p.join(samples, 'ja.wav'),
          cancelSignal: cancel.future,
          onPhase: (phase, _, _) {
            if (phase == 'loading' && !cancel.isCompleted) cancel.complete();
          },
        );
        await expectLater(future, throwsStateError);
        receipts['cancelled'] = true;
      } finally {
        await worker.close();
      }
      final resumed = LocalAsrWorker(
        libraryDirectory: libraries,
        qwenWorkerExecutable: executable,
      );
      try {
        await resumed.start(
          engine: 'qwen3-asr',
          directory: p.join(root, 'qwen3-asr-0.6b-f16'),
          vadPath: p.absolute('assets/models/asr/silero_vad.onnx'),
          language: 'ja',
          threads: 4,
        );
        expect(await resumed.recognize(p.join(samples, 'ja.wav')), isNotEmpty);
        receipts['newOwnerAfterCancel'] = true;
      } finally {
        await resumed.close();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'Qwen production Japanese ASR-align-translation pipeline preserves checkpoints',
    () async {
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp('qwen-workflow-');
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
      final center = _Center(root, storage: storage)
        ..catalog = await loadModelCatalog();
      final model = center.artifact('qwen3-asr-0.6b-f16')!;
      final source = p.join(samples, 'ja.wav');
      final duration = Duration(
        microseconds:
            decodeModelWave(await File(source).readAsBytes()).length *
            1000000 ~/
            16000,
      );
      final spec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'qwen-native',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
          language: 'auto',
        ),
        artifactIdentity: model.identity,
        asrTextProcessingVersion: 1,
        asrAcceleration: AsrAcceleration.cpu,
        asrExecution: AsrExecutionMode.lowMemory,
        asrEnhancements: const AsrEnhancementOptions(
          denoise: false,
          punctuation: false,
          trimSilence: false,
        ),
        enhancementModels: {
          for (final id in [
            AsrEnhancementOptions.alignmentQwenId,
            AsrEnhancementOptions.languageId,
          ])
            id: center.artifact(id)!.identity,
        },
      );
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
          final translator = LocalSubtitleTranslator(center: center);
          final runner = ModelTranscriptionRunner(
            center: center,
            createLocalWorker: () => LocalAsrWorker(
              libraryDirectory: libraries,
              qwenWorkerExecutable: executable,
            ),
            loadDeviceInfo: () async => const ModelDeviceInfo(
              memoryBytes: 16 * 1073741824,
              availableMemoryBytes: 12 * 1073741824,
              processors: 4,
            ),
          );
          var preparations = 0, requests = 0;
          final outputs = <String>[];
          Future<List<Map<String, dynamic>>> run() async => (await runner.run(
            spec: spec,
            sourceIdentity: 'qwen-ja-${translation.id}',
            duration: duration,
            serializeConsumer: true,
            consumerModelBytes: translation.bytes,
            onProgress: (_) {},
            prepareAudio: (_, _, _, _) async {
              final file = await File(
                source,
              ).copy(p.join(temp.path, 'prepared-${++preparations}.wav'));
              return file.path;
            },
            onStableBatch: (batch) async {
              outputs.addAll(
                await translator.translate(
                  texts: batch.cues.map((c) => c.text).toList(),
                  sourceLanguage: 'ja',
                  targetLanguage: 'zh-CN',
                  targetLabel: '简体中文',
                  specification: translationSpec,
                  reservation: batch.reservation,
                  checkpointScope:
                      'qwen-${translation.id}-${batch.processedThrough.inMilliseconds}',
                  onProgress: (_) {},
                  onMetrics: (m) => requests += m.requests,
                ),
              );
            },
          )).map((c) => c.toTimingJson()).toList();
          final first = await run();
          expect(first, isNotEmpty);
          expect(outputs, hasLength(first.length));
          expect(
            outputs.every((s) => RegExp(r'[\u4e00-\u9fff]').hasMatch(s)),
            isTrue,
          );
          final before = (preparations, requests),
              texts = List<String>.of(outputs);
          outputs.clear();
          expect(await run(), first);
          expect((preparations, requests), before);
          expect(outputs, texts);
          receipts['workflow/${translation.id}'] = {
            'cues': first,
            'translations': texts,
            'requests': requests,
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
