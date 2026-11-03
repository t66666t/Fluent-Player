import 'package:flutter/material.dart';
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

const _normal = BilibiliAudioQuality(id: 30280, label: '普通音质');
const _hires = BilibiliAudioQuality(
  id: 30251,
  label: 'Hi-Res无损',
  isSpecial: true,
);
const _dolby = BilibiliAudioQuality(id: 30250, label: '杜比全景声', isSpecial: true);
const _video = BilibiliStreamQuality(id: 80, label: '1080P 高清');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final item = VideoItem(
    id: 'audio-chrome',
    path: 'bilibili://stream/BV1gHjGzyE5Z?cid=1',
    title: 'Audio',
    durationMs: 120000,
    lastUpdated: 0,
    sourceRef: const MediaSourceRef(
      kind: MediaSourceKind.bilibiliStream,
      value: 'BV1gHjGzyE5Z',
      bvid: 'BV1gHjGzyE5Z',
      cid: 1,
    ),
  );

  for (final size in [
    const Size(1200, 800),
    const Size(420, 900),
    const Size(640, 360),
  ]) {
    for (final special in [_hires, _dolby]) {
      testWidgets('audio capsule and menu at $size: ${special.label}', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = MediaPlaybackService();
        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/video.mp4'),
        );
        controller.value = const VideoPlayerValue(
          duration: Duration(minutes: 2),
          isInitialized: true,
        );
        addTearDown(controller.dispose);
        service.debugOverrideStreamQualityChrome(
          item: item,
          qualities: [_video],
          selected: _video,
          audioQualities: [special, _normal],
          selectedAudio: special,
        );

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<SettingsService>.value(
                value: SettingsService(),
              ),
              ChangeNotifierProvider<MediaPlaybackService>.value(
                value: service,
              ),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: VideoControlsOverlay(
                  controller: controller,
                  mediaItemId: item.id,
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
                  initialShowControls: true,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final audio = find.byKey(
          const ValueKey('video-controls-audio-quality-button'),
        );
        final video = find.byKey(
          const ValueKey('video-controls-quality-button'),
        );
        final label = find.descendant(
          of: audio,
          matching: find.text(special.label),
        );
        expect(audio, findsOneWidget);
        expect(
          tester.widget<Text>(label).style?.color,
          const Color(0xFFFF6699),
        );
        expect(
          tester.getRect(audio).bottom,
          lessThan(tester.getRect(video).top),
        );
        expect(
          tester.getRect(audio).right,
          closeTo(tester.getRect(video).right, 0.1),
        );

        service.debugOverrideStreamQualityChrome(
          item: item,
          qualities: [_video],
          selected: _video,
          audioQualities: [special, _normal],
          selectedAudio: _normal,
        );
        await tester.pump();
        expect(tester.widget<Text>(label).style?.color, Colors.white54);

        // Same picker, including ordinary audio and the actual selected row.
        await tester.tap(audio);
        await tester.pumpAndSettle();
        final menu = find.byKey(
          const ValueKey('video-controls-audio-quality-picker'),
        );
        expect(menu, findsOneWidget);
        expect(
          find.descendant(of: menu, matching: find.text(_normal.label)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: menu, matching: find.text(special.label)),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(of: menu, matching: find.text(_normal.label)),
        );
        await tester.pumpAndSettle();
        expect(menu, findsNothing);

        service.debugOverrideStreamQualityChrome(
          item: item,
          qualities: [_video],
          selected: _video,
          audioQualities: [special, _normal],
          selectedAudio: special,
        );
        await tester.pump();
        expect(
          tester.widget<Text>(label).style?.color,
          const Color(0xFFFF6699),
        );
        final initial = tester.widget(audio);
        for (var i = 1; i <= 10; i++) {
          controller.value = controller.value.copyWith(
            position: Duration(milliseconds: i * 16),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(identical(tester.widget(audio), initial), isTrue);
        expect(tester.takeException(), isNull);

        service.debugOverrideStreamQualityChrome(
          item: item,
          qualities: [_video],
          selected: _video,
          audioQualities: [
            _normal,
            const BilibiliAudioQuality(id: 30232, label: '普通音质'),
            const BilibiliAudioQuality(id: 30216, label: '普通音质'),
          ],
          selectedAudio: _normal,
        );
        await tester.pump();
        expect(audio, findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        service.debugOverrideStreamQualityChrome();
        await tester.pump(const Duration(seconds: 6));
      });
    }
  }
}
