import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/video_preview_service.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';

void main() {
  testWidgets(
    'desktop progress paints the saved timeline before a controller exists',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = MediaPlaybackService();
      await service.stop();
      final item = VideoItem(
        id: 'desktop-resume-chrome',
        path: 'bilibili://stream/BV1xx411c7mD?cid=1',
        title: 'Saved video',
        durationMs: 120000,
        lastPositionMs: 42000,
        lastUpdated: 0,
        sourceRef: const MediaSourceRef(
          kind: MediaSourceKind.bilibiliStream,
          value: 'BV1xx411c7mD',
          bvid: 'BV1xx411c7mD',
          cid: 1,
        ),
      );
      service.publishRestoredSessionPreview(item, const Duration(seconds: 42));
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsService>.value(
              value: SettingsService(),
            ),
            ChangeNotifierProvider<MediaPlaybackService>.value(value: service),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: VideoControlsOverlay(
                controller: null,
                mediaTitle: item.title,
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
                onLongPressStart: () => false,
                onLongPressEnd: () {},
                subtitleEntries: const [],
                subtitleStyle: const SubtitleStyle(),
                subtitleAlignment: Alignment.bottomCenter,
                onEnterSubtitleDragMode: () {},
                onToggleBilibiliPanel: () {},
                initialShowControls: true,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final sliders = tester.widgetList<Slider>(find.byType(Slider));
      expect(
        sliders.any((slider) => slider.value == 42000 && slider.max == 120000),
        isTrue,
      );
      // A native probe is not a new service timeline; a zero sample cannot
      // change this controller-free bookmark or its duration scale.
      expect(
        service.positionForProgressChrome(
          Duration.zero,
          libraryBookmark: const Duration(seconds: 42),
        ),
        const Duration(seconds: 42),
      );
      await tester.pumpWidget(const SizedBox());
      VideoPreviewService().clearCache();
      await service.stop();
      await tester.pump(const Duration(seconds: 6));
    },
  );
}
