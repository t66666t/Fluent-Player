import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/android_hardware_input_bridge.dart';
import 'package:video_player_app/utils/tooltip_hover_policy.dart';
import 'package:video_player_app/widgets/tooltip_interaction_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(TooltipHoverPolicy.resetForTesting);

  testWidgets('hover tooltip waits then hides when a finger goes down', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          tooltipTheme: const TooltipThemeData(
            waitDuration: kAppTooltipWaitDuration,
          ),
        ),
        home: TooltipInteractionGuard(
          child: Scaffold(
            body: Center(
              child: Tooltip(
                message: '静音',
                child: const SizedBox(
                  key: ValueKey<String>('tooltip-target'),
                  width: 48,
                  height: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final target = tester.getCenter(find.byKey(const ValueKey('tooltip-target')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(target);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('静音'), findsNothing);

    await tester.pump(kAppTooltipWaitDuration);
    expect(find.text('静音'), findsOneWidget);

    final touch = await tester.createGesture(kind: PointerDeviceKind.touch);
    await touch.down(const Offset(8, 8));
    await tester.pump();
    expect(find.text('静音'), findsNothing);
    expect(TooltipHoverPolicy.suppressSyntheticHover, isTrue);
    await touch.up();
  });

  testWidgets('Android synthetic hover is ignored while a touch is active', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          tooltipTheme: const TooltipThemeData(
            waitDuration: kAppTooltipWaitDuration,
          ),
        ),
        home: TooltipInteractionGuard(
          child: Scaffold(
            body: Center(
              child: Tooltip(
                message: '字幕开关',
                child: const SizedBox(
                  key: ValueKey<String>('tooltip-target'),
                  width: 48,
                  height: 48,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final target = tester.getCenter(find.byKey(const ValueKey('tooltip-target')));
    final touch = await tester.createGesture(kind: PointerDeviceKind.touch);
    await touch.down(const Offset(8, 8));
    await tester.pump();

    AndroidHardwareInputBridge.dispatchNativeHoverForTesting(<Object?, Object?>{
      'action': 9,
      'x': target.dx,
      'y': target.dy,
      'eventTime': 10,
      'deviceId': 77,
    });
    AndroidHardwareInputBridge.dispatchNativeHoverForTesting(<Object?, Object?>{
      'action': 7,
      'x': target.dx,
      'y': target.dy,
      'eventTime': 20,
      'deviceId': 77,
    });
    await tester.pump(kAppTooltipWaitDuration);
    expect(find.text('字幕开关'), findsNothing);

    await touch.up();
    await tester.pump();
    AndroidHardwareInputBridge.dispatchNativeHoverForTesting(<Object?, Object?>{
      'action': 9,
      'x': target.dx,
      'y': target.dy,
      'eventTime': 30,
      'deviceId': 77,
    });
    await tester.pump(kAppTooltipWaitDuration);
    expect(find.text('字幕开关'), findsNothing);

    AndroidHardwareInputBridge.dispatchNativeHoverForTesting(<Object?, Object?>{
      'action': 7,
      'x': target.dx + 12,
      'y': target.dy,
      'eventTime': 35,
      'deviceId': 77,
    });
    await tester.pump(kAppTooltipWaitDuration);
    expect(find.text('字幕开关'), findsOneWidget);

    AndroidHardwareInputBridge.dispatchNativeHoverForTesting(<Object?, Object?>{
      'action': 10,
      'x': target.dx,
      'y': target.dy,
      'eventTime': 40,
      'deviceId': 77,
    });
  });
}
