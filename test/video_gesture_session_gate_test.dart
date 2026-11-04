import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/video_gesture_session_gate.dart';

void main() {
  group('VideoGestureSessionGate', () {
    test('long press blocks transforms until every finger is lifted', () {
      final gate = VideoGestureSessionGate();

      gate.pointerDown(1);
      expect(
        gate.tryStartLongPress(
          transformActive: false,
          transformPointerCount: 1,
        ),
        isTrue,
      );

      gate.pointerDown(2);
      gate.endLongPress();
      gate.pointerUp(1);
      expect(gate.blocksTransforms, isTrue);

      gate.pointerUp(2);
      expect(gate.blocksTransforms, isFalse);
    });

    test('two-finger session rejects a late long press', () {
      final gate = VideoGestureSessionGate();

      gate.pointerDown(1);
      gate.pointerDown(2);

      expect(
        gate.tryStartLongPress(transformActive: true, transformPointerCount: 2),
        isFalse,
      );
      expect(gate.blocksTransforms, isFalse);
    });

    test('pointer-up before long-press end still releases the session', () {
      final gate = VideoGestureSessionGate();

      gate.pointerDown(1);
      expect(
        gate.tryStartLongPress(
          transformActive: false,
          transformPointerCount: 1,
        ),
        isTrue,
      );

      gate.pointerUp(1);
      expect(gate.blocksTransforms, isTrue);
      gate.endLongPress();
      expect(gate.blocksTransforms, isFalse);
    });

    test('a new contact drops a pointer that never lifted', () {
      final gate = VideoGestureSessionGate();

      gate.pointerDown(1);
      expect(
        gate.tryStartLongPress(
          transformActive: false,
          transformPointerCount: 1,
        ),
        isTrue,
      );
      gate.pointerDown(2);
      gate.endLongPress();
      gate.pointerUp(1);
      expect(gate.blocksTransforms, isTrue);

      // Pointer 2's up/cancel was lost. The next finger must not stay locked.
      gate.pointerDown(3);
      expect(gate.blocksTransforms, isFalse);
    });

    test('an owned long-press session cannot be started twice', () {
      final gate = VideoGestureSessionGate();

      gate.pointerDown(1);
      expect(
        gate.tryStartLongPress(
          transformActive: false,
          transformPointerCount: 1,
        ),
        isTrue,
      );
      expect(
        gate.tryStartLongPress(
          transformActive: false,
          transformPointerCount: 1,
        ),
        isFalse,
      );
    });
  });
}
