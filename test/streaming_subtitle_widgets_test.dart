import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_engine.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_model.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/music_lyric_view.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

List<SubtitleItem> cues(int start, int count) => List.generate(
  count,
  (i) => SubtitleItem(
    index: start + i + 1,
    startTime: Duration(seconds: (start + i) * 5),
    endTime: Duration(seconds: (start + i) * 5 + 4),
    text: 'Streaming sentence ${start + i}',
  ),
);

Future<void> frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  for (final mode in ['list', 'paragraph', 'continuous']) {
    testWidgets(
      'growing secondary retains reading anchor and freezes selection: $mode',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'autoScrollSubtitles': false,
          'subtitleViewMode': mode == 'list' ? 0 : 1,
          'subtitleArticleParagraphModeEnabled': mode == 'paragraph',
        });
        final settings = SettingsService()..resetForTest();
        await settings.init();
        final primary = SubtitleCueBuffer()..addAll(cues(0, 80));
        final secondary = SubtitleCueBuffer();
        final controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.invalid/cloud.mp4'),
        );
        controller.value = VideoPlayerValue(
          duration: const Duration(minutes: 10),
          position: const Duration(seconds: 35),
          isInitialized: true,
          isPlaying: false,
        );
        final key = GlobalKey<SubtitleSidebarState>();
        Future<void> show() => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 500,
                height: 550,
                child: SubtitleSidebar(
                  key: key,
                  subtitles: primary.snapshot,
                  secondarySubtitles: secondary.snapshot,
                  controller: controller,
                  isCompact: true,
                  isPortrait: true,
                ),
              ),
            ),
          ),
        );
        await show();
        await frames(tester, 25);
        key.currentState!.locateToTime(
          const Duration(seconds: 180),
          animated: false,
        );
        await frames(tester, 20);
        final listFinder = find
            .descendant(
              of: find.byType(SubtitleSidebar),
              matching: find.byType(ScrollablePositionedList),
            )
            .first;
        ({int cue, double alignment}) anchor() {
          final list = tester.widget<ScrollablePositionedList>(listFinder);
          final positions =
              list.itemPositionsNotifier!.itemPositions.value
                  .where((p) => p.itemLeadingEdge >= 0 && p.itemLeadingEdge < 1)
                  .toList()
                ..sort((a, b) => a.index.compareTo(b.index));
          expect(positions, isNotEmpty);
          final first = positions.first;
          final index = mode == 'continuous'
              ? tester
                    .widget<ContinuousArticleView>(
                      find.byType(ContinuousArticleView),
                    )
                    .layout
                    .lines[first.index]
                    .sentenceIndices
                    .first
              : first.index;
          return (cue: index, alignment: first.itemLeadingEdge);
        }

        final before = anchor();
        secondary.addAll(
          cues(0, 8).map((c) => c.copyWith(text: '译文 ${c.index}')),
        );
        await show();
        await frames(tester, 25);
        final after = anchor();
        if (mode == 'continuous') {
          final view = tester.widget<ContinuousArticleView>(
            find.byType(ContinuousArticleView),
          );
          final list = tester.widget<ScrollablePositionedList>(listFinder);
          final first =
              list.itemPositionsNotifier!.itemPositions.value
                  .where((p) => p.itemLeadingEdge >= 0 && p.itemLeadingEdge < 1)
                  .toList()
                ..sort((a, b) => a.index.compareTo(b.index));
          expect(
            view.layout.lines[first.first.index].sentenceIndices,
            contains(before.cue),
            reason:
                'Reflow can share a line with the preceding sentence; the same reading sentence must remain on that first line.',
          );
        } else {
          expect(after.cue, before.cue);
        }
        expect(after.alignment, closeTo(before.alignment, .015));
        SelectionAreaState selection() => tester.state<SelectionAreaState>(
          find
              .descendant(
                of: find.byType(SubtitleSidebar),
                matching: find.byType(SelectionArea),
              )
              .first,
        );
        selection().selectableRegion.selectAll(SelectionChangedCause.keyboard);
        await tester.pump();
        final selected = key.currentState!.selectedTranscriptText;
        expect(selected, contains('译文 8'));
        secondary.addAll(
          cues(8, 8).map((c) => c.copyWith(text: '译文 ${c.index}')),
        );
        await show();
        await frames(tester, 8);
        expect(key.currentState!.selectedTranscriptText, selected);
        expect(key.currentState!.hasTextSelection, isTrue);
        key.currentState!.clearTextSelection();
        await frames(tester, 25);
        selection().selectableRegion.selectAll(SelectionChangedCause.keyboard);
        await tester.pump();
        expect(key.currentState!.selectedTranscriptText, contains('译文 16'));
        expect(controller.value.position, const Duration(seconds: 35));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.dispose();
      },
    );
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    for (final size in [const Size(360, 760), const Size(1000, 550)]) {
      testWidgets(
        'stream append preserves lyric reading anchor $platform $size',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final primary = SubtitleCueBuffer()..addAll(cues(0, 80));
          final secondary = SubtitleCueBuffer()
            ..addAll(
              cues(0, 80).map((cue) => cue.copyWith(text: '译文 ${cue.index}')),
            );
          final clock = ValueNotifier(const Duration(seconds: 30));
          addTearDown(clock.dispose);
          final key = GlobalKey();
          Future<void> show() => tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: MusicLyricView(
                  key: key,
                  subtitles: primary.snapshot,
                  secondarySubtitles: secondary.snapshot,
                  positionListenable: clock,
                  isPlaying: false,
                ),
              ),
            ),
          );
          await show();
          await frames(tester, 15);
          // Read away from the playback location, then append at the far tail.
          await tester.drag(find.byType(MusicLyricView), const Offset(0, -220));
          await frames(tester, 7);
          final before = <String, double>{};
          for (var i = 0; i < 80; i++) {
            final finder = find.text('Streaming sentence $i');
            if (finder.evaluate().isNotEmpty) {
              before['Streaming sentence $i'] = tester
                  .getTopLeft(finder.first)
                  .dy;
            }
          }
          expect(before, isNotEmpty);
          primary.addAll(cues(80, 10));
          secondary.addAll(
            cues(80, 10).map((cue) => cue.copyWith(text: '译文 ${cue.index}')),
          );
          await show();
          await frames(tester, 4);
          for (final entry in before.entries) {
            final finder = find.text(entry.key);
            if (finder.evaluate().isNotEmpty) {
              expect(
                tester.getTopLeft(finder.first).dy,
                closeTo(entry.value, 1.5),
              );
            }
          }
          expect(clock.value, const Duration(seconds: 30));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final mode in [0, 1]) {
    for (final paragraphs in [false, true]) {
      testWidgets(
        'subtitle ${mode == 0 ? 'list' : 'article'} preserves anchor during append, paragraphs=$paragraphs',
        (tester) async {
          SharedPreferences.setMockInitialValues({
            'autoScrollSubtitles': false,
            'subtitleViewMode': mode,
            'subtitleArticleParagraphModeEnabled': paragraphs,
            'subtitleArticleSentencesPerParagraph': 4,
          });
          final settings = SettingsService()..resetForTest();
          await settings.init();
          final primary = SubtitleCueBuffer()..addAll(cues(0, 80));
          final secondary = SubtitleCueBuffer()
            ..addAll(
              cues(0, 80).map((cue) => cue.copyWith(text: '译文 ${cue.index}')),
            );
          final controller = VideoPlayerController.networkUrl(
            Uri.parse('https://example.invalid/streaming.mp4'),
          );
          controller.value = VideoPlayerValue(
            duration: const Duration(minutes: 10),
            position: const Duration(seconds: 35),
            isInitialized: true,
            isPlaying: false,
          );
          final key = GlobalKey<SubtitleSidebarState>();
          Future<void> show() => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 500,
                  height: 550,
                  child: SubtitleSidebar(
                    key: key,
                    subtitles: primary.snapshot,
                    secondarySubtitles: secondary.snapshot,
                    controller: controller,
                    isCompact: true,
                    isPortrait: true,
                  ),
                ),
              ),
            ),
          );
          await show();
          await frames(tester, 12);
          key.currentState!.jumpToFirstSubtitleTop();
          await frames(tester);
          await tester.drag(
            find.byType(SubtitleSidebar),
            const Offset(0, -150),
          );
          await frames(tester, 10);
          final scrollables = find.descendant(
            of: find.byType(SubtitleSidebar),
            matching: find.byType(Scrollable),
          );
          final positions = [
            for (final element in scrollables.evaluate())
              (element as StatefulElement).state as ScrollableState,
          ];
          final oldOffsets = [
            for (final state in positions) state.position.pixels,
          ];
          primary.addAll(cues(80, 10));
          secondary.addAll(
            cues(80, 10).map((cue) => cue.copyWith(text: '译文 ${cue.index}')),
          );
          await show();
          await frames(tester, 12);
          for (var i = 0; i < positions.length; i++) {
            if (positions[i].mounted) {
              expect(positions[i].position.pixels, closeTo(oldOffsets[i], 1.5));
            }
          }
          expect(controller.value.position, const Duration(seconds: 35));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await controller.dispose();
        },
      );
    }
  }

  test(
    'continuous article append reuses complete line records and matches full layout',
    () async {
      final original = ArticleDocument.fromDisplayTexts(
        generation: 1,
        displayTexts: List.generate(
          250,
          (i) => 'Sentence $i with 中文 and emoji 🌏.',
        ),
      );
      const style = TextStyle(fontSize: 16, height: 1.5);
      ArticleLayoutKey key(int generation) => ArticleLayoutKey(
        documentGeneration: generation,
        width: 350,
        style: style,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      );
      const engine = ArticleLayoutEngine();
      final first = engine.layout(document: original, key: key(1));
      final document = original.appendDisplayTexts(
        generation: 2,
        displayTexts: const ['A final sentence.', '最后一句。'],
      );
      final next = await engine.layoutIncrementally(
        document: document,
        key: key(2),
        appendTo: first,
      );
      final full = engine.layout(document: document, key: key(2));
      expect(
        next!.lines.map((line) => [line.start, line.end]),
        full.lines.map((line) => [line.start, line.end]),
      );
      expect(next.sentenceToLine, full.sentenceToLine);
      expect(identical(next.lines.first, first.lines.first), isTrue);
    },
  );
}
