import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as digest;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/app_branding.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_sync_codec.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_models.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_webdav.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_models.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_state.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_models.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'podcast_core_test.dart' show podcastFixture;

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

Future<List<SyncProgressEvent>> _events(MemoryProgressSyncStore store) async {
  final snapshot = store.value!;
  final groups = <String, Map<String, dynamic>>{
    for (final value in snapshot['groups'] as List)
      (value as Map)['id'] as String: Map<String, dynamic>.from(value),
  };
  final result = <SyncProgressEvent>[];
  for (final raw in snapshot['envelopes'] as List) {
    final envelope = Map<String, dynamic>.from(raw as Map);
    final key = base64Decode(groups[envelope['groupId']]!['key'] as String);
    final plain = await AesGcm.with256bits().decrypt(
      SecretBox(
        base64Decode(envelope['cipherText'] as String),
        nonce: base64Decode(envelope['nonce'] as String),
        mac: Mac(base64Decode(envelope['mac'] as String)),
      ),
      secretKey: SecretKey(key),
      aad: utf8.encode(
        'progress|$kApplicationId|${envelope['groupId']}|${envelope['eventId']}',
      ),
    );
    result.add(
      SyncProgressEvent.fromJson(
        Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map),
      ),
    );
  }
  return result;
}

MemoryProgressSyncStore _remoteStore(
  MemoryProgressSyncStore source, {
  String deviceId = 'second-device',
}) {
  final snapshot = _copy(source.value!);
  snapshot['deviceId'] = deviceId;
  snapshot['deviceName'] = '手机';
  snapshot['enabled'] = false;
  snapshot.remove('privateKey');
  snapshot['fingerprints'] = [];
  for (final group in snapshot['groups'] as List) {
    (group as Map)['collectionId'] = null;
    group['peers'] = [];
  }
  return MemoryProgressSyncStore()..value = snapshot;
}

Future<Map<String, dynamic>> _encryptEvent(
  MemoryProgressSyncStore store,
  SyncProgressEvent event,
) async {
  final group = (store.value!['groups'] as List).cast<Map>().firstWhere(
    (g) => g['id'] == event.groupId,
  );
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(event.toJson())),
    secretKey: SecretKey(base64Decode(group['key'] as String)),
    aad: utf8.encode('progress|$kApplicationId|${event.groupId}|${event.id}'),
  );
  return {
    'kind': 'event',
    'version': 1,
    'edition': kApplicationId,
    'eventId': event.id,
    'groupId': event.groupId,
    'cipherText': base64Encode(box.cipherText),
    'nonce': base64Encode(box.nonce),
    'mac': base64Encode(box.mac.bytes),
  };
}

Future<FolderSyncEvent> _mediaFolderEvent(MemoryProgressSyncStore store) async {
  final groups = (store.value!['groups'] as List).cast<Map>();
  final catalogs = store.value!['folderCatalogs'] as Map;
  for (final state in catalogs.values.whereType<Map>()) {
    for (final raw in (state['events'] as List? ?? []).whereType<Map>()) {
      final event = FolderSyncEvent.fromJson(Map<String, dynamic>.from(raw));
      if (event.node.kind == FolderSyncNodeKind.media &&
          groups.any((group) => group['id'] == event.groupId)) {
        return event;
      }
    }
  }
  throw StateError('Expected a media catalog event');
}

Future<Map<String, dynamic>> _encryptFolderEvent(
  MemoryProgressSyncStore store,
  FolderSyncEvent event,
) async {
  final group = (store.value!['groups'] as List).cast<Map>().firstWhere(
    (group) => group['id'] == event.groupId,
  );
  final box = await AesGcm.with256bits().encrypt(
    utf8.encode(jsonEncode(event.toJson())),
    secretKey: SecretKey(base64Decode(group['key'] as String)),
    aad: utf8.encode('folder|$kApplicationId|${event.groupId}|${event.id}'),
  );
  return {
    'kind': 'folder-event',
    'version': 1,
    'edition': kApplicationId,
    'eventId': event.id,
    'groupId': event.groupId,
    'cipherText': base64Encode(box.cipherText),
    'nonce': base64Encode(box.nonce),
    'mac': base64Encode(box.mac.bytes),
  };
}

String _groupCode(MemoryProgressSyncStore store, String collectionId) {
  final group = Map<String, dynamic>.from(
    (store.value!['groups'] as List).cast<Map>().firstWhere(
      (g) => g['collectionId'] == collectionId,
    ),
  )..remove('collectionId');
  return 'fluent-progress:1:${base64UrlEncode(utf8.encode(jsonEncode({
    'version': 1,
    'edition': kApplicationId,
    'groups': [group],
  })))}';
}

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

Future<T> _withNetwork<T>(Future<T> Function() task) =>
    HttpOverrides.runWithHttpOverrides(task, _RealHttpOverrides());

