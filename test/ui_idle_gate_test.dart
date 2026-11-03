import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/ui_idle_gate.dart';

void main() {
  testWidgets(
    'fifty lifecycles remove input observers and cancel pending work',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
      final router = tester.binding.pointerRouter;
      final original = router.debugGlobalRouteCount;
      for (var i = 0; i < 50; i++) {
        final gate = UiIdleGate();
        final pointer = await tester.startGesture(
          const Offset(20, 20),
          pointer: i + 100,
        );
        final waiting = gate.waitUntilIdle();
        gate.dispose();
        expect(await waiting, isFalse);
        await pointer.up();
        expect(router.debugGlobalRouteCount, original);
      }
    },
  );

  testWidgets('idle work does not request a frame or a repeating timer', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final gate = UiIdleGate();
    addTearDown(gate.dispose);
    var ready = false;
    gate.waitUntilIdle().then((value) => ready = value);
    await tester.idle();
    expect(ready, isTrue);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('a held pointer and its quiet period postpone optional work', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
    final gate = UiIdleGate();
    addTearDown(gate.dispose);
    final gesture = await tester.startGesture(const Offset(40, 40));
    var ready = false;
    gate.waitUntilIdle().then((value) => ready = value);
    await tester.pump(const Duration(seconds: 1));
    expect(ready, isFalse);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 119));
    expect(ready, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(ready, isTrue);
  });

  testWidgets('animation completion releases work without polling', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final gate = UiIdleGate();
    final animation = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 200),
    )..forward();
    addTearDown(() {
      animation.dispose();
      gate.dispose();
    });
    var ready = false;
    gate.waitUntilIdle().then((value) => ready = value);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(ready, isFalse);
    await tester.pump(const Duration(milliseconds: 150));
    expect(animation.isAnimating, isFalse);
    // The ticker may already have requested its final paint frame.
    await tester.pump();
    expect(ready, isTrue);
  });

  testWidgets('keyboard input keeps its normal dispatch and postpones warmup', (
    tester,
  ) async {
    var keysReceived = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Focus(
          autofocus: true,
          onKeyEvent: (_, _) {
            keysReceived++;
            return KeyEventResult.ignored;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pump();
    final gate = UiIdleGate();
    addTearDown(gate.dispose);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    var ready = false;
    gate.waitUntilIdle().then((value) => ready = value);
    await tester.pump(const Duration(milliseconds: 100));
    expect(ready, isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    await tester.pump(const Duration(milliseconds: 119));
    expect(ready, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(ready, isTrue);
    expect(keysReceived, 2);
  });

  testWidgets('background work waits for resume and disposal cancels a wait', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final gate = UiIdleGate();
    addTearDown(() {
      gate.dispose();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    var ready = false;
    gate.waitUntilIdle().then((value) => ready = value);
    await tester.pump(const Duration(seconds: 10));
    expect(ready, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(ready, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final cancelled = gate.waitUntilIdle();
    gate.dispose();
    expect(await cancelled, isFalse);
  });
}
