import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/exclusive_axis_drag_recognizer.dart';

void main() {
  testWidgets('an unfinished horizontal drag does not swallow the next tap', (
    tester,
  ) async {
    var taps = 0;
    var dragStarts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(),
                  (TapGestureRecognizer instance) {
                    instance.onTap = () => taps++;
                  },
                ),
            ExclusiveHorizontalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  ExclusiveHorizontalDragGestureRecognizer
                >(
                  () => ExclusiveHorizontalDragGestureRecognizer(),
                  (ExclusiveHorizontalDragGestureRecognizer instance) {
                    instance.onStart = (_) => dragStarts++;
                    instance.onEnd = (_) {};
                  },
                ),
          },
          child: const SizedBox.expand(),
        ),
      ),
    );

    final TestGesture drag = await tester.startGesture(const Offset(200, 200));
    await drag.moveBy(const Offset(48, 0));
    await tester.pump();
    expect(dragStarts, 1);

    // The first finger never lifts, which is the stuck multi-touch case.
    final TestGesture tap = await tester.startGesture(const Offset(40, 40));
    await tap.up();
    await tester.pump();

    expect(taps, 1);

    await drag.up();
    await tester.pump();
  });
}
