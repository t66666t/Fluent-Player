import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/keyboard_inset_padding.dart';

const _bar = ValueKey('keyboard-test-bar');
const _body = ValueKey('keyboard-test-body');

void main() {
  void configure(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
    addTearDown(tester.view.reset);
  }

  void keyboard(WidgetTester tester, double inset) {
    tester.view.viewInsets = FakeViewPadding(bottom: inset);
    tester.view.padding = FakeViewPadding(
      top: 24,
      bottom: math.max(0, 34 - inset),
    );
  }

  List<double> frames(Size size) {
    final peak = size.height < 500 ? 180.0 : 320.0;
    return [0, 24, 48, 80, peak / 2, peak, peak / 2, 80, 48, 24, 0];
  }

  for (final size in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(768, 1024),
    const Size(1280, 800),
  ]) {
    for (final resize in [true, false]) {
      testWidgets(
        'nested owners reserve once with Scaffold resize=$resize at $size',
        (tester) async {
          configure(tester, size);
          var builds = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                resizeToAvoidBottomInset: resize,
                body: KeyboardInsetPadding(
                  child: KeyboardInsetPadding(
                    child: SafeArea(
                      top: false,
                      child: Builder(
                        builder: (context) {
                          builds++;
                          expect(MediaQuery.viewInsetsOf(context).bottom, 0);
                          return const Column(
                            children: [
                              Expanded(child: SizedBox.expand()),
                              SizedBox(
                                key: _bar,
                                width: double.infinity,
                                height: 44,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final initialBuilds = builds;
          for (final inset in frames(size)) {
            keyboard(tester, inset);
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              tester.getRect(find.byKey(_bar)).bottom,
              closeTo(size.height - math.max(34, inset), .1),
              reason: 'the IME must be reserved once in the same frame',
            );
            expect(tester.takeException(), isNull);
          }
          expect(
            builds,
            initialBuilds,
            reason: 'unchanged content should not rebuild on IME frames',
          );
        },
      );
    }

    testWidgets('Dialog consumes keyboard before nested padding at $size', (
      tester,
    ) async {
      configure(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  insetAnimationDuration: Duration.zero,
                  insetPadding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: 600,
                    height: 600,
                    child: KeyboardInsetPadding(
                      child: Builder(
                        builder: (context) {
                          expect(MediaQuery.viewInsetsOf(context).bottom, 0);
                          return const SizedBox(
                            key: _body,
                            width: double.infinity,
                            height: double.infinity,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      for (final inset in frames(size)) {
        keyboard(tester, inset);
        await tester.pump(const Duration(milliseconds: 16));
        final bounds = tester.getRect(find.byKey(_body));
        expect(
          bounds.height,
          closeTo(
            math.min(600, size.height - 24 - math.max(34, inset) - 32),
            .1,
          ),
        );
        expect(bounds.bottom, lessThanOrEqualTo(size.height - inset - 16 + .1));
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('a draggable editor uses a fraction of the remaining height', (
    tester,
  ) async {
    configure(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              useSafeArea: true,
              isScrollControlled: true,
              builder: (_) => KeyboardInsetPadding(
                child: DraggableScrollableSheet(
                  initialChildSize: .65,
                  minChildSize: .4,
                  maxChildSize: .9,
                  expand: false,
                  builder: (_, controller) => SingleChildScrollView(
                    key: _body,
                    controller: controller,
                    child: const SizedBox(height: 1000),
                  ),
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    for (final inset in [0.0, 80.0, 160.0, 240.0, 320.0, 160.0, 0.0]) {
      keyboard(tester, inset);
      await tester.pump(const Duration(milliseconds: 16));
      final bounds = tester.getRect(find.byKey(_body));
      expect(bounds.height, closeTo((844 - 24 - inset) * .65, .1));
      expect(bounds.bottom, closeTo(844 - inset, .1));
      expect(tester.takeException(), isNull);
    }
  });
}
