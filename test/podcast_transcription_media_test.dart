import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

void main() {
  late Directory directory;
  late PodcastStore store;
  late PodcastController controller;
  late PodcastMediaStore mediaStore;
  late HttpServer origin;
  late PodcastEpisode episode;
  late PodcastMedia media;
  late Completer<void> stalled, release;
  final ranges = <int>[];
  const total = 3 * podcastChunkBytes + 123;
  var ignoreRange = false, failOnce = -1, stallAt = -1;
  var chunkDelayMs = 6;
  Uint8List payload(int offset, int length) =>
      Uint8List.fromList(List.generate(length, (i) => (offset + i) % 251));
  setUp(() async {
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('podcast-transcription-');
    store = PodcastStore(sqlite3.openInMemory());
    ranges.clear();
    ignoreRange = false;
    chunkDelayMs = 6;
    failOnce = stallAt = -1;
    stalled = Completer();
    release = Completer();
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      try {
        final match = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = ignoreRange ? 0 : int.parse(match?[1] ?? '0');
        final end = ignoreRange
            ? total - 1
            : min(total - 1, int.tryParse(match?[2] ?? '') ?? total - 1);
        ranges.add(start);
        if (start == failOnce) {
          failOnce = -1;
          request.response.statusCode = 503;
          await request.response.close();
          return;
        }
        request.response.statusCode = ignoreRange ? 200 : 206;
        request.response.contentLength = end - start + 1;
        request.response.headers.set('content-type', 'audio/mpeg');
        request.response.headers.set('etag', '"episode-v1"');
        if (!ignoreRange) {
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/$total',
          );
        }
        for (var offset = start; offset <= end; offset += 32768) {
          request.response.add(payload(offset, min(32768, end - offset + 1)));
          await request.response.flush();
          if (start == stallAt && offset == start) {
            if (!stalled.isCompleted) stalled.complete();
            await release.future;
          }
          await Future<void>.delayed(Duration(milliseconds: chunkDelayMs));
        }
        await request.response.close();
      } catch (_) {
        /* Intentional cancelled connections. */
      }
    });
    media = PodcastMedia(
      url: 'http://127.0.0.1:${origin.port}/episode.mp3',
      mimeType: 'audio/mpeg',
      length: total,
    );
    episode = PodcastEpisode(
      sourceFeedUrl: 'https://publisher.test/rss',
      id: 'episode',
      channelId: 'channel',
      title: 'Two hour podcast',
      durationMs: 7200000,
      media: [media],
    );
    store.write(
      'episode',
      episode.id,
      episode.toJson(),
      channel: episode.channelId,
    );
    final client = PodcastClient(
      http: PodcastHttp(clientFactory: HttpClient.new),
    );
    mediaStore = PodcastMediaStore(
      root: directory,
      store: store,
      http: client.http,
    );
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: mediaStore,
    )..connectivity = [ConnectivityResult.wifi];
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await controller.close();
    await origin.close(force: true);
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'transcription rechecks a persisted network wait on the current Wi-Fi',
    () async {
      chunkDelayMs = 0;
      store.write(
        'download',
        episode.id,
        PodcastDownload(
          episodeId: episode.id,
          mediaUrl: media.url,
          status: PodcastDownloadStatus.waitingNetwork,
          preparation: true,
        ).toJson(),
        channel: episode.channelId,
      );
      final cancel = Completer<void>();
      final pending = controller.prepareLocalMedia(
        episode,
        media,
        cancelSignal: cancel.future,
      );
      try {
        final file = await pending.timeout(const Duration(seconds: 1));
        expect(await file.readAsBytes(), payload(0, total));
        expect(ranges, isNotEmpty);
        expect(
          controller.downloads.single.status,
          PodcastDownloadStatus.completed,
        );
      } finally {
        if (!cancel.isCompleted) cancel.complete();
        await pending.then<void>((_) {}, onError: (Object _) {});
      }
    },
  );

  for (final (paused, budgetFull) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    test(
      'playback completing the cache releases a queued preparation (paused: $paused, budget full: $budgetFull)',
      () async {
        await mediaStore.chunk(episode, media, 0);
        controller.connectivity = [ConnectivityResult.mobile];
        store.write('lease', 'download:${episode.id}', {
          'owner': 'other-worker',
          'until': DateTime.now()
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch,
        });
        final waited = Completer<void>(), cancel = Completer<void>();
        final progress = <PodcastTransferProgress>[];
        final pending = controller.prepareLocalMedia(
          episode,
          media,
          cancelSignal: cancel.future,
          onProgress: (value) {
            progress.add(value);
            if (value.waitingReason == PodcastWaitingReason.otherWorker &&
                !waited.isCompleted) {
              waited.complete();
            }
          },
        );
        try {
          await waited.future.timeout(const Duration(seconds: 2));
          for (var i = 1; i < 4; i++) {
            await mediaStore.chunk(episode, media, i);
          }
          final before = ranges.length;
          controller.connectivity = [ConnectivityResult.none];
          store.setSetting(null, 'pauseAllDownloads', paused);
          if (budgetFull) {
            store.setSetting(null, 'downloadLimitMb', 128);
            store.write('asset', 'other-download', {
              'id': 'other-download',
              'episodeId': 'other',
              'url': 'https://example.com/other',
              'downloaded': true,
              'segments': {'0': 128 * 1024 * 1024},
            });
          }
          final file = await pending.timeout(const Duration(seconds: 2));
          expect(await file.readAsBytes(), payload(0, total));
          expect(ranges.length, before);
          expect(progress.last.reusedBytes, total);
          expect(progress.last.phase, PodcastTransferPhase.ready);
          expect(
            controller.transferProgress(episode.id)?.phase,
            PodcastTransferPhase.ready,
          );
          expect(mediaStore.isDownloaded(episode.id, media.url), !budgetFull);
          if (budgetFull) {
            expect(controller.downloads, isEmpty);
          } else {
            expect(
              controller.downloads.single.status,
              PodcastDownloadStatus.completed,
            );
          }
        } finally {
          cancel.complete();
          await pending.then<void>((_) {}, onError: (Object _) {});
        }
      },
    );
  }

  test(
    'partial playback cache is completed once, reported and retained for offline reuse',
    () async {
      await mediaStore.chunk(episode, media, 1);
      // Two disjoint gaps now finish concurrently. Keep a transfer alive long
      // enough to sample its live speed, independently of host timing.
      chunkDelayMs = 20;
      ranges.clear();
      final progress = <PodcastTransferProgress>[];
      final file = await controller.prepareLocalMedia(
        episode,
        media,
        onProgress: progress.add,
      );
      expect(await file.readAsBytes(), payload(0, total));
      expect(ranges, [0, 2 * podcastChunkBytes]);
      expect(
        progress.any((p) => p.bytesPerSecond > 0 && p.receivedBytes < total),
        isTrue,
      );
      expect(progress.last.reusedBytes, podcastChunkBytes);
      expect(progress.last.fraction, 1);
      expect(mediaStore.isDownloaded(episode.id, media.url), isTrue);
      expect(
        controller.downloads.single.status,
        PodcastDownloadStatus.completed,
      );
      expect(mediaStore.downloadBytes, total);
      expect(mediaStore.cacheBytes, 0);
      expect(mediaStore.partialDownloadBytes, 0);
      await mediaStore.clean(allTemporary: true);
      controller.connectivity = [ConnectivityResult.none];
      store.setSetting(null, 'pauseAllDownloads', true);
      final before = ranges.length;
      final reused = await controller.prepareLocalMedia(episode, media);
      expect(reused.path, file.path);
      expect(ranges.length, before);
      expect(file.parent.listSync().whereType<File>().length, 1);
    },
  );

  test(
    'a fully cached episode can be promoted and transcribed with downloads paused and no network',
    () async {
      for (var i = 0; i < 4; i++) {
        await mediaStore.chunk(episode, media, i);
      }
      expect(mediaStore.isDownloaded(episode.id, media.url), isFalse);
      ranges.clear();
      store.setSetting(null, 'pauseAllDownloads', true);
      controller.connectivity = [ConnectivityResult.none];
      await controller.prepareLocalMedia(episode, media);
      expect(ranges, isEmpty);
      expect(mediaStore.isDownloaded(episode.id, media.url), isTrue);
    },
  );

  test(
    'complete cache is still usable when the separate download budget is full',
    () async {
      for (var i = 0; i < 4; i++) {
        await mediaStore.chunk(episode, media, i);
      }
      store.setSetting(null, 'downloadLimitMb', 128);
      store.write('asset', 'other-download', {
        'id': 'other-download',
        'episodeId': 'other',
        'url': 'https://example.com/other',
        'downloaded': true,
        'segments': {'0': 128 * 1024 * 1024},
      });
      ranges.clear();
      final progress = <PodcastTransferProgress>[];
      final file = await controller.prepareLocalMedia(
        episode,
        media,
        onProgress: progress.add,
      );
      expect(file.lengthSync(), total);
      expect(ranges, isEmpty);
      expect(mediaStore.isDownloaded(episode.id, media.url), isFalse);
      expect(progress.any((p) => p.message.contains('容量已满')), isTrue);
    },
  );

  test(
    'media used by transcription is protected from cleanup in another worker',
    () async {
      await mediaStore.chunk(episode, media, 0);
      mediaStore.retainForUse(episode.id, 'transcription-owner');
      final worker = PodcastMediaStore(
        root: directory,
        store: store,
        http: controller.client.http,
      );
      try {
        await worker.clean(allTemporary: true);
        expect(
          mediaStore.cachedBytes(episode.id, media.url),
          podcastChunkBytes,
        );
        await expectLater(
          worker.remove(episode.id, media.url, includeDownload: true),
          throwsA(isA<HttpException>()),
        );
        mediaStore.releaseForUse(episode.id, 'transcription-owner');
        await worker.clean(allTemporary: true);
        expect(mediaStore.cachedBytes(episode.id, media.url), 0);
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'a transient download error retries the missing block without fetching completed blocks',
    () async {
      await mediaStore.chunk(episode, media, 0);
      ranges.clear();
      failOnce = podcastChunkBytes;
      final progress = <PodcastTransferProgress>[];
      await controller.prepareLocalMedia(
        episode,
        media,
        onProgress: progress.add,
      );
      expect(ranges.where((start) => start == 0), isEmpty);
      expect(ranges.where((start) => start == podcastChunkBytes), hasLength(2));
      expect(progress.any((p) => p.message.contains('重试')), isTrue);
      expect(mediaStore.isComplete(episode.id, media.url), isTrue);
    },
  );

  test(
    'origins ignoring Range use one sequential fill instead of rereading every prefix',
    () async {
      ignoreRange = true;
      final file = await controller.prepareLocalMedia(episode, media);
      expect(await file.readAsBytes(), payload(0, total));
      expect(ranges, [0]);
    },
  );

  test(
    'cancelling preparation promptly closes its transfer and preserves completed cache blocks',
    () async {
      await mediaStore.chunk(episode, media, 0);
      ranges.clear();
      stallAt = podcastChunkBytes;
      final cancel = Completer<void>();
      final future = controller.prepareLocalMedia(
        episode,
        media,
        cancelSignal: cancel.future,
      );
      final failed = expectLater(future, throwsA(isA<HttpException>()));
      await stalled.future.timeout(const Duration(seconds: 3));
      cancel.complete();
      await failed.timeout(const Duration(seconds: 2));
      expect(mediaStore.cachedBytes(episode.id, media.url), podcastChunkBytes);
      expect(mediaStore.isDownloaded(episode.id, media.url), isFalse);
      while (controller.downloads.single.status ==
          PodcastDownloadStatus.downloading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      stallAt = -1;
      release.complete();
      await controller.prepareLocalMedia(episode, media);
      expect(ranges, isNot(contains(0)));
      expect(mediaStore.isDownloaded(episode.id, media.url), isTrue);
    },
  );

  test('mobile transcription only fetches missing playback blocks', () async {
    await mediaStore.chunk(episode, media, 0);
    ranges.clear();
    controller.connectivity = [ConnectivityResult.mobile];
    final file = await controller
        .prepareLocalMedia(episode, media)
        .timeout(const Duration(seconds: 3));
    expect(await file.readAsBytes(), payload(0, total));
    expect(ranges, [podcastChunkBytes]);
    expect(store.preferences.values.containsKey('unmeteredOnly'), isFalse);
    expect(controller.downloads.single.preparation, isFalse);
  });

  for (final sequential in [false, true]) {
    test(
      'cancelling a joined mobile preparation keeps its user download (sequential: $sequential)',
      () async {
        ignoreRange = sequential;
        chunkDelayMs = 0;
        stallAt = 0;
        controller.connectivity = [ConnectivityResult.mobile];
        controller.enqueue(episode);
        await controller.pumpDownloads();
        await stalled.future.timeout(const Duration(seconds: 2));
        expect(
          controller.downloads.single.status,
          PodcastDownloadStatus.downloading,
        );
        final cancel = Completer<void>();
        final pending = controller.prepareLocalMedia(
          episode,
          media,
          cancelSignal: cancel.future,
        );
        final stopped = expectLater(pending, throwsA(isA<HttpException>()));
        try {
          cancel.complete();
          await stopped.timeout(const Duration(seconds: 1));
          expect(
            controller.downloads.single.status,
            PodcastDownloadStatus.downloading,
          );
          release.complete();
          await controller.waitForIdle().timeout(const Duration(seconds: 2));
          final task = controller.downloads.single;
          expect(task.status, PodcastDownloadStatus.completed);
          expect(task.manualRetain, isTrue);
          expect(task.preparation, isFalse);
          expect(ranges, [0]);
        } finally {
          if (!cancel.isCompleted) cancel.complete();
          if (!release.isCompleted) release.complete();
          await pending.then<void>((_) {}, onError: (Object _) {});
        }
      },
    );
  }

  test(
    'joining an existing download never creates duplicate requests or cancels its owner',
    () async {
      stallAt = 0;
      controller.enqueue(episode);
      await stalled.future.timeout(const Duration(seconds: 3));
      final cancel = Completer<void>();
      final joining = controller.prepareLocalMedia(
        episode,
        media,
        cancelSignal: cancel.future,
      );
      final failed = expectLater(joining, throwsA(isA<HttpException>()));
      cancel.complete();
      await failed;
      expect(
        controller.downloads.single.status,
        PodcastDownloadStatus.downloading,
      );
      release.complete();
      await controller.waitForIdle();
      expect(ranges, [0]);
    },
  );

  test(
    'simultaneous preparations share all chunks and one assembled file',
    () async {
      final result = await Future.wait([
        controller.prepareLocalMedia(episode, media),
        controller.prepareLocalMedia(episode, media),
      ]);
      expect(result.first.path, result.last.path);
      expect(ranges, [0]);
      expect(result.first.parent.listSync().whereType<File>().length, 1);
    },
  );
}
