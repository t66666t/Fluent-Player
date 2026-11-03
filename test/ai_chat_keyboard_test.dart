import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_layout.dart';

void main() {
  const composerKey = ValueKey('keyboard-composer');

  Future<void> mount(
    WidgetTester tester, {
    VoidCallback? onContentBuild,
    ValueNotifier<bool>? enabled,
  }) async {
    final enabledNotifier = enabled ?? ValueNotifier(true);
    if (enabled == null) addTearDown(enabledNotifier.dispose);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(bottom: 20);
    tester.view.padding = const FakeViewPadding(bottom: 20);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            maintainBottomViewPadding: true,
            child: ValueListenableBuilder<bool>(
              valueListenable: enabledNotifier,
              builder: (context, value, child) => AiKeyboardViewport(
                enabled: value,
                reservedBottomInset: 20,
                child: child!,
              ),
              child: Builder(
                builder: (context) {
                  onContentBuild?.call();
                  expect(
                    MediaQuery.viewInsetsOf(context).bottom,
                    enabledNotifier.value ? 0 : tester.view.viewInsets.bottom,
                  );
                  return const Column(
                    children: [
                      Expanded(child: SizedBox.expand()),
                      SizedBox(
                        key: composerKey,
                        height: 44,
                        width: double.infinity,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop single keyboard updates animate without double avoidance or content rebuilds',
    (tester) async {
      var builds = 0;
      await mount(tester, onContentBuild: () => builds++);
      final initialBuilds = builds;
      expect(tester.getRect(find.byKey(composerKey)).bottom, 780);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final intermediate = tester.getRect(find.byKey(composerKey)).bottom;
      expect(intermediate, greaterThan(480));
      expect(intermediate, lessThan(780));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(composerKey)).bottom, closeTo(480, .1));
      expect(builds, initialBuilds);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final closing = tester.getRect(find.byKey(composerKey)).bottom;
      expect(closing, greaterThan(480));
      expect(closing, lessThan(780));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(composerKey)).bottom, closeTo(780, .1));
      expect(builds, initialBuilds);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'animated native insets are followed each frame without another easing delay',
    (tester) async {
      await mount(tester);
      for (final inset in [
        24.0,
        48.0,
        80.0,
        120.0,
        160.0,
        200.0,
        240.0,
        280.0,
        320.0,
        280.0,
        240.0,
        200.0,
        160.0,
        120.0,
        80.0,
        48.0,
        24.0,
        0.0,
      ]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getRect(find.byKey(composerKey)).bottom,
          closeTo(800 - (inset < 20 ? 20 : inset), .1),
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'coalesced native keyboard frames never restart a second easing animation',
    (tester) async {
      await mount(tester);
      for (final inset in [
        16.0,
        64.0,
        156.0,
        300.0,
        320.0,
        272.0,
        160.0,
        80.0,
        0.0,
      ]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getRect(find.byKey(composerKey)).bottom,
          closeTo(800 - (inset < 20 ? 20 : inset), .1),
          reason: 'native inset=$inset must not start another animation',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile follows large first steps, pauses, height changes and dismissal immediately',
    (tester) async {
      var builds = 0;
      await mount(tester, onContentBuild: () => builds++);
      final initialBuilds = builds;
      for (final step in [
        (160.0, 8),
        (280.0, 8),
        (320.0, 180),
        (360.0, 300),
        (160.0, 180),
        (280.0, 8),
        (0.0, 200),
        (320.0, 300),
        (0.0, 300),
      ]) {
        tester.view.viewInsets = FakeViewPadding(bottom: step.$1);
        await tester.pump(Duration(milliseconds: step.$2));
        final expected = 800 - (step.$1 < 20 ? 20 : step.$1);
        expect(
          tester.getRect(find.byKey(composerKey)).bottom,
          closeTo(expected, .01),
          reason: 'native inset=${step.$1}, gap=${step.$2}ms',
        );
        await tester.pump(const Duration(milliseconds: 8));
        expect(
          tester.getRect(find.byKey(composerKey)).bottom,
          closeTo(expected, .01),
          reason: 'no extra app animation after the native update',
        );
        expect(tester.binding.transientCallbackCount, 0);
      }
      expect(builds, initialBuilds);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'mobile does not discard fractional native keyboard frames',
    (tester) async {
      await mount(tester);
      for (final inset in [44.0, 44.2, 44.4, 44.6, 44.3, 44.1]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump(const Duration(milliseconds: 8));
        expect(
          tester.getRect(find.byKey(composerKey)).bottom,
          closeTo(800 - inset, .01),
        );
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'an interrupted keyboard transition continues from its current position',
    (tester) async {
      await mount(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final before = tester.getRect(find.byKey(composerKey)).bottom;
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      expect(
        tester.getRect(find.byKey(composerKey)).bottom,
        closeTo(before, .1),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(composerKey)).bottom, closeTo(780, .1));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('leaving chat releases keyboard avoidance immediately', (
    tester,
  ) async {
    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    await mount(tester, enabled: enabled);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(composerKey)).bottom, closeTo(480, .1));
    enabled.value = false;
    await tester.pump();
    expect(tester.getRect(find.byKey(composerKey)).bottom, closeTo(780, .1));
    expect(tester.takeException(), isNull);
  });
}
