import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:video_player_app/features/ai_chat/ai_inline_math_viewport.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown_emphasis.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';
import 'package:video_player_app/features/ai_chat/ai_math_selection.dart';
import 'package:video_player_app/features/ai_chat/ai_math_syntax.dart';
import 'package:video_player_app/features/ai_chat/ai_math_table_syntax.dart';

final _limitsSummary = File(
  'test/fixtures/ai_limits_codex_summary.md',
).readAsStringSync();

md.Document _document({bool protect = true}) => md.Document(
  blockSyntaxes: [
    const AiMathBlockSyntax(),
    if (protect) const AiMathTableSyntax(),
  ],
  inlineSyntaxes: [AiMathInlineSyntax(), AiMarkdownEmphasisSyntax()],
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
);

Iterable<md.Element> _elements(Iterable<md.Node> nodes, String tag) sync* {
  for (final node in nodes) {
    if (node is! md.Element) continue;
    if (node.tag == tag) yield node;
    yield* _elements(node.children ?? [], tag);
  }
}

List<md.Element> _math(Iterable<md.Node> nodes) => [
  for (final node in nodes)
    if (node is md.Element) ...[
      if ({aiInlineMathTag, aiDisplayMathTag}.contains(node.tag)) node,
      ..._math(node.children ?? []),
    ],
];