Future<void> _deleteTemporaryDirectory(Directory directory) async {
  // Windows may still observe a completed snapshot rename while recursively
  // removing the fixture. Retry its transient sharing/nonempty errors only.
  for (var attempt = 0; ; attempt++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException catch (error) {
      if (!Platform.isWindows ||
          !const {32, 145}.contains(error.osError?.errorCode) ||
          attempt >= 9) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform originalPathProvider;
  final services = <ProgressSyncService>[];

  Future<ProgressSyncService> service(
    ProgressSyncStore store, {
    String? Function()? active,
  }) async {
    final sync = ProgressSyncService(
      library: library,
      store: store,
      enableNetwork: false,
      activeMediaId: active,
    );
    services.add(sync);
    await sync.init();
    return sync;
  }

  void disposeService(ProgressSyncService sync) {
    services.remove(sync);
    sync.dispose();
  }

  Future<VideoItem> seed(
    String folderId,
    String mediaId, {
    int position = 0,
    String? title,
    List<int> bytes = const [1, 2, 3, 4, 5],
    String? parentId,
  }) async {
    final file = File(p.join(root.path, '$mediaId.mp4'));
    await file.writeAsBytes(bytes);
    final item = VideoItem(
      id: mediaId,
      path: file.path,
      title: title ?? mediaId,
      durationMs: 100000,
      lastUpdated: 1,
      lastPositionMs: position,
      parentId: folderId,
    );
    library.seedVideoForTesting(item);
    library.seedCollectionForTesting(
      VideoCollection(
        id: folderId,
        name: folderId,
        createTime: 1,
        childrenIds: [mediaId],
        parentId: parentId,
      ),
    );
    return item;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('progress_sync_service_');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    await library.init();
  });

  tearDown(() async {
    for (final sync in services.reversed) {
      await sync.syncNow();
      sync.dispose();
    }
    services.clear();
    await library.saveProgress();
    library.resetLibraryForTesting();
    PathProviderPlatform.instance = originalPathProvider;
    SettingsService().resetForTest();
    await _deleteTemporaryDirectory(root);
  });

  test(
    'podcast fragments require this edition and ignore old applied markers',
    () async {
      final store = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      try {
        final feed = client.parser.parse(
          utf8.encode(podcastFixture()),
          'https://example.com/rss',
        );
        final records = await PodcastSyncCodec.encode(
          data: {
            'version': 1,
            'channel': feed.channel.toJson(),
            'episodes': [],
          },
          groupId: 'same-group',
          nodeId: 'same-node',
          key: List<int>.filled(32, 42),
        );
        final record = records.single;
        await expectLater(
          PodcastSyncCodec.receive(
            {...record, 'edition': 'other.edition'},
            List<int>.filled(32, 42),
            store,
          ),
          throwsFormatException,
        );
        final old = Map<String, dynamic>.from(record)..remove('edition');
        await expectLater(
          PodcastSyncCodec.receive(old, List<int>.filled(32, 42), store),
          throwsFormatException,
        );
        store.write('syncApplied', 'same-group:${record['digest']}', {'at': 1});
        final decoded = await PodcastSyncCodec.receive(
          record,
          List<int>.filled(32, 42),
          store,
        );
        expect(decoded, isNotNull);
        expect(store.list('syncPending').single['edition'], kApplicationId);
      } finally {
        store.close();
      }
    },
  );

  test('local files with old podcast provenance stay local in sync', () async {
    final folder = await library.createCollection('local-folder', null);
    final file = File(p.join(root.path, 'local-with-old-podcast.mp4'));
    await file.writeAsBytes([1, 2, 3, 4, 5]);
    final item = VideoItem(
      id: 'local-with-old-podcast',
      path: file.path,
      title: 'local',
      durationMs: 100000,
      lastUpdated: 1,
      lastPositionMs: 1000,
      parentId: folder.id,
      sourceRef: const MediaSourceRef(
        value: 'podcast:old',
        kind: MediaSourceKind.podcastEpisode,
        podcast: PodcastEpisodeRef(
          channelId: 'old',
          episodeId: 'old-episode',
          feedUrl: 'https://publisher.invalid/rss',
          mediaUrl: 'https://publisher.invalid/episode.mp3',
        ),
      ),
    );
    library.skipImportSidecarWorkForTesting = true;
    await library.addSingleVideo(item, useOriginalPath: true);
    final store = MemoryProgressSyncStore();
    final sync = await service(store);
    await sync.createFolderBinding(folder.id);
    final event = (await _events(store)).single;
    expect(event.mediaKey, startsWith('node:'));
    expect(
      (store.value!['fingerprints'] as List).single['key'],
      startsWith('sha256:'),
    );
    final portable = PortableTransferService.forTesting();
    final plan = await portable.prepareFolderTransferFiles(
      library: library,
      collectionId: folder.id,
    );
    try {
      final videos = (plan.manifest['snapshot'] as Map)['videos'] as List;
      expect((videos.single as Map)['isOnline'], isFalse);
      expect(plan.files.any((file) => file.path == item.path), isTrue);
    } finally {
      await plan.release();
      portable.dispose();
    }
  });

  test('sync codes reject other editions and untagged legacy codes', () async {
    await seed('isolation-folder', 'isolation-video', position: 1000);
    final sourceStore = MemoryProgressSyncStore();
    final source = await service(sourceStore);
    await source.createFolderBinding('isolation-folder');
    final code = await source.exportSyncCode();
    final payload = Map<String, dynamic>.from(
      jsonDecode(
            utf8.decode(
              base64Url.decode(code.substring('fluent-progress:1:'.length)),
            ),
          )
          as Map,
    );
    String encode(Map<String, dynamic> value) =>
        'fluent-progress:1:${base64UrlEncode(utf8.encode(jsonEncode(value)))}';
    final target = await service(MemoryProgressSyncStore());
    await expectLater(
      target.importSyncCode(encode({...payload, 'edition': 'another.edition'})),
      throwsFormatException,
    );
    final old = Map<String, dynamic>.from(payload)..remove('edition');
    await expectLater(
      target.importSyncCode(encode(old)),
      throwsFormatException,
    );
    final foreignGroup = Map<String, dynamic>.from(
      (payload['groups'] as List).single as Map,
    )..['edition'] = 'another.edition';
    await expectLater(
      target.importSyncCode(
        encode({
          ...payload,
          'groups': [foreignGroup],
        }),
      ),
      throwsFormatException,
    );
    expect(target.invitations, isEmpty);
    await target.importSyncCode(code);
    expect(target.invitations, hasLength(1));
  });

  test(
    'legacy local encrypted checkpoints are retained and retagged',
    () async {
      await seed('legacy-folder', 'legacy-video', position: 1234);
      final store = MemoryProgressSyncStore();
      final source = await service(store);
      await source.createFolderBinding('legacy-folder');
      final event = (await _events(store)).single;
      disposeService(source);
      final group = (store.value!['groups'] as List).cast<Map>().single;
      group.remove('edition');
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(jsonEncode(event.toJson())),
        secretKey: SecretKey(base64Decode(group['key'] as String)),
        aad: utf8.encode('${event.groupId}|${event.id}'),
      );
      store.value!['envelopes'] = [
        {
          'kind': 'event',
          'version': 1,
          'eventId': event.id,
          'groupId': event.groupId,
          'cipherText': base64Encode(box.cipherText),
          'nonce': base64Encode(box.nonce),
          'mac': base64Encode(box.mac.bytes),
        },
      ];
      final restored = await service(store);
      await restored.syncNow();
      expect((await _events(store)).single.value.positionMs, 1234);
      expect(
        ((store.value!['groups'] as List).single as Map)['edition'],
        kApplicationId,
      );
      expect(
        ((store.value!['envelopes'] as List).single as Map)['edition'],
        kApplicationId,
      );
    },
  );

  test('WebDAV ignores a record claiming another edition', () async {
    final local = await seed('edition-folder', 'edition-video', position: 1000);
    final store = MemoryProgressSyncStore();
    final sync = await service(store);
    await sync.createFolderBinding('edition-folder');
    final original = (await _events(store)).single;
    final injected = SyncProgressEvent.fromJson({
      ...original.toJson(),
      'id': 'foreign-checkpoint',
      'value': {...original.value.toJson(), 'positionMs': 90000},
    });
    final dav = await _ServiceDavServer.start();
    await _withNetwork(
      () => sync.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
    );
    final foreign = await _encryptEvent(store, injected)
      ..['edition'] = 'another.edition';
    final name = digest.sha256.convert(utf8.encode(injected.id));
    dav.files['/dav/FluentPlayerProgress/v2/$kApplicationId/events/$name.json'] =
        utf8.encode(jsonEncode(foreign));
    await sync.syncNow();
    expect(local.lastPositionMs, 1000);
    expect(
      (await _events(store)).map((event) => event.id),
      isNot(contains(injected.id)),
    );
  });

  test(
    'legacy projected podcast checkpoints migrate to the episode identity',
    () async {
      final podcastStore = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      final controller = PodcastController(
        store: podcastStore,
        client: client,
        mediaStore: PodcastMediaStore(
          root: Directory(p.join(root.path, 'legacy-podcast')),
          store: podcastStore,
          http: client.http,
        ),
      );
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
        controller,
        library: library,
      );
      ProgressSyncService? sync;
      try {
        final feed = client.parser.parse(
          utf8.encode(podcastFixture()),
          'https://example.com/rss',
        );
        feed.channel.imageUrl = '';
        final card = (await PodcastRuntime.instance.subscribe(feed))!;
        final episode = feed.episodes.first;
        controller.savePlaybackProgress(
          episode.id,
          42000,
          completed: true,
          lastPlayedMs: 100,
        );
        final adapter = await PodcastRuntime.instance.itemFor(episode);
        await library.persistPodcastAdapters();
        final store = MemoryProgressSyncStore();
        sync = await service(store);
        await sync.createFolderBinding(card.id);
        await sync.syncNow();
        final current = (await _events(
          store,
        )).singleWhere((event) => event.mediaKey == 'podcast:${episode.id}');
        final oldNode = await _mediaFolderEvent(store);
        final legacy = SyncProgressEvent(
          id: 'legacy-podcast-event',
          groupId: current.groupId,
          mediaKey: 'node:${oldNode.node.id}',
          title: current.title,
          deviceId: current.deviceId,
          deviceName: current.deviceName,
          clock: current.clock,
          value: current.value,
          createdAtMs: current.createdAtMs,
        );
        disposeService(sync);
        sync = null;
        store.value!['envelopes'] = [await _encryptEvent(store, legacy)];
        final signatures = Map<String, dynamic>.from(
          store.value!['localSignatures'] as Map,
        );
        final clocks = Map<String, dynamic>.from(
          store.value!['localClocks'] as Map,
        );
        signatures.removeWhere((key, _) => key.contains('|__podcast_state__:'));
        clocks.removeWhere((key, _) => key.contains('|__podcast_state__:'));
        signatures['${current.groupId}|${adapter.id}'] =
            current.value.signature;
        clocks['${current.groupId}|${adapter.id}'] = current.clock;
        store.value!['localSignatures'] = signatures;
        store.value!['localClocks'] = clocks;
        sync = await service(store);
        await sync.syncNow();
        final migrated = (await _events(
          store,
        )).singleWhere((event) => event.mediaKey == 'podcast:${episode.id}');
        expect(migrated.value.positionMs, 42000);
        expect(migrated.value.completed, isTrue);
        expect(migrated.descendsFrom(legacy), isTrue);
        final eventId = migrated.id;
        await sync.syncNow();
        expect(
          (await _events(store))
              .singleWhere((event) => event.mediaKey == 'podcast:${episode.id}')
              .id,
          eventId,
        );
      } finally {
        if (sync != null) disposeService(sync);
        PodcastRuntime.debugOverride = null;
        await controller.close();
        podcastStore.close();
      }
    },
  );

  test(
    'explicitly marking an unheard podcast episode is a conflicting edit',
    () async {
      final sourceStore = PodcastStore(sqlite3.openInMemory());
      final targetStore = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      PodcastController controller(PodcastStore store, String name) =>
          PodcastController(
            store: store,
            client: client,
            mediaStore: PodcastMediaStore(
              root: Directory(p.join(root.path, name)),
              store: store,
              http: client.http,
            ),
          );
      final sourceController = controller(sourceStore, 'played-source');
      final targetController = controller(targetStore, 'unplayed-target');
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
        sourceController,
        library: library,
      );
      ProgressSyncService? sender, receiver;
      try {
        final feed = client.parser.parse(
          utf8.encode(podcastFixture()),
          'https://example.com/rss',
        );
        feed.channel.imageUrl = '';
        final sourceCard = (await PodcastRuntime.instance.subscribe(feed))!;
        final episode = feed.episodes.first;
        sourceController.setPlayed(episode.id, true, project: false);
        final sourceSyncStore = MemoryProgressSyncStore();
        sender = await service(sourceSyncStore);
        await sender.createFolderBinding(sourceCard.id);
        final code = _groupCode(sourceSyncStore, sourceCard.id);
        final dav = await _ServiceDavServer.start();
        await _withNetwork(
          () => sender!.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
        );
        disposeService(sender);
        sender = null;

        PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
          targetController,
          library: library,
        );
        targetStore.mergeFeed(feed, initial: true);
        targetController.updateState(
          episode.id,
          (state) => state.favorite = true,
          project: false,
        );
        expect(targetController.state(episode.id).playbackUpdatedMs, 0);
        final target = await library.createCollection('目标频道', null);
        await library.setPodcastChannelRef(
          target.id,
          PodcastChannelRef(
            channelId: feed.channel.id,
            feedUrl: feed.channel.feedUrl,
          ),
        );
        final targetSyncStore = MemoryProgressSyncStore();
        receiver = await service(targetSyncStore);
        await receiver.importSyncCode(code);
        await receiver.acceptInvitation(
          receiver.invitations.single.groupId,
          target.id,
        );
        expect(
          (await _events(
            targetSyncStore,
          )).where((event) => event.mediaKey == 'podcast:${episode.id}'),
          isEmpty,
        );
        targetController.setPlayed(episode.id, false, project: false);
        await receiver.flush();
        expect(
          (await _events(
            targetSyncStore,
          )).where((event) => event.mediaKey == 'podcast:${episode.id}'),
          hasLength(1),
        );
        await _withNetwork(
          () =>
              receiver!.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
        );
        expect(targetController.state(episode.id).played, isFalse);
        final conflict = receiver.conflicts.single;
        expect(conflict.choices.map((event) => event.value.completed).toSet(), {
          true,
          false,
        });
      } finally {
        if (sender != null) disposeService(sender);
        if (receiver != null) disposeService(receiver);
        PodcastRuntime.debugOverride = null;
        await sourceController.close();
        await targetController.close();
        sourceStore.close();
        targetStore.close();
      }
    },
  );

  test(
    'excluding a known network download does not delete its local card',
    () async {
      final item = await seed('folder', 'network', position: 1000);
      final store = MemoryProgressSyncStore();
      final sync = await service(store);
      await sync.createFolderBinding('folder');
      final original = await _mediaFolderEvent(store);
      final dav = await _ServiceDavServer.start();
      await _withNetwork(
        () => sync.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
      );
      final path =
          '/dav/FluentPlayerProgress/v2/$kApplicationId/events/${digest.sha256.convert(utf8.encode(original.id))}.json';
      expect(dav.files, contains(path));
      final batch = library.beginImportBatch(
        title: 'yt-dlp',
        sourceKind: LibraryImportSourceKind.ytDlp,
      )!;
      library.noteImportedMedia(item.id, batchId: batch);
      await library.completeImportBatch(batch, persist: false);
      await sync.syncNow();
      expect(dav.files, isNot(contains(path)));
      final code = await sync.exportSyncCode();
      final data =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(code.substring('fluent-progress:1:'.length)),
                ),
              )
              as Map;
      expect(((data['groups'] as List).single as Map)['catalogCount'], 1);
      expect(library.getVideo(item.id), same(item));
      expect(item.isRecycled, isFalse);
      final before = await _events(store);
      await library.updateVideoProgress(item.id, 2000);
      await sync.flush();
      await sync.syncNow();
      expect(
        (await _events(store)).map((event) => event.id),
        before.map((event) => event.id),
      );
      final catalogs = store.value!['folderCatalogs'] as Map;
      final records = catalogs.values.whereType<Map>().expand(
        (catalog) => (catalog['events'] as List).whereType<Map>(),
      );
      expect(
        records.where(
          (event) =>
              event['node'] is Map &&
              (event['node'] as Map)['id'] == original.node.id &&
              event['deleted'] == true,
        ),
        isEmpty,
      );
    },
  );

  test(
    'binding snapshots existing progress into encrypted portable records',
    () async {
      final item = await seed(
        'desktop-folder',
        'desktop-video',
        position: 12500,
        title: '私人课程标题',
      );
      library.seedMediaActivityForTesting(
        MediaActivityRecord(mediaId: item.id)
          ..completed = false
          ..continueEnrolled = true
          ..lastPlayedAtMs = 12345
          ..accumulatedWatchMs = 9000,
      );
      final store = MemoryProgressSyncStore();
      final sync = await service(store);
      await sync.createFolderBinding('desktop-folder');
      await sync.syncNow();

      final event = (await _events(store)).single;
      expect(event.value.positionMs, 12500);
      expect(event.value.continueEnrolled, isTrue);
      expect(event.value.watchMs, 9000);
      expect(event.mediaKey, startsWith('node:'));
      expect(
        (store.value!['fingerprints'] as List).single['key'],
        startsWith('sha256:5:'),
      );
      final envelopeText = jsonEncode(store.value!['envelopes']);
      expect(envelopeText, isNot(contains('私人课程标题')));
      expect(envelopeText, isNot(contains(item.path)));
      expect(envelopeText, isNot(contains('positionMs')));
      expect(sync.bindings.single.collectionId, 'desktop-folder');
    },
  );

  test(
    'backward local seek advances causality and compacts obsolete checkpoints',
    () async {
      final item = await seed('folder', 'video', position: 70000);
      final store = MemoryProgressSyncStore();
      final sync = await service(store);
      await sync.createFolderBinding('folder');
      final old = (await _events(store)).single;
      await library.updateVideoProgress(item.id, 2000);
      await sync.flush();
      await sync.syncNow();
      final current = (await _events(store)).single;
      expect(current.value.positionMs, 2000);
      expect(current.descendsFrom(old), isTrue);
      expect(current.id, isNot(old.id));
    },
  );

  test(
    'full content identity distinguishes files with identical name and head/tail',
    () async {
      final bytes = List<int>.filled(16384, 7);
      final changed = List<int>.of(bytes)..[8192] = 8;
      await seed(
        'folder-one',
        'first',
        position: 1000,
        title: '同名.mp4',
        bytes: bytes,
      );
      await seed(
        'folder-two',
        'second',
        position: 1000,
        title: '同名.mp4',
        bytes: changed,
      );
      final store = MemoryProgressSyncStore();
      final sync = await service(store);
      await sync.createFolderBinding('folder-one');
      await sync.createFolderBinding('folder-two');
      final events = await _events(store);
      expect(events, hasLength(2));
      expect(events.map((event) => event.mediaKey).toSet(), hasLength(2));
    },
  );

  test(
    'new untouched folder receives matching progress across filenames without changing local metadata',
    () async {
      await seed('desktop-folder', 'desktop-video', position: 42000);
      final desktopStore = MemoryProgressSyncStore();
      final desktop = await service(desktopStore);
      await desktop.createFolderBinding('desktop-folder');
      await desktop.syncNow();
      disposeService(desktop);

      final local = await seed(
        'phone-folder',
        'renamed-video',
        title: '手机中的文件名',
      );
      library.seedMediaActivityForTesting(
        MediaActivityRecord(mediaId: local.id)
          ..addedAtMs = 999
          ..hidden = true,
      );
      final phoneStore = _remoteStore(desktopStore);
      final phone = await service(phoneStore);
      expect(phone.invitations, hasLength(1));
      await phone.acceptInvitation(
        phone.invitations.single.groupId,
        'phone-folder',
      );

      expect(local.lastPositionMs, 42000);
      expect(local.title, '手机中的文件名');
      expect(local.path, endsWith('renamed-video.mp4'));
      expect(library.mediaActivity(local.id)!.addedAtMs, 999);
      expect(library.mediaActivity(local.id)!.hidden, isTrue);
      expect(phone.conflicts, isEmpty);
      expect(phone.bindings.single.matchedCount, 1);
    },
  );

  test(
    'first merge preserves both existing watches until explicit resolution',
    () async {
      await seed('desktop-folder', 'desktop-video', position: 42000);
      final desktopStore = MemoryProgressSyncStore();
      final desktop = await service(desktopStore);
      await desktop.createFolderBinding('desktop-folder');
      await desktop.syncNow();
      disposeService(desktop);

      final local = await seed('phone-folder', 'phone-video', position: 9000);
      final phoneStore = _remoteStore(desktopStore);
      final phone = await service(phoneStore);
      await phone.acceptInvitation(
        phone.invitations.single.groupId,
        'phone-folder',
      );
      expect(local.lastPositionMs, 9000);
      final conflict = phone.conflicts.single;
      expect(
        conflict.choices.map((event) => event.value.positionMs),
        unorderedEquals([42000, 9000]),
      );
      final oldChoices = conflict.choices.toList();
      final chosen = conflict.choices.firstWhere(
        (event) => event.value.positionMs == 42000,
      );
      await phone.resolveConflict(conflict.id, chosen.id);
      expect(local.lastPositionMs, 42000);
      expect(phone.conflicts, isEmpty);
      final current = (await _events(phoneStore)).single;
      expect(oldChoices.every(current.descendsFrom), isTrue);
    },
  );

  test(
    'active player keeps its local position when another device progress is applied',
    () async {
      await seed('desktop-folder', 'desktop-video', position: 42000);
      final desktopStore = MemoryProgressSyncStore();
      final desktop = await service(desktopStore);
      await desktop.createFolderBinding('desktop-folder');
      await desktop.syncNow();
      disposeService(desktop);
      final local = await seed('phone-folder', 'phone-video');
      String? active = local.id;
      final phoneStore = _remoteStore(desktopStore);
      final phone = await service(phoneStore, active: () => active);
      await phone.setEnabled(true);
      await phone.acceptInvitation(
        phone.invitations.single.groupId,
        'phone-folder',
      );
      expect(local.lastPositionMs, 0);
      active = null;
      await phone.preparePlayback(local.id);
      expect(local.lastPositionMs, 42000);
    },
  );

  test(
    'sync code imports as invitation and requires choosing a local folder',
    () async {
      await seed('desktop-folder', 'desktop-video', position: 1000);
      final desktopStore = MemoryProgressSyncStore();
      final desktop = await service(desktopStore);
      await desktop.createFolderBinding('desktop-folder');
      final code = await desktop.exportSyncCode();
      await desktop.syncNow();
      disposeService(desktop);
      await seed('phone-folder', 'phone-video');
      final phone = await service(MemoryProgressSyncStore());
      await phone.importSyncCode(code);
      expect(phone.bindings, isEmpty);
      expect(phone.invitations.single.name, 'desktop-folder');
      await phone.acceptInvitation(
        phone.invitations.single.groupId,
        'phone-folder',
      );
      expect(phone.bindings.single.collectionId, 'phone-folder');
    },
  );

  test(
    'an unapplied active remote watch stays concurrent with the next local tick',
    () async {
      await seed('desktop-folder', 'desktop-video', position: 42000);
      final desktopStore = MemoryProgressSyncStore();
      final desktop = await service(desktopStore);
      await desktop.createFolderBinding('desktop-folder');
      await desktop.syncNow();
      disposeService(desktop);
      final local = await seed('phone-folder', 'phone-video');
      final phoneStore = _remoteStore(desktopStore);
      final phone = await service(phoneStore, active: () => local.id);
      await phone.setEnabled(true);
      await phone.acceptInvitation(
        phone.invitations.single.groupId,
        'phone-folder',
      );
      await library.updateVideoProgress(local.id, 3000);
      await phone.flush();
      await phone.syncNow();
      expect(local.lastPositionMs, 3000);
      final conflict = phone.conflicts.single;
      expect(
        conflict.choices.map((event) => event.value.positionMs),
        unorderedEquals([42000, 3000]),
      );
      expect(conflict.choices[0].descendsFrom(conflict.choices[1]), isFalse);
      expect(conflict.choices[1].descendsFrom(conflict.choices[0]), isFalse);
    },
  );

  test(
    'reload preserves the locally applied branch before unseen remote changes',
    () async {
      final local = await seed('folder', 'video', position: 1000);
      final store = MemoryProgressSyncStore();
      final original = await service(store);
      await original.createFolderBinding('folder');
      await original.syncNow();
      final previous = (await _events(store)).single;
      disposeService(original);
      final remote = SyncProgressEvent(
        id: 'remote-newer',
        groupId: previous.groupId,
        mediaKey: previous.mediaKey,
        title: previous.title,
        deviceId: 'remote-device',
        deviceName: '另一台设备',
        clock: {...previous.clock, 'remote-device': 1},
        value: const SyncProgressValue(
          positionMs: 42000,
          completed: false,
          continueEnrolled: false,
          lastPlayedAtMs: null,
          watchMs: 0,
        ),
        createdAtMs: 1,
      );
      store.value!['envelopes'] = [await _encryptEvent(store, remote)];
      final restarted = await service(store, active: () => local.id);
      await restarted.syncNow();
      expect(local.lastPositionMs, 1000);
      await library.updateVideoProgress(local.id, 2000);
      await restarted.flush();
      await restarted.syncNow();
      final conflict = restarted.conflicts.single;
      expect(
        conflict.choices.map((event) => event.value.positionMs),
        unorderedEquals([2000, 42000]),
      );
      final localEvent = conflict.choices.firstWhere(
        (event) => event.value.positionMs == 2000,
      );
      expect(localEvent.descendsFrom(previous), isTrue);
      expect(localEvent.descendsFrom(remote), isFalse);
    },
  );

  test(
    'applying received progress creates no echo checkpoint on the next scan',
    () async {
      await seed('desktop-folder', 'desktop-video', position: 42000);
      final desktopStore = MemoryProgressSyncStore();
      final desktop = await service(desktopStore);
      await desktop.createFolderBinding('desktop-folder');
      await desktop.syncNow();
      final original = (await _events(desktopStore)).single;
      disposeService(desktop);
      final local = await seed('phone-folder', 'phone-video');
      final phoneStore = _remoteStore(desktopStore);
      final phone = await service(phoneStore);
      await phone.setEnabled(true);
      await phone.acceptInvitation(
        phone.invitations.single.groupId,
        'phone-folder',
      );
      await phone.flush();
      await phone.syncNow();
      expect(local.lastPositionMs, 42000);
      expect((await _events(phoneStore)).map((event) => event.id), [
        original.id,
      ]);
    },
  );

  test(
    'unbinding removes pending envelopes and leaves the local media intact',
    () async {
      final local = await seed('folder', 'video', position: 3000);
      final store = MemoryProgressSyncStore();
      final sync = await service(store);
      await sync.createFolderBinding('folder');
      await sync.unbindFolder('folder');
      await library.updateVideoProgress(local.id, 4000);
      await sync.flush();
      await sync.syncNow();
      expect(sync.bindings, isEmpty);
      expect(store.value!['envelopes'], isEmpty);
      expect(local.lastPositionMs, 4000);
      expect(library.getVideo(local.id), same(local));
    },
  );

  test(
    'opening has a bounded wait and late WebDAV results do not change the active player',
    () async {
      final dav = await _ServiceDavServer.start();
      final local = await seed('folder', 'video', position: 1000);
      String? active;
      final store = MemoryProgressSyncStore();
      final sync = await service(store, active: () => active);
      await sync.createFolderBinding('folder');
      await _withNetwork(
        () => sync.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
      );
      final previous = (await _events(store)).single;
      final incoming = SyncProgressEvent(
        id: 'late-remote',
        groupId: previous.groupId,
        mediaKey: previous.mediaKey,
        title: previous.title,
        deviceId: 'remote-device',
        deviceName: '另一台设备',
        clock: {...previous.clock, 'remote-device': 1},
        value: const SyncProgressValue(
          positionMs: 42000,
          completed: false,
          continueEnrolled: false,
          lastPlayedAtMs: null,
          watchMs: 0,
        ),
        createdAtMs: 1,
      );
      final envelope = await _encryptEvent(store, incoming);
      final name = digest.sha256.convert(utf8.encode(incoming.id));
      dav.files['/dav/FluentPlayerProgress/v2/$kApplicationId/events/$name.json'] =
          utf8.encode(jsonEncode(envelope));
      dav.blockNextListing();
      final pending = sync.syncNow();
      await dav.blockedRequest!.future.timeout(const Duration(seconds: 3));
      try {
        await sync
            .preparePlayback('video')
            .timeout(const Duration(milliseconds: 1500));
        active = local.id;
      } finally {
        dav.releaseListing();
        await pending;
      }
      expect(local.lastPositionMs, 1000);
      expect((await _events(store)).single.id, incoming.id);
    },
  );

  test(
    'a newly imported group can read events skipped during an earlier WebDAV scan',
    () async {
      final dav = await _ServiceDavServer.start();
      await seed('desktop-a', 'video-a', position: 1000, bytes: [1, 1]);
      await seed('desktop-b', 'video-b', position: 2000, bytes: [2, 2]);
      final desktopStore = MemoryProgressSyncStore();
      final desktop = await service(desktopStore);
      await desktop.createFolderBinding('desktop-a');
      await desktop.createFolderBinding('desktop-b');
      final firstCode = _groupCode(desktopStore, 'desktop-a');
      final secondCode = _groupCode(desktopStore, 'desktop-b');
      await _withNetwork(
        () => desktop.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
      );
      disposeService(desktop);
      final first = await seed('phone-a', 'phone-video-a', bytes: [1, 1]);
      final second = await seed('phone-b', 'phone-video-b', bytes: [2, 2]);
      final phone = await service(MemoryProgressSyncStore());
      await phone.importSyncCode(firstCode);
      await phone.acceptInvitation(phone.invitations.single.groupId, 'phone-a');
      await _withNetwork(
        () => phone.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
      );
      expect(first.lastPositionMs, 1000);
      expect(second.lastPositionMs, 0);
      await phone.importSyncCode(secondCode);
      await phone.acceptInvitation(phone.invitations.single.groupId, 'phone-b');
      await phone.syncNow();
      expect(second.lastPositionMs, 2000);
      expect(phone.conflicts, isEmpty);
    },
  );

  test(
    'unchanged WebDAV checkpoints are not uploaded again but new progress is',
    () async {
      final dav = await _ServiceDavServer.start();
      final local = await seed('folder', 'video', position: 1000);
      final store = MemoryProgressSyncStore();
      final sync = await service(store);
      await sync.createFolderBinding('folder');
      await _withNetwork(
        () => sync.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
      );
      int checkpointPuts() =>
          dav.putPaths.where((path) => path.endsWith('.json')).length;
      final firstCount = checkpointPuts();
      expect(
        firstCount,
        3,
      ); // One progress event plus folder/media identity events.
      await sync.syncNow();
      await sync.syncNow();
      expect(checkpointPuts(), firstCount);
      await library.updateVideoProgress(local.id, 2000);
      await sync.flush();
      await sync.syncNow();
      expect(checkpointPuts(), firstCount + 1);
      await sync.syncNow();
      expect(checkpointPuts(), firstCount + 1);
    },
  );

  test(
    'flush reports write failure safely and persists the pending checkpoint after recovery',
    () async {
      final local = await seed('folder', 'video', position: 1000);
      final store = _FailingWriteStore();
      final sync = await service(store);
      await sync.createFolderBinding('folder');
      await sync.syncNow();
      final savedId = (await _events(store)).single.id;
      store.failWrites = true;
      try {
        await library.updateVideoProgress(local.id, 2000);
        await expectLater(sync.flush(), completes);
        expect(sync.error, '进度暂未保存，将在下次同步时重试');
        final unchanged = (await _events(store)).single;
        expect(unchanged.id, savedId);
        expect(unchanged.value.positionMs, 1000);
        expect(local.lastPositionMs, 2000);
      } finally {
        store.failWrites = false;
      }
      await sync.flush();
      await sync.syncNow();
      final recovered = (await _events(store)).single;
      expect(recovered.value.positionMs, 2000);
      expect(recovered.id, isNot(savedId));
      expect(sync.error, isNull);
    },
  );

  for (final readThrows in [true, false]) {
    test(
      '${readThrows ? 'unreadable' : 'future-version'} storage is never overwritten by enable or rename',
      () async {
        final store = _ProtectedReadStore(
          error: readThrows
              ? const FormatException('damaged encrypted storage')
              : null,
          snapshot: readThrows
              ? null
              : {'version': 999, 'futurePrivateData': 'preserve me'},
        );
        final sync = await service(store);
        expect(sync.error, isNotNull);
        expect(store.writes, 0);
        // Both a reported rejection and a disabled, non-writing return preserve
        // the user's original storage. Unexpected exception types still fail.
        Future<void> attempt(Future<void> Function() action) async {
          try {
            await action();
          } on FormatException {
            // An invalid store can only be repaired explicitly, never by retrying
            // an unrelated setting and writing a partial in-memory snapshot.
          }
        }

        await attempt(() => sync.setEnabled(true));
        await attempt(() => sync.renameDevice('新的设备名'));
        await sync.syncNow();
        expect(sync.enabled, isFalse);
        expect(store.writes, 0);
        if (!readThrows) {
          expect(store.snapshot, {
            'version': 999,
            'futurePrivateData': 'preserve me',
          });
        }
      },
    );
  }

  test(
    'parent and child folders cannot produce overlapping sync groups',
    () async {
      await seed('child', 'video', position: 1000, parentId: 'parent');
      library.seedCollectionForTesting(
        VideoCollection(
          id: 'parent',
          name: 'parent',
          createTime: 1,
          childrenIds: ['child'],
        ),
      );
      final sync = await service(MemoryProgressSyncStore());
      await sync.createFolderBinding('parent');
      await expectLater(
        sync.createFolderBinding('child'),
        throwsA(isA<FormatException>()),
      );
      expect(sync.bindings, hasLength(1));
    },
  );

  test(
    'disabled sync cancels saved retryable tasks on progress-only policy and repairs old checkpoints on startup',
    () async {
      await seed('folder', 'video', position: 1000);
      final store = MemoryProgressSyncStore();
      final original = await service(store);
      await original.createFolderBinding('folder');
      await original.setEnabled(false);
      disposeService(original);
      FolderTransferTask task(
        String id, {
        bool incoming = false,
        String? target,
        String source = 'folder',
        Map<String, dynamic> options = const {},
      }) => FolderTransferTask(
        id: id,
        direction: incoming
            ? FolderTransferDirection.receive
            : FolderTransferDirection.send,
        peerId: 'remote',
        peerName: 'remote',
        sourceCollectionId: source,
        folderName: 'folder',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        phase: FolderTransferPhase.needsAttention,
        accepted: true,
        targetCollectionId: target,
        syncOptions: options,
      );
      final paused = [
        task('paused-outgoing'),
        task(
          'paused-target',
          incoming: true,
          target: 'folder',
          source: 'remote-folder',
        ),
        task(
          'paused-option',
          incoming: true,
          source: 'remote-folder',
          options: {'targetCollectionId': 'folder'},
        ),
        task('unrelated-task', source: 'unrelated'),
      ];
      store.value!['folderTransfers'] = {
        'tasks': paused.map((task) => task.toJson()).toList(),
        'targets': <String, String>{},
      };
      final sync = await service(store);
      expect(sync.enabled, isFalse);
      await sync.updateFolderSettings(
        'folder',
        sync
            .folderSettings('folder')
            .copyWith(mode: FolderSyncMode.progressOnly),
      );
      expect(
        sync.folderTransfers
            .where((task) => task.id != 'unrelated-task')
            .every(
              (task) =>
                  task.phase == FolderTransferPhase.cancelled && !task.accepted,
            ),
        isTrue,
      );
      expect(
        sync.folderTransfers
            .singleWhere((task) => task.id == 'unrelated-task')
            .phase,
        FolderTransferPhase.needsAttention,
      );
      disposeService(sync);
      // Old versions could persist a paused task alongside an already-selected
      // progress-only mode. Startup must retire it before the auto-retry queue.
      (store.value!['folderTransfers'] as Map)['tasks'] = [
        task('old-paused-task').toJson(),
      ];
      final restored = await service(store);
      expect(
        restored.folderTransfers.single.phase,
        FolderTransferPhase.cancelled,
      );
      await restored.updateFolderSettings(
        'folder',
        restored.folderSettings('folder'),
      );
      expect(
        restored.folderTransfers.single.phase,
        FolderTransferPhase.cancelled,
      );
    },
  );

  test(
    'changing one-way source retires saved wrong-direction tasks but preserves allowed incoming work',
    () async {
      await seed('folder', 'video', position: 1000);
      final store = MemoryProgressSyncStore();
      final original = await service(store);
      await original.createFolderBinding('folder');
      await original.setEnabled(false);
      disposeService(original);
      final group = (store.value!['groups'] as List).cast<Map>().single;
      group['peers'] = ['selected-source', 'other-source'];
      store.value!['trustedKeys'] = {
        for (final peer in ['selected-source', 'other-source'])
          peer: base64Encode(List.filled(32, 7)),
      };
      store.value!['pairedNames'] = {
        'selected-source': 'Selected',
        'other-source': 'Other',
      };
      FolderTransferTask task(String id, String peer, {bool incoming = true}) =>
          FolderTransferTask(
            id: id,
            direction: incoming
                ? FolderTransferDirection.receive
                : FolderTransferDirection.send,
            peerId: peer,
            peerName: peer,
            sourceCollectionId: incoming ? 'remote-folder' : 'folder',
            targetCollectionId: incoming ? 'folder' : null,
            folderName: 'folder',
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            phase: FolderTransferPhase.paused,
            accepted: true,
          );
      store.value!['folderTransfers'] = {
        'tasks': [
          task('allowed-receive', 'selected-source').toJson(),
          task('wrong-receive', 'other-source').toJson(),
          task('wrong-outgoing', 'selected-source', incoming: false).toJson(),
        ],
        'targets': <String, String>{},
      };
      final sync = await service(store);
      await sync.updateFolderSettings(
        'folder',
        sync
            .folderSettings('folder')
            .copyWith(
              mode: FolderSyncMode.oneWay,
              sourceDeviceId: 'selected-source',
            ),
      );
      expect(
        sync.folderTransfers
            .singleWhere((task) => task.id == 'allowed-receive')
            .phase,
        FolderTransferPhase.paused,
      );
      expect(
        sync.folderTransfers
            .where((task) => task.id != 'allowed-receive')
            .every((task) => task.phase == FolderTransferPhase.cancelled),
        isTrue,
      );
    },
  );

  test(
    'unbinding while disabled also cancels paused saved transfers matched only by target',
    () async {
      await seed('folder', 'video', position: 1000);
      final store = MemoryProgressSyncStore();
      final original = await service(store);
      await original.createFolderBinding('folder');
      await original.setEnabled(false);
      disposeService(original);
      final task = FolderTransferTask(
        id: 'saved-target-only',
        direction: FolderTransferDirection.receive,
        peerId: 'remote',
        peerName: 'remote',
        sourceCollectionId: 'remote-folder',
        folderName: 'folder',
        targetCollectionId: 'folder',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        phase: FolderTransferPhase.paused,
        accepted: true,
      );
      store.value!['folderTransfers'] = {
        'tasks': [task.toJson()],
        'targets': <String, String>{},
      };
      final sync = await service(store);
      await sync.unbindFolder('folder');
      expect(sync.bindings, isEmpty);
      expect(sync.folderTransfers.single.phase, FolderTransferPhase.cancelled);
      expect(sync.folderTransfers.single.accepted, isFalse);
      expect(library.getVideo('video'), isNotNull);
    },
  );

  test(
    'same-position concurrent watches retain all monotone statistics',
    () async {
      final local = await seed('folder', 'video', position: 1000);
      final store = MemoryProgressSyncStore();
      final original = await service(store);
      await original.createFolderBinding('folder');
      final baseline = (await _events(store)).single;
      disposeService(original);
      SyncProgressEvent incoming(
        String id,
        String author,
        int watch,
        int played,
      ) => SyncProgressEvent(
        id: id,
        groupId: baseline.groupId,
        mediaKey: baseline.mediaKey,
        title: baseline.title,
        deviceId: author,
        deviceName: author,
        clock: {...baseline.clock, author: 1},
        value: SyncProgressValue(
          positionMs: 1000,
          completed: false,
          continueEnrolled: false,
          lastPlayedAtMs: played,
          watchMs: watch,
        ),
        createdAtMs: played,
      );
      store.value!['envelopes'] = [
        await _encryptEvent(store, incoming('a-watch', 'first', 100, 1000)),
        await _encryptEvent(store, incoming('z-watch', 'second', 900, 9000)),
      ];
      final restarted = await service(store);
      await restarted.syncNow();
      expect(local.lastPositionMs, 1000);
      expect(library.mediaActivity(local.id)!.accumulatedWatchMs, 900);
      expect(library.mediaActivity(local.id)!.lastPlayedAtMs, 9000);
      expect(restarted.conflicts, isEmpty);
      await restarted.syncNow();
      expect(library.mediaActivity(local.id)!.accumulatedWatchMs, 900);
    },
  );

  test(
    'community retired cloud sources stay stored without publishing sync events',
    () async {
      const cloud = CloudDriveSourceRef(
        providerId: 'baidu',
        remoteAccountId: 'remote-account',
        driveId: 'drive',
        fileId: 'file',
        revision: 'remote/version 1',
      );
      final historical = await seed(
        'desktop-cloud',
        'desktop-cloud-media',
        position: 22000,
      );
      // Retiring a remote identity must not remove an earlier local download.
      final originalFile = File(historical.path);
      final originalBytes = await originalFile.readAsBytes();
      historical.path = cloud.logicalUri;
      historical.sourceRef = MediaSourceRef(
        value: cloud.logicalUri,
        kind: MediaSourceKind.cloudDrive,
        cloudDrive: cloud,
      );
      final provenance = historical.sourceRef!.toJson();
      final store = MemoryProgressSyncStore();
      final sync = await service(store);
      await sync.createFolderBinding('desktop-cloud');
      await sync.syncNow();

      // The community media tree excludes retired remote entries before both
      // progress capture and media catalog capture. Never revive cloud access.
      expect(library.mediaInFolderTree('desktop-cloud'), isEmpty);
      expect(await _events(store), isEmpty);
      final catalogs = store.value!['folderCatalogs'] as Map;
      final mediaEvents = <FolderSyncEvent>[
        for (final state in catalogs.values.whereType<Map>())
          for (final raw in (state['events'] as List? ?? []).whereType<Map>())
            if (FolderSyncEvent.fromJson(
                  Map<String, dynamic>.from(raw),
                ).node.kind ==
                FolderSyncNodeKind.media)
              FolderSyncEvent.fromJson(Map<String, dynamic>.from(raw)),
      ];
      expect(mediaEvents, isEmpty);
      expect(sync.folderTransfers, isEmpty);

      expect(library.getVideo(historical.id), same(historical));
      expect(library.storageVideos, contains(same(historical)));
      expect(historical.isRecycled, isFalse);
      expect(historical.path, cloud.logicalUri);
      expect(historical.lastPositionMs, 22000);
      expect(historical.sourceRef!.toJson(), provenance);
      expect(await originalFile.exists(), isTrue);
      expect(await originalFile.readAsBytes(), originalBytes);
    },
  );

  test(
    'one-way source rejects queued follower folder events from WebDAV',
    () async {
      final dav = await _ServiceDavServer.start();
      final local = await seed('folder', 'video', position: 1000);
      final store = MemoryProgressSyncStore();
      final sync = await service(store);
      await sync.createFolderBinding('folder');
      final baseline = await _mediaFolderEvent(store);
      await sync.updateFolderSettings(
        'folder',
        sync
            .folderSettings('folder')
            .copyWith(
              mode: FolderSyncMode.oneWay,
              sourceDeviceId: sync.deviceId,
            ),
      );
      final queued = FolderSyncEvent(
        id: 'queued-follower-edit',
        groupId: baseline.groupId,
        deviceId: 'follower',
        clock: {...baseline.clock, 'follower': 1},
        node: baseline.node.copyWith(name: 'unexpected remote rename'),
      );
      final envelope = await _encryptFolderEvent(store, queued);
      dav.files['/dav/FluentPlayerProgress/v2/$kApplicationId/events/${digest.sha256.convert(utf8.encode(queued.id))}.json'] =
          utf8.encode(jsonEncode(envelope));
      await _withNetwork(
        () => sync.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
      );
      expect(local.title, 'video');
      expect(
        sync.folderSyncIssues.where(
          (issue) => issue.choices.any((choice) => choice.eventId == queued.id),
        ),
        isEmpty,
      );
    },
  );

  test(
    'a newly selected one-way source reaffirms inherited consensus for fresh followers',
    () async {
      await seed('first-folder', 'first-media', position: 17000);
      final originalStore = MemoryProgressSyncStore();
      final first = await service(originalStore);
      await first.createFolderBinding('first-folder');
      await first.syncNow();
      disposeService(first);
      final local = await seed('second-folder', 'second-media');
      final newStore = _remoteStore(originalStore);
      final next = await service(newStore);
      final groupId = next.invitations.single.groupId;
      await next.acceptInvitation(groupId, 'second-folder');
      await next.updateFolderSettings(
        'second-folder',
        next
            .folderSettings('second-folder')
            .copyWith(
              mode: FolderSyncMode.oneWay,
              sourceDeviceId: next.deviceId,
            ),
      );
      final state = FolderSyncState.fromJson(
        Map<String, dynamic>.from(
          (newStore.value!['folderCatalogs'] as Map)[groupId],
        ),
        deviceId: next.deviceId,
        deviceName: next.deviceName,
      );
      expect(state.activeEvents, isNotEmpty);
      expect(
        state.activeEvents.every((event) => event.deviceId == next.deviceId),
        isTrue,
      );
      expect(local.lastPositionMs, 17000);
      final ids = state.activeEvents.map((event) => event.id).toSet();
      await next.syncNow();
      final after = FolderSyncState.fromJson(
        Map<String, dynamic>.from(
          (newStore.value!['folderCatalogs'] as Map)[groupId],
        ),
        deviceId: next.deviceId,
        deviceName: next.deviceName,
      );
      expect(after.activeEvents.map((event) => event.id).toSet(), ids);
    },
  );

  test(
    'WebDAV pruning resumes more than 5000 durable obsolete records in batches',
    () async {
      final dav = await _ServiceDavServer.start();
      await seed('folder', 'video', position: 1000);
      final store = MemoryProgressSyncStore();
      final original = await service(store);
      await original.createFolderBinding('folder');
      disposeService(original);
      store.value!['pruneRemote'] = List.generate(
        5001,
        (index) => 'obsolete-$index',
      );
      final restarted = await service(store);
      await _withNetwork(
        () => restarted.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
      );
      expect(restarted.error, isNull);
      expect(
        dav.deletePaths.where((path) => path.endsWith('.json')),
        hasLength(5001),
      );
      expect(store.value!['pruneRemote'], isEmpty);
      expect(dav.putPaths.where((path) => path.endsWith('.json')), isNotEmpty);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  for (final malformedJson in [true, false]) {
    test(
      'WebDAV ${malformedJson ? 'damaged JSON' : 'bad authentication'} does not block valid changes and a repaired record is retried',
      () async {
        final dav = await _ServiceDavServer.start();
        final local = await seed('folder', 'video', position: 1000);
        final store = MemoryProgressSyncStore();
        final sync = await service(store);
        await sync.createFolderBinding('folder');
        await _withNetwork(
          () => sync.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
        );
        final baseline = (await _events(store)).single;
        SyncProgressEvent incoming(String id, int sequence, int position) =>
            SyncProgressEvent(
              id: id,
              groupId: baseline.groupId,
              mediaKey: baseline.mediaKey,
              title: baseline.title,
              deviceId: 'remote',
              deviceName: 'remote',
              clock: {...baseline.clock, 'remote': sequence},
              value: SyncProgressValue(
                positionMs: position,
                completed: false,
                continueEnrolled: false,
                lastPlayedAtMs: null,
                watchMs: 0,
              ),
              createdAtMs: 1,
            );
        final good = incoming('good-event', 1, 2000);
        final repaired = incoming('repair-event', 2, 3000);
        final goodEnvelope = await _encryptEvent(store, good);
        final repairedEnvelope = await _encryptEvent(store, repaired);
        String davPath(String id) =>
            '/dav/FluentPlayerProgress/v2/$kApplicationId/events/${digest.sha256.convert(utf8.encode(id))}.json';
        dav.files[davPath(good.id)] = utf8.encode(jsonEncode(goodEnvelope));
        final damaged = malformedJson
            ? utf8.encode('{broken')
            : utf8.encode(
                jsonEncode({
                  ...repairedEnvelope,
                  'mac': base64Encode(List.filled(16, 0)),
                }),
              );
        dav.files[davPath(repaired.id)] = damaged;
        await sync.syncNow();
        expect(local.lastPositionMs, 2000);
        expect(sync.error, isNotNull);
        expect(dav.files[davPath(repaired.id)], damaged);
        dav.files[davPath(repaired.id)] = utf8.encode(
          jsonEncode(repairedEnvelope),
        );
        await sync.syncNow();
        expect(local.lastPositionMs, 3000);
        expect(sync.error, isNull);
      },
    );
  }

  test(
    'superseded podcast snapshots are pruned only after replacement upload succeeds',
    () async {
      final podcastStore = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      final controller = PodcastController(
        store: podcastStore,
        client: client,
        mediaStore: PodcastMediaStore(
          root: Directory(p.join(root.path, 'podcast-media')),
          store: podcastStore,
          http: client.http,
        ),
      );
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
        controller,
        library: library,
      );
      ProgressSyncService? sync;
      try {
        final feed = client.parser.parse(
          utf8.encode(podcastFixture()),
          'https://example.com/rss',
        );
        feed.channel.imageUrl = '';
        final card = (await PodcastRuntime.instance.subscribe(feed))!;
        podcastStore.setSetting(null, 'autoDownload', true);
        podcastStore.setSetting(feed.channel.id, 'autoDownload', true);
        final store = MemoryProgressSyncStore();
        sync = await service(store);
        await sync.createFolderBinding(card.id);
        final dav = await _ServiceDavServer.start();
        await _withNetwork(
          () => sync!.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
        );
        Set<String> podcastFiles() => dav.files.entries
            .where((entry) {
              final data = jsonDecode(utf8.decode(entry.value));
              return data is Map && data['kind'] == 'podcast-event';
            })
            .map((entry) => entry.key)
            .toSet();
        final original = podcastFiles();
        expect(original, isNotEmpty);
        final receiver = PodcastStore(sqlite3.openInMemory());
        try {
          final group = (store.value!['groups'] as List).cast<Map>().single;
          final key = base64Decode(group['key'] as String);
          Map<String, dynamic>? snapshot;
          for (final path in original) {
            final record = Map<String, dynamic>.from(
              jsonDecode(utf8.decode(dav.files[path]!)) as Map,
            );
            snapshot =
                await PodcastSyncCodec.receive(record, key, receiver) ??
                snapshot;
          }
          expect(snapshot, isNotNull);
          expect(snapshot!.containsKey('globalSettings'), isFalse);
          expect(snapshot.containsKey('globalSettingsUpdatedMs'), isFalse);
          expect(snapshot.containsKey('settings'), isFalse);
          expect(snapshot.containsKey('states'), isFalse);
        } finally {
          receiver.close();
        }
        podcastStore.setSetting(null, 'autoDownload', false);
        await sync.syncNow();
        expect(podcastFiles(), original);
        podcastStore.setSetting(feed.channel.id, 'speed', 1.5);
        await sync.syncNow();
        expect(podcastFiles(), original);
        final channel = podcastStore.channel(feed.channel.id)!;
        channel.title = 'Updated channel';
        podcastStore.write('channel', channel.id, channel.toJson());
        dav.failJsonPuts = true;
        await sync.syncNow();
        expect(podcastFiles().containsAll(original), isTrue);
        expect(store.value!['pruneRemote'], isNotEmpty);
        expect(sync.error, isNotNull);
        dav.failJsonPuts = false;
        await sync.syncNow();
        expect(podcastFiles().intersection(original), isEmpty);
        expect(podcastFiles(), isNotEmpty);
        expect(store.value!['pruneRemote'], isEmpty);
        expect(sync.error, isNull);
      } finally {
        if (sync != null) disposeService(sync);
        PodcastRuntime.debugOverride = null;
        await controller.close();
        podcastStore.close();
      }
    },
  );

  test('podcast episode state syncs without creating library adapters', () async {
    final podcastStore = PodcastStore(sqlite3.openInMemory());
    final client = PodcastClient();
    final controller = PodcastController(
      store: podcastStore,
      client: client,
      mediaStore: PodcastMediaStore(
        root: Directory(p.join(root.path, 'episode-media')),
        store: podcastStore,
        http: client.http,
      ),
    );
    PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
      controller,
      library: library,
    );
    ProgressSyncService? sync;
    try {
      final feed = client.parser.parse(
        utf8.encode(podcastFixture()),
        'https://example.com/rss',
      );
      feed.channel.imageUrl = '';
      final card = (await PodcastRuntime.instance.subscribe(feed))!;
      final episode = feed.episodes.first;
      expect(PodcastRuntime.instance.adapterFor(episode.id), isNull);
      controller.setPlayed(episode.id, true, project: false);
      final store = MemoryProgressSyncStore();
      String? active;
      sync = await service(store, active: () => active);
      await sync.createFolderBinding(card.id);
      await sync.flush();
      final first = (await _events(
        store,
      )).singleWhere((event) => event.mediaKey == 'podcast:${episode.id}');
      expect(first.value.completed, isTrue);
      expect(PodcastRuntime.instance.adapterFor(episode.id), isNull);

      final dav = await _ServiceDavServer.start();
      final remote = SyncProgressEvent(
        id: 'remote-podcast-progress',
        groupId: first.groupId,
        mediaKey: first.mediaKey,
        title: episode.title,
        deviceId: 'remote',
        deviceName: '手机',
        clock: {...first.clock, 'remote': 1},
        value: const SyncProgressValue(
          positionMs: 25000,
          completed: false,
          continueEnrolled: true,
          lastPlayedAtMs: 100,
          watchMs: 0,
        ),
        createdAtMs: 100,
      );
      final envelope = await _encryptEvent(store, remote);
      dav.files['/dav/FluentPlayerProgress/v2/$kApplicationId/events/${digest.sha256.convert(utf8.encode(remote.id))}.json'] =
          utf8.encode(jsonEncode(envelope));
      active = episode.id;
      await _withNetwork(
        () => sync!.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
      );
      expect(controller.state(episode.id).played, isTrue);
      active = null;
      await sync.preparePlayback(episode.id);
      expect(controller.state(episode.id).played, isFalse);
      expect(controller.state(episode.id).positionMs, 25000);
      expect(PodcastRuntime.instance.adapterFor(episode.id), isNull);

      controller.setPlayed(episode.id, true, project: false);
      await sync.flush();
      await sync.syncNow();
      final updated = (await _events(
        store,
      )).singleWhere((event) => event.mediaKey == remote.mediaKey);
      expect(updated.value.completed, isTrue);
      expect(updated.descendsFrom(remote), isTrue);
      expect(PodcastRuntime.instance.adapterFor(episode.id), isNull);

      final simultaneous = SyncProgressEvent(
        id: 'concurrent-podcast-progress',
        groupId: first.groupId,
        mediaKey: first.mediaKey,
        title: episode.title,
        deviceId: 'third-device',
        deviceName: '平板',
        clock: const {'third-device': 1},
        value: const SyncProgressValue(
          positionMs: 5000,
          completed: false,
          continueEnrolled: true,
          lastPlayedAtMs: 200,
          watchMs: 0,
        ),
        createdAtMs: 200,
      );
      dav.files['/dav/FluentPlayerProgress/v2/$kApplicationId/events/${digest.sha256.convert(utf8.encode(simultaneous.id))}.json'] =
          utf8.encode(jsonEncode(await _encryptEvent(store, simultaneous)));
      await sync.syncNow();
      expect(controller.state(episode.id).played, isTrue);
      final conflict = sync.conflicts.single;
      expect(
        conflict.choices.map((event) => event.id),
        contains(simultaneous.id),
      );
      await sync.resolveConflict(conflict.id, simultaneous.id);
      expect(controller.state(episode.id).played, isFalse);
      expect(controller.state(episode.id).positionMs, 5000);
      expect(sync.conflicts, isEmpty);
    } finally {
      if (sync != null) disposeService(sync);
      PodcastRuntime.debugOverride = null;
      await controller.close();
      podcastStore.close();
    }
  });

  test(
    'podcast sync creates a subscription reference and restores unprojected state',
    () async {
      final sourceStore = PodcastStore(sqlite3.openInMemory());
      final receiverStore = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      PodcastController makeController(
        PodcastStore podcastStore,
        String name,
      ) => PodcastController(
        store: podcastStore,
        client: client,
        mediaStore: PodcastMediaStore(
          root: Directory(p.join(root.path, name)),
          store: podcastStore,
          http: client.http,
        ),
      );
      final sourceController = makeController(sourceStore, 'source-podcasts');
      final receiverController = makeController(
        receiverStore,
        'receiver-podcasts',
      );
      PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
        sourceController,
        library: library,
      );
      ProgressSyncService? sender, receiver;
      try {
        final feed = client.parser.parse(
          utf8.encode(podcastFixture()),
          'https://example.com/rss',
        );
        feed.channel.imageUrl = '';
        final sourceCard = (await PodcastRuntime.instance.subscribe(feed))!;
        final episode = feed.episodes.first;
        sourceController.setPlayed(episode.id, true, project: false);
        sourceStore.setSetting(feed.channel.id, 'autoDownload', true);
        final state = MemoryProgressSyncStore();
        sender = await service(state);
        await sender.createFolderBinding(sourceCard.id);
        final code = _groupCode(state, sourceCard.id);
        final dav = await _ServiceDavServer.start();
        await _withNetwork(
          () => sender!.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
        );
        disposeService(sender);
        sender = null;

        PodcastRuntime.debugOverride = PodcastRuntime.forTesting(
          receiverController,
          library: library,
        );
        receiverStore.setSetting(null, 'autoDownload', false);
        final target = await library.createCollection('接收播客', null);
        receiver = await service(MemoryProgressSyncStore());
        await receiver.importSyncCode(code);
        await receiver.acceptInvitation(
          receiver.invitations.single.groupId,
          target.id,
        );
        await _withNetwork(
          () =>
              receiver!.configureWebDav(ProgressSyncWebDavConfig(url: dav.url)),
        );
        expect(
          receiverStore.channel(feed.channel.id)?.feedUrl,
          feed.channel.feedUrl,
        );
        expect(target.podcastRef?.channelId, feed.channel.id);
        expect(receiverController.state(episode.id).played, isTrue);
        expect(PodcastRuntime.instance.adapterFor(episode.id), isNull);
        expect(
          receiverStore.effective(feed.channel.id).flag('autoDownload'),
          isFalse,
        );
        expect(receiverStore.read('download', episode.id), isNull);
      } finally {
        if (sender != null) disposeService(sender);
        if (receiver != null) disposeService(receiver);
        PodcastRuntime.debugOverride = null;
        await sourceController.close();
        await receiverController.close();
        sourceStore.close();
        receiverStore.close();
      }
    },
  );
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

