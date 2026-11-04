import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';

bool _fontsLoaded = false;

Future<void> _loadFonts() async {
  if (_fontsLoaded) return;
  for (final family in <String, List<String>>{
    'Main': ['Regular', 'Italic', 'Bold', 'BoldItalic'],
    'Math': ['Italic', 'BoldItalic'],
    'AMS': ['Regular'],
    'Size1': ['Regular'],
    'Size2': ['Regular'],
    'Size3': ['Regular'],
    'Size4': ['Regular'],
  }.entries) {
    final loader = FontLoader('packages/flutter_math_fork/KaTeX_${family.key}');
    for (final face in family.value) {
      loader.addFont(
        rootBundle.load(
          'packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_${family.key}-$face.ttf',
        ),
      );
    }
    await loader.load();
  }
  await (FontLoader('MiSans')
        ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))
        ..addFont(rootBundle.load('assets/fonts/MiSans-Bold.otf')))
      .load();
  _fontsLoaded = true;
}

Future<void> _mount(
  WidgetTester tester,
  Widget child, {
  double width = 900,
  double scale = 1,
}) async {
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(_loadFonts);
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
            child: Padding(padding: const EdgeInsets.all(12), child: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _element(Element element) =>
    find.byElementPredicate((candidate) => identical(element, candidate));

Iterable<Element> _prose(WidgetTester tester) => tester
    .elementList(find.byType(RichText))
    .where(
      (element) =>
          (element.widget as RichText).text.toPlainText().contains('正文'),
    );

List<Rect> _glyphBoxes(Element element, {String? needle}) {
  final widget = element.widget as RichText;
  final paragraph = element.findRenderObject()! as RenderParagraph;
  final text = widget.text.toPlainText();
  final transform = paragraph.getTransformTo(null);
  final ranges = <(int, int)>[];
  if (needle != null) {
    final start = text.indexOf(needle);
    expect(start, greaterThanOrEqualTo(0));
    ranges.add((start, start + needle.length));
  } else {
    for (var index = 0; index < text.length; index++) {
      if (text[index].trim().isNotEmpty && text.codeUnitAt(index) != 0xfffc) {
        ranges.add((index, index + 1));
      }
    }
  }
  return [
    for (final range in ranges)
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: range.$1, extentOffset: range.$2),
      ))
        MatrixUtils.transformRect(transform, box.toRect()),
  ];
}

bool _overlap(Rect a, Rect b) {
  final intersection = a.intersect(b);
  return intersection.width > .5 && intersection.height > .5;
}

