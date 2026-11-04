import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';
import 'package:video_player_app/features/ai_chat/ai_math_selection.dart';

// User-facing TeX examples drawn from the commands and environments supported
// by flutter_math_fork 0.7.4. Exercise the public Markdown input path rather
// than asserting a particular AST representation or cloning algorithm.
const _examples = <({String name, String tex})>[
  (name: 'accents', tex: r'\hat{x}+\bar{y}+\vec{v}'),
  (name: 'wide accents', tex: r'\widehat{ABC}+\widetilde{xy}'),
  (name: 'under accents', tex: r'\underline{a+b}+\underleftarrow{AB}'),
  (name: 'overset', tex: r'a\overset{!}{=}b'),
  (name: 'underset', tex: r'\underset{x\to0}{f(x)}=L'),
  (name: 'stackrel', tex: r'A\stackrel{f}{\longrightarrow}B'),
  (name: 'overbrace', tex: r'\overbrace{a+b+c}^{n\text{ terms}}'),
  (name: 'underbrace', tex: r'\underbrace{x+x+x}_{3x}'),
  (name: 'arrow with absent lower annotation', tex: r'A\xrightarrow{f}B'),
  (name: 'arrow with both annotations', tex: r'A\xrightarrow[g]{f}B'),
  (name: 'nested fractions', tex: r'\frac{1+\frac{a}{b}}{c_1+c_2}'),
  (name: 'binomial', tex: r'\binom{n}{k}=\frac{n!}{k!(n-k)!}'),
  (name: 'root without optional index', tex: r'\sqrt{x^2+y^2}'),
  (name: 'root with optional index', tex: r'\sqrt[n]{1+x}'),
  (
    name: 'automatic delimiters',
    tex: r'\left\langle\frac{a}{b},x\right\rangle',
  ),
  (
    name: 'explicit delimiter sizing',
    tex: r'\Bigl(\frac{a}{b}\Bigr)+\bigl[x\bigr]',
  ),
  (name: 'explicit font sizes', tex: r'{\small x}+{\Large y}'),
  (
    name: 'math styles',
    tex: r'{\displaystyle\sum_{k=1}^{n}k}+{\scriptstyle x}',
  ),
  (
    name: 'font families',
    tex: r'\mathbf{AB}+\mathit{x}+\mathbb{R}+\mathcal{F}',
  ),
  (name: 'text in math', tex: r'\text{rank}(A)=2'),
  (name: 'colors', tex: r'\textcolor{red}{a+b}+{\color{blue}c}'),
  (name: 'enclosures', tex: r'\boxed{x+1}+\fbox{word}'),
  (name: 'cancellation', tex: r'\cancel{x}+\bcancel{y}+\xcancel{z}'),
  (name: 'raised text', tex: r'A+\raisebox{0.3em}{up}'),
  (name: 'vertical phantom', tex: r'A\vphantom{\frac{b}{c}}+B'),
  (name: 'horizontal phantom', tex: r'a\hphantom{long}b'),
  (name: 'full phantom', tex: r'x+\phantom{y^2}+z'),
  (name: 'explicit spaces', tex: r'a\hspace{1em}b\mkern3mu c\,d\!e'),
  (name: 'rules', tex: r'\rule{1em}{0.1em}+x'),
  (name: 'named operators', tex: r'\operatorname{rank}(A)+\sin x+\log y'),
  (
    name: 'large operators and limits',
    tex: r'\sum_{i=1}^{n}i+\prod_{j=1}^{m}j',
  ),
  (name: 'integral limits', tex: r'\int_0^1 x^2\,\mathrm{d}x'),
  (name: 'nested scripts', tex: r'x_{i_j}^{n+1}+a_{k}^{b_c}'),
  (name: 'operator classes', tex: r'a\mathbin{\star}b\mathrel{\sim}c'),
  (name: 'cases', tex: r'f(x)=\begin{cases}x^2&x\ge0\\-x&x<0\end{cases}'),
  (
    name: 'array with empty cells',
    tex: r'\begin{array}{ccc}a&&b\\&c&\\d&&e\end{array}',
  ),
  (
    name: 'matrix with empty cells',
    tex: r'\begin{pmatrix}a&&b\\&c&\\d&&e\end{pmatrix}',
  ),
  (
    name: 'array borders',
    tex: r'\begin{array}{c|r}\hline a&b\\c&d\\\hline\end{array}',
  ),
  (
    name: 'aligned derivation',
    tex: r'\begin{aligned}a&=b+c\\&=d+e\end{aligned}',
  ),
  (
    name: 'CJK nested annotation',
    tex: r'\underbrace{a+b}_{\text{结果}}+\frac{\text{成功}}{\text{总数}}',
  ),
];

