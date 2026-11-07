import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/ios_model_download.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';

const _retired = {
  'zipformer-zh-en-tiny-int8',
  'whisper-large-v3-turbo-int8',
  'firered-asr2-ctc-int8',
  'zipformer-zh-en-tiny-int8-gpu',
  'whisper-large-v3-turbo-int8-gpu',
  'firered-asr2-ctc-int8-gpu',
};

class _Secrets implements AiChatSecretStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

ModelArtifact _fixture(String id, {bool retired = false}) => ModelArtifact(
  id: id,
  name: id,
  engine: retired ? 'zipformer' : 'sensevoice',
  revision: 'a' * 40,
  parameters: '',
  quantization: '',
  languages: const ['zh', 'en'],
  description: '',
  license: 'MIT',
  homepage: '',
  purpose: ModelPurpose.transcription,
  suggestedRamGb: 4,
  memoryNote: '',
  retired: retired,
  files: [
    ModelFile(
      name: 'model.onnx',
      bytes: 4,
      sha256: 'b' * 64,
      sources: const {},
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'three models and their exclusive packs are absent from active choices',
    () async {
      final active = await loadModelCatalog();
      final all = await loadModelCatalog(includeRetired: true);
      expect(all.where((m) => m.retired).map((m) => m.id).toSet(), _retired);
      expect(active.any((m) => _retired.contains(m.id)), isFalse);
      expect(
        active
            .where((m) => m.purpose == ModelPurpose.transcription)
            .map((m) => m.id),
        containsAll([
          'sensevoice-small-int8',
          'dolphin-base-int8',
          'parakeet-v3-int8',
          'qwen3-asr-0.6b-f16',
          'qwen3-asr-1.7b-f16',
        ]),
      );
      expect(
        active.any(
          (m) =>
              m.purpose == ModelPurpose.transcription &&
              localAsrAdapter(m.engine).supportsHotwords,
        ),
        isTrue,
      );
    },
  );

  group('retirement migration', () {
    late Directory root;
    late AppStorageService storage;
    late ModelCenterService center;
    late ModelArtifact old, replacement;
    late File record;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('model-retirement-');
      storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(root.path, 'support')),
          documents: Directory(p.join(root.path, 'documents')),
          defaultData: Directory(p.join(root.path, 'data')),
          executable: Directory(p.join(root.path, 'executable')),
        ),
      );
      await storage.initialize();
      old = _fixture('zipformer-zh-en-tiny-int8', retired: true);
      replacement = _fixture('sensevoice-small-int8');
      center = ModelCenterService(
        storage: storage,
        secrets: _Secrets(),
        catalogLoader: () async => [old, replacement],
        createDio: () =>
            throw StateError('retirement must not start a download'),
      );
      record = await storage.dataRecord('model_center.json');
    });
    tearDown(() async {
      await center.shutdown();
      await root.delete(recursive: true);
    });
    Future<void> saveOld(ModelDownload download, {bool selected = true}) =>
        writeStorageJson(record, {
          'asrProfileId': selected ? 'local:${old.id}' : 'gongyi',
          'profiles': [
            ModelServiceProfile(
              id: 'local:${old.id}',
              name: old.name,
              kind: TranscriptionServiceKind.local,
              model: old.id,
            ).toJson(),
          ],
          'downloads': [download.toJson()],
          'asrEnhancements': const AsrEnhancementOptions(
            hotwords: '专业术语',
          ).toJson(),
        });

    test(
      'installed weights and frozen jobs survive; new defaults stay local',
      () async {
        final dir = await center.modelDirectory(old);
        await dir.create(recursive: true);
        await File(p.join(dir.path, 'model.onnx')).writeAsBytes([1, 2, 3, 4]);
        await writeStorageJson(File(p.join(dir.path, 'installed.json')), {
          'identity': old.identity,
        });
        await saveOld(
          ModelDownload(
            artifactId: old.id,
            phase: ModelDownloadPhase.installed,
          ),
        );
        await center.initialize();
        expect(center.catalog.map((m) => m.id), [replacement.id]);
        expect(center.asrProfile.model, replacement.id);
        expect(center.asrProfile.local, isTrue);
        expect(center.asrEnhancements.hotwords, '专业术语');
        expect(center.installed(old.id), isTrue);
        expect(center.activeDownloads, 0);
        final frozen = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'local:${old.id}',
            name: old.name,
            kind: TranscriptionServiceKind.local,
            model: old.id,
          ),
          artifactIdentity: old.identity,
        );
        final fingerprint = frozen.recognitionFingerprint;
        expect(
          await center.usingAsrModels(frozen, (m, _, _) async => m.identity),
          old.identity,
        );
        expect(frozen.recognitionFingerprint, fingerprint);
        expect(await File(p.join(dir.path, 'model.onnx')).readAsBytes(), [
          1,
          2,
          3,
          4,
        ]);
        await expectLater(center.selectAsr(old), throwsStateError);
        await expectLater(center.enqueue(old.id), throwsStateError);
        await expectLater(center.queueAsrDownload(old), throwsStateError);
        expect(
          (jsonDecode(await record.readAsString()) as Map)['asrProfileId'],
          'local:${replacement.id}',
        );
      },
    );

    test(
      'unfinished retired downloads pause and preserve checkpoints and the selected public profile',
      () async {
        final dir = await center.modelDirectory(old);
        await dir.create(recursive: true);
        final partial = File(p.join(dir.path, 'model.onnx.part'));
        await partial.writeAsBytes([1, 2]);
        await saveOld(
          ModelDownload(
            artifactId: old.id,
            phase: ModelDownloadPhase.downloading,
            received: 2,
            fileState: {
              'model.onnx': {'url': 'old-source', 'etag': 'old-etag'},
            },
          ),
          selected: false,
        );
        await center.initialize();
        expect(center.asrProfileId, ModelCenterService.legacyProfile.id);
        expect(center.downloads[old.id]!.phase, ModelDownloadPhase.paused);
        expect(center.downloads[old.id]!.received, 2);
        expect(
          center.downloads[old.id]!.fileState['model.onnx']['etag'],
          'old-etag',
        );
        expect(await partial.readAsBytes(), [1, 2]);
        expect(center.activeDownloads, 0);
        await expectLater(
          center.usingModel(old.id, (_, _) async => true),
          throwsStateError,
        );
        final saved = jsonDecode(await record.readAsString()) as Map;
        expect(saved['asrProfileId'], ModelCenterService.legacyProfile.id);
        expect((saved['downloads'] as List).single['phase'], 'paused');
      },
    );
  });

  test(
    'iOS pauses every CPU/GPU file using its original background key',
    () async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(IosModelDownload.channel, (
        call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () =>
            messenger.setMockMethodCallHandler(IosModelDownload.channel, null),
      );
      final models = (await loadModelCatalog(
        includeRetired: true,
      )).where((m) => m.retired).toList();
      for (final model in models) {
        await IosModelDownload.pauseRetiredModelDownload(
          model.identity,
          model.files.map((f) => f.name),
        );
      }
      expect(calls.every((call) => call.method == 'pause'), isTrue);
      expect(calls.map((call) => (call.arguments as Map)['key']), [
        for (final model in models)
          for (final file in model.files) '${model.identity}:${file.name}',
      ]);
    },
  );
}
