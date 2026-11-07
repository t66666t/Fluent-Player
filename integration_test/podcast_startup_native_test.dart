import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/debug/debug_log_buffer.dart';
import 'package:video_player_app/features/podcasts/podcast_client.dart';
import 'package:video_player_app/features/podcasts/podcast_media_store.dart';
import 'package:video_player_app/features/podcasts/podcast_models.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_hooks.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/podcast_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/media_playback_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PODCAST_STARTUP_NATIVE_TEST');
  const feedUrl = String.fromEnvironment('PODCAST_STARTUP_FEED');
  const title = String.fromEnvironment('PODCAST_STARTUP_TITLE');

  testWidgets(
    'cold podcast starts on the first play with the native backend',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      NativeVideoPlayerMediaKit.ensureInitialized();
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      final directory = await Directory.systemTemp.createTemp(
        'podcast-startup-',
      );
      final store = PodcastStore(sqlite3.openInMemory());
      var connections = 0;
      final http = feedUrl.isEmpty
          ? PodcastHttp(
              clientFactory: () => HttpClient()
                ..connectionFactory = (uri, _, _) async {
                  if (connections++ == 0) {
                    throw const SocketException('first connection unavailable');
                  }
                  return Socket.startConnect(uri.host, uri.port);
                },
            )
          : PodcastHttp();
      final mediaStore = PodcastMediaStore(
        root: directory,
        store: store,
        http: http,
      );
      final playback = MediaPlaybackService.forTesting();
      final previousResolve = PodcastPlaybackHooks.resolve;
      final owner = Object();
      HttpServer? server;
      try {
        final List<PodcastEpisode> episodes;
        if (feedUrl.isNotEmpty) {
          final feed = (await PodcastClient(http: http).resolve(feedUrl)).feed;
          episodes = [
            title.isEmpty
                ? feed.episodes[3]
                : feed.episodes.firstWhere((e) => e.title.contains(title)),
          ];
        } else {
          final audio = File('${directory.path}/cold.mp3');
          final encoded = await Process.run('ffmpeg', [
            '-hide_banner',
            '-loglevel',
            'error',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=220:sample_rate=44100:duration=120',
            '-c:a',
            'libmp3lame',
            '-b:a',
            '192k',
            audio.path,
          ]);
          expect(encoded.exitCode, 0, reason: '${encoded.stderr}');
          final bytes = await audio.readAsBytes();
          server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          server.listen((request) async {
            try {
              final range = RegExp(
                r'^bytes=(\d+)-(\d*)$',
              ).firstMatch(request.headers.value('range') ?? '');
              final start = int.tryParse(range?[1] ?? '') ?? 0;
              final end = min(
                bytes.length - 1,
                int.tryParse(range?[2] ?? '') ?? bytes.length - 1,
              );
              request.response.statusCode = range == null ? 200 : 206;
              request.response.headers.set('content-type', 'audio/mpeg');
              request.response.headers.set('etag', '"cold"');
              if (range != null) {
                request.response.headers.set(
                  'content-range',
                  'bytes $start-$end/${bytes.length}',
                );
              }
              request.response.contentLength = end - start + 1;
              request.response.add(bytes.sublist(start, end + 1));
              await request.response.close();
            } on IOException {
              // Decoder probes and seeks may close an earlier request.
            }
          });
          final url = 'http://127.0.0.1:${server.port}/cold.mp3';
          episodes = PodcastClient().parser
              .parse(
                utf8.encode(
                  '<rss version="2.0"><channel><title>Cold</title>'
                  '<item><guid>cold</guid><title>Cold</title>'
                  '<enclosure url="$url" type="audio/mpeg" '
                  'length="${bytes.length}"/></item></channel></rss>',
                ),
                'http://127.0.0.1:${server.port}/rss',
              )
              .episodes;
        }
        playback.setPlaybackPageVisible(owner, true);
        for (final episode in episodes) {
          final media = episode.media.first;
          PodcastPlaybackHooks.resolve = (_) =>
              mediaStore.playbackUri(episode, media);
          final item = VideoItem(
            id: episode.id,
            path: 'podcast:${episode.id}',
            title: episode.title,
            durationMs: episode.durationMs,
            lastUpdated: 0,
            type: MediaType.audio,
            sourceRef: MediaSourceRef(
              kind: MediaSourceKind.podcastEpisode,
              value: 'podcast:${episode.id}',
              podcast: PodcastEpisodeRef(
                channelId: episode.channelId,
                episodeId: episode.id,
                feedUrl: feedUrl.isEmpty ? 'http://localhost/rss' : feedUrl,
                mediaUrl: media.url,
              ),
            ),
          );
          final elapsed = Stopwatch()..start();
          await playback.play(item).timeout(const Duration(seconds: 35));
          final startup = playback.onlineStartup;
          debugPrint(
            'PODCAST_STARTUP ${jsonEncode({
              'title': episode.title,
              'state': playback.state.name,
              'elapsedMs': elapsed.elapsedMilliseconds,
              'cachedBytes': mediaStore.cachedBytes(episode.id, media.url),
              if (feedUrl.isEmpty) 'connections': connections,
              'sourceEvents': DebugLogBuffer.instance.entries.where((entry) => entry.text.contains('[PodcastMediaStore]')).map((entry) => entry.display).toList(),
              'phase': startup?.phase.name,
              'marks': startup?.marks.map((m) => {'step': m.step, 'ms': m.ms}).toList(),
            })}',
          );
          expect(playback.state, PlaybackState.playing);
          expect(startup?.isReady, isTrue);
          if (feedUrl.isEmpty) expect(connections, greaterThan(1));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(playback.position, greaterThan(Duration.zero));
          final controller = playback.controller;
          await playback.pause();
          expect(playback.state, PlaybackState.paused);
          await playback.resume();
          expect(playback.state, PlaybackState.playing);
          expect(playback.controller, same(controller));
          await playback.stop();
        }
      } finally {
        await playback.stop();
        playback.setPlaybackPageVisible(owner, false);
        playback.dispose();
        PodcastPlaybackHooks.resolve = previousResolve;
        await mediaStore.close();
        await server?.close(force: true);
        store.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
