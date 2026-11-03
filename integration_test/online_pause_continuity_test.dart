import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/podcasts/podcast_playback_policy.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

// Uses only an in-process HTTP fixture: no account, CDN, library or downloads.
// Run on a native target. Android runs must use an isolated test application ID
// so installing the integration runner does not replace the user's application.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final profiles = <String, Map<String, String>>{
    'podcast': {PodcastPlaybackPolicy.streamHeader: 'audio'},
    'cloud': NativeVideoPlayerMediaKit.cloudDrivePlayerHeaders(hls: false),
    'bilibili audio': {NativeVideoPlayerMediaKit.audioPrimaryStreamHeader: '1'},
  };

  for (final profile in profiles.entries) {
    testWidgets('${profile.key} pause never accumulates skipped audio', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      NativeVideoPlayerMediaKit.ensureInitialized();
      final audio = _silenceWav();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          final range = RegExp(
            r'^bytes=(\d+)-(\d*)$',
          ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
          final start = range == null ? 0 : int.parse(range[1]!);
          if (start >= audio.length) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            return;
          }
          final end = range == null || range[2]!.isEmpty
              ? audio.length - 1
              : int.parse(range[2]!).clamp(start, audio.length - 1);
          request.response.headers
            ..contentType = ContentType('audio', 'wav')
            ..set(HttpHeaders.acceptRangesHeader, 'bytes');
          if (range != null) {
            request.response.statusCode = HttpStatus.partialContent;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${audio.length}',
            );
          }
          request.response.contentLength = end - start + 1;
          request.response.add(Uint8List.sublistView(audio, start, end + 1));
        } on IOException {
          // A native seek/dispose may cancel the old Range connection.
        } finally {
          try {
            await request.response.close();
          } on IOException {
            // The native client may have already closed it.
          }
        }
      });
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('http://127.0.0.1:${server.port}/audio.wav'),
        httpHeaders: profile.value,
      );
      final samples = <Map<String, Object>>[];
      try {
        await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
        // media_kit initializes on a post-frame callback even for audio-only
        // media. Request frames while waiting on that creation barrier.
        final frames = Timer.periodic(const Duration(milliseconds: 16), (_) {
          WidgetsBinding.instance.scheduleFrame();
        });
        try {
          await controller.initialize().timeout(const Duration(seconds: 15));
        } finally {
          frames.cancel();
        }
        await controller.setVolume(0);
        // ignore: invalid_use_of_visible_for_testing_member
        final playerId = controller.playerId;
        Future<Duration> nativePosition() async =>
            (await NativeVideoPlayerMediaKit.transportPositionFor(playerId))!;

        for (final rate in [1.0, 2.0]) {
          await controller.setPlaybackSpeed(rate);
          await controller.play();
          await Future<void>.delayed(const Duration(milliseconds: 600));
          await controller.pause();
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final initial = await nativePosition();
          var playingMicroseconds = 0;
          for (var cycle = 0; cycle < 16; cycle++) {
            final clock = Stopwatch()..start();
            await controller.play();
            await Future<void>.delayed(
              Duration(milliseconds: cycle.isEven ? 60 : 150),
            );
            await controller.pause();
            playingMicroseconds += clock.elapsedMicroseconds;
            await Future<void>.delayed(const Duration(milliseconds: 160));
            final stopped = await nativePosition();
            final advanceMs = (stopped - initial).inMicroseconds / 1000;
            final expectedMs = playingMicroseconds / 1000 * rate;
            samples.add({
              'rate': rate,
              'cycle': cycle,
              'advanceMs': advanceMs,
              'playingMs': playingMicroseconds / 1000,
              'driftMs': advanceMs - expectedMs,
            });
            // Resuming an inactive device can spend some wall time warming
            // its output. That time must not be counted as unheard media.
            // Bound cumulative forward jumps, rather than requiring audio to
            // advance during device warmup. Steady playback rate is checked
            // independently below.
            expect(
              advanceMs - expectedMs,
              lessThan(150),
              reason: '${profile.key}: $samples',
            );
          }
          // Allow the final native position notification to settle before
          // checking that the audible pause boundary stays stationary.
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final stopped = await nativePosition();
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(
            ((await nativePosition()) - stopped).inMilliseconds.abs(),
            lessThanOrEqualTo(5),
          );
          expect(controller.value.isPlaying, isFalse);
          // ignore: invalid_use_of_visible_for_testing_member
          expect(controller.playerId, playerId);

          await controller.play();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final running = await nativePosition();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final advanced = await nativePosition();
          expect(
            ((advanced - running).inMilliseconds - 500 * rate).abs(),
            lessThan(150),
          );
          await controller.pause();
        }

        // A pending pause boundary must not override an intentional user seek.
        await controller.seekTo(const Duration(seconds: 20));
        await controller.setPlaybackSpeed(1);
        await controller.play();
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await controller.pause();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final afterSeek = await nativePosition();
        expect(afterSeek.inMilliseconds, inInclusiveRange(20000, 21200));
        expect(controller.value.hasError, isFalse);

        // Pause recovery must preserve natural EOF and queue advancement.
        await controller.seekTo(const Duration(seconds: 44));
        await controller.play();
        final completionWait = Stopwatch()..start();
        while (!controller.value.isCompleted &&
            completionWait.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        expect(controller.value.isCompleted, isTrue);
        expect(controller.value.isPlaying, isFalse);

        // ignore: avoid_print
        print(
          'ONLINE_PAUSE_CONTINUITY ${jsonEncode({'profile': profile.key, 'operatingSystem': Platform.operatingSystem, 'samples': samples, 'afterSeekMs': afterSeek.inMilliseconds, 'completed': controller.value.isCompleted})}',
        );
      } finally {
        await controller.dispose();
        await server.close(force: true);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }
}

Uint8List _silenceWav() {
  const sampleRate = 48000;
  const dataLength = sampleRate * 2 * 45;
  final data = ByteData(44 + dataLength);
  for (final entry in {0: 'RIFF', 8: 'WAVE', 12: 'fmt ', 36: 'data'}.entries) {
    for (var index = 0; index < entry.value.length; index++) {
      data.setUint8(entry.key + index, entry.value.codeUnitAt(index));
    }
  }
  data
    ..setUint32(4, 36 + dataLength, Endian.little)
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(40, dataLength, Endian.little);
  return data.buffer.asUint8List();
}
