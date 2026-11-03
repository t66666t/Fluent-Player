import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';

void main() {
  test(
    'live Apple directory result resolves into a playable public podcast feed',
    () async {
      final client = PodcastClient(
        http: PodcastHttp(clientFactory: () => HttpClient()),
      );
      final results = await client.search('Planet Money', region: 'US');
      expect(results, isNotEmpty);
      final selected =
          results
              .where((r) => r.title.toLowerCase() == 'planet money')
              .firstOrNull ??
          results.first;
      final resolution = await client.resolve(selected.feedUrl);
      expect(resolution.singleEpisode, isFalse);
      expect(resolution.feed.channel.title, isNotEmpty);
      expect(resolution.feed.episodes, isNotEmpty);
      expect(
        resolution.feed.episodes.first.media.first.url,
        startsWith('https://'),
      );
    },
    skip: !const bool.fromEnvironment('PODCAST_LIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
