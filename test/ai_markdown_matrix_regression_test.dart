import 'test_artifacts.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';
import 'package:video_player_app/features/ai_chat/ai_math_selection.dart';

// This is the user's original response, including its hard line breaks, Chinese
// punctuation around emphasis, list indentation and all three display blocks.
final _matrixSummary = File(
  'test/fixtures/ai_matrix_summary.md',
).readAsStringSync();

const _inlineSources = <String>[
  r'm\times n',
  'A',
  r'm\times s',
  'B',
  r's\times n',
  'AB',
  r'm\times n',
  'i',
  'j',
  'A',
  'i',
  'B',
  'j',
  r'\det(A+B)',
  r'\det(A)+\det(B)',
];

Finder _formula({required bool block}) => find.byWidgetPredicate(
  (widget) => widget is AiMathFormula && widget.block == block,
);

Finder _element(Element element) =>
    find.byElementPredicate((candidate) => identical(candidate, element));

Future<void> _loadFonts() async {
  for (final name in [
    'Main-Regular',
    'Main-Italic',
    'Math-Italic',
    'AMS-Regular',
    'Size1-Regular',
    'Size2-Regular',
    'Size3-Regular',
    'Size4-Regular',
  ]) {
    final family = name.split('-').first;
    final data = await rootBundle.load(
      'packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_$name.ttf',
    );
    await (FontLoader(
      'packages/flutter_math_fork/KaTeX_$family',
    )..addFont(Future.value(data))).load();
  }
  for (final entry in {
    'MiSans': 'assets/fonts/MiSans-Regular.otf',
    'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
    'monospace':
        'packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_Typewriter-Regular.ttf',
  }.entries) {
    await (FontLoader(entry.key)..addFont(rootBundle.load(entry.value))).load();
  }
}

Future<void> _mount(
  WidgetTester tester,
  String source, {
  double width = 630,
  double scale = 1,
  bool streaming = false,
  ValueChanged<Duration>? onSeek,
  GlobalKey? capture,
}) async {
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.binding.setSurfaceSize(Size(width, 1400));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.windows,
        brightness: Brightness.dark,
        fontFamily: 'MiSans',
      ),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: const Color(0xff191919),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: AiMarkdown(
                    data: source,
                    isStreaming: streaming,
                    onSeek: onSeek,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Iterable<RichText> _richTexts(WidgetTester tester) =>
    tester.widgetList<RichText>(find.byType(RichText));

String _visibleText(WidgetTester tester) =>
    _richTexts(tester).map((rich) => rich.text.toPlainText()).join('\n');

TextStyle? _styleContaining(
  InlineSpan span,
  String text, [
  TextStyle? inherited,
]) {
  final style = inherited?.merge(span.style) ?? span.style;
  if (span is! TextSpan) return null;
  if (span.text?.contains(text) ?? false) return style;
  for (final child in span.children ?? <InlineSpan>[]) {
    final found = _styleContaining(child, text, style);
    if (found != null) return found;
  }
  return null;
}

// A paragraph containing WidgetSpans cannot necessarily provide a dry baseline:
// the TeX renderer has custom render boxes without dry baseline support. The
// ordinary Chinese glyph has known metrics, however. Derive the distance from
// its tight selection box to its alphabetic baseline with TextPainter, then
// apply that offset to the actual glyph box in the production paragraph.
double _proseGlyphBaseline(Element element, String text) {
  final rich = element.widget as RichText;
  final paragraph = element.findRenderObject()! as RenderParagraph;
  final plain = rich.text.toPlainText();
  final start = plain.indexOf(text);
  expect(start, greaterThanOrEqualTo(0));
  final selected = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: start + text.length),
  );
  expect(selected, hasLength(1));
  final painter = TextPainter(
    text: TextSpan(text: text, style: _styleContaining(rich.text, text)),
    textDirection: rich.textDirection ?? Directionality.of(element),
    textScaler: rich.textScaler,
    strutStyle: rich.strutStyle,
    textHeightBehavior: rich.textHeightBehavior,
  )..layout();
  final referenceBox = painter
      .getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: text.length),
      )
      .single;
  final baselineWithinBox =
      painter.computeLineMetrics().single.baseline - referenceBox.top;
  painter.dispose();
  // localToGlobal transforms the complete baseline point, including any
  // ancestor scaling, instead of adding an unscaled distance to a global y.
  return paragraph
      .localToGlobal(Offset(0, selected.single.top + baselineWithinBox))
      .dy;
}

