import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_coordinator.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_models.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'media_cache_service_test.dart' show FakeBackend;
import 'test_dir_cleanup.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String> getApplicationDocumentsPath() async => root;
  @override
  Future<String> getApplicationSupportPath() async => root;
  @override
  Future<String> getTemporaryPath() async => p.join(root, 'temp');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform previousPaths;
  final library = LibraryService();
  final caches = <MediaCacheService>[];
  final backends = <FakeBackend>[];
  const cloud = CloudDriveSourceRef(
    providerId: 'baidu',
    remoteAccountId: 'account',
    driveId: 'drive',
    fileId: 'file',
    revision: 'v1',
  );

  Future<MediaCacheService> cache(String id) async {
    final backend = FakeBackend(root)
      ..failure = StateError('No network is permitted');
    backends.add(backend);
    final result = MediaCacheService(
      backend: backend,
      journal: File(p.join(root.path, '$id-cache.json')),
      observeNetwork: false,
    );
    caches.add(result);
    await result.initialize();
    return result;
  }

  Future<VideoItem> card(String id, String parent, {String? path}) async {
    final item = VideoItem(
      id: id,
      path: path ?? cloud.logicalUri,
      title: 'Cloud Video',
      parentId: parent,
      durationMs: 100000,
      lastPositionMs: 22000,
      lastUpdated: 1,
      hasProbedChapters: true,
      sourceRef: MediaSourceRef(
        kind: MediaSourceKind.cloudDrive,
        value: cloud.logicalUri,
        cloudDrive: cloud,
      ),
    );
    await library.addSingleVideo(
      item,
      useOriginalPath: true,
      reuseExistingItem: false,
    );
    return library.getVideo(id)!;
  }

  FolderSyncCoordinator coordinator(String device) => FolderSyncCoordinator(
    library: library,
    deviceId: device,
    deviceName: device,
    contentKey: (item) async =>
        'cloud:${item.sourceRef!.cloudDrive!.sourceKey}',
  );

  Future<CacheVariant> register(
    MediaCacheService service,
    VideoItem item,
    File file, {
    String quality = '1080',
    String revision = 'v1',
    CacheContent content = CacheContent.media,
  }) async {
    final variant = CacheVariant(
      source: CacheSource.fromItem(item)!,
      quality: CacheQuality(
        id: quality,
        label: '${quality}P',
        revision: revision,
      ),
      path: file.path,
      bytes: await file.length(),
      createdAt: 1,
      managed: false,
      content: content,
    );
    await service.registerLegacy(variant);
    return variant;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('sync_cloud_coordinator_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    SettingsService().copyImportedMediaToPrivateStorage = false;
    library.resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
  });
  tearDown(() async {
    for (final service in caches) {
      await service.shutdown();
    }
    expect(backends.every((backend) => backend.calls == 0), isTrue);
    caches.clear();
    backends.clear();
    MediaCacheService.instance = null;
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = previousPaths;
    await deleteTestTempDir(root);
  });

  test(
    'uncached receiver and another cached quality never republish size zero or change logical metadata',
    () async {
      final from = await library.createCollection('Computer Root', null);
      final to = await library.createCollection('Phone Alias', null);
      final source = await card('source', from.id),
          receiver = await card('receiver', to.id);
      final sourceCache = await cache('source'),
          receiverCache = await cache('receiver');
      final sourceFile = await File(
        p.join(root.path, '1080.mp4'),
      ).writeAsBytes(List.filled(1024, 7));
      await register(sourceCache, source, sourceFile);
      final sender = coordinator('sender'), phone = coordinator('phone');
      const settings = FolderSyncSettings();
      MediaCacheService.instance = sourceCache;
      await sender.capture('group', from.id, settings);
      final sourceState = sender.state('group');
      final node = sourceState.safeNodes.values.singleWhere(
        (node) => node.kind == FolderSyncNodeKind.media,
      );
      final original = sourceState.heads(node.id).single;
      expect(node.size, 1024);
      expect(node.extension, '.mp4');
      final phoneState = phone.state('group', settings: settings)
        ..mergeAll(sourceState.activeEvents);
      for (var round = 0; round < 3; round++) {
        MediaCacheService.instance = receiverCache;
        await phone.capture('group', to.id, settings);
        await phone.apply('group', to.id, settings);
        expect(phoneState.heads(node.id).single.id, original.id);
        expect(phoneState.safeNodes[node.id]!.size, 1024);
        expect(phone.missing('group'), contains(node.id));
        expect(phone.localIssues('group').single.reason, 'cloudNeedsCache');
        MediaCacheService.instance = sourceCache;
        sourceState.mergeAll(phoneState.activeEvents);
        await sender.capture('group', from.id, settings);
        expect(sourceState.heads(node.id).single.id, original.id);
        phoneState.mergeAll(sourceState.activeEvents);
      }
      final lowerFile = await File(
        p.join(root.path, '720.mkv'),
      ).writeAsBytes(List.filled(512, 3));
      await register(receiverCache, receiver, lowerFile, quality: '720');
      MediaCacheService.instance = receiverCache;
      await phone.capture('group', to.id, settings);
      await phone.apply('group', to.id, settings);
      expect(phoneState.heads(node.id).single.id, original.id);
      expect(phoneState.safeNodes[node.id]!.size, 1024);
      expect(phoneState.safeNodes[node.id]!.extension, '.mp4');
      expect(await phone.cloudTransferBytes(receiver), 512);
      expect(phone.missing('group'), isEmpty);
      expect(phone.localIssues('group'), isEmpty);
      final lease = await receiverCache.acquire(receiver);
      expect(lease?.completePath, lowerFile.path);
      await lease!.release();
      expect(receiver.lastPositionMs, 22000);
      expect(library.getCollection(to.id)!.name, 'Phone Alias');
    },
  );

  for (final registered in [false, true]) {
    test(
      'explicit legacy local cloud file becomes offline ready without relabeling existing quality=$registered',
      () async {
        final folder = await library.createCollection('Cloud', null);
        final file = await File(
          p.join(root.path, 'received.mp4'),
        ).writeAsBytes(List.filled(120, 5));
        final item = await card('legacy', folder.id, path: file.path);
        final service = await cache('legacy');
        if (registered) await register(service, item, file);
        MediaCacheService.instance = service;
        final sync = coordinator('local');
        await sync.capture('group', folder.id, const FolderSyncSettings());
        await sync.apply('group', folder.id, const FolderSyncSettings());
        expect(service.variants, hasLength(1));
        expect(
          service.variants.single.quality.id,
          registered ? '1080' : 'original',
        );
        expect(sync.missing('group'), isEmpty);
        expect(sync.localIssues('group'), isEmpty);
        final lease = await service.acquire(item);
        expect(lease?.completePath, file.path);
        await lease!.release();
        await sync.capture('group', folder.id, const FolderSyncSettings());
        expect(service.variants, hasLength(1));
      },
    );
  }

  for (final invalid in ['pendingDelete', 'oldRevision', 'isolatedTrack']) {
    test('legacy repair does not resurrect a $invalid cached path', () async {
      final folder = await library.createCollection('Cloud', null);
      final file = await File(
        p.join(root.path, 'invalid.mp4'),
      ).writeAsBytes(List.filled(120, 5));
      final item = await card('invalid', folder.id, path: file.path);
      final service = await cache('invalid');
      final variant = await register(
        service,
        item,
        file,
        revision: invalid == 'oldRevision' ? 'old' : 'v1',
        content: invalid == 'isolatedTrack'
            ? CacheContent.video
            : CacheContent.media,
      );
      if (invalid == 'pendingDelete') variant.pendingDelete = true;
      MediaCacheService.instance = service;
      final sync = coordinator('local');
      await sync.capture('group', folder.id, const FolderSyncSettings());
      await sync.apply('group', folder.id, const FolderSyncSettings());
      expect(service.variants, hasLength(1));
      expect(service.completeExportVariant(item), isNull);
      expect(sync.localIssues('group').single.reason, 'cloudNeedsCache');
      expect(sync.missing('group'), hasLength(1));
    });
  }
}