class _ProtectedReadStore implements ProgressSyncStore {
  _ProtectedReadStore({this.error, this.snapshot});
  final Object? error;
  final Map<String, dynamic>? snapshot;
  int writes = 0;
  @override
  Future<Map<String, dynamic>?> read() async {
    if (error != null) throw error!;
    return snapshot == null ? null : _copy(snapshot!);
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    writes++;
  }
}

class _FailingWriteStore extends MemoryProgressSyncStore {
  bool failWrites = false;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (failWrites) throw const FileSystemException('simulated full storage');
    await super.write(value);
  }
}

class _ServiceDavServer {
  _ServiceDavServer(this.server);
  final HttpServer server;
  final directories = <String>{'/', '/dav/'};
  final files = <String, List<int>>{};
  final putPaths = <String>[];
  final deletePaths = <String>[];
  bool failJsonPuts = false;
  Completer<void>? blockedRequest;
  Completer<void>? _gate;
  bool _blockNext = false;
  String get url => 'http://127.0.0.1:${server.port}/dav/';

  static Future<_ServiceDavServer> start() async {
    final fixture = _ServiceDavServer(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    fixture.server.listen(fixture._handle);
    addTearDown(() async {
      fixture.releaseListing();
      await fixture.server.close(force: true);
    });
    return fixture;
  }

  void blockNextListing() {
    _blockNext = true;
    blockedRequest = Completer<void>();
    _gate = Completer<void>();
  }

  void releaseListing() {
    if (_gate?.isCompleted == false) _gate!.complete();
  }

  String _entry(String path, {bool directory = false}) =>
      '''
<d:response><d:href>$path</d:href><d:propstat><d:prop><d:resourcetype>
${directory ? '<d:collection/>' : ''}</d:resourcetype></d:prop>
<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>''';

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final bytes = await request.fold<List<int>>(
      [],
      (value, part) => value..addAll(part),
    );
    final response = request.response;
    switch (request.method) {
      case 'PROPFIND':
        if (!directories.contains(path)) {
          response.statusCode = 404;
          break;
        }
        if (_blockNext && request.headers.value('Depth') == '1') {
          _blockNext = false;
          blockedRequest!.complete();
          await _gate!.future;
        }
        final entries = [_entry(path, directory: true)];
        if (request.headers.value('Depth') == '1') {
          entries.addAll(
            files.keys
                .where(
                  (name) =>
                      name.startsWith(path) &&
                      !name.substring(path.length).contains('/'),
                )
                .map(_entry),
          );
        }
        response.statusCode = 207;
        response.write(
          '<d:multistatus xmlns:d="DAV:">${entries.join()}</d:multistatus>',
        );
      case 'MKCOL':
        directories.add(path);
        response.statusCode = 201;
      case 'PUT':
        putPaths.add(path);
        if (failJsonPuts && path.endsWith('.json')) {
          response.statusCode = 503;
          break;
        }
        if (files.containsKey(path) &&
            request.headers.value('If-None-Match') == '*') {
          response.statusCode = 412;
        } else {
          files[path] = bytes;
          response.statusCode = 201;
        }
      case 'GET':
        if (files.containsKey(path)) {
          response.add(files[path]!);
        } else {
          response.statusCode = 404;
        }
      case 'DELETE':
        deletePaths.add(path);
        response.statusCode = files.remove(path) == null ? 404 : 204;
      default:
        response.statusCode = 405;
    }
    await response.close();
  }
}
