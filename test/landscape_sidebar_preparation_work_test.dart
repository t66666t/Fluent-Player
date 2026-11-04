import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';
import 'package:video_player_app/widgets/transcript_text_cache.dart';

void main() {
  testWidgets(
    'continuous article becomes readable while new cues keep arriving',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': false,
        'subtitleViewMode': 1,
        'subtitleArticleParagraphModeEnabled': false,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      SubtitleItem cue(int index) => SubtitleItem(
        index: index,
        startTime: Duration(seconds: index * 2),
        endTime: Duration(seconds: index * 2 + 1),
        text: 'cue $index.',
      );
      final buffer = SubtitleCueBuffer()
        ..addAll(List<SubtitleItem>.generate(1000, cue));
      var cues = buffer.snapshot;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 500,
              child: StatefulBuilder(
                builder: (_, set) {
                  update = set;
                  return SubtitleSidebar(subtitles: cues, isCompact: true);
                },
              ),
            ),
          ),
        ),
      );
      var readableDuringStream = false;
      for (var batch = 0; batch < 160; batch++) {
        update(() {
          buffer.addAll([cue(cues.length)]);
          cues = buffer.snapshot;
        });
        await tester.pump(const Duration(milliseconds: 8));
        readableDuringStream |= find
            .byType(ContinuousArticleView)
            .evaluate()
            .isNotEmpty;
      }
      expect(
        readableDuringStream,
        isTrue,
        reason: 'New cues must not continually cancel the article prefix.',
      );
      await tester.pumpAndSettle();
      final view = tester.widget<ContinuousArticleView>(
        find.byType(ContinuousArticleView),
      );
      expect(view.document.sentences.length, cues.length);
      expect(view.document.text, endsWith('cue ${cues.length - 1}.'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    '12,000-cue sidebar prepares visible text and keeps distant seeks usable',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'autoScrollSubtitles': false,
        'subtitleViewMode': 0,
      });
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final readIndices = <int>{};
      final cues = List<SubtitleItem>.generate(
        12000,
        (index) => _CountedCue(index, () => readIndices.add(index)),
      );
      final key = GlobalKey<SubtitleSidebarState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                width: 320,
                height: 500,
                child: SubtitleSidebar(
                  key: key,
                  subtitles: cues,
                  isCompact: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        readIndices.length,
        lessThan(100),
        reason: 'Opening the list must not normalize the entire transcript.',
      );
      expect(find.textContaining('Normalized cue 0'), findsWidgets);
      key.currentState!.locateToTime(
        const Duration(seconds: 18000),
        animated: false,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Normalized cue 9000'), findsWidgets);
      expect(readIndices.length, lessThan(200));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'long article preparation yields, waits for motion and cancels stale work',
    (tester) async {
      var interacting = true, cancelled = false, reads = 0, done = false;
      final texts = TranscriptTextCache<String>(
        length: 500,
        resolve: (index) {
          reads++;
          return ' cue $index\nالعربية 👩🏽‍💻 ';
        },
      );
      final pending = ArticleDocument.fromDisplayTextsIncrementally(
        generation: 1,
        displayTexts: texts,
        isInteracting: () => interacting,
        isCancelled: () => cancelled,
        frameBudget: Duration.zero,
      )..then((_) => done = true);
      await tester.pump();
      await tester.pump();
      expect(reads, 0);
      interacting = false;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 8));
      }
      expect(reads, inExclusiveRange(0, texts.length));
      expect(done, isFalse);
      cancelled = true;
      await tester.pump();
      expect(await pending, isNull);
      expect(done, isTrue);
    },
  );

  testWidgets(
    'incremental article preserves text, image placeholders and sentence ranges',
    (tester) async {
      final texts = List.generate(
        600,
        (i) => i % 7 == 0 ? '' : ' 第 $i 句\n e\u0301 🇨🇳 ',
      );
      final images = List.generate(600, (i) => i % 21 == 0);
      final expected = ArticleDocument.fromDisplayTexts(
        generation: 4,
        displayTexts: texts,
        imageSubtitleFlags: images,
      );
      ArticleDocument? actual;
      final pending = ArticleDocument.fromDisplayTextsIncrementally(
        generation: 4,
        displayTexts: texts,
        imageSubtitleFlags: images,
      ).then((value) => actual = value);
      for (var i = 0; i < 100 && actual == null; i++) {
        await tester.pump(const Duration(milliseconds: 8));
      }
      await pending;
      expect(actual, isNotNull);
      expect(actual!.hasSameBody(expected), isTrue);
      expect(actual!.generation, expected.generation);
      final prefix = ArticleDocument.fromDisplayTexts(
        generation: 3,
        displayTexts: texts.take(300).toList(),
        imageSubtitleFlags: images.take(300).toList(),
      );
      actual = null;
      final append = ArticleDocument.fromDisplayTextsIncrementally(
        generation: 4,
        displayTexts: texts,
        imageSubtitleFlags: images,
        appendTo: prefix,
      ).then((value) => actual = value);
      for (var i = 0; i < 100 && actual == null; i++) {
        await tester.pump(const Duration(milliseconds: 8));
      }
      await append;
      expect(actual!.hasSameBody(expected), isTrue);
    },
  );
}

class _CountedCue extends SubtitleItem {
  _CountedCue(int cueIndex, this.onRead)
    : super(
        index: cueIndex,
        startTime: Duration(seconds: cueIndex * 2),
        endTime: Duration(seconds: cueIndex * 2 + 1),
        text: ' Normalized\ncue $cueIndex ',
      );
  final VoidCallback onRead;
  @override
  String get text {
    onRead();
    return super.text;
  }
}
