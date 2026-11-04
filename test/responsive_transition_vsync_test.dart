import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/responsive_transition_vsync.dart';

class _Vsync implements TickerProvider {
  late TickerCallback tick;
  @override
  Ticker createTicker(TickerCallback onTick) {
    tick = onTick;
    return Ticker(onTick);
  }
}

void main() {
  for (final hz in [60, 144, 240]) {
    test(
      'cold sidebar frame preserves motion at $hz Hz without slowing later frames',
      () {
        final source = _Vsync();
        final period = Duration(microseconds: (1000000 / hz).round());
        final clock = ResponsiveTransitionVsync(
          source,
          period,
          protectFirstAdvance: false,
        );
        final times = <Duration>[];
        final ticker = clock.createTicker(times.add);
        addTearDown(ticker.dispose);
        clock.start(alignFirstTick: false);
        source.tick(const Duration(milliseconds: 180));
        expect(times.last, period);
        source.tick(const Duration(milliseconds: 200));
        expect(times.last, period + const Duration(milliseconds: 20));
        source.tick(const Duration(milliseconds: 400));
        expect(times.last, period + const Duration(milliseconds: 220));
        clock.start(alignFirstTick: false);
        source.tick(Duration.zero);
        source.tick(const Duration(milliseconds: 160));
        expect(times.last, const Duration(milliseconds: 160));
      },
    );
  }
}
