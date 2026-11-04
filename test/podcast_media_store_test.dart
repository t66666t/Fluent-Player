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
  late HttpServer server;
  late PodcastEpisode episode;
  late PodcastMedia media;
  late Uint8List payload;
  var requests = 0;
  var ignoreRange = false;
  var unknownLength = false;
  var misalignedRange = false;
  var etag = '"v1"';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fluent-podcast-test-');
    store = PodcastStore(sqlite3.openInMemory());
    payload = Uint8List.fromList(
      List.generate(podcastChunkBytes * 2 + 12345, (i) => i % 251),
    );
    requests = 0;
    ignoreRange = false;
    unknownLength = false;
    misalignedRange = false;
    etag = '"v1"';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      final response = request.response;
      if (request.uri.path.endsWith('.m3u8')) {
        response.headers.set('content-type', 'application/vnd.apple.mpegurl');
        response.write(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:30,\nepisode.mp3\n#EXT-X-ENDLIST',
        );
        await response.close();
        return;
      }
      response.headers.set('etag', etag);
      response.headers.set('content-type', 'audio/mpeg');
      final range = request.headers.value('range'),
          match = range == null
              ? null
              : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      final start = ignoreRange ? 0 : int.tryParse(match?[1] ?? '') ?? 0,
          end = ignoreRange
              ? payload.length - 1
              : min(
                  payload.length - 1,
                  int.tryParse(match?[2] ?? '') ?? payload.length - 1,
                );
      if (start >= payload.length) {
        response.statusCode = 416;
        await response.close();
        return;
      }
      if (match != null && !ignoreRange) {
        response.statusCode = 206;
        response.headers.set(
          'content-range',
          misalignedRange
              ? 'bytes 0-${end - start}/${payload.length}'
              : 'bytes $start-$end/${payload.length}',
        );
      }
      if (!unknownLength) response.contentLength = end - start + 1;
      response.add(
        Uint8List.sublistView(
          payload,
          misalignedRange ? 0 : start,
          misalignedRange ? end - start + 1 : end + 1,
        ),
      );
      try {
        await response.close();
      } catch (_) {}
    });
    media = PodcastMedia(
      url: 'http://127.0.0.1:${server.port}/episode.mp3',
      mimeType: 'audio/mpeg',
    );
    episode = PodcastEpisode(
      sourceFeedUrl: 'https://publisher.test/rss',
      id: 'episode',
      channelId: 'channel',
      title: '测试节目',
      media: [media],
    );
    store.write(
      'episode',
      episode.id,
      episode.toJson(),
      channel: episode.channelId,
    );
    mediaStore = PodcastMediaStore(
      root: Directory('${directory.path}/media'),
      store: store,
      http: PodcastHttp(clientFactory: () => HttpClient()),
    );
  });
  tearDown(() async {
    await mediaStore.close();
    await server.close(force: true);
    store.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  test(
    'partial playback cache is reused but never reported as complete',
    () async {
      final first = await mediaStore.chunk(episode, media, 0);
      expect(first, payload.sublist(0, podcastChunkBytes));
      expect(mediaStore.isComplete(episode.id, media.url), isFalse);
      await mediaStore.chunk(episode, media, 0);
      expect(requests, 1);
      expect(
        () => mediaStore.assemble(episode, media),
        throwsA(isA<HttpException>()),
      );
    },
  );
  test(
    'downloads fill missing chunks and offline gateway serves exact ranges',
    () async {
      await mediaStore.chunk(episode, media, 1);
      await mediaStore.chunk(episode, media, 0, download: true);
      await mediaStore.chunk(episode, media, 1, download: true);
      await mediaStore.chunk(episode, media, 2, download: true);
      expect(requests, 3);
      await mediaStore.markDownloaded(episode, media);
      expect(mediaStore.isDownloaded(episode.id, media.url), isTrue);
      final uri = await mediaStore.playbackUri(episode, media);
      await server.close(force: true);
      final client = HttpClient();
      try {
        final request = await client.getUrl(uri);
        request.headers.set('range', 'bytes=1048500-1048700');
        final response = await request.close();
        expect(response.statusCode, 206);
        final data = await response.fold<List<int>>(
          [],
          (all, next) => all..addAll(next),
        );
        expect(data, payload.sublist(1048500, 1048701));
      } finally {
        client.close(force: true);
      }
      final complete = await mediaStore.assemble(episode, media);
      expect(await complete.readAsBytes(), payload);
    },
  );
  test(
    'a source that ignores Range never appends an entire response to a resumed chunk',
    () async {
      ignoreRange = true;
      final second = await mediaStore.chunk(episode, media, 1, download: true);
      expect(second, payload.sublist(podcastChunkBytes, podcastChunkBytes * 2));
      expect(mediaStore.cachedBytes(episode.id, media.url), podcastChunkBytes);
      expect(mediaStore.isComplete(episode.id, media.url), isFalse);
    },
  );
  test(
    'a misaligned 206 cannot replay the opening in a later podcast chunk',
    () async {
      misalignedRange = true;
      await expectLater(
        mediaStore.chunk(episode, media, 1, download: true),
        throwsA(isA<HttpException>()),
      );
      expect(mediaStore.cachedBytes(episode.id, media.url), 0);
      misalignedRange = false;
      expect(
        await mediaStore.chunk(episode, media, 1, download: true),
        payload.sublist(podcastChunkBytes, podcastChunkBytes * 2),
      );
    },
  );
  test(
    'ETag change invalidates old segments instead of splicing source revisions',
    () async {
      await mediaStore.chunk(episode, media, 0);
      etag = '"v2"';
      payload = Uint8List.fromList(payload.map((b) => (b + 1) % 251).toList());
      await mediaStore.chunk(episode, media, 1, download: true);
      final manifest = mediaStore.manifest(episode.id, media.url);
      expect(manifest['revision'], 1);
      expect((manifest['segments'] as Map).keys, ['1']);
      expect(mediaStore.isComplete(episode.id, media.url), isFalse);
    },
  );
  test(
    'servers ignoring Range finish in one sequential request and reuse earlier chunks',
    () async {
      ignoreRange = true;
      await mediaStore.chunk(episode, media, 0, download: true);
      final progress = <int>[];
      expect(
        await mediaStore.fillSequential(
          episode,
          media,
          onProgress: (received, total) {
            progress.add(received);
            return true;
          },
        ),
        isTrue,
      );
      expect(requests, 2);
      expect(mediaStore.isComplete(episode.id, media.url), isTrue);
      expect(progress.last, payload.length);
      expect(
        await (await mediaStore.assemble(episode, media)).readAsBytes(),
        payload,
      );
    },
  );
  test('sequential compatibility reads save progress when paused', () async {
    ignoreRange = true;
    expect(
      await mediaStore.fillSequential(
        episode,
        media,
        onProgress: (received, total) => received < podcastChunkBytes,
      ),
      isFalse,
    );
    expect(mediaStore.cachedBytes(episode.id, media.url), podcastChunkBytes);
    expect(mediaStore.isComplete(episode.id, media.url), isFalse);
  });
  test(
    'independent media stores serialize asset writes through SQLite',
    () async {
      final secondStore = PodcastMediaStore(
        root: mediaStore.root,
        store: store,
        http: PodcastHttp(clientFactory: HttpClient.new),
      );
      try {
        await Future.wait([
          mediaStore.chunk(episode, media, 0, download: true),
          secondStore.chunk(episode, media, 1, download: true),
        ]);
        expect(requests, 2);
        expect(
          mediaStore.cachedBytes(episode.id, media.url),
          podcastChunkBytes * 2,
        );
      } finally {
        await secondStore.close();
      }
    },
  );
  test(
    'cache disabling avoids persistence while explicit downloading still stores bytes',
    () async {
      store.setSetting(null, 'cacheEnabled', false);
      await mediaStore.chunk(episode, media, 0);
      expect(mediaStore.cachedBytes(episode.id, media.url), 0);
      await mediaStore.chunk(episode, media, 0, download: true);
      expect(mediaStore.cachedBytes(episode.id, media.url), podcastChunkBytes);
    },
  );
  test(
    'clear cache preserves playing, retained and completed downloads',
    () async {
      await mediaStore.chunk(episode, media, 0);
      mediaStore.protectedEpisodes.add(episode.id);
      await mediaStore.clean(allTemporary: true);
      expect(mediaStore.cachedBytes(episode.id, media.url), podcastChunkBytes);
      mediaStore.protectedEpisodes.clear();
      store.saveState(episode.id, PodcastEpisodeState(retained: true));
      await mediaStore.clean(allTemporary: true);
      expect(mediaStore.cachedBytes(episode.id, media.url), podcastChunkBytes);
      store.saveState(episode.id, PodcastEpisodeState());
      await mediaStore.clean(allTemporary: true);
      expect(mediaStore.cachedBytes(episode.id, media.url), 0);
    },
  );
  test('gateway returns 416 for invalid or out-of-bounds ranges', () async {
    final uri = await mediaStore.playbackUri(episode, media);
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set('range', 'bytes=${payload.length + 1}-');
      final response = await request.close();
      expect(response.statusCode, 416);
      expect(
        response.headers.value('content-range'),
        'bytes */${payload.length}',
      );
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  });
  test(
    'unknown-length exact chunk boundary is finalized without a false partial download',
    () async {
      ignoreRange = true;
      unknownLength = true;
      payload = Uint8List.sublistView(payload, 0, podcastChunkBytes * 2);
      await mediaStore.chunk(episode, media, 0, download: true);
      await mediaStore.chunk(episode, media, 1, download: true);
      expect(mediaStore.isComplete(episode.id, media.url), isFalse);
      expect(
        await mediaStore.chunk(episode, media, 2, download: true),
        isEmpty,
      );
      expect(mediaStore.isComplete(episode.id, media.url), isTrue);
    },
  );
  test(
    'assembled files replace chunks and continue serving shared offline ranges',
    () async {
      for (var i = 0; i < 3; i++) {
        await mediaStore.chunk(episode, media, i, download: true);
      }
      final assembled = await mediaStore.assemble(episode, media);
      final files = directory
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(files, hasLength(1));
      expect(
        FileSystemEntity.identicalSync(files.single.path, assembled.path),
        isTrue,
      );
      await server.close(force: true);
      expect(
        await mediaStore.chunk(episode, media, 1),
        payload.sublist(podcastChunkBytes, podcastChunkBytes * 2),
      );
      expect(mediaStore.cachedBytes(episode.id, media.url), payload.length);
      final replacement = File('${directory.path}/replacement.mp3');
      final next = Uint8List.fromList(
        payload.map((b) => (b + 3) % 251).toList(),
      );
      await replacement.writeAsBytes(next);
      await mediaStore.importFile(episode, media, replacement);
      expect(
        await (await mediaStore.assemble(episode, media)).readAsBytes(),
        next,
      );
    },
  );
  test(
    'HLS rewrites segment and key URLs through the scoped gateway',
    () async {
      final hls = PodcastMedia(
        url: 'http://127.0.0.1:${server.port}/playlist.m3u8',
        mimeType: 'application/vnd.apple.mpegurl',
      );
      episode = PodcastEpisode.fromJson({
        ...episode.toJson(),
        'media': [hls.toJson()],
      });
      final uri = await mediaStore.playbackUri(episode, hls);
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(uri)).close();
        final body = await response.transform(SystemEncoding().decoder).join();
        expect(body, contains('#EXTM3U'));
        expect(body, isNot(contains('episode.mp3')));
        final key = RegExp('URI="([^"]+)"').firstMatch(body)![1]!;
        expect(Uri.parse(key).port, uri.port);
        final segment = body
            .split('\n')
            .firstWhere((line) => line.startsWith('http'));
        final segmentResponse = await (await client.getUrl(
          Uri.parse(segment),
        )).close();
        expect(
          await segmentResponse.fold<List<int>>(
            [],
            (bytes, chunk) => bytes..addAll(chunk),
          ),
          payload,
        );
        expect(mediaStore.isDownloaded(episode.id, hls.url), isFalse);
      } finally {
        client.close(force: true);
      }
    },
  );
}
