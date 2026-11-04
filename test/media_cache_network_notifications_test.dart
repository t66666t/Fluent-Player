import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/media_cache/media_cache_backend.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/network/network_http.dart';

import 'media_cache_service_test.dart' show FakeBackend, until;
import 'network_settings_service_test.dart'
    show MemoryNetworkStore, MemoryCredentials;

// No network client: hold fake bytes at 10% until cancellation. Stop gates let
// tests pause manually while an old transfer is still releasing resources.
class _HeldBackend extends FakeBackend {
  _HeldBackend(super.root);
  final starts = <String, int>{};
  final tokens = <String, CancelToken>{};
  final stopGates = <String, Completer<void>>{};

  @override
  Future<File> download(
    CacheTask task,
    CacheDownloadPlan plan,
    MediaCachePreferences preferences,
    CancelToken cancel,
    void Function(CacheTransferProgress) onProgress,
  ) async {
    starts.update(task.id, (count) => count + 1, ifAbsent: () => 1);
    tokens[task.id] = cancel;
    onProgress(const CacheTransferProgress(received: 1024, total: 10240));
    await cancel.whenCancel;
    await stopGates[task.id]?.future;
    cancel.throwIfCancellationRequested();
    throw StateError('fake transfer must be cancelled');
  }
}

CacheSource _source(String id, NetworkScope scope) => CacheSource(
  itemId: id,
  title: id,
  kind: MediaType.video,
  ref: switch (scope) {
    NetworkScope.bilibili => MediaSourceRef(
      value: 'BV$id',
      kind: MediaSourceKind.bilibiliStream,
      bvid: 'BV$id',
      cid: 123,
    ),
    NetworkScope.cloudDrive => MediaSourceRef(
      value: id,
      kind: MediaSourceKind.cloudDrive,
      cloudDrive: CloudDriveSourceRef(
        providerId: 'baidu',
        remoteAccountId: 'offline',
        driveId: '',
        fileId: id,
      ),
    ),
    _ => MediaSourceRef(
      value: id,
      kind: MediaSourceKind.podcastEpisode,
      podcast: PodcastEpisodeRef(
        channelId: 'channel',
        episodeId: id,
        feedUrl: 'https://feed.invalid/rss',
        mediaUrl: scope == NetworkScope.podcastsDomestic
            ? 'https://audio.xmcdn.com/$id.mp3'
            : 'https://audio.invalid/$id.mp3',
      ),
    ),
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late NetworkSettingsService settings;
  late _HeldBackend backend;
  late MediaCacheService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp(
      'cache-network-notifications-',
    );
    settings = NetworkSettingsService(
      store: MemoryNetworkStore(),
      credentials: MemoryCredentials(),
      migrateLegacy: false,
    );
    await settings.ready;
    await settings.setUnifiedMode(NetworkMode.system);
    backend = _HeldBackend(root);
    service = MediaCacheService(
      backend: backend,
      journal: File('${root.path}/queue.json'),
      observeNetwork: false,
      networkSettings: settings,
    );
    await service.initialize();
    service.preferences.parallelTasks = 8;
  });

  tearDown(() async {
    for (final gate in backend.stopGates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await service.shutdown();
    service.dispose();
    settings.dispose();
    await root.delete(recursive: true);
  });

  Future<CacheTask> start(String id, NetworkScope scope) async {
    final task = (await service.enqueue(_source(id, scope)))!;
    await until(() => backend.starts.containsKey(task.id));
    return task;
  }

  test(
    'system notification bursts preserve Bilibili, cloud and both podcast scopes',
    () async {
      final tasks = [
        for (final scope in [
          NetworkScope.bilibili,
          NetworkScope.cloudDrive,
          NetworkScope.podcastsDomestic,
          NetworkScope.podcasts,
        ])
          await start(scope.name, scope),
      ];
      for (var i = 0; i < 100; i++) {
        settings.deviceNetworkChanged();
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      for (final task in tasks) {
        expect(task.state, CacheTaskState.downloading);
        expect(task.received, 1024);
        expect(backend.starts[task.id], 1);
        expect(backend.tokens[task.id]!.isCancelled, isFalse);
      }
      await service.pauseAll();
      for (var i = 0; i < 50; i++) {
        settings.deviceNetworkChanged();
      }
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        tasks.every((task) => task.state == CacheTaskState.paused),
        isTrue,
      );
      expect(backend.starts.values, everyElement(1));
    },
  );

  test('unrelated settings never cancel a cache transfer', () async {
    final task = await start('bili', NetworkScope.bilibili);
    await settings.setUnifiedMode(null);
    // Wait for the intentional unified policy handoff to finish first.
    await until(() => backend.starts[task.id] == 2);
    final token = backend.tokens[task.id]!;
    await settings.setMode(NetworkScope.translation, NetworkMode.direct);
    await settings.setMode(NetworkScope.ytDlpOther, NetworkMode.direct);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(backend.starts[task.id], 2);
    expect(token.isCancelled, isFalse);
  });

  test(
    'a scope policy edit reconnects only its affected cache source',
    () async {
      await settings.setUnifiedMode(null);
      final bili = await start('bili', NetworkScope.bilibili);
      final cloud = await start('cloud', NetworkScope.cloudDrive);
      final podcast = await start('podcast', NetworkScope.podcasts);
      await settings.setMode(NetworkScope.bilibili, NetworkMode.system);
      await until(() => backend.starts[bili.id] == 2);
      expect(backend.starts[cloud.id], 1);
      expect(backend.starts[podcast.id], 1);
      expect(backend.tokens[cloud.id]!.isCancelled, isFalse);
      expect(backend.tokens[podcast.id]!.isCancelled, isFalse);
    },
  );

  test('manual pause wins during a multi-task policy handoff', () async {
    await settings.setUnifiedMode(null);
    final first = await start('first', NetworkScope.bilibili);
    final second = await start('second', NetworkScope.bilibili);
    final gate = backend.stopGates[first.id] = Completer<void>();
    await settings.setMode(NetworkScope.bilibili, NetworkMode.system);
    expect(first.state, CacheTaskState.waitingNetwork);
    await service.pause(second.id);
    gate.complete();
    await until(() => backend.starts[first.id] == 2);
    expect(second.state, CacheTaskState.paused);
    expect(backend.starts[second.id], 1);
  });

  test(
    'foreground auto-resume cannot override a manual pause during shutdown',
    () async {
      final task = await start('bili', NetworkScope.bilibili);
      final gate = backend.stopGates[task.id] = Completer<void>();
      final waiting = service.pause(
        task.id,
        state: CacheTaskState.waitingNetwork,
      );
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      final manual = service.pause(task.id);
      gate.complete();
      await Future.wait([waiting, manual]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(task.state, CacheTaskState.paused);
      expect(backend.starts[task.id], 1);
    },
  );
}