Iterable<RenderParagraph> _mathGlyphParagraphs(
  WidgetTester tester,
  Finder math,
) sync* {
  for (final element in tester.elementList(
    find.descendant(of: math, matching: find.byType(RichText)),
  )) {
    final paragraph = element.findRenderObject();
    if (paragraph is RenderParagraph &&
        paragraph.text.toPlainText().trim().isNotEmpty &&
        !paragraph.text.toPlainText().contains('\uFFFC')) {
      yield paragraph;
    }
  }
}

String _boldText(InlineSpan span, [TextStyle? inherited]) {
  final style = inherited?.merge(span.style) ?? span.style;
  final own = span is TextSpan ? span.text ?? '' : '';
  return '${(style?.fontWeight?.value ?? 0) >= FontWeight.w600.value ? own : ''}'
      '${span is TextSpan ? (span.children ?? <InlineSpan>[]).map((child) => _boldText(child, style)).join() : ''}';
}

List<Rect> _textBoxes(WidgetTester tester, String needle) {
  final result = <Rect>[];
  for (final element in tester.elementList(find.byType(RichText))) {
    final widget = element.widget as RichText;
    final text = widget.text.toPlainText();
    final render = element.findRenderObject();
    if (render is! RenderParagraph || !render.hasSize) continue;
    var start = text.indexOf(needle);
    while (start != -1) {
      final boxes = render.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + needle.length),
      );
      result.addAll(
        boxes.map(
          (box) => box.toRect().shift(render.localToGlobal(Offset.zero)),
        ),
      );
      start = text.indexOf(needle, start + needle.length);
    }
  }
  return result;
}

void _expectNonzero(Rect rect, String reason) {
  expect(
    rect.width,
    greaterThan(.1),
    reason: '$reason must have visible width',
  );
  expect(
    rect.height,
    greaterThan(.1),
    reason: '$reason must have visible height',
  );
}

void _expectHorizontalBounds(Rect rect, double width, String reason) {
  expect(rect.left, greaterThanOrEqualTo(11.5), reason: reason);
  expect(rect.right, lessThanOrEqualTo(width - 11.5), reason: reason);
}

Future<void> _expectInlineGeometry(
  WidgetTester tester,
  double width, {
  bool allowIndivisibleOverflow = false,
}) async {
  final inline = tester.elementList(_formula(block: false)).toList();
  expect(
    inline.map((element) => (element.widget as AiMathFormula).source.trim()),
    _inlineSources,
    reason: 'Every original inline formula must survive Markdown parsing',
  );
  Rect? previous;
  double? previousBaseline;
  for (final element in inline) {
    final source = (element.widget as AiMathFormula).source;
    final finder = _element(element);
    final rect = tester.getRect(finder);
    _expectNonzero(rect, source);
    _expectHorizontalBounds(rect, width, source);
    final math = find.descendant(of: finder, matching: find.byType(Math));
    expect(math, findsOneWidget, reason: 'Inline $source must be typeset');
    final glyphRect = tester.getRect(math);
    _expectNonzero(glyphRect, 'typeset $source');
    if (allowIndivisibleOverflow && glyphRect.width > rect.width + .5) {
      await _expectAccessibleOverflow(tester, finder, math, rect, source);
    } else {
      _expectHorizontalBounds(glyphRect, width, 'typeset $source');
    }
    final firstGlyph = _mathGlyphParagraphs(tester, math).first;
    final baseline = firstGlyph
        .localToGlobal(
          Offset(
            0,
            firstGlyph.getDryBaseline(
              firstGlyph.constraints,
              TextBaseline.alphabetic,
            )!,
          ),
        )
        .dy;
    // Compare baselines rather than box centers: B and m×s have different
    // natural ascents, particularly at 2× text scaling.
    if (previous != null) {
      expect(
        baseline,
        greaterThanOrEqualTo(previousBaseline! - .5),
        reason: '$source must not jump above the preceding formula',
      );
      if ((baseline - previousBaseline).abs() < .5) {
        expect(
          glyphRect.left,
          greaterThanOrEqualTo(previous.right - .5),
          reason: '$source must not overlap a previous inline formula',
        );
      }
    }
    previous = glyphRect;
    previousBaseline = baseline;
  }
}

