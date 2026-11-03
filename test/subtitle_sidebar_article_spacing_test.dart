import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/transcription_manager.dart';
import 'package:video_player_app/widgets/subtitle_generation_footer.dart';
import 'package:video_player_app/widgets/subtitle_sidebar.dart';

void main() {
  for (final paragraphMode in [true, false]) {
    for (final portrait in [true, false]) {
      for (final fontScale in [.65, 1.5]) {
        testWidgets(
          '${paragraphMode ? 'paragraph' : 'continuous'} article edges use '
          'line spacing, portrait=$portrait, font=$fontScale',
          (tester) async {
            SharedPreferences.setMockInitialValues({
              'autoScrollSubtitles': false,
              'subtitleViewMode': 1,
              'subtitleArticleParagraphModeEnabled': paragraphMode,
              'subtitleArticleSentencesPerParagraph': 4,
              'portraitSidebarFontSizeScale': fontScale,
              'landscapeSidebarFontSizeScale': fontScale,
            });
            final settings = SettingsService()..resetForTest();
            await settings.init();
            final playback = MediaPlaybackService.forTesting();
            final manager = TranscriptionManager();
            final size = portrait ? const Size(390, 600) : const Size(900, 600);
            await tester.binding.setSurfaceSize(size);
            addTearDown(() async {
              await tester.pumpWidget(const SizedBox());
              playback.dispose();
              manager.dispose();
              settings.resetForTest();
              await tester.binding.setSurfaceSize(null);
            });
            await tester.pumpWidget(
              MultiProvider(
                providers: [
                  ChangeNotifierProvider<MediaPlaybackService>.value(
                    value: playback,
                  ),
                  ChangeNotifierProvider<TranscriptionManager>.value(
                    value: manager,
                  ),
                ],
                child: MaterialApp(
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(portrait ? 1.3 : 1),
                    ),
                    child: child!,
                  ),
                  home: Scaffold(
                    body: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: portrait ? size.width : 380,
                        height: size.height,
                        child: SubtitleSidebar(
                          subtitles: _cues,
                          isCompact: true,
                          isPortrait: portrait,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await _frames(tester);

            final list = find.byType(ScrollablePositionedList);
            final viewport = tester.getRect(list);
            final lines = _visibleTextLines(tester, viewport);
            expect(lines.length, greaterThan(2));
            final lineGap = lines[1].top - lines[0].bottom;
            expect(lineGap, greaterThan(0));
            final topGap = lines.first.top - viewport.top;
            expect(topGap, inInclusiveRange(0, lineGap + 1));

            final indexedList = tester.widget<ScrollablePositionedList>(list);
            indexedList.itemScrollController!.jumpTo(
              index: indexedList.itemCount - 2,
            );
            await _frames(tester);
            final scrollable = tester.state<ScrollableState>(
              find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .first,
            );
            scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
            await _frames(tester);
            final bottomGap =
                tester.getRect(list).bottom -
                _visibleTextLines(tester, tester.getRect(list)).last.bottom;
            expect(bottomGap, inInclusiveRange(0, lineGap + 1));
            expect(bottomGap, closeTo(topGap, 1));
            final footer = find.byType(SubtitleGenerationFooter);
            if (footer.evaluate().isNotEmpty) {
              expect(tester.getSize(footer).height, 0);
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}

final _cues = List.generate(
  80,
  (i) => SubtitleItem(
    index: i,
    startTime: Duration(seconds: i * 3),
    endTime: Duration(seconds: i * 3 + 3),
    text: 'Sentence $i is a readable subtitle with enough words to wrap.',
  ),
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

List<Rect> _visibleTextLines(WidgetTester tester, Rect viewport) {
  final lines = <Rect>[];
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.descendant(
      of: find.byType(ScrollablePositionedList),
      matching: find.byType(RichText),
    ),
  )) {
    final text = paragraph.text.toPlainText();
    if (!paragraph.hasSize || text.trim().isEmpty) continue;
    // Joiner spaces inherit the paragraph's default style. Measure actual
    // words so those spaces are not mistaken for a second line of text.
    for (final word in RegExp(r'\S+').allMatches(text)) {
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: word.start, extentOffset: word.end),
      )) {
        final rect = box.toRect().shift(paragraph.localToGlobal(Offset.zero));
        if (rect.bottom <= viewport.top || rect.top >= viewport.bottom) {
          continue;
        }
        final existing = lines.indexWhere(
          (line) => (line.top - rect.top).abs() < .5,
        );
        if (existing < 0) {
          lines.add(rect);
        } else {
          lines[existing] = lines[existing].expandToInclude(rect);
        }
      }
    }
  }
  return lines..sort((a, b) => a.top.compareTo(b.top));
}
