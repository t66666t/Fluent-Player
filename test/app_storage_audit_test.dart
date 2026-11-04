import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_audit.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/storage_audit_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  late Directory root;
  late Directory data;
  late PathProviderPlatform provider;
  final audits = <AppStorageAudit>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('app_storage_audit_');
    data = await Directory(p.join(root.path, 'data')).create();
    final cache = await Directory(p.join(root.path, 'cache')).create();
    provider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Provider(data.path, cache.path);
    SettingsService().largeDataRootPath = data.path;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    await library.init();
  });
  tearDown(() async {
    for (final audit in audits) {
      audit.dispose();
    }
    audits.clear();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = provider;
    await root.delete(recursive: true);
  });
  Future<File> write(String folder, String name) async {
    final file = File(p.join(data.path, folder, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(20, 1));
    await file.setLastModified(
      DateTime.now().subtract(const Duration(hours: 1)),
    );
    return file;
  }

  AppStorageAudit audit({
    BilibiliStreamingService? streaming,
    YtDlpDownloadService? ytDlp,
  }) {
    final result = AppStorageAudit(
      library: library,
      streaming: streaming,
      ytDlp: ytDlp,
    );
    audits.add(result);
    return result;
  }

  test(
    'registered local model roots retain classification and survive cache cleanup',
    () async {
      final previousStorage = AppStorageService.instance;
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.windows,
          support: data,
          documents: data,
          defaultData: data,
          executable: Directory(p.join(root.path, 'program')),
        ),
      );
      AppStorageService.instance = storage;
      try {
        await storage.initialize(configuredRoot: data.path);
        await storage.featureDirectory('local_models');
        await storage.featureDirectory('model_jobs');
        final model = await write(
          p.join('local_models', 'asr-revision'),
          'model.int8.onnx',
        );
        final partial = await write(
          p.join('local_models', 'translation-revision'),
          'model.bin.part',
        );
        final checkpoint = await write('model_jobs', 'asr-key.json.tmp');
        final work = await write('model_jobs', 'service-probe-123.wav');
        final manager = audit();
        final snapshot = await manager.service.scan();
        final entries = {for (final file in snapshot.files) file.path: file};
        expect(entries[model.path]!.category, StorageCategory.models);
        expect(entries[partial.path]!.category, StorageCategory.models);
        expect(entries[checkpoint.path]!.category, StorageCategory.metadata);
        expect(entries[work.path]!.category, StorageCategory.workTemp);
        expect(
          entries[p.join(storage.controlDirectory.path, 'layout.json')]!
              .category,
          StorageCategory.metadata,
        );
        expect(
          snapshot.files.where((file) => file.path == model.path),
          hasLength(1),
        );
        final result = await manager.service.delete(
          StorageDeletionPlan([
            entries[model.path]!,
            entries[partial.path]!,
            entries[checkpoint.path]!,
            entries[work.path]!,
          ], action: StorageCleanupAction.clearCache),
        );
        expect(result.deletedPaths, isEmpty);
        expect(result.skipped, hasLength(4));
        for (final file in [model, partial, checkpoint, work]) {
          expect(await file.exists(), isTrue);
        }
      } finally {
        AppStorageService.instance = previousStorage;
      }
    },
  );

  test(
    'missing optional services do not prevent clearing orphaned media',
    () async {
      final orphan = await write('imported_videos', 'old.mp4');
      final manager = audit();
      expect(manager.deletionBlockedReason(), isNull);
      final snapshot = await manager.service.scan();
      final entry = snapshot.files.singleWhere(
        (file) => file.path == orphan.path,
      );
      final result = await manager.service.delete(StorageDeletionPlan([entry]));
      expect(result.deletedPaths, [orphan.path]);
    },
  );

  test(
    'tool initialization and retained playback session only protect their own files',
    () async {
      final playing = await write(
        p.join('bilibili_stream_cache', 'playing'),
        'video.m4s',
      );
      final unused = await write(
        p.join('bilibili_stream_cache', 'unused'),
        'video.m4s',
      );
      final orphan = await write('imported_videos', 'old.mp4');
      final manager = audit(
        streaming: _Streaming({'playing'}),
        ytDlp: _InitializingYtDlp(),
      );
      expect(manager.deletionBlockedReason(), isNull);
      final snapshot = await manager.service.scan();
      expect(
        snapshot.files
            .singleWhere((file) => file.path == playing.path)
            .canDelete,
        false,
      );
      final result = await manager.service.delete(
        StorageDeletionPlan(
          snapshot.files.where((file) => file.canDelete).toList(),
        ),
      );
      expect(result.deletedPaths, containsAll([unused.path, orphan.path]));
      expect(await playing.exists(), true);
    },
  );

  test(
    'a new adapter reuses the completed inventory for the same library root',
    () async {
      await write('imported_videos', 'old.mp4');
      final first = audit();
      final snapshot = await first.service.scan();
      first.dispose();
      audits.remove(first);
      final second = audit();
      expect(identical(second.service.lastSnapshot, snapshot), true);
    },
  );

  test(
    'a media file referenced after verification is protected on its own',
    () async {
      final media = await write('imported_videos', 'new-card.mp4');
      final unused = await write('imported_videos', 'unused.mp4');
      final manager = audit();
      final snapshot = await manager.service.scan();
      await library.addSingleVideo(
        VideoItem(
          id: 'new-card',
          path: media.path,
          title: 'new card',
          durationMs: 100,
          lastUpdated: 0,
          hasProbedChapters: true,
        ),
        useOriginalPath: true,
      );
      expect(
        await manager.fileDeletionBlockedReason(
          snapshot.files.singleWhere((file) => file.path == media.path),
        ),
        isNotNull,
      );
      expect(
        await manager.fileDeletionBlockedReason(
          snapshot.files.singleWhere((file) => file.path == unused.path),
        ),
        isNull,
      );
    },
  );

  test(
    'an active import retains orphaned files without blocking the entire page',
    () async {
      final media = await write('imported_videos', 'pending.mp4');
      final manager = audit();
      final snapshot = await manager.service.scan();
      library.isImporting.value = true;
      expect(manager.deletionBlockedReason(), isNull);
      expect(
        await manager.fileDeletionBlockedReason(
          snapshot.files.singleWhere((file) => file.path == media.path),
        ),
        contains('正在导入'),
      );
      library.isImporting.value = false;
      expect(
        await manager.fileDeletionBlockedReason(
          snapshot.files.singleWhere((file) => file.path == media.path),
        ),
        isNull,
      );
    },
  );

  test(
    'selected cleanup does not mark the whole inventory refreshed',
    () async {
      final media = await write('imported_videos', 'new-card.mp4');
      final manager = audit();
      final snapshot = await manager.service.scan();
      final entry = snapshot.files.singleWhere(
        (file) => file.path == media.path,
      );
      await library.addSingleVideo(
        VideoItem(
          id: 'new-card',
          path: media.path,
          title: 'new card',
          durationMs: 100,
          lastUpdated: 0,
          hasProbedChapters: true,
        ),
        useOriginalPath: true,
      );
      expect(manager.service.resourcesChanged!(), isTrue);
      final result = await manager.service.delete(StorageDeletionPlan([entry]));
      expect(result.deletedPaths, isEmpty);
      expect(await media.exists(), isTrue);
      expect(manager.service.resourcesChanged!(), isTrue);
    },
  );
}

class _Provider extends PathProviderPlatform {
  _Provider(this.data, this.cache);
  final String data;
  final String cache;
  @override
  Future<String?> getApplicationDocumentsPath() async => data;
  @override
  Future<String?> getApplicationSupportPath() async => data;
  @override
  Future<String?> getTemporaryPath() async => cache;
  @override
  Future<String?> getApplicationCachePath() async => cache;
}

class _Streaming extends ChangeNotifier implements BilibiliStreamingService {
  _Streaming(this.ids);
  final Set<String> ids;
  @override
  Set<String> get cacheItemIdsInUse => ids;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _InitializingYtDlp extends ChangeNotifier
    implements YtDlpDownloadService {
  @override
  bool get isInitializing => true;
  @override
  List<YtDlpTaskRecord> get tasks => [];
  @override
  Future<void> forgetStorageFiles(List<String> paths) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
