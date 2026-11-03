import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/transcript_scroll_motion.dart';

void main() {
  test(
    'added distance contributes progressively less time without a cutoff',
    () {
      var previousTime = 0.0;
      var previousIncrease = double.infinity;
      for (var distance = 1.0; distance <= 2000; distance++) {
        final motion = TranscriptScrollMotion(
          from: 0,
          to: distance,
          viewport: 700,
          visibleTarget: true,
        );
        final increase = motion.seconds - previousTime;
        expect(increase, greaterThan(0));
        expect(increase, lessThan(previousIncrease));
        expect(motion.seconds, lessThan(.300));
        previousTime = motion.seconds;
        previousIncrease = increase;
      }
      final near = TranscriptScrollMotion(from: 0, to: 40, viewport: 700);
      final far = TranscriptScrollMotion(from: 0, to: 400, viewport: 700);
      // Ten times the travel adds less than 90ms, not ten times the wait.
      expect(far.seconds - near.seconds, inExclusiveRange(.080, .090));
    },
  );
  test(
    'distance durations stay consistent across viewports and follow modes',
    () {
      for (final viewport in [200.0, 700.0, 1400.0]) {
        for (final distance in [24.0, 40.0, 80.0, 240.0, 420.0, 700.0]) {
          for (final auto in [false, true]) {
            for (final visible in [false, true]) {
              final motion = TranscriptScrollMotion(
                from: 100,
                to: 100 + distance,
                viewport: viewport,
                isAuto: auto,
                visibleTarget: visible,
              );
              final expectedMilliseconds = <double, double>{
                24: 163.636,
                40: 200,
                80: 240,
                240: 276.923,
                420: 286.364,
                700: 291.667,
              }[distance]!;
              expect(
                motion.duration.inMicroseconds / 1000,
                closeTo(expectedMilliseconds, .002),
              );
              expect(
                motion.x(motion.seconds / 2),
                closeTo(100 + distance / 2, 1e-8),
              );
              expect(motion.x(motion.seconds), motion.to);
              expect(motion.isDone(motion.seconds), isTrue);
            }
          }
        }
      }
    },
  );
  test(
    'reading trajectories stay bounded and stop within the motion budget',
    () {
      for (final viewport in [200.0, 420.0, 700.0, 1400.0]) {
        for (final direction in [-1.0, 1.0]) {
          for (final velocity in [-10000.0, 0.0, 150.0, 10000.0]) {
            final distance = TranscriptScrollMotion.travelLimitFor(viewport);
            final motion = TranscriptScrollMotion(
              from: 500,
              to: 500 + direction * distance,
              viewport: viewport,
              initialVelocity: velocity,
            );
            expect(motion.duration.inMicroseconds, lessThanOrEqualTo(300001));
            var previous = motion.from;
            for (var step = 0; step <= 200; step++) {
              final time = motion.seconds * step / 200;
              final value = motion.x(time);
              expect(
                (value - previous) * direction,
                greaterThanOrEqualTo(-1e-8),
              );
              expect(
                (motion.to - value) * direction,
                greaterThanOrEqualTo(-1e-8),
              );
              expect(
                motion.dx(time).abs(),
                lessThanOrEqualTo(distance / .240 + 1e-8),
              );
              previous = value;
            }
            expect(motion.x(motion.seconds + 1), motion.to);
            expect(motion.dx(motion.seconds), 0);
            expect(motion.isDone(motion.seconds), isTrue);
          }
        }
      }
    },
  );

  test('a replacement recalculates duration without inheriting velocity', () {
    final fresh = TranscriptScrollMotion(
      from: 500,
      to: 620,
      viewport: 700,
      visibleTarget: true,
    );
    final velocity = fresh.dx(0) * .9;
    final motion = TranscriptScrollMotion(
      from: 500,
      to: 620,
      viewport: 700,
      initialVelocity: velocity,
      visibleTarget: true,
    );
    expect(motion.seconds, fresh.seconds);
    expect(motion.dx(0), closeTo(fresh.dx(0), 1e-8));
    expect(motion.x(.008) - motion.from, greaterThan(1.4));
    expect(motion.dx(.00001), closeTo(motion.dx(0), .001));
  });

  test('a reversed target does not continue in the old direction', () {
    final motion = TranscriptScrollMotion(
      from: 500,
      to: 420,
      viewport: 700,
      initialVelocity: 400,
    );
    expect(motion.dx(0), lessThan(0));
    expect(motion.x(.008), lessThan(500));
    expect(motion.x(.008), greaterThan(420));
  });

  test('a close target sheds unsafe velocity instead of overshooting', () {
    final motion = TranscriptScrollMotion(
      from: 100,
      to: 100.8,
      viewport: 700,
      initialVelocity: 800,
    );
    final stationaryStart = TranscriptScrollMotion(
      from: 100,
      to: 100.8,
      viewport: 700,
    );
    expect(motion.seconds, closeTo(stationaryStart.seconds, 1e-8));
    expect(motion.seconds, lessThan(.016));
    for (var step = 0; step <= 100; step++) {
      expect(
        motion.x(motion.seconds * step / 100),
        inInclusiveRange(100, 100.8),
      );
    }
  });

  for (final hz in [24, 60, 90, 120, 144, 240]) {
    for (final auto in [false, true]) {
      test(
        '$hz Hz ${auto ? 'follow' : 'locate'} moves uniformly without easing',
        () {
          final motion = TranscriptScrollMotion(
            from: 100,
            to: 420,
            viewport: 700,
            visibleTarget: true,
            isAuto: auto,
          );
          final velocity = motion.dx(0);
          expect(velocity, greaterThan(0));
          expect(motion.dx(motion.seconds - .00001), closeTo(velocity, 1e-8));
          for (var frame = 1; frame / hz < motion.seconds; frame++) {
            expect(
              motion.x(frame / hz) - motion.x((frame - 1) / hz),
              closeTo(velocity / hz, 1e-8),
            );
          }
          expect(motion.x(motion.seconds), motion.to);
          expect(motion.dx(motion.seconds), 0);
        },
      );
    }
  }

  for (final viewport in [200.0, 700.0, 1400.0]) {
    for (final distance in [20.0, 40.0, 80.0, 120.0]) {
      test(
        '$viewport viewport $distance px short moves allow reading time',
        () {
          final manual = TranscriptScrollMotion(
            from: 0,
            to: distance,
            viewport: viewport,
            visibleTarget: true,
          );
          final auto = TranscriptScrollMotion(
            from: 0,
            to: distance,
            viewport: viewport,
            visibleTarget: true,
            isAuto: true,
          );
          expect(manual.seconds, greaterThan(.100));
          expect(auto.seconds, manual.seconds);
          expect(auto.seconds - manual.seconds, lessThan(.080));
        },
      );
    }
  }

  test(
    'duration and speed grow continuously without a tiny correction crawl',
    () {
      for (final auto in [false, true]) {
        var lastDuration = 0.0;
        var lastSpeed = 0.0;
        for (final distance in [.5, .8, 2.0, 8.0, 20.0, 40.0, 80.0, 120.0]) {
          final motion = TranscriptScrollMotion(
            from: 0,
            to: distance,
            viewport: 700,
            isAuto: auto,
            visibleTarget: true,
          );
          expect(motion.seconds, greaterThan(lastDuration));
          expect(motion.dx(0), greaterThanOrEqualTo(lastSpeed - 1e-8));
          if (distance <= 2) expect(motion.seconds, lessThan(.060));
          lastDuration = motion.seconds;
          lastSpeed = motion.dx(0);
        }
      }
    },
  );

  test('tiny, line and long moves each have a bounded reading duration', () {
    final cases = <double, (double, double)>{
      .5: (.007, .008),
      2: (.027, .028),
      8: (.085, .087),
      20: (.149, .151),
      40: (.199, .201),
      80: (.239, .241),
      120: (.257, .258),
      240: (.276, .278),
      420: (.286, .288),
    };
    for (final entry in cases.entries) {
      for (final auto in [false, true]) {
        final motion = TranscriptScrollMotion(
          from: 0,
          to: entry.key,
          viewport: 700,
          visibleTarget: true,
          isAuto: auto,
        );
        expect(
          motion.seconds,
          inInclusiveRange(entry.value.$1, entry.value.$2),
          reason: '${entry.key}px, auto=$auto',
        );
      }
    }
  });

  test('retargeting from a tiny correction cannot drag out a longer move', () {
    for (final auto in [false, true]) {
      for (final direction in [-1.0, 1.0]) {
        for (final distance in [2.0, 8.0, 20.0, 40.0, 80.0, 240.0]) {
          final fresh = TranscriptScrollMotion(
            from: 100,
            to: 100 + distance * direction,
            viewport: 700,
            visibleTarget: true,
            isAuto: auto,
          );
          final retargeted = TranscriptScrollMotion(
            from: 100,
            to: fresh.to,
            viewport: 700,
            initialVelocity: direction,
            visibleTarget: true,
            isAuto: auto,
          );
          expect(retargeted.seconds, closeTo(fresh.seconds, 1e-8));
          expect(retargeted.dx(0).abs(), closeTo(fresh.dx(0).abs(), 1e-8));
        }
      }
    }
  });

  test('rapid follows cannot inherit the speed of a longer locate', () {
    for (final auto in [false, true]) {
      for (final direction in [-1.0, 1.0]) {
        for (final distance in [2.0, 20.0, 40.0, 80.0]) {
          final fresh = TranscriptScrollMotion(
            from: 100,
            to: 100 + distance * direction,
            viewport: 700,
            visibleTarget: true,
            isAuto: auto,
          );
          final retargeted = TranscriptScrollMotion(
            from: 100,
            to: fresh.to,
            viewport: 700,
            initialVelocity: 900 * direction,
            visibleTarget: true,
            isAuto: auto,
          );
          expect(retargeted.seconds, closeTo(fresh.seconds, 1e-8));
          expect(retargeted.dx(0), closeTo(fresh.dx(0), 1e-8));
        }
      }
    }
  });

  test('large viewports do not authorize long text sweeps', () {
    expect(TranscriptScrollMotion.travelLimitFor(1400), lessThanOrEqualTo(200));
  });

  test('a zero-distance request remains stationary', () {
    final motion = TranscriptScrollMotion(
      from: 100,
      to: 100,
      viewport: 700,
      initialVelocity: 800,
    );
    expect(motion.x(.1), 100);
    expect(motion.dx(.1), 0);
  });

  test('a farther visible target scrolls without an excessive wait', () {
    final motion = TranscriptScrollMotion(
      from: 100,
      to: 520,
      viewport: 700,
      visibleTarget: true,
    );
    expect(motion.duration.inMicroseconds, lessThanOrEqualTo(300001));
    expect(motion.duration.inMilliseconds, greaterThan(230));
    var previous = motion.from;
    for (var step = 0; step <= 200; step++) {
      final time = motion.seconds * step / 200;
      final value = motion.x(time);
      expect(value, inInclusiveRange(previous, motion.to));
      expect(motion.dx(time), lessThan(700 * 3));
      previous = value;
    }
    expect(motion.x(motion.seconds), motion.to);
  });
}
