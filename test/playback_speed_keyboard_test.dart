import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/android_hardware_input_bridge.dart';
import 'package:video_player_app/widgets/playback_speed_dialog.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('nextPlaybackSpeedPreset', () {
    test('steps along the speed-picker notches', () {
      expect(nextPlaybackSpeedPreset(1.0, direction: 1), 1.25);
      expect(nextPlaybackSpeedPreset(1.0, direction: -1), 0.75);
      expect(nextPlaybackSpeedPreset(1.1, direction: 1), 1.25);
      expect(nextPlaybackSpeedPreset(1.1, direction: -1), 1.0);
      expect(nextPlaybackSpeedPreset(0.25, direction: -1), isNull);
      expect(nextPlaybackSpeedPreset(5.0, direction: 1), isNull);
    });
  });

  group('overlay Shift+arrow speed notches', () {
    testWidgets('nudges session speed without writing the lock', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      await settings.setPlaybackSpeedLock(2.0, true);
      final speeds = <double>[];

      final state = await _pumpOverlay(
        tester,
        settings: settings,
        onSpeedUpdate: (speed) async => speeds.add(speed),
      );
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration.zero,
        ),
      );
      state.handleKeyEvent(
        focusNode,
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration(milliseconds: 40),
        ),
      );
      state.handleKeyEvent(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration(milliseconds: 80),
        ),
      );
      await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(speeds, <double>[1.25]);
      expect(settings.playbackSpeed, 2.0);
      expect(settings.isPlaybackSpeedLocked, isTrue);

      await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowLeft,
          logicalKey: LogicalKeyboardKey.arrowLeft,
          timeStamp: Duration(milliseconds: 200),
        ),
      );
      await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(speeds, <double>[1.25, 0.75]);
      expect(settings.playbackSpeed, 2.0);
      expect(settings.isPlaybackSpeedLocked, isTrue);

      await _settleOverlay(tester);
    });

    testWidgets('plain arrows do not change speed', (tester) async {
      final speeds = <double>[];
      final state = await _pumpOverlay(
        tester,
        onSpeedUpdate: (speed) async => speeds.add(speed),
      );
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration.zero,
        ),
      );
      state.handleKeyEvent(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration(milliseconds: 40),
        ),
      );

      expect(speeds, isEmpty);
      await _settleOverlay(tester);
    });

    testWidgets('a short space still toggles when the hold timer runs first', (
      tester,
    ) async {
      var toggles = 0;
      final state = await _pumpOverlay(
        tester,
        onSpeedUpdate: (_) async {},
        onTogglePlay: () => toggles++,
        onLongPressStart: () => true,
      );
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration.zero,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      state.handleKeyEvent(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration(milliseconds: 40),
        ),
      );

      expect(toggles, 1);
      await _settleOverlay(tester);
    });

    testWidgets('a real space hold boosts and does not toggle', (tester) async {
      var toggles = 0;
      final state = await _pumpOverlay(
        tester,
        onSpeedUpdate: (_) async {},
        onTogglePlay: () => toggles++,
        onLongPressStart: () => true,
      );
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration.zero,
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      state.handleKeyEvent(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration(milliseconds: 400),
        ),
      );

      expect(toggles, 0);
      await _settleOverlay(tester);
    });

    testWidgets(
      'background ends a speed hold once and ignores its late key-up',
      (tester) async {
        var starts = 0;
        var ends = 0;
        var toggles = 0;
        final state = await _pumpOverlay(
          tester,
          onSpeedUpdate: (_) async {},
          onTogglePlay: () => toggles++,
          onLongPressStart: () {
            starts++;
            return true;
          },
          onLongPressEnd: () => ends++,
        );
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        state.handleKeyEvent(
          focusNode,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration.zero,
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(starts, 1);
        expect(ends, 0);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        expect(ends, 1);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        expect(ends, 1);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(ends, 1);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        state.handleKeyEvent(
          focusNode,
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration(seconds: 2),
          ),
        );
        expect(toggles, 0);
        expect(ends, 1);

        state.handleKeyEvent(
          focusNode,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration(seconds: 3),
          ),
        );
        state.handleKeyEvent(
          focusNode,
          const KeyUpEvent(
            physicalKey: PhysicalKeyboardKey.space,
            logicalKey: LogicalKeyboardKey.space,
            timeStamp: Duration(milliseconds: 3040),
          ),
        );
        expect(toggles, 1);
        expect(starts, 1);
        await _settleOverlay(tester);
      },
    );

    testWidgets('inactive retains a short Space tap without starting a hold', (
      tester,
    ) async {
      var starts = 0;
      var toggles = 0;
      final state = await _pumpOverlay(
        tester,
        onSpeedUpdate: (_) async {},
        onTogglePlay: () => toggles++,
        onLongPressStart: () {
          starts++;
          return true;
        },
      );
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration.zero,
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump(const Duration(seconds: 1));
      expect(starts, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      state.handleKeyEvent(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration(milliseconds: 40),
        ),
      );
      expect(toggles, 1);
      await _settleOverlay(tester);
    });

    testWidgets('background before the hold threshold cancels pending boost', (
      tester,
    ) async {
      var starts = 0;
      var toggles = 0;
      final state = await _pumpOverlay(
        tester,
        onSpeedUpdate: (_) async {},
        onTogglePlay: () => toggles++,
        onLongPressStart: () {
          starts++;
          return true;
        },
      );
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration.zero,
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(starts, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      state.handleKeyEvent(
        focusNode,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration(seconds: 2),
        ),
      );
      expect(toggles, 0);
      await _settleOverlay(tester);
    });

    testWidgets('ignores Shift+arrows during hold-to-boost', (tester) async {
      final speeds = <double>[];
      final state = await _pumpOverlay(
        tester,
        isLongPressing: true,
        onSpeedUpdate: (speed) async => speeds.add(speed),
      );
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration.zero,
        ),
      );
      await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(speeds, isEmpty);
      await _settleOverlay(tester);
    });

    testWidgets('Android Activity shift flag steps speed without Ctrl/Alt', (
      tester,
    ) async {
      final speeds = <double>[];
      final state = await _pumpOverlay(
        tester,
        onSpeedUpdate: (speed) async => speeds.add(speed),
      );

      state.handleAndroidHardwareKeyEventForTest(
        AndroidHardwareInputBridge.decodeKeyForTesting(<Object?, Object?>{
          'keyCode': 22,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 1,
          'shift': true,
        })!,
      );

      expect(speeds, <double>[1.25]);
      await _settleOverlay(tester);
    });
  });
}

Future<VideoControlsOverlayState> _pumpOverlay(
  WidgetTester tester, {
  SettingsService? settings,
  required Future<void> Function(double speed) onSpeedUpdate,
  bool isLongPressing = false,
  VoidCallback? onTogglePlay,
  bool Function()? onLongPressStart,
  VoidCallback? onLongPressEnd,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(
          value: settings ?? (SettingsService()..resetForTest()),
        ),
        ChangeNotifierProvider<MediaPlaybackService>.value(
          value: MediaPlaybackService(),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: VideoControlsOverlay(
            controller: null,
            isLocked: false,
            allowPlayWhenUninitialized: true,
            onTogglePlay: onTogglePlay ?? () {},
            onBackPressed: () {},
            onToggleLock: () {},
            onSpeedUpdate: onSpeedUpdate,
            showSubtitles: false,
            onToggleSubtitles: () {},
            onMoveSubtitles: () {},
            isLongPressing: isLongPressing,
            longPressFeedbackText: '',
            onLongPressStart: onLongPressStart ?? () => false,
            onLongPressEnd: onLongPressEnd ?? () {},
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

Future<void> _settleOverlay(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 20));
}
