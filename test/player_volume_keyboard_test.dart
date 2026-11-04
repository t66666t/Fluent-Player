import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/player_volume_keyboard.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerVolumeKeyboard', () {
    test('short presses snap to YouTube/VLC 5% notches', () {
      expect(
        PlayerVolumeKeyboard.applyShortPress(1.0, -1),
        closeTo(0.95, 1e-9),
      );
      expect(
        PlayerVolumeKeyboard.applyShortPress(0.95, -1),
        closeTo(0.90, 1e-9),
      );
      expect(
        PlayerVolumeKeyboard.applyShortPress(0.53, 1),
        closeTo(0.55, 1e-9),
      );
      expect(
        PlayerVolumeKeyboard.applyShortPress(0.53, -1),
        closeTo(0.50, 1e-9),
      );
      expect(PlayerVolumeKeyboard.applyShortPress(0.02, -1), 0.0);
      expect(PlayerVolumeKeyboard.applyShortPress(0.98, 1), 1.0);
    });

    test('hold ticks stay on a 2% grid so a burst cannot jump 0-100', () {
      expect(PlayerVolumeKeyboard.applyHoldTick(0.95, -1), closeTo(0.93, 1e-9));
      double volume = 1.0;
      for (int i = 0; i < 5; i++) {
        volume = PlayerVolumeKeyboard.applyHoldTick(volume, -1);
      }
      expect(volume, closeTo(0.90, 1e-9));
    });
  });

  group('video overlay arrow volume', () {
    late MediaPlaybackService playback;

    setUp(() async {
      playback = MediaPlaybackService();
      await playback.setVolume(1.0);
      if (playback.isMuted) {
        await playback.toggleMute();
      }
    });

    tearDown(() async {
      await playback.setVolume(1.0);
    });

    Future<VideoControlsOverlayState> pumpOverlay(WidgetTester tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService()..resetForTest(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: playback),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: VideoControlsOverlay(
                controller: null,
                isLocked: false,
                allowPlayWhenUninitialized: true,
                onTogglePlay: () {},
                onBackPressed: () {},
                onToggleLock: () {},
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
        ),
      );
      return tester.state<VideoControlsOverlayState>(
        find.byType(VideoControlsOverlay),
      );
    }

    Future<void> settleOverlay(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
    }

    testWidgets('short taps step 5% and show the swipe volume HUD', (
      tester,
    ) async {
      final state = await pumpOverlay(tester);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      void tapDown() {
        state.handleKeyEvent(
          focusNode,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.arrowDown,
            logicalKey: LogicalKeyboardKey.arrowDown,
            timeStamp: Duration.zero,
          ),
        );
        state.handleKeyEvent(
          focusNode,
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.arrowDown,
            logicalKey: LogicalKeyboardKey.arrowDown,
            timeStamp: Duration(milliseconds: 40),
          ),
        );
      }

      tapDown();
      await tester.pump();
      expect(playback.volume, closeTo(0.95, 1e-9));
      expect(find.text('95%'), findsOneWidget);

      tapDown();
      tapDown();
      await tester.pump();
      expect(playback.volume, closeTo(0.85, 1e-9));
      expect(find.text('85%'), findsOneWidget);
      await settleOverlay(tester);
    });

    testWidgets('OS key repeats do not stack extra 5% steps before hold', (
      tester,
    ) async {
      final state = await pumpOverlay(tester);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration.zero,
        ),
      );
      state.handleKeyEvent(
        focusNode,
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration(milliseconds: 40),
        ),
      );
      state.handleKeyEvent(
        focusNode,
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration(milliseconds: 80),
        ),
      );
      await tester.pump();
      expect(playback.volume, closeTo(0.95, 1e-9));

      await tester.pump(PlayerVolumeKeyboard.holdStartDelay);
      await tester.pump();
      expect(playback.volume, closeTo(0.93, 1e-9));

      await tester.pump(PlayerVolumeKeyboard.holdTickInterval);
      await tester.pump();
      expect(playback.volume, closeTo(0.91, 1e-9));

      state.handleKeyEvent(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration(milliseconds: 800),
        ),
      );
      await tester.pump(PlayerVolumeKeyboard.holdTickInterval * 3);
      expect(playback.volume, closeTo(0.91, 1e-9));
      await settleOverlay(tester);
    });

    testWidgets('inactive and background cancel a volume hold without key-up', (
      tester,
    ) async {
      final state = await pumpOverlay(tester);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      var presses = 0;
      void pressDown() => state.handleKeyEvent(
        focusNode,
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration(seconds: presses++),
        ),
      );

      pressDown();
      await tester.pump();
      await tester.pump(PlayerVolumeKeyboard.holdStartDelay);
      await tester.pump();
      expect(playback.volume, closeTo(0.93, 1e-9));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 3));
      expect(playback.volume, closeTo(0.93, 1e-9));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 3));
      expect(playback.volume, closeTo(0.93, 1e-9));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 3));
      expect(playback.volume, closeTo(0.93, 1e-9));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(playback.volume, closeTo(0.93, 1e-9));

      // A new press works immediately; no stale held-key deduplication remains.
      pressDown();
      await tester.pump();
      expect(playback.volume, closeTo(0.90, 1e-9));
      state.handleKeyEvent(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.arrowDown,
          logicalKey: LogicalKeyboardKey.arrowDown,
          timeStamp: Duration(milliseconds: 40),
        ),
      );
      await settleOverlay(tester);
    });
  });
}
