import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_policy.dart';
import 'package:video_player_app/platform/native_audio_pause_repair.dart';
import 'package:video_player_app/platform/pitch_preserving_audio_pipeline.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

void main() {
  final enabled = Platform.environment['RUN_NATIVE_MEDIA_KIT_TESTS'] == '1';
  final fixtures = Platform.environment['NATIVE_PAUSE_FIXTURES'];
  final profiles = [
    'audio',
    'unseekable',
    if (fixtures != null) ...['progressive', 'hls', 'split'],
  ];

  for (final profile in profiles) {
    test(
      'real $profile audio preserves pause position and stops its device',
      () async {
        MediaKit.ensureInitialized();
        final directory = await Directory.systemTemp.createTemp(
          'pause_repair_',
        );
        final audio = File('${directory.path}/audio.wav');
        await audio.writeAsBytes(_silenceWav());
        final resources = <String, File>{
          '/audio.wav': audio,
          if (fixtures != null)
            for (final file in Directory(fixtures).listSync().whereType<File>())
              '/${file.uri.pathSegments.last}': file,
        };
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        final requestsByPath = <String, int>{};
        server.listen((request) async {
          try {
            final file = resources[request.uri.path];
            if (file == null) {
              request.response.statusCode = 404;
              return;
            }
            requests++;
            requestsByPath.update(
              request.uri.path,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
            final length = await file.length();
            final range = profile == 'unseekable'
                ? null
                : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(
                    request.headers.value(HttpHeaders.rangeHeader) ?? '',
                  );
            final start = range == null ? 0 : int.parse(range[1]!);
            if (start >= length) {
              request.response.statusCode = 416;
              return;
            }
            final end = range == null || range[2]!.isEmpty
                ? length - 1
                : int.parse(range[2]!).clamp(start, length - 1);
            if (profile != 'unseekable') {
              request.response.headers.set('accept-ranges', 'bytes');
            }
            if (range != null) {
              request.response.statusCode = 206;
              request.response.headers.set(
                'content-range',
                'bytes $start-$end/$length',
              );
            }
            request.response.contentLength = end - start + 1;
            await request.response.addStream(file.openRead(start, end + 1));
          } on IOException {
            // Native seek/disposal can close the old request.
          } finally {
            try {
              await request.response.close();
            } on IOException {
              // The player may already have disconnected.
            }
          }
        });
        final player = Player(
          configuration: const PlayerConfiguration(
            vo: 'null',
            osc: false,
            libass: false,
            pitch: false,
            muted: true,
          ),
        );
        final native = player.platform! as NativePlayer;
        final repair = NativeAudioPauseRepair.forPlayer(
          player,
          isCurrent: () => true,
        );
        Future<double> rawPosition() async => double.parse(
          await native.getProperty('time-pos', waitForInitialization: false),
        );
        Future<double> position() async {
          final paused = repair.pausedPosition;
          return paused == null
              ? await rawPosition()
              : paused.inMicroseconds / 1000000;
        }

        Future<void> deviceState({required bool active}) async {
          if (!Platform.isWindows) return;
          final probe = await Process.run('python', [
            'test/support/windows_audio_session_probe.py',
            '$pid',
          ]);
          expect(probe.exitCode, 0, reason: probe.stderr.toString());
          final states = jsonDecode(probe.stdout.toString()) as List;
          expect(states, isNotEmpty);
          final diagnostic = <String, String>{};
          if (states.contains('active') != active) {
            for (final key in [
              'pause',
              'paused-for-cache',
              'core-idle',
              'seeking',
              'time-pos',
              'audio-pts',
              'current-ao',
              'eof-reached',
              'track-list',
            ]) {
              diagnostic[key] = await native.getProperty(key);
            }
          }
          expect(states.contains('active'), active, reason: '$diagnostic');
        }

        final samples = <Map<String, Object>>[];
        try {
          await PitchPreservingAudioPipeline.configure(player);
          if (Platform.isWindows) await native.setProperty('ao', 'wasapi');
          final options = profile == 'audio' || profile == 'unseekable'
              ? PodcastPlaybackPolicy.nativeOptions(audioOnly: true)
              : profile == 'split'
              ? <String, String>{
                  'cache': 'yes',
                  'cache-pause': 'yes',
                  'cache-pause-initial': 'no',
                  'cache-pause-wait': '0.15',
                  'cache-secs': '16',
                  'demuxer-readahead-secs': '12',
                  'demuxer-max-bytes': '${32 * 1024 * 1024}',
                  'demuxer-max-back-bytes': '${12 * 1024 * 1024}',
                  'force-seekable': 'yes',
                }
              : NativeVideoPlayerMediaKit.cloudDriveNativeOptions(
                  hls: profile == 'hls',
                  fastStart: true,
                );
          for (final option in options.entries) {
            await native.setProperty(option.key, option.value);
          }
          final path = switch (profile) {
            'progressive' => 'sample.mp4',
            'hls' => 'sample.m3u8',
            'split' => 'video.mp4',
            _ => 'audio.wav',
          };
          if (profile != 'audio') await native.setProperty('vid', 'auto');
          final uri = 'http://127.0.0.1:${server.port}/$path';
          await player.open(
            Media(
              profile == 'split'
                  ? NativeVideoPlayerMediaKit.dualTrackEdl(
                      uri,
                      'http://127.0.0.1:${server.port}/audio.m4a',
                    )
                  : uri,
            ),
            play: false,
          );
          final filter = await native.getProperty('af');
          for (final rate in [1.0, 2.0]) {
            await player.setRate(rate);
            await repair.play();
            await Future<void>.delayed(const Duration(milliseconds: 700));
            if (profile == 'unseekable') {
              expect(await native.getProperty('seekable'), 'no');
            }
            await deviceState(active: true);
            await repair.pause();
            await Future<void>.delayed(const Duration(milliseconds: 180));
            final start = await position();
            var playingMicroseconds = 0;
            final initialRequests = Map<String, int>.from(requestsByPath);
            for (var cycle = 0; cycle < 16; cycle++) {
              final boundary = await position();
              final clock = Stopwatch()..start();
              await repair.play();
              await Future<void>.delayed(const Duration(milliseconds: 25));
              // Read the real native clock after resume, independently of the
              // held pause position. Recovery must actually restore the media.
              expect(
                await rawPosition(),
                inInclusiveRange(
                  boundary - .060,
                  boundary + clock.elapsedMicroseconds / 1000000 * rate + .080,
                ),
                reason:
                    '$profile $rate $cycle resumed after its audible boundary',
              );
              await Future<void>.delayed(
                Duration(milliseconds: cycle.isEven ? 35 : 125),
              );
              await repair.pause();
              playingMicroseconds += clock.elapsedMicroseconds;
              await Future<void>.delayed(const Duration(milliseconds: 160));
              final actual = await position();
              expect(
                actual,
                greaterThanOrEqualTo(boundary - .005),
                reason: '$profile $rate $cycle repeated already-heard media',
              );
              final mark = repair.lastPausePosition;
              expect(mark, isNotNull);
              expect(
                (actual - mark!.inMicroseconds / 1000000).abs(),
                lessThan(.060),
              );
              final extra =
                  (actual - start) * 1000 - playingMicroseconds / 1000 * rate;
              expect(extra, lessThan(100), reason: '$profile $rate $cycle');
              samples.add({'rate': rate, 'cycle': cycle, 'extraMs': extra});
            }
            // The fixture is entirely inside the native rewind window. Recovery
            // must reuse packets rather than reopening the upstream per pause.
            for (final entry in initialRequests.entries) {
              expect(
                requestsByPath[entry.key],
                entry.value,
                reason: '$profile re-fetched ${entry.key} during pause repair',
              );
            }
            final held = await position();
            await Future<void>.delayed(const Duration(milliseconds: 350));
            expect((await position() - held).abs(), lessThan(.005));
            await deviceState(active: false);

            await repair.play();
            await Future<void>.delayed(const Duration(milliseconds: 400));
            final running = await position();
            await Future<void>.delayed(const Duration(milliseconds: 500));
            expect(
              ((await position() - running) - .5 * rate).abs(),
              lessThan(.15),
            );
            await repair.pause();
          }
          expect(await native.getProperty('af'), filter);
          for (var i = 0; i < 6; i++) {
            await Future.wait([
              repair.play(),
              repair.pause(),
              repair.play(),
              repair.pause(),
            ]);
          }
          expect(await native.getProperty('pause'), 'yes');
          if (profile == 'unseekable') {
            // Finish sequentially: an uncached remote seek is not supported by
            // this transport and pause repair must not force it to become one.
            await player.setRate(8);
          } else {
            await repair.seek(() => player.seek(const Duration(seconds: 20)));
            await player.setRate(1);
            await repair.play();
            await Future<void>.delayed(const Duration(milliseconds: 600));
            await repair.pause();
            await Future<void>.delayed(const Duration(milliseconds: 200));
            expect(await position(), inInclusiveRange(20, 21.2));
            await repair.seek(() => player.seek(const Duration(seconds: 44)));
          }
          await repair.play();
          final end = Stopwatch()..start();
          while (!player.state.completed && end.elapsedMilliseconds < 10000) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          expect(player.state.completed, isTrue);
          await repair.pause();
          expect(await native.getProperty('eof-reached'), 'yes');
          await deviceState(active: false);
          // ignore: avoid_print
          print(
            'NATIVE_PAUSE_REPAIR ${jsonEncode({'profile': profile, 'platform': Platform.operatingSystem, 'requests': requests, 'completed': true, 'samples': samples})}',
          );
        } finally {
          await repair.dispose();
          await player.dispose();
          await server.close(force: true);
          await directory.delete(recursive: true);
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

Uint8List _silenceWav() {
  const rate = 48000;
  const length = rate * 2 * 45;
  final bytes = ByteData(44 + length);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    for (var i = 0; i < entry.value.length; i++) {
      bytes.setUint8(entry.key + i, entry.value.codeUnitAt(i));
    }
  }
  bytes
    ..setUint32(4, 36 + length, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(40, length, Endian.little);
  return bytes.buffer.asUint8List();
}
