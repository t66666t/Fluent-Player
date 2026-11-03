import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_library_continue_policy.dart';

void main() {
  test('defaults keep the original 30s / 20% shorter gate', () {
    const policy = ContinueWatchPolicy.defaults;
    expect(policy.shorterThresholdMs(null), 30000);
    expect(policy.shorterThresholdMs(10000), 2000);
    expect(policy.shorterThresholdMs(1), 30000);
    expect(policy.hasReachedWatchGate(1999, 10000), isFalse);
    expect(policy.hasReachedWatchGate(2000, 10000), isTrue);
    expect(policy.compactLabel, contains('30秒'));
    expect(policy.compactLabel, contains('20%'));
  });

  test('both and either combine time and percent independently', () {
    final both = ContinueWatchPolicy.defaults.copyWith(
      combineMode: ContinueWatchCombineMode.both,
      minWatchMs: 30000,
      minDurationFraction: 0.2,
    );
    expect(both.hasReachedWatchGate(25000, 100000), isFalse);
    expect(both.hasReachedWatchGate(30000, 100000), isTrue);
    expect(both.hasReachedWatchGate(30000, 200000), isFalse);

    final either = both.copyWith(combineMode: ContinueWatchCombineMode.either);
    expect(either.hasReachedWatchGate(25000, 100000), isTrue);
    expect(either.hasReachedWatchGate(1000, 100000), isFalse);
  });

  test('json round-trip keeps custom age days instead of snapping to chips', () {
    final restored = ContinueWatchPolicy.fromJsonString(
      ContinueWatchPolicy.defaults
          .copyWith(minWatchMs: 25000, maxAgeDays: 3)
          .toJsonString(),
    );
    expect(restored.minWatchMs, 25000);
    expect(restored.maxAgeDays, 3);
    expect(ContinueWatchPolicy.fromJsonString('not-json').minWatchMs, 30000);
  });

  test('duration slider ticks are equal-width, first steps are 0 then 1s', () {
    final steps = ContinueWatchSliderSteps.minWatchMs;
    final last = steps.length - 1;
    expect(ContinueWatchSliderSteps.msOf(0, steps), 0);
    expect(ContinueWatchSliderSteps.msOf(1 / last, steps), 1000);
    expect(ContinueWatchSliderSteps.msOf(2 / last, steps), 2000);
    expect(ContinueWatchSliderSteps.sliderOf(0, steps), 0);
    expect(ContinueWatchSliderSteps.sliderOf(1000, steps), closeTo(1 / last, 1e-9));
    expect(ContinueWatchSliderSteps.sliderOf(30000, steps), greaterThan(0.4));
    expect(ContinueWatchSliderSteps.sliderOf(30000, steps), lessThan(0.7));
    // Off-tick values sit between neighbors instead of snapping the thumb.
    final custom = ContinueWatchSliderSteps.sliderOf(32000, steps);
    expect(custom, greaterThan(ContinueWatchSliderSteps.sliderOf(30000, steps)));
    expect(custom, lessThan(ContinueWatchSliderSteps.sliderOf(35000, steps)));
  });

  test('duration and percent inputs accept typed custom values', () {
    expect(
      ContinueWatchPolicy.parseDurationMs('25', maxMs: 600000),
      25000,
    );
    expect(
      ContinueWatchPolicy.parseDurationMs('1:30', maxMs: 600000),
      90000,
    );
    expect(
      ContinueWatchPolicy.parseDurationMs('1分30秒', maxMs: 600000),
      90000,
    );
    expect(ContinueWatchPolicy.parseDurationMs('不限', maxMs: 600000), 0);
    expect(ContinueWatchPolicy.parseDurationMs('nope', maxMs: 600000), isNull);
    expect(
      ContinueWatchPolicy.parsePercentFraction('12.5', maxFraction: 0.8),
      closeTo(0.125, 1e-9),
    );
    expect(ContinueWatchPolicy.parseAgeDays('3'), 3);
    expect(ContinueWatchPolicy.parseAgeDays(''), 0);
  });

  test('watchNeedMsForDuration follows easier vs both', () {
    const tenMin = 10 * 60 * 1000;
    const policy = ContinueWatchPolicy.defaults;
    expect(policy.watchNeedMsForDuration(tenMin), 30000);
    expect(policy.watchNeedMsForDuration(10000), 2000);

    final both = policy.copyWith(combineMode: ContinueWatchCombineMode.both);
    expect(both.watchNeedMsForDuration(tenMin), 120000);
    expect(both.watchNeedMsForDuration(10000), 30000);
  });
}
