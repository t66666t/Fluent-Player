import 'dart:math' as math;

import 'package:flutter/animation.dart';

/// Bounded reading motion with smooth starts, stops and same-direction retargets.
///
/// Logical distance sets the reading time; viewport-relative travel adds time
/// for moves that occupy more of the reader's field of view. There are no
/// device breakpoints, fixed-speed sweeps or spring overshoots.
class TranscriptScrollMotion extends Simulation {
  factory TranscriptScrollMotion({
    required double from,
    required double to,
    required double viewport,
    double initialVelocity = 0,
    bool isAuto = false,
    bool visibleTarget = false,
  }) {
    final distance = to - from;
    final travel = distance.abs();
    if (travel == 0) return TranscriptScrollMotion._(from, to, 0, 0);
    final extent = viewport.isFinite && viewport > 0 ? viewport : 700.0;
    // At a 700dp viewport, 40/80/240/700dp takes 209/265/375/480ms.
    // Smooth, concave terms avoid timing cliffs at line/device boundaries.
    // Tiny corrections still finish quickly instead of acquiring a fixed delay.
    final seconds =
        (.120 * (1 - math.exp(-travel / 12)) +
            .160 * (1 - math.exp(-travel / 120)) +
            .200 * math.sqrt(travel / extent)) *
        (isAuto ? 1.06 : 1.0);
    final boundedSeconds = math.min(seconds, .650);
    // A quintic Hermite trajectory preserves safe forward velocity. Limiting
    // the normalized tangent to 2 keeps the entire curve monotonic, with no
    // overshoot even when a fast locate is redirected to a very close cue.
    final tangent = initialVelocity.isFinite
        ? (initialVelocity * distance.sign * boundedSeconds / travel).clamp(
            0.0,
            2.0,
          )
        : 0.0;
    return TranscriptScrollMotion._(from, to, boundedSeconds, tangent);
  }

  TranscriptScrollMotion._(this.from, this.to, this.seconds, this._tangent);

  final double from;
  final double to;
  final double seconds;
  final double _tangent;

  Duration get duration => Duration(microseconds: (seconds * 1000000).ceil());

  /// Keep custom ScrollPosition implementations on the same trajectory too.
  Curve get curve => _TranscriptMotionCurve(this);

  static double speedLimitFor(double viewport) =>
      (viewport * 1.6).clamp(720.0, 960.0);

  /// Budget for cached anchors outside the visible viewport. Visible anchors
  /// can move through at most one viewport within the bounded reading interval.
  static double travelLimitFor(double viewport) =>
      math.min(math.min(viewport * .4, 200), speedLimitFor(viewport) * .23);

  @override
  double x(double time) {
    if (time <= 0) return from;
    if (time >= seconds) return to;
    final t = time / seconds;
    final t3 = t * t * t;
    final progress =
        t3 * (10 + t * (-15 + 6 * t)) +
        _tangent * (t + t3 * (-6 + t * (8 - 3 * t)));
    return from + (to - from) * progress;
  }

  @override
  double dx(double time) {
    if (time < 0 || time >= seconds) return 0;
    final t = time / seconds;
    return (to - from) /
        seconds *
        (1 - t) *
        (1 - t) *
        (30 * t * t + _tangent * (1 + 2 * t - 15 * t * t));
  }

  @override
  bool isDone(double time) => time >= seconds;
}

class _TranscriptMotionCurve extends Curve {
  const _TranscriptMotionCurve(this.motion);

  final TranscriptScrollMotion motion;

  @override
  double transformInternal(double t) => motion.to == motion.from
      ? t
      : (motion.x(t * motion.seconds) - motion.from) /
            (motion.to - motion.from);
}
