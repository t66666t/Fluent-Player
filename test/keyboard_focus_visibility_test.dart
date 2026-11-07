import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';
import 'package:video_player_app/utils/keyboard_focus_visibility.dart';

void main() {
  for (final kind in [
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
  ]) {
    testWidgets('$kind fades focus after a click and navigation restores it', (
      tester,
    ) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Focus(
                  focusNode: focus,
                  autofocus: true,
                  child: KeyboardFocusHighlight(
                    key: const ValueKey('outline'),
                    focused: true,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.lightBlueAccent,
                        width: 2,
                      ),
                    ),
                    child: const SizedBox(width: 100, height: 40),
                  ),
                ),
                GestureDetector(
                  onTap: () => taps++,
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox(
                    key: ValueKey('pointer-target'),
                    width: 100,
                    height: 80,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(focus.hasPrimaryFocus, isTrue);
      expect(_outlineAlpha(tester), 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(_outlineAlpha(tester), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(_outlineAlpha(tester), 1);

      final click = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('pointer-target'))),
        kind: kind,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(_outlineAlpha(tester), inExclusiveRange(0, 1));
      expect(focus.hasPrimaryFocus, isTrue);
      await click.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(_outlineAlpha(tester), 0);
      expect(focus.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(
        const PointerHoverEvent(
          position: Offset(220, 160),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();
      expect(_outlineAlpha(tester), 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(_outlineAlpha(tester), 1);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Tab shows button focus, pointer hides it without clearing focus',
    (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      var activated = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appInteractionTheme(ThemeData.dark()),
          home: KeyboardFocusTheme(
            child: Scaffold(
              body: Center(
                child: TextButton(
                  focusNode: focus,
                  onPressed: () => activated++,
                  child: const Text('Action'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(focus.hasPrimaryFocus, isTrue);
      BorderSide? side() => Theme.of(
        tester.element(find.text('Action')),
      ).textButtonTheme.style?.side?.resolve({WidgetState.focused});
      expect(side()?.color.a, 1);
      await tester.tap(find.text('Action'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(focus.hasPrimaryFocus, isTrue);
      expect(activated, 1);
      expect(side()?.color.a ?? 0, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(side()?.color.a, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(activated, 2);
    },
  );

  testWidgets('reduced motion switches focus feedback without an animation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: KeyboardFocusHighlight(
              key: const ValueKey('outline'),
              focused: true,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.lightBlueAccent),
              ),
              child: const SizedBox(width: 100, height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_outlineAlpha(tester), 1);
  });
}

double _outlineAlpha(WidgetTester tester) {
  final paint = find.descendant(
    of: find.byKey(const ValueKey('outline')),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is DecoratedBox &&
          widget.position == DecorationPosition.foreground,
    ),
  );
  return (tester.widget<DecoratedBox>(paint).decoration as BoxDecoration)
      .border!
      .top
      .color
      .a;
}
