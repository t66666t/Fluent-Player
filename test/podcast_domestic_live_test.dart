import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_controller.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_policy.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/services/media_artwork_repository.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/network/platform_proxy_resolver.dart';

class _LivePaths extends PathProviderPlatform {
  _LivePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PODCAST_DOMESTIC_LIVE_TEST');
  const native = bool.fromEnvironment('PODCAST_DOMESTIC_NATIVE_TEST');
  const deviceProxy = String.fromEnvironment(
    'PODCAST_TEST_SYSTEM_PROXY',
    defaultValue: 'DIRECT',
  );
  late Directory directory;
  late PathProviderPlatform previousPaths;
  final network = NetworkHttp.instance;

  setUpAll(() async {
    if (!enabled) return;
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('podcast-domestic-live-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _LivePaths(directory.path);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformProxyResolver.channel, (call) async {
          if (call.method == 'resolveProxy') return [deviceProxy];
          throw MissingPluginException();
        });
    await network.settings.ready;
  });

  tearDownAll(() async {
    if (!enabled) return;
    await network.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformProxyResolver.channel, null);
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });

  // These use the production PodcastHttp, artwork fetcher and playback gateway.
  // Only platform settings are supplied by the test, in an isolated directory.
  for (final mode in <NetworkMode?>[
    null,
    NetworkMode.direct,
    NetworkMode.system,
  ]) {
    for (final (query, appleId) in [
      ('十字路口Crossing', '1729552193'),
      ('AI炼金术', '1671502201'),
    ]) {
      test(
        '$query ${mode?.name ?? 'automatic'} search, covers, preview and subscription play',
        () async {
          await network.settings.setUnifiedMode(mode);
          final client = PodcastClient();
          final results = await client.search(query, region: 'CN');
          final selected = results.firstWhere(
            (item) => item.appleId == appleId,
          );
          final feed = (await client.resolve(selected.feedUrl)).feed;
          expect(feed.episodes, isNotEmpty);
          final episode = feed.episodes.first;
          expect(episode.description, isNotEmpty);
          expect(episode.durationMs, greaterThan(0));
          expect(episode.publishedMs, greaterThan(0));
          for (final url in {feed.channel.imageUrl, episode.imageUrl}) {
            if (url.isEmpty) continue;
            final image = await defaultArtworkFetcher(
              ArtworkFetchRequest(
                uri: Uri.parse(url),
                headers: const {},
                maxBytes: 12 * 1024 * 1024,
                connectTimeout: const Duration(seconds: 15),
                headerTimeout: const Duration(seconds: 25),
                totalBudget: const Duration(seconds: 45),
                cancelled: () => false,
                scope: NetworkSites.forPodcast(Uri.parse(url)),
              ),
            );
            expect(image.status, 200);
            expect(inspectArtworkBytes(image.bytes).width, greaterThan(0));
          }
          final store = PodcastStore(sqlite3.openInMemory());
          final mediaStore = PodcastMediaStore(
            root: Directory(
              '${directory.path}/${mode?.name ?? 'auto'}-$appleId',
            ),
            store: store,
            http: client.http,
          );
          final controller = PodcastController(
            store: store,
            client: client,
            mediaStore: mediaStore,
          );
          final player = HttpClient()..findProxy = (_) => 'DIRECT';
          try {
            // Discover preview uses this gateway before the channel is saved.
            final uri = await mediaStore.playbackUri(
              episode,
              episode.media.first,
            );
            expect(store.channel(feed.channel.id), isNull);
            for (final start in [0, 1024 * 1024]) {
              if (start > 0) {
                await controller.subscribe(feed);
                expect(store.channel(feed.channel.id)?.active, isTrue);
              }
              final request = await player.getUrl(uri);
              request.headers.set('range', 'bytes=$start-${start + 32767}');
              final response = await request.close();
              expect(response.statusCode, 206);
              expect(
                response.headers.value('content-range'),
                startsWith('bytes $start-${start + 32767}/'),
              );
              final bytes = await response.fold<int>(
                0,
                (count, chunk) => count + chunk.length,
              );
              expect(bytes, 32768);
            }
            if (native && Platform.isWindows) {
              final result = await _decodeAndSeek(mediaStore, episode.id, uri);
              expect(result['position'] as num, greaterThanOrEqualTo(31));
              // ignore: avoid_print
              print(
                'PODCAST_DOMESTIC_NATIVE $query ${mode?.name ?? 'automatic'}: $result',
              );
            }
            // ignore: avoid_print
            print(
              'PODCAST_DOMESTIC_LIVE $query ${mode?.name ?? 'automatic'}: '
              '${feed.episodes.length} episodes; covers OK; preview and subscribed ranges OK',
            );
          } finally {
            player.close(force: true);
            await controller.close();
            store.close();
          }
        },
        skip: !enabled,
        timeout: const Timeout(Duration(minutes: 2)),
      );
    }
  }
}

Future<Map<String, dynamic>> _decodeAndSeek(
  PodcastMediaStore mediaStore,
  String episodeId,
  Uri uri,
) async {
  final player = await Process.start('python', [
    'test/support/podcast_native_seek_probe.py',
    File('build/windows/x64/runner/Debug/libmpv-2.dll').absolute.path,
    uri.toString(),
    '30',
    jsonEncode({
      ...PodcastPlaybackPolicy.nativeOptions(audioOnly: true),
      if (const String.fromEnvironment('PODCAST_NATIVE_LOG').isNotEmpty)
        'log-file': const String.fromEnvironment('PODCAST_NATIVE_LOG'),
      if (const String.fromEnvironment('PODCAST_NATIVE_LOG').isNotEmpty)
        'msg-level': 'all=debug',
    }),
  ]);
  final output = Completer<Map<String, dynamic>>();
  final errors = player.stderr.transform(utf8.decoder).join();
  final messages = player.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (!line.startsWith('{')) return;
        final event = jsonDecode(line) as Map<String, dynamic>;
        if (event['event'] == 'seek-start') {
          mediaStore.prepareForSeek(episodeId);
          player.stdin.writeln('go');
        }
        if (event['event'] == 'result' && !output.isCompleted) {
          output.complete(event);
        }
      });
  try {
    final exit = await player.exitCode.timeout(const Duration(seconds: 90));
    expect(exit, 0, reason: await errors);
    return await output.future.timeout(const Duration(seconds: 1));
  } finally {
    player.kill();
    await messages.cancel();
  }
}
