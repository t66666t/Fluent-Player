import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'package:video_player_app/widgets/custom_drag.dart';

Widget button(String type, VoidCallback? action, {Key? key}) => switch (type) {
  'ink' => InkWell(
    key: key,
    onTap: action,
    child: const Center(child: Text('Run')),
  ),
  'icon' => IconButton(
    key: key,
    onPressed: action,
    icon: const Icon(Icons.settings),
  ),
  'filled' => FilledButton(
    key: key,
    onPressed: action,
    child: const Text('Run'),
  ),
  'outlined' => OutlinedButton(
    key: key,
    onPressed: action,
    child: const Text('Run'),
  ),
  'elevated' => ElevatedButton(
    key: key,
    onPressed: action,
    child: const Text('Run'),
  ),
  _ => TextButton(key: key, onPressed: action, child: const Text('Run')),
};

Future<void> mount(
  WidgetTester tester,
  Widget child, {
  TargetPlatform platform = TargetPlatform.windows,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: Center(child: SizedBox(width: 180, height: 64, child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('typed dropdowns and popup menus work on $platform', (
      tester,
    ) async {
      Object? selected;
      for (final value in <Object>[1, 'quality', TargetPlatform.android]) {
        Widget dropdown<T>(T value, {bool enabled = true}) =>
            DesktopButtonClickRegion(
              child: DropdownButton<T>(
                value: value,
                items: [
                  DropdownMenuItem<T>(
                    value: value,
                    child: const Text('choice'),
                  ),
                ],
                onChanged: enabled ? (T? next) => selected = next : null,
              ),
            );
        Widget typed({bool enabled = true}) => switch (value) {
          int v => dropdown<int>(v, enabled: enabled),
          String v => dropdown<String>(v, enabled: enabled),
          TargetPlatform v => dropdown<TargetPlatform>(v, enabled: enabled),
          _ => throw StateError('unexpected test value'),
        };
        await mount(tester, typed(), platform: platform);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('choice'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('choice').last);
        await tester.pumpAndSettle();
        expect(selected, value);
        selected = null;
        await mount(tester, typed(enabled: false), platform: platform);
        await tester.tap(find.text('choice'));
        await tester.pumpAndSettle();
        expect(selected, isNull);
        expect(find.text('choice'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await mount(
        tester,
        DesktopButtonClickRegion(
          child: PopupMenuButton<int>(
            onSelected: (int value) => selected = value,
            itemBuilder: (_) => [
              const PopupMenuItem<int>(value: 2, child: Text('popup choice')),
            ],
          ),
        ),
        platform: platform,
      );
      await tester.tap(find.byType(PopupMenuButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('popup choice'));
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
    });
  }
  for (final type in [
    'text',
    'icon',
    'filled',
    'outlined',
    'elevated',
    'ink',
  ]) {
    testWidgets('$type activates once after a moving mouse release inside', (
      tester,
    ) async {
      var calls = 0;
      const key = ValueKey('button');
      await mount(
        tester,
        DesktopButtonClickRegion(child: button(type, () => calls++, key: key)),
      );
      final rect = tester.getRect(find.byKey(key));
      final gesture = await tester.startGesture(
        Offset(rect.left + 6, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(rect.right - 6, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 16));
      expect(calls, 0);
      await gesture.up();
      expect(calls, 1);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('moving outside and returning can click the original button', (
    tester,
  ) async {
    var calls = 0;
    const key = ValueKey('button');
    await mount(
      tester,
      DesktopButtonClickRegion(
        child: button('filled', () => calls++, key: key),
      ),
    );
    final rect = tester.getRect(find.byKey(key));
    final gesture = await tester.startGesture(
      rect.center,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(rect.right + 30, rect.center.dy));
    await gesture.moveTo(Offset(rect.right - 3, rect.center.dy));
    await gesture.up();
    expect(calls, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('an outside release cancels even with very little movement', (
    tester,
  ) async {
    var calls = 0;
    const key = ValueKey('button');
    await mount(
      tester,
      DesktopButtonClickRegion(
        child: button('filled', () => calls++, key: key),
      ),
    );
    final rect = tester.getRect(find.byKey(key));
    final gesture = await tester.startGesture(
      Offset(rect.right - 1, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(rect.right + 1, rect.center.dy));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('moving to a different button does not activate either button', (
    tester,
  ) async {
    var calls = 0;
    const first = ValueKey('first');
    const second = ValueKey('second');
    await mount(
      tester,
      Row(
        children: [
          Expanded(
            child: DesktopButtonClickRegion(
              child: button('text', () => calls++, key: first),
            ),
          ),
          Expanded(
            child: DesktopButtonClickRegion(
              child: button('text', () => calls++, key: second),
            ),
          ),
        ],
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(first)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(tester.getCenter(find.byKey(second)));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('a genuine parent drag wins without an extra button click', (
    tester,
  ) async {
    var clicks = 0;
    var drags = 0;
    await mount(
      tester,
      GestureDetector(
        onPanUpdate: (_) => drags++,
        child: DesktopButtonClickRegion(
          child: button('filled', () => clicks++),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(20, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(drags, greaterThan(0));
    expect(clicks, 0);
  });

  testWidgets('touch movement keeps its original cancellation tolerance', (
    tester,
  ) async {
    var clicks = 0;
    await mount(
      tester,
      DesktopButtonClickRegion(child: button('filled', () => clicks++)),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
    );
    await gesture.moveBy(const Offset(30, 0));
    await gesture.moveBy(const Offset(-30, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(clicks, 0);
    await tester.tap(find.byType(FilledButton));
    expect(clicks, 1);
  });

  testWidgets('disabled, secondary and cancelled presses never activate', (
    tester,
  ) async {
    var calls = 0;
    await mount(
      tester,
      DesktopButtonClickRegion(child: button('filled', null)),
    );
    await tester.tap(find.byType(FilledButton), kind: PointerDeviceKind.mouse);
    expect(calls, 0);
    await mount(
      tester,
      DesktopButtonClickRegion(child: button('filled', () => calls++)),
    );
    final secondary = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await secondary.up();
    final cancelled = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
      pointer: 741,
      kind: PointerDeviceKind.mouse,
    );
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(DesktopButtonClickRegion.ownsPointer(741), isFalse);
  });

  testWidgets('keyboard activation uses the native button once', (
    tester,
  ) async {
    var calls = 0;
    final node = FocusNode();
    addTearDown(node.dispose);
    await mount(
      tester,
      DesktopButtonClickRegion(
        child: TextButton(
          focusNode: node,
          onPressed: () => calls++,
          child: const Text('Run'),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(calls, 1);
  });

  testWidgets('mobile keeps the original native movement rule', (tester) async {
    var calls = 0;
    await mount(
      tester,
      DesktopButtonClickRegion(child: button('filled', () => calls++)),
      platform: TargetPlatform.android,
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(30, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  for (final gate in ['ignore', 'absorb', 'offstage']) {
    testWidgets('a $gate gate cancels an already pressed button', (
      tester,
    ) async {
      var blocked = false;
      var calls = 0;
      late StateSetter update;
      await mount(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            final child = DesktopButtonClickRegion(
              child: button('filled', () => calls++),
            );
            return switch (gate) {
              'ignore' => IgnorePointer(ignoring: blocked, child: child),
              'absorb' => AbsorbPointer(absorbing: blocked, child: child),
              _ => Offstage(offstage: blocked, child: child),
            };
          },
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(FilledButton)),
        kind: PointerDeviceKind.mouse,
      );
      update(() => blocked = true);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a dedicated long-press action keeps native movement tolerance', (
    tester,
  ) async {
    var clicks = 0;
    var holds = 0;
    await mount(
      tester,
      DesktopButtonClickRegion(
        child: FilledButton(
          onPressed: () => clicks++,
          onLongPress: () => holds++,
          child: const Text('Run'),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(clicks, 0);
    expect(holds, 0);
    final hold = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await hold.up();
    await tester.pumpAndSettle();
    expect(holds, 1);
    expect(clicks, 0);
  });

  for (final replace in [false, true]) {
    testWidgets(
      'changing the pressed target cancels without a parent click, replace=$replace',
      (tester) async {
        var changed = false;
        var calls = 0;
        var parentClicks = 0;
        late StateSetter update;
        await mount(
          tester,
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Material(
                child: InkWell(
                  onTap: () => parentClicks++,
                  child: changed && !replace
                      ? const SizedBox.expand()
                      : DesktopButtonClickRegion(
                          child: button(
                            changed ? 'text' : 'filled',
                            () => calls++,
                          ),
                        ),
                ),
              );
            },
          ),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(FilledButton)),
          pointer: 744,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump(const Duration(milliseconds: 16));
        update(() => changed = true);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls, 0);
        expect(parentClicks, 0);
        expect(DesktopButtonClickRegion.ownsPointer(744), isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final initiallyEnabled in [false, true]) {
    testWidgets(
      'changing enabled state during a press cancels, initially=$initiallyEnabled',
      (tester) async {
        var enabled = initiallyEnabled;
        var calls = 0;
        var parentClicks = 0;
        late StateSetter update;
        await mount(
          tester,
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Material(
                child: InkWell(
                  onTap: () => parentClicks++,
                  child: DesktopButtonClickRegion(
                    child: button('filled', enabled ? () => calls++ : null),
                  ),
                ),
              );
            },
          ),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(FilledButton)),
          kind: PointerDeviceKind.mouse,
        );
        if (initiallyEnabled) {
          update(() => enabled = false);
          await tester.pump();
        }
        update(() => enabled = true);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls, 0);
        expect(parentClicks, 0);
        await tester.tap(
          find.byType(FilledButton),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(parentClicks, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('an ordinary rebuild keeps the current button click available', (
    tester,
  ) async {
    var version = 0;
    var calls = 0;
    late StateSetter update;
    await mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return DesktopButtonClickRegion(
            child: FilledButton(
              onPressed: () => calls++,
              child: Text('Run $version'),
            ),
          );
        },
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FilledButton)),
      kind: PointerDeviceKind.mouse,
    );
    update(() => version++);
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  for (final enabled in [true, false]) {
    testWidgets('a card child button owns its click, enabled=$enabled', (
      tester,
    ) async {
      var cardClicks = 0;
      var buttonClicks = 0;
      var drags = 0;
      const key = ValueKey('child-button');
      await mount(
        tester,
        GatedDraggable<int>(
          data: 1,
          feedback: const SizedBox.shrink(),
          onDragStarted: () => drags++,
          onTap: () => cardClicks++,
          child: Material(
            child: InkWell(
              onTap: () => cardClicks++,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Expanded(child: Center(child: Text('Card'))),
                  SizedBox(
                    width: 64,
                    child: DesktopButtonClickRegion(
                      child: TextButton(
                        key: key,
                        onPressed: enabled ? () => buttonClicks++ : null,
                        child: const Text('Menu'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byKey(key));
      final gesture = await tester.startGesture(
        Offset(rect.left + 5, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(rect.right - 5, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(buttonClicks, enabled ? 1 : 0);
      expect(cardClicks, 0);
      expect(drags, 0);
      await tester.tap(find.text('Card'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(cardClicks, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('keyed buttons keep their native element while reordered', (
    tester,
  ) async {
    final first = GlobalKey();
    final second = GlobalKey();
    var reversed = false;
    late StateSetter update;
    await mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          final keys = reversed ? [second, first] : [first, second];
          return Row(
            children: [
              for (final key in keys)
                DesktopButtonClickRegion(
                  child: button('text', () {}, key: key),
                ),
            ],
          );
        },
      ),
    );
    final original = first.currentContext;
    update(() => reversed = true);
    await tester.pumpAndSettle();
    expect(first.currentContext, same(original));
    expect(first.currentWidget, isA<TextButton>());
    expect(tester.takeException(), isNull);
  });
}
