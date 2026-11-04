import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/progress_tracker.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

class _LiveApi extends BilibiliApiService {
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

// Opt in explicitly. Reads the app's existing Bilibili session; never writes
// cookies, library cards, the real resume snapshot or signed media URLs.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  const enabled = bool.fromEnvironment('BILIBILI_AUDIO_LIVE');
  testWidgets(
    'authenticated best-audio default and manual choices play through the native player',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      if (Platform.isWindows) {
        PathProviderWindows.registerWith();
        FlutterSecureStorageWindows.registerWith();
      }
      NativeVideoPlayerMediaKit.ensureInitialized();
      final root = await Directory.systemTemp.createTemp(
        'bilibili-audio-live-',
      );
      final output = Directory(
        Platform.environment['BILIBILI_AUDIO_REPORT'] ?? '${root.path}/report',
      );
      await output.create(recursive: true);
      final api = _LiveApi();
      await api.init();
      expect(
        await api.hasCookie(),
        isTrue,
        reason: 'Existing app login is required',
      );
      final streaming = BilibiliStreamingService(
        api,
        cacheDirectory: Directory('${root.path}/cache'),
      );
      final service = MediaPlaybackService.forTesting();
      final settings = SettingsService();
      final owner = Object();
      final boundaryKey = GlobalKey();
      final reports = <Map<String, Object?>>[];

      Future<T> pumping<T>(Future<T> work) async {
        var done = false;
        final observed = work.whenComplete(() => done = true);
        final watch = Stopwatch()..start();
        while (!done && watch.elapsed < const Duration(seconds: 70)) {
          await tester.pump(const Duration(milliseconds: 16));
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
        return observed;
      }

      Future<void> capture(String name) async {
        await tester.pump();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final frame = await boundary.toImage(pixelRatio: 1);
        try {
          final data = await frame.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${output.path}/$name.png',
          ).writeAsBytes(data!.buffer.asUint8List());
        } finally {
          frame.dispose();
        }
      }

      try {
        await service.initialize(
          playlistManager: PlaylistManager(),
          progressTracker: ProgressTracker(
            playbackStateStore: PlaybackStateStore(
              directoryProvider: () async => root,
            ),
          ),
          bilibiliStreamingService: streaming,
        );
        service.setPlaybackPageVisible(owner, true);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(value: settings),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: service,
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: RepaintBoundary(
                  key: boundaryKey,
                  child: ListenableBuilder(
                    listenable: service,
                    builder: (context, _) {
                      final controller = service.controller;
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          const ColoredBox(color: Colors.black),
                          if (controller != null &&
                              service.hasMountableController)
                            VideoPlayer(controller),
                          VideoControlsOverlay(
                            key: ValueKey(
                              'audio-chrome-${service.currentItem?.id}-${service.selectedStreamAudioQuality?.id}',
                            ),
                            controller: controller,
                            mediaItemId: service.currentItem?.id,
                            isLocked: false,
                            onTogglePlay: () {
                              unawaited(
                                service.isPlaying
                                    ? service.pause()
                                    : service.resume(),
                              );
                            },
                            onBackPressed: () {},
                            onToggleLock: () {},
                            onSpeedUpdate: service.setPlaybackSpeed,
                            showSubtitles: false,
                            onToggleSubtitles: () {},
                            onMoveSubtitles: () {},
                            isLongPressing: false,
                            longPressFeedbackText: '',
                            onLongPressStart: () => false,
                            onLongPressEnd: () {},
                            subtitleEntries: const [],
                            subtitleStyle: const SubtitleStyle(),
                            subtitleAlignment: Alignment.bottomCenter,
                            onEnterSubtitleDragMode: () {},
                            initialShowControls: true,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );

        for (final (bvid, id, codec) in [
          ('BV1gHjGzyE5Z', 30251, 'flac'),
          ('BV1kX4y197P4', 30250, 'eac3'),
        ]) {
          final info = await api.fetchVideoInfo(bvid);
          final page = info.pages.first;
          final item = VideoItem(
            id: 'audio-live-$bvid',
            path: 'bilibili://stream/$bvid?cid=${page.cid}',
            title: info.title,
            durationMs: page.duration * 1000,
            lastUpdated: 0,
            isTransient: true,
            sourceRef: MediaSourceRef(
              kind: MediaSourceKind.bilibiliStream,
              value: bvid,
              bvid: bvid,
              cid: page.cid,
            ),
          );
          streaming.rememberQuality(item.id, 32);
          await pumping(
            service.play(
              item,
              autoPlay: false,
              startPosition: const Duration(seconds: 5),
            ),
          );
          expect(service.state, PlaybackState.paused);
          final initial = service.selectedStreamAudioQuality!;
          final initialNative = await NativeVideoPlayerMediaKit.audioStateFor(
            service.controller!.playerId,
          );
          final normal = service.streamAudioQualities.firstWhere(
            (quality) => !quality.isSpecial,
          );
          if (reports.isEmpty) {
            expect(initial.id, id);
            expect(initialNative?['audio-codec-name'], codec);
            await capture('$bvid-default-active');
            expect(
              await pumping(service.switchBilibiliAudioQuality(normal.id)),
              isTrue,
            );
          } else {
            expect(
              initial.id,
              normal.id,
              reason:
                  'The manual ordinary-audio choice applies to later videos',
            );
            expect(initialNative?['audio-codec-name'], 'aac');
          }
          expect(service.streamAudioQualities.map((q) => q.id), contains(id));
          await capture('$bvid-inactive');
          final quality = service.selectedStreamQuality!.id;
          expect(await pumping(service.switchBilibiliAudioQuality(id)), isTrue);
          expect(service.selectedStreamAudioQuality?.id, id);
          expect(service.selectedStreamQuality?.id, quality);
          expect(service.state, PlaybackState.paused);
          expect(service.position.inMilliseconds, closeTo(5000, 500));
          final native = await NativeVideoPlayerMediaKit.audioStateFor(
            service.controller!.playerId,
          );
          expect(native?['audio-codec-name'], codec);
          expect(
            int.tryParse(native?['audio-params/samplerate'] ?? ''),
            greaterThan(0),
          );
          await capture('$bvid-active');
          reports.add({
            'bvid': bvid,
            'initialAudio': initial.id,
            'initialCodec': initialNative?['audio-codec-name'],
            'selectedAudio': id,
            'label': service.selectedStreamAudioQuality!.label,
            'native': native,
            'positionMs': service.position.inMilliseconds,
            'paused': true,
          });

          // Exercise audible playback and return to baseline AAC on the same video.
          await pumping(service.resume());
          await Future<void>.delayed(const Duration(milliseconds: 700));
          await tester.pump();
          expect(
            await pumping(service.switchBilibiliAudioQuality(normal.id)),
            isTrue,
          );
          expect(service.state, PlaybackState.playing);
          expect(service.selectedStreamAudioQuality?.id, normal.id);
          await pumping(service.pause());
        }
        await File(
          '${output.path}/native-report.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
      } finally {
        await pumping(service.stop());
        service.setPlaybackPageVisible(owner, false);
        await tester.pumpWidget(const SizedBox.shrink());
        await streaming.shutdown();
        await root.delete(recursive: true);
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
