import 'dart:math' as math;

import 'package:flutter/physics.dart';

/// Uniform reading motion with no easing or slowly settling tail.
///
/// Duration grows with distance, with diminishing increases toward 300ms.
/// A line moves in about 200ms and a longer locate takes only a little longer.
/// Tiny corrections approach zero duration without a separate threshold.
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
    if (travel == 0) return TranscriptScrollMotion._(from, to, 0);
    // Map distance to duration, not to a fixed speed. This continuous,
    // concave mapping gives 40/80/240px about 200/240/277ms respectively.
    // Unlike a linear distance term it never grows into a long text sweep.
    // Retarget from the current position; inherited speed must not stretch
    // the new reading interval or fling a nearby target past the reader.
    final seconds = .300 * (travel / (travel + 20));
    return TranscriptScrollMotion._(from, to, seconds);
  }

  TranscriptScrollMotion._(this.from, this.to, this.seconds);

  final double from;
  final double to;
  final double seconds;

  Duration get duration => Duration(microseconds: (seconds * 1000000).ceil());

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
    return from + (to - from) * (time / seconds);
  }

  @override
  double dx(double time) {
    if (time < 0 || time >= seconds) return 0;
    return (to - from) / seconds;
  }

  @override
  bool isDone(double time) => time >= seconds;
}
