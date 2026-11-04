import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

void main() {
  late Directory directory;
  late PodcastStore store;
  late PodcastMediaStore mediaStore;
  late HttpServer origin;
  late PodcastEpisode episode;
  late PodcastMedia media;
  late HttpClient player;
  late Completer<void> prefixSent, releasePrefix;
  final requests = <(int, int)>[];
  const total = 64 * podcastChunkBytes, distant = 32 * podcastChunkBytes;
  var stallPrefix = false,
      stallFirstPrefixOnly = false,
      stallPrefixHeaders = false,
      redirects = 0,
      etag = '"v1"';
  Uint8List bytesAt(int start, int length) =>
      Uint8List.fromList(List.generate(length, (i) => (start + i) % 251));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('podcast-seek-');
    store = PodcastStore(sqlite3.openInMemory());
    prefixSent = Completer();
    releasePrefix = Completer();
    stallPrefix = false;
    stallFirstPrefixOnly = false;
    stallPrefixHeaders = false;
    redirects = 0;
    etag = '"v1"';
    requests.clear();
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      try {
        final response = request.response;
        if (request.uri.path == '/redirect') {
          redirects++;
          response.statusCode = 302;
          response.headers.set('location', '/media.mp3');
          await response.close();
          return;
        }
        if (request.uri.queryParameters['expired'] == '1') {
          response.statusCode = 403;
          await response.close();
          return;
        }
        final range = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final honorsRange =
            request.headers.value('if-range') == null ||
            request.headers.value('if-range') == etag;
        final start = honorsRange ? int.tryParse(range?[1] ?? '') ?? 0 : 0;
        final end = honorsRange
            ? min(total - 1, int.tryParse(range?[2] ?? '') ?? total - 1)
            : total - 1;
        requests.add((start, end));
        if (stallPrefixHeaders &&
            start == 0 &&
            end > 0 &&
            !prefixSent.isCompleted) {
          prefixSent.complete();
          await releasePrefix.future;
        }
        response.statusCode = range != null && honorsRange ? 206 : 200;
        response.contentLength = end - start + 1;
        response.headers.set('content-type', 'audio/mpeg');
        response.headers.set('etag', etag);
        if (response.statusCode == 206) {
          response.headers.set('content-range', 'bytes $start-$end/$total');
        }
        for (var offset = start; offset <= end; offset += 32768) {
          response.add(bytesAt(offset, min(32768, end - offset + 1)));
          await response.flush();
          if (stallPrefix &&
              start == 0 &&
              end > 0 &&
              offset == 0 &&
              (!stallFirstPrefixOnly || !prefixSent.isCompleted)) {
            if (!prefixSent.isCompleted) prefixSent.complete();
            await releasePrefix.future;
          }
        }
        await response.close();
      } catch (_) {
        /* Playback cancellation is intentional. */
      }
    });
    media = PodcastMedia(
      url: 'http://127.0.0.1:${origin.port}/media.mp3',
      mimeType: 'audio/mpeg',
    );
    episode = PodcastEpisode(
      sourceFeedUrl: 'https://publisher.test/rss',
      id: 'seek-episode',
      channelId: 'show',
      title: 'Long episode',
      durationMs: 3600000,
      media: [media],
    );
    mediaStore = PodcastMediaStore(
      root: directory,
      store: store,
      http: PodcastHttp(clientFactory: HttpClient.new),
    );
    player = HttpClient();
  });
  tearDown(() async {
    if (!releasePrefix.isCompleted) releasePrefix.complete();
    player.close(force: true);
    await mediaStore.close();
    await origin.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });
  Future<List<int>> readRange(Uri uri, int start, int length) async {
    final request = await player.getUrl(uri);
    request.headers.set('range', 'bytes=$start-${start + length - 1}');
    final response = await request.close();
    expect(response.statusCode, 206);
    return response.fold<List<int>>([], (all, next) => all..addAll(next));
  }

  test('HEAD probes one byte and never primes the first megabyte', () async {
    final uri = await mediaStore.playbackUri(episode, media);
    final response = await (await player.headUrl(uri)).close();
    expect(response.contentLength, total);
    await response.drain<void>();
    expect(requests, [(0, 0)]);
    expect(mediaStore.cachedBytes(episode.id, media.url), 0);
  });
  test(
    'playback receives its first bytes before a cache chunk has finished',
    () async {
      stallPrefix = true;
      final uri = await mediaStore.playbackUri(episode, media);
      final request = await player.getUrl(uri);
      request.headers.set('range', 'bytes=0-');
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      final iterator = StreamIterator(response);
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 2)),
        isTrue,
      );
      expect(iterator.current, bytesAt(0, iterator.current.length));
      expect(releasePrefix.isCompleted, isFalse);
      mediaStore.prioritizePlayback(episode.id);
      await iterator.cancel();
    },
  );
  test(
    'a cold playback joining an active read receives the prefix before the origin resumes',
    () async {
      stallPrefix = true;
      final uri = await mediaStore.playbackUri(episode, media);
      final firstRequest = await player.getUrl(uri);
      firstRequest.headers.set('range', 'bytes=0-');
      final first = StreamIterator(await firstRequest.close());
      expect(await first.moveNext(), isTrue);
      await prefixSent.future;

      final secondRequest = await player.getUrl(uri);
      secondRequest.headers.set('range', 'bytes=0-65535');
      final secondResponse = await secondRequest.close().timeout(
        const Duration(seconds: 2),
      );
      final second = StreamIterator(secondResponse);
      try {
        expect(
          await second.moveNext().timeout(const Duration(seconds: 2)),
          isTrue,
        );
        expect(second.current, bytesAt(0, second.current.length));
        expect(releasePrefix.isCompleted, isFalse);
        final received = BytesBuilder()..add(second.current);
        // Releasing the original decoder request must leave the joined
        // reader's shared transfer alive.
        await first.cancel();
        releasePrefix.complete();
        while (await second.moveNext().timeout(const Duration(seconds: 2))) {
          received.add(second.current);
        }
        expect(received.takeBytes(), bytesAt(0, 65536));
      } finally {
        mediaStore.prioritizePlayback(episode.id);
        await first.cancel();
        await second.cancel();
      }
    },
  );
  test(
    'cold playback replays the prefix of an in-flight download window',
    () async {
      stallPrefix = true;
      var downloading = true;
      final download = mediaStore.fillWindow(
        episode,
        media,
        shouldContinue: () => downloading,
      );
      await prefixSent.future;
      final uri = await mediaStore.playbackUri(episode, media);
      try {
        expect(
          await readRange(uri, 0, 8192).timeout(const Duration(seconds: 2)),
          bytesAt(0, 8192),
        );
        expect(releasePrefix.isCompleted, isFalse);
      } finally {
        downloading = false;
        releasePrefix.complete();
        await download;
      }
    },
  );
  test(
    'jumping to a far range cancels obsolete playback without downloading the prefix',
    () async {
      stallPrefix = true;
      final uri = await mediaStore.playbackUri(episode, media);
      final request = await player.getUrl(uri);
      request.headers.set('range', 'bytes=0-');
      final old = StreamIterator(await request.close());
      await old.moveNext();
      var previousEnded = false;
      final previousDone = old.moveNext().then<void>(
        (_) => previousEnded = true,
        onError: (Object _, StackTrace _) => previousEnded = true,
      );
      mediaStore.prepareForSeek(episode.id);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Closing this socket before mpv has issued its seek can signal EOF.
      expect(previousEnded, isFalse);
      final result = await readRange(
        uri,
        distant + 123,
        8192,
      ).timeout(const Duration(seconds: 2));
      expect(result, bytesAt(distant + 123, 8192));
      expect(releasePrefix.isCompleted, isFalse);
      await previousDone.timeout(const Duration(seconds: 2));
      expect(
        requests.where((range) => range.$1 > 0 && range.$1 < distant),
        isEmpty,
      );
      await old.cancel();
    },
  );
  test(
    'seeking within an unfinished cache chunk replaces the stalled read',
    () async {
      stallPrefix = true;
      stallFirstPrefixOnly = true;
      final uri = await mediaStore.playbackUri(episode, media);
      final request = await player.getUrl(uri);
      request.headers.set('range', 'bytes=0-');
      final old = StreamIterator(await request.close());
      expect(await old.moveNext(), isTrue);
      await prefixSent.future;
      mediaStore.prepareForSeek(episode.id);
      try {
        final result = await readRange(
          uri,
          podcastChunkBytes - 4096,
          8192,
        ).timeout(const Duration(seconds: 2));
        expect(result, bytesAt(podcastChunkBytes - 4096, 8192));
        expect(releasePrefix.isCompleted, isFalse);
      } finally {
        mediaStore.prioritizePlayback(episode.id);
        await old.cancel();
      }
    },
  );
  test(
    'same-chunk seek cancels an obsolete request waiting for response headers',
    () async {
      stallPrefixHeaders = true;
      final uri = await mediaStore.playbackUri(episode, media);
      final request = await player.getUrl(uri);
      request.headers.set('range', 'bytes=0-');
      final previous = request.close().then<void>(
        (response) async => response.drain<void>(),
        onError: (Object _) {},
      );
      await prefixSent.future;
      mediaStore.prepareForSeek(episode.id);
      try {
        expect(
          await readRange(uri, 123, 8192).timeout(const Duration(seconds: 2)),
          bytesAt(123, 8192),
        );
        expect(releasePrefix.isCompleted, isFalse);
        await previous.timeout(const Duration(seconds: 2));
      } finally {
        mediaStore.prioritizePlayback(episode.id);
      }
    },
  );
  test(
    'a paused decoder cannot hold its current cache chunk ahead of a seek',
    () async {
      final uri = await mediaStore.playbackUri(episode, media);
      final request = await player.getUrl(uri);
      request.headers.set('range', 'bytes=0-');
      final old = StreamIterator(await request.close());
      expect(await old.moveNext(), isTrue);
      var lastCount = -1;
      for (var attempt = 0; attempt < 50; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        if (requests.length == lastCount) break;
        lastCount = requests.length;
      }
      final activeChunk = requests.last.$1;
      mediaStore.prepareForSeek(episode.id);
      try {
        expect(
          await readRange(
            uri,
            activeChunk + 123,
            8192,
          ).timeout(const Duration(seconds: 2)),
          bytesAt(activeChunk + 123, 8192),
        );
      } finally {
        mediaStore.prioritizePlayback(episode.id);
        await old.cancel();
      }
    },
  );
  test(
    'a stalled download cannot hold the asset lock ahead of playback at another position',
    () async {
      stallPrefix = true;
      var finished = false;
      final download = mediaStore.chunk(episode, media, 0, download: true).then(
        (data) {
          finished = true;
          return data;
        },
      );
      await prefixSent.future;
      final uri = await mediaStore.playbackUri(episode, media);
      expect(
        await readRange(uri, distant, 8192).timeout(const Duration(seconds: 2)),
        bytesAt(distant, 8192),
      );
      expect(finished, isFalse);
      releasePrefix.complete();
      await download;
      await mediaStore.chunk(episode, media, 32);
      expect(
        (mediaStore.manifest(episode.id, media.url)['segments'] as Map).keys,
        containsAll(['0', '32']),
      );
    },
  );
  test(
    'resolved media URLs skip repeat tracking redirects and expired URLs fall back safely',
    () async {
      media = PodcastMedia(
        url: 'http://127.0.0.1:${origin.port}/redirect',
        mimeType: 'audio/mpeg',
      );
      episode = PodcastEpisode.fromJson({
        ...episode.toJson(),
        'media': [media.toJson()],
      });
      final uri = await mediaStore.playbackUri(episode, media);
      final head = await (await player.headUrl(uri)).close();
      await head.drain<void>();
      await mediaStore.chunk(episode, media, 32);
      expect(redirects, 1);
      final m = mediaStore.manifest(episode.id, media.url)
        ..['resolvedUrl'] =
            'http://127.0.0.1:${origin.port}/media.mp3?expired=1';
      store.write('asset', m['id'], m);
      expect(
        await mediaStore.chunk(episode, media, 33),
        bytesAt(33 * podcastChunkBytes, podcastChunkBytes),
      );
      expect(redirects, 2);
    },
  );
  test(
    'If-Range representation changes retry at the target rather than reading a whole prefix',
    () async {
      await mediaStore.chunk(episode, media, 0);
      etag = '"v2"';
      expect(
        await mediaStore.chunk(episode, media, 32),
        bytesAt(distant, podcastChunkBytes),
      );
      expect(mediaStore.manifest(episode.id, media.url)['revision'], 1);
      expect(
        (mediaStore.manifest(episode.id, media.url)['segments'] as Map).keys,
        ['32'],
      );
    },
  );
}
