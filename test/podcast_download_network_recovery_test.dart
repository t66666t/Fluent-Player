import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late HttpServer origin;
  late PodcastStore store;
  late PodcastController controller;
  late PodcastEpisode episode;
  late PodcastMedia media;
  late Completer<void> cancel, requestStarted, release;
  late Completer<List<ConnectivityResult>> heldRead;
  var reads = 0, requests = 0;
  var failRead = false, holdResponse = false;
  final payload = List<int>.filled(65536, 85);

  setUp(() async {
    HttpOverrides.global = null;
    root = await Directory.systemTemp.createTemp('podcast-network-recovery-');
    store = PodcastStore(sqlite3.openInMemory());
    // Old global and channel values must have no effect after an upgrade.
    for (final scope in ['global', 'channel']) {
      store.write('settings', scope, {
        'unmeteredOnly': true,
        'transcriptionUnmeteredOnly': true,
      });
    }
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    reads = requests = 0;
    failRead = holdResponse = false;
    cancel = Completer<void>();
    requestStarted = Completer<void>();
    release = Completer<void>();
    heldRead = Completer<List<ConnectivityResult>>();
    origin.listen((request) async {
      try {
        requests++;
        if (!requestStarted.isCompleted) requestStarted.complete();
        if (holdResponse) await release.future;
        final range = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = int.tryParse(range?[1] ?? '') ?? 0;
        final end = min(
          payload.length - 1,
          int.tryParse(range?[2] ?? '') ?? payload.length - 1,
        );
        request.response.statusCode = 206;
        request.response.headers.set('content-type', 'audio/mpeg');
        request.response.headers.set('etag', '"episode"');
        request.response.headers.set(
          'content-range',
          'bytes $start-$end/${payload.length}',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(payload.sublist(start, end + 1));
        await request.response.close();
      } catch (_) {}
    });
    media = PodcastMedia(
      url: 'http://127.0.0.1:${origin.port}/episode.mp3',
      mimeType: 'audio/mpeg',
      length: payload.length,
    );
    episode = PodcastEpisode(
      sourceFeedUrl: 'https://publisher.test/rss',
      id: 'episode',
      channelId: 'channel',
      title: 'Episode',
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
    controller = PodcastController(
      store: store,
      client: client,
      mediaStore: PodcastMediaStore(
        root: root,
        store: store,
        http: client.http,
      ),
      readConnectivity: () async {
        reads++;
        if (failRead) {
          throw PlatformException(code: 'temporarily_unavailable');
        }
        return heldRead.future;
      },
    );
  });
  tearDown(() async {
    if (!cancel.isCompleted) cancel.complete();
    if (!release.isCompleted) release.complete();
    if (!heldRead.isCompleted) heldRead.complete([ConnectivityResult.none]);
    await controller.close();
    await origin.close(force: true);
    store.close();
    await root.delete(recursive: true);
  });

  Future<File> prepare({void Function(PodcastTransferProgress)? onProgress}) =>
      controller.prepareLocalMedia(
        episode,
        media,
        cancelSignal: cancel.future,
        onProgress: onProgress,
      );

  for (final detected in <List<ConnectivityResult>>[
    [ConnectivityResult.mobile],
    [ConnectivityResult.wifi, ConnectivityResult.vpn],
    [ConnectivityResult.ethernet],
    [ConnectivityResult.vpn],
    [ConnectivityResult.other],
    [ConnectivityResult.none],
    [],
  ]) {
    test('transcription uses working HTTP on network $detected', () async {
      controller.connectivity = detected;
      final progress = <PodcastTransferProgress>[];
      final file = await prepare(
        onProgress: progress.add,
      ).timeout(const Duration(seconds: 2));
      expect(await file.readAsBytes(), payload);
      expect(reads, 0, reason: 'a stalled detector must not gate HTTP');
      expect(requests, 1);
      expect(
        progress.any((p) => p.phase == PodcastTransferPhase.waitingNetwork),
        isFalse,
      );
      expect(store.preferences.values.containsKey('unmeteredOnly'), isFalse);
      expect(
        store
            .effective(episode.channelId)
            .values
            .containsKey('transcriptionUnmeteredOnly'),
        isFalse,
      );
      expect(controller.downloads.single.preparation, isFalse);
    });
  }

  test(
    'a failed network detector cannot block a manual mobile download',
    () async {
      failRead = true;
      controller.connectivity = [ConnectivityResult.mobile];
      controller.enqueue(episode);
      await controller.waitForIdle().timeout(const Duration(seconds: 2));
      expect(
        controller.downloads.single.status,
        PodcastDownloadStatus.completed,
      );
      expect(requests, 1);
      expect(reads, 0);
    },
  );

  test('automatic downloads also use mobile data', () async {
    final channel = PodcastChannel(
      id: episode.channelId,
      feedUrl: 'https://example.com/feed',
      title: 'Channel',
    );
    store.write('channel', channel.id, channel.toJson());
    store.setSetting(channel.id, 'autoDownload', true);
    controller.connectivity = [ConnectivityResult.mobile];
    controller.enqueue(episode, automatic: true);
    await controller.waitForIdle().timeout(const Duration(seconds: 2));
    expect(controller.downloads.single.status, PodcastDownloadStatus.completed);
    expect(controller.downloads.single.automatic, isTrue);
    expect(requests, 1);
    expect(reads, 0);
  });

  test(
    'an old persisted network wait resumes on mobile without a change event',
    () async {
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
      controller.connectivity = [ConnectivityResult.mobile];
      expect(controller.downloads.single.status, PodcastDownloadStatus.queued);
      final file = await prepare().timeout(const Duration(seconds: 2));
      expect(await file.readAsBytes(), payload);
      expect(requests, 1);
      expect(reads, 0);
    },
  );

  test('Wi-Fi to mobile transitions do not pause an active transfer', () async {
    controller.connectivity = [ConnectivityResult.wifi];
    holdResponse = true;
    final pending = prepare();
    await requestStarted.future.timeout(const Duration(seconds: 2));
    controller.connectivity = [ConnectivityResult.mobile];
    await controller.pumpDownloads();
    release.complete();
    final file = await pending.timeout(const Duration(seconds: 2));
    expect(await file.readAsBytes(), payload);
    expect(requests, 1);
    expect(reads, 0);
  });

  test('cancellation during response headers starts no late request', () async {
    holdResponse = true;
    final pending = prepare();
    final stopped = expectLater(pending, throwsA(isA<HttpException>()));
    await requestStarted.future.timeout(const Duration(seconds: 2));
    cancel.complete();
    await stopped.timeout(const Duration(seconds: 1));
    release.complete();
    await controller.waitForIdle().timeout(const Duration(seconds: 2));
    expect(controller.downloads.single.status, PodcastDownloadStatus.paused);
    expect(requests, 1);
  });

  test(
    'complete local audio needs no network when downloads are paused',
    () async {
      final first = await prepare();
      final before = requests;
      controller.connectivity = [ConnectivityResult.none];
      store.setSetting(null, 'pauseAllDownloads', true);
      final reused = await prepare();
      expect(reused.path, first.path);
      expect(requests, before);
      expect(reads, 0);
      expect(await reused.readAsBytes(), payload);
    },
  );
}
