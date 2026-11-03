import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/danmaku_model.dart';
import 'package:video_player_app/services/danmaku_collision_layout.dart';
import 'package:video_player_app/widgets/danmaku_overlay.dart';

DanmakuItem _item(int index) => DanmakuItem(
  index: index,
  startTime: Duration(milliseconds: index * 10),
  duration: const Duration(seconds: 10),
  text: '弹幕 $index',
  type: DanmakuType.scroll,
  colorValue: 0xffffffff,
  sourceY: 0,
);

DanmakuCollisionBox _box(
  int index, {
  int startUs = 0,
  int durationUs = 10000000,
  double width = 100,
  double y = 0,
  double height = 20,
  double? fixedX,
  double padding = 1,
  DanmakuType? type,
}) => DanmakuCollisionBox(
  index: index,
  startUs: startUs,
  durationUs: durationUs,
  startX: fixedX ?? 390,
  endX: fixedX ?? -width,
  y: y,
  width: width,
  height: height,
  padding: padding,
  horizontalGap: 0,
  type: type ?? (fixedX == null ? DanmakuType.scroll : DanmakuType.top),
);

void main() {
  test(
    'density is stable across seeks, nested and filters before the active cap',
    () {
      final items = List.generate(1000, _item);
      Set<int> selected(double density) => {
        for (final item in items)
          if (danmakuPassesDensity(item, density)) item.index,
      };
      final half = selected(.5);
      expect(half.length, inInclusiveRange(450, 550));
      expect(half, containsAll(selected(.25)));
      expect(selected(1).length, items.length);
      final active = DanmakuActiveSet(items);
      final first = List<int>.of(
        active.update(
          positionUs: 9000000,
          speed: 1,
          admissionCap: 640,
          density: .5,
        ),
      );
      active.update(positionUs: 0, speed: 1, admissionCap: 640, density: .5);
      expect(
        active.update(
          positionUs: 9000000,
          speed: 1,
          admissionCap: 640,
          density: .5,
        ),
        first,
      );
      final fuller = active.update(
        positionUs: 9000000,
        speed: 1,
        admissionCap: 640,
        density: 1,
      );
      expect(fuller.length, greaterThan(first.length));
      expect(first.every((index) => half.contains(index)), isTrue);
    },
  );

  test(
    'admits distant overtaking but still avoids an immediate entry pileup',
    () {
      final short = _box(0, width: 40);
      final long = _box(1, startUs: 2000000, width: 700);
      expect(
        long.xAt(long.startUs),
        greaterThan(short.xAt(long.startUs) + short.width + 4),
      );
      expect(long.conflictsWith(short), isFalse);
      expect(
        _box(2, startUs: 1000000, width: 700).conflictsWith(short),
        isTrue,
      );
      // Two short comments at the same interval remain separated throughout.
      expect(
        _box(2, startUs: 2000000, width: 40).conflictsWith(short),
        isFalse,
      );
    },
  );

  test(
    'scroll, top and bottom can overlap; only the same type shares lanes',
    () {
      final fixed = _box(0, fixedX: 145, y: 0);
      expect(_box(1, y: 0).conflictsWith(fixed), isFalse);
      expect(_box(2, fixedX: 145, y: 0).conflictsWith(fixed), isTrue);
      expect(
        _box(3, fixedX: 145, type: DanmakuType.bottom).conflictsWith(fixed),
        isFalse,
      );
      expect(
        _box(4, fixedX: 145, y: 24, padding: 50).conflictsWith(fixed),
        isFalse,
      );
      // Neighboring rows may share a little glyph/outline height.
      expect(_box(6, fixedX: 145, y: 16).conflictsWith(fixed), isFalse);
      expect(_box(7, fixedX: 145, y: 8).conflictsWith(fixed), isTrue);
      expect(
        _box(5, startUs: 10000000, fixedX: 145).conflictsWith(fixed),
        isFalse,
      );
    },
  );

  test(
    'rejected comments stay suppressed until expiry; seek and reflow reset',
    () {
      final gate = DanmakuCollisionGate();
      gate.beginFrame(1000000, layoutKey: 'phone');
      expect(gate.admit(_box(0, durationUs: 2000000, fixedX: 145)), isTrue);
      final later = _box(1, startUs: 500000, fixedX: 145);
      expect(gate.admit(later), isFalse);
      gate.beginFrame(2500000, layoutKey: 'phone');
      gate.retainActive({1});
      expect(gate.admit(later), isFalse);
      gate.beginFrame(1000000, layoutKey: 'phone');
      expect(gate.admit(later), isTrue);
      gate.beginFrame(1000000, layoutKey: 'tablet');
      expect(gate.placements, isEmpty);
    },
  );

  test(
    'all rows are used independently for each type before suppressing a burst',
    () {
      final gate = DanmakuCollisionGate();
      gate.beginFrame(1000000, layoutKey: 'phone');
      for (var index = 0; index < 30; index++) {
        final type = DanmakuType.values[index % 3];
        gate.place(
          _box(
            index,
            type: type,
            fixedX: type == DanmakuType.scroll ? null : 145,
          ),
          candidateYs: [22, 44],
        );
      }
      final accepted = gate.placements.toList();
      expect(accepted.length, 9);
      for (final type in DanmakuType.values) {
        expect(
          accepted.where((box) => box.type == type).map((box) => box.y).toSet(),
          {0, 22, 44},
        );
      }
      // Bitmap upload/metric refresh retains the chosen lane.
      final second = accepted.firstWhere((box) => box.y == 22);
      expect(gate.place(second.atY(0))!.y, 22);
    },
  );
}
