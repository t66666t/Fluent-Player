import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_source_policy.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/podcasts/podcast_runtime.dart';
import 'package:video_player_app/models/video_item.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PodcastStore store;
  late PodcastMediaStore mediaStore;
  late PodcastController controller;
  var connections = 0;
  const media = PodcastMedia(url: 'https://cdn.publisher.test/episode.mp3');
  PodcastEpisode episode({String feed = '', List<PodcastMedia>? enclosures}) =>
      PodcastEpisode(
        id: 'episode',
        channelId: 'channel',
        title: 'Episode',
        media: enclosures ?? [media],
        sourceFeedUrl: feed,
      );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('podcast-rss-policy-');
    connections = 0;
    store = PodcastStore(sqlite3.openInMemory());
    final http = PodcastHttp(
      clientFactory: () {
        connections++;
        throw StateError('No request should reach this factory');
      },
    );
    mediaStore = PodcastMediaStore(root: directory, store: store, http: http);
    controller = PodcastController(
      store: store,
      client: PodcastClient(http: http),
      mediaStore: mediaStore,
    );
  });
  tearDown(() async {
    await controller.close();
    store.close();
    await directory.delete(recursive: true);
  });

  test(
    'retired directory and HTTP entry points never construct a network client',
    () async {
      final client = controller.client;
      await expectLater(client.search('episode'), throwsUnsupportedError);
      await expectLater(
        client.resolve('https://publisher.test/rss'),
        throwsUnsupportedError,
      );
      await expectLater(client.http.get(media.url), throwsUnsupportedError);
      expect(connections, 0);
    },
  );

  test(
    'streaming and download APIs reject before leases, callbacks or queue writes',
    () async {
      final old = episode(feed: 'https://publisher.test/rss');
      var callbacks = 0;
      await expectLater(
        mediaStore.chunk(old, media, 0),
        throwsUnsupportedError,
      );
      await expectLater(
        mediaStore.fillWindow(
          old,
          media,
          shouldContinue: () {
            callbacks++;
            return true;
          },
        ),
        throwsUnsupportedError,
      );
      await expectLater(
        mediaStore.fillSequential(
          old,
          media,
          onProgress: (_, _) {
            callbacks++;
            return true;
          },
        ),
        throwsUnsupportedError,
      );
      await expectLater(controller.requestDispatch(), throwsUnsupportedError);
      await expectLater(
        controller.refreshAll(manual: true),
        throwsUnsupportedError,
      );
      await expectLater(
        controller.refreshChannel(old.channelId),
        throwsUnsupportedError,
      );
      await expectLater(
        controller.subscribe(
          PodcastFeed(
            PodcastChannel(
              id: old.channelId,
              feedUrl: old.sourceFeedUrl,
              title: 'Old',
            ),
            [old],
          ),
        ),
        throwsUnsupportedError,
      );
      expect(callbacks, 0);
      expect(store.channels, isEmpty);
      expect(store.list('download'), isEmpty);
      expect(store.list('assetLease'), isEmpty);
      expect(connections, 0);
    },
  );

  test(
    'runtime initialization and legacy playback hooks cannot reactivate podcasts',
    () async {
      final runtime = PodcastRuntime();
      final old = episode(feed: 'https://publisher.test/rss');
      final item = VideoItem(
        id: 'old',
        path: 'podcast:old',
        title: 'Old',
        durationMs: 0,
        lastUpdated: 0,
      );
      try {
        await expectLater(runtime.initialize(), throwsUnsupportedError);
        await expectLater(runtime.prepareCardArtwork(), throwsUnsupportedError);
        await expectLater(runtime.play(old), throwsUnsupportedError);
        await expectLater(
          runtime.resolvePlayback(item),
          throwsUnsupportedError,
        );
        await expectLater(runtime.materialize(item), throwsUnsupportedError);
        await expectLater(runtime.prepareLearning(old), throwsUnsupportedError);
        await expectLater(runtime.restoreSavedQueue(), throwsUnsupportedError);
        await expectLater(runtime.refresh(), throwsUnsupportedError);
        expect(runtime.ready, isFalse);
        expect(connections, 0);
      } finally {
        runtime.dispose();
      }
    },
  );

  test(
    'legacy webpage imports cannot start playback, preparation or downloads',
    () async {
      final old = episode();
      store.write('episode', old.id, old.toJson(), channel: old.channelId);
      await expectLater(
        mediaStore.playbackUri(old, media),
        throwsUnsupportedError,
      );
      await expectLater(
        controller.prepareLocalMedia(old, media),
        throwsUnsupportedError,
      );
      expect(() => controller.enqueue(old), throwsUnsupportedError);
      expect(controller.downloads, isEmpty);
      expect(connections, 0);
    },
  );

  test(
    'retired dispatch refuses old tasks while preserving progress and queue records',
    () async {
      final old = episode();
      store.write('episode', old.id, old.toJson(), channel: old.channelId);
      store.write(
        'download',
        old.id,
        PodcastDownload(episodeId: old.id, mediaUrl: media.url).toJson(),
        channel: old.channelId,
      );
      controller.updateState(old.id, (state) => state.positionMs = 12345);
      final saved = Map<String, dynamic>.from(store.read('download', old.id)!);
      await expectLater(controller.pumpDownloads(), throwsUnsupportedError);
      await controller.waitForIdle();
      expect(store.read('download', old.id), saved);
      expect(controller.state(old.id).positionMs, 12345);
      expect(connections, 0);
    },
  );

  test(
    'complete local files and history survive a missing feed provenance',
    () async {
      final old = episode();
      final file = File('${directory.path}/import.mp3');
      await file.writeAsBytes([1, 2, 3, 4]);
      await mediaStore.importFile(old, media, file);
      final local = await mediaStore.assemble(old, media);
      expect(await local.readAsBytes(), [1, 2, 3, 4]);
      expect(mediaStore.localFileFor(old.id, media.url)?.path, local.path);
      await expectLater(controller.cleanup(), throwsUnsupportedError);
      expect(await local.readAsBytes(), [1, 2, 3, 4]);
      await expectLater(
        controller.prepareLocalMedia(old, media),
        throwsUnsupportedError,
      );
      await expectLater(
        mediaStore.playbackUri(old, media),
        throwsUnsupportedError,
      );
      expect(connections, 0);
    },
  );

  test(
    'source evidence round trips and only covers its supplied enclosures',
    () {
      final sourced = episode(feed: 'https://publisher.test/rss');
      final restored = PodcastEpisode.fromJson(sourced.toJson());
      expect(podcastHasRssMedia(restored, media), isTrue);
      expect(
        podcastHasRssMedia(
          restored,
          const PodcastMedia(url: 'https://other.test/extracted.mp3'),
        ),
        isFalse,
      );
      final webpage = episode(feed: 'https://www.youtube.com/watch?v=abc');
      expect(podcastHasRssMedia(webpage, media), isFalse);
      for (final url in [
        'https://www.youtube-nocookie.com/embed/abcdefghijk',
        'https://r1.googlevideo.com/videoplayback?id=old-stream',
        'https://cn.example.bilivideo.com/upgcxcode/audio.m4s',
        'https://cn.example.bilivideo.cn/upgcxcode/audio.m4s',
      ]) {
        final extracted = PodcastMedia(url: url);
        expect(
          podcastHasRssMedia(
            episode(
              feed: 'https://publisher.test/rss',
              enclosures: [extracted],
            ),
            extracted,
          ),
          isFalse,
        );
      }
      final youtube = const PodcastMedia(
        url: 'https://www.youtube.com/watch?v=abc',
      );
      expect(
        podcastHasRssMedia(
          episode(feed: 'https://publisher.test/rss', enclosures: [youtube]),
          youtube,
        ),
        isFalse,
      );
    },
  );
}
