import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/danmaku_presentation_position.dart';

DanmakuPresentationPosition _visiblePosition() =>
    DanmakuPresentationPosition()..addListener(() {});

void main() {
  test(
    'a small resume clock rollback preserves outstanding pause calibration',
    () {
      final position = _visiblePosition();
      addTearDown(position.dispose);
      position.reset(const Duration(seconds: 10));
      position.reanchor(const Duration(milliseconds: 10300));
      position.advance(const Duration(microseconds: 10300020));
      final frozen = position.value;
      // A wall-clock read just before the first VSync can be a few microseconds
      // ahead of that frame's anchor. This is not an explicit seek.
      position.advance(const Duration(milliseconds: 10300));
      expect(position.value, frozen);
      position.advance(const Duration(microseconds: 10308333));
      expect(
        (position.value - frozen).inMicroseconds,
        inInclusiveRange(7499, 9167),
      );
      position.reset(const Duration(seconds: 3));
      expect(position.value, const Duration(seconds: 3));
    },
  );
  for (final offsetMs in [-300, 300]) {
    test('native calibration by ${offsetMs}ms preserves the paused frame', () {
      final position = _visiblePosition();
      addTearDown(position.dispose);
      const presented = Duration(seconds: 10);
      final native = presented + Duration(milliseconds: offsetMs);
      position.reset(presented);
      var notifications = 0;
      position.addListener(() => notifications++);
      position.reanchor(native);
      for (var sample = 0; sample < 100; sample++) {
        position.advance(native);
      }
      expect(position.value, presented);
      expect(notifications, 0);
    });
  }

  for (final rate in [.5, 1.0, 2.0, 8.0]) {
    for (final offsetMs in [-300, 300]) {
      test('resumption at ${rate}x consumes ${offsetMs}ms smoothly', () {
        final position = _visiblePosition();
        addTearDown(position.dispose);
        const presented = Duration(seconds: 10);
        position.reset(presented);
        var source = presented + Duration(milliseconds: offsetMs);
        position.reanchor(source);
        final frameUs = (8333 * rate).round();
        for (var frame = 0; frame < 1000; frame++) {
          final before = position.value;
          source += Duration(microseconds: frameUs);
          position.advance(source);
          final delta = (position.value - before).inMicroseconds;
          expect(delta, inInclusiveRange(frameUs * .9 - 1, frameUs * 1.1 + 1));
        }
        expect(position.value, source);
      });
    }
  }

  test('a new pause calibration replaces the outstanding difference', () {
    final position = _visiblePosition();
    addTearDown(position.dispose);
    position.reset(const Duration(seconds: 10));
    position.reanchor(const Duration(milliseconds: 10300));
    position.advance(const Duration(milliseconds: 10400));
    final frozen = position.value;
    position.reanchor(const Duration(milliseconds: 10700));
    position.reanchor(const Duration(milliseconds: 10800));
    expect(position.value, frozen);
    position.advance(const Duration(milliseconds: 10800));
    expect(position.value, frozen);
    position.advance(const Duration(seconds: 18));
    expect(position.value, const Duration(seconds: 18));
  });

  test('seeks and media replacement discard all prior calibration', () {
    final position = _visiblePosition();
    addTearDown(position.dispose);
    position.reset(const Duration(seconds: 10));
    position.reanchor(const Duration(milliseconds: 10400));
    for (final target in [
      const Duration(seconds: 30),
      const Duration(seconds: 5),
      Duration.zero,
    ]) {
      position.reset(target);
      expect(position.value, target);
      position.advance(target + const Duration(milliseconds: 16));
      expect(position.value, target + const Duration(milliseconds: 16));
    }
  });

  test('the presented position stays inside a corrected media duration', () {
    final position = _visiblePosition();
    addTearDown(position.dispose);
    position.reset(const Duration(seconds: 10));
    position.reanchor(const Duration(seconds: 9));
    position.advance(
      const Duration(milliseconds: 9100),
      duration: const Duration(seconds: 10),
    );
    expect(position.value, const Duration(seconds: 10));
  });

  test('a reopened overlay starts at current media time', () {
    final position = DanmakuPresentationPosition();
    addTearDown(position.dispose);
    void listener() {}
    position.reset(const Duration(seconds: 10));
    position.addListener(listener);
    position.reanchor(const Duration(milliseconds: 10400));
    expect(position.value, const Duration(seconds: 10));
    position.removeListener(listener);
    position.addListener(listener);
    expect(position.value, const Duration(milliseconds: 10400));
    position.removeListener(listener);
    position.reanchor(const Duration(seconds: 12));
    expect(position.value, const Duration(seconds: 12));
  });
}
