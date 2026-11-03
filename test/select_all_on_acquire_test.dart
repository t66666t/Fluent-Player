import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/select_all_on_acquire.dart';

void main() {
  const sample = 'https://lesson.example/one extra';

  Future<TextEditingController> pumpField(
    WidgetTester tester, {
    TargetPlatform? platform,
    String text = sample,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = TextEditingController(text: text);
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectAllOnAcquire(
            controller: controller,
            focusNode: focus,
            builder: (context, onTap) => TextField(
              key: const ValueKey('acquire-field'),
              controller: controller,
              focusNode: focus,
              selectAllOnFocus: true,
              onTap: onTap,
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  Finder field() => find.byKey(const ValueKey('acquire-field'));

  void expectEntire(TextEditingController controller) {
    expect(controller.selection.baseOffset, controller.text.length);
    expect(controller.selection.extentOffset, 0);
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('entering tap selects all on $platform, the next tap does not', (
      tester,
    ) async {
      final controller = await pumpField(tester, platform: platform);
      try {
        await tester.tap(field(), kind: PointerDeviceKind.mouse);
        await tester.pump();
        expectEntire(controller);

        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(field(), kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(controller.selection.isCollapsed, isTrue);
        expect(controller.text, sample);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('a finger tap follows the same enter-then-edit rule', (
    tester,
  ) async {
    final controller = await pumpField(tester);
    await tester.tap(field(), kind: PointerDeviceKind.touch);
    await tester.pump();
    expectEntire(controller);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(field(), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(controller.selection.isCollapsed, isTrue);
  });

  testWidgets('leaving the field arms the next entry again', (tester) async {
    final controller = await pumpField(tester);
    await tester.tap(field());
    await tester.pump();
    expectEntire(controller);
    tester.widget<TextField>(field()).focusNode!.unfocus();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<TextField>(field()).focusNode!.hasFocus, isFalse);
    await tester.tap(field());
    await tester.pump();
    expectEntire(controller);
  });

  testWidgets('a drag does not replace the gesture with a full selection', (
    tester,
  ) async {
    final controller = await pumpField(tester);
    final start = tester.getTopLeft(field()) + const Offset(12, 16);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(48, 0));
    await gesture.up();
    await tester.pump();
    final selection = controller.selection;
    final replacedEntireValue =
        selection.baseOffset == controller.text.length &&
        selection.extentOffset == 0;
    expect(replacedEntireValue, isFalse);
  });

  testWidgets('shift-click does not select the whole value', (tester) async {
    final controller = await pumpField(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(field(), kind: PointerDeviceKind.mouse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    final selection = controller.selection;
    final replacedEntireValue =
        selection.baseOffset == controller.text.length &&
        selection.extentOffset == 0;
    expect(replacedEntireValue, isFalse);
  });

  testWidgets('an empty field stays collapsed', (tester) async {
    final controller = await pumpField(tester, text: '');
    await tester.tap(field());
    await tester.pump();
    expect(controller.selection.isCollapsed, isTrue);
  });

  testWidgets('a long-press keeps the word instead of selecting everything', (
    tester,
  ) async {
    final controller = await pumpField(tester);
    await tester.longPress(field());
    await tester.pump();
    final selection = controller.selection;
    final replacedEntireValue =
        selection.baseOffset == controller.text.length &&
        selection.extentOffset == 0;
    expect(replacedEntireValue, isFalse);
  });

  testWidgets('double-tap selects a word instead of forcing the whole value', (
    tester,
  ) async {
    final controller = await pumpField(tester);
    await tester.tap(field());
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(field());
    await tester.pump();
    expect(controller.selection.isCollapsed, isFalse);
    expect(controller.selection.end - controller.selection.start, lessThan(sample.length));
  });
}
