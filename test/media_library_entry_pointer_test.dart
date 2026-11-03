import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_root_entry.dart';
import 'package:video_player_app/models/media_library_root_entry_order.dart';
import 'package:video_player_app/widgets/media_library_entry_switcher.dart';

const _frame = Duration(milliseconds: 16);

class _PointerHarness extends StatefulWidget {
  const _PointerHarness({this.width = 600, this.reorderEnabled = true});

  final double width;
  final bool reorderEnabled;

  @override
  State<_PointerHarness> createState() => _PointerHarnessState();
}

class _PointerHarnessState extends State<_PointerHarness> {
  var selected = MediaLibraryRootEntry.folders;
  var order = List<MediaLibraryRootEntry>.of(
    MediaLibraryRootEntryOrder.defaults,
  );
  var selections = 0;
  var reorders = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(platform: TargetPlatform.windows),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: widget.width,
            height: 48,
            child: MediaLibraryEntrySwitcher(
              selected: selected,
              highlightIndex: order.indexOf(selected).toDouble(),
              entries: order,
              availableEntries: MediaLibraryRootEntry.values.toSet(),
              compact: true,
              reorderEnabled: widget.reorderEnabled,
              onReorder: (oldIndex, newIndex) => setState(() {
                reorders++;
                order = MediaLibraryRootEntryOrder.moved(
                  order,
                  oldIndex: oldIndex,
                  newIndex: newIndex,
                );
              }),
              onSelected: (entry) => setState(() {
                selections++;
                selected = entry;
              }),
            ),
          ),
        ),
      ),
    );
  }
}

Finder get _proxy => find.byWidgetPredicate(
  (widget) => widget is TooltipVisibility && !widget.visible,
);

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(MediaLibraryEntrySwitcher),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

Future<_PointerHarnessState> _pump(
  WidgetTester tester, {
  double width = 600,
  bool reorderEnabled = true,
}) async {
  await tester.pumpWidget(
    _PointerHarness(width: width, reorderEnabled: reorderEnabled),
  );
  await tester.pumpAndSettle();
  return tester.state<_PointerHarnessState>(find.byType(_PointerHarness));
}

