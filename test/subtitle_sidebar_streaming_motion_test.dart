import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/utils/ui_interaction_budget.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';

List<SubtitleItem> _cues(int start, int count) => List.generate(
  count,
  (i) => SubtitleItem(
    index: start + i,
    startTime: Duration(seconds: (start + i) * 3),
    endTime: Duration(seconds: (start + i) * 3 + 2),
    text: 'Cue ${start + i}: 阅读当前字幕，同时保持播放和文稿动画流畅。',
  ),
);

Map<String, Widget> _readingText(WidgetTester tester) => {
  for (final element
      in find
          .descendant(
            of: find.byType(SubtitleSidebar),
            matching: find.byType(Text),
          )
          .evaluate())
    if (element.widget case final Text text)
      if ((text.data ?? text.textSpan?.toPlainText() ?? '').contains('Cue '))
        text.key?.toString() ?? text.data ?? text.textSpan!.toPlainText(): text,
};

void main() {
  testWidgets(
    'a late font load refreshes line metrics without replacing the document',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'subtitleViewMode': 1,
        'subtitleArticleParagraphModeEnabled': false,
        'autoScrollSubtitles': false,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'LateReadingMetrics'),
          home: Scaffold(
            body: SizedBox(
              width: 430,
              height: 640,
              child: SubtitleSidebar(subtitles: _cues(0, 100)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.widget<ContinuousArticleView>(
        find.byType(ContinuousArticleView),
      );
      final load = FontLoader('LateReadingMetrics')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'));
      await tester.runAsync(load.load);
      await tester.pumpAndSettle();
      final after = tester.widget<ContinuousArticleView>(
        find.byType(ContinuousArticleView),
      );
      expect(after.document, same(before.document));
      expect(identical(after.layout.lines, before.layout.lines), isFalse);
      expect(after.layout.key.style.fontFamily, 'LateReadingMetrics');
      expect(
        find.byKey(const ValueKey('subtitle-continuous-article-preparing')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in ['list', 'paragraph', 'continuous']) {
    testWidgets('$mode streamed tail preserves existing reading text widgets', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'subtitleViewMode': mode == 'list' ? 0 : 1,
        'subtitleArticleParagraphModeEnabled': mode == 'paragraph',
        'subtitleArticleSentencesPerParagraph': 4,
        'autoScrollSubtitles': true,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final primary = SubtitleCueBuffer()..addAll(_cues(0, 6000));
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://example.invalid/transcript-performance.mp4'),
      );
      controller.value = VideoPlayerValue(
        duration: const Duration(hours: 10),
        position: const Duration(seconds: 9000),
        isInitialized: true,
      );
      final key = GlobalKey<SubtitleSidebarState>();
      late StateSetter update;
      var subtitles = primary.snapshot;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'Ahem'),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SizedBox(
                width: 480,
                height: 640,
                child: SubtitleSidebar(
                  key: key,
                  subtitles: subtitles,
                  controller: controller,
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      key.currentState!.locateToCurrentSubtitle(ignorePointer: true);
      await tester.pumpAndSettle();
      final before = _readingText(tester);
      if (mode == 'continuous') {
        final view = tester.widget<ContinuousArticleView>(
          find.byType(ContinuousArticleView),
        );
        expect(
          view.style.fontFamily,
          'Ahem',
          reason:
              'Line measurement and selectable text must use the same inherited font.',
        );
        expect(view.layout.key.style, view.style);
      }
      expect(before.length, greaterThan(5));
      for (var batch = 0; batch < 3; batch++) {
        primary.addAll(_cues(6000 + batch * 2, 2));
        update(() => subtitles = primary.snapshot);
        await tester.pumpAndSettle();
        final after = _readingText(tester);
        final rebuilt = before.keys.where(
          (key) =>
              after.containsKey(key) && !identical(before[key], after[key]),
        );
        expect(
          rebuilt,
          isEmpty,
          reason: 'Appending a distant tail must not rebuild existing text.',
        );
      }
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ScrollablePositionedList).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final list = tester.widget<ScrollablePositionedList>(
        find
            .descendant(
              of: find.byType(SubtitleSidebar),
              matching: find.byType(ScrollablePositionedList),
            )
            .first,
      );
      final article = mode == 'continuous'
          ? tester.widget<ContinuousArticleView>(
              find.byType(ContinuousArticleView),
            )
          : null;
      int? target;
      for (final item in list.itemPositionsNotifier!.itemPositions.value) {
        if (item.itemLeadingEdge < .4 || item.itemLeadingEdge > .75) continue;
        if (article != null) {
          for (final sentence
              in article.layout.lines[item.index].sentenceIndices) {
            if (article.layout.lineForSentence(sentence) == item.index) {
              target = sentence;
              break;
            }
          }
        } else {
          target = mode == 'paragraph' ? item.index * 4 : item.index;
        }
        if (target != null) break;
      }
      expect(target, isNotNull);
      key.currentState!.locateToTime(Duration(seconds: target! * 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final position = scrollable.position;
      final activity = position.activity;
      final pixels = position.pixels;
      expect(position.isScrollingNotifier.value, isTrue);
      expect(UiInteractionBudget.instance.isActive, isTrue);
      primary.addAll(_cues(6006, 2));
      update(() => subtitles = primary.snapshot);
      await tester.pump(const Duration(milliseconds: 16));
      expect(identical(scrollable.position, position), isTrue);
      expect(
        identical(position.activity, activity),
        isTrue,
        reason: 'Stream updates must not replace a running scroll activity.',
      );
      expect((position.pixels - pixels).abs(), lessThan(60));
      await tester.pumpAndSettle();
      expect(position.isScrollingNotifier.value, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(UiInteractionBudget.instance.isActive, isFalse);
      await controller.dispose();
    });
  }
}
