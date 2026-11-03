import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/android_hardware_input_bridge.dart';
import 'package:video_player_app/utils/desktop_media_management_shortcuts.dart';
import 'package:video_player_app/utils/desktop_player_shortcuts.dart';
import 'package:video_player_app/utils/hardware_keyboard_shortcuts.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mobile physical keyboard policy', () {
    test('Android and iOS support attached keyboards and hover pointers', () {
      expect(
        supportsHardwareKeyboardShortcutsOn(TargetPlatform.android),
        isTrue,
      );
      expect(supportsHardwareKeyboardShortcutsOn(TargetPlatform.iOS), isTrue);
      expect(supportsPlayerPointerHoverOn(TargetPlatform.android), isTrue);
    });

    test(
      'Android restores player actions but leaves Back and window F alone',
      () {
        for (final action in DesktopPlayerShortcutAction.values) {
          final expected =
              action != DesktopPlayerShortcutAction.back &&
              action != DesktopPlayerShortcutAction.toggleFullScreen;
          expect(
            DesktopPlayerShortcuts.isAvailableOnPlatform(
              action,
              TargetPlatform.android,
            ),
            expected,
            reason: '$action has the wrong Android availability',
          );
        }
        expect(
          DesktopPlayerShortcuts.usesCoordinatedSeekOnPlatform(
            TargetPlatform.android,
          ),
          isTrue,
        );
      },
    );

    test('Android management shortcuts omit OS/window-only actions', () {
      expect(
        DesktopMediaManagementShortcuts.isAvailableOnPlatform(
          DesktopMediaManagementShortcutAction.toggleViewMode,
          TargetPlatform.android,
        ),
        isTrue,
      );
      expect(
        DesktopMediaManagementShortcuts.isAvailableOnPlatform(
          DesktopMediaManagementShortcutAction.backOrExitSelection,
          TargetPlatform.android,
        ),
        isFalse,
      );
      expect(
        DesktopMediaManagementShortcuts.isAvailableOnPlatform(
          DesktopMediaManagementShortcutAction.toggleFullScreen,
          TargetPlatform.android,
        ),
        isFalse,
      );
      expect(
        DesktopMediaManagementShortcuts.isAvailableOnPlatform(
          DesktopMediaManagementShortcutAction.openLargeDataDirectory,
          TargetPlatform.android,
        ),
        isFalse,
      );
    });
  });

  group('Android Activity key decoding', () {
    test('decodes Xiaomi/Android key codes, repeats and modifiers', () {
      final down = AndroidHardwareInputBridge.decodeKeyForTesting(
        <Object?, Object?>{
          'keyCode': 62,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 100,
        },
      );
      expect(down, isNotNull);
      expect(down!.logicalKey, LogicalKeyboardKey.space);
      expect(down.toKeyEvent(), isA<KeyDownEvent>());

      final repeat = AndroidHardwareInputBridge.decodeKeyForTesting(
        <Object?, Object?>{
          'keyCode': 22,
          'action': 0,
          'repeatCount': 3,
          'eventTime': 120,
          'ctrl': true,
        },
      );
      expect(repeat, isNotNull);
      expect(repeat!.logicalKey, LogicalKeyboardKey.arrowRight);
      expect(repeat.hasBlockingModifier, isTrue);
      expect(repeat.isShiftPressed, isFalse);
      expect(repeat.toKeyEvent(), isA<KeyRepeatEvent>());

      final shifted = AndroidHardwareInputBridge.decodeKeyForTesting(
        <Object?, Object?>{
          'keyCode': 21,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 130,
          'shift': true,
        },
      );
      expect(shifted, isNotNull);
      expect(shifted!.logicalKey, LogicalKeyboardKey.arrowLeft);
      expect(shifted.isShiftPressed, isTrue);
      expect(shifted.hasBlockingModifier, isFalse);

      final up = AndroidHardwareInputBridge.decodeKeyForTesting(
        <Object?, Object?>{
          'keyCode': 47,
          'action': 1,
          'repeatCount': 0,
          'eventTime': 140,
        },
      );
      expect(up, isNotNull);
      expect(up!.logicalKey, LogicalKeyboardKey.keyS);
      expect(up.toKeyEvent(), isA<KeyUpEvent>());
    });

    test('uses Unicode fallback and never forwards Back/Escape', () {
      final fallback = AndroidHardwareInputBridge.decodeKeyForTesting(
        <Object?, Object?>{
          'keyCode': 0,
          'unicodeChar': 86,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 1,
        },
      );
      expect(fallback?.logicalKey, LogicalKeyboardKey.keyV);
      expect(
        AndroidHardwareInputBridge.decodeKeyForTesting(<Object?, Object?>{
          'keyCode': 4,
          'action': 0,
        }),
        isNull,
      );
      expect(
        AndroidHardwareInputBridge.decodeKeyForTesting(<Object?, Object?>{
          'keyCode': 111,
          'action': 0,
        }),
        isNull,
      );
    });

    test('deduplicates native and Flutter copies but not physical repeats', () {
      final deduplicator = AndroidHardwareKeyDeduplicator();
      const flutterDown = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.space,
        logicalKey: LogicalKeyboardKey.space,
        timeStamp: Duration(milliseconds: 1000),
      );
      const nativeDown = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.space,
        logicalKey: LogicalKeyboardKey.space,
        timeStamp: Duration(milliseconds: 1002),
      );
      const nextPress = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.space,
        logicalKey: LogicalKeyboardKey.space,
        timeStamp: Duration(milliseconds: 1100),
      );

      expect(
        deduplicator.shouldDispatch(flutterDown, fromNativeBridge: false),
        isTrue,
      );
      expect(
        deduplicator.shouldDispatch(nativeDown, fromNativeBridge: true),
        isFalse,
      );
      expect(
        deduplicator.shouldDispatch(nextPress, fromNativeBridge: false),
        isTrue,
      );
    });

    test('deduplicates copies even when event clocks disagree', () {
      final deduplicator = AndroidHardwareKeyDeduplicator();
      const flutterDown = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyB,
        logicalKey: LogicalKeyboardKey.keyB,
        timeStamp: Duration(milliseconds: 8),
      );
      const nativeDown = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyB,
        logicalKey: LogicalKeyboardKey.keyB,
        timeStamp: Duration(milliseconds: 48000),
      );

      expect(
        deduplicator.shouldDispatch(flutterDown, fromNativeBridge: false),
        isTrue,
      );
      expect(
        deduplicator.shouldDispatch(nativeDown, fromNativeBridge: true),
        isFalse,
      );
    });

    test('decodes letter B and G used by player toggles', () {
      expect(
        AndroidHardwareInputBridge.decodeKeyForTesting(<Object?, Object?>{
          'keyCode': 30,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 1,
        })?.logicalKey,
        LogicalKeyboardKey.keyB,
      );
      expect(
        AndroidHardwareInputBridge.decodeKeyForTesting(<Object?, Object?>{
          'keyCode': 35,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 1,
        })?.logicalKey,
        LogicalKeyboardKey.keyG,
      );
    });
  });

  testWidgets('player distinguishes a tap, OS repeat and a held key', (
    tester,
  ) async {
    var playPauseCount = 0;
    var longPressStartCount = 0;
    var longPressEndCount = 0;

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService()..resetForTest(),
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
              onTogglePlay: () => playPauseCount++,
              onBackPressed: () {},
              onToggleLock: () {},
              onSpeedUpdate: (_) async {},
              showSubtitles: false,
              onToggleSubtitles: () {},
              onMoveSubtitles: () {},
              isLongPressing: false,
              longPressFeedbackText: '',
              onLongPressStart: () {
                longPressStartCount++;
                return true;
              },
              onLongPressEnd: () => longPressEndCount++,
              subtitleEntries: const [],
              subtitleStyle: const SubtitleStyle(),
              subtitleAlignment: Alignment.bottomCenter,
              onEnterSubtitleDragMode: () {},
            ),
          ),
        ),
      ),
    );

    final state = tester.state<VideoControlsOverlayState>(
      find.byType(VideoControlsOverlay),
    );
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);

    KeyEventResult dispatch(KeyEvent event) =>
        state.handleKeyEvent(focusNode, event);

    expect(
      dispatch(
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.space,
          logicalKey: LogicalKeyboardKey.space,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.handled,
    );
    dispatch(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.space,
        logicalKey: LogicalKeyboardKey.space,
        timeStamp: Duration(milliseconds: 50),
      ),
    );
    expect(playPauseCount, 1);
    expect(longPressStartCount, 0);

    dispatch(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowRight,
        logicalKey: LogicalKeyboardKey.arrowRight,
        timeStamp: Duration(seconds: 1),
      ),
    );
    expect(
      dispatch(
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowRight,
          logicalKey: LogicalKeyboardKey.arrowRight,
          timeStamp: Duration(milliseconds: 1050),
        ),
      ),
      KeyEventResult.handled,
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(longPressStartCount, 1);
    expect(playPauseCount, 1);

    dispatch(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.arrowRight,
        logicalKey: LogicalKeyboardKey.arrowRight,
        timeStamp: Duration(milliseconds: 1300),
      ),
    );
    expect(longPressEndCount, 1);

    dispatch(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowLeft,
        logicalKey: LogicalKeyboardKey.arrowLeft,
        timeStamp: Duration(seconds: 2),
      ),
    );
    expect(
      dispatch(
        const KeyRepeatEvent(
          physicalKey: PhysicalKeyboardKey.arrowLeft,
          logicalKey: LogicalKeyboardKey.arrowLeft,
          timeStamp: Duration(milliseconds: 2050),
        ),
      ),
      KeyEventResult.handled,
    );
    await tester.pump(const Duration(milliseconds: 250));
    expect(longPressStartCount, 1);
    dispatch(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.arrowLeft,
        logicalKey: LogicalKeyboardKey.arrowLeft,
        timeStamp: Duration(milliseconds: 2300),
      ),
    );
    expect(longPressStartCount, 1);
    expect(longPressEndCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets(
    'B and G stay single-shot when Flutter and the Activity bridge both fire',
    (tester) async {
      var sidebarToggles = 0;
      var episodeToggles = 0;

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService()..resetForTest(),
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
                onToggleSidebar: () => sidebarToggles++,
                onToggleEpisodePicker: () => episodeToggles++,
              ),
            ),
          ),
        ),
      );

      final state = tester.state<VideoControlsOverlayState>(
        find.byType(VideoControlsOverlay),
      );
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyB,
          logicalKey: LogicalKeyboardKey.keyB,
          timeStamp: Duration(milliseconds: 8),
        ),
      );
      state.handleAndroidHardwareKeyEventForTest(
        AndroidHardwareInputBridge.decodeKeyForTesting(<Object?, Object?>{
          'keyCode': 30,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 48000,
        })!,
      );
      expect(sidebarToggles, 1);

      state.handleKeyEvent(
        focusNode,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyG,
          logicalKey: LogicalKeyboardKey.keyG,
          timeStamp: Duration(milliseconds: 9),
        ),
      );
      state.handleAndroidHardwareKeyEventForTest(
        AndroidHardwareInputBridge.decodeKeyForTesting(<Object?, Object?>{
          'keyCode': 35,
          'action': 0,
          'repeatCount': 0,
          'eventTime': 49000,
        })!,
      );
      expect(episodeToggles, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
    },
  );
}
