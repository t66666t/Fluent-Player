import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/player_top_bar.dart';

void main() {
  var calls = 0;
  Future<void> mount(WidgetTester tester, {bool enabled = true}) async {
    calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 600,
              height: 48,
              child: PlayerTopBar(
                leading: const [],
                leadingWidth: 0,
                title: const Text('Video'),
                gap: 8,
                mirrored: false,
                buttonExtent: 40,
                iconSize: 20,
                buttonPadding: EdgeInsets.zero,
                actions: [
                  PlayerTopBarAction(
                    action: PlayerTopAction.settings,
                    button: IconButton(
                      key: const ValueKey('settings'),
                      icon: const Icon(Icons.settings),
                      onPressed: enabled ? () => calls++ : null,
                      constraints: const BoxConstraints.tightFor(
                        width: 40,
                        height: 40,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                    width: 40,
                    icon: Icons.settings,
                    label: 'Settings',
                    enabled: enabled,
                    onSelected: () => calls++,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('moving across the original player button still clicks once', (
    tester,
  ) async {
    await mount(tester);
    final rect = tester.getRect(find.byKey(const ValueKey('settings')));
    final gesture = await tester.startGesture(
      Offset(rect.left + 4, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(rect.right - 4, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 16));
    expect(calls, 0);
    await gesture.up();
    expect(calls, 1);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('releasing just outside the original player button cancels', (
    tester,
  ) async {
    await mount(tester);
    final rect = tester.getRect(find.byKey(const ValueKey('settings')));
    final gesture = await tester.startGesture(
      Offset(rect.right - 2, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(rect.right + 2, rect.center.dy));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('cancelled and disabled player buttons do not activate', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('settings'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.cancel();
    expect(calls, 0);
    await mount(tester, enabled: false);
    await tester.tap(
      find.byKey(const ValueKey('settings')),
      kind: PointerDeviceKind.mouse,
    );
    expect(calls, 0);
  });
}
