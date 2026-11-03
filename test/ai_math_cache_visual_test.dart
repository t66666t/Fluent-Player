import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';

Future<void> _mount(
  WidgetTester tester, {
  required String source,
  bool block = false,
  double scale = 1,
  double fontSize = 14,
  Brightness brightness = Brightness.dark,
  int occurrences = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 600,
              child: AiMathViewport(
                maxWidth: 600,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < occurrences; i++)
                      AiMathFormula(
                        key: ValueKey('formula-$i'),
                        source: source,
                        maxWidth: 600,
                        block: block,
                        textStyle: TextStyle(fontSize: fontSize),
                      ),
                  ],
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

Finder _glyph(String symbol) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText() == symbol,
);

void main() {
  setUp(AiMathCache.reset);

  for (final source in [
    r'A\xrightarrow{f}B',
    r'A\xrightarrow[g]{f}B',
    r'A\xleftarrow{f}B',
    r'A\xrightarrow{\text{上}}B',
    r'A\xrightarrow[\text{下}]{\text{上}}B',
  ]) {
    for (final block in [false, true]) {
      testWidgets(
        'nullable arrow slots render in duplicate ${block ? 'blocks' : 'inlines'}: $source',
        (tester) async {
          await _mount(tester, source: source, block: block, occurrences: 2);
          expect(tester.takeException(), isNull);
          expect(find.byType(AiMathFormula), findsNWidgets(2));
          expect(find.byType(Math), findsWidgets);
          expect(find.textContaining('公式暂无法排版'), findsNothing);
          expect(_glyph('A'), findsNWidgets(2));
          expect(_glyph('B'), findsNWidgets(2));
          if (source.contains('上')) expect(_glyph('上'), findsNWidgets(2));
          if (source.contains('下')) expect(_glyph('下'), findsNWidgets(2));
          expect(AiMathCache.parseCount, 1);
          for (final element in tester.elementList(find.byType(Math))) {
            final size = element.size!;
            expect(size.width, greaterThan(0));
            expect(size.height, greaterThan(0));
          }
          await _mount(
            tester,
            source: source,
            block: block,
            occurrences: 2,
            brightness: Brightness.light,
          );
          expect(tester.takeException(), isNull);
          expect(find.textContaining('公式暂无法排版'), findsNothing);
          expect(_glyph('A'), findsNWidgets(2));
          expect(AiMathCache.parseCount, 1);
        },
      );
    }
  }

  testWidgets('same block occurrence follows a runtime text scaling change', (
    tester,
  ) async {
    await _mount(tester, source: 'x', block: true);
    final originalState = tester.state(find.byType(AiMathFormula));
    final originalGlyph = tester.getSize(_glyph('x'));
    final originalMath = tester.getSize(find.byType(Math));
    await _mount(tester, source: 'x', block: true, scale: 2);
    expect(tester.state(find.byType(AiMathFormula)), same(originalState));
    expect(
      tester.getSize(_glyph('x')).width,
      closeTo(originalGlyph.width * 2, .01),
    );
    expect(
      tester.getSize(_glyph('x')).height,
      closeTo(originalGlyph.height * 2, .01),
    );
    expect(
      tester.getSize(find.byType(Math)).width,
      closeTo(originalMath.width * 2, .1),
    );
    expect(AiMathCache.parseCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same inline occurrence follows an absolute font size change', (
    tester,
  ) async {
    await _mount(tester, source: 'x=1');
    final originalState = tester.state(find.byType(AiMathFormula));
    final originalGlyph = tester.getSize(_glyph('x'));
    await _mount(tester, source: 'x=1', fontSize: 28);
    expect(tester.state(find.byType(AiMathFormula)), same(originalState));
    expect(
      tester.getSize(_glyph('x')).width,
      closeTo(originalGlyph.width * 2, .01),
    );
    expect(
      tester.getSize(_glyph('x')).height,
      closeTo(originalGlyph.height * 2, .01),
    );
    expect(AiMathCache.parseCount, 1);
    expect(tester.takeException(), isNull);
  });
}
