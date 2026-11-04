import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_coordinator.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_models.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_state.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'test_dir_cleanup.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String> getApplicationDocumentsPath() async => root;
  @override
  Future<String> getApplicationSupportPath() async => root;
  @override
  Future<String> getApplicationCachePath() async => p.join(root, 'cache');
  @override
  Future<String> getTemporaryPath() async => p.join(root, 'temp');
}

Future<String?> _contentKey(VideoItem item) async {
  try {
    final file = File(item.path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    return 'sha256:${bytes.length}:${sha256.convert(bytes)}';
  } on FileSystemException {
    return null;
  }
}

FolderSyncCoordinator _coordinator(LibraryService library) =>
    FolderSyncCoordinator(
      library: library,
      deviceId: 'local-device',
      deviceName: 'Local device',
      contentKey: _contentKey,
    );

FolderSyncEvent _delete(FolderSyncState catalog, String nodeId) {
  final original = catalog.heads(nodeId).single;
  return FolderSyncEvent(
    id: 'remote-delete-$nodeId',
    groupId: catalog.groupId,
    deviceId: 'remote-device',
    clock: {...original.clock, 'remote-device': 1},
    node: original.node,
    deleted: true,
    createdAtMs: 1,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final originalPaths = PathProviderPlatform.instance;
  late Directory temporary;
  late LibraryService library;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('sync_coordinator_');
    PathProviderPlatform.instance = _Paths(temporary.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = temporary.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
  });
  tearDown(() async {
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = originalPaths;
    await deleteTestTempDir(temporary);
  });

  Future<VideoItem> media(
    String id,
    String parentId, {
    String extension = '.mp4',
    int content = 1,
    int position = 0,
  }) async {
    final file = await File(
      p.join(temporary.path, '$id$extension'),
    ).writeAsBytes(List.generate(256, (i) => (i + content) % 251));
    final item = VideoItem(
      id: id,
      path: file.path,
      parentId: parentId,
      title: 'Video $id',
      durationMs: 100000,
      lastPositionMs: position,
      lastUpdated: 1,
      hasProbedChapters: true,
    );
    await library.addSingleVideo(item, useOriginalPath: true);
    return library.getVideo(id)!;
  }

  for (final mode in [FolderSyncMode.smart, FolderSyncMode.oneWay]) {
    test('bound root aliases stay local in ${mode.name} mode', () async {
      final source = await library.createCollection('Computer Root', null);
      final parent = await library.createCollection('My Library', null);
      final receiver = await library.createCollection('Phone Alias', parent.id);
      final settings = FolderSyncSettings(
        mode: mode,
        sourceDeviceId: mode == FolderSyncMode.oneWay ? 'sender' : null,
      );
      final sender = FolderSyncCoordinator(
        library: library,
        deviceId: 'sender',
        deviceName: 'Computer',
        contentKey: _contentKey,
      );
      final phone = FolderSyncCoordinator(
        library: library,
        deviceId: 'phone',
        deviceName: 'Phone',
        contentKey: _contentKey,
      );
      await sender.capture('aliases', source.id, settings);
      phone
          .state('aliases', settings: settings)
          .mergeAll(sender.state('aliases').activeEvents);
      await phone.capture('aliases', receiver.id, settings);
      await phone.apply('aliases', receiver.id, settings);
      expect(library.getCollection(receiver.id)!.name, 'Phone Alias');
      expect(library.getCollection(receiver.id)!.parentId, parent.id);
      await library.renameItem(receiver.id, 'Renamed on phone');
      await phone.capture('aliases', receiver.id, settings);
      sender.state('aliases').mergeAll(phone.state('aliases').activeEvents);
      await sender.apply('aliases', source.id, settings);
      expect(library.getCollection(source.id)!.name, 'Computer Root');
      expect(phone.state('aliases').issues, isEmpty);
      expect(sender.state('aliases').issues, isEmpty);
    });
  }

  test('saved root-name-only conflicts no longer block descendants', () async {
    final root = await library.createCollection('Local Alias', null);
    final coordinator = _coordinator(library);
    final catalog = coordinator.state('old-aliases');
    catalog.mergeAll([
      for (final device in ['computer', 'phone'])
        FolderSyncEvent(
          id: 'root-$device',
          groupId: 'old-aliases',
          deviceId: device,
          clock: {device: 1},
          node: FolderSyncNode(
            id: 'shared-root',
            kind: FolderSyncNodeKind.folder,
            name: device,
          ),
        ),
    ]);
    await coordinator.capture(
      'old-aliases',
      root.id,
      const FolderSyncSettings(),
    );
    await coordinator.apply('old-aliases', root.id, const FolderSyncSettings());
    expect(catalog.rootNodeId, 'shared-root');
    expect(catalog.issues, isEmpty);
    expect(library.getCollection(root.id)!.name, 'Local Alias');
  });

  for (final removeFolder in [false, true]) {
    test(
      'explicit local ${removeFolder ? 'folder' : 'media'} removal stays suppressed with syncDeletes enabled after rescans and restart',
      () async {
        const settings = FolderSyncSettings(syncDeletes: true);
        final root = await library.createCollection('Root', null);
        final folder = await library.createCollection('Folder', root.id);
        final item = await media('local-video', folder.id);
        var coordinator = _coordinator(library);
        await coordinator.capture('group', root.id, settings);
        var catalog = coordinator.state('group');
        final folderNode = catalog.nodeIdForLocal(folder.id)!;
        final mediaNode = catalog.nodeIdForLocal(item.id)!;
        final localId = removeFolder ? folder.id : item.id;
        final nodeId = removeFolder ? folderNode : mediaNode;
        final initialIds = catalog.activeEvents.map((e) => e.id).toSet();
        final remote = FolderSyncState(
          groupId: 'group',
          deviceId: 'remote-device',
        )..mergeAll(catalog.activeEvents);

        // This is the local-only branch of removeSyncedItem: the explicit
        // suppression must take precedence over the shared deletion setting.
        catalog.suppress(nodeId);
        await library.recycleSyncItem(localId);
        for (var pass = 0; pass < 3; pass++) {
          await coordinator.capture('group', root.id, settings);
          await coordinator.apply('group', root.id, settings);
        }
        expect(catalog.events.any((event) => event.deleted), isFalse);
        expect(catalog.activeEvents.map((e) => e.id).toSet(), initialIds);
        expect(catalog.isSuppressed(nodeId), isTrue);
        expect(library.getCollection(root.id)!.isRecycled, isFalse);

        final saved =
            jsonDecode(jsonEncode(coordinator.toJson()))
                as Map<String, dynamic>;
        coordinator = _coordinator(library)..restore(saved);
        catalog = coordinator.state('group');
        await coordinator.capture('group', root.id, settings);
        await coordinator.apply('group', root.id, settings);
        expect(catalog.isSuppressed(nodeId), isTrue);
        expect(catalog.events.any((event) => event.deleted), isFalse);
        expect(catalog.activeEvents.map((e) => e.id).toSet(), initialIds);
        expect(
          removeFolder
              ? library.getCollection(localId)!.isRecycled
              : library.getVideo(localId)!.isRecycled,
          isTrue,
        );
        remote.mergeAll(catalog.activeEvents);
        expect(remote.heads(folderNode).single.deleted, isFalse);
        expect(remote.heads(mediaNode).single.deleted, isFalse);
        expect(remote.safeNodes.keys, containsAll([folderNode, mediaNode]));
        expect(await File(item.path).exists(), isTrue);
      },
    );
  }

  for (final excluded in [false, true]) {
    test(
      '${excluded ? 'excluded' : 'unbound'} active local child blocks remote parent-folder recycling',
      () async {
        final settings = FolderSyncSettings(
          syncDeletes: true,
          excludedExtensions: excluded ? ['.tmp'] : const [],
        );
        final root = await library.createCollection('Root', null);
        final folder = await library.createCollection('Folder', root.id);
        final coordinator = _coordinator(library);
        await coordinator.capture('group', root.id, settings);
        final catalog = coordinator.state('group');
        final folderNode = catalog.nodeIdForLocal(folder.id)!;

        final localOnly = await media(
          'local-only',
          folder.id,
          extension: excluded ? '.tmp' : '.mp4',
        );
        if (excluded) await coordinator.capture('group', root.id, settings);
        expect(catalog.nodeIdForLocal(localOnly.id), isNull);
        catalog.merge(_delete(catalog, folderNode));
        expect(catalog.safeDeletedNodeIds, contains(folderNode));

        await coordinator.apply('group', root.id, settings);
        expect(folder.isRecycled, isFalse);
        expect(root.childrenIds, contains(folder.id));
        expect(localOnly.isRecycled, isFalse);
        expect(folder.childrenIds, contains(localOnly.id));
        expect(await File(localOnly.path).exists(), isTrue);
        expect(
          coordinator
              .localIssues('group')
              .any(
                (issue) =>
                    issue.nodeId == folderNode &&
                    issue.reason == 'deleteHasLiveDescendants',
              ),
          isTrue,
        );

        // The guard is about preserving a live local child, rather than
        // permanently refusing an otherwise valid remote tombstone.
        await library.recycleSyncItem(localOnly.id);
        await coordinator.apply('group', root.id, settings);
        expect(folder.isRecycled, isTrue);
        expect(root.childrenIds, isNot(contains(folder.id)));
        expect(coordinator.localIssues('group'), isEmpty);
        expect(await File(localOnly.path).exists(), isTrue);
      },
    );
  }

  for (final recycledSource in [false, true]) {
    test(
      'keep-both media fork reuses ${recycledSource ? 'recoverable old' : 'existing live'} local content under a distinct entry identity',
      () async {
        const settings = FolderSyncSettings();
        final root = await library.createCollection('Root', null);
        final original = await media('original', root.id, position: 45000);
        final reusable = await media(
          'other-version',
          root.id,
          content: 12,
          position: 32000,
        );
        if (recycledSource) await library.recycleSyncItem(reusable.id);
        final coordinator = _coordinator(library);
        await coordinator.capture('group', root.id, settings);
        final catalog = coordinator.state('group');
        final rootNode = catalog.nodeIdForLocal(root.id)!;
        final originalNode = catalog.nodeIdForLocal(original.id)!;
        final key = (await _contentKey(reusable))!;
        final size = await File(reusable.path).length();
        final reusablePosition = reusable.lastPositionMs;
        catalog.merge(
          FolderSyncEvent(
            id: 'keep-both-event',
            groupId: 'group',
            deviceId: 'remote-device',
            clock: const {'remote-device': 1},
            node: FolderSyncNode(
              id: 'kept-fork',
              parentId: rootNode,
              kind: FolderSyncNodeKind.media,
              name: 'Video（保留副本）',
              contentKey: key,
              size: size,
              extension: '.mp4',
            ),
            createdAtMs: 1,
          ),
        );

        await coordinator.apply('group', root.id, settings);
        final forkId = catalog.localIdForNode('kept-fork');
        expect(forkId, isNotNull);
        expect(forkId, isNot(original.id));
        expect(forkId, isNot(reusable.id));
        final fork = library.getVideo(forkId!)!;
        expect(fork.path, reusable.path);
        expect(await _contentKey(fork), key);
        expect(fork.title, 'Video（保留副本）');
        expect(fork.lastPositionMs, 0);
        expect(fork.parentId, root.id);
        expect(fork.isRecycled, isFalse);
        expect(original.lastPositionMs, 45000);
        expect(reusable.lastPositionMs, reusablePosition);
        expect(reusable.isRecycled, recycledSource);
        expect(catalog.nodeIdForLocal(original.id), originalNode);
        expect(catalog.appliedNode('kept-fork')!.contentKey, key);
        expect(coordinator.missing('group'), isEmpty);
        expect(coordinator.missingCount('group'), 0);
        final activeIds = catalog.activeEvents.map((e) => e.id).toSet();

        await coordinator.capture('group', root.id, settings);
        await coordinator.apply('group', root.id, settings);
        expect(catalog.localIdForNode('kept-fork'), forkId);
        expect(catalog.activeEvents.map((e) => e.id).toSet(), activeIds);
        expect(
          library.mediaInFolderTree(root.id),
          hasLength(recycledSource ? 2 : 3),
        );
      },
    );
  }
}
