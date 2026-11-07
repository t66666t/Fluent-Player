import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';

class _Downloads extends ModelCenterService {
  _Downloads({required super.storage, required super.catalogLoader});
  final enqueued = <String>[];
  @override
  Future<void> enqueue(String id) async {
    enqueued.add(id);
    downloads[id] = ModelDownload(artifactId: id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Downloads center;
  late List<ModelArtifact> models;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('asr-preparation-');
    final storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.linux,
        support: Directory(p.join(root.path, 'support')),
        documents: Directory(p.join(root.path, 'documents')),
        defaultData: Directory(p.join(root.path, 'data')),
        executable: Directory(p.join(root.path, 'exe')),
      ),
    );
    models = await loadModelCatalog(includeRetired: true);
    center = _Downloads(storage: storage, catalogLoader: () async => models);
    await center.initialize();
    center.asrProfileId = ModelCenterService.communityDefaultProfile.id;
    center.asrEnhancements = AsrEnhancementOptions.disabled;
  });
  tearDown(() async {
    await center.shutdown();
    center.dispose();
    await root.delete(recursive: true);
  });

  void install(String id) {
    center.downloads[id] = ModelDownload(
      artifactId: id,
      phase: ModelDownloadPhase.installed,
    );
  }

  test(
    'cold capture freezes an uninstalled model without starting downloads',
    () async {
      final spec = await center.captureTranscription();
      expect(spec.profile.model, 'sensevoice-small-int8');
      expect(
        spec.artifactIdentity,
        center.artifact(spec.profile.model)!.identity,
      );
      expect(center.enqueued, isEmpty);
      expect(center.installed(spec.profile.model), isFalse);
      expect(
        center.asrDownloadComponents(center.artifact(spec.profile.model)!),
        contains(center.artifact(asrVadModelId)),
      );
    },
  );

  test(
    'task downloads its frozen model, then VAD, and resumes automatically',
    () async {
      final spec = await center.captureTranscription();
      final progress = <String>[];
      final prepared = center.prepareAsrModels(spec, onProgress: progress.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(center.enqueued, [spec.profile.model]);
      expect(progress.join(), contains('SenseVoice'));
      expect(InferenceScheduler.instance.busy, isFalse);
      // Changing the default while waiting cannot switch this job's download.
      center.asrProfileId = ModelCenterService.legacyProfile.id;
      install(spec.profile.model);
      await Future<void>.delayed(const Duration(milliseconds: 230));
      expect(center.enqueued, [spec.profile.model, asrVadModelId]);
      install(asrVadModelId);
      final vad = await prepared;
      expect(p.basename(vad.path), asrVadFileName);
      expect(progress.join(), contains('Silero'));
      expect(center.enqueued, isNot(contains('gongyi')));
      // Reusing an installed combination never queues another transfer.
      await center.prepareAsrModels(spec);
      expect(center.enqueued, [spec.profile.model, asrVadModelId]);
    },
  );

  test(
    'two tasks share an active transfer; cancellation stops only its waiter',
    () async {
      final spec = await center.captureTranscription();
      install(asrVadModelId);
      final cancelled = Completer<void>();
      final first = center.prepareAsrModels(
        spec,
        cancelSignal: cancelled.future,
      );
      final firstResult = expectLater(first, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = center.prepareAsrModels(spec);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(center.enqueued, [spec.profile.model]);
      cancelled.complete();
      await firstResult;
      expect(
        center.downloads[spec.profile.model]!.phase,
        ModelDownloadPhase.queued,
      );
      install(spec.profile.model);
      await second;
      expect(center.enqueued, [spec.profile.model]);
    },
  );

  test('already cancelled tasks do not enqueue weights', () async {
    final spec = await center.captureTranscription();
    await expectLater(
      center.prepareAsrModels(spec, cancelSignal: Future<void>.value()),
      throwsStateError,
    );
    expect(center.enqueued, isEmpty);
  });

  for (final phase in [ModelDownloadPhase.failed, ModelDownloadPhase.paused]) {
    test(
      'download $phase reports failure and retry preserves the task identity',
      () async {
        final spec = await center.captureTranscription();
        install(asrVadModelId);
        final preparation = center.prepareAsrModels(spec);
        final failed = expectLater(
          preparation,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              contains('重试转录可继续下载'),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        center.downloads[spec.profile.model]!.phase = phase;
        await failed;
        final retry = center.prepareAsrModels(spec);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(center.enqueued, [spec.profile.model, spec.profile.model]);
        install(spec.profile.model);
        await retry;
      },
    );
  }

  test('changed and missing identities fail before any download', () async {
    final captured = await center.captureTranscription();
    final wrong = ModelJobSpec.fromJson({
      ...captured.toJson(),
      'artifactIdentity': 'different-revision',
    });
    await expectLater(center.prepareAsrModels(wrong), throwsStateError);
    expect(center.enqueued, isEmpty);
  });

  test(
    'retired missing weights fail closed and installed frozen tasks remain usable',
    () async {
      final model =
          center.artifact('whisper-turbo-int8') ??
          models.firstWhere(
            (m) => m.retired && m.purpose == ModelPurpose.transcription,
          );
      final spec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'frozen',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
        ),
        artifactIdentity: model.identity,
      );
      await expectLater(center.prepareModel(spec), throwsStateError);
      expect(center.enqueued, isEmpty);
      install(model.id);
      await center.prepareModel(spec);
      expect(center.enqueued, isEmpty);
    },
  );

  test(
    'local translation captures missing weights and prepares that frozen version',
    () async {
      final spec = await captureLocalTranslation(center);
      center.translationModelId = 'qwen3-4b-q4';
      final preparation = center.prepareModel(spec);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(center.enqueued, [spec.profile.model]);
      install(spec.profile.model);
      await preparation;
      expect(spec.profile.model, 'hy-mt2-1.8b-q4');
    },
  );

  test(
    'an existing cached VAD is imported offline once for concurrent tasks',
    () async {
      const bytes = [1, 2, 3, 4];
      final digest = sha256.convert(bytes).toString();
      final fixture = ModelArtifact(
        id: asrVadModelId,
        name: 'Fixture VAD',
        engine: 'silero-vad',
        revision: digest,
        parameters: '',
        quantization: '',
        languages: const [],
        description: '',
        license: 'MIT',
        homepage: 'https://fixture.invalid',
        purpose: ModelPurpose.enhancement,
        suggestedRamGb: 1,
        memoryNote: '',
        files: [
          ModelFile(
            name: asrVadFileName,
            bytes: bytes.length,
            sha256: digest,
            sources: const {'fixture': 'https://fixture.invalid/vad'},
          ),
        ],
      );
      center.catalog = [
        for (final model in center.catalog)
          if (model.id == asrVadModelId) fixture else model,
      ];
      final legacy = File(
        p.join((await center.modelRoot()).path, asrVadFileName),
      );
      await legacy.writeAsBytes(bytes);
      final prepared = await Future.wait([
        center.prepareAsrVad(),
        center.prepareAsrVad(),
      ]);
      expect(prepared[0].path, prepared[1].path);
      expect(await prepared.first.readAsBytes(), bytes);
      expect(await legacy.readAsBytes(), bytes);
      expect(center.enqueued, isEmpty);
      expect(center.installed(asrVadModelId), isTrue);
    },
  );

  test(
    'a shared VAD cannot be deleted during inference and its lease is released',
    () async {
      final spec = await center.captureTranscription();
      install(spec.profile.model);
      install(asrVadModelId);
      await center.usingAsrModels(spec, (_, _, dependencies) async {
        expect(dependencies, contains(asrVadModelId));
        expect(center.inUse(asrVadModelId), isTrue);
        await expectLater(center.remove(asrVadModelId), throwsStateError);
      });
      expect(center.inUse(asrVadModelId), isFalse);
      expect(center.inUse(spec.profile.model), isFalse);
    },
  );

  test(
    'VAD has a fixed catalog identity and is independent of enhancement toggles',
    () {
      final vad = center.artifact(asrVadModelId)!;
      expect(vad.files.single.name, asrVadFileName);
      expect(vad.files.single.bytes, 643854);
      expect(vad.revision, vad.files.single.sha256);
      for (final model in models.where(
        (m) => !m.retired && m.purpose == ModelPurpose.transcription,
      )) {
        expect(
          center.asrDownloadComponents(model).map((m) => m.id),
          contains(asrVadModelId),
          reason: model.id,
        );
      }
    },
  );
}
