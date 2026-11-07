import 'test_artifacts.dart';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_math_fork/ast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';
import 'package:video_player_app/features/ai_chat/ai_math_selection.dart';
import 'package:video_player_app/features/ai_chat/ai_math_syntax.dart';

List<md.Element> mathNodes(String source) {
  final document = md.Document(
    blockSyntaxes: const [AiMathBlockSyntax()],
    inlineSyntaxes: [AiMathInlineSyntax()],
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  final result = <md.Element>[];
  void visit(md.Node node) {
    if (node is md.Element) {
      if ({aiInlineMathTag, aiDisplayMathTag}.contains(node.tag)) {
        result.add(node);
      }
      for (final child in node.children ?? <md.Node>[]) {
        visit(child);
      }
    }
  }

  document.parseLines(const LineSplitter().convert(source)).forEach(visit);
  return result;
}

String mathText(Math math) {
  String text(GreenNode node) {
    if (node is PhantomNode) return '';
    if (node is SymbolNode) return node.symbol;
    return node.children.whereType<GreenNode>().map(text).join();
  }

  return text(math.ast!.greenRoot);
}

const _sample = r'''
# 数学与视频笔记

行内关系 $E=mc^2$，分数 \(\frac{a}{b}\) 与概率 \(P(A\mid B)\)。

## 二次方程

\[
x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}
\]

## 矩阵与分段函数

$$
\begin{pmatrix}1 & 2 \\ 3 & 4\end{pmatrix}
\quad
f(x)=\begin{cases}x^2 & \text{当 }x\geq 0 \\ -x & \text{当 }x<0\end{cases}
$$

## 推导与积分

\begin{align*}
S_n &= \sum_{k=1}^{n} k \\
    &= \frac{n(n+1)}{2}
\end{align*}

\[
\int_0^1 x^2\,\mathrm{d}x=\frac{1}{3}
\]

| 含义 | 公式 |
| --- | --- |
| 均值 | $\mu=\frac{1}{n}\sum_i x_i$ |

```latex
\lim_{n\to\infty}\left(1+\frac{1}{n}\right)^n=e
```

代码中的 `$x$` 保留原文，价格 $5 与 $10 也保留。
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AiMathCache.reset);
  Map<String, dynamic>? clipboard;
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = Map<String, dynamic>.from(call.arguments as Map);
          }
          if (call.method == 'Clipboard.getData') return clipboard;
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  test(
    'supports both inline delimiters and both standalone display delimiters',
    () {
      final nodes = mathNodes(
        r'a $x_1^2$ b \(\frac{a}{b}\)'
        '\n\n'
        r'$$x+y$$'
        '\n\n'
        r'\[\sqrt{x}\]',
      );
      expect(nodes.map((node) => node.tag), [
        aiInlineMathTag,
        aiInlineMathTag,
        aiDisplayMathTag,
        aiDisplayMathTag,
      ]);
      expect(nodes[1].textContent, r'\frac{a}{b}');
      expect(
        nodes.every((node) => node.attributes['complete'] == 'true'),
        isTrue,
      );
    },
  );

  test(
    'preserves code, escaped dollars, links and prices mixed with real math',
    () {
      final source =
          r'`$code$` \$5 and $10 and $20 plus $x^2$.'
          '\n\n'
          '```python\n'
          r'print("$$not math$$")'
          '\n```\n\n'
          r'[Download](https://example.com/$path)';
      final nodes = mathNodes(source);
      expect(nodes.length, 1);
      expect(nodes.single.textContent, 'x^2');
      expect(mathNodes(r'$5 and $10'), isEmpty);
    },
  );

  test(
    'retains formulas in lists, quotations and tables without Markdown consuming TeX',
    () {
      final nodes = mathNodes(
        r'- **意义**：$x_1+x_2$'
        '\n\n'
        r'> \(a*b\)'
        '\n\n'
        '| A | B |\n|---|---|\n'
        r'| $a$ | $b$ |',
      );
      expect(nodes.map((node) => node.textContent), [
        'x_1+x_2',
        'a*b',
        'a',
        'b',
      ]);
    },
  );

  test(
    'unclosed display does not swallow a following paragraph and valid blank lines work',
    () {
      final nodes = mathNodes(
        r'\['
        '\n'
        r'\frac{a}{b}'
        '\n\n后续说明',
      );
      expect(nodes.single.attributes['complete'], 'false');
      expect(nodes.single.textContent, isNot(contains('后续说明')));
      final blank = mathNodes(
        r'$$'
        '\na\n\nb\n'
        r'$$',
      );
      expect(blank.single.attributes['complete'], 'true');
      expect(blank.single.textContent, 'a\n\nb');
    },
  );

  test(
    'AMS wrappers, matrices and cases parse with bounded macro expansion',
    () {
      for (final formula in [
        r'\begin{equation}E=mc^2\end{equation}',
        r'\begin{align*}a&=b+c\\&=d\end{align*}',
        r'\begin{gather}a=b\\c=d\end{gather}',
        r'\begin{pmatrix}1&2\\3&4\end{pmatrix}',
        r'\begin{cases}x&x>0\\0&x\leq0\end{cases}',
      ]) {
        expect(
          AiMathCache.parse(formula, display: true).parseError,
          isNull,
          reason: formula,
        );
      }
      expect(
        AiMathCache.parse(r'\def\a{\a}\a', display: true).parseError,
        isNotNull,
      );
    },
  );

  test('cache reuses good and invalid parses and has two memory bounds', () {
    final first = AiMathCache.parse(r'\frac{x}{y}', display: true);
    for (var i = 0; i < 1000; i++) {
      expect(
        identical(AiMathCache.parse(r'\frac{x}{y}', display: true), first),
        isTrue,
      );
    }
    expect(AiMathCache.parseCount, 1);
    AiMathCache.parse(r'\unsupportedcommand{x}', display: false);
    AiMathCache.parse(r'\unsupportedcommand{x}', display: false);
    expect(AiMathCache.parseCount, 2);
    for (var i = 0; i < 140; i++) {
      AiMathCache.parse('x_{$i}', display: false);
    }
    expect(AiMathCache.entryCount, AiMathCache.maxEntries);
    for (var i = 0; i < 80; i++) {
      AiMathCache.parse('\\text{${'a' * 900}$i}', display: true);
    }
    expect(
      AiMathCache.characterCount,
      lessThanOrEqualTo(AiMathCache.maxCharacters),
    );
    expect(AiMathCache.entryCount, lessThan(AiMathCache.maxEntries));
  });

  test('records cold parsing and warm cache cost without reparsing', () async {
    final formulas = List.generate(
      100,
      (i) => '\\frac{x_{$i}^2+1}{\\sqrt{y_{$i}}}+\\sum_{k=1}^{n}k',
    );
    final cold = Stopwatch()..start();
    for (final source in formulas) {
      AiMathCache.parse(source, display: true);
    }
    cold.stop();
    final warm = Stopwatch()..start();
    for (var i = 0; i < 50; i++) {
      for (final source in formulas) {
        AiMathCache.parse(source, display: true);
      }
    }
    warm.stop();
    expect(AiMathCache.parseCount, 100);
    final result = {
      'environment':
          'Flutter test / Windows host; parsing only, not device frame time',
      'cold_parses': 100,
      'warm_lookups': 5000,
      'cold_total_us': cold.elapsedMicroseconds,
      'warm_total_us': warm.elapsedMicroseconds,
      'cold_mean_us': cold.elapsedMicroseconds / 100,
      'warm_mean_us': warm.elapsedMicroseconds / 5000,
    };
    final output = testArtifact('math-benchmark.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
    );
  });

  Future<void> mount(
    WidgetTester tester,
    String data, {
    bool streaming = false,
    double width = 300,
    TargetPlatform platform = TargetPlatform.windows,
    double scale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform, brightness: Brightness.dark),
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: width,
                child: AiMarkdown(data: data, isStreaming: streaming),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('native math corpus lays out on $platform at 300px', (
      tester,
    ) async {
      await mount(tester, _sample, platform: platform);
      expect(find.byType(Math), findsWidgets);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('公式暂无法排版'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'narrow views and large text wrap equations without clipping or shrinking',
    (tester) async {
      await mount(
        tester,
        r'\[' + List.filled(50, 'a+b+c').join('+') + r'\]',
        width: 180,
        scale: 2,
      );
      expect(tester.takeException(), isNull);
      final scrolls = tester.widgetList<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(
        scrolls.any((scroll) => scroll.scrollDirection == Axis.horizontal),
        isTrue,
      );
      final maths = tester.widgetList<Math>(find.byType(Math));
      expect(maths.every((math) => math.textStyle!.fontSize == 18), isTrue);
      final positions = tester.stateList<ScrollableState>(
        find.descendant(
          of: find.byType(AiMathFormula),
          matching: find.byType(Scrollable),
        ),
      );
      expect(positions.single.position.maxScrollExtent, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('display formulas reflow on resize without reparsing their TeX', (
    tester,
  ) async {
    final expression = List.filled(20, r'x^2').join('+');
    final source = '\\[$expression\\]';
    await mount(tester, source, width: 180);
    final narrow = tester.getSize(find.byType(AiSelectableMath));
    final state = tester.state(find.byType(AiMathFormula));
    final parts = find.byType(Math);
    final rows = tester
        .elementList(parts)
        .map(
          (element) => tester
              .getTopLeft(
                find.byElementPredicate(
                  (candidate) => identical(candidate, element),
                ),
              )
              .dy,
        )
        .toSet();
    expect(rows.length, greaterThan(1));
    final viewport = tester.getRect(find.byType(AiSelectableMath));
    for (final element in tester.elementList(parts)) {
      final rect = tester.getRect(
        find.byElementPredicate((candidate) => identical(candidate, element)),
      );
      expect(rect.left, greaterThanOrEqualTo(viewport.left));
      expect(rect.right, lessThanOrEqualTo(viewport.right + .01));
    }
    await mount(tester, source, width: 700);
    expect(tester.state(find.byType(AiMathFormula)), same(state));
    final wide = tester.getSize(find.byType(AiSelectableMath));
    expect(wide.height, lessThan(narrow.height));
    expect(wide.width, greaterThan(narrow.width));
    expect(AiMathCache.parseCount, 1);
    await mount(tester, source, width: 180);
    expect(tester.getSize(find.byType(AiSelectableMath)), narrow);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unwrapped parts retain TeX operator spacing and baselines', (
    tester,
  ) async {
    for (final source in [
      'a+b=c',
      r'a+\frac{b}{c}=d',
      'a+-b=c',
      '-a+b-c=d',
      r'\mathbf{a+b=c}',
      'a(b+c)+d=e',
      r'x\allowbreak y+z=t',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                AiMathFormula(source: source, block: true, maxWidth: 700),
                Math.tex(
                  source,
                  settings: const TexParserSettings(displayMode: true),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final intact = tester.getSize(find.byType(Math).last);
      final flowed = tester.getSize(find.byType(AiSelectableMath));
      expect(flowed.width, closeTo(intact.width, .01), reason: source);
      expect(flowed.height, closeTo(intact.height + 15, .01), reason: source);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('continuations lead with an operator and use a hanging indent', (
    tester,
  ) async {
    final terms = List.generate(12, (i) => 'a_{${i + 1}}').join('+');
    await mount(tester, '\\[S=$terms\\]', width: 200);
    final rows = <List<(String, Rect)>>[[]];
    for (final element in tester.elementList(find.byType(Math))) {
      final finder = find.byElementPredicate(
        (item) => identical(item, element),
      );
      final rect = tester.getRect(finder);
      if (rows.last.isNotEmpty && rect.left < rows.last.last.$2.right - .01) {
        rows.add([]);
      }
      rows.last.add((mathText(element.widget as Math), rect));
    }
    expect(rows.length, greaterThan(1));
    final lines = rows;
    final firstLeft = lines.first.first.$2.left;
    for (var i = 0; i < lines.length; i++) {
      final text = lines[i].map((part) => part.$1).join();
      expect(text, isNot(matches(r'[+=−]$')));
      if (i > 0) {
        expect(text, matches(r'^[+=−]'));
        expect(lines[i].first.$2.left, greaterThan(firstLeft));
      }
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'parenthesized arguments and spaced no-break groups stay intact',
    (tester) async {
      for (final source in [
        'F(x)=(a+b+c+d+e+f)+z',
        r'x\nobreak\quad +\nobreak\quad y^2+z',
      ]) {
        await mount(tester, '\\[$source\\]', width: 100);
        final parts = tester.widgetList<Math>(find.byType(Math)).map(mathText);
        if (source.startsWith('F')) {
          expect(parts, contains('=(a+b+c+d+e+f)'));
        } else {
          expect(parts, contains('x+y2'));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'explicit aligned derivations retain their rows and copy source',
    (tester) async {
      const source = r'\begin{aligned}a&=b+c\\&=d+e\end{aligned}';
      await mount(tester, '\\[$source\\]', width: 120);
      expect(find.byType(Math), findsOneWidget);
      final selection = tester.renderObject<RenderAiSelectableMath>(
        find.byType(AiSelectableMath),
      );
      selection.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(selection.getSelectedContent()?.plainText, '\\[$source\\]');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('lists, quotes and math fences use their local block width', (
    tester,
  ) async {
    final expression = List.filled(20, 'x^2').join('+');
    for (final source in [
      '- 公式\n\n  \\[$expression\\]',
      '> \\[$expression\\]',
      '```math\n$expression\n```',
    ]) {
      await mount(tester, source, width: 180);
      final formulaRect = tester.getRect(find.byType(AiSelectableMath));
      expect(formulaRect.right, lessThanOrEqualTo(180));
      expect(find.byType(Math), findsWidgets);
      for (final element in tester.elementList(find.byType(Math))) {
        final rect = tester.getRect(
          find.byElementPredicate((candidate) => identical(candidate, element)),
        );
        expect(rect.right, lessThanOrEqualTo(formulaRect.right + .01));
      }
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(AiMathFormula),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scroll.position.maxScrollExtent, 0);
      expect(tester.takeException(), isNull, reason: source);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'indivisible matrices and fractions stay bounded and scrollable',
    (tester) async {
      final terms = List.filled(20, 'x^2').join('+');
      final matrixRow = List.filled(20, 'x').join('&');
      for (final expression in [
        '\\begin{pmatrix}$matrixRow\\end{pmatrix}',
        '\\frac{$terms}{y}',
        'a=\\frac{$terms}{y}+b',
        '\\left($terms\\right)',
        'x\\nobreak +\\nobreak ${'y' * 50}',
      ]) {
        await mount(tester, '\\[$expression\\]', width: 180);
        final rect = tester.getRect(find.byType(AiSelectableMath));
        expect(rect.right, lessThanOrEqualTo(180));
        final scrollFinder = find.descendant(
          of: find.byType(AiMathFormula),
          matching: find.byType(Scrollable),
        );
        final scroll = tester.state<ScrollableState>(scrollFinder);
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        await tester.drag(scrollFinder, const Offset(-100, 0));
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, greaterThan(0));
        expect(find.text('公式暂无法排版，已保留原文'), findsNothing);
        expect(tester.takeException(), isNull, reason: expression);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'unfinished streaming formulas wait, then parse once and reuse in later frames',
    (tester) async {
      const equation = r'\[\frac{x^2+1}{\sqrt{y}}\]';
      for (var i = 2; i < equation.length; i++) {
        await mount(tester, equation.substring(0, i), streaming: true);
        expect(tester.takeException(), isNull);
      }
      expect(AiMathCache.parseCount, 0);
      await mount(tester, equation, streaming: true);
      expect(AiMathCache.parseCount, 1);
      for (var i = 0; i < 15; i++) {
        await mount(tester, '$equation\n\n后续说明 $i', streaming: true);
      }
      expect(AiMathCache.parseCount, 1);
      await mount(tester, equation);
      expect(AiMathCache.parseCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wide inline formulas in tables and resizing retain their layout state',
    (tester) async {
      final expression = List.filled(30, 'a+b+c').join('+');
      final source =
          '| 含义 | 表达式 |\n|---|---|\n| 宽公式 | \$$expression\$ |\n\n\\[$expression\\]';
      await mount(tester, source, width: 180);
      expect(tester.takeException(), isNull);
      final count = AiMathCache.parseCount;
      final states = tester.stateList(find.byType(AiMathFormula)).toList();
      await mount(tester, source, width: 700);
      expect(tester.takeException(), isNull);
      expect(AiMathCache.parseCount, count);
      expect(
        tester.stateList(find.byType(AiMathFormula)).first,
        same(states.first),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'large price lists and malformed dollars keep linear-looking plain text paths',
    () {
      expect(mathNodes(List.filled(3000, r'$5, ').join()), isEmpty);
      expect(mathNodes('\$${'a' * 4096}!'), isEmpty);
    },
  );

  testWidgets(
    'invalid and excessive formulas keep readable source and copy actions without crashing',
    (tester) async {
      final tooDeep = '${'{' * 40}x${'}' * 40}';
      await mount(tester, '${r'\[\unknowncommand{x}\]'}\n\n\\[$tooDeep\\]');
      expect(find.text('公式暂无法排版，已保留原文'), findsOneWidget);
      expect(find.text('公式较复杂，已保留原文，可复制查看'), findsOneWidget);
      expect(find.byType(AiSelectableMath), findsNWidgets(2));
      expect(AiMathCache.parseCount, 1);
      expect(tester.takeException(), isNull);
      Actions.invoke(
        tester.element(find.byType(AiSelectableMath).first),
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pump();
      Actions.invoke(
        tester.element(find.byType(AiSelectableMath).first),
        CopySelectionTextIntent.copy,
      );
      await tester.pump();
      expect(
        (await tester.runAsync(() => Clipboard.getData('text/plain')))?.text,
        '${r'\[\unknowncommand{x}\]'}\\[$tooDeep\\]',
      );
      await mount(tester, r'\[x+y=z\]');
      final formulaRect = tester.getRect(find.byType(AiSelectableMath));
      final mouse = await tester.startGesture(
        formulaRect.centerLeft + const Offset(1, 0),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.moveTo(formulaRect.centerRight - const Offset(1, 0));
      await tester.pump();
      await mouse.up();
      await tester.pump();
      await tester.tap(
        find.byType(AiSelectableMath),
        buttons: kSecondaryMouseButton,
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(() => Clipboard.getData('text/plain')))?.text,
        r'\[x+y=z\]',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'math fences render when finished and ordinary fences remain code',
    (tester) async {
      const source =
          '```latex\n'
          r'\frac{a}{b}'
          '\n```\n\n```dart\n'
          r'final dollar = "$x$";'
          '\n```';
      await mount(tester, source, streaming: true);
      expect(AiMathCache.parseCount, 0);
      await mount(tester, source);
      expect(AiMathCache.parseCount, 1);
      expect(find.byTooltip('复制代码'), findsOneWidget);
      expect(find.byType(AiSelectableMath), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Chinese labels use bundled fonts in subscripts and fractions', (
    tester,
  ) async {
    await mount(tester, r'\[P_{\text{结果}}=\frac{\text{成功次数}}{\text{总次数}}\]');
    final labels = tester
        .widgetList<RichText>(find.byType(RichText))
        .where((text) => text.text.style?.fontFamily == 'Noto Sans SC');
    expect(labels.length, greaterThan(4));
    expect(tester.takeException(), isNull);
    expect(find.text('公式暂无法排版，已保留原文'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('math review screenshot with bundled KaTeX fonts', (
    tester,
  ) async {
    await tester.runAsync(() async {
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
        final font = FontLoader('packages/flutter_math_fork/KaTeX_$family')
          ..addFont(Future.value(data));
        await font.load();
      }
      final regular = FontLoader('Noto Sans SC')
        ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'));
      await regular.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final monospace = FontLoader('monospace')
        ..addFont(
          rootBundle.load(
            'packages/flutter_math_fork/lib/katex_fonts/fonts/KaTeX_Typewriter-Regular.ttf',
          ),
        );
      await monospace.load();
    });
    final capture = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(540, 1300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Noto Sans SC'),
        home: Scaffold(
          body: RepaintBoundary(
            key: capture,
            child: ColoredBox(
              color: const Color(0xff141218),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: SingleChildScrollView(child: AiMarkdown(data: _sample)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final picture = await boundary.toImage(pixelRatio: 1.5);
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      final output = testArtifact('math-preview.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(png!.buffer.asUint8List());
      picture.dispose();
    });
    Actions.invoke(
      tester.element(find.byType(AiSelectableMath).first),
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final picture = await boundary.toImage(pixelRatio: 1.5);
      final png = await picture.toByteData(format: ui.ImageByteFormat.png);
      await testArtifact(
        'math-selection-preview.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      picture.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
    const wrapPreview = r'''
# 公式随宽度换行

普通项、分数和积分保持原字号：

\[
F(x)=\frac{x^2+1}{2}+\frac{x^3+2}{3}+\int_0^x t^2\,dt+\frac{x^4+3}{4}+x^5+x^6
\]

> 引用中的公式按引用区域宽度换行。
>
> \[a_1+a_2+a_3+a_4+a_5+a_6+a_7+a_8+a_9+a_{10}=S\]

矩阵保持完整，可在公式区域横向滚动：

\[
\begin{pmatrix}a_{11}&a_{12}&a_{13}&a_{14}&a_{15}&a_{16}&a_{17}&a_{18}&a_{19}&a_{20}\\a_{21}&a_{22}&a_{23}&a_{24}&a_{25}&a_{26}&a_{27}&a_{28}&a_{29}&a_{30}\end{pmatrix}
\]
''';
    for (final width in [320.0, 540.0]) {
      await tester.binding.setSurfaceSize(Size(width, 820));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Noto Sans SC'),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: const Color(0xff141218),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: SingleChildScrollView(
                    child: AiMarkdown(data: wrapPreview),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final picture = await boundary.toImage(pixelRatio: 1.5);
        final png = await picture.toByteData(format: ui.ImageByteFormat.png);
        final suffix = width == 320 ? 'narrow' : 'wide';
        await testArtifact(
          'math-wrap-$suffix.png',
        ).writeAsBytes(png!.buffer.asUint8List());
        picture.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
