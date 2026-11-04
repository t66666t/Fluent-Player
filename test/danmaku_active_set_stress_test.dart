import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

void main() {
  test('membership revision changes when equal-length sets are replaced', () {
    final items = List.generate(
      3,
      (i) => DanmakuItem(
        index: i,
        startTime: Duration(seconds: i),
        duration: const Duration(seconds: 1),
        text: '$i',
        type: DanmakuType.scroll,
        colorValue: 0xFFFFFFFF,
        sourceY: 0,
      ),
    );
    final active = DanmakuActiveSet(items);
    active.update(
      positionUs: 500000,
      speed: 1,
      admissionCap: 640,
      viewportWidth: 60,
    );
    final first = active.revision;
    active.update(
      positionUs: 750000,
      speed: 1,
      admissionCap: 640,
      viewportWidth: 60,
    );
    expect(active.revision, first);
    expect(
      active.update(
        positionUs: 1500000,
        speed: 1,
        admissionCap: 640,
        viewportWidth: 60,
      ),
      [1],
    );
    expect(active.revision, greaterThan(first));
    final second = active.revision;
    active.update(
      positionUs: 500000,
      speed: 1,
      admissionCap: 640,
      viewportWidth: 60,
    );
    expect(active.revision, greaterThan(second));
  });
  test('event-driven membership matches a full scan across clock changes', () {
    final random = Random(42);
    final items = List.generate(
      2000,
      (index) => DanmakuItem(
        index: index,
        startTime: Duration(milliseconds: index * 13),
        duration: Duration(milliseconds: 1 + random.nextInt(18000)),
        text: 'comment ${index % 100}',
        type: DanmakuType.values[index % DanmakuType.values.length],
        colorValue: 0xFFFFFFFF,
        sourceY: 40,
      ),
    );
    final active = DanmakuActiveSet(items);
    var position = 0;
    var speed = 1.0;
    var width = 1920.0;
    for (var frame = 0; frame < 1400; frame++) {
      position += 8333;
      if (frame % 117 == 0) position = random.nextInt(30000000);
      if (frame % 53 == 0) {
        speed = [0.05, 0.5, 1.0, 2.0, 16.0][random.nextInt(5)];
      }
      if (frame % 71 == 0) width = [320.0, 1920.0, 3840.0][random.nextInt(3)];
      // Even subpixel resizes can move an expiration boundary.
      if (frame % 97 == 0) width += 0.25;
      final expected = <int>[];
      for (final item in items) {
        final elapsed = position - item.startTime.inMicroseconds;
        if (elapsed >= 0 &&
            elapsed <
                resolveDanmakuDurationUs(
                  item,
                  speed: speed,
                  viewportWidth: width,
                  referenceWidth: 1920,
                )) {
          expected.add(item.index);
        }
      }
      expect(
        active.update(
          positionUs: position,
          speed: speed,
          admissionCap: 0x3fffffff,
          viewportWidth: width,
        ),
        expected,
        reason: 'frame $frame, position $position, speed $speed, width $width',
      );
    }
  });

  test('expiration is exclusive and later short comments expire first', () {
    final items = <DanmakuItem>[
      for (var i = 0; i < 2; i++)
        DanmakuItem(
          index: i,
          startTime: Duration(seconds: i),
          duration: Duration(seconds: i == 0 ? 10 : 1),
          text: '$i',
          type: DanmakuType.scroll,
          colorValue: 0xFFFFFFFF,
          sourceY: 40,
        ),
    ];
    final active = DanmakuActiveSet(items);
    List<int> sample(int us, {int cap = 640}) => List.of(
      active.update(
        positionUs: us,
        speed: 1,
        admissionCap: cap,
        viewportWidth: 60,
        textWidthOf: (item) => item.index == 0 ? 540 : 0,
      ),
    );
    expect(sample(0), [0]);
    expect(sample(1000000), [0, 1]);
    expect(sample(1999999), [0, 1]);
    expect(sample(2000000), [0]);
    expect(sample(2000000, cap: 0), isEmpty);
    expect(sample(2000000), isEmpty); // No resurrection during pause.
    expect(sample(1000000), [0, 1]); // Backward seek resets membership.
    expect(sample(9999999), [0]);
    expect(sample(10000000), isEmpty);
  });

  test('dense unchanged membership CPU benchmark', () {
    final items = List.generate(
      640,
      (i) => DanmakuItem(
        index: i,
        startTime: Duration.zero,
        duration: const Duration(seconds: 600),
        text: 'dense $i',
        type: DanmakuType.scroll,
        colorValue: 0xFFFFFFFF,
        sourceY: 40,
      ),
    );
    final samples = <int>[];
    for (var run = 0; run < 7; run++) {
      final active = DanmakuActiveSet(items);
      active.update(positionUs: 0, speed: .05, admissionCap: 640);
      final timer = Stopwatch()..start();
      for (var frame = 1; frame <= 10000; frame++) {
        active.update(positionUs: frame * 8333, speed: .05, admissionCap: 640);
      }
      timer.stop();
      samples.add(timer.elapsedMicroseconds);
    }
    samples.sort();
    // Informational CPU measurement, never a flaky wall-time assertion.
    // ignore: avoid_print
    print('640 active / 10000 updates median: ${samples[3]} us');
  });
}
