import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';

PodcastEpisode _episode(PodcastChannel channel, int index) {
  return PodcastEpisode(
    id: 'ep-$index',
    channelId: channel.id,
    title: index % 5 == 0 ? '很长的节目标题' * 8 : '第 $index 集',
    media: [
      PodcastMedia(
        url: 'https://cdn.example/audio/$index.mp3',
        mimeType: index.isEven ? 'audio/mpeg' : 'video/mp4',
      ),
    ],
    imageUrl: index % 17 == 0 ? '' : 'https://cdn.example/art/$index.jpg',
    publishedMs: 1_700_000_000_000 + index,
    durationMs: 60_000 + index,
    season: index < 10 ? 1 : 2,
  );
}

Future<
  ({
    PodcastStore store,
    PodcastController controller,
    PodcastRuntime runtime,
    Directory root,
  })
>
seed(int count) async {
  final store = PodcastStore(sqlite3.openInMemory());
  final channel = PodcastChannel(
    id: 'channel-1',
    feedUrl: 'https://example.com/rss',
    title: '频道',
    imageUrl: 'https://cdn.example/channel.jpg',
  );
  store.write('channel', channel.id, channel.toJson());
  final episodes = <PodcastEpisode>[
    for (var index = 0; index < count; index++) _episode(channel, index),
  ];
  for (final episode in episodes) {
    store.write('episode', episode.id, episode.toJson(), channel: channel.id);
  }
  final root = await Directory.systemTemp.createTemp('podcast-smooth-');
  final client = PodcastClient();
  final controller = PodcastController(
    store: store,
    client: client,
    mediaStore: PodcastMediaStore(root: root, store: store, http: client.http),
  );
  final runtime = PodcastRuntime.forTesting(
    controller,
    playlist: PlaylistManager(),
  );
  return (store: store, controller: controller, runtime: runtime, root: root);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'starting a 500 episode queue does not persist every row or shrink on retry',
    () async {
      final harness = await seed(500);
      addTearDown(() async {
        await harness.controller.close();
        harness.runtime.dispose();
        harness.store.close();
        if (harness.root.existsSync()) {
          await harness.root.delete(recursive: true);
        }
      });
      final episodes = [
        for (var index = 0; index < 500; index++)
          harness.store.episode('ep-$index')!,
      ];
      final before = harness.store.catalogQueries;
      await harness.runtime.play(episodes.first, queue: episodes);
      final ids = harness.runtime.playlist!.playlist
          .map((item) => item.sourceRef!.podcast!.episodeId)
          .toList();
      expect(ids, [for (final episode in episodes) episode.id]);
      expect(harness.runtime.persistedEpisodeIds.toSet(), {'ep-0'});
      expect(harness.store.catalogQueries, before);

      await harness.runtime.play(episodes[400]);
      final afterRetry = harness.runtime.playlist!.playlist
          .map((item) => item.sourceRef!.podcast!.episodeId)
          .toList();
      expect(afterRetry, ids);
      expect(harness.runtime.persistedEpisodeIds.toSet(), {'ep-0', 'ep-400'});

      final record = harness.store.read('queue', 'current')!;
      expect(record['version'], 2);
      expect((record['entries'] as List).length, 500);
      expect(record['ids'], ids);
    },
  );

  test(
    'a playback retry without a queue does not replace members with one episode',
    () async {
      final harness = await seed(8);
      addTearDown(() async {
        await harness.controller.close();
        harness.runtime.dispose();
        harness.store.close();
        if (harness.root.existsSync()) {
          await harness.root.delete(recursive: true);
        }
      });
      final episodes = [
        for (var index = 0; index < 8; index++)
          harness.store.episode('ep-$index')!,
      ];
      await harness.runtime.play(episodes[2], queue: episodes);
      await harness.runtime.play(episodes[2]);
      expect(harness.runtime.playlist!.playlist, hasLength(8));
      expect(
        harness.runtime.playlist!.playlist.map((item) => item.id).toList(),
        [for (final episode in episodes) episode.id],
      );
    },
  );

  test(
    'saved entries restore order, skip a missing row, and keep a local file',
    () async {
      final harness = await seed(4);
      final localFile = File(
        '${harness.root.path}${Platform.pathSeparator}local.mp3',
      );
      await localFile.writeAsBytes([1, 2, 3]);
      addTearDown(() async {
        await harness.controller.close();
        harness.runtime.dispose();
        harness.store.close();
        if (harness.root.existsSync()) {
          await harness.root.delete(recursive: true);
        }
      });
      final local = VideoItem(
        id: 'local-1',
        path: localFile.path,
        title: '本地',
        durationMs: 1000,
        lastUpdated: 1,
        type: MediaType.audio,
      );
      final first = harness.runtime.itemFor(
        harness.store.episode('ep-0')!,
        persist: false,
      );
      final third = harness.runtime.itemFor(
        harness.store.episode('ep-2')!,
        persist: false,
      );
      final items = await Future.wait([first, third]);
      harness.runtime.playlist!.setPlaylist([
        items[0],
        local,
        items[1],
      ], currentItemId: local.id);
      harness.runtime.reorderPodcastQueue(['ep-2', 'ep-0']);
      final record = harness.store.read('queue', 'current')!;
      expect(
        (record['entries'] as List).map((row) => (row as Map)['kind']).toList(),
        ['podcast', 'media', 'podcast'],
      );

      final saved = harness.store.read('queue', 'current')!;
      expect(
        (saved['entries'] as List)
            .map((row) => (row as Map)['mediaId'])
            .toList(),
        ['ep-2', 'local-1', 'ep-0'],
      );
      harness.store.remove('episode', 'ep-2');
      harness.runtime.playlist!.setPlaylist(const []);
      final restored = await harness.runtime.restoreSavedQueue(
        expectedMediaId: 'ep-0',
      );
      expect(restored, isTrue);
      expect(
        harness.runtime.playlist!.playlist.map((item) => item.id).toList(),
        ['ep-0'],
      );
    },
  );

  test('old id-only queue records still restore', () async {
    final harness = await seed(3);
    addTearDown(() async {
      await harness.controller.close();
      harness.runtime.dispose();
      harness.store.close();
      if (harness.root.existsSync()) await harness.root.delete(recursive: true);
    });
    harness.store.write('queue', 'current', {
      'ids': ['ep-2', 'missing', 'ep-0'],
      'custom': true,
    });
    final restored = await harness.runtime.restoreSavedQueue(
      expectedMediaId: 'ep-0',
    );
    expect(restored, isTrue);
    expect(harness.runtime.playlist!.playlist.map((item) => item.id).toList(), [
      'ep-2',
      'ep-0',
    ]);
  });

  test('catalog queries stay cached while download bytes change', () {
    final store = PodcastStore(sqlite3.openInMemory());
    addTearDown(store.close);
    final channel = PodcastChannel(
      id: 'channel-1',
      feedUrl: 'https://example.com/rss',
      title: '频道',
    );
    store.write('channel', channel.id, channel.toJson());
    for (var index = 0; index < 30; index++) {
      final episode = _episode(channel, index);
      store.write('episode', episode.id, episode.toJson(), channel: channel.id);
    }
    final snapshot = PodcastCatalogSnapshot();
    snapshot.resolve(
      store: store,
      channelId: channel.id,
      filter: 'all',
      query: '',
      sort: 'newest',
      hidePlayed: false,
      downloaded: const {},
      countFilters: const ['all', 'unplayed'],
    );
    final queries = store.catalogQueries;
    expect(snapshot.episodes, hasLength(30));
    snapshot.resolve(
      store: store,
      channelId: channel.id,
      filter: 'all',
      query: '',
      sort: 'newest',
      hidePlayed: false,
      downloaded: const {},
      countFilters: const ['all', 'unplayed'],
    );
    expect(store.catalogQueries, queries);
    expect(snapshot.resolutions, 1);
    snapshot.resolve(
      store: store,
      channelId: channel.id,
      filter: 'all',
      query: '第 4',
      sort: 'newest',
      hidePlayed: false,
      downloaded: const {},
      countFilters: const ['all', 'unplayed'],
    );
    expect(snapshot.resolutions, 2);
    expect(store.catalogQueries, greaterThan(queries));
  });

  test('search applies the latest text and clears immediately', () async {
    final debounce = PodcastSearchDebounce(
      wait: const Duration(milliseconds: 80),
    );
    final applied = <String>[];
    debounce.submit('a', applied.add);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    debounce.submit('ab', applied.add);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(applied, ['ab']);
    debounce.submit('', applied.add);
    expect(applied, ['ab', '']);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(applied, ['ab', '']);
    debounce.dispose();
  });

  test('a direct tap does not wait for the previous episode resolve', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    final previousPlatform = VideoPlayerPlatform.instance;
    final previousResolve = PodcastPlaybackHooks.resolve;
    VideoPlayerPlatform.instance = _ReadyPlatform();
    final gates = <String, Completer<Uri>>{};
    PodcastPlaybackHooks.resolve = (item) {
      final gate = Completer<Uri>();
      gates[item.id] = gate;
      return gate.future;
    };
    final playback = MediaPlaybackService.forTesting();
    VideoItem episode(String id) => VideoItem(
      id: id,
      path: 'podcast:$id',
      title: id,
      durationMs: 1000,
      lastUpdated: 1,
      type: MediaType.audio,
      sourceRef: MediaSourceRef(
        value: 'podcast:$id',
        kind: MediaSourceKind.podcastEpisode,
        podcast: PodcastEpisodeRef(
          channelId: 'channel-1',
          episodeId: id,
          feedUrl: 'https://example.com/rss',
          mediaUrl: 'https://cdn.example/$id.mp3',
        ),
      ),
    );
    final slow = episode('slow-b');
    final fast = episode('fast-c');
    var slowDone = false;
    final slowPlay = playback.playPlaylistItem(slow);
    unawaited(slowPlay.whenComplete(() => slowDone = true));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(gates.containsKey(slow.id), isTrue);
    expect(slowDone, isFalse);
    final fastPlay = playback.playPlaylistItem(fast);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(slowDone, isTrue, reason: 'B must stop waiting when C is tapped');
    gates[fast.id]!.complete(Uri.parse('http://127.0.0.1/fast.mp3'));
    await fastPlay.timeout(const Duration(seconds: 5));
    expect(playback.currentItem?.id, fast.id);
    gates[slow.id]!.complete(Uri.parse('http://127.0.0.1/slow.mp3'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(playback.currentItem?.id, fast.id);
    PodcastPlaybackHooks.resolve = previousResolve;
    VideoPlayerPlatform.instance = previousPlatform;
    playback.dispose();
  });
}

class _ReadyPlatform extends VideoPlayerPlatform {
  final events = <int, StreamController<VideoEvent>>{};
  final playing = <int>{};
  var next = 1;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = next++;
    events[id] = StreamController<VideoEvent>();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    scheduleMicrotask(() {
      events[playerId]?.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 30),
          size: Size.zero,
        ),
      );
    });
    return events[playerId]!.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    await events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async => playing.add(playerId);

  @override
  Future<void> pause(int playerId) async => playing.remove(playerId);

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => playing.contains(playerId)
      ? const Duration(milliseconds: 40)
      : Duration.zero;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setAllowBackgroundPlayback(bool allowBackgroundPlayback) async {}

  @override
  Widget buildView(int playerId) => const SizedBox.shrink();
}
