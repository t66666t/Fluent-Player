import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'player_control_metrics.dart';

/// The portrait player's quality row leaves the fullscreen button and the
/// side rail free. Subtitles use the same geometry, including the first frame.
class CompactStreamQualityLayout {
  const CompactStreamQualityLayout._({
    required this.bounds,
    required this.maxPillWidth,
    required this.gap,
    required this.vertical,
  });

  final Rect bounds;
  final double maxPillWidth;
  final double gap;
  final bool vertical;

  factory CompactStreamQualityLayout.fromSize(
    Size size, {
    required int controlCount,
    EdgeInsets viewPadding = EdgeInsets.zero,
  }) {
    if (controlCount <= 0 || size.isEmpty || !size.isFinite) {
      return const CompactStreamQualityLayout._(
        bounds: Rect.zero,
        maxPillWidth: 0,
        gap: 0,
        vertical: false,
      );
    }
    final metrics = PlayerControlMetrics.fromSize(size);
    final pillHeight = math.min(metrics.chapterButtonHeight, size.height);
    final gap = math.min(6.0, size.width * .02);
    final left =
        math.max(viewPadding.left, metrics.sideControlHorizontalInset) +
        metrics.sideControlButtonExtent +
        6;
    final right = math.max(
      68.0,
      math.max(viewPadding.right, metrics.sideControlHorizontalInset) +
          metrics.sideControlButtonExtent +
          6,
    );
    final available = math.max(0.0, size.width - left - right);
    final stackedHeight = pillHeight * controlCount + gap * (controlCount - 1);
    final vertical =
        controlCount > 1 &&
        available < 196 &&
        size.height >= stackedHeight + 60;
    final pillWidth = math.min(
      144.0,
      vertical
          ? available
          : math.max(
              0.0,
              (available - gap * (controlCount - 1)) / controlCount,
            ),
    );
    final width = math.min(
      available,
      vertical
          ? pillWidth
          : pillWidth * controlCount + gap * (controlCount - 1),
    );
    final height = vertical ? stackedHeight : pillHeight;
    final bottom = math.min(20.0, math.max(0.0, size.height - height));
    return CompactStreamQualityLayout._(
      bounds: Rect.fromLTWH(
        size.width - right - width,
        size.height - bottom - height,
        width,
        height,
      ),
      maxPillWidth: pillWidth,
      gap: gap,
      vertical: vertical,
    );
  }
}