Future<void> _mount(
  WidgetTester tester,
  String source, {
  double width = 360,
  ValueChanged<Duration>? onSeek,
  GlobalKey? capture,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.windows,
        brightness: Brightness.dark,
        fontFamily: 'MiSans',
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: RepaintBoundary(
              key: capture,
              child: AiMarkdown(data: source, onSeek: onSeek),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

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
  await (FontLoader(
    'MiSans',
  )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.otf'))).load();
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
  final output = File('.artifacts/ai-chat/$name.png');
  await output.parent.create(recursive: true);
  await output.writeAsBytes(png!.buffer.asUint8List());
  picture.dispose();
});

void main() {
  setUp(AiMathCache.reset);

  test(
    'real Codex limits response retains all three rows and three columns',
    () {
      final ast = _document().parse(_limitsSummary);
      final table = _elements(ast, 'table').single;
      final header = _elements(table.children!, 'th').toList();
      expect(header, hasLength(3));
      expect(header[0].textContent, '极限结论');
      expect(header[1].textContent, '关键估计');
      expect(_math(header[2].children!).single.textContent, r'\delta');
      final rows = _elements(table.children!, 'tbody').single.children!;
      expect(rows, hasLength(3));
      final expected = <List<List<String>>>[
        [
          [r'\displaystyle\lim_{x\to2}\frac{x^3-8}{x-2}=12'],
          [r'|x-2|<1', r'=|x-2||x+4|<7|x-2|'],
          [r'\min\{1,\varepsilon/7\}'],
        ],
        [
          [r'\displaystyle\lim_{x\to1}\frac{x^2-1}{2x^2-x-1}=\frac23'],
          [r'|x-1|<1', r'=\frac{|x-1|}{3|2x+1|}<\frac{|x-1|}{3}'],
          [r'\min\{1,3\varepsilon\}'],
        ],
        [
          [r'\displaystyle\lim_{x\to x_0}\sin x=\sin x_0'],
          [r'|\sin x-\sin x_0|\le |x-x_0|'],
          [r'\varepsilon'],
        ],
      ];
      for (var row = 0; row < rows.length; row++) {
        final cells = (rows[row] as md.Element).children!;
        expect(cells, hasLength(3));
        for (var column = 0; column < 3; column++) {
          expect(
            _math([(cells[column])]).map((node) => node.textContent),
            expected[row][column],
            reason:
                'row $row / column $column must retain its complete formulas',
          );
        }
        expect(cells[1].textContent, contains(row == 2 ? '利用和差化积，得到' : '时，误差'));
      }
      final sourceMath = RegExp(r'\\\(([\s\S]*?)\\\)|\\\[([\s\S]*?)\\\]')
          .allMatches(_limitsSummary)
          .map((match) => (match[1] ?? match[2]!).trim());
      expect(_math(ast).map((node) => node.textContent.trim()), sourceMath);

      // This fixture reproduces actual data loss in the upstream GFM table
      // parser; it is not merely a comparison to our own token implementation.
      final nativeTable = _elements(
        _document(protect: false).parse(_limitsSummary),
        'table',
      ).single;
      final nativeRows = _elements(
        nativeTable.children!,
        'tbody',
      ).single.children!;
      expect(
        _math(
          (nativeRows.first as md.Element).children!,
        ).map((n) => n.textContent),
        isNot(contains(r'\min\{1,\varepsilon/7\}')),
      );
    },
  );

  for (final formula in [
    r'\(|x-2|<1\)',
    r'\(\|x-2\|<1\)',
    r'$|x|$',
    r'$\|x\|$',
    r'$$|x|$$',
    r'\[|x|\]',
  ]) {
    test('math bars remain one cell and preserve source: $formula', () {
      final source =
          '| math | explanation | final |\n'
          '|---|---|---|\n'
          '| $formula | keep | done |';
      final ast = _document().parse(source);
      final cells = _elements(ast, 'td').toList();
      expect(cells, hasLength(3));
      expect(cells[1].textContent, 'keep');
      expect(cells[2].textContent, 'done');
      final math = _math(cells.first.children!).single;
      expect(math.attributes['complete'], 'true');
      expect(math.attributes['copy-source'], formula);
      final originalMath = _math(_document().parseInline(formula)).single;
      expect(math.textContent, originalMath.textContent);
    });
  }

  test('math bars in a heading do not change the header column count', () {
    final ast = _document().parse(
      r'| $|x|$ | label |'
      '\n|:---|---:|\n| first | second |',
    );
    final headers = _elements(ast, 'th').toList();
    expect(headers, hasLength(2));
    expect(headers.first.attributes['align'], 'left');
    expect(headers.last.attributes['align'], 'right');
    expect(_math(headers.first.children!).single.textContent, '|x|');
  });

  test(
    'normal pipes, code, escapes and link destinations retain GFM behavior',
    () {
      for (final row in [
        r'| plain | next | last |',
        r'| plain \| pipe | next | last |',
        r'| `\(|x|\)` | next | last |',
        r'| ``$|x|$`` | next | last |',
        r'| \\( |x| \\) | next | last |',
        r'| [label](https://example.com/$|x|$) | next | last |',
        r'| <https://example.com/$|x|$> | next | last |',
        r'| unclosed \(|x| | next | last |',
        r'| unclosed \(|x| | next | last \\)',
        r'| price $5 and $10 | next | last |',
      ]) {
        final source = '| a | b | c |\n|---|---|---|\n$row';
        expect(
          md.renderToHtml(_document().parse(source)),
          md.renderToHtml(_document(protect: false).parse(source)),
          reason: row,
        );
      }
    },
  );

  test(
    'temporary protection restores original parser lines and token-like text',
    () {
      final source =
          '| a | b |\n|---|---|\n'
          '| \ufdd0AI_MATH_PIPE_0\ufdd1 ${r'$|x|$'} | end |\n\n'
          '```latex\n${r'\(|code|\)'}\n```';
      final lines = source.split('\n').map(md.Line.new).toList();
      final originals = lines.map((line) => line.content).toList();
      final ast = _document().parseLineList(lines);
      expect(lines.map((line) => line.content), originals);
      expect(
        _elements(ast, 'td').first.textContent,
        contains('\ufdd0AI_MATH_PIPE_0\ufdd1'),
      );
      expect(_math(ast).single.attributes['copy-source'], r'$|x|$');
      expect(_elements(ast, 'code').single.textContent, '${r'\(|code|\)'}\n');
    },
  );

  testWidgets('long table math uses the cell viewport and can reveal its end', (
    tester,
  ) async {
    const formula =
        r'\(\frac{x^{12}+x^{11}+x^{10}+x^9+x^8+x^7+x^6+x^5+x^4+x^3+x^2+x+1}{|x-2|}=12345\)';
    await _mount(
      tester,
      '| conclusion | estimate | delta |\n|---|---|---|\n'
      '| $formula | ${r'$|x-2|<1$'} | ${r'$\varepsilon/7$'} |',
      width: 330,
    );
    expect(tester.takeException(), isNull);
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(2));
    expect(table.children.last.children, hasLength(3));
    final formulaFinder = find.byWidgetPredicate(
      (widget) => widget is AiMathFormula && widget.copySource == formula,
    );
    expect(formulaFinder, findsOneWidget);
    final viewportFinder = find.descendant(
      of: formulaFinder,
      matching: find.byType(AiInlineMathViewport),
    );
    final viewport = tester.renderObject<RenderAiInlineMathViewport>(
      find.descendant(
        of: viewportFinder,
        matching: find.byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_InlineMathViewport',
        ),
      ),
    );
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: viewportFinder, matching: find.byType(Scrollable)),
    );
    expect(viewport.size.width, inInclusiveRange(180, 208));
    expect(scroll.position.maxScrollExtent, greaterThan(50));
    final originalX = viewport.child!.localToGlobal(Offset.zero).dx;
    await tester.drag(
      viewportFinder,
      const Offset(-70, 0),
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(0));
    expect(viewport.child!.localToGlobal(Offset.zero).dx, lessThan(originalX));
    scroll.position.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    final childRight = viewport.child!
        .localToGlobal(Offset(viewport.child!.size.width, 0))
        .dx;
    final viewportRight = viewport
        .localToGlobal(Offset(viewport.size.width, 0))
        .dx;
    expect(childRight, closeTo(viewportRight, .1));
    final selectable = tester.widget<AiSelectableMath>(
      find.descendant(
        of: formulaFinder,
        matching: find.byType(AiSelectableMath),
      ),
    );
    expect(selectable.source, formula);
    expect(find.byType(Math), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('real Codex limits response renders all table formulas', (
    tester,
  ) async {
    await _mount(tester, _limitsSummary, width: 390);
    final expected = _math(_document().parse(_limitsSummary));
    final formulas = tester.widgetList<AiMathFormula>(
      find.byType(AiMathFormula),
    );
    expect(
      formulas.map((formula) => formula.source.trim()),
      expected.map((node) => node.textContent.trim()),
    );
    expect(formulas.every((formula) => formula.complete), isTrue);
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(4));
    expect(table.children.every((row) => row.children.length == 3), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'whole table scroll reveals linked math and leaves vertical scrolling intact',
    (tester) async {
      Duration? sought;
      final prose = List.filled(30, '后续正文用于检查对话的纵向滚动。').join('\n\n');
      await _mount(
        tester,
        '| conclusion | estimate | delta |\n|---|---|---|\n'
        '| ${r'$|x|$'} | condition | [${r'$|z|$'}](video://seek?ms=12000) |\n\n$prose',
        width: 330,
        onSeek: (time) => sought = time,
      );
      final outer = find
          .ancestor(
            of: find.byType(Table),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is SingleChildScrollView &&
                  widget.scrollDirection == Axis.horizontal,
            ),
          )
          .first;
      final scroll = tester.widget<SingleChildScrollView>(outer).controller!;
      expect(scroll.position.maxScrollExtent, greaterThan(300));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: ui.PointerDeviceKind.mouse,
          position: tester.getTopLeft(outer) + const Offset(40, 10),
          scrollDelta: const Offset(60, 0),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, 60);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final linkedFormula = find.byWidgetPredicate(
        (widget) => widget is AiMathFormula && widget.copySource == r'$|z|$',
      );
      await tester.tap(linkedFormula);
      await tester.pumpAndSettle();
      expect(sought, const Duration(seconds: 12));
      final selectable = tester.renderObject<RenderAiSelectableMath>(
        find.descendant(
          of: linkedFormula,
          matching: find.byType(AiSelectableMath),
        ),
      );
      selectable.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(selectable.getSelectedContent()!.plainText, r'$|z|$');
      selectable.dispatchSelectionEvent(const ClearSelectionEvent());
      final vertical = find
          .byWidgetPredicate(
            (widget) =>
                widget is SingleChildScrollView &&
                widget.scrollDirection == Axis.vertical,
          )
          .first;
      final verticalState = tester.state<ScrollableState>(
        find.descendant(of: vertical, matching: find.byType(Scrollable)).first,
      );
      await tester.drag(linkedFormula, const Offset(0, -90));
      await tester.pumpAndSettle();
      expect(verticalState.position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [320.0, 800.0]) {
    testWidgets(
      'real limits summary has readable bounded columns at ${width}px',
      (tester) async {
        await tester.runAsync(_loadFonts);
        final capture = GlobalKey();
        await _mount(tester, _limitsSummary, width: width, capture: capture);
        final table = tester.renderObject<RenderTable>(find.byType(Table));
        expect(table.size.width, 672);
        final scrollFinder = find
            .ancestor(
              of: find.byType(Table),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is SingleChildScrollView &&
                    widget.scrollDirection == Axis.horizontal,
              ),
            )
            .first;
        final scroll = tester
            .widget<SingleChildScrollView>(scrollFinder)
            .controller!;
        expect(scroll.position.maxScrollExtent, width == 320 ? 352 : 0);
        await _writeScreenshot(
          tester,
          capture,
          'limits-summary-${width.toInt()}',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
