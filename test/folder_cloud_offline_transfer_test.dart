import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/media_cache/media_cache_backend.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/features/portable_transfer/portable_folder_transfer.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_materialization_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'media_cache_service_test.dart' show FakeBackend;
import 'test_dir_cleanup.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'temporary');
}

class _OfflineBackend extends FakeBackend {
  _OfflineBackend(super.root);
  int networkCalls = 0;
  @override
  Future<List<CacheQuality>> qualities(CacheSource source) async {
    networkCalls++;
    throw StateError('原网盘账号与链接已不可用');
  }

  @override
  Future<CacheDownloadPlan> resolve(CacheTask task, CancelToken cancel) async {
    networkCalls++;
    throw StateError('迁移不能联网或自动下载');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final priorPaths = PathProviderPlatform.instance;
  late Directory root;
  late MediaCacheService cache;
  late _OfflineBackend backend;
  late PortableTransferService service;
  late PortableFolderTransfer transfer;

  Future<MediaCacheService> newCache(String name) async {
    backend = _OfflineBackend(root);
    final value = MediaCacheService(
      backend: backend,
      journal: File(p.join(root.path, '$name-cache.json')),
      observeNetwork: false,
    );
    MediaCacheService.instance = value;
    await value.initialize();
    return value;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('folder_cloud_offline_');
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    settings.largeDataRootPath = root.path;
    settings.copyImportedMediaToPrivateStorage = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/yt_dlp'),
          (call) async =>
              call.method == 'getLocalAppDataPath' ? root.path : null,
        );
    library.resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 120000;
    cache = await newCache('sender');
    service = PortableTransferService.forTesting();
    transfer = PortableFolderTransfer(service: service);
  });

  tearDown(() async {
    service.dispose();
    await cache.shutdown();
    MediaCacheService.instance = null;
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = priorPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.example.video_player_app/yt_dlp'),
          null,
        );
    expect(MaterializedMediaLease.pathsInUse, isEmpty);
    await deleteTestTempDir(root);
  });

  Future<CacheVariant> register(
    VideoItem item,
    String name, {
    String revision = 'revision-2',
    String quality = '1080',
    CacheContent content = CacheContent.media,
  }) async {
    final file = await File(
      p.join(root.path, name),
    ).writeAsString('bytes:$name');
    final variant = CacheVariant(
      source: CacheSource.fromItem(item)!,
      quality: CacheQuality(
        id: quality,
        label: quality,
        height: int.tryParse(quality),
        revision: revision,
      ),
      path: file.path,
      bytes: await file.length(),
      createdAt: 1,
      managed: false,
      content: content,
    );
    await cache.registerLegacy(variant);
    return variant;
  }

  Future<VideoItem> addCloud(String parent, {bool audio = false}) async {
    const ref = CloudDriveSourceRef(
      providerId: 'baidu',
      remoteAccountId: 'unavailable-account',
      driveId: 'drive',
      fileId: 'cloud-original',
      revision: 'revision-2',
    );
    final item = VideoItem(
      id: 'cloud-card',
      path: ref.logicalUri,
      title: '网盘离线媒体',
      parentId: parent,
      sourceRef: MediaSourceRef(
        value: ref.logicalUri,
        kind: MediaSourceKind.cloudDrive,
        cloudDrive: ref,
      ),
      type: audio ? MediaType.audio : MediaType.video,
      lastPositionMs: 23456,
      durationMs: 120000,
      lastUpdated: 1,
      hasProbedChapters: true,
    );
    await library.addSingleVideo(item, reuseExistingItem: false);
    return item;
  }

  Future<VideoItem> receiveDirect(
    PortableFolderFiles plan,
    String sourceId,
  ) async {
    final incoming = Directory(p.join(root.path, 'incoming-files'));
    final hashes = <String, String>{};
    for (final file in plan.files) {
      final copy = File(
        p.joinAll([incoming.path, ...file.relativePath.split('/')]),
      );
      await copy.parent.create(recursive: true);
      await File(file.path).copy(copy.path);
      hashes[file.relativePath] = sha256
          .convert(await copy.readAsBytes())
          .toString();
    }
    final senderBackend = backend;
    await plan.release();
    await cache.shutdown();
    cache = await newCache('receiver');
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    final received = await transfer.importReceivedFolder(
      library: library,
      packagePath: incoming.path,
      receivedDirectory: incoming,
      receivedManifest: {...plan.manifest, 'checksums': hashes},
      originDeviceId: 'sender',
      sourceCollectionId: sourceId,
    );
    final item = library.mediaInFolderTree(received.collectionId).single;
    expect(senderBackend.networkCalls, 0);
    expect(backend.networkCalls, 0);
    expect(p.isWithin(incoming.path, item.path), isFalse);
    await incoming.delete(recursive: true);
    return item;
  }

  for (final audio in [false, true]) {
    for (final local in [false, true]) {
      test(
        '${audio ? 'audio' : 'video'} ${local ? 'local cloud-origin' : 'logical cloud'} transfers offline without a login',
        () async {
          final folder = await library.createCollection('发送', null);
          final original = await addCloud(folder.id, audio: audio);
          final variant = await register(
            original,
            audio ? 'audio.m4a' : 'video.mp4',
          );
          if (local) original.path = variant.path;
          final expected = await File(variant.path).readAsBytes();
          final plan = await transfer.prepareDirectFiles(
            library: library,
            collectionId: folder.id,
          );
          final record =
              (plan.manifest['snapshot']['videos'] as List).single as Map;
          expect(record['isOnline'], isFalse);
          expect(record['cachedCloudMedia'], isNull);
          expect(record['cloudDownloadQuality']['id'], '1080');
          expect((record['video'] as Map)['path'], startsWith('@asset:'));
          expect((record['video'] as Map)['lastPositionMs'], 23456);
          expect(MaterializedMediaLease.isPathInUse(variant.path), isTrue);
          final item = await receiveDirect(plan, folder.id);
          await File(variant.path).delete();
          expect(
            item.sourceRef?.cloudDrive?.sourceKey,
            original.sourceRef!.cloudDrive!.sourceKey,
          );
          expect(item.type, original.type);
          // Folder sync applies causally tracked progress after file import.
          expect(item.lastPositionMs, 0);
          final lease = await cache.acquire(item);
          expect(lease, isNotNull);
          expect(await File(lease!.completePath!).readAsBytes(), expected);
          await lease.release();
          expect(backend.networkCalls, 0);
        },
      );
    }
  }

  test(
    'uncached, stale and isolated cloud resources require a complete cache and release earlier sources',
    () async {
      final folder = await library.createCollection('发送', null);
      final first = await File(
        p.join(root.path, 'local.mp4'),
      ).writeAsString('local complete');
      await library.addSingleVideo(
        VideoItem(
          id: 'first',
          path: first.path,
          title: '本地',
          parentId: folder.id,
          durationMs: 1,
          lastUpdated: 1,
          hasProbedChapters: true,
        ),
        useOriginalPath: true,
      );
      final cloud = await addCloud(folder.id);
      await register(cloud, 'old.mp4', revision: 'revision-1');
      await register(cloud, 'track.mp4', content: CacheContent.video);
      await expectLater(
        transfer.prepareDirectFiles(library: library, collectionId: folder.id),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('缓存完成'),
          ),
        ),
      );
      expect(MaterializedMediaLease.pathsInUse, isEmpty);
      expect(backend.networkCalls, 0);
    },
  );

  test(
    'selected delta is not blocked by an unrelated uncached cloud card',
    () async {
      final folder = await library.createCollection('发送', null);
      final media = await File(
        p.join(root.path, 'local.mp4'),
      ).writeAsString('local complete');
      await library.addSingleVideo(
        VideoItem(
          id: 'selected',
          path: media.path,
          title: '本地',
          parentId: folder.id,
          durationMs: 1,
          lastUpdated: 1,
          hasProbedChapters: true,
        ),
        useOriginalPath: true,
      );
      await addCloud(folder.id);
      final plan = await transfer.prepareDirectFiles(
        library: library,
        collectionId: folder.id,
        includeMediaIds: {'selected'},
      );
      expect(
        (plan.manifest['snapshot']['videos'] as List).single['exportId'],
        'selected',
      );
      expect(MaterializedMediaLease.isPathInUse(media.path), isTrue);
      await plan.release();
      await plan.release();
      expect(MaterializedMediaLease.pathsInUse, isEmpty);
    },
  );

  test(
    'Bilibili active cache stays online while owned download is protected until source release',
    () async {
      final folder = await library.createCollection('发送', null);
      VideoItem bili(String id) => VideoItem(
        id: id,
        title: id,
        parentId: folder.id,
        path: 'bilibili://stream/BVsame/7',
        sourceRef: const MediaSourceRef(
          value: 'BVsame',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BVsame',
          cid: 7,
        ),
        isBilibiliExported: true,
        durationMs: 1,
        lastUpdated: 1,
        hasProbedChapters: true,
      );
      final online = bili('online');
      final downloaded = bili('downloaded');
      final owned = await register(downloaded, 'download.mp4', revision: 'cid');
      downloaded.bilibiliDownloadPath = owned.path;
      final optional = await register(
        online,
        'active-cache.mp4',
        quality: '2160',
        revision: 'cid',
      );
      await library.addSingleVideo(online, reuseExistingItem: false);
      await library.addSingleVideo(downloaded, reuseExistingItem: false);
      final plan = await transfer.prepareDirectFiles(
        library: library,
        collectionId: folder.id,
      );
      final records = (plan.manifest['snapshot']['videos'] as List).cast<Map>();
      expect(
        records.singleWhere((row) => row['exportId'] == online.id)['isOnline'],
        isTrue,
      );
      expect(
        records.singleWhere(
          (row) => row['exportId'] == downloaded.id,
        )['isOnline'],
        isFalse,
      );
      expect(plan.files.any((file) => file.path == optional.path), isFalse);
      expect(plan.files.any((file) => file.path == owned.path), isTrue);
      await cache.deleteVariant(owned.id);
      expect(await File(owned.path).exists(), isTrue);
      await plan.release();
      expect(await File(owned.path).exists(), isFalse);
    },
  );

  test(
    'fallback folder package carries offline cloud registration and releases source protection',
    () async {
      final folder = await library.createCollection('发送', null);
      final cloud = await addCloud(folder.id);
      final variant = await register(
        cloud,
        'original.mp4',
        quality: 'original',
      );
      final prepared = await transfer.prepareFolderPackage(
        library: library,
        collectionId: folder.id,
        outputPath: p.join(root.path, 'legacy.fluentpack'),
      );
      expect(MaterializedMediaLease.pathsInUse, isEmpty);
      await cache.shutdown();
      cache = await newCache('receiver');
      library.resetLibraryForTesting();
      library.skipImportSidecarWorkForTesting = true;
      final result = await transfer.importReceivedFolder(
        library: library,
        packagePath: prepared.path,
        originDeviceId: 'sender',
        sourceCollectionId: folder.id,
      );
      await File(variant.path).delete();
      final restored = library.mediaInFolderTree(result.collectionId).single;
      final lease = await cache.acquire(restored);
      expect(lease, isNotNull);
      expect(
        await File(lease!.completePath!).readAsString(),
        'bytes:original.mp4',
      );
      await lease.release();
      expect(backend.networkCalls, 0);
    },
  );

  test(
    'unregistered local cloud-origin file is offline media and estimate releases its hold',
    () async {
      final folder = await library.createCollection('发送', null);
      final cloud = await addCloud(folder.id);
      final local = await File(
        p.join(root.path, 'local-original.mp4'),
      ).writeAsString('owned local original');
      cloud.path = local.path;
      final estimate = await transfer.estimateFolder(
        library: library,
        collectionId: folder.id,
      );
      expect(estimate.totalBytes, await local.length());
      expect(MaterializedMediaLease.pathsInUse, isEmpty);
      final plan = await transfer.prepareDirectFiles(
        library: library,
        collectionId: folder.id,
      );
      final record = (plan.manifest['snapshot']['videos'] as List).single;
      expect(record['cloudDownloadQuality']['id'], 'original');
      final restored = await receiveDirect(plan, folder.id);
      final lease = await cache.acquire(restored);
      expect(lease, isNotNull);
      expect(
        await File(lease!.completePath!).readAsString(),
        'owned local original',
      );
      await lease.release();
    },
  );

  test(
    'cancellation during direct preparation releases complete cloud source leases',
    () async {
      final folder = await library.createCollection('发送', null);
      final cloud = await addCloud(folder.id);
      final variant = await register(cloud, 'source.mp4');
      cloud.thumbnailPath = (await File(
        p.join(root.path, 'cover.jpg'),
      ).writeAsString('cover')).path;
      var checks = 0;
      await expectLater(
        transfer.prepareDirectFiles(
          library: library,
          collectionId: folder.id,
          isCancelled: () => ++checks > 1,
        ),
        throwsA(isA<PortableExportCancelled>()),
      );
      expect(MaterializedMediaLease.pathsInUse, isEmpty);
      await cache.deleteVariant(variant.id);
      expect(await File(variant.path).exists(), isFalse);
    },
  );

  test(
    'legacy local Bilibili source without a cache entry restores an owned offline file',
    () async {
      final folder = await library.createCollection('发送', null);
      final local = await File(
        p.join(root.path, 'legacy.mp4'),
      ).writeAsString('legacy Bilibili bytes');
      final item = VideoItem(
        id: 'legacy-bili',
        title: '旧下载',
        parentId: folder.id,
        path: local.path,
        sourceRef: const MediaSourceRef(
          value: 'BVlegacy',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BVlegacy',
          cid: 9,
        ),
        durationMs: 1,
        lastUpdated: 1,
        hasProbedChapters: true,
      );
      await library.addSingleVideo(
        item,
        useOriginalPath: true,
        reuseExistingItem: false,
      );
      final plan = await transfer.prepareDirectFiles(
        library: library,
        collectionId: folder.id,
      );
      final record = (plan.manifest['snapshot']['videos'] as List).single;
      expect(record['bilibiliDownloadQuality']['id'], 'legacy');
      final restored = await receiveDirect(plan, folder.id);
      expect(restored.bilibiliDownloadPath, isNotNull);
      expect(restored.path, startsWith('bilibili://'));
      final lease = await cache.acquire(restored);
      expect(lease, isNotNull);
      expect(
        await File(lease!.completePath!).readAsString(),
        'legacy Bilibili bytes',
      );
      await lease.release();
    },
  );

  for (final sameSource in [true, false]) {
    test(
      sameSource
          ? 'repeat cloud receipt repairs a missing cache registration without replacing the card or progress'
          : 'equal local bytes are shared without replacing a cloud card identity with an unrelated local card',
      () async {
        final folder = await library.createCollection('发送', null);
        final cloud = await addCloud(folder.id);
        final variant = await register(cloud, 'original.mp4');
        final bytes = await File(variant.path).readAsBytes();
        final plan = await transfer.prepareDirectFiles(
          library: library,
          collectionId: folder.id,
        );
        final incoming = Directory(p.join(root.path, 'incoming-repair'));
        final hashes = <String, String>{};
        for (final file in plan.files) {
          final target = File(
            p.joinAll([incoming.path, ...file.relativePath.split('/')]),
          );
          await target.parent.create(recursive: true);
          await File(file.path).copy(target.path);
          hashes[file.relativePath] = sha256
              .convert(await target.readAsBytes())
              .toString();
        }
        await plan.release();
        await cache.shutdown();
        cache = await newCache('receiver');
        library.resetLibraryForTesting();
        library.skipImportSidecarWorkForTesting = true;
        final targetFolder = await library.createCollection('接收端现有', null);
        final existingFile = await File(
          p.join(root.path, 'receiver-existing.mp4'),
        ).writeAsBytes(bytes);
        final existing = VideoItem(
          id: 'existing-receiver',
          path: existingFile.path,
          title: '现有条目',
          parentId: targetFolder.id,
          sourceRef: sameSource ? cloud.sourceRef : null,
          durationMs: 120000,
          lastPositionMs: 777,
          lastUpdated: 1,
          hasProbedChapters: true,
        );
        await library.addSingleVideo(existing, useOriginalPath: true);
        expect(cache.variants, isEmpty);
        if (!sameSource) {
          await expectLater(
            transfer.importReceivedFolder(
              library: library,
              packagePath: incoming.path,
              receivedDirectory: incoming,
              receivedManifest: {...plan.manifest, 'checksums': hashes},
              originDeviceId: 'sender',
              sourceCollectionId: folder.id,
              existingTargetCollectionId: targetFolder.id,
              beforeExtraLocalCopy: (needed) async {
                expect(needed, bytes.length);
                throw const FormatException('接收空间不足');
              },
            ),
            throwsA(isA<FormatException>()),
          );
          expect(await File(existing.path).readAsBytes(), bytes);
          expect(library.mediaInFolderTree(targetFolder.id), hasLength(1));
          expect(cache.variants, isEmpty);
        }
        var extraCopyChecks = 0;
        final received = await transfer.importReceivedFolder(
          library: library,
          packagePath: incoming.path,
          receivedDirectory: incoming,
          receivedManifest: {...plan.manifest, 'checksums': hashes},
          originDeviceId: 'sender',
          sourceCollectionId: folder.id,
          existingTargetCollectionId: targetFolder.id,
          beforeExtraLocalCopy: (needed) async {
            expect(needed, bytes.length);
            extraCopyChecks++;
          },
        );
        expect(extraCopyChecks, sameSource ? 0 : 1);
        final restored = library.getVideo(
          received.sourceToLocalIds[cloud.id]!,
        )!;
        expect(
          restored.sourceRef?.cloudDrive?.sourceKey,
          cloud.sourceRef!.cloudDrive!.sourceKey,
        );
        if (sameSource) {
          expect(restored.id, existing.id);
          expect(restored.lastPositionMs, 777);
          expect(library.mediaInFolderTree(targetFolder.id), hasLength(1));
        } else {
          expect(restored.id, isNot(existing.id));
          expect(library.getVideo(existing.id)?.lastPositionMs, 777);
          expect(library.mediaInFolderTree(targetFolder.id), hasLength(2));
        }
        await incoming.delete(recursive: true);
        final lease = await cache.acquire(restored);
        expect(lease, isNotNull);
        expect(await File(lease!.completePath!).readAsBytes(), bytes);
        await lease.release();
        if (!sameSource) {
          expect(restored.path, isNot(existing.path));
          final imported = cache.variants.singleWhere(
            (variant) => variant.source.itemId == restored.id,
          );
          await cache.deleteVariant(imported.id);
          expect(await File(existing.path).readAsBytes(), bytes);
          expect(library.getVideo(existing.id)?.path, existing.path);
        }
        expect(backend.networkCalls, 0);
      },
    );
  }
}
