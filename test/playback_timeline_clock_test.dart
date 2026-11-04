import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/playback_timeline_clock.dart';

void main() {
  test('unobserved intervals preserve each rate without scheduling frames', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(const Duration(seconds: 10), running: true, rate: 1);
    clock.sampleFrame(Duration.zero);
    nowUs = 16000;
    clock.sampleFrame(const Duration(milliseconds: 16));
    nowUs += 4000;
    clock.useMonotonicTime();
    nowUs += 1000000;
    expect(clock.position, const Duration(milliseconds: 11020));
    clock.setRate(2);
    nowUs += 500000;
    expect(clock.position, const Duration(milliseconds: 12020));
    clock.setRunning(false);
    nowUs += 10000000;
    expect(clock.position, const Duration(milliseconds: 12020));
    clock.setRunning(true);
    nowUs += 500000;
    expect(clock.position, const Duration(milliseconds: 13020));
    // A fresh display timestamp establishes a new baseline. It cannot replay
    // the off-page interval or reinterpret it at the latest speed.
    expect(clock.sampleFrame(const Duration(seconds: 100)), clock.position);
    expect(clock.position, const Duration(milliseconds: 13020));
    expect(
      clock.sampleFrame(const Duration(milliseconds: 100008)),
      const Duration(milliseconds: 13036),
    );
  });

  test(
    'a clock first observed after idle enters at current monotonic time',
    () {
      var nowUs = 0;
      final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
      clock.reset(const Duration(seconds: 10), running: true, rate: 1);
      clock.useMonotonicTime();
      nowUs = 3000000;
      expect(
        clock.sampleFrame(const Duration(seconds: 90)),
        const Duration(seconds: 13),
      );
      // A visible seek retains the original first-frame contract instead.
      clock.reset(const Duration(seconds: 20), running: true, rate: 1);
      nowUs += 100000;
      expect(
        clock.sampleFrame(const Duration(seconds: 100)),
        const Duration(seconds: 20),
      );
    },
  );

  test('unobserved native-led clocks retain stall bounds on reentry', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(
      Duration.zero,
      running: true,
      rate: 1,
      maxNativeExtrapolation: const Duration(milliseconds: 250),
    );
    clock.sampleFrame(Duration.zero);
    clock.useMonotonicTime();
    nowUs = 1000000;
    expect(clock.position, Duration.zero);
    clock.observeNativePosition(const Duration(milliseconds: 100));
    nowUs += 1000000;
    expect(clock.position, const Duration(milliseconds: 350));
    clock.observeNativePosition(const Duration(milliseconds: 100));
    nowUs += 1000000;
    expect(
      clock.sampleFrame(const Duration(seconds: 30)),
      const Duration(milliseconds: 350),
    );
    clock.observeNativePosition(const Duration(milliseconds: 200));
    expect(clock.position, const Duration(milliseconds: 200));
  });

  group('native-led podcast timeline', () {
    late PlaybackTimelineClock clock;
    var nowUs = 0;

    setUp(() {
      nowUs = 0;
      clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
      clock.reset(
        const Duration(minutes: 30),
        running: true,
        rate: 1,
        duration: const Duration(hours: 2),
        maxNativeExtrapolation: const Duration(milliseconds: 250),
      );
    });

    test('play intent cannot advance lyrics before native audio starts', () {
      clock.sampleFrame(Duration.zero);
      for (var second = 1; second <= 120; second++) {
        clock.observeNativePosition(const Duration(minutes: 30));
        expect(
          clock.sampleFrame(Duration(seconds: second)),
          const Duration(minutes: 30),
        );
      }
    });

    test('a new episode stays at zero until audio actually starts', () {
      clock.reset(
        Duration.zero,
        running: true,
        rate: 1,
        maxNativeExtrapolation: const Duration(milliseconds: 250),
      );
      clock.sampleFrame(Duration.zero);
      clock.observeNativePosition(Duration.zero);
      expect(clock.sampleFrame(const Duration(minutes: 3)), Duration.zero);
      clock.observeNativePosition(const Duration(milliseconds: 100));
      expect(clock.position, const Duration(milliseconds: 100));
    });

    test('buffering freezes and resumes from real audio, excluding wait', () {
      clock.observeNativePosition(const Duration(milliseconds: 1800100));
      clock.sampleFrame(Duration.zero);
      expect(
        clock.sampleFrame(const Duration(milliseconds: 100)),
        const Duration(milliseconds: 1800200),
      );
      clock.setRunning(false);
      expect(clock.position, const Duration(milliseconds: 1800100));
      clock.sampleFrame(const Duration(seconds: 60));
      clock.setRunning(true);
      clock.observeNativePosition(const Duration(milliseconds: 1800100));
      expect(
        clock.sampleFrame(const Duration(seconds: 90)),
        const Duration(milliseconds: 1800100),
      );
      clock.observeNativePosition(const Duration(milliseconds: 1800200));
      expect(clock.position, const Duration(milliseconds: 1800200));
      clock.sampleFrame(const Duration(seconds: 100));
      expect(
        clock.sampleFrame(const Duration(milliseconds: 100016)),
        const Duration(milliseconds: 1800216),
      );
    });

    test('missing buffering events and duplicate samples cannot run away', () {
      clock.observeNativePosition(const Duration(milliseconds: 1800100));
      clock.sampleFrame(Duration.zero);
      expect(
        clock.sampleFrame(const Duration(seconds: 10)),
        const Duration(milliseconds: 1800350),
      );
      for (var second = 11; second < 100; second++) {
        clock.observeNativePosition(const Duration(milliseconds: 1800100));
        expect(
          clock.sampleFrame(Duration(seconds: second)),
          const Duration(milliseconds: 1800350),
        );
      }
      clock.observeNativePosition(const Duration(milliseconds: 1800150));
      expect(clock.position, const Duration(milliseconds: 1800150));
    });

    test('wall-clock sampling is bounded before VSync attaches too', () {
      nowUs = const Duration(minutes: 2).inMicroseconds;
      expect(clock.position, const Duration(minutes: 30));
      clock.observeNativePosition(const Duration(milliseconds: 1800100));
      nowUs += const Duration(minutes: 2).inMicroseconds;
      expect(clock.position, const Duration(milliseconds: 1800350));
      clock.observeNativePosition(const Duration(milliseconds: 1800200));
      expect(clock.position, const Duration(milliseconds: 1800200));
    });

    test(
      'seek target waits for advancement and drops previous interpolation',
      () {
        clock.observeNativePosition(const Duration(milliseconds: 1800100));
        clock.sampleFrame(Duration.zero);
        clock.sampleFrame(const Duration(milliseconds: 100));
        clock.reset(
          const Duration(minutes: 45),
          running: false,
          rate: 2,
          maxNativeExtrapolation: const Duration(milliseconds: 250),
        );
        clock.setRunning(true);
        clock.observeNativePosition(const Duration(minutes: 45));
        expect(
          clock.sampleFrame(const Duration(minutes: 1)),
          const Duration(minutes: 45),
        );
        clock.observeNativePosition(const Duration(milliseconds: 2700100));
        clock.sampleFrame(const Duration(minutes: 2));
        expect(
          clock.sampleFrame(const Duration(milliseconds: 120100)),
          const Duration(milliseconds: 2700300),
        );
        expect(
          clock.sampleFrame(const Duration(minutes: 3)),
          const Duration(milliseconds: 2700600),
        );
      },
    );

    test(
      'a native discontinuity corrects drift rather than accumulating it',
      () {
        clock.observeNativePosition(const Duration(milliseconds: 1800100));
        clock.sampleFrame(Duration.zero);
        clock.sampleFrame(const Duration(milliseconds: 200));
        clock.observeNativePosition(const Duration(minutes: 31));
        expect(clock.position, const Duration(minutes: 31));
        clock.observeNativePosition(const Duration(seconds: 15));
        expect(
          clock.sampleFrame(const Duration(seconds: 3)),
          const Duration(seconds: 15),
        );
        expect(
          clock.sampleFrame(const Duration(seconds: 30)),
          const Duration(seconds: 15),
        );
      },
    );

    test('normal samples keep the frame clock smooth over a long episode', () {
      var frameUs = 0;
      for (var sample = 1; sample <= 3600; sample++) {
        final native = Duration(milliseconds: 1800000 + sample * 200);
        clock.observeNativePosition(native);
        for (var frame = 0; frame < 12; frame++) {
          frameUs += 16667;
          final shown = clock.sampleFrame(Duration(microseconds: frameUs));
          expect((shown - native).inMilliseconds.abs(), lessThanOrEqualTo(250));
        }
      }
    });

    test('switching to ordinary media restores the original smooth clock', () {
      clock.reset(Duration.zero, running: true, rate: 1);
      clock.sampleFrame(Duration.zero);
      expect(
        clock.sampleFrame(const Duration(minutes: 2)),
        const Duration(minutes: 2),
      );
    });

    test('a corrected duration bounds even a paused native position', () {
      clock.setRunning(false);
      clock.setDuration(const Duration(minutes: 20));
      expect(clock.position, const Duration(minutes: 20));
      expect(clock.sampleFrame(Duration.zero), const Duration(minutes: 20));
    });
  });

  test('rate changes alter slope without changing position', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(const Duration(seconds: 10), running: true, rate: 1);

    nowUs += 100000;
    expect(clock.position, const Duration(milliseconds: 10100));

    final beforeSpeedUp = clock.position;
    clock.setRate(3);
    expect(clock.position, beforeSpeedUp);
    nowUs += 100000;
    expect(clock.position, const Duration(milliseconds: 10400));

    final beforeSlowDown = clock.position;
    clock.setRate(1);
    expect(clock.position, beforeSlowDown);
    nowUs += 100000;
    expect(clock.position, const Duration(milliseconds: 10500));
  });

  test('pause and resume preserve the same timeline position', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(Duration.zero, running: true, rate: 2);
    nowUs += 250000;
    clock.setRunning(false);
    expect(clock.position, const Duration(milliseconds: 500));

    nowUs += 1000000;
    expect(clock.position, const Duration(milliseconds: 500));
    clock.setRunning(true);
    nowUs += 250000;
    expect(clock.position, const Duration(seconds: 1));
  });

  test('explicit reset handles seek without retaining prior interpolation', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(Duration.zero, running: true, rate: 1);
    nowUs += 500000;
    clock.reset(const Duration(seconds: 30), running: true, rate: 1);
    expect(clock.position, const Duration(seconds: 30));
  });

  test('a missed display frame samples the full elapsed media time', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(Duration.zero, running: true, rate: 1);

    nowUs += 16667;
    expect(clock.position, const Duration(microseconds: 16667));

    // One VSync was missed. The next presented frame must be at the true
    // 50,001 us position, with no delayed catch-up applied to later frames.
    nowUs += 33334;
    expect(clock.position, const Duration(microseconds: 50001));

    nowUs += 16667;
    expect(clock.position, const Duration(microseconds: 66668));
  });

  test('VSync sampling ignores callback execution-time jitter', () {
    var nowUs = 0;
    final clock = PlaybackTimelineClock(nowMicroseconds: () => nowUs);
    clock.reset(
      Duration.zero,
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );

    expect(clock.sampleFrame(Duration.zero), Duration.zero);
    nowUs = 70000;
    expect(
      clock.sampleFrame(const Duration(microseconds: 16667)),
      const Duration(microseconds: 16667),
    );
    nowUs = 71000;
    expect(
      clock.sampleFrame(const Duration(microseconds: 33334)),
      const Duration(microseconds: 33334),
    );
  });

  test('frame-driven pause and resume never change presented position', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      const Duration(seconds: 10),
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );

    clock.sampleFrame(Duration.zero);
    final beforePause = clock.sampleFrame(const Duration(microseconds: 16667));
    clock.setRunning(false);
    expect(clock.position, beforePause);
    expect(clock.sampleFrame(const Duration(seconds: 5)), beforePause);

    clock.setRunning(true);
    expect(clock.position, beforePause);
    expect(clock.sampleFrame(const Duration(seconds: 6)), beforePause);
    expect(
      clock.sampleFrame(const Duration(microseconds: 6016667)),
      beforePause + const Duration(microseconds: 16667),
    );
  });

  test('frame-driven rate change changes slope without moving position', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      Duration.zero,
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );

    clock.sampleFrame(Duration.zero);
    clock.sampleFrame(const Duration(milliseconds: 10));
    final beforeRateChange = clock.position;
    clock.setRate(2);
    expect(clock.position, beforeRateChange);
    expect(
      clock.sampleFrame(const Duration(milliseconds: 20)),
      beforeRateChange + const Duration(milliseconds: 20),
    );
  });

  test('successive native rate changes keep overlay time continuous', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      const Duration(seconds: 8),
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );
    clock.sampleFrame(Duration.zero);

    const rates = <double>[1.08, 1.28, 1.5, 1.72, 1.92, 2.0];
    var frameTime = Duration.zero;
    var previousPosition = clock.position;
    for (final rate in rates) {
      final beforeRateChange = clock.position;
      clock.setRate(rate);
      expect(clock.position, beforeRateChange);

      frameTime += const Duration(milliseconds: 16);
      final nextPosition = clock.sampleFrame(frameTime);
      final advanceUs = (nextPosition - previousPosition).inMicroseconds;
      expect(advanceUs, closeTo((16000 * rate).round(), 1));
      expect(nextPosition, greaterThan(previousPosition));
      previousPosition = nextPosition;
    }
  });

  test('native drift samples adjust slope without moving current position', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      Duration.zero,
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );
    clock.sampleFrame(Duration.zero);
    clock.sampleFrame(const Duration(milliseconds: 10));

    for (var i = 0; i < 7; i++) {
      final beforeSample = clock.position;
      clock.observeNativePosition(
        beforeSample + const Duration(milliseconds: 20),
      );
      expect(clock.position, beforeSample);
    }

    final beforeFrame = clock.position;
    final afterFrame = clock.sampleFrame(const Duration(milliseconds: 20));
    final advanceUs = (afterFrame - beforeFrame).inMicroseconds;
    expect(advanceUs, greaterThanOrEqualTo(10000));
    expect(advanceUs, lessThanOrEqualTo(10050));
  });

  test('large native mismatch is never converted into a visible jump', () {
    final clock = PlaybackTimelineClock(nowMicroseconds: () => 0);
    clock.reset(
      const Duration(seconds: 5),
      running: true,
      rate: 1,
      duration: const Duration(minutes: 1),
    );
    clock.sampleFrame(Duration.zero);
    clock.sampleFrame(const Duration(milliseconds: 10));
    final before = clock.position;
    for (var i = 0; i < 8; i++) {
      clock.observeNativePosition(const Duration(seconds: 20));
    }
    expect(clock.position, before);
  });
}
