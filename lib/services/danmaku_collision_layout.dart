import 'dart:math' as math;

import '../models/danmaku_model.dart';
import '../models/danmaku_style.dart';

/// A stable subset of the source stream. Lowering density only removes items;
/// frame rate, seeks and prefetch batch boundaries cannot change the subset.
bool danmakuPassesDensity(DanmakuItem item, double density) {
  final fraction = density.isFinite
      ? density.clamp(kDanmakuDensityMin, kDanmakuDensityMax)
      : 1.0;
  if (fraction >= 1) return true;
  var hash = ((0x811c9dc5 ^ item.index) * 0x01000193) & 0x7fffffff;
  hash = ((hash ^ item.startTime.inMicroseconds) * 0x01000193) & 0x7fffffff;
  for (final value in item.text.codeUnits) {
    hash = ((hash ^ value) * 0x01000193) & 0x7fffffff;
  }
  return (hash % 10000) / 10000 < fraction;
}

/// Glyph body and trajectory in media time. Each danmaku type owns its lanes;
/// outlines, shadows and small overlaps between neighboring rows are allowed.
class DanmakuCollisionBox {
  const DanmakuCollisionBox({
    required this.index,
    required this.startUs,
    required this.durationUs,
    required this.startX,
    required this.endX,
    required this.y,
    required this.width,
    required this.height,
    required this.padding,
    required this.horizontalGap,
    this.type = DanmakuType.scroll,
  });

  final int index;
  final int startUs;
  final int durationUs;
  final double startX;
  final double endX;
  final double y;
  final double width;
  final double height;

  /// Raster extent only; decorative effects do not reserve neighboring lanes.
  final double padding;
  final double horizontalGap;
  final DanmakuType type;

  int get endUs => startUs + durationUs;

  double xAt(int timeUs) =>
      startX + (endX - startX) * ((timeUs - startUs) / durationUs);

  DanmakuCollisionBox atY(double value) => DanmakuCollisionBox(
    index: index,
    startUs: startUs,
    durationUs: durationUs,
    startX: startX,
    endX: endX,
    y: value,
    width: width,
    height: height,
    padding: padding,
    horizontalGap: horizontalGap,
    type: type,
  );

  /// Prevent a same-type pileup now or in the next half-second of media time.
  /// Predicting the entire crossing eliminated otherwise readable comments.
  bool conflictsWith(DanmakuCollisionBox other, {int? positionUs}) {
    if (type != other.type) return false;
    final verticalOverlap =
        math.min(y + height, other.y + other.height) - math.max(y, other.y);
    if (verticalOverlap <= math.min(height, other.height) * .5) {
      return false;
    }
    final from = math.max(math.max(startUs, other.startUs), positionUs ?? 0);
    final until = math.min(math.min(endUs, other.endUs), from + 500000);
    if (from >= until) return false;
    final atStart = xAt(from) - other.xAt(from);
    final atEnd = xAt(until) - other.xAt(until);
    final gap = math.max(horizontalGap, other.horizontalGap);
    return math.max(atStart, atEnd) > -width - gap &&
        math.min(atStart, atEnd) < other.width + gap;
  }
}

/// Tries all available lanes before skipping a crowded comment. Keeps its
/// chosen lane and admission decision for the entire visible lifetime.
/// A rejected comment never pops in halfway when the blocking comment leaves.
/// Reflow is permitted after a seek or an explicit presentation/layout change.
class DanmakuCollisionGate {
  final Map<int, DanmakuCollisionBox> _admitted = {};
  final Set<int> _suppressed = {};
  int? _lastPositionUs;
  Object? _layoutKey;

  Iterable<DanmakuCollisionBox> get placements => _admitted.values;

  bool beginFrame(int positionUs, {required Object layoutKey}) {
    final last = _lastPositionUs;
    final reset =
        _layoutKey != layoutKey ||
        last == null ||
        positionUs < last ||
        positionUs - last > 2000000;
    if (reset) {
      _admitted.clear();
      _suppressed.clear();
    }
    _layoutKey = layoutKey;
    _lastPositionUs = positionUs;
    return reset;
  }

  void retainActive(Set<int> indices) {
    _admitted.removeWhere((index, _) => !indices.contains(index));
    _suppressed.removeWhere((index) => !indices.contains(index));
  }

  DanmakuCollisionBox? place(
    DanmakuCollisionBox box, {
    Iterable<double> candidateYs = const [],
  }) {
    if (_suppressed.contains(box.index)) return null;
    final previous = _admitted[box.index];
    if (previous != null) {
      // Atlas uploads must not cause an in-flight comment to jump lanes.
      return _admitted[box.index] = box.atY(previous.y);
    }
    for (final y in [box.y].followedBy(candidateYs)) {
      final candidate = y == box.y ? box : box.atY(y);
      final crowded = _admitted.values.any(
        (other) => candidate.conflictsWith(other, positionUs: _lastPositionUs),
      );
      if (!crowded) {
        _admitted[box.index] = candidate;
        return candidate;
      }
    }
    _suppressed.add(box.index);
    return null;
  }

  bool admit(DanmakuCollisionBox box) => place(box) != null;
}
