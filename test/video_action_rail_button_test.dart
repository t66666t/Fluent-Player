import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/video_action_rail_button.dart';
import 'package:video_player_app/widgets/video_action_rail_layout.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    ValueNotifier<bool> collapsed, {
    required VoidCallback onPressed,
    required VoidCallback onBackground,
    bool toggle = true,
    bool showLabel = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBackground,
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
              Center(
                child: ValueListenableBuilder<bool>(
                  valueListenable: collapsed,
                  builder: (context, value, _) => VideoActionRailButton(
                    label: toggle ? (value ? '展开' : '收起') : '网页导入',
                    tooltip: toggle ? (value ? '展开' : '收起') : '浏览器导入',
                    icon: toggle
                        ? Icons.keyboard_arrow_up
                        : Icons.language_rounded,
                    isToggle: toggle,
                    isCollapsed: value,
                    showLabel: showLabel,
                    layout: VideoActionRailLayout.resolve(
                      screenSize: const Size(390, 844),
                      availableWidth: 358,
                      availableHeight: 600,
                      textScaler: TextScaler.noScaling,
                      showLabels: showLabel,
                      actionCount: 1,
                    ),
                    onPressed: onPressed,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('caption taps are inert and do not reach the covered media', (
    tester,
  ) async {
    final collapsed = ValueNotifier(false);
    addTearDown(collapsed.dispose);
    var actions = 0, background = 0;
    await mount(
      tester,
      collapsed,
      toggle: false,
      onPressed: () => actions++,
      onBackground: () => background++,
    );
    final caption = find.byKey(const ValueKey('action-label-backplate-网页导入'));
    await tester.tapAt(tester.getCenter(caption));
    await tester.pump();
    expect(actions, 0);
    expect(background, 0);

    final disc = find.byKey(const ValueKey('action-button-disc-网页导入'));
    final rect = tester.getRect(disc);
    // This point is inside the square bounds but outside the circular surface.
    await tester.tapAt(rect.topLeft + const Offset(1, 1));
    await tester.pump();
    expect(actions, 0);
    await tester.tapAt(rect.center);
    await tester.pump();
    expect(actions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggle caption never changes the expanded state', (
    tester,
  ) async {
    final collapsed = ValueNotifier(true);
    addTearDown(collapsed.dispose);
    var actions = 0, background = 0;
    await mount(
      tester,
      collapsed,
      onPressed: () {
        actions++;
        collapsed.value = !collapsed.value;
      },
      onBackground: () => background++,
    );

    await tester.tapAt(tester.getCenter(find.text('展开')));
    await tester.pumpAndSettle();
    expect(collapsed.value, isTrue);
    expect(actions, 0);
    expect(background, 0);
    await tester.tap(find.byKey(const ValueKey('action-button-disc-toggle')));
    await tester.pumpAndSettle();
    expect(collapsed.value, isFalse);
    await tester.tapAt(tester.getCenter(find.text('收起')));
    await tester.pumpAndSettle();
    expect(collapsed.value, isFalse);
    expect(actions, 1);
    expect(background, 0);
  });

  testWidgets(
    'only the idle toggle surface fades and its arrow follows the same progress',
    (tester) async {
      final collapsed = ValueNotifier(true);
      addTearDown(collapsed.dispose);
      await mount(
        tester,
        collapsed,
        onPressed: () => collapsed.value = !collapsed.value,
        onBackground: () {},
      );
      final disc = find.byKey(const ValueKey('action-button-disc-toggle'));
      double alpha() => tester.widget<Material>(disc).color!.a;
      double rotation() {
        final transform = tester
            .widget<Transform>(
              find.descendant(of: disc, matching: find.byType(Transform)).first,
            )
            .transform;
        return math.atan2(transform.entry(1, 0), transform.entry(0, 0));
      }

      expect(alpha(), closeTo(0.30, 0.001));
      expect(rotation(), closeTo(0, 0.001));
      expect(
        tester.widget<Text>(find.text('展开')).style!.color,
        AppTokens.text1,
      );
      final back = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('action-label-backplate-展开')),
      );
      expect((back.decoration as BoxDecoration).color, AppTokens.bgBase);

      await tester.tap(disc);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final openingAlpha = alpha();
      expect(openingAlpha, greaterThan(0.30));
      expect(openingAlpha, lessThan(1));
      expect(
        rotation() / math.pi,
        closeTo((openingAlpha - 0.30) / 0.70, 0.001),
      );
      await tester.pumpAndSettle();
      expect(alpha(), closeTo(1, 0.001));
      expect(rotation(), closeTo(math.pi, 0.001));

      await tester.tap(disc);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final closingAlpha = alpha();
      expect(closingAlpha, greaterThan(0.30));
      expect(closingAlpha, lessThan(1));
      expect(
        rotation() / math.pi,
        closeTo((closingAlpha - 0.30) / 0.70, 0.001),
      );
      await tester.pumpAndSettle();
      expect(alpha(), closeTo(0.30, 0.001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reversing the fade has no color or rotation jump', (
    tester,
  ) async {
    final collapsed = ValueNotifier(true);
    addTearDown(collapsed.dispose);
    await mount(
      tester,
      collapsed,
      onPressed: () => collapsed.value = !collapsed.value,
      onBackground: () {},
    );
    final disc = find.byKey(const ValueKey('action-button-disc-toggle'));
    double alpha() => tester.widget<Material>(disc).color!.a;
    await tester.tap(disc);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final before = alpha();
    await tester.tap(disc);
    await tester.pump();
    expect(alpha(), closeTo(before, 0.001));
    await tester.pump(const Duration(milliseconds: 80));
    expect(alpha(), lessThan(before));
    await tester.pumpAndSettle();
    expect(alpha(), closeTo(0.30, 0.001));
  });

  testWidgets(
    'ordinary action surfaces remain opaque even when collapsed is true',
    (tester) async {
      final collapsed = ValueNotifier(true);
      addTearDown(collapsed.dispose);
      await mount(
        tester,
        collapsed,
        toggle: false,
        showLabel: false,
        onPressed: () {},
        onBackground: () {},
      );
      final disc = find.byKey(const ValueKey('action-button-disc-网页导入'));
      expect(tester.widget<Material>(disc).color!.a, 1);
      expect(find.text('网页导入'), findsNothing);
      expect(tester.getSize(disc), const Size.square(44));
    },
  );
}
