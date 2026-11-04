import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'unverified old default migrates locally while frozen profiles and authorized services retain identity',
    () async {
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp(
        'interface-migration-',
      );
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(temp.path, 'support')),
          documents: Directory(p.join(temp.path, 'documents')),
          defaultData: Directory(p.join(temp.path, 'data')),
          executable: Directory(p.join(temp.path, 'bin')),
        ),
      );
      final centers = <ModelCenterService>[];
      try {
        await storage.initialize();
        final record = await storage.dataRecord('model_center.json');
        const olderBuiltin = {
          'id': 'retired-builtin',
          'name': '历史内置接口',
          'kind': 'retired-builtin',
          'language': 'en',
        };
        const custom = ModelServiceProfile(
          id: 'custom',
          name: '自己的转录服务',
          kind: TranscriptionServiceKind.openai,
          endpoint: 'https://asr.example.test/v1',
          model: 'custom-model',
        );
        await writeStorageJson(record, {
          'asrProfileId': olderBuiltin['id'],
          'profiles': [olderBuiltin, custom.toJson()],
        });
        final center = ModelCenterService(
          storage: storage,
          catalogLoader: () async => [],
        );
        centers.add(center);
        await center.initialize();
        expect(
          center.asrProfileId,
          ModelCenterService.communityDefaultProfile.id,
        );
        expect(center.asrProfile.kind, TranscriptionServiceKind.local);
        expect(
          center.profiles.keys,
          unorderedEquals([
            'gongyi',
            ModelCenterService.communityDefaultProfile.id,
            'custom',
          ]),
        );
        expect(center.profiles['custom']!.toJson(), custom.toJson());
        final queued = ModelJobSpec.fromJson({
          'profile': olderBuiltin,
          'threads': 3,
        });
        expect(queued.profile.kind, TranscriptionServiceKind.gongyi);
        expect(queued.profile.id, ModelCenterService.legacyProfile.id);
        expect(queued.profile.name, '公益接口');
        expect(queued.profile.language, 'en');
        expect(queued.threads, 3);
        await center.save();
        final restored = ModelCenterService(
          storage: storage,
          catalogLoader: () async => [],
        );
        centers.add(restored);
        await restored.initialize();
        expect(
          restored.asrProfileId,
          ModelCenterService.communityDefaultProfile.id,
        );
        expect(restored.profiles['custom']!.toJson(), custom.toJson());
        center.asrProfileId = 'custom';
        await center.save();
        final customSelected = ModelCenterService(
          storage: storage,
          catalogLoader: () async => [],
        );
        centers.add(customSelected);
        await customSelected.initialize();
        expect(customSelected.asrProfileId, 'custom');
      } finally {
        for (final center in centers) {
          await center.shutdown();
          center.dispose();
        }
        await temp.delete(recursive: true);
      }
    },
  );
  for (final old in [1, 2, 3, 4]) {
    test(
      'legacy setting $old migrates once; queued jobs retain their preference',
      () async {
        SharedPreferences.setMockInitialValues({});
        final temp = await Directory.systemTemp.createTemp(
          'inference-migration-',
        );
        final storage = AppStorageService(
          locations: () async => StorageLocations(
            platform: StoragePlatform.linux,
            support: Directory(p.join(temp.path, 'support')),
            documents: Directory(p.join(temp.path, 'documents')),
            defaultData: Directory(p.join(temp.path, 'data')),
            executable: Directory(p.join(temp.path, 'bin')),
          ),
        );
        try {
          await storage.initialize();
          final record = await storage.dataRecord('model_center.json');
          await writeStorageJson(record, {'threads': old});
          final center = ModelCenterService(
            storage: storage,
            catalogLoader: () async => [],
          );
          await center.initialize();
          expect(center.asrCpuThreads, old == 2 ? 0 : old);
          await center.save();
          final restored = ModelCenterService(
            storage: storage,
            catalogLoader: () async => [],
          );
          await restored.initialize();
          expect(restored.asrCpuThreads, center.asrCpuThreads);
          final queued = ModelJobSpec.fromJson({
            'profile': const ModelServiceProfile(
              id: 'local',
              name: 'local',
              kind: TranscriptionServiceKind.local,
            ).toJson(),
            'threads': old,
          });
          expect(queued.asrCpuThreads, isNull);
          expect(queued.requestedAsrThreads, old);
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );
  }
  test(
    'local cache identity excludes performance; all old thread keys are readable',
    () {
      const profile = ModelServiceProfile(
        id: 'local',
        name: 'local',
        model: 'sensevoice-small-int8',
        kind: TranscriptionServiceKind.local,
        language: 'en',
      );
      const automatic = ModelJobSpec(
        profile: profile,
        artifactIdentity: 'weights@1',
        asrCpuThreads: 0,
      );
      const manual = ModelJobSpec(
        profile: profile,
        artifactIdentity: 'weights@1',
        threads: 4,
        asrCpuThreads: 12,
      );
      expect(automatic.recognitionFingerprint, manual.recognitionFingerprint);
      for (final threads in [1, 2, 3, 4]) {
        final old = jsonEncode({
          'version': 1,
          'profile': profile.toJson(),
          'artifactIdentity': 'weights@1',
          'threads': threads,
          'segmentation': 'vad-12s-overlap-v1',
        });
        expect(automatic.recognitionCacheFingerprints, contains(old));
      }
      final restored = ModelJobSpec.fromJson(manual.toJson());
      expect(restored.requestedAsrThreads, 12);
      expect(
        const ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'local',
            name: 'local',
            model: 'sensevoice-small-int8',
            kind: TranscriptionServiceKind.local,
            language: 'zh',
          ),
          artifactIdentity: 'weights@1',
        ).recognitionFingerprint,
        isNot(automatic.recognitionFingerprint),
      );
    },
  );
  test('remote job serialization and identity preserve the old contract', () {
    const remote = ModelJobSpec(
      profile: ModelServiceProfile(
        id: 'paid',
        name: 'paid',
        kind: TranscriptionServiceKind.openai,
        model: 'api-model',
      ),
      threads: 3,
    );
    final json = remote.toJson();
    expect(json, isNot(contains('asrCpuThreads')));
    final restored = ModelJobSpec.fromJson({...json, 'asrCpuThreads': 0});
    expect(restored.toJson(), json);
    expect(restored.recognitionFingerprint, remote.recognitionFingerprint);
  });
}
