import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_folder_transfer.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_models.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_state.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'test_dir_cleanup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late LibraryService library;
  late PortableTransferService service;
  late PortableFolderTransfer transfer;
  final previousProvider = PathProviderPlatform.instance;
  var nextPackage = 0;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('portable_identity_');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = temp.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    service = PortableTransferService.forTesting();
    transfer = PortableFolderTransfer(service: service);
  });
  tearDown(() async {
    service.dispose();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = previousProvider;
    await deleteTestTempDir(temp);
  });

  Future<VideoItem> add(String parent, String id, List<int> bytes) async {
    final file = File(p.join(temp.path, '$id.mp4'));
    await file.writeAsBytes(bytes);
    final video = VideoItem(
      id: id,
      path: file.path,
      title: id,
      durationMs: 100000,
      lastUpdated: 1,
      parentId: parent,
      hasProbedChapters: true,
    );
    await library.addSingleVideo(video, useOriginalPath: true);
    return video;
  }

  Future<PortablePreparedFolderPackage> pack(
    String root,
    Map<String, String> ids, {
    Set<String>? include,
    Set<String> skip = const {},
    bool sidecars = true,
    Map<String, dynamic> metadata = const {},
  }) => transfer.prepareFolderPackage(
    library: library,
    collectionId: root,
    outputPath: p.join(temp.path, 'package-${nextPackage++}.fluentpack'),
    stableIds: ids,
    includeMediaIds: include,
    includeSidecars: sidecars,
    skipContentKeys: skip,
    syncMetadata: metadata,
  );

  Future<PortableReceivedFolder> receive(
    PortablePreparedFolderPackage package, {
    PortableReceivedFolder? previous,
    Set<String> suppressed = const {},
    Set<String> protected = const {},
    PortableFolderProtection? resolveProtected,
    bool reconcile = true,
  }) => transfer.importReceivedFolder(
    library: library,
    packagePath: package.path,
    originDeviceId: 'remote',
    sourceCollectionId: package.collectionId,
    existingTargetCollectionId: previous?.collectionId,
    existingLocalIds: previous?.stableToLocalIds ?? {},
    suppressedNodeIds: suppressed,
    protectedNodeIds: protected,
    resolveProtectedNodeIds: resolveProtected,
    reconcileStructure: reconcile,
  );

  Future<void> restartFromCrash(
    String libraryState,
    String receiptsState,
  ) async {
    service.dispose();
    service = PortableTransferService.forTesting();
    transfer = PortableFolderTransfer(service: service);
    library.resetLibraryForTesting();
    await File(p.join(temp.path, 'library.json')).writeAsString(libraryState);
    await File(
      p.join(temp.path, 'library.json.bak'),
    ).writeAsString(libraryState);
    await File(
      p.join(temp.path, 'portable_transfer', 'folder_receipts_v1.json'),
    ).writeAsString(receiptsState);
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    await service.initialize(library: library);
  }

  test(
    'stable IDs repeat without duplicate cards and preserve local activity',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final package = await pack(
        source.id,
        ids,
        metadata: {
          'events': [
            {
              'nodeId': 'movie',
              'clock': {'remote': 2},
            },
          ],
        },
      );
      final first = await receive(package);
      final localId = first.stableToLocalIds['movie']!;
      library.getVideo(localId)!.lastPositionMs = 42000;
      library.seedMediaActivityForTesting(
        MediaActivityRecord(
          mediaId: localId,
          completed: true,
          continueEnrolled: true,
          lastPlayedAtMs: 20,
        ),
      );
      final again = await receive(package, previous: first);
      expect(again.stableToLocalIds, first.stableToLocalIds);
      expect(library.mediaInFolderTree(first.collectionId), hasLength(1));
      expect(library.getVideo(localId)!.lastPositionMs, 42000);
      expect(library.mediaActivity(localId)?.completed, true);
      expect(again.syncMetadata['events'], hasLength(1));
    },
  );

  test(
    'suppressed recycled media stays unchanged after a complete resend',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final localId = first.stableToLocalIds['movie']!;
      final local = library.getVideo(localId)!;
      local.lastPositionMs = 42000;
      library.seedMediaActivityForTesting(
        MediaActivityRecord(
          mediaId: localId,
          completed: true,
          continueEnrolled: true,
          lastPlayedAtMs: 20,
        ),
      );
      await library.recycleSyncItem(localId);
      final before = local.toJson();
      final originalIds = library.storageVideos.map((item) => item.id).toSet();
      await File(video.path).writeAsBytes([4, 3, 2, 1]);
      video.title = '远端改名';
      // A cleaner may remove the inactive metadata directory between sends.
      await Directory(
        p.join(temp.path, 'portable_transfer'),
      ).delete(recursive: true);
      final result = await receive(
        await pack(source.id, ids),
        previous: first,
        suppressed: {'movie'},
      );
      expect(result.stableToLocalIds['movie'], localId);
      expect(library.getVideo(localId), same(local));
      expect(library.getVideo(localId)!.toJson(), before);
      expect(library.getVideo(localId)!.isRecycled, true);
      expect(library.getVideo(localId)!.lastPositionMs, 42000);
      expect(library.mediaActivity(localId)?.completed, true);
      expect(library.mediaInFolderTree(first.collectionId), isEmpty);
      expect(library.storageVideos.map((item) => item.id).toSet(), originalIds);
      expect(result.importedMediaCount, 0);
      expect(
        await File(
          p.join(temp.path, 'portable_transfer', 'folder_receipts_v1.json'),
        ).exists(),
        true,
      );
    },
  );

  test(
    'suppressed folder blocks existing and newly added descendants on full resend',
    () async {
      final source = await library.createCollection('课程', null);
      final a = await library.createCollection('A', source.id);
      final video = await add(a.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', a.id: 'a', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final localFolder = library.getCollection(first.stableToLocalIds['a']!)!;
      final localVideo = library.getVideo(first.stableToLocalIds['movie']!)!;
      localVideo.lastPositionMs = 27000;
      await library.recycleSyncItem(localFolder.id);
      final folderBefore = localFolder.toJson();
      final videoBefore = localVideo.toJson();
      await library.applySyncItemMetadata(
        a.id,
        name: '远端改名',
        parentId: source.id,
      );
      final b = await library.createCollection('新增子文件夹', a.id);
      final c = await library.createCollection('新增孙文件夹', b.id);
      final added = await add(c.id, 'new-lesson', [8, 7, 6, 5]);
      ids.addAll({b.id: 'b', c.id: 'c', added.id: 'new-movie'});
      final folderIds = library.storageCollections
          .map((item) => item.id)
          .toSet();
      final mediaIds = library.storageVideos.map((item) => item.id).toSet();
      final package = await pack(source.id, ids);
      final result = await receive(package, previous: first, suppressed: {'a'});
      expect(result.stableToLocalIds, first.stableToLocalIds);
      expect(library.getCollection(localFolder.id), same(localFolder));
      expect(localFolder.toJson(), folderBefore);
      expect(library.getVideo(localVideo.id), same(localVideo));
      expect(localVideo.toJson(), videoBefore);
      expect(library.getContents(first.collectionId), isEmpty);
      expect(
        library.storageCollections.map((item) => item.id).toSet(),
        folderIds,
      );
      expect(library.storageVideos.map((item) => item.id).toSet(), mediaIds);
      expect(result.importedMediaCount, 0);

      // Suppressing the linked root must likewise retain its recycled ID.
      final root = library.getCollection(first.collectionId)!;
      await library.recycleSyncItem(root.id);
      final rootBefore = root.toJson();
      final rootSuppressed = await receive(
        package,
        previous: first,
        suppressed: {'root'},
      );
      expect(rootSuppressed.collectionId, root.id);
      expect(rootSuppressed.stableToLocalIds, first.stableToLocalIds);
      expect(library.getCollection(root.id), same(root));
      expect(root.toJson(), rootBefore);
      expect(library.storageVideos.map((item) => item.id).toSet(), mediaIds);
    },
  );

  test(
    'incoming causal content conflict protects local media until explicitly resolved',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final localId = first.stableToLocalIds['movie']!;
      final local = library.getVideo(localId)!;
      final baseNode = FolderSyncNode(
        id: 'movie',
        parentId: 'root',
        kind: FolderSyncNodeKind.media,
        name: video.title,
        contentKey: 'sha256:4:${sha256.convert([1, 2, 3, 4])}',
        size: 4,
        extension: '.mp4',
      );
      final catalog = FolderSyncState(groupId: 'group', deviceId: 'local');
      catalog.mergeAll([
        _folderEvent(
          'root-initial',
          const FolderSyncNode(
            id: 'root',
            kind: FolderSyncNodeKind.folder,
            name: '课程',
          ),
        ),
        _folderEvent('movie-initial', baseNode),
      ]);
      catalog.markApplied('root', localId: first.collectionId);
      catalog.markApplied('movie', localId: localId);
      await File(local.path).writeAsBytes([9, 9, 9, 9]);
      local.lastPositionMs = 44000;
      local.title = '本机名称';
      final localEvent = _folderEvent(
        'local-edit',
        baseNode.copyWith(
          name: local.title,
          contentKey: 'sha256:4:${sha256.convert([9, 9, 9, 9])}',
        ),
        device: 'local',
        clock: {'remote': 1, 'local': 1},
      );
      catalog.merge(localEvent);
      expect(catalog.issues, isEmpty);
      await File(video.path).writeAsBytes([4, 3, 2, 1]);
      video.title = '远端名称';
      final remoteEvent = _folderEvent(
        'remote-edit',
        baseNode.copyWith(
          name: video.title,
          contentKey: 'sha256:4:${sha256.convert([4, 3, 2, 1])}',
        ),
        clock: {'remote': 2},
      );
      final package = await pack(
        source.id,
        ids,
        metadata: {
          'events': [remoteEvent.toJson()],
        },
      );
      final before = local.toJson();
      final mediaIds = library.storageVideos.map((item) => item.id).toSet();
      var checks = 0;
      Future<Set<String>> protect(Map<String, dynamic> metadata) async {
        await Future<void>.delayed(Duration.zero);
        checks++;
        if (checks == 1) {
          expect(library.getVideo(localId)!.toJson(), before);
          expect(
            library.storageVideos.map((item) => item.id).toSet(),
            mediaIds,
          );
        }
        catalog.mergeAll([
          for (final raw in metadata['events'] as List)
            FolderSyncEvent.fromJson(Map<String, dynamic>.from(raw as Map)),
        ]);
        return catalog.issues.map((issue) => issue.nodeId).toSet();
      }

      final blocked = await receive(
        package,
        previous: first,
        reconcile: false,
        resolveProtected: protect,
      );
      expect(checks, 1);
      expect(catalog.issues.single.nodeId, 'movie');
      expect(catalog.issues.single.kind, FolderSyncIssueKind.contentConflict);
      expect(blocked.stableToLocalIds['movie'], localId);
      expect(blocked.importedMediaCount, 0);
      expect(blocked.syncMetadata['events'], [remoteEvent.toJson()]);
      expect(library.getVideo(localId), same(local));
      expect(library.getVideo(localId)!.toJson(), before);
      expect(await File(local.path).readAsBytes(), [9, 9, 9, 9]);
      expect(library.storageVideos.map((item) => item.id).toSet(), mediaIds);

      catalog.resolve('movie', remoteEvent.id);
      expect(catalog.issues, isEmpty);
      final resolved = await receive(
        package,
        previous: blocked,
        reconcile: false,
        resolveProtected: protect,
      );
      expect(checks, 2);
      expect(resolved.stableToLocalIds['movie'], localId);
      final current = library.getVideo(localId)!;
      expect(await File(current.path).readAsBytes(), [4, 3, 2, 1]);
      expect(current.lastPositionMs, 44000);
      // Structural changes are applied by the safe catalogue, not the packet.
      expect(current.title, '本机名称');
      final backup = library.storageVideos.singleWhere(
        (item) => item.isRecycled,
      );
      expect(await File(backup.path).readAsBytes(), [9, 9, 9, 9]);
    },
  );

  test(
    'protected folder preserves its tree and blocks new descendants without suppressing later receives',
    () async {
      final source = await library.createCollection('课程', null);
      final a = await library.createCollection('A', source.id);
      final video = await add(a.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', a.id: 'a', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final localFolder = library.getCollection(first.stableToLocalIds['a']!)!;
      final localVideo = library.getVideo(first.stableToLocalIds['movie']!)!;
      localVideo.lastPositionMs = 27000;
      final folderBefore = localFolder.toJson();
      final videoBefore = localVideo.toJson();
      await library.applySyncItemMetadata(
        a.id,
        name: '远端目录名',
        parentId: source.id,
      );
      await File(video.path).writeAsBytes([4, 3, 2, 1]);
      final b = await library.createCollection('新增子文件夹', a.id);
      final added = await add(b.id, 'new-lesson', [8, 7, 6, 5]);
      ids.addAll({b.id: 'b', added.id: 'new-movie'});
      final folderIds = library.storageCollections
          .map((item) => item.id)
          .toSet();
      final mediaIds = library.storageVideos.map((item) => item.id).toSet();
      final package = await pack(source.id, ids);
      final blocked = await receive(package, previous: first, protected: {'a'});
      expect(blocked.stableToLocalIds, first.stableToLocalIds);
      expect(localFolder.toJson(), folderBefore);
      expect(localVideo.toJson(), videoBefore);
      expect(await File(localVideo.path).readAsBytes(), [1, 2, 3, 4]);
      expect(
        library.storageCollections.map((item) => item.id).toSet(),
        folderIds,
      );
      expect(library.storageVideos.map((item) => item.id).toSet(), mediaIds);
      final resolved = await receive(package, previous: blocked);
      expect(resolved.stableToLocalIds['a'], localFolder.id);
      expect(library.getCollection(localFolder.id)!.name, '远端目录名');
      expect(resolved.stableToLocalIds['b'], isNotNull);
      expect(resolved.stableToLocalIds['new-movie'], isNotNull);
      expect(await File(library.getVideo(localVideo.id)!.path).readAsBytes(), [
        4,
        3,
        2,
        1,
      ]);
    },
  );

  test(
    'protection validation failure leaves the receiving library untouched',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final local = library.getVideo(first.stableToLocalIds['movie']!)!;
      final before = local.toJson();
      await File(video.path).writeAsBytes([4, 3, 2, 1]);
      final folderIds = library.storageCollections
          .map((item) => item.id)
          .toSet();
      final mediaIds = library.storageVideos.map((item) => item.id).toSet();
      final package = await pack(source.id, ids);
      await expectLater(
        receive(
          package,
          previous: first,
          resolveProtected: (_) async => throw const FormatException('目录事件无效'),
        ),
        throwsFormatException,
      );
      expect(local.toJson(), before);
      expect(await File(local.path).readAsBytes(), [1, 2, 3, 4]);
      expect(
        library.storageCollections.map((item) => item.id).toSet(),
        folderIds,
      );
      expect(library.storageVideos.map((item) => item.id).toSet(), mediaIds);
      expect(service.storageTemporaryDirectoriesInUse, isEmpty);
    },
  );

  test(
    'crash after publishing a staged revision rolls it back before retry without duplicate cards',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final localId = first.stableToLocalIds['movie']!;
      final local = library.getVideo(localId)!;
      local.lastPositionMs = 44000;
      library.seedMediaActivityForTesting(
        MediaActivityRecord(mediaId: localId, completed: true),
      );
      await library.renameItem(localId, local.title);
      final oldPath = local.path;
      final originalIds = library.storageVideos.map((item) => item.id).toSet();
      await File(video.path).writeAsBytes([4, 3, 2, 1]);
      final package = await pack(source.id, ids);
      String? libraryCheckpoint, journalCheckpoint, stagedId;
      void checkpoint() {
        if (libraryCheckpoint != null) return;
        final staged = library.storageVideos
            .where((item) => !originalIds.contains(item.id) && !item.isRecycled)
            .firstOrNull;
        if (staged == null) return;
        libraryCheckpoint = File(
          p.join(temp.path, 'library.json'),
        ).readAsStringSync();
        journalCheckpoint = File(
          p.join(temp.path, 'portable_transfer', 'folder_receipts_v1.json'),
        ).readAsStringSync();
        stagedId = staged.id;
      }

      library.addListener(checkpoint);
      try {
        await receive(package, previous: first);
      } finally {
        library.removeListener(checkpoint);
      }
      expect(libraryCheckpoint, isNotNull);
      final journal = jsonDecode(journalCheckpoint!) as Map;
      final sourceKey = jsonEncode(['remote', source.id]);
      expect((journal['mappings'] as Map)[sourceKey][video.id], localId);
      expect((journal['staging'] as Map)[sourceKey][video.id], {
        'existingId': localId,
        'stagedId': stagedId,
      });

      // Recovery must explicitly recycle its journaled staging revision before
      // permanent deletion; ordinary live cards remain protected by the guard.
      final stagedAtCrash = (jsonDecode(libraryCheckpoint!)['videos'] as List)
          .cast<Map>()
          .singleWhere((record) => record['id'] == stagedId);
      expect(stagedAtCrash['isRecycled'], isFalse);

      // Restore the exact files present at addSingleVideo's first notification,
      // rather than cancelling the import and exercising its normal rollback.
      await restartFromCrash(libraryCheckpoint!, journalCheckpoint!);
      expect(library.getVideo(stagedId!), isNull);
      expect(library.getVideo(localId)!.path, oldPath);
      expect(library.getVideo(localId)!.lastPositionMs, 44000);
      expect(library.mediaActivity(localId)?.completed, true);
      expect(await File(oldPath).readAsBytes(), [1, 2, 3, 4]);
      final retried = await receive(package, previous: first);
      expect(retried.stableToLocalIds['movie'], localId);
      expect(library.mediaInFolderTree(first.collectionId).single.id, localId);
      expect(library.getVideo(localId)!.lastPositionMs, 44000);
      expect(library.mediaActivity(localId)?.completed, true);
      expect(await File(library.getVideo(localId)!.path).readAsBytes(), [
        4,
        3,
        2,
        1,
      ]);
      expect(
        library.storageVideos.where((item) => item.isRecycled),
        hasLength(1),
      );
      expect(
        library.storageVideos
            .where((item) => !item.isRecycled)
            .map((item) => item.id)
            .toSet(),
        originalIds,
      );
    },
  );

  test(
    'crash after a revision commit retains its original ID and only one old version',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final localId = first.stableToLocalIds['movie']!;
      final oldPath = library.getVideo(localId)!.path;
      library.getVideo(localId)!.lastPositionMs = 28000;
      await File(video.path).writeAsBytes([4, 3, 2, 1]);
      final package = await pack(source.id, ids);
      String? libraryCheckpoint, journalCheckpoint;
      void checkpoint() {
        if (libraryCheckpoint != null ||
            library.getVideo(localId)!.path == oldPath) {
          return;
        }
        libraryCheckpoint = File(
          p.join(temp.path, 'library.json'),
        ).readAsStringSync();
        journalCheckpoint = File(
          p.join(temp.path, 'portable_transfer', 'folder_receipts_v1.json'),
        ).readAsStringSync();
      }

      library.addListener(checkpoint);
      try {
        await receive(package, previous: first);
      } finally {
        library.removeListener(checkpoint);
      }
      expect(libraryCheckpoint, isNotNull);
      expect((jsonDecode(journalCheckpoint!) as Map)['staging'], isNotEmpty);
      await restartFromCrash(libraryCheckpoint!, journalCheckpoint!);
      expect(library.getVideo(localId)!.lastPositionMs, 28000);
      expect(await File(library.getVideo(localId)!.path).readAsBytes(), [
        4,
        3,
        2,
        1,
      ]);
      final retried = await receive(package, previous: first);
      expect(retried.importedMediaCount, 0);
      expect(retried.stableToLocalIds['movie'], localId);
      expect(library.mediaInFolderTree(first.collectionId).single.id, localId);
      final backup = library.storageVideos.singleWhere(
        (item) => item.isRecycled,
      );
      expect(await File(backup.path).readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test(
    'new media intent is durable before publication and restart reuses that card',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final added = await add(source.id, 'added', [8, 7, 6, 5]);
      ids[added.id] = 'added';
      final package = await pack(source.id, ids);
      final originalIds = library.storageVideos.map((item) => item.id).toSet();
      String? libraryCheckpoint, journalCheckpoint, addedLocalId;
      void checkpoint() {
        if (libraryCheckpoint != null) return;
        final inserted = library.storageVideos
            .where((item) => !originalIds.contains(item.id) && !item.isRecycled)
            .firstOrNull;
        if (inserted == null) return;
        libraryCheckpoint = File(
          p.join(temp.path, 'library.json'),
        ).readAsStringSync();
        journalCheckpoint = File(
          p.join(temp.path, 'portable_transfer', 'folder_receipts_v1.json'),
        ).readAsStringSync();
        addedLocalId = inserted.id;
      }

      library.addListener(checkpoint);
      try {
        await receive(package, previous: first);
      } finally {
        library.removeListener(checkpoint);
      }
      expect(libraryCheckpoint, isNotNull);
      final journal = jsonDecode(journalCheckpoint!) as Map;
      expect(
        (journal['mappings'] as Map)[jsonEncode([
          'remote',
          source.id,
        ])][added.id],
        addedLocalId,
      );
      await restartFromCrash(libraryCheckpoint!, journalCheckpoint!);
      library.getVideo(addedLocalId!)!.lastPositionMs = 12000;
      final retried = await receive(package, previous: first);
      expect(retried.importedMediaCount, 0);
      expect(retried.stableToLocalIds['added'], addedLocalId);
      expect(library.getVideo(addedLocalId!)!.lastPositionMs, 12000);
      expect(library.mediaInFolderTree(first.collectionId), hasLength(2));
      expect(library.storageVideos.where((item) => item.isRecycled), isEmpty);
    },
  );

  for (final nested in [false, true]) {
    test(
      'crash after publishing ${nested ? 'a child folder' : 'the first root'} reuses its durable planned ID',
      () async {
        final source = await library.createCollection('课程', null);
        final child = nested
            ? await library.createCollection('章节', source.id)
            : null;
        final video = await add(child?.id ?? source.id, 'lesson', [1, 2, 3, 4]);
        final ids = {
          source.id: 'root',
          if (child != null) child.id: 'chapter',
          video.id: 'movie',
        };
        final package = await pack(source.id, ids);
        final originalFolders = library.storageCollections
            .map((item) => item.id)
            .toSet();
        String? libraryCheckpoint, journalCheckpoint, localFolderId;
        void checkpoint() {
          if (libraryCheckpoint != null) return;
          final inserted = library.storageCollections
              .where(
                (item) =>
                    !originalFolders.contains(item.id) &&
                    item.name == (nested ? '章节' : '课程'),
              )
              .firstOrNull;
          if (inserted == null) return;
          libraryCheckpoint = File(
            p.join(temp.path, 'library.json'),
          ).readAsStringSync();
          journalCheckpoint = File(
            p.join(temp.path, 'portable_transfer', 'folder_receipts_v1.json'),
          ).readAsStringSync();
          localFolderId = inserted.id;
        }

        library.addListener(checkpoint);
        try {
          await receive(package);
        } finally {
          library.removeListener(checkpoint);
        }
        expect(libraryCheckpoint, isNotNull);
        final journal = jsonDecode(journalCheckpoint!) as Map;
        final mappings =
            (journal['mappings'] as Map)[jsonEncode(['remote', source.id])]
                as Map;
        final localRootId = mappings[source.id] as String;
        expect(mappings[child?.id ?? source.id], localFolderId);
        await restartFromCrash(libraryCheckpoint!, journalCheckpoint!);
        expect(library.getCollection(localFolderId!), isNotNull);
        // No manager target/result is supplied: recovery must use the receipt.
        final retried = await receive(package);
        expect(retried.collectionId, localRootId);
        expect(
          retried.stableToLocalIds[nested ? 'chapter' : 'root'],
          localFolderId,
        );
        expect(
          library.storageCollections,
          hasLength(originalFolders.length + (nested ? 2 : 1)),
        );
        expect(library.mediaInFolderTree(localRootId), hasLength(1));
        expect(
          await File(
            library.mediaInFolderTree(localRootId).single.path,
          ).readAsBytes(),
          [1, 2, 3, 4],
        );
      },
    );
  }

  test(
    'unknown receipt versions remain untouched and cannot import over existing state',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final package = await pack(source.id, {
        source.id: 'root',
        video.id: 'movie',
      });
      final receipts = File(
        p.join(temp.path, 'portable_transfer', 'folder_receipts_v1.json'),
      );
      const futureJournal = '{"version":99,"future":{"retain":"all"}}';
      await receipts.parent.create(recursive: true);
      await receipts.writeAsString(futureJournal);
      service.dispose();
      service = PortableTransferService.forTesting();
      transfer = PortableFolderTransfer(service: service);
      await expectLater(receive(package), throwsFormatException);
      expect(await receipts.readAsString(), futureJournal);
      expect(library.storageCollections.single.id, source.id);
      expect(library.storageVideos.single.id, video.id);
    },
  );

  test(
    'preselected folder IDs cannot replace existing cards or escape storage',
    () async {
      final folder = await library.createCollection(
        '目录',
        null,
        id: 'planned-root',
      );
      final video = await add(folder.id, 'movie', [1, 2, 3, 4]);
      for (final id in [folder.id, video.id, '../outside', '']) {
        await expectLater(
          library.createCollection('replacement', null, id: id),
          throwsFormatException,
        );
      }
      expect(library.getCollection(folder.id), same(folder));
      expect(folder.name, '目录');
      expect(library.storageCollections, hasLength(1));
      expect(library.getVideo(video.id), same(video));
    },
  );

  test(
    'different stable nodes with equal content keep independent cards and share physical media',
    () async {
      final source = await library.createCollection('课程', null);
      final a = await library.createCollection('A', source.id);
      final b = await library.createCollection('B', source.id);
      final one = await add(a.id, 'one', [1, 2, 3, 4]);
      final two = await add(b.id, 'two', [1, 2, 3, 4]);
      final first = await receive(
        await pack(source.id, {
          source.id: 'root',
          a.id: 'a',
          b.id: 'b',
          one.id: 'one',
          two.id: 'two',
        }),
      );
      final x = library.getVideo(first.stableToLocalIds['one']!)!;
      final y = library.getVideo(first.stableToLocalIds['two']!)!;
      expect(x.id, isNot(y.id));
      expect(x.parentId, isNot(y.parentId));
      expect(x.path, y.path);
      x.lastPositionMs = 50000;
      expect(y.lastPositionMs, 0);
      final shared = x.path;
      await library.recycleSyncItem(x.id);
      await library.deleteFromRecycleBin([x.id]);
      expect(await File(shared).readAsBytes(), [1, 2, 3, 4]);
      await library.recycleSyncItem(y.id);
      expect(await File(shared).exists(), true);
      await library.deleteFromRecycleBin([y.id]);
      expect(await File(shared).exists(), false);
    },
  );

  test(
    'same names with distinct bytes never merge logical nodes or physical resources',
    () async {
      final source = await library.createCollection('课程', null);
      final one = await add(source.id, 'one', [1, 2, 3]);
      final two = await add(source.id, 'two', [3, 2, 1]);
      one.title = two.title = 'same';
      final received = await receive(
        await pack(source.id, {
          source.id: 'root',
          one.id: 'one',
          two.id: 'two',
        }),
      );
      final videos = library.mediaInFolderTree(received.collectionId);
      expect(videos, hasLength(2));
      expect(videos.map((item) => item.title).toSet(), {'same'});
      expect(videos.map((item) => item.path).toSet(), hasLength(2));
    },
  );

  test(
    'stable metadata aligns rename and moves while preserving receiver root placement',
    () async {
      final source = await library.createCollection('课程', null);
      final a = await library.createCollection('A', source.id);
      final b = await library.createCollection('B', source.id);
      final video = await add(a.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', a.id: 'a', b.id: 'b', video.id: 'movie'};
      final firstPack = await pack(source.id, ids);
      final first = await receive(firstPack);
      final outer = await library.createCollection('我的分类', null);
      await library.moveItemToCollection(first.collectionId, outer.id);
      await library.applySyncItemMetadata(
        source.id,
        name: '改名课程',
        parentId: null,
      );
      await library.applySyncItemMetadata(a.id, name: '改名章节', parentId: b.id);
      await library.applySyncItemMetadata(
        video.id,
        name: '改名视频',
        parentId: b.id,
      );
      final fp = firstPack.fingerprints[video.id]!;
      final delta = await pack(
        source.id,
        ids,
        include: {video.id},
        skip: {'sha256:${fp.size}:${fp.sha256}'},
      );
      final result = await receive(delta, previous: first);
      expect(result.stableToLocalIds, first.stableToLocalIds);
      expect(library.getCollection(first.collectionId)!.parentId, outer.id);
      expect(library.getCollection(first.collectionId)!.name, '改名课程');
      expect(
        library.getCollection(first.stableToLocalIds['a']!)!.parentId,
        first.stableToLocalIds['b'],
      );
      expect(
        library.getVideo(first.stableToLocalIds['movie']!)!.parentId,
        first.stableToLocalIds['b'],
      );
      expect(library.getVideo(first.stableToLocalIds['movie']!)!.title, '改名视频');
      expect(delta.mediaCount, 0);
    },
  );

  test(
    'missing physical file repairs the original stable card without a duplicate or empty backup',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final id = first.stableToLocalIds['movie']!;
      library.getVideo(id)!.lastPositionMs = 9000;
      await File(library.getVideo(id)!.path).delete();
      final repaired = await receive(
        await pack(source.id, ids, include: {video.id}),
        previous: first,
      );
      expect(repaired.stableToLocalIds['movie'], id);
      expect(library.mediaInFolderTree(first.collectionId).single.id, id);
      expect(await File(library.getVideo(id)!.path).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(library.getVideo(id)!.lastPositionMs, 9000);
      expect(library.storageVideos.where((item) => item.isRecycled), isEmpty);
    },
  );

  test(
    'new content preserves the stable ID and a recoverable old version with subtitle associations',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3, 4]);
      final subtitle = File(p.join(temp.path, 'subtitle.srt'));
      await subtitle.writeAsString('old subtitles');
      video.subtitlePath = subtitle.path;
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final local = library.getVideo(first.stableToLocalIds['movie']!)!;
      final oldPath = local.path;
      final oldSubtitle = local.subtitlePath!;
      await File(video.path).writeAsBytes([4, 3, 2, 1]);
      await subtitle.writeAsString('new subtitles');
      final result = await receive(
        await pack(source.id, ids, include: {video.id}),
        previous: first,
      );
      expect(result.stableToLocalIds['movie'], local.id);
      final current = library.getVideo(local.id)!;
      expect(await File(current.path).readAsBytes(), [4, 3, 2, 1]);
      expect(await File(current.subtitlePath!).readAsString(), 'new subtitles');
      final backup = library.storageVideos.singleWhere(
        (item) => item.isRecycled,
      );
      expect(backup.path, oldPath);
      expect(backup.subtitlePath, oldSubtitle);
      expect(await File(backup.path).readAsBytes(), [1, 2, 3, 4]);
      expect(await File(backup.subtitlePath!).readAsString(), 'old subtitles');
      await library.deleteFromRecycleBin([current.id]);
      expect(await File(backup.path).readAsBytes(), [1, 2, 3, 4]);
      expect(await File(backup.subtitlePath!).readAsString(), 'old subtitles');
      await library.restoreFromRecycleBin([backup.id]);
      expect(library.getVideo(backup.id)!.isRecycled, false);
    },
  );

  test(
    'media selection can carry only folders and rejects duplicate stable IDs',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3]);
      final package = await pack(source.id, {
        source.id: 'root',
        video.id: 'movie',
      }, include: {});
      final stream = InputFileStream(package.path);
      final archive = ZipDecoder().decodeStream(stream);
      final manifest =
          jsonDecode(
                utf8.decode(
                  archive.files
                      .singleWhere((item) => item.name == 'manifest.json')
                      .content,
                ),
              )
              as Map;
      expect((manifest['snapshot'] as Map)['videos'], isEmpty);
      expect(manifest['stableIds'], {source.id: 'root'});
      archive.clear();
      await stream.close();
      await expectLater(
        pack(source.id, {source.id: 'same', video.id: 'same'}),
        throwsFormatException,
      );
      await expectLater(
        pack(
          source.id,
          {source.id: 'root'},
          metadata: {
            'events': [Object()],
          },
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'metadata primitive rejects cycles and invalid parents; recycle remains idempotent and physical',
    () async {
      final a = await library.createCollection('A', null);
      final b = await library.createCollection('B', a.id);
      final video = await add(b.id, 'lesson', [1, 2, 3]);
      await expectLater(
        library.applySyncItemMetadata(a.id, name: 'A', parentId: b.id),
        throwsFormatException,
      );
      await expectLater(
        library.applySyncItemMetadata(
          video.id,
          name: 'movie',
          parentId: 'missing',
        ),
        throwsFormatException,
      );
      expect(library.getCollection(a.id)!.parentId, isNull);
      await library.recycleSyncItem(a.id);
      await library.recycleSyncItem(a.id);
      expect(await File(video.path).readAsBytes(), [1, 2, 3]);
    },
  );
  test(
    'content-only delta creates a second stable card in another folder without copying bytes',
    () async {
      final source = await library.createCollection('课程', null);
      final a = await library.createCollection('A', source.id);
      final firstVideo = await add(a.id, 'first', [1, 2, 3, 4]);
      final firstPackage = await pack(source.id, {
        source.id: 'root',
        a.id: 'a',
        firstVideo.id: 'first',
      });
      final first = await receive(firstPackage);
      final localFirst = library.getVideo(first.stableToLocalIds['first']!)!;
      localFirst.lastPositionMs = 6000;
      final b = await library.createCollection('B', source.id);
      final secondVideo = await add(b.id, 'second', [1, 2, 3, 4]);
      final key = 'sha256:4:${sha256.convert([1, 2, 3, 4])}';
      final delta = await pack(
        source.id,
        {
          source.id: 'root',
          a.id: 'a',
          b.id: 'b',
          firstVideo.id: 'first',
          secondVideo.id: 'second',
        },
        include: {secondVideo.id},
        skip: {key},
      );
      expect(delta.mediaCount, 0);
      expect(delta.totalBytes, lessThan(8000));
      final result = await receive(delta, previous: first);
      final localSecond = library.getVideo(result.stableToLocalIds['second']!)!;
      expect(localSecond.id, isNot(localFirst.id));
      expect(localSecond.parentId, isNot(localFirst.parentId));
      expect(localSecond.path, localFirst.path);
      expect(localSecond.lastPositionMs, 0);
      expect(localFirst.lastPositionMs, 6000);
      expect(library.mediaInFolderTree(first.collectionId), hasLength(2));
    },
  );

  test(
    'sidecars can be omitted without changing source subtitle bindings',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3]);
      final subtitle = File(p.join(temp.path, 'local.srt'));
      await subtitle.writeAsString('local subtitles');
      video.subtitlePath = subtitle.path;
      final package = await pack(source.id, {
        source.id: 'root',
        video.id: 'movie',
      }, sidecars: false);
      final received = await receive(package);
      expect(
        library.getVideo(received.stableToLocalIds['movie']!)!.subtitlePath,
        isNull,
      );
      expect(video.subtitlePath, subtitle.path);
      expect(await subtitle.readAsString(), 'local subtitles');
    },
  );
  test(
    'cancel before committing a revision keeps the original card and bytes',
    () async {
      final source = await library.createCollection('课程', null);
      final video = await add(source.id, 'lesson', [1, 2, 3]);
      final ids = {source.id: 'root', video.id: 'movie'};
      final first = await receive(await pack(source.id, ids));
      final localId = first.stableToLocalIds['movie']!;
      final oldPath = library.getVideo(localId)!.path;
      await File(video.path).writeAsBytes([3, 2, 1]);
      final package = await pack(source.id, ids);
      var cancelled = false;
      await expectLater(
        transfer.importReceivedFolder(
          library: library,
          packagePath: package.path,
          originDeviceId: 'remote',
          sourceCollectionId: source.id,
          existingTargetCollectionId: first.collectionId,
          existingLocalIds: first.stableToLocalIds,
          reconcileStructure: true,
          isCancelled: () => cancelled,
          onProgress: (_, status) {
            if (status.startsWith('正在恢复卡片')) cancelled = true;
          },
        ),
        throwsA(isA<PortableExportCancelled>()),
      );
      expect(library.mediaInFolderTree(first.collectionId).single.id, localId);
      expect(library.getVideo(localId)!.path, oldPath);
      expect(await File(oldPath).readAsBytes(), [1, 2, 3]);
      expect(library.storageVideos.where((item) => item.isRecycled), isEmpty);
    },
  );
}

FolderSyncEvent _folderEvent(
  String id,
  FolderSyncNode node, {
  String device = 'remote',
  Map<String, int> clock = const {'remote': 1},
}) => FolderSyncEvent(
  id: id,
  groupId: 'group',
  deviceId: device,
  clock: clock,
  node: node,
  deleted: false,
  createdAtMs: 1,
);

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}
