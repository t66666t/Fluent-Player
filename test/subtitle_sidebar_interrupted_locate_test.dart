import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  for (final article in [false, true]) {
    testWidgets('${article ? 'article' : 'list'} opening repair interrupts '
        'a distant auto-follow without leaving transparent text', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': true,
        'subtitleViewMode': article ? 1 : 0,
        'subtitleArticleSentencesPerParagraph': 1,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final subtitles = List.generate(
        300,
        (i) => SubtitleItem(
          index: i,
          startTime: Duration(seconds: i * 3),
          endTime: Duration(seconds: i * 3 + 2),
          text: 'subtitle $i',
        ),
      );
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/interrupted.mp4'),
      );
      controller.value = const VideoPlayerValue(
        duration: Duration(minutes: 15),
        isInitialized: true,
        isPlaying: true,
      );
      final key = GlobalKey<SubtitleSidebarState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 360,
              child: SubtitleSidebar(
                key: key,
                subtitles: subtitles,
                controller: controller,
                isCompact: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      controller.value = controller.value.copyWith(
        position: subtitles[200].startTime,
      );
      // Start the same distant animated locate used by auto-follow. It mounts a second
      // list on the next frame; the opening repair is queued before that
      // list's post-mount animation callback.
      key.currentState!.locateToTime(
        subtitles[200].startTime,
        preferSingleStage: false,
      );
      key.currentState!.locateToCurrentSubtitle(ignorePointer: true);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final list = find.byType(ScrollablePositionedList);
      final fades = tester.widgetList<FadeTransition>(
        find.descendant(of: list, matching: find.byType(FadeTransition)),
      );
      expect(fades, hasLength(1));
      // ItemPositions can remain nonempty even when the entire list has
      // opacity zero. Check the actual paint opacity, not just text geometry.
      expect(fades.single.opacity.value, 1.0);
      final text = find.text('subtitle 200', findRichText: true);
      expect(text, findsOneWidget);
      expect(tester.getRect(list).overlaps(tester.getRect(text)), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    });
  }
}
