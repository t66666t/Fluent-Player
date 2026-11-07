import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/community_media_input.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides? previousHttp;
  setUp(() {
    previousHttp = HttpOverrides.current;
    HttpOverrides.global = null;
  });
  tearDown(() {
    HttpOverrides.global = previousHttp;
  });
  test('only exact RSS podcast identities enter playback and preparation', () {
    const source = MediaSourceRef(
      kind: MediaSourceKind.podcastEpisode,
      value: 'podcast:one',
      podcast: PodcastEpisodeRef(
        channelId: 'channel',
        episodeId: 'one',
        feedUrl: 'https://publisher.test/rss',
        mediaUrl: 'https://cdn.publisher.test/one.mp3',
      ),
    );
    expect(communityMediaIsPlayable('podcast:one', source: source), isTrue);
    expect(
      () => requireCommunityProcessingSource('podcast:one', source: source),
      returnsNormally,
    );
    expect(
      () => requireCommunityLocalMedia('podcast:one'),
      throwsUnsupportedError,
    );
    for (final path in [
      'podcast:other',
      source.podcast!.mediaUrl,
      'cloud-drive:one',
      'bilibili://stream/one',
    ]) {
      expect(communityMediaIsPlayable(path, source: source), isFalse);
    }
    final item = VideoItem(
      id: 'one',
      path: 'podcast:one',
      title: 'Episode',
      durationMs: 0,
      lastUpdated: 0,
      sourceRef: source,
    );
    expect(
      PlaybackQueuePolicy(sourceExists: (_) => false).isEligible(item),
      isTrue,
    );
    expect(
      PlaybackQueuePolicy(sourceExists: (_) => false).isEligible(
        VideoItem(
          id: 'forged',
          path: 'podcast:one',
          title: 'Forged',
          durationMs: 0,
          lastUpdated: 0,
        ),
      ),
      isFalse,
    );
  });

  test(
    'RSS subscription, media preparation and local gateway work end to end',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'community-podcast-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final audio = List<int>.generate(4096, (i) => i % 251);
      server.listen((request) async {
        if (request.uri.path == '/rss') {
          request.response.headers.contentType = ContentType(
            'application',
            'rss+xml',
          );
          request.response.write(
            '<rss version="2.0"><channel><title>Publisher</title>'
            '<link>$base</link><description>Local fixture</description><item>'
            '<guid>one</guid><title>One</title><enclosure url="$base/one.mp3" '
            'type="audio/mpeg" length="4096"/></item></channel></rss>',
          );
        } else {
          request.response.headers.set('content-type', 'audio/mpeg');
          request.response.contentLength = audio.length;
          request.response.add(audio);
        }
        await request.response.close();
      });
      final store = PodcastStore(sqlite3.openInMemory());
      final http = PodcastHttp(clientFactory: () => HttpClient());
      final media = PodcastMediaStore(
        root: directory,
        store: store,
        http: http,
      );
      final controller = PodcastController(
        store: store,
        client: PodcastClient(http: http),
        mediaStore: media,
      );
      try {
        final resolution = await controller.client.resolve('$base/rss');
        final channel = await controller.subscribe(resolution.feed);
        final episode = store.episodes(channel.id).single;
        expect(episode.sourceFeedUrl, '$base/rss');
        final file = await controller.prepareLocalMedia(
          episode,
          episode.media.single,
        );
        expect(await file.readAsBytes(), audio);
        final gateway = await media.playbackUri(episode, episode.media.single);
        final player = HttpClient();
        try {
          final response = await (await player.getUrl(gateway)).close();
          expect(await response.expand((bytes) => bytes).toList(), audio);
        } finally {
          player.close(force: true);
        }
        controller.updateState(episode.id, (state) => state.positionMs = 4321);
        expect(controller.state(episode.id).positionMs, 4321);
      } finally {
        await controller.close();
        store.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
