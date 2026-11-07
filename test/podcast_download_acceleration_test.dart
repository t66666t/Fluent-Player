import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_connection_policy.dart';
import 'package:video_player_app/features/podcasts/podcast_download_gate.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_transfer.dart';
import 'package:video_player_app/services/network/network_models.dart';

void main() {
  setUp(() => HttpOverrides.global = null);

  test(
    'automatic routes classify each destination and switch only once on a transport failure',
    () {
      var now = DateTime.utc(2026, 10, 18);
      final routes = PodcastConnectionPolicy(now: () => now);
      final domestic = Uri.https('qncdn.xyzcdn.net', '/audio.mp3');
      final overseas = Uri.https('cdn.example.org', '/audio.mp3');
      expect(routes.modeFor(domestic), NetworkMode.direct);
      expect(routes.modeFor(overseas), NetworkMode.system);
      for (final status in [401, 403, 429, 503]) {
        expect(
          routes.connectionFailed(overseas, HttpException('HTTP $status')),
          isFalse,
        );
      }
      expect(
        routes.connectionFailed(
          overseas,
          const HandshakeException('TLS certificate'),
        ),
        isFalse,
      );
      expect(
        routes.connectionFailed(overseas, TimeoutException('idle')),
        isTrue,
      );
      expect(routes.modeFor(overseas), NetworkMode.direct);
      expect(routes.modeFor(domestic), NetworkMode.direct);
      expect(
        routes.connectionFailed(overseas, const SocketException('offline')),
        isFalse,
      );
      expect(routes.generation, 1);
      now = now.add(const Duration(minutes: 11));
      expect(routes.modeFor(overseas), NetworkMode.system);
    },
  );

  test(
    'Retry-After accepts HTTP dates and never shortens the server cooldown',
    () {
      final now = DateTime.utc(2026, 10, 18);
      expect(parseRetryAfter('900', now: now), const Duration(minutes: 15));
      expect(
        parseRetryAfter(
          HttpDate.format(now.add(const Duration(minutes: 20))),
          now: now,
        ),
        const Duration(minutes: 20),
      );
      expect(parseRetryAfter('invalid', now: now), isNull);
      expect(
        parseRetryAfter(
          HttpDate.format(now.subtract(const Duration(seconds: 1))),
          now: now,
        ),
        Duration.zero,
      );
    },
  );

  test(
    'separate database connections share host and global limits; queued cancellation is prompt',
    () async {
      final root = await Directory.systemTemp.createTemp('podcast-gate-');
      final first = PodcastStore.open('${root.path}/podcasts.sqlite');
      final second = PodcastStore.open('${root.path}/podcasts.sqlite');
      final a = PodcastDownloadGate(first), b = PodcastDownloadGate(second);
      final release = Completer<void>(), cancel = Completer<void>();
      var active = 0, peak = 0;
      final held = <Future<void>>[];
      Future<void> hold(PodcastDownloadGate gate, String host) =>
          gate.run(Uri.https(host), () async {
            active++;
            peak = max(peak, active);
            await release.future;
            active--;
          }, shouldContinue: () => true);
      try {
        for (var i = 0; i < 3; i++) {
          held.add(hold(i.isEven ? a : b, 'same.test'));
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final waiting = <String>[];
        final blocked = b.run(
          Uri.https('same.test'),
          () async => fail('host limit bypassed'),
          shouldContinue: () => true,
          cancelSignal: cancel.future,
          onWaiting: (message, limited) => waiting.add(message),
        );
        final blockedDone = expectLater(
          blocked,
          throwsA(isA<PodcastTransferException>()),
        );
        held.add(hold(b, 'other.test'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(active, 4);
        expect(first.list('downloadConnection'), hasLength(4));
        final global = a.run(
          Uri.https('third.test'),
          () async => fail('global limit bypassed'),
          shouldContinue: () => true,
          cancelSignal: cancel.future,
        );
        final globalDone = expectLater(
          global,
          throwsA(isA<PodcastTransferException>()),
        );
        cancel.complete();
        await Future.wait([
          blockedDone,
          globalDone,
        ]).timeout(const Duration(seconds: 1));
        expect(waiting, isNotEmpty);
        release.complete();
        await Future.wait(held);
        expect(peak, 4);
        expect(first.list('downloadConnection'), isEmpty);
      } finally {
        if (!release.isCompleted) release.complete();
        await Future.wait(held);
        a.close();
        b.close();
        first.close();
        second.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    '429 cooldown survives gate recreation and all tasks wait without new requests',
    () async {
      final store = PodcastStore(sqlite3.openInMemory());
      final gate = PodcastDownloadGate(store);
      final host = Uri.https('limited.test');
      gate.observe(host, 429, '900');
      gate.close();
      final next = PodcastDownloadGate(store);
      final cancel = Completer<void>();
      final notices = <String>[];
      try {
        final job = next.run(
          host,
          () async => fail('requested while rate limited'),
          shouldContinue: () => true,
          cancelSignal: cancel.future,
          onWaiting: (message, limited) {
            expect(limited, isTrue);
            notices.add(message);
          },
        );
        final done = expectLater(job, throwsA(isA<PodcastTransferException>()));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(notices.single, contains('900'));
        expect(store.list('downloadConnection'), isEmpty);
        cancel.complete();
        await done.timeout(const Duration(seconds: 1));
      } finally {
        next.close();
        store.close();
      }
    },
  );

  group('real HTTP transfers', () {
    late Directory root;
    late PodcastStore store;
    late PodcastMediaStore mediaStore;
    late HttpServer server;
    late PodcastEpisode episode;
    late PodcastMedia media;
    late Completer<void> entered, release;
    final ranges = <(int, int)>[];
    var total = 36 * podcastChunkBytes + 17;
    var ignoreRange = false, holdHeaders = false, stallBody = false;
    var active = 0, peak = 0;
    var version = 1;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('podcast-fast-');
      store = PodcastStore(sqlite3.openInMemory());
      entered = Completer();
      release = Completer();
      ranges.clear();
      version = 1;
      stallBody = false;
      active = peak = 0;
      ignoreRange = holdHeaders = false;
      total = 36 * podcastChunkBytes + 17;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        active++;
        peak = max(peak, active);
        try {
          if (!entered.isCompleted) entered.complete();
          if (holdHeaders) await release.future;
          final match = RegExp(
            r'bytes=(\d+)-(\d+)',
          ).firstMatch(request.headers.value('range') ?? '');
          final start = ignoreRange ? 0 : int.parse(match?[1] ?? '0');
          final end = ignoreRange
              ? total - 1
              : min(total - 1, int.parse(match?[2] ?? '${total - 1}'));
          ranges.add((start, end));
          request.response.statusCode = ignoreRange ? 200 : 206;
          request.response.headers.set('content-type', 'audio/mpeg');
          final responseVersion = version;
          request.response.headers.set('etag', '"stable-$responseVersion"');
          request.response.contentLength = end - start + 1;
          if (!ignoreRange) {
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/$total',
            );
          }
          for (var offset = start; offset <= end; offset += 65536) {
            final data = Uint8List(min(65536, end + 1 - offset))
              ..fillRange(
                0,
                min(65536, end + 1 - offset),
                ((offset ~/ podcastChunkBytes) + responseVersion - 1) % 251,
              );
            request.response.add(data);
            await request.response.flush();
            if (stallBody &&
                ranges.length == 1 &&
                offset + data.length == podcastChunkBytes) {
              await release.future;
            }
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
          await request.response.close();
        } catch (_) {
          /* A cancelled client closes its socket. */
        } finally {
          active--;
        }
      });
      media = PodcastMedia(
        url: 'http://127.0.0.1:${server.port}/audio.mp3',
        mimeType: 'audio/mpeg',
        length: total,
      );
      episode = PodcastEpisode(
        sourceFeedUrl: 'https://publisher.test/rss',
        id: 'e',
        channelId: 'c',
        title: 'long podcast',
        media: [media],
      );
      mediaStore = PodcastMediaStore(
        root: Directory('${root.path}/media'),
        store: store,
        http: PodcastHttp(clientFactory: HttpClient.new),
        bodyIdleTimeout: const Duration(seconds: 2),
      );
    });
    tearDown(() async {
      if (!release.isCompleted) release.complete();
      await mediaStore.close();
      await server.close(force: true);
      store.close();
      await root.delete(recursive: true);
    });

    test(
      'validated long audio really uses parallel disjoint 16 MiB windows and exact disk content',
      () async {
        final progress = <int>[];
        while (!mediaStore.isComplete(episode.id, media.url)) {
          await mediaStore.fillWindow(
            episode,
            media,
            shouldContinue: () => true,
            onUseful: (saved, pending) => progress.add(saved + pending),
          );
        }
        expect(peak, 2);
        expect(ranges.first, (0, 4 * podcastChunkBytes - 1));
        expect(
          ranges,
          contains((4 * podcastChunkBytes, 20 * podcastChunkBytes - 1)),
        );
        expect(
          ranges,
          contains((20 * podcastChunkBytes, 36 * podcastChunkBytes - 1)),
        );
        expect(ranges.length, 4);
        expect(store.list('downloadConnection'), isEmpty);
        final file = await mediaStore.assemble(episode, media);
        final data = await file.readAsBytes();
        expect(data.length, total);
        for (var i = 0; i < data.length; i += 65536) {
          expect(data[i], (i ~/ podcastChunkBytes) % 251);
        }
        expect(progress, orderedEquals([...progress]..sort()));
      },
    );

    test(
      'a download joins an already-open playback chunk without requesting it twice',
      () async {
        total = 5 * podcastChunkBytes;
        final playing = mediaStore.chunk(episode, media, 0);
        await entered.future;
        final downloading = mediaStore.fillWindow(
          episode,
          media,
          shouldContinue: () => true,
        );
        await playing;
        final result = await downloading;
        expect(result.complete, isTrue);
        expect(ranges.map((r) => r.$1), [0, podcastChunkBytes]);
      },
    );

    test(
      'a 206 version change discards old chunks before parallel downloads resume',
      () async {
        await mediaStore.fillWindow(episode, media, shouldContinue: () => true);
        version = 2;
        while (!mediaStore.isComplete(episode.id, media.url)) {
          await mediaStore.fillWindow(
            episode,
            media,
            shouldContinue: () => true,
          );
        }
        final file = await mediaStore.assemble(episode, media);
        final data = await file.readAsBytes();
        for (var i = 0; i < data.length; i += 65536) {
          expect(data[i], ((i ~/ podcastChunkBytes) + 1) % 251);
        }
        expect(mediaStore.manifest(episode.id, media.url)['revision'], 1);
      },
    );

    test(
      'a paused decoder sharing a download chunk cannot block download completion',
      () async {
        total = 36 * podcastChunkBytes;
        await mediaStore.fillWindow(episode, media, shouldContinue: () => true);
        final downloading = mediaStore.fillWindow(
          episode,
          media,
          shouldContinue: () => true,
        );
        final player = HttpClient();
        try {
          final uri = await mediaStore.playbackUri(episode, media);
          final request = await player.getUrl(uri);
          request.headers.set('range', 'bytes=${4 * podcastChunkBytes}-');
          final response = await request.close();
          expect(response.statusCode, 206);
          // Intentionally do not consume the decoder's HTTP body.
          final result = await downloading.timeout(const Duration(seconds: 4));
          expect(result.complete, isTrue);
        } finally {
          player.close(force: true);
        }
      },
    );

    test(
      'a source losing Range support stops its parallel batch and fills sequentially once',
      () async {
        await mediaStore.fillWindow(episode, media, shouldContinue: () => true);
        ignoreRange = true;
        final result = await mediaStore.fillWindow(
          episode,
          media,
          shouldContinue: () => true,
        );
        expect(result.complete, isTrue);
        expect(mediaStore.cachedBytes(episode.id, media.url), total);
        expect(ranges.length, lessThanOrEqualTo(4));
      },
    );

    test(
      'a stalled response automatically resumes from the first missing chunk and explains the retry',
      () async {
        stallBody = true;
        total = 3 * podcastChunkBytes + 17;
        store.write(
          'episode',
          episode.id,
          episode.toJson(),
          channel: episode.channelId,
        );
        final controller = PodcastController(
          store: store,
          client: PodcastClient(http: mediaStore.http),
          mediaStore: mediaStore,
        )..connectivity = [ConnectivityResult.wifi];
        final progress = <PodcastTransferProgress>[];
        try {
          final file = await controller
              .prepareLocalMedia(episode, media, onProgress: progress.add)
              .timeout(const Duration(seconds: 8));
          expect(file.lengthSync(), total);
          expect(ranges.map((range) => range.$1), [0, podcastChunkBytes]);
          expect(progress.any((p) => p.message.contains('重试')), isTrue);
          expect(mediaStore.isComplete(episode.id, media.url), isTrue);
        } finally {
          await controller.close();
        }
      },
    );

    test(
      'Range-ignoring source is saved from its first response with one request',
      () async {
        ignoreRange = true;
        total = 2 * podcastChunkBytes + 17;
        final result = await mediaStore.fillWindow(
          episode,
          media,
          shouldContinue: () => true,
        );
        expect(result.complete, isTrue);
        expect(ranges, hasLength(1));
        expect(mediaStore.cachedBytes(episode.id, media.url), total);
      },
    );

    test(
      'cancel during header wait releases the task without waiting for timeout',
      () async {
        holdHeaders = true;
        final cancel = Completer<void>();
        final job = mediaStore.fillWindow(
          episode,
          media,
          shouldContinue: () => !cancel.isCompleted,
          cancelSignal: cancel.future,
        );
        await entered.future.timeout(const Duration(seconds: 2));
        cancel.complete();
        final result = await job.timeout(const Duration(seconds: 1));
        expect(result.stopped, isTrue);
        expect(store.list('downloadConnection'), isEmpty);
      },
    );
  });
}