List<(TextSpan, TextStyle?)> _textLeaves(
  InlineSpan span, [
  TextStyle? inherited,
]) {
  final style = inherited?.merge(span.style) ?? span.style;
  if (span is! TextSpan) return const [];
  return [
    if (span.text?.isNotEmpty ?? false) (span, style),
    for (final child in span.children ?? <InlineSpan>[])
      ..._textLeaves(child, style),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AiMathCache.reset);

  testWidgets(
    'tall inline fractions and scripts never overlap neighboring text lines',
    (tester) async {
      const source =
          '上行正文：矩阵运算应保持清晰，所有字符都应完整显示。  \n'
          r'中行正文：\(\dfrac{1+\frac{a}{b}}{\frac{c}{d}+\frac{e}{f}}\)'
          r' 与 \(x_{i_j}^{n^{k+1}}\) 必须留出上下空间。'
          '  \n下行正文：分子与分母都不能盖住这一行。';
      for (final width in [240.0, 500.0]) {
        for (final scale in [1.0, 2.0]) {
          await _mount(
            tester,
            const AiMarkdown(data: source),
            width: width,
            scale: scale,
          );
          expect(tester.takeException(), isNull);
          final prose = _prose(tester).single;
          final textBoxes = _glyphBoxes(prose);
          final formulas = tester
              .elementList(find.byType(AiMathFormula))
              .map((element) => tester.getRect(_element(element)))
              .toList();
          expect(formulas, hasLength(2));
          for (var index = 0; index < formulas.length; index++) {
            final formula = formulas[index];
            expect(formula.width, greaterThan(1));
            expect(formula.height, greaterThan(1));
            for (final textBox in textBoxes) {
              expect(
                _overlap(formula, textBox),
                isFalse,
                reason:
                    'Formula $index $formula overlaps prose $textBox at '
                    '${width}px / ${scale}x. Line height must include the '
                    'actual ascent and descent of inline math.',
              );
            }
            for (final other in formulas.skip(index + 1)) {
              expect(
                _overlap(formula, other),
                isFalse,
                reason: 'Inline formulas must not overlap each other',
              );
            }
          }
        }
      }
    },
  );

  testWidgets(
    'nested bold italic links retain every text and math span and destination',
    (tester) async {
      final seeks = <Duration>[];
      await _mount(
        tester,
        AiMarkdown(
          data:
              r'正文 [**粗体 *斜体 \(A+\frac{b}{c}\)* 尾部 00:04**](video://seek?ms=12000) 结束。',
          onSeek: seeks.add,
        ),
      );
      expect(tester.takeException(), isNull);
      final prose = _prose(tester).single;
      final rich = prose.widget as RichText;
      final text = rich.text.toPlainText();
      expect(text, contains('粗体 斜体'));
      expect(text, contains('尾部 00:04'));
      expect(text, isNot(contains('**')));
      final leaves = _textLeaves(rich.text);
      (TextSpan, TextStyle?) leaf(String label) =>
          leaves.firstWhere((entry) => entry.$1.text!.contains(label));
      final bold = leaf('粗体');
      final italic = leaf('斜体');
      final tail = leaf('尾部');
      expect(bold.$2?.fontWeight, FontWeight.bold);
      expect(italic.$2?.fontWeight, FontWeight.bold);
      expect(italic.$2?.fontStyle, FontStyle.italic);
      expect(tail.$2?.fontWeight, FontWeight.bold);
      expect(identical(bold.$1.recognizer, italic.$1.recognizer), isTrue);
      expect(identical(bold.$1.recognizer, tail.$1.recognizer), isTrue);
      expect(bold.$1.recognizer, isA<TapGestureRecognizer>());
      final formula = tester.widget<AiMathFormula>(find.byType(AiMathFormula));
      expect(formula.source, r'A+\frac{b}{c}');
      expect(formula.textStyle?.fontWeight, FontWeight.bold);
      expect(formula.textStyle?.fontStyle, FontStyle.italic);
      await tester.tapAt(_glyphBoxes(prose, needle: '粗体').single.center);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(AiMathFormula));
      await tester.pumpAndSettle();
      await tester.tapAt(_glyphBoxes(prose, needle: '尾部').single.center);
      await tester.pumpAndSettle();
      expect(seeks, List.filled(3, const Duration(seconds: 12)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repeated fractions matrices CJK and phantoms render independently across themes',
    (tester) async {
      const sources = [
        r'\frac{a+b}{c+d}',
        r'\begin{pmatrix}a&b\\c&d\end{pmatrix}',
        r'\text{中文}+x',
        r'\phantom{x^2}+y',
      ];
      final inline = [
        for (var repeat = 0; repeat < 2; repeat++)
          for (final source in sources) '\\($source\\)',
      ].join('，');
      final blocks = [
        for (var repeat = 0; repeat < 2; repeat++)
          for (final source in sources) '\\[\n$source\n\\]',
      ].join('\n\n');
      final markdown = '正文 $inline。\n\n$blocks';
      await _mount(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final brightness in [Brightness.light, Brightness.dark])
              Theme(
                data: ThemeData(
                  platform: TargetPlatform.windows,
                  brightness: brightness,
                  fontFamily: 'MiSans',
                ),
                child: AiMarkdown(data: markdown),
              ),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
      final formulas = tester.elementList(find.byType(AiMathFormula)).toList();
      expect(formulas, hasLength(32));
      final dimensions = <(String, bool), List<Size>>{};
      for (final element in formulas) {
        final formula = element.widget as AiMathFormula;
        final finder = _element(element);
        final rect = tester.getRect(finder);
        expect(rect.width, greaterThan(1), reason: formula.source);
        expect(rect.height, greaterThan(1), reason: formula.source);
        dimensions
            .putIfAbsent((formula.source, formula.block), () => [])
            .add(rect.size);
        final maths = tester.widgetList<Math>(
          find.descendant(of: finder, matching: find.byType(Math)),
        );
        expect(maths, isNotEmpty);
        for (final math in maths) {
          expect(math.parseError, isNull, reason: formula.source);
          expect(
            math.textStyle?.color,
            Theme.of(element).colorScheme.onSurface,
            reason: 'Cached trees must not retain a different theme color',
          );
        }
        final text = tester
            .widgetList<RichText>(
              find.descendant(of: finder, matching: find.byType(RichText)),
            )
            .map((widget) => widget.text.toPlainText())
            .join();
        expect(text, isNot(contains('公式暂无法排版')), reason: formula.source);
        expect(text.trim(), isNotEmpty, reason: formula.source);
        if (formula.source.contains('中文')) expect(text, contains('中文'));
      }
      for (final sizes in dimensions.values) {
        expect(sizes, hasLength(4));
        for (final size in sizes.skip(1)) {
          expect(size.width, closeTo(sizes.first.width, .01));
          expect(size.height, closeTo(sizes.first.height, .01));
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '2x text scaling scales both prose and inline math exactly once',
    (tester) async {
      const markdown = AiMarkdown(data: r'正文 \(A+\frac{b}{c}\) 尾文。');
      final formulaSizes = <Size>[];
      final textSizes = <Size>[];
      for (final scale in [1.0, 2.0]) {
        await _mount(tester, markdown, width: 1200, scale: scale);
        final rect = tester.getRect(find.byType(AiMathFormula));
        formulaSizes.add(rect.size);
        textSizes.add(
          _glyphBoxes(_prose(tester).single, needle: '正文').single.size,
        );
        expect(tester.takeException(), isNull);
      }
      expect(formulaSizes[1].width, closeTo(formulaSizes[0].width * 2, .1));
      expect(formulaSizes[1].height, closeTo(formulaSizes[0].height * 2, .1));
      // Text glyphs can round to a physical half-pixel at a different font
      // size; the formula viewport itself must still scale exactly once.
      expect(textSizes[1].width, closeTo(textSizes[0].width * 2, .75));
      expect(textSizes[1].height, closeTo(textSizes[0].height * 2, .75));
    },
  );
}
