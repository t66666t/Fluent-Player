import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  final settings = SettingsService();
  final playback = MediaPlaybackService();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    await settings.init();
    playback.debugOverrideStreamQualityChrome();
  });

  for (final withQuality in [false, true]) {
    testWidgets('preparing chrome stays hidden under a parked mouse; '
        'quality=$withQuality', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
      addTearDown(controller.dispose);
      var preparing = true;
      var plays = 0;
      var tools = 0;
      final item = VideoItem(
        id: 'preparing-item',
        path: 'bilibili://stream/BV1xx411c7mD?cid=1',
        title: 'Video',
        durationMs: 120000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          value: 'BV1xx411c7mD',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1xx411c7mD',
          cid: 1,
        ),
      );
      Widget host() => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(value: settings),
          ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: VideoControlsOverlay(
              controller: preparing ? null : controller,
              isPreparing: preparing,
              mediaItemId: item.id,
              mediaTitle: item.title,
              initialDuration: const Duration(minutes: 2),
              initialPosition: const Duration(seconds: 30),
              reserveQualityControl: withQuality,
              initialShowControls: false,
              enableSeekThumbnailPreview: false,
              isLocked: false,
              onBackPressed: () {},
              onToggleFullScreen: () {},
              onToggleLock: () {},
              onTogglePlay: () => plays++,
              onOpenSettings: () => tools++,
              onSpeedUpdate: (_) async {},
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
            ),
          ),
        ),
      );

      await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(100, 100));
      addTearDown(mouse.removePointer);
      await tester.pumpWidget(host());
      await tester.pump(const Duration(seconds: 5));
      final overlay = find.byType(VideoControlsOverlay);
      final state = tester.state<VideoControlsOverlayState>(overlay);
      expect(state.controlsVisible, isFalse);
      final top = find.byKey(const ValueKey('video-controls-top-settings'));
      final progress = find.byKey(
        const ValueKey('video-controls-progress-area'),
      );
      final bottom = find.byKey(const ValueKey('video-controls-bottom-panel'));
      final before = [
        tester.getRect(top),
        tester.getRect(progress),
        tester.getRect(bottom),
      ];
      expect(tester.widget<IconButton>(top).onPressed, isNull);
      expect(find.text('正在打开…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('00:30 / 02:00'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(plays, 0);
      expect(tools, 0);

      // Qualities and native readiness arrive together after a slow resolve.
      if (withQuality) {
        playback.debugOverrideStreamQualityChrome(
          item: item,
          qualities: const [BilibiliStreamQuality(id: 80, label: '1080P')],
        );
      }
      controller.value = VideoPlayerValue(
        duration: const Duration(minutes: 2),
        position: const Duration(seconds: 30),
        size: const Size(1920, 1080),
        isInitialized: true,
      );
      preparing = false;
      await tester.pumpWidget(host());
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('正在打开…'), findsNothing);
      expect(tester.state<VideoControlsOverlayState>(overlay), same(state));
      expect(state.controlsVisible, isFalse);
      expect(top.hitTestable(), findsNothing);
      expect([
        tester.getRect(top),
        tester.getRect(progress),
        tester.getRect(bottom),
      ], before);
      await mouse.moveTo(const Offset(120, 100));
      await tester.pump(const Duration(milliseconds: 250));
      expect(state.controlsVisible, isTrue);
      expect(top.hitTestable(), findsOneWidget);
      await tester.tap(top);
      expect(tools, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
      expect(tester.takeException(), isNull);
    });
  }
}
