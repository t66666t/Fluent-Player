import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/screens/video_player_screen.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('missing source mounts controls without a native controller', () {
    expect(
      shouldMountPlaybackControls(
        initialized: false,
        controllerAssigned: false,
        sourceMissing: true,
        subtitleDragActive: false,
        ghostDragActive: false,
      ),
      isTrue,
    );
    expect(
      shouldMountPlaybackControls(
        initialized: false,
        controllerAssigned: false,
        sourceMissing: false,
        subtitleDragActive: false,
        ghostDragActive: false,
      ),
      isTrue,
    );
  });

  testWidgets('missing source keeps the play button available for retry', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var retryCount = 0;
    var backCount = 0;
    var exitCount = 0;
    var fullScreenCount = 0;

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
            body: VideoControlsOverlay(
              controller: null,
              isLocked: false,
              onTogglePlay: () => retryCount++,
              onBackPressed: () => backCount++,
              onExitPressed: () => exitCount++,
              onToggleFullScreen: () => fullScreenCount++,
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
              allowPlayWhenUninitialized: true,
            ),
          ),
        ),
      ),
    );

    final playButton = find.byKey(const ValueKey('video-controls-play-pause'));
    expect(playButton, findsOneWidget);
    expect(tester.widget<IconButton>(playButton).onPressed, isNotNull);

    await tester.tap(playButton);
    await tester.pump();
    expect(retryCount, 1);

    final closeButton = find.byKey(const ValueKey('video-controls-close'));
    expect(closeButton, findsOneWidget);
    expect(tester.widget<IconButton>(closeButton).tooltip, '退出播放');
    await tester.tap(closeButton);
    await tester.pump();
    expect(exitCount, 1);

    final state = tester.state<VideoControlsOverlayState>(
      find.byType(VideoControlsOverlay),
    );
    final shortcutFocus = FocusNode();
    addTearDown(shortcutFocus.dispose);
    expect(
      state.handleKeyEvent(
        shortcutFocus,
        const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.escape,
          logicalKey: LogicalKeyboardKey.escape,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.handled,
    );
    expect(backCount, 1, reason: 'Escape returns on key-down');
    await tester.pump(const Duration(seconds: 1));
    expect(backCount, 1);
    expect(fullScreenCount, 0);
    expect(
      state.handleKeyEvent(
        shortcutFocus,
        const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.escape,
          logicalKey: LogicalKeyboardKey.escape,
          timeStamp: Duration.zero,
        ),
      ),
      KeyEventResult.handled,
    );
    expect(backCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 20));
  });
}
