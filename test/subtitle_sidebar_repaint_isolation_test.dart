import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  for (final mode in ['list', 'paragraph', 'continuous']) {
    testWidgets(
      '$mode locate feedback does not repaint the surrounding player',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': true,
          'subtitleViewMode': mode == 'list' ? 0 : 1,
          'subtitleArticleParagraphModeEnabled': mode != 'continuous',
          'subtitleArticleSentencesPerParagraph': 1,
        });
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/sidebar-paint.mp4'),
        );
        controller.value = const VideoPlayerValue(
          duration: Duration(minutes: 10),
          isInitialized: true,
        );
        final painter = _PlayerPaintCounter();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 360,
                  height: 500,
                  child: CustomPaint(
                    painter: painter,
                    child: SubtitleSidebar(
                      subtitles: List.generate(
                        100,
                        (i) => SubtitleItem(
                          index: i,
                          startTime: Duration(seconds: i * 3),
                          endTime: Duration(seconds: i * 3 + 3),
                          text: 'Subtitle $i, readable transcript text.',
                        ),
                      ),
                      controller: controller,
                      onItemTap: (target) {
                        controller.value = controller.value.copyWith(
                          position: target,
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final before = painter.paints;
        // Ink feedback uses the sidebar's Material, outside the individual
        // reading-row boundaries. Exercise both it and the moving list.
        if (mode == 'list') {
          await tester.tap(find.text('Subtitle 4, readable transcript text.'));
        } else {
          await tester.tap(find.byTooltip('定位到当前字幕'));
        }
      await tester.pump();
      final afterTap = painter.paints;
      expect(afterTap - before, lessThanOrEqualTo(1));
        for (var frame = 0; frame < 80; frame++) {
          await tester.pump(const Duration(microseconds: 6944));
        }
        expect(
        painter.paints - afterTap,
          0,
          reason: 'Transcript ink and motion must stay within the sidebar.',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
      },
    );
  }
}

class _PlayerPaintCounter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(_PlayerPaintCounter oldDelegate) => false;
}
