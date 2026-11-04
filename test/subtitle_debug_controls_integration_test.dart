import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/widgets/subtitle_settings_sheet.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';
import 'tooltip_finders.dart';

void main() {
  final session = SubtitleDebugSession.instance;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    session.resetForTest();
    await session.initialize();
  });
  tearDown(() async {
    session.resetForTest();
  });

  testWidgets(
    'real player speed button opens on tap and long-press toggles presets',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/test.mp4'),
      );
      controller.value = const VideoPlayerValue(
        duration: Duration(minutes: 1),
        isInitialized: true,
        size: Size(1280, 720),
      );
      addTearDown(controller.dispose);
      final playback = MediaPlaybackService();
      addTearDown(playback.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: VideoControlsOverlay(
                controller: controller,
                isLocked: false,
                onTogglePlay: () {},
                onBackPressed: () {},
                onToggleLock: () {},
                onSpeedUpdate: (_) async {},
                showSubtitles: false,
                onToggleSubtitles: () {},
                onMoveSubtitles: () {},
                isLongPressing: false,
                longPressFeedbackText: '',
                onLongPressStart: () => true,
                onLongPressEnd: () {},
                subtitleEntries: const [],
                subtitleStyle: const SubtitleStyle(),
                subtitleAlignment: Alignment.bottomCenter,
                onEnterSubtitleDragMode: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final speed = findTooltipLabeled('倍速');
      expect(speed, findsOneWidget);
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        await tester.longPress(speed, kind: kind);
        await tester.pump();
        expect(session.enabled, kind == PointerDeviceKind.touch);
      }
      await tester.tap(speed);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('playback-speed-popover')),
        findsOneWidget,
      );
      expect(controller.value.playbackSpeed, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 20));
    },
  );

  testWidgets('full style sheet protects original controls while previewing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: SubtitleSettingsSheet(
              style: const SubtitleStyle(),
              onClose: () {},
              hideGhostModeToggle: true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('主字号'), findsOneWidget);
    session.toggle();
    session.select(subtitleDebugPresets.first);
    await tester.pump();
    expect(find.text('主字号'), findsNothing);
    session.useOriginal();
    await tester.pump();
    expect(find.text('主字号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
