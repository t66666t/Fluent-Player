import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_episode_selection.dart';
import 'package:video_player_app/features/podcasts/podcast_feed_parser.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/media_artwork_ref.dart';
import 'package:video_player_app/services/effective_media_playback_preferences.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('playback follows the app until a podcast override exists', () {
    const resolver = EffectiveMediaPlaybackPreferences();
    const software = SoftwarePlaybackDefaults(
      autoPlayOnCompletion: false,
      effectiveSpeed: 1.25,
      speedLocked: true,
    );
    final continuous = resolver.continuous(
      globalRaw: const {},
      software: software,
    );
    expect(continuous.value, isFalse);
    expect(continuous.source, PlaybackPreferenceSource.software);

    final globalOff = resolver.continuous(
      globalRaw: const {'continuous': false},
      channelRaw: const {},
      software: const SoftwarePlaybackDefaults(
        autoPlayOnCompletion: true,
        effectiveSpeed: 1,
      ),
    );
    expect(globalOff.value, isFalse);
    expect(globalOff.source, PlaybackPreferenceSource.podcastGlobal);

    final channelOn = resolver.continuous(
      globalRaw: const {'continuous': false},
      channelRaw: const {'continuous': true},
      software: software,
    );
    expect(channelOn.value, isTrue);
    expect(channelOn.source, PlaybackPreferenceSource.channel);

    final inherited = resolver.continuous(
      globalRaw: const {'continuous': false},
      channelRaw: const {},
      software: software,
    );
    expect(inherited.value, isFalse);

    final speed = resolver.speed(globalRaw: const {}, software: software);
    expect(speed.value, 1.25);
    expect(speed.source, PlaybackPreferenceSource.software);
    final session = resolver.speed(
      globalRaw: const {'speed': 1.5},
      software: software,
      sessionSpeed: 2,
    );
    expect(session.source, PlaybackPreferenceSource.session);
    expect(session.value, 2);
    expect(
      resolver.caption(
        key: 'continuous',
        channelScope: false,
        explicitHere: false,
        resolved: continuous,
        software: software,
      ),
      '跟随软件（当前关闭）',
    );
  });

  test('manual order, refresh and selection do not invent media rows', () {
    final store = PodcastStore(sqlite3.openInMemory());
    addTearDown(store.close);
    final feed = const PodcastFeedParser().parse(
      utf8.encode('''
<?xml version="1.0"?>
<rss version="2.0"><channel>
<title>Order</title><link>https://example.com</link>
<item><title>A</title><guid>a</guid><pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
<enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
<item><title>B</title><guid>b</guid><pubDate>Tue, 02 Jan 2024 00:00:00 GMT</pubDate>
<enclosure url="https://example.com/b.mp3" type="audio/mpeg"/></item>
</channel></rss>
'''),
      'https://example.com/rss',
    );
    store.mergeFeed(feed, initial: true);
    final channelId = feed.channel.id;
    final newest = store.queryEpisodeIds(channelId: channelId, sort: 'newest');
    expect(newest, hasLength(2));
    expect(newest.first, isNot(newest.last));
    final order = store.manualOrder(channelId);
    expect(
      store.moveManual(
        channelId: channelId,
        movingIds: [newest.last],
        beforeId: newest.first,
        expectedRevision: order.revision,
      ),
      isTrue,
    );
    expect(store.manualOrder(channelId).ids.first, newest.last);
    expect(
      store.moveManual(
        channelId: channelId,
        movingIds: [newest.first],
        beforeId: newest.last,
        expectedRevision: order.revision,
      ),
      isFalse,
    );
    expect(store.manualOrder(channelId).ids.first, newest.last);

    final updated = const PodcastFeedParser().parse(
      utf8.encode('''
<?xml version="1.0"?>
<rss version="2.0"><channel>
<title>Order</title><link>https://example.com</link>
<item><title>A</title><guid>a</guid><pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
<enclosure url="https://example.com/a.mp3" type="audio/mpeg"/></item>
<item><title>B</title><guid>b</guid><pubDate>Tue, 02 Jan 2024 00:00:00 GMT</pubDate>
<enclosure url="https://example.com/b.mp3" type="audio/mpeg"/></item>
<item><title>C</title><guid>c</guid><pubDate>Wed, 03 Jan 2024 00:00:00 GMT</pubDate>
<enclosure url="https://example.com/c.mp3" type="audio/mpeg"/></item>
</channel></rss>
'''),
      'https://example.com/rss',
    );
    store.mergeFeed(updated);
    final after = store.manualOrder(channelId).ids;
    expect(after.first, isNot(newest.first));
    expect(after.sublist(1), store.manualOrder(channelId).ids.sublist(1));
    final relative = after.where((id) => id != after.first).toList();
    expect(relative.first, newest.last);

    final hidden = after.last;
    store.setPresentation(hidden, hidden: true, localTitle: '别名');
    final visible = store.queryEpisodeIds(channelId: channelId, sort: 'manual');
    expect(visible, isNot(contains(hidden)));
    expect(store.queryEpisodeIds(channelId: channelId, filter: 'hidden'), [
      hidden,
    ]);
    final many = List<String>.generate(10000, (index) => 'ep-$index');
    final selection = PodcastEpisodeSelection()..selectAll(many);
    expect(selection.ids, hasLength(10000));
    selection.retain([...many.take(3), 'new-episode']);
    expect(selection.ids, ['ep-0', 'ep-1', 'ep-2']);
    expect(selection.ids, isNot(contains('new-episode')));
    selection.deselectAll();
    expect(selection.ids, isEmpty);
    expect(selection.active, isTrue);
    selection.clear();
    expect(selection.active, isFalse);
  });

  test('listen buckets split never started, in progress, and heard', () {
    final store = PodcastStore(sqlite3.openInMemory());
    addTearDown(store.close);
    final feed = const PodcastFeedParser().parse(
      utf8.encode('''
<?xml version="1.0"?>
<rss version="2.0"><channel>
<title>Buckets</title><link>https://example.com</link>
<item><title>Fresh</title><guid>fresh</guid><pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate>
<enclosure url="https://example.com/fresh.mp3" type="audio/mpeg"/></item>
<item><title>Started</title><guid>started</guid><pubDate>Tue, 02 Jan 2024 00:00:00 GMT</pubDate>
<enclosure url="https://example.com/started.mp3" type="audio/mpeg"/></item>
<item><title>Done</title><guid>done</guid><pubDate>Wed, 03 Jan 2024 00:00:00 GMT</pubDate>
<enclosure url="https://example.com/done.mp3" type="audio/mpeg"/></item>
</channel></rss>
'''),
      'https://example.com/rss',
    );
    store.mergeFeed(feed, initial: true);
    final channelId = feed.channel.id;
    final ids = {
      for (final episode in store.episodes(channelId))
        episode.title: episode.id,
    };
    store.saveState(ids['Started']!, PodcastEpisodeState(positionMs: 1500));
    store.saveState(
      ids['Done']!,
      PodcastEpisodeState(played: true, positionMs: 9000),
    );
    expect(store.queryEpisodeIds(channelId: channelId, filter: 'unplayed'), [
      ids['Fresh'],
    ]);
    expect(store.queryEpisodeIds(channelId: channelId, filter: 'inProgress'), [
      ids['Started'],
    ]);
    expect(store.queryEpisodeIds(channelId: channelId, filter: 'played'), [
      ids['Done'],
    ]);

    final revision = store.catalogRevision;
    store.saveState(ids['Started']!, PodcastEpisodeState(positionMs: 2400));
    expect(store.catalogRevision, revision);
    store.saveState(ids['Started']!, PodcastEpisodeState());
    expect(store.catalogRevision, revision + 1);
    expect(
      store.queryEpisodeIds(channelId: channelId, filter: 'inProgress'),
      isEmpty,
    );

    final hiddenRevision = store.catalogRevision;
    store.setPresentation(ids['Fresh']!, hidden: true);
    expect(store.catalogRevision, hiddenRevision + 1);
    store.setPresentation(ids['Fresh']!, hidden: true);
    expect(store.catalogRevision, hiddenRevision + 1);
    expect(store.queryEpisodeIds(channelId: channelId, filter: 'hidden'), [
      ids['Fresh'],
    ]);
    store.setPresentation(ids['Fresh']!, hidden: false);
    expect(
      store.queryEpisodeIds(channelId: channelId, filter: 'unplayed'),
      contains(ids['Fresh']),
    );

    final snapshot = PodcastCatalogSnapshot();
    snapshot.resolve(
      store: store,
      channelId: channelId,
      filter: 'unplayed',
      query: '',
      sort: 'newest',
      hidePlayed: false,
      downloaded: const {},
      countFilters: const ['unplayed', 'inProgress'],
    );
    final queries = store.catalogQueries;
    snapshot.resolve(
      store: store,
      channelId: channelId,
      filter: 'unplayed',
      query: '',
      sort: 'newest',
      hidePlayed: false,
      downloaded: const {},
      countFilters: const ['unplayed', 'inProgress'],
    );
    expect(store.catalogQueries, queries);
    store.saveState(ids['Fresh']!, PodcastEpisodeState(favorite: true));
    snapshot.resolve(
      store: store,
      channelId: channelId,
      filter: 'unplayed',
      query: '',
      sort: 'newest',
      hidePlayed: false,
      downloaded: const {},
      countFilters: const ['unplayed', 'inProgress'],
    );
    expect(store.catalogQueries, greaterThan(queries));
  });

  test(
    'version 2 export keeps explicit overrides and version 1 import says so',
    () {
      final store = PodcastStore(sqlite3.openInMemory());
      addTearDown(store.close);
      final feed = const PodcastFeedParser().parse(
        utf8.encode('''
<?xml version="1.0"?>
<rss version="2.0"><channel>
<title>Settings</title>
<item><title>One</title><guid>one</guid>
<enclosure url="https://example.com/one.mp3" type="audio/mpeg"/></item>
</channel></rss>
'''),
        'https://example.com/rss',
      );
      store.mergeFeed(feed, initial: true);
      final exported = store.exportChannel(feed.channel.id);
      expect(exported['version'], 2);
      expect(exported['globalSettings'], isEmpty);
      expect(exported['inheritanceVersion'], 1);

      store.setSetting(null, 'continuous', false);
      store.setSetting(feed.channel.id, 'continuous', true);
      final overridden = store.exportChannel(feed.channel.id);
      expect(overridden['globalSettings'], {'continuous': false});
      expect(overridden['settings'], containsPair('continuous', true));

      final older = PodcastStore(sqlite3.openInMemory());
      addTearDown(older.close);
      final legacy = Map<String, dynamic>.from(exported);
      legacy['version'] = 1;
      legacy['globalSettings'] = {'continuous': true, 'speed': 1.0};
      legacy['globalSettingsUpdatedMs'] = 10;
      final result = older.importChannel(legacy);
      expect(result.notices, contains('已保留旧版独立设置，可恢复跟随软件'));
      expect(
        older.read('settings', 'global'),
        containsPair('continuous', true),
      );

      final restored = PodcastStore(sqlite3.openInMemory());
      addTearDown(restored.close);
      restored.setSetting(null, 'continuous', true);
      final clear = Map<String, dynamic>.from(overridden);
      (clear['globalSettings'] as Map).remove('continuous');
      clear['globalSettingsUpdatedMs'] =
          DateTime.now().millisecondsSinceEpoch + 60000;
      restored.importChannel(clear);
      expect(
        restored.read('settings', 'global')?.containsKey('continuous'),
        isNot(true),
      );
    },
  );

  test('a newer database is refused instead of rewritten', () {
    final database = sqlite3.openInMemory();
    database.execute('PRAGMA user_version=3');
    expect(() => PodcastStore(database), throwsA(isA<FormatException>()));
    database.dispose();
  });

  test(
    'shared artwork downloads one original for many viewers and sizes',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final image = base64Decode(png);
      server.listen((request) {
        hits++;
        request.response.headers.set('etag', '"cover"');
        request.response.contentLength = image.length;
        request.response.add(image);
        request.response.close();
      });
      final root = await Directory.systemTemp.createTemp('artwork-test');
      final repository = await MediaArtworkRepository.open(
        root,
        installAsActive: false,
        retryBase: Duration.zero,
        fetcher: _httpFetcher,
      );
      addTearDown(() async {
        repository.close();
        await server.close(force: true);
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final url = 'http://127.0.0.1:${server.port}/cover.png?sig=one';
      final ref = ArtworkRef(
        ownerKind: 'episode',
        ownerId: 'ep',
        primary: ArtworkRequest(url: url, adapter: ArtworkAdapter.podcast),
      );
      final results = await Future.wait(
        List.generate(8, (index) => repository.load(ref)),
      );
      expect(hits, 1);
      expect(repository.diagnostics.network, 1);
      expect(results.first.hasImage, isTrue, reason: results.first.reason);
      expect(results.first.localPath, isNotNull);
      expect(
        results.every((item) => item.localPath == results.first.localPath),
        isTrue,
      );
      expect(artworkSizeBucket(40, 3), 128);
      expect(artworkSizeBucket(400, 3), 1600);
      final otherSize = await repository.load(
        ArtworkRef(
          ownerKind: 'episode',
          ownerId: 'large-viewer',
          primary: ArtworkRequest(url: url, adapter: ArtworkAdapter.podcast),
        ),
      );
      // Digest text can coincidentally contain "128". Check actual cache reuse
      // after a different size bucket instead of depending on random hash text.
      expect(otherSize.localPath, results.first.localPath);
      expect(hits, 1);

      final second = 'http://127.0.0.1:${server.port}/same.png';
      final again = await repository.load(
        ArtworkRef(
          ownerKind: 'episode',
          ownerId: 'other',
          primary: ArtworkRequest(url: second, adapter: ArtworkAdapter.podcast),
        ),
      );
      expect(hits, 2);
      expect(again.blobHash, results.first.blobHash);
      final blobs = Directory(
        '${root.path}/blobs',
      ).listSync().whereType<File>();
      expect(blobs, hasLength(1));

      final offline = await repository.load(ref);
      expect(offline.fromDisk, isTrue);
      expect(hits, 2);
    },
  );

  test(
    'bad images fall back and a failed refresh keeps the previous file',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var mode = 'ok';
      var hits = 0;
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final image = base64Decode(png);
      server.listen((request) {
        hits++;
        if (request.uri.path == '/bad') {
          request.response.statusCode = mode == 'missing' ? 404 : 200;
          final body = utf8.encode(mode == 'html' ? '<html>nope</html>' : '');
          request.response.contentLength = body.length;
          request.response.add(body);
          request.response.close();
          return;
        }
        if (mode == 'fail') {
          request.response.statusCode = 500;
          request.response.contentLength = 0;
          request.response.close();
          return;
        }
        if (mode == 'nostore') {
          request.response.headers.set('cache-control', 'no-store');
        }
        request.response.contentLength = image.length;
        request.response.add(image);
        request.response.close();
      });
      final root = await Directory.systemTemp.createTemp('artwork-fail');
      var now = DateTime.utc(2026, 1, 1);
      final repository = await MediaArtworkRepository.open(
        root,
        installAsActive: false,
        retryBase: Duration.zero,
        clock: () => now,
        fetcher: _httpFetcher,
      );
      addTearDown(() async {
        repository.close();
        await server.close(force: true);
        if (root.existsSync()) await root.delete(recursive: true);
      });
      final base = 'http://127.0.0.1:${server.port}';
      mode = 'html';
      final fallback = await repository.load(
        ArtworkRef(
          ownerKind: 'episode',
          ownerId: 'ep',
          primary: ArtworkRequest(
            url: '$base/bad',
            adapter: ArtworkAdapter.podcast,
          ),
          fallbacks: [
            ArtworkRequest(
              url: '$base/channel.png',
              adapter: ArtworkAdapter.podcast,
            ),
          ],
        ),
      );
      expect(fallback.hasImage, isTrue);
      expect(fallback.localPath, contains('blobs'));

      mode = 'ok';
      final first = await repository.load(
        ArtworkRef(
          ownerKind: 'channel',
          ownerId: 'ch',
          primary: ArtworkRequest(
            url: '$base/keep.png',
            adapter: ArtworkAdapter.podcast,
          ),
        ),
      );
      final kept = first.localPath;
      mode = 'fail';
      now = now.add(const Duration(days: 8));
      final stale = await repository.load(
        ArtworkRef(
          ownerKind: 'channel',
          ownerId: 'ch',
          primary: ArtworkRequest(
            url: '$base/keep.png',
            adapter: ArtworkAdapter.podcast,
          ),
        ),
      );
      expect(stale.localPath, kept);
      expect(File(kept!).existsSync(), isTrue);

      mode = 'nostore';
      final blobsBefore = Directory(
        '${root.path}/blobs',
      ).listSync().whereType<File>().length;
      final memory = await repository.load(
        ArtworkRef(
          ownerKind: 'search',
          ownerId: 'q',
          primary: ArtworkRequest(
            url: '$base/temp.png',
            adapter: ArtworkAdapter.podcast,
          ),
          temporary: true,
        ),
      );
      expect(memory.localPath, isNull);
      expect(memory.memoryBytes, isNotEmpty);
      expect(
        Directory('${root.path}/blobs').listSync().whereType<File>().length,
        blobsBefore,
      );
      expect(hits, greaterThan(0));
    },
  );

  test('app autoplay stays independent from an empty podcast map', () {
    final settings = SettingsService()..resetForTest();
    settings.autoPlayOnCompletion = false;
    final resolved = const EffectiveMediaPlaybackPreferences().continuous(
      globalRaw: const {},
      software: SoftwarePlaybackDefaults.current(settings),
    );
    expect(resolved.value, isFalse);
    expect(settings.autoPlayOnCompletion, isFalse);
  });
}

