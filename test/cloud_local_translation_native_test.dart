import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/ai_subtitle_translator.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/cloud_translation_batches.dart';
import 'package:video_player_app/services/local_transcription_stream.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/subtitle_translation_service.dart';
import 'support/prepared_local_models.dart';

class _Center extends ModelCenterService with PreparedLocalModels {
  _Center({required super.storage});
  @override
  Future<void> initialize() async {}
  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) => action(
    artifact(id)!,
    Directory(p.absolute('.artifacts/model-center/native/$id')),
  );
}

class _Measured extends SubtitleTranslationService {
  final runs = <LocalTranslationMetrics>[];
  final scheduler = InferenceScheduler(
    openResources: () async {
      final captured = DateTime.now();
      return InferenceResourceSession(
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: 'windows',
            processors: 8,
            memoryBytes: 8 * 1073741824,
            availableMemoryBytes: 4 * 1073741824,
            capturedAt: captured,
          ),
          now: () => captured,
        ),
      );
    },
  );
  @override
  Future<List<String>> translateCueBatch({
    required List<SubtitleItem> items,
    required String sourceLanguage,
    required String targetLanguage,
    required SubtitleTranslateProvider provider,
    required void Function(double) onProgress,
    void Function(String?)? onActivity,
    void Function(int, String)? onTranslated,
    AiSubtitleTranslationSettings? aiOptions,
    AiSubtitleApiSettings? aiEndpoint,
    ModelJobSpec? localSpecification,
    ModelCenterService? modelCenter,
    LocalTranslationSession? localSession,
    InferenceReservation? reservation,
    String precedingContext = '',
    String checkpointScope = '',
    Future<void>? cancelSignal,
    SmartTranslationPolicy? smartPolicy,
  }) => LocalSubtitleTranslator(center: modelCenter, scheduler: scheduler)
      .translate(
        texts: items.map((c) => c.text).toList(),
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        targetLabel: '简体中文',
        onProgress: onProgress,
        onActivity: onActivity,
        onTranslated: onTranslated,
        specification: localSpecification,
        session: localSession,
        reservation: reservation,
        precedingContext: precedingContext,
        checkpointScope: checkpointScope,
        cancelSignal: cancelSignal,
        onMetrics: runs.add,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('CLOUD_LOCAL_NATIVE');
  test(
    'cloud primary stays complete while native batches reuse a single translation model',
    () async {
      SharedPreferences.setMockInitialValues({});
      await LlamaLogging.configure(level: LlamaLogLevel.warn);
      final root = await Directory.systemTemp.createTemp('cloud-local-native-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(root.path, 'support')),
          documents: Directory(p.join(root.path, 'docs')),
          defaultData: Directory(p.join(root.path, 'data')),
          executable: Directory(p.join(root.path, 'exe')),
        ),
      );
      await storage.initialize();
      final center = _Center(storage: storage)
        ..catalog = await loadModelCatalog();
      final model = center.artifact('hy-mt2-1.8b-q4')!;
      final specification = ModelJobSpec(
        profile: ModelServiceProfile(
          id: model.id,
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
        ),
        artifactIdentity: model.identity,
        translation: const LocalTranslationOptions(
          acceleration: TranslationAcceleration.cpu,
          threads: 2,
          batchSize: 2,
        ),
      );
      final texts = [
        'Hello everyone.',
        'Please open the window.',
        'This is a useful tool.',
        'The meeting starts at nine.',
        'Thanks for your help.',
        'See you tomorrow.',
      ];
      final cues = [
        for (var i = 0; i < texts.length; i++)
          SubtitleItem(
            index: i + 1,
            text: texts[i],
            startTime: Duration(seconds: i * 5),
            endTime: Duration(seconds: i * 5 + 4),
          ),
      ];
      final primary = File(p.join(root.path, 'original.srt'));
      await primary.writeAsString(encodeStreamingSrt(cues));
      final original = await primary.readAsBytes();
      final store = await StreamingSubtitleStore.create(
        File(p.join(root.path, 'stream.jsonl')),
        {
          'generationId': 'cloud-native',
          'primaryPath': primary.path,
          'secondaryPath': p.join(root.path, 'translated.srt'),
          'primaryComplete': true,
        },
        completedPrimary: cues,
      );
      final measured = _Measured();
      final watch = Stopwatch()..start();
      final commits = <Map<String, int>>[];
      final stream = LocalTranscriptionStream(
        openStore: () async => store,
        choice: TranscriptTranslateChoice(
          enabled: true,
          direction: TranscriptTranslateDirection.toChinese,
          provider: SubtitleTranslateProvider.local,
          aiOptions: AiSubtitleTranslationSettings.defaults,
          localSpecification: specification,
        ),
        center: center,
        translator: measured,
        cancelSignal: Completer<void>().future,
        checkCancelled: () {},
        onActivity: (_, _) {},
        onFailure: () {},
        onCommitted: (state, addedPrimary, secondary) async {
          expect(addedPrimary, isEmpty);
          expect(state.primary.snapshot, hasLength(6));
          expect(await primary.readAsBytes(), original);
          commits.add({
            'atMs': watch.elapsedMilliseconds,
            'secondaryCues': state.secondary.snapshot.length,
          });
        },
      );
      try {
        for (final batch in cloudTranslationBatches(cues, maxCues: 2)) {
          await stream.accept(batch);
        }
        await stream.drain();
        final loads = measured.runs.fold<int>(0, (n, m) => n + m.modelLoads);
        final reuses = measured.runs.fold<int>(0, (n, m) => n + m.modelReuses);
        expect(commits.map((c) => c['secondaryCues']), [2, 4, 6]);
        expect(loads, 1);
        expect(reuses, 2);
        expect(
          store.secondary.snapshot.every(
            (c) => RegExp(r'[\u3400-\u9fff]').hasMatch(c.text),
          ),
          isTrue,
        );
        final output = File(
          '.artifacts/model-center/cloud-local-translation-native-results.json',
        );
        await output.parent.create(recursive: true);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'platform': Platform.operatingSystem,
            'model': model.id,
            'admission': '8 GiB total / 4 GiB available fixture',
            'elapsedMs': watch.elapsedMilliseconds,
            'commits': commits,
            'modelLoads': loads,
            'modelReuses': reuses,
          }),
        );
      } finally {
        await stream.close();
        measured.dispose();
        await center.shutdown();
        center.dispose();
        if (root.absolute.parent.path == Directory.systemTemp.absolute.path &&
            root.path.contains('cloud-local-native-')) {
          await root.delete(recursive: true);
        }
      }
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
