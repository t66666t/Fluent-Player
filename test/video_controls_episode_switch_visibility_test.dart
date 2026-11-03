import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget overlayHarness({
    required VideoPlayerController controller,
    required MediaPlaybackService playbackService,
    required ValueNotifier<bool> controlsVisibility,
    required bool initialShowControls,
    required ValueChanged<bool> onControlsVisibilityIntent,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(value: SettingsService()),
        ChangeNotifierProvider<MediaPlaybackService>.value(
          value: playbackService,
        ),
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
            playbackControlsVisibility: controlsVisibility,
            initialShowControls: initialShowControls,
            onControlsVisibilityIntent: onControlsVisibilityIntent,
          ),
        ),
      ),
    );
  }

  testWidgets('remount after an episode skip keeps hidden playback chrome hidden', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    final playbackService = MediaPlaybackService();
    final controlsVisibility = ValueNotifier<bool>(true);
    addTearDown(controlsVisibility.dispose);
    var chromeVisible = true;

    await tester.pumpWidget(
      overlayHarness(
        controller: controller,
        playbackService: playbackService,
        controlsVisibility: controlsVisibility,
        initialShowControls: chromeVisible,
        onControlsVisibilityIntent: (visible) => chromeVisible = visible,
      ),
    );
    expect(chromeVisible, isTrue);

    await tester.tapAt(const Offset(500, 350));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(chromeVisible, isFalse);

    // Keyboard/headset skips and auto-play-on-completion both unmount the
    // overlay, then rebuild it with the last immediate chrome intent.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      overlayHarness(
        controller: controller,
        playbackService: playbackService,
        controlsVisibility: controlsVisibility,
        initialShowControls: chromeVisible,
        onControlsVisibilityIntent: (visible) => chromeVisible = visible,
      ),
    );
    await tester.pump();
    expect(chromeVisible, isFalse);
    expect(controlsVisibility.value, isFalse);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(500, 350));
    await tester.pump();
    expect(
      controlsVisibility.value,
      isFalse,
      reason: 'a leftover pointer over the player must not reveal chrome',
    );

    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('remount after an episode skip keeps visible playback chrome visible', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.invalid/video.mp4'),
    );
    addTearDown(controller.dispose);
    final playbackService = MediaPlaybackService();
    final controlsVisibility = ValueNotifier<bool>(true);
    addTearDown(controlsVisibility.dispose);
    var chromeVisible = true;

    await tester.pumpWidget(
      overlayHarness(
        controller: controller,
        playbackService: playbackService,
        controlsVisibility: controlsVisibility,
        initialShowControls: chromeVisible,
        onControlsVisibilityIntent: (visible) => chromeVisible = visible,
      ),
    );
    expect(chromeVisible, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      overlayHarness(
        controller: controller,
        playbackService: playbackService,
        controlsVisibility: controlsVisibility,
        initialShowControls: chromeVisible,
        onControlsVisibilityIntent: (visible) => chromeVisible = visible,
      ),
    );
    await tester.pump();
    expect(chromeVisible, isTrue);
    expect(controlsVisibility.value, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });
}
