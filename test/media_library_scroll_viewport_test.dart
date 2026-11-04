import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/media_library_scroll_viewport.dart';
import 'package:video_player_app/widgets/playback_source_viewport.dart';

final _thumb = find.byKey(MediaLibraryScrollViewport.thumbKey);

Widget _list(ScrollController controller, {int count = 100}) =>
    ListView.builder(
      controller: controller,
      itemExtent: 72,
      itemCount: count,
      itemBuilder: (_, index) => Text('Card $index'),
    );

Widget _frame(ScrollController controller, {Widget? child}) => MaterialApp(
  home: Scaffold(
    body: MediaLibraryScrollViewport(
      controller: controller,
      child: child ?? _list(controller),
    ),
  ),
);

void main() {
  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(844, 390),
    const Size(900, 1200),
    const Size(1440, 900),
    const Size(2560, 1440),
  ]) {
    testWidgets('$size: compact left thumb and symmetric gutters', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_frame(controller));
      await tester.pumpAndSettle();
      final thumb = tester.getRect(_thumb);
      final list = tester.getRect(find.byType(ListView));
      expect(thumb.height, inInclusiveRange(56, 88));
      expect(thumb.right, lessThanOrEqualTo(list.left));
      expect(list.left, inInclusiveRange(10, 20));
      if (size.width < 600) expect(list.left, lessThanOrEqualTo(14));
      expect(list.left, closeTo(size.width - list.right, .001));
      expect(find.byType(RawScrollbar), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('visibility follows content and resized viewport metrics', (
    tester,
  ) async {
    final controller = ScrollController();
    final count = ValueNotifier(1);
    addTearDown(controller.dispose);
    addTearDown(count.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 300);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _frame(
        controller,
        child: ValueListenableBuilder<int>(
          valueListenable: count,
          builder: (_, value, _) => _list(controller, count: value),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_thumb, findsNothing);
    final left = tester.getTopLeft(find.byType(ListView)).dx;
    count.value = 5;
    await tester.pumpAndSettle();
    expect(_thumb, findsOneWidget);
    // Even a list that only overflows by a little gets a short thumb.
    expect(tester.getSize(_thumb).height, lessThanOrEqualTo(88));
    expect(tester.getTopLeft(find.byType(ListView)).dx, left);
    tester.view.physicalSize = const Size(390, 600);
    await tester.pumpAndSettle();
    expect(_thumb, findsNothing);
    tester.view.physicalSize = const Size(390, 300);
    await tester.pumpAndSettle();
    expect(_thumb, findsOneWidget);
    count.value = 0;
    await tester.pumpAndSettle();
    expect(_thumb, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final kind in [
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
  ]) {
    testWidgets('${kind.name}: padded thumb drags to both ends', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_frame(controller));
      await tester.pumpAndSettle();
      var gesture = await tester.startGesture(
        tester.getCenter(_thumb) + const Offset(3, 0),
        kind: kind,
      );
      await gesture.moveBy(const Offset(0, 1000));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, controller.position.maxScrollExtent);
      gesture = await tester.startGesture(tester.getCenter(_thumb), kind: kind);
      await gesture.moveBy(const Offset(0, -1000));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(controller.offset, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'wheel works over cards and both gutters without double scrolling',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_frame(controller));
      await tester.pumpAndSettle();
      for (final point in [
        const Offset(300, 200),
        const Offset(5, 200),
        const Offset(795, 200),
      ]) {
        final before = controller.offset;
        await tester.sendEventToBinding(
          PointerScrollEvent(position: point, scrollDelta: const Offset(0, 90)),
        );
        await tester.pumpAndSettle();
        expect(controller.offset, closeTo(before + 90, .001));
      }
    },
  );

  testWidgets(
    'arrow repeats accumulate and input, modifiers and dialogs keep keys',
    (tester) async {
      final controller = ScrollController();
      final nav = GlobalKey<NavigatorState>();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            body: Column(
              children: [
                const TextField(),
                Expanded(
                  child: MediaLibraryScrollViewport(
                    controller: controller,
                    child: _list(controller),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(250));
      final down = controller.offset;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(controller.offset, lessThan(down));
      final before = controller.offset;
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
        expect(controller.offset, before);
      }
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.offset, before);
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(
        showDialog<void>(
          context: nav.currentContext!,
          builder: (_) => const AlertDialog(content: Text('Dialog')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.offset, before);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(before));
    },
  );

  testWidgets('kept-alive pages only scroll while active', (tester) async {
    final first = ScrollController();
    final second = ScrollController();
    final active = ValueNotifier(true);
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) => Stack(
              children: [
                for (final (controller, shown) in [
                  (first, value),
                  (second, !value),
                ])
                  Offstage(
                    offstage: !shown,
                    child: PlaybackViewportActivity(
                      active: shown,
                      child: MediaLibraryScrollViewport(
                        controller: controller,
                        child: _list(controller),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(first.offset, greaterThan(0));
    expect(second.offset, 0);
    final saved = first.offset;
    active.value = false;
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(first.offset, saved);
    expect(second.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'thumb clears playback overlays and stays left with reduced motion',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: MediaLibraryScrollViewport(
              controller: controller,
              bottomObstruction: 160,
              child: _list(controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final rect = tester.getRect(_thumb);
      expect(rect.left, 0);
      expect(rect.bottom, lessThanOrEqualTo(440));
      final before = controller.offset;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(controller.offset, lessThan(before));
      expect(controller.position.isScrollingNotifier.value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
