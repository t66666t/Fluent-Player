import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PODCAST_NETWORK_NATIVE_TEST');
  const live = bool.fromEnvironment('PODCAST_TRANSCRIPTION_SOURCE_LIVE_TEST');
  testWidgets(
    'native Wi-Fi revives a persisted transcription network wait',
    (tester) async {
      final connectivity = await Connectivity().checkConnectivity();
      // ignore: avoid_print
      print(
        'PODCAST_NETWORK_NATIVE connectivity=${connectivity.map((v) => v.name).toList()}',
      );
      final root = await Directory.systemTemp.createTemp(
        'podcast-network-native-',
      );
      final store = PodcastStore(sqlite3.openInMemory());
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payload = List<int>.filled(65536, 85);
      var requests = 0;
      origin.listen((request) async {
        try {
          requests++;
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
          request.response.headers.set('etag', '"network-probe"');
          request.response.headers.set(
            'content-range',
            'bytes $start-$end/${payload.length}',
          );
          request.response.contentLength = end - start + 1;
          request.response.add(payload.sublist(start, end + 1));
          await request.response.close();
        } catch (_) {}
      });
      final media = PodcastMedia(
        url: 'http://127.0.0.1:${origin.port}/episode.mp3',
        mimeType: 'audio/mpeg',
        length: payload.length,
      );
      final episode = PodcastEpisode(
        sourceFeedUrl: 'https://publisher.test/rss',
        id: 'network-probe',
        channelId: 'channel',
        title: 'Network probe',
        media: [media],
      );
      store.write(
        'episode',
        episode.id,
        episode.toJson(),
        channel: episode.channelId,
      );
      final client = PodcastClient();
      final controller = PodcastController(
        store: store,
        client: client,
        readConnectivity: Connectivity().checkConnectivity,
        mediaStore: PodcastMediaStore(
          root: root,
          store: store,
          http: client.http,
        ),
      )..connectivity = [ConnectivityResult.none];
      store.write(
        'download',
        episode.id,
        PodcastDownload(
          episodeId: episode.id,
          mediaUrl: media.url,
          preparation: true,
          status: PodcastDownloadStatus.waitingNetwork,
        ).toJson(),
        channel: episode.channelId,
      );
      final cancel = Completer<void>();
      try {
        final pending = controller.prepareLocalMedia(
          episode,
          media,
          cancelSignal: cancel.future,
        );
        final file = await pending.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            cancel.complete();
            throw TimeoutException(
              '本机网络检测阻止了转录下载：${controller.downloads.map((v) => v.status.name).toList()}，请求数 $requests',
            );
          },
        );
        expect(await file.readAsBytes(), payload);
        expect(requests, greaterThan(0));
        // ignore: avoid_print
        print(
          'PODCAST_NETWORK_NATIVE transcription download OK; requests=$requests',
        );
      } finally {
        if (!cancel.isCompleted) cancel.complete();
        await controller.close();
        await origin.close(force: true);
        store.close();
        await root.delete(recursive: true);
      }
    },
    skip: !enabled || !Platform.isWindows,
  );
  testWidgets(
    'Crossing transcription downloads real audio after a persisted network wait',
    (tester) async {
      final root = await Directory.systemTemp.createTemp('podcast-asr-source-');
      final store = PodcastStore(sqlite3.openInMemory());
      final client = PodcastClient();
      final mediaStore = PodcastMediaStore(
        root: root,
        store: store,
        http: client.http,
      );
      final controller = PodcastController(
        store: store,
        client: client,
        mediaStore: mediaStore,
        readConnectivity: Connectivity().checkConnectivity,
      )..connectivity = [ConnectivityResult.none];
      final cancel = Completer<void>();
      try {
        final feed = (await client.resolve(
          'https://feed.xyzfm.space/68fyjknth9hj',
        )).feed;
        final episode = feed.episodes.firstWhere(
          (episode) => episode.media.any(
            (media) => !media.isVideo && !media.isStreamManifest,
          ),
        );
        final media = episode.media.firstWhere(
          (media) => !media.isVideo && !media.isStreamManifest,
        );
        store.write(
          'episode',
          episode.id,
          episode.toJson(),
          channel: episode.channelId,
        );
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
        var received = 0;
        File? completed;
        try {
          completed = await controller
              .prepareLocalMedia(
                episode,
                media,
                cancelSignal: cancel.future,
                onProgress: (progress) {
                  received = max(received, progress.receivedBytes);
                  // Prove the real transcription download path without uploading
                  // an episode to ASR or fetching a full long podcast just to test.
                  if (!cancel.isCompleted &&
                      mediaStore.cachedBytes(episode.id, media.url) >=
                          podcastChunkBytes) {
                    cancel.complete();
                  }
                },
              )
              .timeout(const Duration(seconds: 90));
        } on HttpException {
          if (!cancel.isCompleted) rethrow;
        }
        await controller.waitForTask(episode.id);
        expect(received, greaterThan(0));
        expect(mediaStore.cachedBytes(episode.id, media.url), greaterThan(0));
        if (completed != null) expect(await completed.exists(), isTrue);
        // ignore: avoid_print
        print(
          'PODCAST_TRANSCRIPTION_SOURCE Crossing: '
          'received=$received cached=${mediaStore.cachedBytes(episode.id, media.url)} '
          'completed=${completed != null}; native connectivity=${controller.connectivity.map((v) => v.name).toList()}',
        );
      } finally {
        if (!cancel.isCompleted) cancel.complete();
        await controller.close();
        store.close();
        await root.delete(recursive: true);
      }
    },
    skip: !enabled || !live || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
