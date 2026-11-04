import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/danmaku_presentation_position.dart';
import 'package:video_player_app/services/playback_timeline_clock.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

void main() {
  for (final hz in [
    24.0,
    30.0,
    59.94,
    60.0,
    75.0,
    90.0,
    120.0,
    144.0,
    165.0,
    240.0,
    360.0,
    500.0,
    540.0,
    1000.0,
  ]) {
    for (final rate in [.5, 1.0, 1.25, 1.5, 2.0, 8.0]) {
      test('${hz}Hz at ${rate}x stays on the same media-time trajectory', () {
        final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
        clock.reset(Duration.zero, running: true, rate: rate);
        clock.sampleFrame(Duration.zero);
        final frames = (hz * 120).round();
        for (var frame = 1; frame <= frames; frame++) {
          final timestampUs = (frame * 1000000 / hz).round();
          final shown = clock.sampleFrame(Duration(microseconds: timestampUs));
          expect(
            shown.inMicroseconds,
            closeTo((timestampUs * rate).round(), 1),
            reason: 'frame $frame must not accumulate per-frame rounding drift',
          );
        }
      });
    }
  }

  test('frame budgets follow reported refresh without a 60/200Hz floor', () {
    for (final hz in [
      1.0,
      12.0,
      24.0,
      59.94,
      120.0,
      144.0,
      240.0,
      360.0,
      540.0,
      1000.0,
      2000.0,
    ]) {
      expect(
        resolveDanmakuFrameBudgetUs(refreshRate: hz),
        (1000000 / hz).round(),
      );
    }
  });

  test(
    'missing refresh metadata retains missed-frame-resistant estimation',
    () {
      for (final interval in [41667, 16667, 8333, 4167, 2778, 1000]) {
        expect(
          resolveDanmakuFrameBudgetUs(
            vsyncIntervalsUs: [
              interval,
              interval,
              interval,
              interval,
              interval * 2,
              interval * 3,
            ],
          ),
          interval,
        );
      }
      for (final invalid in [
        0.0,
        -1.0,
        double.nan,
        double.infinity,
        1000000.0,
      ]) {
        expect(resolveDanmakuFrameBudgetUs(refreshRate: invalid), 16667);
      }
      expect(
        resolveDanmakuFrameBudgetUs(vsyncIntervalsUs: [-1, 0, 99999999]),
        16667,
      );
    },
  );

  test(
    'variable refresh and dropped frames preserve continuous displacement',
    () {
      final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
      final position = DanmakuPresentationPosition()..addListener(() {});
      addTearDown(position.dispose);
      clock.reset(Duration.zero, running: true, rate: 1.25);
      clock.sampleFrame(Duration.zero);
      var timestampUs = 0;
      for (final intervalUs in [
        41667,
        16667,
        8333,
        6944,
        6061,
        4167,
        2778,
        16667,
        50000,
        6944,
        8333,
        4167,
      ]) {
        final before = position.value;
        timestampUs += intervalUs;
        position.advance(
          clock.sampleFrame(Duration(microseconds: timestampUs)),
        );
        expect(position.value.inMicroseconds, closeTo(timestampUs * 1.25, 1));
        expect(
          (position.value - before).inMicroseconds,
          closeTo(intervalUs * 1.25, 1),
        );
      }
      final frozen = position.value;
      clock.setRunning(false);
      timestampUs += 3000000;
      position.advance(clock.sampleFrame(Duration(microseconds: timestampUs)));
      expect(position.value, frozen);
      clock.setRunning(true);
      timestampUs += 2778;
      position.advance(clock.sampleFrame(Duration(microseconds: timestampUs)));
      expect(position.value, frozen);
      timestampUs += 2778;
      position.advance(clock.sampleFrame(Duration(microseconds: timestampUs)));
      expect((position.value - frozen).inMicroseconds, closeTo(2778 * 1.25, 1));
    },
  );
}
