import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  for (final initiallyVisible in [false, true]) {
    testWidgets('hidden playback chrome stops rebuilding and resumes current '
        'progress; initiallyVisible=$initiallyVisible', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/video.mp4'),
      );
      addTearDown(controller.dispose);
      controller.value = const VideoPlayerValue(
        duration: Duration(minutes: 10),
        isInitialized: true,
      );
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
                controller: controller,
                initialShowControls: initiallyVisible,
                enableSeekThumbnailPreview: false,
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
      await tester.pump();
      final state = tester.state<VideoControlsOverlayState>(
        find.byType(VideoControlsOverlay),
      );
      if (initiallyVisible) {
        state.applyControlsVisibilityIntent(false);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        controller.value = controller.value.copyWith(
          position: const Duration(seconds: 1),
        );
        await tester.pump();
        // The still-visible fade must continue tracking the player.
        expect(find.text('00:01 / 10:00'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
      }
      final progress = find.byKey(
        const ValueKey('video-controls-progress-area'),
      );
      final hiddenProgress = tester.widget(progress);
      for (var tick = 2; tick <= 30; tick++) {
        controller.value = controller.value.copyWith(
          position: Duration(seconds: tick),
        );
        await tester.pump(const Duration(milliseconds: 7));
        expect(identical(tester.widget(progress), hiddenProgress), isTrue);
      }
      expect(find.text('00:30 / 10:00'), findsNothing);
      state.applyControlsVisibilityIntent(true);
      await tester.pump();
      expect(find.text('00:30 / 10:00'), findsOneWidget);
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 31),
      );
      await tester.pump(const Duration(milliseconds: 7));
      expect(find.text('00:31 / 10:00'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 21));
    });
  }
}