Future<void> _expectAccessibleOverflow(
  WidgetTester tester,
  Finder formula,
  Finder content,
  Rect viewport,
  String source,
) async {
  final scrolls = tester
      .stateList<ScrollableState>(
        find.descendant(of: formula, matching: find.byType(Scrollable)),
      )
      .where(
        (scroll) =>
            axisDirectionToAxis(scroll.position.axisDirection) ==
            Axis.horizontal,
      )
      .toList();
  expect(scrolls, hasLength(1), reason: source);
  final scroll = scrolls.single;
  expect(scroll.position.maxScrollExtent, greaterThan(0), reason: source);
  final first = tester.renderObject<RenderBox>(content.first);
  final clipper = RenderAbstractViewport.of(first) as RenderBox;
  final clip = clipper.describeApproximatePaintClip(first);
  expect(clip, isNotNull, reason: 'Overflow must be clipped locally: $source');
  expect(clip!.width, closeTo(clipper.size.width, .5));
  scroll.position.jumpTo(scroll.position.maxScrollExtent);
  await tester.pump();
  // All right edges, including the last glyph of an indivisible term, must be
  // reachable. A full-width natural Math box is allowed behind the local clip.
  for (final element in tester.elementList(content)) {
    expect(
      tester.getRect(_element(element)).right,
      lessThanOrEqualTo(viewport.right + .5),
      reason: 'The right end must be reachable by scrolling: $source',
    );
  }
  scroll.position.jumpTo(0);
  await tester.pump();
}

Future<void> _expectBlockGeometry(
  WidgetTester tester,
  double width, {
  bool allowIndivisibleOverflow = false,
}) async {
  final blocks = tester.elementList(_formula(block: true)).toList();
  expect(
    blocks.length,
    3,
    reason: 'The original contains three display blocks',
  );
  for (final element in blocks) {
    final source = (element.widget as AiMathFormula).source;
    final finder = _element(element);
    final viewport = tester.getRect(
      find.descendant(of: finder, matching: find.byType(AiSelectableMath)),
    );
    _expectNonzero(viewport, 'display viewport');
    _expectHorizontalBounds(viewport, width, 'list-local display viewport');
    final maths = find.descendant(of: finder, matching: find.byType(Math));
    final parts = tester
        .elementList(maths)
        .map((element) => tester.getRect(_element(element)))
        .toList();
    final detail =
        '$source; viewport=${viewport.width}; '
        'part widths=${parts.map((rect) => rect.width).toList()}';
    final naturallyOversized =
        allowIndivisibleOverflow &&
        parts.any((rect) => rect.width > viewport.width + .5);
    // At normal widths all these equalities must wrap without scrolling.
    // Only the explicitly exercised 180px/2x extreme permits an indivisible
    // mathematical term to use a clipped, accessible horizontal viewport.
    for (final scroll in tester.stateList<ScrollableState>(
      find.descendant(of: finder, matching: find.byType(Scrollable)),
    )) {
      if (axisDirectionToAxis(scroll.position.axisDirection) ==
          Axis.horizontal) {
        if (!naturallyOversized) {
          expect(
            scroll.position.maxScrollExtent,
            closeTo(0, .5),
            reason:
                'Breakable identities must use the list-local width: $detail',
          );
        }
      }
    }
    if (naturallyOversized) {
      await _expectAccessibleOverflow(tester, finder, maths, viewport, detail);
    }
    for (final math in tester.elementList(
      find.descendant(of: finder, matching: find.byType(Math)),
    )) {
      final rect = tester.getRect(_element(math));
      _expectNonzero(rect, 'display math term');
      expect(
        rect.left,
        greaterThanOrEqualTo(viewport.left - .5),
        reason: detail,
      );
      if (!naturallyOversized) {
        expect(
          rect.right,
          lessThanOrEqualTo(viewport.right + .5),
          reason: detail,
        );
      }
      expect(rect.top, greaterThanOrEqualTo(viewport.top - .5), reason: detail);
      expect(
        rect.bottom,
        lessThanOrEqualTo(viewport.bottom + .5),
        reason: detail,
      );
    }
  }
}

