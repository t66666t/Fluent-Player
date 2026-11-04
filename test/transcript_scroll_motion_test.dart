import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/transcript_scroll_motion.dart';

void main() {
  test('custom scroll positions use the same curve as the native activity', () {
    for (final velocity in [-800.0, 0.0, 300.0, 10000.0]) {
      final motion = TranscriptScrollMotion(
        from: 100,
        to: 260,
        viewport: 700,
        initialVelocity: velocity,
      );
      for (var step = 0; step <= 100; step++) {
        final t = step / 100;
        expect(
          100 + 160 * motion.curve.transform(t),
          closeTo(motion.x(t * motion.seconds), 1e-8),
        );
      }
    }
  });
  test('distance adds time continuously including tiny corrections', () {
    for (final viewport in [200.0, 420.0, 700.0, 1400.0]) {
      for (final auto in [false, true]) {
        var previous = 0.0;
        var previousIncrease = double.infinity;
        for (var distance = .5; distance <= viewport; distance += .5) {
          final motion = TranscriptScrollMotion(
            from: 0,
            to: distance,
            viewport: viewport,
            isAuto: auto,
          );
          final increase = motion.seconds - previous;
          expect(increase, greaterThan(0));
          expect(increase, lessThan(previousIncrease));
          expect(motion.seconds, lessThan(.650));
          if (distance <= 2) expect(motion.seconds, lessThan(.060));
          previous = motion.seconds;
          previousIncrease = increase;
        }
      }
    }
  });
  test('line, paragraph and half-page moves have distinct reading budgets', () {
    for (final viewport in [420.0, 700.0, 1400.0]) {
      final line = TranscriptScrollMotion(from: 0, to: 40, viewport: viewport);
      final paragraph = TranscriptScrollMotion(
        from: 0,
        to: 160,
        viewport: viewport,
      );
      final halfPage = TranscriptScrollMotion(
        from: 0,
        to: viewport / 2,
        viewport: viewport,
      );
      expect(line.seconds, inInclusiveRange(.180, .260));
      expect(paragraph.seconds - line.seconds, greaterThan(.080));
      expect(halfPage.seconds, inInclusiveRange(.300, .600));
      final follow = TranscriptScrollMotion(
        from: 0,
        to: 160,
        viewport: viewport,
        isAuto: true,
      );
      expect(follow.seconds, greaterThan(paragraph.seconds));
      expect(follow.seconds - paragraph.seconds, lessThan(.040));
    }
    final phone = TranscriptScrollMotion(from: 0, to: 160, viewport: 320);
    final tablet = TranscriptScrollMotion(from: 0, to: 500, viewport: 1000);
    expect(tablet.seconds, greaterThan(phone.seconds));
    expect(tablet.seconds - phone.seconds, lessThan(.180));
  });
  test(
    'resting starts and stops have zero velocity and smooth acceleration',
    () {
      final motion = TranscriptScrollMotion(from: 100, to: 420, viewport: 700);
      expect(motion.dx(0), 0);
      expect(motion.dx(motion.seconds), 0);
      const dt = .000001;
      expect(motion.dx(dt) / dt, lessThan(1));
      expect(motion.dx(motion.seconds - dt) / dt, lessThan(1));
      expect(motion.x(motion.seconds / 2), closeTo(260, 1e-8));
      expect(motion.x(motion.seconds), 420);
      expect(motion.isDone(motion.seconds), isTrue);
    },
  );
  test(
    'same-direction retarget preserves safe speed without extending time',
    () {
      final first = TranscriptScrollMotion(from: 0, to: 120, viewport: 700);
      final at = first.seconds * .4;
      final next = TranscriptScrollMotion(
        from: first.x(at),
        to: 200,
        viewport: 700,
        initialVelocity: first.dx(at),
      );
      final fresh = TranscriptScrollMotion(
        from: next.from,
        to: next.to,
        viewport: 700,
      );
      expect(next.dx(0), closeTo(first.dx(at), 1e-8));
      expect(next.seconds, fresh.seconds);
      expect(next.x(.008) - next.from, greaterThan(fresh.x(.008) - fresh.from));
    },
  );
  test('reverse targets discard opposing momentum', () {
    final motion = TranscriptScrollMotion(
      from: 500,
      to: 420,
      viewport: 700,
      initialVelocity: 400,
    );
    expect(motion.dx(0), 0);
    expect(motion.x(.008), inExclusiveRange(420, 500));
  });
  for (final hz in [24, 60, 90, 120, 144, 240]) {
    test('$hz Hz motion remains monotonic and lands without overshooting', () {
      for (final viewport in [200.0, 700.0, 1400.0]) {
        for (final distance in [.8, 8.0, 40.0, 240.0, 700.0]) {
          for (final direction in [-1.0, 1.0]) {
            for (final velocity in [-10000.0, 0.0, 150.0, 10000.0]) {
              final motion = TranscriptScrollMotion(
                from: 500,
                to: 500 + distance * direction,
                viewport: viewport,
                initialVelocity: velocity,
              );
              var previous = motion.from;
              for (
                var frame = 0;
                frame <= (motion.seconds * hz).ceil();
                frame++
              ) {
                final value = motion.x(frame / hz);
                expect(
                  (value - previous) * direction,
                  greaterThanOrEqualTo(-1e-8),
                );
                expect(
                  (motion.to - value) * direction,
                  greaterThanOrEqualTo(-1e-8),
                );
                expect(
                  motion.dx(frame / hz).abs(),
                  lessThanOrEqualTo(2 * distance / motion.seconds + 1e-8),
                );
                previous = value;
              }
              expect(motion.x(motion.seconds + 1), motion.to);
              expect(motion.dx(motion.seconds), 0);
            }
          }
        }
      }
    });
  }
  test('zero distance stays stationary with inherited momentum', () {
    final motion = TranscriptScrollMotion(
      from: 100,
      to: 100,
      viewport: 700,
      initialVelocity: 800,
    );
    expect(motion.x(0), 100);
    expect(motion.x(.1), 100);
    expect(motion.dx(0), 0);
    expect(motion.isDone(0), isTrue);
  });
  test('cached offscreen anchors retain their bounded travel limit', () {
    expect(TranscriptScrollMotion.travelLimitFor(1400), lessThanOrEqualTo(200));
  });
}
