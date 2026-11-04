import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/android_hardware_input_bridge.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('locked mobile unlock button fades out and returns on tap', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(800, 450));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    final playbackService = MediaPlaybackService();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: playbackService,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: VideoControlsOverlay(
              controller: controller,
              isLocked: true,
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

    final lockButton = find.byKey(const ValueKey('player-side-lock'));
    AnimatedOpacity lockOpacity() => tester.widget<AnimatedOpacity>(
      find
          .ancestor(of: lockButton, matching: find.byType(AnimatedOpacity))
          .first,
    );

    expect(lockButton, findsOneWidget);
    expect(lockOpacity().opacity, 1);

    await tester.pump(const Duration(seconds: 3));
    expect(lockOpacity().opacity, 0);

    await tester.tapAt(const Offset(400, 225));
    await tester.pump(const Duration(milliseconds: 200));
    expect(lockOpacity().opacity, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'desktop subtitle avoidance follows the near-completed controls fade',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
      addTearDown(controller.dispose);

      final playbackService = MediaPlaybackService();
      final controlsVisibility = ValueNotifier<bool>(true);
      addTearDown(controlsVisibility.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(
              value: playbackService,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: 750,
                    child: VideoControlsOverlay(
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
                      playbackControlsVisibility: controlsVisibility,
                    ),
                  ),
                  const Expanded(
                    child: ColoredBox(
                      key: ValueKey('non-player-sidebar'),
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final playerMouseRegion = find.byKey(
        const ValueKey('video-controls-player-mouse-region'),
      );
      MouseRegion region() => tester.widget<MouseRegion>(playerMouseRegion);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);

      // The complete 750px-wide surface is the player. This includes any
      // black space around a contained video.
      await mouse.addPointer(location: const Offset(500, 350));
      await tester.pump();
      expect(region().cursor, MouseCursor.defer);
      expect(controlsVisibility.value, isTrue);

      // Crossing into a sibling sidebar starts fading without a click, but the
      // controls still occupy subtitle space until they are almost faded out.
      await mouse.moveTo(const Offset(900, 350));
      expect(controlsVisibility.value, isTrue);
      await tester.pump();
      expect(region().cursor, SystemMouseCursors.none);
      await tester.pump(const Duration(milliseconds: 99));
      expect(controlsVisibility.value, isTrue);
      await tester.pump(const Duration(milliseconds: 16));
      expect(controlsVisibility.value, isFalse);

      // Re-entering reserves subtitle space before the fade-in starts.
      await mouse.moveTo(const Offset(500, 350));
      expect(controlsVisibility.value, isTrue);
      await tester.pump();
      expect(region().cursor, MouseCursor.defer);

      // Re-entering during a fade-out must cancel the pending release and
      // never let subtitles briefly return to the controls area.
      await mouse.moveTo(const Offset(900, 350));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(controlsVisibility.value, isTrue);
      await mouse.moveTo(const Offset(500, 350));
      expect(controlsVisibility.value, isTrue);
      await tester.pump(const Duration(milliseconds: 120));
      expect(controlsVisibility.value, isTrue);

      // A rapid second round trip must not be affected by a stale hide timer.
      await mouse.moveTo(const Offset(900, 350));
      await mouse.moveTo(const Offset(500, 350));
      await tester.pump();
      expect(region().cursor, MouseCursor.defer);
      expect(tester.takeException(), isNull);

      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      // VideoPreviewService deliberately keeps a short cache-cleanup timer
      // after this overlay is disposed.
      await tester.pump(const Duration(seconds: 20));
    },
  );

  testWidgets('Android hover shows details and yields cleanly to touch', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    final controlsVisibility = ValueNotifier<bool>(true);
    addTearDown(controlsVisibility.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService(),
          ),
          ChangeNotifierProvider<MediaPlaybackService>.value(
            value: MediaPlaybackService(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 750,
                  child: VideoControlsOverlay(
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
                    playbackControlsVisibility: controlsVisibility,
                  ),
                ),
                const Expanded(child: ColoredBox(color: Colors.grey)),
              ],
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('video-controls-player-mouse-region')),
      findsOneWidget,
    );

    // Exercise the Activity-level fallback path used when the vendor input
    // stack does not forward hover into Flutter by itself.
    AndroidHardwareInputBridge.dispatchNativeHoverForTesting(<Object?, Object?>{
      'action': 9,
      'x': 500.0,
      'y': 350.0,
      'eventTime': 10,
      'deviceId': 91,
    });
    await tester.pump();
    expect(controlsVisibility.value, isTrue);

    final lockButton = find.byKey(const ValueKey('player-side-lock'));
    final lockTooltipWidget = find.descendant(
      of: lockButton,
      matching: find.byType(Tooltip),
    );
    final lockTooltip = tester.widget<Tooltip>(lockTooltipWidget).message!;
    final lockPosition = tester.getCenter(lockButton);
    AndroidHardwareInputBridge.dispatchNativeHoverForTesting(<Object?, Object?>{
      'action': 7,
      'x': lockPosition.dx,
      'y': lockPosition.dy,
      'eventTime': 20,
      'deviceId': 91,
    });
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      find.text(lockTooltip),
      findsOneWidget,
      reason: 'native Android hover must open the existing IconButton tooltip',
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(500, 350));
    await tester.pump();
    final touch = await tester.createGesture(kind: PointerDeviceKind.touch);
    await touch.down(const Offset(450, 300));
    await mouse.moveTo(const Offset(900, 350));
    expect(
      controlsVisibility.value,
      isTrue,
      reason: 'mouse exit must not hide controls during an active touch',
    );
    await touch.cancel();

    // A later genuine mouse move takes ownership back.
    await tester.pump(const Duration(milliseconds: 130));
    await mouse.moveTo(const Offset(500, 350));
    await mouse.moveTo(const Offset(900, 350));
    await tester.pump(const Duration(milliseconds: 170));
    expect(controlsVisibility.value, isFalse);

    AndroidHardwareInputBridge.dispatchNativeHoverForTesting(<Object?, Object?>{
      'action': 10,
      'x': 900.0,
      'y': 350.0,
      'eventTime': 30,
      'deviceId': 91,
    });
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'hovering a subtitle above the player does not flicker controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
      addTearDown(controller.dispose);
      final controlsVisibility = ValueNotifier<bool>(true);
      addTearDown(controlsVisibility.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(
              value: MediaPlaybackService(),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: 750,
                    child: Stack(
                      children: [
                        VideoControlsOverlay(
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
                          playbackControlsVisibility: controlsVisibility,
                        ),
                        // Mirrors the real subtitle: it is painted above the
                        // player and moves back down once controls hide.
                        ValueListenableBuilder<bool>(
                          valueListenable: controlsVisibility,
                          builder: (context, visible, _) {
                            return Positioned(
                              key: const ValueKey('avoidance-hover-subtitle'),
                              left: 180,
                              top: visible ? 180 : 560,
                              width: 300,
                              height: 64,
                              child: GestureDetector(
                                onLongPress: () {},
                                behavior: HitTestBehavior.opaque,
                                child: const ColoredBox(
                                  color: Color(0xAA000000),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const Expanded(child: ColoredBox(color: Colors.grey)),
                ],
              ),
            ),
          ),
        ),
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(500, 400));
      await tester.pump();
      expect(controlsVisibility.value, isTrue);

      // Cursor rests on the subtitle after it has moved clear of the controls.
      await mouse.moveTo(const Offset(330, 212));
      await tester.pump();
      expect(controlsVisibility.value, isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      expect(controlsVisibility.value, isTrue);
      await tester.pump(const Duration(milliseconds: 400));
      expect(controlsVisibility.value, isTrue);

      // Small movements on the subtitle keep the avoided position stable.
      await mouse.moveTo(const Offset(360, 220));
      await tester.pump(const Duration(milliseconds: 250));
      expect(controlsVisibility.value, isTrue);

      // Idling there still hides the chrome, and the subtitle dropping away
      // must not immediately bring the controls back.
      await tester.pump(const Duration(seconds: 4));
      expect(controlsVisibility.value, isFalse);
      await tester.pump(const Duration(milliseconds: 50));
      expect(controlsVisibility.value, isFalse);

      // A later real movement reveals them once, without oscillating.
      await mouse.moveTo(const Offset(400, 300));
      await tester.pump();
      expect(controlsVisibility.value, isTrue);
      await mouse.moveTo(const Offset(330, 212));
      await tester.pump(const Duration(milliseconds: 400));
      expect(controlsVisibility.value, isTrue);

      // Leaving the player from the subtitle still hides the controls.
      await mouse.moveTo(const Offset(900, 350));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 170));
      expect(controlsVisibility.value, isFalse);

      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 20));
    },
  );
}
