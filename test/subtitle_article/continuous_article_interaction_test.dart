import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_engine.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_model.dart';
import 'package:video_player_app/features/subtitle_article/continuous_article_view.dart';

void main() {
  testWidgets('growing past one viewport retains mounted selectable lines', (
    tester,
  ) async {
    const style = TextStyle(fontSize: 16, height: 1.6);
    final active = ValueNotifier<List<int>>([0]);
    final scroll = ItemScrollController();
    final positions = ItemPositionsListener.create();
    var document = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: List.generate(3, (i) => 'Sentence $i stays near the top.'),
    );
    ArticleLayout measure() => const ArticleLayoutEngine().layout(
      document: document,
      key: ArticleLayoutKey(
        documentGeneration: document.generation,
        width: 360,
        style: style,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      ),
    );
    var layout = measure();
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 300,
            child: SelectionArea(
              child: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return ContinuousArticleView(
                    document: document,
                    layout: layout,
                    style: style,
                    highlightStyle: style.copyWith(color: Colors.blueAccent),
                    activeIndices: active,
                    itemScrollController: scroll,
                    itemPositionsListener: positions,
                    onSubtitleTap: (_) {},
                    padding: const EdgeInsets.all(20),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final text = find.byKey(const ValueKey('subtitle-continuous-line-text-0'));
    final original = text.evaluate().single;
    final top = tester.getTopLeft(text);
    update(() {
      document = ArticleDocument.fromDisplayTexts(
        generation: 2,
        displayTexts: List.generate(
          30,
          (i) => 'Sentence $i stays near the top.',
        ),
      );
      layout = measure();
    });
    await tester.pumpAndSettle();
    expect(text.evaluate().single, same(original));
    expect(tester.getTopLeft(text), top);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });

  testWidgets('a resized article returns to the top when it fits', (
    tester,
  ) async {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: List.generate(6, (i) => 'Sentence $i stays near the top.'),
    );
    const style = TextStyle(fontSize: 16, height: 1.6);
    final layout = const ArticleLayoutEngine().layout(
      document: document,
      key: const ArticleLayoutKey(
        documentGeneration: 1,
        width: 360,
        style: style,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      ),
    );
    final active = ValueNotifier<List<int>>([4]);
    final scroll = ItemScrollController();
    var height = 120.0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 400,
                height: height,
                child: ContinuousArticleView(
                  document: document,
                  layout: layout,
                  style: style,
                  highlightStyle: style.copyWith(color: Colors.blueAccent),
                  activeIndices: active,
                  itemScrollController: scroll,
                  itemPositionsListener: ItemPositionsListener.create(),
                  onSubtitleTap: (_) {},
                  initialSentenceIndex: 4,
                  initialAlignment: .5,
                  padding: const EdgeInsets.all(20),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = find.byType(ScrollablePositionedList);
    final state = tester.state(list);
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    expect(
      position().maxScrollExtent - position().minScrollExtent,
      greaterThan(0),
    );
    scroll.jumpTo(index: layout.lines.length - 1, alignment: .8);
    await tester.pumpAndSettle();
    update(() => height = 600);
    await tester.pumpAndSettle();
    expect(tester.state(list), same(state));
    expect(
      position().maxScrollExtent - position().minScrollExtent,
      closeTo(0, .5),
    );
    expect(
      tester
              .getTopLeft(
                find.byKey(const ValueKey('subtitle-continuous-line-0')),
              )
              .dy -
          tester.getTopLeft(list).dy,
      closeTo(20, .5),
    );
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });

  testWidgets(
    'short article ignores the reading anchor and starts at the top',
    (tester) async {
      final document = ArticleDocument.fromDisplayTexts(
        generation: 1,
        displayTexts: List.generate(
          6,
          (i) => 'Sentence $i stays near the top.',
        ),
      );
      const style = TextStyle(fontSize: 16, height: 1.6);
      final layout = const ArticleLayoutEngine().layout(
        document: document,
        key: const ArticleLayoutKey(
          documentGeneration: 1,
          width: 360,
          style: style,
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
        ),
      );
      final active = ValueNotifier<List<int>>([4]);
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              height: 600,
              child: ContinuousArticleView(
                document: document,
                layout: layout,
                style: style,
                highlightStyle: style.copyWith(color: Colors.blueAccent),
                activeIndices: active,
                itemScrollController: ItemScrollController(),
                itemPositionsListener: ItemPositionsListener.create(),
                onSubtitleTap: (_) {},
                initialSentenceIndex: 4,
                initialAlignment: .5,
                padding: const EdgeInsets.all(20),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('subtitle-continuous-line-0'));
      final list = find.byType(ScrollablePositionedList);
      expect(
        tester.getTopLeft(first).dy - tester.getTopLeft(list).dy,
        closeTo(20, .5),
      );
      await tester.pumpWidget(const SizedBox());
      active.dispose();
    },
  );

  testWidgets('hit testing maps each same-line sentence to its own index', (
    tester,
  ) async {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: const <String>['one', 'two', 'three'],
    );
    const style = TextStyle(fontSize: 16, height: 1.6);
    const key = ArticleLayoutKey(
      documentGeneration: 1,
      width: 400,
      style: style,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    final layout = const ArticleLayoutEngine().layout(
      document: document,
      key: key,
    );
    final active = ValueNotifier<List<int>>(<int>[]);
    int? tappedIndex;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 120,
          child: ContinuousArticleView(
            document: document,
            layout: layout,
            style: style,
            highlightStyle: style.copyWith(color: Colors.blueAccent),
            activeIndices: active,
            itemScrollController: ItemScrollController(),
            itemPositionsListener: ItemPositionsListener.create(),
            onSubtitleTap: (index) => tappedIndex = index,
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    );
    await tester.pump();

    final lineFinder = find.byKey(const ValueKey('subtitle-continuous-line-0'));
    final lineText = tester.widget<Text>(
      find.byKey(const ValueKey('subtitle-continuous-line-text-0')),
    );
    expect(lineText.overflow, TextOverflow.visible);

    final painter = TextPainter(
      text: TextSpan(text: document.text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 400);
    final second = document.sentenceForDisplayIndex(1)!;
    final secondBox = painter
        .getBoxesForSelection(
          TextSelection(baseOffset: second.start, extentOffset: second.end),
        )
        .single
        .toRect();
    await tester.tapAt(tester.getTopLeft(lineFinder) + secondBox.center);
    await tester.pump();
    expect(tappedIndex, 1);

    tappedIndex = null;
    final separatorX = painter
        .getOffsetForCaret(TextPosition(offset: second.start - 1), Rect.zero)
        .dx;
    await tester.tapAt(
      tester.getTopLeft(lineFinder) + Offset(separatorX, secondBox.center.dy),
    );
    await tester.pump();
    expect(tappedIndex, isNull);

    painter.dispose();
    active.dispose();
  });
}
