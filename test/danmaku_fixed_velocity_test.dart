import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

DanmakuItem comment(int index, String text) => DanmakuItem(
  index: index,
  startTime: Duration.zero,
  duration: const Duration(seconds: 8),
  text: text,
  type: DanmakuType.scroll,
  colorValue: 0xffffffff,
  sourceY: 0,
);

void main() {
  test('short and long comments move 60 logical pixels each second', () {
    final item = comment(0, 'test');
    for (final width in [320.0, 390.0, 844.0, 1920.0]) {
      for (final textWidth in [30.0, 150.0, 900.0]) {
        for (final speed in [0.025, 0.5, 1.0, 2.0]) {
          final duration = resolveDanmakuDurationUs(
            item,
            speed: speed,
            viewportWidth: width,
            referenceWidth: 1920,
            motionAnchorWidth: 1920,
            textWidth: textWidth,
          );
          expect(
            (width + textWidth) / (duration / 1000000),
            closeTo(60 * speed, 0.0001),
          );
        }
      }
    }
  });

  test('seek and prefetch retain a long tail beyond the old ASS expiry', () {
    final items = [comment(0, 'long comment'), comment(1, 'short')];
    double widthOf(DanmakuItem item) => item.index == 0 ? 900 : 30;
    final active = DanmakuActiveSet(items);
    List<int> at(int time) => List.of(
      active.update(
        positionUs: time,
        speed: 1,
        admissionCap: 640,
        viewportWidth: 300,
        textWidthOf: widthOf,
      ),
    );
    expect(at(15000000), [0]);
    expect(
      resolveDanmakuPrefetchIndices(
        items,
        positionUs: 15000000,
        speed: 1,
        viewportWidth: 300,
        textWidthOf: widthOf,
      ),
      [0],
    );
    expect(at(19999999), [0]);
    expect(at(20000000), isEmpty);
    expect(at(15000000), [0]);
  });

  test('font metrics and viewport changes recalculate exact expiry', () {
    final items = [comment(0, 'text')];
    final active = DanmakuActiveSet(items);
    List<int> sample(double width, double textWidth, int revision) => List.of(
      active.update(
        positionUs: 7000000,
        speed: 1,
        admissionCap: 640,
        viewportWidth: width,
        textWidthOf: (_) => textWidth,
        metricsKey: revision,
      ),
    );
    expect(sample(300, 150, 0), [0]);
    expect(sample(300, 30, 1), isEmpty);
    expect(sample(844, 30, 1), [0]);
  });
}