void main() {
  testWidgets('mouse starts after a small movement and follows each frame', (
    tester,
  ) async {
    final state = await _pump(tester);
    final label = find.text('最近添加');
    final start = tester.getCenter(label);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(4, 0));
    await tester.pump(_frame);
    expect(_proxy, findsNothing);
    await gesture.moveBy(const Offset(4, 0));
    await tester.pump(_frame);
    expect(_proxy, findsOneWidget);
    expect(tester.getCenter(label).dx, closeTo(start.dx + 8, 2));
    final lifted = tester.getCenter(label).dx;
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(_frame);
    expect(tester.getCenter(label).dx, closeTo(lifted + 40, 0.5));
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump(_frame);
    expect(tester.getCenter(label).dx, closeTo(lifted + 20, 0.5));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(state.selections, 0);
    expect(state.reorders, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fast mouse reorder owns a narrow row and keeps its viewport', (
    tester,
  ) async {
    final state = await _pump(tester, width: 200);
    final position = _position(tester);
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final parked = position.pixels;
    final target = tester.getCenter(find.text('哔哩哔哩'));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('网盘')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-8, 0));
    await tester.pump(_frame);
    expect(_proxy, findsOneWidget);
    await gesture.moveTo(target);
    await tester.pump(_frame);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.order.indexOf(MediaLibraryRootEntry.cloudDrive), 3);
    expect(state.reorders, 1);
    expect(state.selections, 0);
    expect(position.pixels, closeTo(parked, 0.01));
    expect(tester.takeException(), isNull);
  });

  for (final hold in [Duration.zero, const Duration(milliseconds: 700)]) {
    testWidgets('mouse click tolerates small jitter and a $hold hold', (
      tester,
    ) async {
      final state = await _pump(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('最近添加')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(3, 2));
      await tester.pump(hold);
      expect(_proxy, findsNothing);
      expect(state.selections, 0);
      await gesture.up();
      expect(state.selected, MediaLibraryRootEntry.recent);
      expect(state.selections, 1);
      await tester.pumpAndSettle();
      expect(state.reorders, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a mouse drag returning to its origin cannot become a click', (
    tester,
  ) async {
    final state = await _pump(tester);
    final start = tester.getCenter(find.text('最近添加'));
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump(_frame);
    expect(_proxy, findsOneWidget);
    await gesture.moveTo(start);
    await tester.pump(_frame);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.selections, 0);
    expect(state.reorders, 0);
    expect(state.order, MediaLibraryRootEntryOrder.defaults);
  });

  testWidgets('vertical mouse movement cancels the click without reordering', (
    tester,
  ) async {
    final state = await _pump(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('最近添加')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(_frame);
    await gesture.moveBy(const Offset(20, 0));
    await tester.pump(_frame);
    expect(_proxy, findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(state.selections, 0);
    expect(state.reorders, 0);
  });

  for (final buttons in [
    kSecondaryMouseButton,
    kMiddleMouseButton,
    kPrimaryMouseButton | kSecondaryMouseButton,
  ]) {
    testWidgets('mouse buttons=$buttons neither select nor reorder', (
      tester,
    ) async {
      final state = await _pump(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('最近添加')),
        kind: PointerDeviceKind.mouse,
        buttons: buttons,
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump(_frame);
      expect(_proxy, findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(state.selections, 0);
      expect(state.reorders, 0);
    });
  }

  testWidgets('spurious Windows deltas cannot move the mouse reorder proxy', (
    tester,
  ) async {
    final state = await _pump(tester);
    final label = find.text('最近添加');
    final start = tester.getCenter(label);
    final gesture = await tester.startGesture(
      start,
      pointer: 741,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.updateWithCustomEvent(
      PointerMoveEvent(
        pointer: 741,
        device: 1,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
        position: start,
        delta: const Offset(500, 0),
      ),
    );
    await tester.pump(_frame);
    expect(_proxy, findsNothing);
    await gesture.moveBy(const Offset(8, 0));
    await tester.pump(_frame);
    expect(_proxy, findsOneWidget);
    expect(tester.getCenter(label).dx, closeTo(start.dx + 8, 2));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(state.selections, 0);
    expect(state.reorders, 0);
  });

  testWidgets('mouse cancellation leaves the next click available', (
    tester,
  ) async {
    final state = await _pump(tester);
    final label = find.text('最近添加');
    final gesture = await tester.startGesture(
      tester.getCenter(label),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(state.selections, 0);
    await tester.tap(label, kind: PointerDeviceKind.mouse);
    expect(state.selections, 1);
    await tester.pumpAndSettle();
    expect(state.reorders, 0);
  });

  testWidgets('quick touch swipe scrolls while a held touch can reorder', (
    tester,
  ) async {
    final state = await _pump(tester, width: 200);
    final position = _position(tester);
    final start = position.pixels;
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('文件夹')),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump(_frame);
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump(_frame);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(start));
    expect(state.selections, 0);
    expect(state.reorders, 0);

    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    final target = tester.getCenter(find.text('哔哩哔哩'));
    final hold = await tester.startGesture(tester.getCenter(find.text('网盘')));
    await tester.pump(kLongPressTimeout + _frame);
    expect(_proxy, findsOneWidget);
    await hold.moveTo(target);
    await tester.pump(_frame);
    await hold.up();
    await tester.pumpAndSettle();
    expect(state.order.indexOf(MediaLibraryRootEntry.cloudDrive), 3);
    expect(state.reorders, 1);
    expect(state.selections, 0);
  });

  testWidgets('wheel scrolling does not select a page or reorder titles', (
    tester,
  ) async {
    final state = await _pump(tester, width: 200);
    final position = _position(tester);
    final start = position.pixels;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(MediaLibraryEntrySwitcher)),
        scrollDelta: const Offset(0, 80),
      ),
    );
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(start));
    expect(state.selections, 0);
    expect(state.reorders, 0);
  });

  testWidgets('trackpad panning scrolls without selecting or reordering', (
    tester,
  ) async {
    final state = await _pump(tester, width: 200);
    final position = _position(tester);
    final start = position.pixels;
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    final origin = tester.getCenter(find.byType(MediaLibraryEntrySwitcher));
    await gesture.panZoomStart(origin);
    await gesture.panZoomUpdate(origin, pan: const Offset(-40, 0));
    await tester.pump(_frame);
    await gesture.panZoomUpdate(origin, pan: const Offset(-80, 0));
    await tester.pump(_frame);
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(start));
    expect(_proxy, findsNothing);
    expect(state.selections, 0);
    expect(state.reorders, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a row with reordering disabled still supports mouse scrolling', (
    tester,
  ) async {
    final state = await _pump(tester, width: 200, reorderEnabled: false);
    final position = _position(tester);
    final start = position.pixels;
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('文件夹')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump(_frame);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(start));
    expect(state.selections, 0);
    expect(state.reorders, 0);
  });
}
