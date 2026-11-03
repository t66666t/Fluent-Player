import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'podcast_core_test.dart' show podcastFixture;

class _FixtureHttp extends PodcastHttp {
  _FixtureHttp(this.source);
  final String Function(Uri) source;
  @override
  Future<PodcastResponse> get(
    String url, {
    Map<String, String> headers = const {},
    int maxBytes = 32 * 1024 * 1024,
    void Function(HttpClient)? onClient,
    bool Function()? isCancelled,
  }) async =>
      PodcastResponse(utf8.encode(source(Uri.parse(url))), 200, url, {});
}

void main() {
  test(
    'Apple episode links resolve a channel and identify the shared episode',
    () async {
      final client = PodcastClient(
        http: _FixtureHttp((uri) {
          if (uri.host == 'itunes.apple.com') {
            return jsonEncode({
              'results': [
                uri.queryParameters['id'] == '123'
                    ? {'feedUrl': 'https://publisher.test/rss'}
                    : {'episodeGuid': 'stable', 'trackName': '第一集'},
              ],
            });
          }
          return podcastFixture(second: true);
        }),
      );
      final result = await client.resolve(
        'https://podcasts.apple.com/cn/podcast/id123?i=456',
      );
      expect(result.singleEpisode, isFalse);
      expect(result.focusEpisodeId, result.feed.episodes.first.id);
      expect(result.message, isNull);
    },
  );
  test(
    'a removed Apple episode is not silently represented as a found episode',
    () async {
      final client = PodcastClient(
        http: _FixtureHttp(
          (uri) => uri.host == 'itunes.apple.com'
              ? jsonEncode({
                  'results': uri.queryParameters['id'] == '123'
                      ? [
                          {'feedUrl': 'https://publisher.test/rss'},
                        ]
                      : [],
                })
              : podcastFixture(),
        ),
      );
      final result = await client.resolve(
        'https://podcasts.apple.com/podcast/id123?i=999',
      );
      expect(result.focusEpisodeId, isNull);
      expect(result.message, contains('不在当前公开节目列表'));
    },
  );
  test(
    'public Xiaoyuzhou episode data remains a single import without RSS',
    () async {
      final client = PodcastClient(
        http: _FixtureHttp(
          (_) =>
              '''<html><script type="application/json" id="__NEXT_DATA__">${jsonEncode({
                'props': {
                  'pageProps': {
                    'episode': {
                      'eid': 'one',
                      'title': '公开单集',
                      'duration': 121,
                      'media': {
                        'source': {'url': 'https://cdn.test/audio.m4a'},
                      },
                      'podcast': {'title': '播客作者'},
                    },
                  },
                },
              })}</script></html>''',
        ),
      );
      final result = await client.resolve(
        'https://www.xiaoyuzhoufm.com/episode/one',
      );
      expect(result.singleEpisode, isTrue);
      expect(result.feed.channel.active, isFalse);
      expect(result.feed.episodes.single.durationMs, 121000);
      expect(
        result.feed.episodes.single.media.single.url,
        'https://cdn.test/audio.m4a',
      );
    },
  );
  test(
    'web discovery confirms RSS and does not invent a feed for ordinary pages',
    () async {
      final client = PodcastClient(
        http: _FixtureHttp(
          (uri) => switch (uri.path) {
            '/show' =>
              '<link rel="alternate" type="application/rss+xml" href="/rss">',
            '/rss' => podcastFixture(),
            _ => '<html><title>A show without a feed</title></html>',
          },
        ),
      );
      expect(
        (await client.resolve('https://publisher.test/show')).singleEpisode,
        isFalse,
      );
      await expectLater(
        client.resolve('https://publisher.test/empty'),
        throwsFormatException,
      );
    },
  );
}
