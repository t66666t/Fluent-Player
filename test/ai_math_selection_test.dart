import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';
import 'package:video_player_app/features/ai_chat/ai_math_selection.dart';

void main() {
  String? copied;
  setUp(() {
    AiMathCache.reset();
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> mount(
    WidgetTester tester,
    String text, {
    TargetPlatform platform = TargetPlatform.windows,
    double width = 400,
    bool streaming = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: width,
              child: AiMarkdown(data: text, isStreaming: streaming),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  RenderAiSelectableMath formula(WidgetTester tester, [int index = 0]) =>
      tester.renderObject<RenderAiSelectableMath>(
        find.byType(AiSelectableMath).at(index),
      );

  Future<void> copy(WidgetTester tester) async {
    Actions.invoke(
      tester.element(find.byType(AiSelectableMath).first),
      CopySelectionTextIntent.copy,
    );
    await tester.pump();
  }

  testWidgets(
    'mouse drag across prose and inline math copies original TeX in order',
    (tester) async {
      const source = r'Before $\frac{a}{b}$ after';
      await mount(tester, source);
      final paragraphFinder = find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().startsWith('Before ') &&
            widget.text.toPlainText().endsWith(' after'),
      );
      final paragraph = tester.renderObject<RenderParagraph>(paragraphFinder);
      final plain = paragraph.text.toPlainText();
      final origin = paragraph.localToGlobal(Offset.zero);
      final first = paragraph
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 7),
          )
          .first
          .toRect()
          .shift(origin);
      final last = paragraph
          .getBoxesForSelection(
            TextSelection(
              baseOffset: plain.indexOf(' after'),
              extentOffset: plain.length,
            ),
          )
          .last
          .toRect()
          .shift(origin);
      final mouse = await tester.startGesture(
        first.centerLeft + const Offset(1, 0),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.moveTo(last.centerRight - const Offset(1, 0));
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      expect(formula(tester).value.status, SelectionStatus.uncollapsed);
      expect(formula(tester).value.selectionRects, isNotEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(copied, source);
      expect(AiMathCache.parseCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in TargetPlatform.values.where(
    (p) => p != TargetPlatform.fuchsia,
  )) {
    testWidgets('formula native selection and source copy on $platform', (
      tester,
    ) async {
      const source = r'\[\frac{x^2+1}{\sqrt{y}}\]';
      await mount(tester, source, platform: platform);
      if (platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS) {
        await tester.longPress(find.byType(AiSelectableMath));
      } else {
        final rect = tester.getRect(find.byType(AiSelectableMath));
        final mouse = await tester.startGesture(
          rect.centerLeft + const Offset(1, 0),
          kind: ui.PointerDeviceKind.mouse,
        );
        await tester.pump();
        await mouse.moveTo(rect.centerRight - const Offset(1, 0));
        await tester.pump();
        await mouse.up();
      }
      await tester.pumpAndSettle();
      expect(
        copied,
        isNull,
        reason: 'selection must not write to the clipboard',
      );
      expect(formula(tester).getSelectedContent()?.plainText, source);
      if (platform == TargetPlatform.android ||
          platform == TargetPlatform.iOS) {
        expect(find.text('Copy'), findsOneWidget);
        await tester.tap(find.text('Copy'));
        await tester.pump();
      } else {
        await copy(tester);
      }
      expect(copied, source);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'select-all preserves original delimiters, environments and math fences',
    (tester) async {
      const source =
          'Inline ${r'\(a+b\)'}\n\n'
          '${r'$$'}\n${r'\begin{pmatrix}1&2\\3&4\end{pmatrix}'}\n${r'$$'}\n\n'
          '${r'\begin{align*}'}\nx &= y\\\\\n${r'\end{align*}'}\n\n'
          '```latex\n${r'\int_0^1 x\,dx'}\n```\n\n'
          '```dart\nprint(1);\n```';
      await mount(tester, source);
      Actions.invoke(
        tester.element(find.byType(AiSelectableMath).first),
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pumpAndSettle();
      await copy(tester);
      expect(copied, contains(r'\(a+b\)'));
      expect(
        copied,
        contains(
          '${r'$$'}\n${r'\begin{pmatrix}1&2\\3&4\end{pmatrix}'}\n${r'$$'}',
        ),
      );
      expect(
        copied,
        contains('${r'\begin{align*}'}\nx &= y\\\\\n${r'\end{align*}'}'),
      );
      expect(copied, contains(r'\int_0^1 x\,dx'));
      expect(copied, contains('print(1);'));
      expect(copied, isNot(contains('latex')));
      expect(copied, isNot(contains('dart')));
      expect(copied, isNot(contains('\uFFFC')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reverse drag selects a whole formula and keyboard edges leave it',
    (tester) async {
      await mount(tester, r'\[x+y=z\]');
      final rect = tester.getRect(find.byType(AiSelectableMath));
      final mouse = await tester.startGesture(
        rect.centerRight - const Offset(1, 0),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      await mouse.moveTo(rect.centerLeft + const Offset(1, 0));
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      await copy(tester);
      expect(copied, r'\[x+y=z\]');
      final render = formula(tester);
      render.dispatchSelectionEvent(const ClearSelectionEvent());
      expect(render.getSelectedContent(), isNull);
      expect(
        render.dispatchSelectionEvent(
          const GranularlyExtendSelectionEvent(
            forward: true,
            isEnd: true,
            granularity: TextGranularity.character,
          ),
        ),
        SelectionResult.end,
      );
      expect(render.getSelectedContent()?.plainText, r'\[x+y=z\]');
      expect(
        render.dispatchSelectionEvent(
          const GranularlyExtendSelectionEvent(
            forward: true,
            isEnd: true,
            granularity: TextGranularity.character,
          ),
        ),
        SelectionResult.next,
      );
    },
  );

  testWidgets(
    'selected formula survives resize and directional movement reaches adjacent prose',
    (tester) async {
      final expression = List.filled(20, 'x^2').join('+');
      final source = 'Before\n\n\\[$expression\\]\n\nAfter';
      await mount(tester, source, width: 180);
      final render = formula(tester);
      render.dispatchSelectionEvent(const SelectAllSelectionEvent());
      await tester.pumpAndSettle();
      await mount(tester, source, width: 320);
      expect(formula(tester), same(render));
      expect(render.value.selectionRects.single.width, render.size.width);
      expect(render.size.width, lessThanOrEqualTo(320));
      expect(render.getSelectedContent()?.plainText, '\\[$expression\\]');
      final registrar =
          SelectionContainer.maybeOf(
                tester.element(find.byType(AiSelectableMath)),
              )!
              as SelectionHandler;
      registrar.dispatchSelectionEvent(const ClearSelectionEvent());
      registrar.dispatchSelectionEvent(
        SelectWordSelectionEvent(
          globalPosition: tester.getCenter(find.byType(AiSelectableMath)),
        ),
      );
      final dx = render.localToGlobal(Offset(render.size.width / 2, 0)).dx;
      registrar.dispatchSelectionEvent(
        DirectionallyExtendSelectionEvent(
          dx: dx,
          isEnd: true,
          direction: SelectionExtendDirection.nextLine,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'wide formula selects while scrolled; stream source changes clear stale selection',
    (tester) async {
      final expression = '\\left(${List.filled(50, 'x^2').join('+')}\\right)';
      await mount(tester, '\\[$expression\\]', width: 180);
      final scroll = find
          .descendant(
            of: find.byType(AiMathFormula),
            matching: find.byType(SingleChildScrollView),
          )
          .first;
      await tester.drag(scroll, const Offset(-100, 0));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: scroll, matching: find.byType(Scrollable)).first,
      );
      expect(scrollable.position.pixels, greaterThan(0));
      final before = formula(tester);
      before.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(before.getSelectedContent()?.plainText, '\\[$expression\\]');
      expect(before.value.selectionRects.single.width, lessThanOrEqualTo(180));
      await mount(tester, r'\[x+y', width: 180, streaming: true);
      final incomplete = formula(tester);
      incomplete.dispatchSelectionEvent(const SelectAllSelectionEvent());
      expect(incomplete.getSelectedContent()?.plainText, r'\[x+y');
      await mount(tester, r'\[x+y+z', width: 180, streaming: true);
      expect(formula(tester), same(incomplete));
      expect(formula(tester).getSelectedContent(), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
