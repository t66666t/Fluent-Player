import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Future<void> playbackFrames(WidgetTester tester, int milliseconds) async {
    // Establish the VSync baseline immediately after an acknowledged resume.
    // One long pump delays the very first frame by the entire wait interval,
    // which is not how the continuously rendered player screen behaves.
    await tester.pump();
    for (var elapsed = 0; elapsed < milliseconds; elapsed += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets(
    'rapid native play/pause keeps the lyric clock aligned across repeated transitions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      NativeVideoPlayerMediaKit.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp(
        'native_transport_sync_',
      );
      // A silent PCM file exercises the real audio clock without audible output.
      final pcmLength = 48000 * 2 * 45;
      final bytes = Uint8List(44 + pcmLength);
      final header = ByteData.sublistView(bytes);
      for (final entry in {
        0: 'RIFF',
        8: 'WAVE',
        12: 'fmt ',
        36: 'data',
      }.entries) {
        bytes.setRange(
          entry.key,
          entry.key + entry.value.length,
          ascii.encode(entry.value),
        );
      }
      header.setUint32(4, 36 + pcmLength, Endian.little);
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, 48000, Endian.little);
      header.setUint32(28, 96000, Endian.little);
      header.setUint16(32, 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      header.setUint32(40, pcmLength, Endian.little);
      final file = File('${directory.path}/clock.wav');
      await file.writeAsBytes(bytes);
      final service = MediaPlaybackService();
      try {
        await service.initialize(
          playlistManager: PlaylistManager(),
          progressTracker: ProgressTracker(
            playbackStateStore: PlaybackStateStore(
              directoryProvider: () async => directory,
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: ValueListenableBuilder<Duration>(
                  valueListenable: service.positionNotifier,
                  builder: (context, position, _) =>
                      Text('Lyric clock: ${position.inMilliseconds} ms'),
                ),
              ),
            ),
          ),
        );
        await service.play(
          VideoItem(
            id: 'native-transport-check',
            path: file.path,
            title: 'Native transport check',
            type: MediaType.audio,
            durationMs: 45000,
            lastUpdated: 0,
          ),
          autoPlay: false,
          startPosition: const Duration(seconds: 10),
        );
        final samples = <Map<String, Object>>[];
        for (var cycle = 0; cycle < 12; cycle++) {
          await service.resume();
          await playbackFrames(tester, 120);
          final requests = <Future<void>>[service.pause()];
          await tester.pump(const Duration(milliseconds: 3));
          requests.add(service.resume());
          await tester.pump(const Duration(milliseconds: 3));
          requests.add(service.pause());
          final finishPlaying = cycle.isEven;
          if (finishPlaying) requests.add(service.resume());
          await Future.wait(requests);
          await playbackFrames(tester, 150);
          // ignore: invalid_use_of_visible_for_testing_member
          final native = (await NativeVideoPlayerMediaKit.transportPositionFor(
            service.controller!.playerId,
          ))!;
          final lyric = service.positionNotifier.value;
          final drift = (lyric - native).inMilliseconds.abs();
          samples.add({
            'cycle': cycle,
            'playing': finishPlaying,
            'nativeMs': native.inMilliseconds,
            'lyricMs': lyric.inMilliseconds,
            'driftMs': drift,
          });
          expect(service.isPlaying, finishPlaying);
          expect(service.controller!.value.isPlaying, finishPlaying);
          expect(
            drift,
            lessThanOrEqualTo(150),
            reason:
                'lyric time must stay within the native sampling tolerance; cycle $cycle: $samples',
          );
          if (!finishPlaying) {
            await tester.pump(const Duration(milliseconds: 200));
            expect(service.positionNotifier.value, lyric);
            // ignore: invalid_use_of_visible_for_testing_member
            final stopped =
                (await NativeVideoPlayerMediaKit.transportPositionFor(
                  service.controller!.playerId,
                ))!;
            expect(
              (stopped - native).inMilliseconds.abs(),
              lessThanOrEqualTo(5),
            );
          }
        }
        final reportPath = Platform.environment['PLAYBACK_SYNC_REPORT'];
        if (reportPath != null && reportPath.isNotEmpty) {
          final report = File(reportPath);
          await report.parent.create(recursive: true);
          await report.writeAsString(
            const JsonEncoder.withIndent('  ').convert({'cycles': samples}),
          );
        }
        await service.pause();
        await tester.pump();
      } finally {
        await service.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        // This is only the absolute directory created for this test above.
        await directory.delete(recursive: true);
      }
    },
  );
}
