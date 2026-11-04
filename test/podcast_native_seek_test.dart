import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_policy.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);
  test(
    'real native player seeks the newest long Draymond Green episode without scanning its prefix',
    () async {
      final client = PodcastClient(
        http: PodcastHttp(clientFactory: HttpClient.new),
      );
      final feed = (await client.resolve(
        'https://rss.amperwave.net/v2/feed/audacynetwork/draymond-green',
      )).feed;
      final episodes = [...feed.episodes]
        ..sort((a, b) => b.publishedMs.compareTo(a.publishedMs));
      final episode = episodes.firstWhere(
        (e) => e.durationMs > const Duration(minutes: 36).inMilliseconds,
      );
      final directory = await Directory.systemTemp.createTemp(
        'podcast-native-seek-',
      );
      final store = PodcastStore(sqlite3.openInMemory());
      final mediaStore = PodcastMediaStore(
        root: directory,
        store: store,
        http: client.http,
      );
      Process? player;
      try {
        final uri = await mediaStore.playbackUri(episode, episode.media.first);
        player = await Process.start('python', [
          'test/support/podcast_native_seek_probe.py',
          File('build/windows/x64/runner/Debug/libmpv-2.dll').absolute.path,
          uri.toString(),
          '2100',
          jsonEncode(PodcastPlaybackPolicy.nativeOptions(audioOnly: true)),
        ]);
        final output = Completer<Map>();
        final errors = player.stderr.transform(utf8.decoder).join();
        final input = player.stdin;
        final messages = player.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (!line.startsWith('{')) return;
              final event = jsonDecode(line) as Map;
              if (event['event'] == 'seek-start') {
                mediaStore.prepareForSeek(episode.id);
                input.writeln('go');
              }
              if (event['event'] == 'result' && !output.isCompleted) {
                output.complete(event);
              }
            });
        final exit = await player.exitCode.timeout(const Duration(seconds: 90));
        await messages.cancel();
        expect(exit, 0, reason: await errors);
        final result = await output.future.timeout(const Duration(seconds: 1));
        final m = mediaStore.manifest(episode.id, episode.media.first.url);
        final indices =
            (m['segments'] as Map).keys
                .map((key) => int.parse(key.toString()))
                .toList()
              ..sort();
        final bytes = mediaStore.cachedBytes(
          episode.id,
          episode.media.first.url,
        );
        expect(bytes, lessThan(16 * 1024 * 1024));
        expect(
          int.tryParse(result['streamPos'].toString()) ?? 0,
          greaterThan(20 * 1024 * 1024),
        );
        // ignore: avoid_print
        print(
          'PODCAST_NATIVE_SEEK: episode=${episode.title}; seekMs=${result['seekMs']}; streamPos=${result['streamPos']}; position=${result['position']}; cachedBytes=$bytes; chunks=$indices',
        );
      } finally {
        player?.kill();
        await mediaStore.close();
        store.close();
        await directory.delete(recursive: true);
      }
    },
    skip:
        !const bool.fromEnvironment('PODCAST_NATIVE_SEEK_TEST') ||
        !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
