import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_inline_math_viewport.dart';

class _BaselineBox extends LeafRenderObjectWidget {
  const _BaselineBox({
    super.key,
    required this.width,
    required this.height,
    required this.baseline,
  });

  final double width, height, baseline;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBaselineBox(width, height, baseline);
}

class _RenderBaselineBox extends RenderBox {
  _RenderBaselineBox(this.width, this.height, this.baseline);

  final double width, height, baseline;

  @override
  void performLayout() => size = computeDryLayout(constraints);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(Size(width, height));

  @override
  double computeMinIntrinsicWidth(double height) => width;

  @override
  double computeMaxIntrinsicWidth(double height) => width;

  @override
  double computeMinIntrinsicHeight(double width) => height;

  @override
  double computeMaxIntrinsicHeight(double width) => height;

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) =>
      this.baseline;

  @override
  double computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => this.baseline;

  @override
  void paint(PaintingContext context, Offset offset) => context.canvas.drawRect(
    offset & size,
    Paint()..color = const Color(0xff00ff00),
  );

  @override
  bool hitTestSelf(Offset position) => true;
}

class _BaselineProbe extends SingleChildRenderObjectWidget {
  const _BaselineProbe({required super.child});

  @override
  _RenderBaselineProbe createRenderObject(BuildContext context) =>
      _RenderBaselineProbe();
}

class _RenderBaselineProbe extends RenderProxyBox {
  double? actualBaseline;

  @override
  void performLayout() {
    super.performLayout();
    // Actual baselines may only be queried by the parent during layout/paint.
    actualBaseline = child?.getDistanceToBaseline(
      TextBaseline.alphabetic,
      onlyReal: true,
    );
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required double childWidth,
    double width = 120,
    double height = 40,
    double baseline = 27,
    ScrollController? controller,
    Widget Function(Widget child)? wrapper,
  }) async {
    Widget child = _BaselineProbe(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: AiInlineMathViewport(
          controller: controller,
          child: _BaselineBox(
            key: ValueKey((childWidth, height, baseline)),
            width: childWidth,
            height: height,
            baseline: baseline,
          ),
        ),
      ),
    );
    if (wrapper != null) child = wrapper(child);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  RenderAiInlineMathViewport viewport(WidgetTester tester) =>
      tester.allRenderObjects.whereType<RenderAiInlineMathViewport>().single;

  double? measuredBaseline(WidgetTester tester) => tester.allRenderObjects
      .whereType<_RenderBaselineProbe>()
      .single
      .actualBaseline;

  testWidgets('short formulas use natural width and preserve every baseline', (
    tester,
  ) async {
    for (final dimensions in [(18.0, 12.0), (45.0, 31.0), (80.0, 19.0)]) {
      await mount(
        tester,
        childWidth: 37,
        height: dimensions.$1,
        baseline: dimensions.$2,
      );
      final render = viewport(tester);
      expect(render.size, Size(37, dimensions.$1));
      expect(measuredBaseline(tester), dimensions.$2);
      expect(
        render.getDryBaseline(
          const BoxConstraints(maxWidth: 120),
          TextBaseline.alphabetic,
        ),
        dimensions.$2,
      );
      expect(
        render.getDryLayout(const BoxConstraints(maxWidth: 120)),
        render.size,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'wide formulas scroll, clip and retain the mathematical baseline',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await mount(tester, childWidth: 400, controller: controller);
      final render = viewport(tester);
      expect(render.size, const Size(120, 40));
      expect(render.child!.size, const Size(400, 40));
      expect(measuredBaseline(tester), 27);
      expect(
        render.describeApproximatePaintClip(render.child!),
        const Rect.fromLTWH(0, 0, 120, 40),
      );
      expect(controller.position.maxScrollExtent, 280);
      await tester.drag(
        find.byType(AiInlineMathViewport),
        const Offset(-90, 0),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(0));
      expect(measuredBaseline(tester), 27);
      expect(
        render.getDryBaseline(
          const BoxConstraints(maxWidth: 120),
          TextBaseline.alphabetic,
        ),
        27,
      );
      final shifted =
          render.child!.localToGlobal(Offset.zero) -
          render.localToGlobal(Offset.zero);
      expect(shifted.dx, closeTo(-controller.offset, .001));
      expect(shifted.dy, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('horizontal mouse wheel scrolls only overflowing formulas', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await mount(tester, childWidth: 400, controller: controller);
    final position = tester.getCenter(find.byType(AiInlineMathViewport));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        kind: ui.PointerDeviceKind.mouse,
        position: position,
        scrollDelta: const Offset(65, 0),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, 65);
    await mount(tester, childWidth: 40, controller: controller);
    expect(controller.offset, 0);
    expect(controller.position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short formulas leave mouse selection drags to the ancestor', (
    tester,
  ) async {
    var updates = 0;
    await mount(
      tester,
      childWidth: 90,
      wrapper: (child) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (_) => updates++,
        child: child,
      ),
    );
    await tester.drag(
      find.byType(AiInlineMathViewport),
      const Offset(-45, 0),
      kind: ui.PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(updates, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline formulas leave vertical scrolling to the message', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await mount(
      tester,
      childWidth: 90,
      wrapper: (child) => SizedBox(
        width: 200,
        height: 160,
        child: SingleChildScrollView(
          controller: controller,
          child: SizedBox(
            height: 600,
            child: Padding(
              padding: const EdgeInsets.only(top: 40),
              child: Align(alignment: Alignment.topLeft, child: child),
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(AiInlineMathViewport), const Offset(0, -70));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('supports table intrinsic and dry layout without LayoutBuilder', (
    tester,
  ) async {
    await mount(
      tester,
      childWidth: 300,
      wrapper: (child) => IntrinsicWidth(
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          children: [
            TableRow(children: [child, const Text('说明')]),
          ],
        ),
      ),
    );
    expect(viewport(tester).size, const Size(120, 40));
    expect(viewport(tester).getMinIntrinsicWidth(40), 300);
    expect(viewport(tester).getMaxIntrinsicWidth(40), 300);
    expect(tester.takeException(), isNull);
  });
}
