import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/video_action_rail.dart';
import 'package:video_player_app/widgets/video_action_rail_button.dart';
import 'package:video_player_app/widgets/video_action_rail_layout.dart';
import 'package:video_player_app/widgets/video_action_rail_motion.dart';

void main() {
  testWidgets('rapid retargeting preserves both position and velocity', (
    tester,
  ) async {
    final motion = VideoActionRailMotion(vsync: tester, expanded: false);
    addTearDown(motion.dispose);
    motion.setExpanded(true);
    await tester.pump();
    for (var tap = 0; tap < 80; tap++) {
      await tester.pump(Duration(milliseconds: [7, 11, 16, 23][tap % 4]));
      final position = motion.value;
      final velocity = motion.velocity;
      motion.setExpanded(tap.isOdd);
      expect(motion.value, closeTo(position, 0.000001));
      expect(motion.velocity, closeTo(velocity, 0.000001));
      expect(motion.value, inInclusiveRange(0, 1));
    }
    motion.setExpanded(false);
    await tester.pumpAndSettle();
    expect(motion.value, 0);
    expect(motion.isAnimating, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('fresh motion has no overshoot and finishes without idle ticks', (
    tester,
  ) async {
    final motion = VideoActionRailMotion(vsync: tester, expanded: false);
    addTearDown(motion.dispose);
    for (final expanded in [true, false]) {
      motion.setExpanded(expanded);
      await tester.pump();
      var previous = motion.value;
      for (var frame = 0; frame < 60 && motion.isAnimating; frame++) {
        await tester.pump(const Duration(milliseconds: 8));
        expect(motion.value, inInclusiveRange(0, 1));
        expect(
          (motion.value - previous) * (expanded ? 1 : -1),
          greaterThanOrEqualTo(-0.000001),
        );
        previous = motion.value;
      }
      expect(motion.value, expanded ? 1 : 0);
      expect(motion.isAnimating, isFalse);
    }
    expect(tester.binding.transientCallbackCount, 0);
  });

  for (final hz in [60, 90, 120, 144]) {
    testWidgets('paint motion at $hz Hz does not rebuild or relayout actions', (
      tester,
    ) async {
      final collapsed = ValueNotifier(true);
      addTearDown(collapsed.dispose);
      final pageWork = _Work();
      final actionWork = _Work();
      await tester.pumpWidget(
        _Harness(
          collapsed: collapsed,
          pageWork: pageWork,
          actionWork: actionWork,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action-button-disc-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final actionCounts = actionWork.counts;
      final pageCounts = pageWork.counts;
      final step = Duration(microseconds: (1000000 / hz).round());
      for (var frame = 0; frame < 8; frame++) {
        await tester.pump(step);
      }
      expect(actionWork.counts, actionCounts);
      expect(pageWork.counts, pageCounts);
      await tester.pumpAndSettle();
      expect(actionWork.builds, actionCounts.$1);
      expect(actionWork.layouts, actionCounts.$2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.binding.transientCallbackCount, 0);
    });
  }

  testWidgets('reduced motion and muted tickers settle immediately', (
    tester,
  ) async {
    final collapsed = ValueNotifier(true);
    addTearDown(collapsed.dispose);
    await tester.pumpWidget(_Harness(collapsed: collapsed));
    await tester.pumpAndSettle();
    collapsed.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(_progress(tester).value, inExclusiveRange(0, 1));
    await tester.pumpWidget(
      _Harness(collapsed: collapsed, disableAnimations: true),
    );
    await tester.pumpAndSettle();
    expect(_progress(tester).value, 1);
    expect(tester.binding.transientCallbackCount, 0);
    collapsed.value = true;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('action-rail-grid')), findsNothing);
    expect(find.text('展开'), findsOneWidget);
    await tester.pumpWidget(
      _Harness(collapsed: collapsed, tickerEnabled: false),
    );
    collapsed.value = false;
    await tester.pumpAndSettle();
    expect(_progress(tester).value, 1);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'one shared motion drives rows and toggle without label buildup',
    (tester) async {
      final collapsed = ValueNotifier(true);
      addTearDown(collapsed.dispose);
      await tester.pumpWidget(_Harness(collapsed: collapsed));
      await tester.pumpAndSettle();
      for (var tap = 0; tap < 40; tap++) {
        await tester.tap(
          find.byKey(const ValueKey('action-button-disc-toggle')),
        );
        await tester.pump();
        await tester.pump(Duration(milliseconds: [8, 16, 33][tap % 3]));
        final value = _progress(tester).value;
        final disc = tester.widget<Material>(
          find.byKey(const ValueKey('action-button-disc-toggle')),
        );
        final rotation = tester.widget<RotationTransition>(
          find.descendant(
            of: find.byKey(const ValueKey('action-button-disc-toggle')),
            matching: find.byType(RotationTransition),
          ),
        );
        expect(disc.color!.a, closeTo(0.30 + 0.70 * value, 0.000001));
        expect(rotation.turns.value, closeTo(value / 2, 0.000001));
        expect(find.text('展开').evaluate().length, lessThanOrEqualTo(1));
        expect(find.text('收起').evaluate().length, lessThanOrEqualTo(1));
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('action-rail-grid')), findsNothing);
      expect(find.text('展开'), findsOneWidget);
      expect(find.text('收起'), findsNothing);
    },
  );

  testWidgets('shared Flutter motion works with every platform theme', (
    tester,
  ) async {
    final collapsed = ValueNotifier(true);
    addTearDown(collapsed.dispose);
    for (final platform in TargetPlatform.values) {
      collapsed.value = true;
      await tester.pumpWidget(
        _Harness(
          key: ValueKey(platform),
          collapsed: collapsed,
          platform: platform,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('action-button-disc-toggle')));
      await tester.pumpAndSettle();
      expect(_progress(tester).value, 1);
      await tester.tap(find.byKey(const ValueKey('action-button-disc-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('action-rail-grid')), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}

Animation<double> _progress(WidgetTester tester) =>
    (tester
                .widget<Flow>(find.byKey(const ValueKey('action-rail-grid')))
                .delegate
            as VideoActionRailFlow)
        .progress;

class _Work {
  int builds = 0, layouts = 0, paints = 0;
  (int, int, int) get counts => (builds, layouts, paints);
}

class _Tracked extends StatelessWidget {
  const _Tracked({required this.work, required this.child});
  final _Work work;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    work.builds++;
    return _TrackedBox(work: work, child: child);
  }
}

class _TrackedBox extends SingleChildRenderObjectWidget {
  const _TrackedBox({required this.work, required super.child});
  final _Work work;

  @override
  RenderObject createRenderObject(BuildContext context) => _TrackedRender(work);
}

class _TrackedRender extends RenderProxyBox {
  _TrackedRender(this.work);
  final _Work work;

  @override
  void performLayout() {
    work.layouts++;
    super.performLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    work.paints++;
    super.paint(context, offset);
  }
}

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.collapsed,
    this.pageWork,
    this.actionWork,
    this.disableAnimations = false,
    this.tickerEnabled = true,
    this.platform = TargetPlatform.windows,
  });
  final ValueNotifier<bool> collapsed;
  final _Work? pageWork;
  final _Work? actionWork;
  final bool disableAnimations;
  final bool tickerEnabled;
  final TargetPlatform platform;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final scrollController = ScrollController();
  late final layout = VideoActionRailLayout.resolve(
    screenSize: const Size(390, 844),
    availableWidth: 358,
    availableHeight: 500,
    textScaler: TextScaler.noScaling,
    showLabels: true,
  );
  late final actions = [
    for (var index = 0; index < 8; index++)
      _Tracked(
        work: widget.actionWork ?? _Work(),
        child: VideoActionRailButton(
          label: '操作$index',
          tooltip: '操作$index',
          icon: Icons.folder,
          onPressed: () {},
          layout: layout,
          showLabel: true,
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.dark().copyWith(platform: widget.platform),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(disableAnimations: widget.disableAnimations),
      child: TickerMode(enabled: widget.tickerEnabled, child: child!),
    ),
    home: Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _Tracked(
              work: widget.pageWork ?? _Work(),
              child: const ColoredBox(color: Colors.black),
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: ValueListenableBuilder<bool>(
              valueListenable: widget.collapsed,
              builder: (context, collapsed, _) => VideoActionRail(
                layout: layout,
                maxHeight: 500,
                collapsed: collapsed,
                scrollController: scrollController,
                actions: actions,
                toggleBuilder: (progress) => VideoActionRailButton(
                  label: collapsed ? '展开' : '收起',
                  tooltip: collapsed ? '展开' : '收起',
                  icon: Icons.keyboard_arrow_up,
                  onPressed: () => widget.collapsed.value = !collapsed,
                  layout: layout,
                  showLabel: true,
                  isToggle: true,
                  isCollapsed: collapsed,
                  expansion: progress,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    scrollController.dispose();
    super.dispose();
  }
}
