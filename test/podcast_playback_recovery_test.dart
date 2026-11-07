import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_connection_policy.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/services/network/network_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PodcastStore store;
  late PodcastMediaStore mediaStore;
  late HttpServer origin;
  late HttpClient player;
  late PodcastConnectionPolicy routes;
  late PodcastEpisode episode;
  late PodcastMedia media;
  final payload = List<int>.generate(65536, (i) => i % 251);
  final connections = <NetworkMode>[];
  var originStatus = HttpStatus.partialContent;
  var alwaysFail = false;
  var failConnections = 1;
  var holdHeaders = false;
  var holdFirstHeaders = false;
  late Completer<void> requested, release;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('podcast-first-play-');
    store = PodcastStore(sqlite3.openInMemory());
    player = HttpClient();
    routes = PodcastConnectionPolicy();
    connections.clear();
    alwaysFail = false;
    failConnections = 1;
    holdHeaders = false;
    holdFirstHeaders = false;
    requested = Completer<void>();
    release = Completer<void>();
    originStatus = HttpStatus.partialContent;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      try {
        final first = !requested.isCompleted;
        if (first) requested.complete();
        if (holdHeaders || holdFirstHeaders && first) await release.future;
        final response = request.response;
        response.statusCode = originStatus;
        if (originStatus != HttpStatus.partialContent) {
          await response.close();
          return;
        }
        final range = RegExp(
          r'^bytes=(\d+)-(\d*)$',
        ).firstMatch(request.headers.value('range') ?? '')!;
        final start = int.parse(range[1]!);
        final end = min(
          payload.length - 1,
          int.tryParse(range[2]!) ?? payload.length - 1,
        );
        response.headers.set(
          'content-range',
          'bytes $start-$end/${payload.length}',
        );
        response.headers.set('content-type', 'audio/mpeg');
        response.headers.set('etag', '"episode"');
        response.contentLength = end - start + 1;
        response.add(payload.sublist(start, end + 1));
        await response.close();
      } on IOException {
        // The player may cancel a probe.
      }
    });
    final http = PodcastHttp(
      routes: routes,
      clientFactory: () => HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..connectionFactory = (uri, _, _) async {
          connections.add(routes.modeFor(uri));
          if (alwaysFail || failConnections-- > 0) {
            throw const SocketException('first route unavailable');
          }
          return Socket.startConnect(InternetAddress.loopbackIPv4, origin.port);
        },
    );
    final feed = PodcastClient().parser.parse(
      utf8.encode(
        '<rss version="2.0"><channel><title>Publisher</title>'
        '<item><guid>cold</guid><title>Cold</title>'
        '<enclosure url="http://media.overseas.test/audio.mp3" '
        'type="audio/mpeg" length="${payload.length}"/>'
        '</item></channel></rss>',
      ),
      'https://publisher.test/rss',
    );
    episode = feed.episodes.single;
    media = episode.media.single;
    mediaStore = PodcastMediaStore(
      root: directory,
      store: store,
      http: http,
      playbackRequestTimeout: const Duration(milliseconds: 150),
    );
  });

  tearDown(() async {
    if (!release.isCompleted) release.complete();
    player.close(force: true);
    await mediaStore.close();
    await origin.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });

  Future<HttpClientResponse> open() async {
    final uri = await mediaStore.playbackUri(episode, media);
    final request = await player.getUrl(uri);
    request.headers.set('range', 'bytes=0-8191');
    return request.close().timeout(const Duration(seconds: 2));
  }

  for (final cold in [true, false]) {
    test(
      'first play recovers a failed ${cold ? 'probe' : 'range'} route',
      () async {
        if (!cold) {
          final manifest = mediaStore.manifest(episode.id, media.url)
            ..['total'] = payload.length;
          store.write(
            'asset',
            manifest['id'],
            manifest,
            channel: episode.channelId,
          );
        }
        final response = await open();
        final bytes = await response.fold<List<int>>(
          [],
          (all, next) => all..addAll(next),
        );
        expect(response.statusCode, HttpStatus.partialContent);
        expect(bytes, payload.sublist(0, 8192));
        expect(connections.take(2), [NetworkMode.system, NetworkMode.direct]);
        expect(routes.generation, 1);
      },
    );
  }

  for (final cold in [true, false]) {
    test('both routes failing returns a complete error (cold=$cold)', () async {
      if (!cold) {
        final manifest = mediaStore.manifest(episode.id, media.url)
          ..['total'] = payload.length;
        store.write(
          'asset',
          manifest['id'],
          manifest,
          channel: episode.channelId,
        );
      }
      alwaysFail = true;
      final response = await open();
      await response.drain<void>();
      expect(response.statusCode, HttpStatus.badGateway);
      expect(response.contentLength, 0);
      expect(response.headers.value('content-range'), isNull);
      expect(connections, [NetworkMode.system, NetworkMode.direct]);
      expect(routes.generation, 1);
    });
  }

  test(
    'a stalled cold probe reconnects before native initialization expires',
    () async {
      failConnections = 0;
      holdFirstHeaders = true;
      final response = await open();
      final bytes = await response.fold<List<int>>(
        [],
        (all, next) => all..addAll(next),
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(bytes, payload.sublist(0, 8192));
      expect(release.isCompleted, isFalse);
      expect(connections.take(2), [NetworkMode.system, NetworkMode.direct]);
      expect(routes.generation, 1);
    },
  );

  test(
    'an already selected alternate reconnects without another route flip',
    () async {
      routes.connectionFailed(
        Uri.parse(media.url),
        const SocketException('previous failure'),
      );
      final response = await open();
      final bytes = await response.fold<List<int>>(
        [],
        (all, next) => all..addAll(next),
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(bytes, payload.sublist(0, 8192));
      expect(connections.take(2), [NetworkMode.direct, NetworkMode.direct]);
      expect(routes.generation, 1);
    },
  );

  test(
    'cancelling a cold probe releases its read without switching routes',
    () async {
      failConnections = 0;
      holdHeaders = true;
      final uri = await mediaStore.playbackUri(episode, media);
      final request = await player.getUrl(uri);
      final opening = request.close();
      // Attach the error listener before intentionally interrupting the socket.
      final closed = opening.then<void>(
        (response) => response.drain<void>(),
        onError: (Object _, StackTrace _) {},
      );
      await requested.future.timeout(const Duration(seconds: 2));
      request.abort();
      mediaStore.prioritizePlayback(episode.id);
      for (
        var count = 0;
        count < 50 && mediaStore.storageProtectedAssetIds.isNotEmpty;
        count++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(mediaStore.storageProtectedAssetIds, isEmpty);
      expect(connections, [NetworkMode.system]);
      expect(routes.generation, 0);
      await closed;
    },
  );

  for (final status in [403, 404, 429, 502]) {
    test(
      'an origin $status does not switch routes or repeat requests',
      () async {
        failConnections = 0;
        originStatus = status;
        final response = await open();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.badGateway);
        expect(connections, [NetworkMode.system]);
        expect(routes.generation, 0);
      },
    );
  }
}
