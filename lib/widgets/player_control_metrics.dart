import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Responsive dimensions for the playback controls.
///
/// The scale is based on the player's own constraints rather than the physical
/// screen, so split-screen windows and an open sidebar are handled correctly.
/// The shortest side controls perceived size while available width prevents a
/// dense control row from overflowing.
@immutable
class PlayerControlMetrics {
  final double scale;
  final bool isCompact;
  final double iconSize;
  final double primaryIconSize;
  final double sideControlButtonExtent;
  final double sideControlIconSize;
  final double sideControlGap;
  final double sideControlHorizontalInset;
  final double bottomHorizontalPadding;
  final double bottomPadding;
  final double bottomRowHeight;
  final double bottomButtonExtent;
  final double controlGap;
  final double progressHitHeight;
  final double chapterButtonHeight;
  final double chapterButtonBottom;
  final double chapterButtonWidthFactor;
  final double timeFontSize;
  final double toolFontSize;
  final double episodeButtonHeight;
  final double episodeIconSize;
  final double trackHeight;
  final double thumbRadius;
  final double overlayRadius;

  const PlayerControlMetrics._({
    required this.scale,
    required this.isCompact,
    required this.iconSize,
    required this.primaryIconSize,
    required this.sideControlButtonExtent,
    required this.sideControlIconSize,
    required this.sideControlGap,
    required this.sideControlHorizontalInset,
    required this.bottomHorizontalPadding,
    required this.bottomPadding,
    required this.bottomRowHeight,
    required this.bottomButtonExtent,
    required this.controlGap,
    required this.progressHitHeight,
    required this.chapterButtonHeight,
    required this.chapterButtonBottom,
    required this.chapterButtonWidthFactor,
    required this.timeFontSize,
    required this.toolFontSize,
    required this.episodeButtonHeight,
    required this.episodeIconSize,
    required this.trackHeight,
    required this.thumbRadius,
    required this.overlayRadius,
  });

  factory PlayerControlMetrics.fromSize(Size size, {double safeBottom = 0}) {
    final width = size.width.isFinite ? math.max(0.0, size.width) : 0.0;
    final height = size.height.isFinite ? math.max(0.0, size.height) : 0.0;
    final shortestSide = math.min(width, height);

    final shortSideProgress = ((shortestSide - 320) / 400).clamp(0.0, 1.0);
    final easedProgress = 1 - math.pow(1 - shortSideProgress, 2).toDouble();
    final shortSideScale = 0.72 + (0.28 * easedProgress);
    final widthPressure = (width / 900).clamp(0.78, 1.0);
    final scale = math
        .min(shortSideScale, widthPressure)
        .clamp(0.72, 1.0)
        .toDouble();

    double scaled(double value, double minimum) =>
        (value * scale).clamp(minimum, value).toDouble();

    // Keep the thin visual track, with a target large enough for touch. The
    // chapter/quality capsules reserve space above this full interaction area.
    final progressHitHeight = scaled(44, 40);
    final chapterButtonHeight = scaled(34, 28);
    final bottomButtonExtent = scaled(44, 40);
    return PlayerControlMetrics._(
      scale: scale,
      isCompact: scale < 0.88 || width < 700,
      iconSize: scaled(24, 19),
      primaryIconSize: scaled(32, 25),
      sideControlButtonExtent: scaled(40, 36),
      sideControlIconSize: scaled(20, 17),
      sideControlGap: scaled(5, 3),
      sideControlHorizontalInset: scaled(12, 8),
      bottomHorizontalPadding: scaled(16, 8),
      bottomPadding: math.max(safeBottom, scaled(4, 3)),
      bottomRowHeight: bottomButtonExtent,
      bottomButtonExtent: bottomButtonExtent,
      controlGap: scaled(8, 4),
      progressHitHeight: progressHitHeight,
      chapterButtonHeight: chapterButtonHeight,
      // Keep the visual progress line centered between the chapter pill and
      // the controls below it. The progress line sits at the midpoint of the
      // hit area, so using the full hit height produces equal spacing.
      chapterButtonBottom: progressHitHeight,
      // YouTube lets the title determine the pill width and only constrains
      // its maximum. Keep that maximum responsive without letting the pill
      // dominate narrow players.
      chapterButtonWidthFactor: (0.28 + ((1 - scale) * 0.10)).clamp(0.28, 0.34),
      timeFontSize: scaled(12, 10),
      toolFontSize: scaled(14, 11),
      episodeButtonHeight: scaled(32, 27),
      episodeIconSize: scaled(18, 15),
      trackHeight: scaled(4, 2.5),
      thumbRadius: scaled(6, 4),
      overlayRadius: scaled(10, 8),
    );
  }

  /// Shared chrome for the chapter / quality capsules above the progress bar.
  double get progressPillFontSize => (13 * scale).clamp(10.0, 13.0).toDouble();

  double get progressPillIconSize => (18 * scale).clamp(16.0, 18.0).toDouble();

  double get progressPillContentGap => (5 * scale).clamp(3.0, 5.0).toDouble();

  double get progressPillHorizontalPadding =>
      (12 * scale).clamp(9.0, 12.0).toDouble();

  double get progressPillTextMeasurementSlack =>
      (4 * scale).clamp(3.0, 4.0).toDouble();

  double get progressPillChromeWidth =>
      (progressPillHorizontalPadding * 2) +
      progressPillContentGap +
      progressPillIconSize;

  /// Width that can show every [labels] value without resizing when the
  /// selected label changes. Still capped by [maxWidth] on narrow players.
  double measureProgressPillWidth({
    required Iterable<String> labels,
    required TextStyle textStyle,
    required TextDirection textDirection,
    required TextScaler textScaler,
    Locale? locale,
    required double maxWidth,
  }) {
    var maxTextWidth = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        maxLines: 1,
        textDirection: textDirection,
        textScaler: textScaler,
        locale: locale,
        textWidthBasis: TextWidthBasis.longestLine,
      )..layout();
      maxTextWidth = math.max(maxTextWidth, painter.width);
    }
    return math.min(
      maxWidth,
      progressPillChromeWidth + maxTextWidth + progressPillTextMeasurementSlack,
    );
  }

  double progressAreaHeight({
    required bool hasChapterButton,
    bool hasQualityButton = false,
  }) {
    if (!hasChapterButton && !hasQualityButton) return progressHitHeight;
    return progressHitHeight + chapterButtonHeight + (4 * scale);
  }

  double bottomControlsHeight({
    required bool hasChapterButton,
    bool hasQualityButton = false,
  }) {
    return bottomPadding +
        bottomRowHeight +
        progressAreaHeight(
          hasChapterButton: hasChapterButton,
          hasQualityButton: hasQualityButton,
        );
  }
}
