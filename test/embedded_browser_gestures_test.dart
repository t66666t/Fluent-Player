import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/embedded_browser_gestures.dart';

/// Accepts on pointer-down, the same moment a platform view's eager recognizer
/// claims a captcha drag.
class _Claim extends OneSequenceGestureRecognizer {
  _Claim(this.onResult);

  final ValueChanged<bool> onResult;
  var _reported = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    stopTrackingIfPointerNoLongerDown(event);
  }

  @override
  void acceptGesture(int pointer) {
    if (_reported) return;
    _reported = true;
    onResult(true);
  }

  @override
  void rejectGesture(int pointer) {
    if (_reported) return;
    _reported = true;
    onResult(false);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'claim';
}

void main() {
  testWidgets(
    'selection and mixed input never trigger ancestor gestures',
    (tester) async {
      var parentActions = 0;
      final moves = <PointerDeviceKind>{};
      await tester.pumpWidget(
        MaterialApp(
          home: GestureDetector(
            onTap: () => parentActions++,
            onDoubleTap: () => parentActions++,
            onLongPress: () => parentActions++,
            onPanUpdate: (_) => parentActions++,
            child: EmbeddedBrowserGestureBoundary(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerMove: (event) => moves.add(event.kind),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
        final gesture = await tester.startGesture(
          const Offset(100, 200),
          kind: kind,
        );
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveBy(const Offset(180, 20));
        await gesture.up();
        await tester.pumpAndSettle();
      }
      final first = await tester.startGesture(
        const Offset(100, 200),
        pointer: 10,
      );
      final second = await tester.startGesture(
        const Offset(200, 200),
        pointer: 11,
      );
      await first.moveBy(const Offset(-50, -10));
      await second.moveBy(const Offset(50, 10));
      await first.cancel();
      await second.up();
      await tester.pumpAndSettle();
      expect(moves, {PointerDeviceKind.touch, PointerDeviceKind.mouse});
      expect(parentActions, 0);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.all(),
  );

  testWidgets('browser surface and page swipe do not take each other', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pager = PageController();
    addTearDown(pager.dispose);
    bool? browserClaimed;
    var browserMoves = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PageView(
            controller: pager,
            children: [
              Column(
                children: [
                  const SizedBox(
                    height: 64,
                    child: Center(child: Text('页面工具条')),
                  ),
                  Expanded(
                    child: EmbeddedBrowserGestureBoundary(
                      child: RawGestureDetector(
                        behavior: HitTestBehavior.opaque,
                        gestures: <Type, GestureRecognizerFactory>{
                          _Claim: GestureRecognizerFactoryWithHandlers<_Claim>(
                            () => _Claim((won) => browserClaimed = won),
                            (_) {},
                          ),
                        },
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerMove: (_) => browserMoves++,
                          child: const SizedBox.expand(
                            child: Center(child: Text('浏览器')),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const Center(child: Text('下载队列')),
            ],
          ),
        ),
      ),
    );

    await tester.drag(find.text('浏览器'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(browserClaimed, isTrue);
    expect(browserMoves, greaterThan(0));
    expect(pager.page, 0);
    expect(find.text('下载队列').hitTestable(), findsNothing);

    await tester.drag(find.text('页面工具条'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(pager.page, greaterThan(0.5));
    expect(find.text('下载队列').hitTestable(), findsOneWidget);

    await tester.drag(find.text('下载队列'), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(pager.page, 0);
    expect(find.text('浏览器').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'texture browser still receives the drag the page no longer takes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pager = PageController();
      addTearDown(pager.dispose);
      var moves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView(
              controller: pager,
              children: [
                EmbeddedBrowserGestureBoundary(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerMove: (_) => moves++,
                    child: const SizedBox.expand(
                      child: Center(child: Text('纹理浏览器')),
                    ),
                  ),
                ),
                const Center(child: Text('另一页')),
              ],
            ),
          ),
        ),
      );
      await tester.drag(find.text('纹理浏览器'), const Offset(-300, 20));
      await tester.pumpAndSettle();
      expect(moves, greaterThan(0));
      expect(pager.page, 0);
      expect(find.text('另一页').hitTestable(), findsNothing);
    },
  );

  test('platform recognizer claims the sequence immediately', () {
    final created = embeddedBrowserGestureRecognizers
        .map((factory) => factory.constructor())
        .toList();
    addTearDown(() {
      for (final recognizer in created) {
        recognizer.dispose();
      }
    });
    expect(created.single, isA<EagerGestureRecognizer>());
  });
}