String _repeatedMarkdown(String tex) =>
    'First: \\($tex\\); second: \\($tex\\).\n\n'
    '\\[\n$tex\n\\]\n\n'
    '\\[\n$tex\n\\]';

Future<void> _mount(
  WidgetTester tester,
  String source, {
  required double width,
  required double scale,
  required Brightness brightness,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.windows,
        brightness: brightness,
      ),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: width,
              child: AiMarkdown(data: source),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _expectTypesetCopies(WidgetTester tester, String source) {
  expect(tester.takeException(), isNull, reason: source);
  final formulas = find.byType(AiMathFormula);
  expect(formulas, findsNWidgets(4), reason: source);
  final widgets = tester.widgetList<AiMathFormula>(formulas).toList();
  expect(widgets.where((formula) => !formula.block), hasLength(2));
  expect(widgets.where((formula) => formula.block), hasLength(2));
  for (final element in tester.elementList(formulas)) {
    final formula = element.widget as AiMathFormula;
    expect(formula.source.trim(), source);
    final occurrence = find.byElementPredicate(
      (candidate) => identical(candidate, element),
    );
    final selection = find.descendant(
      of: occurrence,
      matching: find.byType(AiSelectableMath),
    );
    expect(selection, findsOneWidget, reason: source);
    final rect = tester.getRect(selection);
    expect(rect.width, greaterThan(0), reason: source);
    expect(rect.height, greaterThan(0), reason: source);
    final math = find.descendant(of: occurrence, matching: find.byType(Math));
    expect(math, findsWidgets, reason: source);
    expect(
      tester
          .widgetList<Math>(math)
          .every((widget) => widget.parseError == null),
      isTrue,
      reason: 'Every copy must parse as mathematics: $source',
    );
    final glyphs = tester
        .elementList(math)
        .map(
          (element) => tester.getRect(
            find.byElementPredicate(
              (candidate) => identical(candidate, element),
            ),
          ),
        );
    expect(
      glyphs.any((rect) => rect.width > .1 && rect.height > .1),
      isTrue,
      reason: 'Each occurrence must contain a nonzero typeset formula: $source',
    );
  }
  for (final fallback in ['公式暂无法排版', '公式较复杂', '公式未闭合', '公式接收中']) {
    expect(find.textContaining(fallback), findsNothing, reason: source);
  }
  expect(tester.takeException(), isNull, reason: source);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AiMathCache.reset);

  for (final example in _examples) {
    testWidgets(
      'repeated inline and display ${example.name} survive restyling',
      (tester) async {
        final markdown = _repeatedMarkdown(example.tex);
        await _mount(
          tester,
          markdown,
          width: 680,
          scale: 1,
          brightness: Brightness.dark,
        );
        _expectTypesetCopies(tester, example.tex);
        // Keep all four occurrences mounted while changing inherited visual
        // inputs. AST render-state isolation must also survive updated layouts.
        await _mount(
          tester,
          markdown,
          width: 380,
          scale: 1.75,
          brightness: Brightness.light,
        );
        _expectTypesetCopies(tester, example.tex);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
