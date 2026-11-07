import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_sync_codec.dart';
import 'podcast_core_test.dart' show podcastFixture;

void main() {
  late Directory directory;
  late PodcastStore store;
  late PodcastController controller;
  late HttpServer server;
  var version = 1, requests = 0;
  var activeMedia = 0, peakMedia = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'fluent-podcast-controller-',
    );
    store = PodcastStore(sqlite3.openInMemory());
    version = 1;
    requests = 0;
    activeMedia = peakMedia = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      final bulk = request.uri.path.startsWith('/bulk-');
      if (bulk) {
        activeMedia++;
        if (activeMedia > peakMedia) peakMedia = activeMedia;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        request.response.headers.set('content-type', 'audio/mpeg');
        request.response.contentLength = 4096;
        request.response.add(List<int>.filled(4096, 0));
        await request.response.close();
        activeMedia--;
        return;
      }
      final tag = '"v$version"';
      request.response.headers.set('etag', tag);
      if (request.headers.value('if-none-match') == tag) {
        request.response.statusCode = 304;
      } else {
        request.response.add(utf8.encode(podcastFixture(second: version > 1)));
      }
      await request.response.close();
      if (bulk) activeMedia--;
    });
    final client = PodcastClient(
      http: PodcastHttp(clientFactory: () => HttpClient()),
    );
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(
        root: Directory('${directory.path}/media'),
        store: store,
        http: client.http,
      ),
    );
    controller.connectivity = [ConnectivityResult.wifi];
  });
  tearDown(() async {
    await controller.close();
    await server.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });
  Future<PodcastChannel> subscribe() async => controller.subscribe(
    (await controller.client.resolve(
      'http://127.0.0.1:${server.port}/rss',
    )).feed,
  );
  test('legacy RSS rows require a full refresh before remote use', () async {
    final channel = await subscribe();
    final episode = store.episodes(channel.id).single;
    final legacy = episode.toJson()..remove('sourceFeedUrl');
    store.write('episode', episode.id, legacy, channel: channel.id);
    controller.updateState(episode.id, (state) => state.positionMs = 4567);
    // The stored ETag matches the server. A conditional request would return
    // 304 and could not establish whether this row came from an RSS enclosure.
    channel.etag = '"v1"';
    store.write('channel', channel.id, channel.toJson());
    await controller.refreshChannel(channel.id);
    expect(store.episode(episode.id)!.sourceFeedUrl, channel.feedUrl);
    expect(controller.state(episode.id).positionMs, 4567);
    expect(store.episodes(channel.id).length, 1);
  });
  test(
    'published history confirms legacy enclosures without resetting progress',
    () async {
      final channel = await subscribe();
      final episode = store.episodes(channel.id).single;
      final legacy = episode.toJson()..remove('sourceFeedUrl');
      store.write('episode', episode.id, legacy, channel: channel.id);
      controller.updateState(episode.id, (state) => state.positionMs = 8765);
      channel.nextPage = '${channel.feedUrl}?page=2';
      store.write('channel', channel.id, channel.toJson());
      await controller.refreshChannel(channel.id, history: true);
      expect(
        store.episode(episode.id)!.sourceFeedUrl,
        '${channel.feedUrl}?page=2',
      );
      expect(store.episode(episode.id)!.discoveredMs, episode.discoveredMs);
      expect(controller.state(episode.id).positionMs, 8765);
      expect(store.channel(channel.id)!.feedUrl, channel.feedUrl);
    },
  );
  test(
    'first subscription establishes a baseline, later refresh creates only new notices',
    () async {
      final channel = await subscribe();
      expect(controller.newCount(channel.id), 0);
      expect(store.list('notice'), isEmpty);
      store.setSetting(channel.id, 'notify', true);
      version = 2;
      await controller.refreshChannel(channel.id);
      expect(controller.newCount(channel.id), 1);
      expect(store.list('notice').length, 1);
      await controller.refreshChannel(channel.id);
      expect(store.list('notice').length, 1);
      expect(store.episodes(channel.id).length, 2);
      controller.markSeen(channel.id);
      expect(controller.newCount(channel.id), 0);
      expect(controller.unheardCount(channel.id), 2);
    },
  );
  test(
    'duplicate subscriptions locate the original channel without resetting progress',
    () async {
      final first = await subscribe();
      final episode = store.episodes(first.id).single;
      controller.updateState(episode.id, (s) => s.positionMs = 1234);
      store.write(
        'episode',
        episode.id,
        episode.toJson()..remove('sourceFeedUrl'),
        channel: first.id,
      );
      final second = await subscribe();
      expect(first.id, second.id);
      expect(controller.channels.length, 1);
      expect(controller.state(episode.id).positionMs, 1234);
      expect(store.episode(episode.id)!.sourceFeedUrl, first.feedUrl);
    },
  );
  test(
    'starting an episode leaves unheard, and mark unheard returns it',
    () async {
      final channel = await subscribe();
      final episode = store.episodes(channel.id).single;
      final snapshot = PodcastCatalogSnapshot();
      void resolve(String filter) => snapshot.resolve(
        store: store,
        channelId: channel.id,
        filter: filter,
        query: '',
        sort: 'newest',
        hidePlayed: false,
        downloaded: const {},
        countFilters: const ['unplayed', 'inProgress', 'played'],
      );

      resolve('unplayed');
      expect(snapshot.ids, [episode.id]);
      controller.updateState(
        episode.id,
        (state) => state.positionMs = 1000,
        debounced: true,
      );
      resolve('unplayed');
      expect(snapshot.ids, isEmpty);
      resolve('inProgress');
      expect(snapshot.ids, [episode.id]);

      final queries = store.catalogQueries;
      final revision = store.catalogRevision;
      controller.updateState(
        episode.id,
        (state) => state.positionMs = 2000,
        debounced: true,
      );
      resolve('inProgress');
      expect(store.catalogQueries, queries);
      expect(store.catalogRevision, revision);
      expect(store.state(episode.id).positionMs, 1000);
      expect(controller.state(episode.id).positionMs, 2000);

      controller.setPlayed(episode.id, false);
      expect(controller.state(episode.id).played, isFalse);
      expect(controller.state(episode.id).positionMs, 0);
      resolve('unplayed');
      expect(snapshot.ids, [episode.id]);
      resolve('inProgress');
      expect(snapshot.ids, isEmpty);

      controller.updateState(episode.id, (state) => state.positionMs = 4000);
      controller.setPlayed(episode.id, true);
      expect(controller.state(episode.id).played, isTrue);
      expect(controller.state(episode.id).positionMs, 0);
      resolve('played');
      expect(snapshot.ids, [episode.id]);
    },
  );
  test('replay bookmarks preserve listened history and its filter', () async {
    final channel = await subscribe();
    final episode = store.episodes(channel.id).single;
    controller.setPlayed(episode.id, true);
    final playedAt = controller.state(episode.id).playedAtMs;
    controller.savePlaybackProgress(
      episode.id,
      2500,
      lastPlayedMs: 1234,
      debounced: true,
    );
    controller.flushStates();
    controller.reload();
    expect(controller.state(episode.id).played, isTrue);
    expect(controller.state(episode.id).playedAtMs, playedAt);
    expect(controller.state(episode.id).positionMs, 2500);
    expect(controller.state(episode.id).lastPlayedMs, 1234);
    expect(store.queryEpisodeIds(channelId: channel.id, filter: 'played'), [
      episode.id,
    ]);
    expect(
      store.queryEpisodeIds(channelId: channel.id, filter: 'inProgress'),
      isEmpty,
    );

    controller.setPlayed(episode.id, false);
    expect(controller.state(episode.id).played, isFalse);
    expect(controller.state(episode.id).positionMs, 0);
    expect(controller.state(episode.id).playedAtMs, 0);
    controller.savePlaybackProgress(episode.id, 1000);
    expect(controller.state(episode.id).listenBucket, 'inProgress');
  });
  test(
    'explicit synced listened changes still replace the local flag',
    () async {
      final channel = await subscribe();
      final episode = store.episodes(channel.id).single;
      controller.savePlaybackProgress(
        episode.id,
        0,
        completed: true,
        lastPlayedMs: 5678,
      );
      expect(store.state(episode.id).played, isTrue);
      expect(store.state(episode.id).playedAtMs, 5678);
      controller.savePlaybackProgress(episode.id, 1000, completed: false);
      expect(store.state(episode.id).played, isFalse);
      expect(store.state(episode.id).playedAtMs, 0);
      expect(controller.state(episode.id).listenBucket, 'inProgress');
    },
  );
  test(
    'auto-update off prevents even a channel page check while manual refresh remains available',
    () async {
      final channel = await subscribe();
      final before = requests;
      store.setSetting(channel.id, 'autoRefresh', false);
      await controller.refreshChannel(channel.id, manual: false);
      expect(requests, before);
      await controller.refreshChannel(channel.id);
      expect(requests, before + 1);
    },
  );
  test(
    'refresh leases prevent two concurrent checks for the same channel',
    () async {
      final channel = await subscribe();
      final before = requests;
      await Future.wait([
        controller.refreshChannel(channel.id),
        controller.refreshChannel(channel.id),
      ]);
      expect(requests, before + 1);
    },
  );
  test(
    'downloads use mobile data and preserve a paused task across controller reload',
    () async {
      final channel = await subscribe();
      final episode = PodcastEpisode(
        sourceFeedUrl: 'https://publisher.test/rss',
        id: 'mobile',
        channelId: channel.id,
        title: 'Mobile download',
        media: [
          PodcastMedia(
            url: 'http://127.0.0.1:${server.port}/bulk-mobile.mp3',
            mimeType: 'audio/mpeg',
            length: 4096,
          ),
        ],
      );
      store.write('episode', episode.id, episode.toJson(), channel: channel.id);
      controller.connectivity = [ConnectivityResult.mobile];
      controller.enqueue(episode);
      await controller.pumpDownloads();
      await controller.waitForIdle();
      expect(
        controller.downloads.single.status,
        PodcastDownloadStatus.completed,
      );
      controller.pause(episode.id);
      controller.reload();
      expect(controller.downloads.single.status, PodcastDownloadStatus.paused);
      expect(channel.active, isTrue);
    },
  );
  test('oversized downloads pause before requesting media', () async {
    final channel = await subscribe();
    store.setSetting(null, 'downloadLimitMb', 128);
    final episode = PodcastEpisode(
      sourceFeedUrl: 'https://publisher.test/rss',
      id: 'large',
      channelId: channel.id,
      title: '视频',
      media: [
        PodcastMedia(
          url: 'http://127.0.0.1:${server.port}/huge.mp4',
          mimeType: 'video/mp4',
          length: 1024 * 1024 * 1024,
        ),
      ],
    );
    store.write('episode', episode.id, episode.toJson(), channel: channel.id);
    final before = requests;
    controller.enqueue(episode);
    for (
      var i = 0;
      i < 100 &&
          controller.downloads.single.status != PodcastDownloadStatus.paused;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(controller.downloads.single.status, PodcastDownloadStatus.paused);
    expect(controller.downloads.single.error, contains('上限'));
    expect(requests, before);
  });
  test(
    'batch enqueue drains a durable queue without exceeding concurrency or starving IO',
    () async {
      final channel = await subscribe();
      for (var index = 0; index < 8; index++) {
        final episode = PodcastEpisode(
          sourceFeedUrl: 'https://publisher.test/rss',
          id: 'bulk-$index',
          channelId: channel.id,
          title: '节目 $index',
          media: [
            PodcastMedia(
              url: 'http://127.0.0.1:${server.port}/bulk-$index.mp3',
              mimeType: 'audio/mpeg',
            ),
          ],
        );
        store.write(
          'episode',
          episode.id,
          episode.toJson(),
          channel: channel.id,
        );
        controller.enqueue(episode);
      }
      for (
        var i = 0;
        i < 300 &&
            controller.downloads.any(
              (t) => t.status != PodcastDownloadStatus.completed,
            );
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.downloads, hasLength(8));
      expect(
        controller.downloads.every(
          (t) => t.status == PodcastDownloadStatus.completed,
        ),
        isTrue,
      );
      expect(peakMedia, lessThanOrEqualTo(2));
    },
  );
  test(
    'encrypted sync reassembles out-of-order fragments and rejects authentication changes',
    () async {
      final channel = await subscribe();
      final data = store.exportChannel(channel.id);
      data['padding'] = List.filled(400000, '字').join();
      final key = List<int>.generate(32, (i) => i);
      final encoded = await PodcastSyncCodec.encode(
        data: data,
        groupId: 'group',
        nodeId: 'node',
        key: key,
      );
      expect(encoded.length, greaterThan(1));
      Map<String, dynamic>? decoded;
      for (final record in encoded.reversed) {
        decoded = await PodcastSyncCodec.receive(record, key, store) ?? decoded;
      }
      expect(decoded!['channel'], data['channel']);
      expect(store.list('syncFragment'), isEmpty);
      final different = await PodcastSyncCodec.encode(
        data: data,
        groupId: 'other-group',
        nodeId: 'node',
        key: key,
      );
      expect(different.first['eventId'], isNot(encoded.first['eventId']));
      final tampered = {...different.first, 'channelId': 'altered'};
      expect(
        () => PodcastSyncCodec.receive(tampered, key, store),
        throwsA(anything),
      );
    },
  );
}