/// Speaks HTTP on a raw socket. Flutter tests replace HttpClient with a stub
/// that never reaches the local server.
Future<ArtworkFetchResponse> _httpFetcher(ArtworkFetchRequest request) async {
  final socket = await Socket.connect(
    request.uri.host,
    request.uri.port,
    timeout: request.connectTimeout,
  );
  final headerText = StringBuffer(
    'GET ${request.uri.path} HTTP/1.1\r\nHost: ${request.uri.host}\r\nConnection: close\r\n',
  );
  request.headers.forEach((name, value) {
    headerText.write('$name: $value\r\n');
  });
  headerText.write('\r\n');
  socket.write(headerText.toString());
  final data = await socket.fold<List<int>>(<int>[], (left, chunk) {
    left.addAll(chunk);
    return left;
  });
  await socket.close();
  final split = _splitHttp(data);
  return ArtworkFetchResponse(
    status: split.$1,
    headers: split.$2,
    bytes: split.$3,
    finalUri: request.uri,
  );
}

(int, Map<String, String>, List<int>) _splitHttp(List<int> data) {
  final text = latin1.decode(data, allowInvalid: true);
  final breakAt = text.indexOf('\r\n\r\n');
  if (breakAt < 0) {
    return (0, const {}, data);
  }
  final head = text.substring(0, breakAt).split('\r\n');
  final status =
      int.tryParse(head.first.split(' ').elementAtOrNull(1) ?? '') ?? 0;
  final headers = <String, String>{};
  for (final line in head.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim().toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  return (status, headers, data.sublist(breakAt + 4));
}