Future<void> _writeScreenshot(
  WidgetTester tester,
  GlobalKey capture,
  String name,
) => tester.runAsync(() async {
  final boundary =
      capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final picture = await boundary.toImage();
  final png = await picture.toByteData(format: ui.ImageByteFormat.png);
  final output = testArtifact('$name.png');
  await output.parent.create(recursive: true);
  await output.writeAsBytes(png!.buffer.asUint8List());
  picture.dispose();
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AiMathCache.reset);

  testWidgets('Chinese punctuation adjacent to strong emphasis stays styled', (
    tester,
  ) async {
    await _mount(tester, _matrixSummary);
    final text = _visibleText(tester);
    expect(text, isNot(contains('**')));
    final bold = _richTexts(tester).map((rich) => _boldText(rich.text)).join();
    for (final plain in ['这节课以', '为主线，介绍矩阵的基本运算。', '固定大小的', '转置就是交换行、列']) {
      expect(
        bold,
        isNot(contains(plain)),
        reason: 'Strong style must not leak to $plain',
      );
    }
    for (final expected in [
      '“矩阵计算不仅要会算，更要理解运算律”',
      '乘法一般不满足交换律',
      '颠倒乘法顺序',
      '把矩阵的加法、数乘作为基础，再理解乘法、转置、幂等运算及其相互关系，而不是把公式孤立地死记硬背。',
      '行列式不是绝对值；类似“大小”的概念应由范数描述。',
      '学习时需注意：',
    ]) {
      expect(
        bold,
        contains(expected),
        reason: '$expected must actually be bold',
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('short inline math shares the prose baseline and reading order', (
    tester,
  ) async {
    const sentence =
        r'若 \(A\) 为 \(m\times s\)，\(B\) 为 \(s\times n\)，则 \(AB\) 为 \(m\times n\)。';
    for (final scale in [1.0, 2.0]) {
      await _mount(tester, sentence, width: 1200, scale: scale);
      final proseElements = tester
          .elementList(find.byType(RichText))
          .where(
            (element) =>
                (element.widget as RichText).text.toPlainText().startsWith('若'),
          );
      expect(proseElements, hasLength(1));
      final prose = proseElements.single.findRenderObject()! as RenderParagraph;
      expect(
        prose.text.toPlainText(),
        contains('为'),
        reason:
            'Math must remain in the same paragraph as the complete sentence',
      );
      final proseBaseline = _proseGlyphBaseline(proseElements.single, '若');
      final firstGlyph = _textBoxes(tester, '若').single;
      Rect previous = firstGlyph;
      for (final element in tester.elementList(_formula(block: false))) {
        final math = find.descendant(
          of: _element(element),
          matching: find.byType(Math),
        );
        expect(math, findsOneWidget);
        final rect = tester.getRect(math);
        _expectNonzero(rect, (element.widget as AiMathFormula).source);
        expect(rect.left, greaterThan(previous.right));
        expect(
          rect.overlaps(
            Rect.fromLTRB(0, firstGlyph.top, 1200, firstGlyph.bottom),
          ),
          isTrue,
        );
        final glyphs = _mathGlyphParagraphs(tester, math).toList();
        expect(glyphs, isNotEmpty);
        for (final glyph in glyphs) {
          // Leaf RenderParagraphs have no WidgetSpans. Their public dry
          // baseline API is valid outside layout, unlike getDistanceToBaseline.
          final baseline = glyph.getDryBaseline(
            glyph.constraints,
            TextBaseline.alphabetic,
          );
          expect(baseline, isNotNull);
          expect(
            glyph.localToGlobal(Offset(0, baseline!)).dy,
            closeTo(proseBaseline, 1.5),
            reason:
                'The actual ${glyph.text.toPlainText()} glyph must share '
                'the prose baseline at ${scale}x',
          );
        }
        previous = rect;
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'a short list sentence does not strand its dimension on a new line',
    (tester) async {
      await _mount(
        tester,
        '1. **矩阵与线性空间**  \n   固定大小的 \\(m\\times n\\) 矩阵。',
        width: 300,
      );
      final lead = _textBoxes(tester, '固定大小的').single;
      final tail = _textBoxes(tester, '矩阵。').single;
      final math = tester.getRect(find.byType(Math));
      expect(lead.top, closeTo(tail.top, 1));
      expect(math.left, greaterThan(lead.right));
      expect(math.right, lessThan(tail.left));
      expect(math.center.dy, inInclusiveRange(lead.top, lead.bottom));
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [180.0, 300.0, 630.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('original matrix summary is intact at ${width}px / ${scale}x', (
        tester,
      ) async {
        await tester.runAsync(_loadFonts);
        final capture = GlobalKey();
        await _mount(
          tester,
          _matrixSummary,
          width: width,
          scale: scale,
          capture: capture,
          onSeek: (_) {},
        );
        // Always write the full original before assertions, so any regression
        // leaves a reviewable image rather than suppressing its debug evidence.
        await _writeScreenshot(
          tester,
          capture,
          'matrix-summary-${width.toInt()}-${scale.toInt()}x',
        );
        final allowIndivisibleOverflow = width == 180 && scale == 2;
        await _expectInlineGeometry(
          tester,
          width,
          allowIndivisibleOverflow: allowIndivisibleOverflow,
        );
        await _expectBlockGeometry(
          tester,
          width,
          allowIndivisibleOverflow: allowIndivisibleOverflow,
        );
        final visible = _visibleText(tester);
        expect(visible, isNot(contains('**')));
        expect(visible, contains('核心结论'));
        expect(visible, contains('这些不宜直接当作定义记忆。'));
        expect(visible, isNot(contains('公式暂无法排版')));
        expect(visible, isNot(contains('公式未闭合')));
        for (final timestamp in [
          '00:11:12',
          '00:15:56',
          '00:19:16',
          '00:28:52',
          '00:28:59',
          '00:37:23',
          '00:41:09',
          '00:46:19',
          '00:46:26',
          '00:48:29',
        ]) {
          expect(visible, contains(timestamp));
        }
        // A formula may start below the fold. Scrolling it into view must reveal
        // the actual glyphs, rather than a zero-sized or clipped placeholder.
        for (final element
            in tester.elementList(_formula(block: false)).toList()) {
          await tester.ensureVisible(_element(element));
          await tester.pumpAndSettle();
          final rect = tester.getRect(
            find.descendant(of: _element(element), matching: find.byType(Math)),
          );
          expect(rect.top, greaterThanOrEqualTo(-.5));
          expect(rect.bottom, lessThanOrEqualTo(1400.5));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets(
    'code, escaped dollars, citation taps and link labels survive math',
    (tester) async {
      Duration? sought;
      const source =
          r'代码 `$x$`，价格 \$5 与 \$10；公式 \(x+1\)；链接 [项目](https://example.com/$path)。来源：[00:11:12]–[00:15:56]。'
          '\n\n```dart\n'
          r'final amount = "$not_math$";'
          '\n```';
      await _mount(tester, source, onSeek: (value) => sought = value);
      expect(
        tester
            .widgetList<AiMathFormula>(_formula(block: false))
            .map((formula) => formula.source),
        ['x+1'],
      );
      final text = _visibleText(tester);
      for (final expected in [
        r'$x$',
        r'$5',
        r'$10',
        r'final amount = "$not_math$";',
        '项目',
        '00:11:12',
        '00:15:56',
      ]) {
        expect(text, contains(expected));
      }
      expect(text, isNot(contains(r'\$5')));
      expect(find.byTooltip('复制代码'), findsOneWidget);
      final linkSpans = <TextSpan>[];
      void collect(InlineSpan span) {
        if (span is TextSpan) {
          if (span.text == '项目') linkSpans.add(span);
          span.children?.forEach(collect);
        }
      }

      for (final rich in _richTexts(tester)) {
        collect(rich.text);
      }
      expect(linkSpans, hasLength(1));
      expect(linkSpans.single.recognizer, isA<TapGestureRecognizer>());
      final timestamp = _textBoxes(tester, '00:11:12').single;
      _expectNonzero(timestamp, 'clickable timestamp');
      await tester.tapAt(timestamp.center);
      await tester.pumpAndSettle();
      expect(sought, const Duration(minutes: 11, seconds: 12));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an indivisible wide matrix reserves room for its scrollbar', (
    tester,
  ) async {
    const source =
        r'\[\begin{pmatrix}a_{11}&a_{12}&a_{13}&a_{14}&a_{15}&a_{16}\\a_{21}&a_{22}&a_{23}&a_{24}&a_{25}&a_{26}\end{pmatrix}\]';
    await _mount(tester, source, width: 180);
    final formula = _formula(block: true);
    final horizontal = find.descendant(
      of: formula,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal,
      ),
    );
    expect(horizontal, findsOneWidget);
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: horizontal, matching: find.byType(Scrollable)),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    final viewport = tester.getRect(horizontal);
    _expectHorizontalBounds(viewport, 180, 'unbreakable matrix local viewport');
    final glyphs = tester.getRect(
      find.descendant(of: formula, matching: find.byType(Math)),
    );
    expect(
      viewport.bottom - glyphs.bottom,
      greaterThanOrEqualTo(8),
      reason: 'The desktop scrollbar must not paint over the formula glyphs',
    );
    await tester.drag(horizontal, const Offset(-80, 0));
    await tester.pump();
    expect(scroll.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'streamed original preserves all completed math and final layout',
    (tester) async {
      final inline = RegExp(r'\\\((.*?)\\\)', dotAll: true);
      for (var end = 37; end < _matrixSummary.length; end += 53) {
        final partial = _matrixSummary.substring(0, end);
        await _mount(tester, partial, width: 300, streaming: true);
        final expected = inline
            .allMatches(partial)
            .map((match) => match.group(1)!.trim());
        final actual = tester
            .widgetList<AiMathFormula>(_formula(block: false))
            .where((formula) => formula.complete)
            .map((formula) => formula.source.trim());
        expect(
          actual,
          expected,
          reason: 'Completed inline math disappeared at character $end',
        );
        for (final element in tester.elementList(_formula(block: false))) {
          final formula = element.widget as AiMathFormula;
          if (!formula.complete || formula.source.trim().isEmpty) continue;
          final rect = tester.getRect(_element(element));
          _expectNonzero(rect, 'stream frame $end');
          _expectHorizontalBounds(rect, 300, 'stream frame $end');
        }
        expect(tester.takeException(), isNull, reason: 'Stream character $end');
      }
      await _mount(tester, _matrixSummary, width: 300);
      await _expectInlineGeometry(tester, 300);
      await _expectBlockGeometry(tester, 300);
      expect(_visibleText(tester), isNot(contains('**')));
      expect(tester.takeException(), isNull);
    },
  );
}
