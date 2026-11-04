import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../models/subtitle_style.dart';

export 'subtitle_text_wrap.dart';

/// Shared geometry for playback and video export. Existing ordinary layouts
/// remain proportional; the trial can opt into bounded screen reading sizes.
abstract final class SubtitleLayout {
  static const maxWidthFraction = .86;
  static const maxLineEms = 34.0;

  static double videoReferenceHeight(Size viewport, {double? referenceHeight}) {
    final height = referenceHeight ?? viewport.height;
    if (!viewport.width.isFinite || viewport.width <= 0) {
      return height.isFinite && height > 0 ? height : kSubtitleReferenceHeight;
    }
    return height.isFinite && height > 0
        ? math.min(viewport.width, height)
        : viewport.width;
  }

  /// Ghost captions are a reading aid. Bound their size using the whole window
  /// so a sidebar or a differently shaped video cannot resize the glyphs.
  static double ghostReferenceHeight(Size viewport) {
    final shortSide = viewport.shortestSide;
    return shortSide.isFinite && shortSide > 0
        ? shortSide.clamp(360.0, 720.0)
        : kSubtitleReferenceHeight;
  }

  /// Logical screen reading size for ghost captions and calibration of the
  /// ordinary video-relative profile.
  /// Square-root growth avoids doubling the type when a tablet's short side
  /// doubles. Bounds apply before the user's font and overall-size multipliers.
  static double balancedScreenReferenceHeight(
    Size pageSize, {
    double? viewportWidth,
  }) {
    final shortSide = pageSize.shortestSide;
    final safeShortSide = shortSide.isFinite && shortSide > 0
        ? shortSide
        : 390.0;
    var fontSize = (17 * math.sqrt(safeShortSide / 390)).clamp(16.0, 26.0);
    // Keep at least twelve full-width glyphs on unusually narrow panes.
    if (viewportWidth != null && viewportWidth.isFinite && viewportWidth > 0) {
      fontSize = math.min(fontSize, viewportWidth * maxWidthFraction / 12);
    }
    return fontSize *
        kSubtitleReferenceHeight /
        kSubtitleTextMetricReferenceFontSize;
  }

  /// Calibrate against the complete screen, then scale with the actual video.
  /// Rotating the same screen preserves its short side and therefore the
  /// glyph/video ratio. Do not impose a pixel floor or a pane-width cap here:
  /// either would enlarge captions relative to a smaller portrait video.
  static double balancedVideoReferenceHeight(
    Size viewport, {
    required Size pageSize,
    double? referenceHeight,
  }) {
    final pageShortSide = pageSize.shortestSide;
    final validPage = pageShortSide.isFinite && pageShortSide > 0;
    final calibrationSize = validPage ? pageSize : viewport;
    final shortSide = calibrationSize.shortestSide;
    final safeShortSide = shortSide.isFinite && shortSide > 0
        ? shortSide
        : kSubtitleReferenceHeight;
    return videoReferenceHeight(viewport, referenceHeight: referenceHeight) *
        balancedScreenReferenceHeight(calibrationSize) /
        safeShortSide;
  }

  /// Burned-in text belongs to video pixels, not a device's logical pixels.
  /// Freeze the reading profile at a 720-short-side reference before scaling
  /// to the output canvas, so 4K export does not get a screen-size font cap.
  static SubtitleStyle forVideoExport(SubtitleStyle style) {
    if (!style.layoutStyle.balancedScreenSizing) return style;
    final factor =
        balancedScreenReferenceHeight(const Size(1280, 720)) /
        kSubtitleReferenceHeight;
    return style.copyWith(
      layoutStyle: style.layoutStyle.copyWith(
        balancedScreenSizing: false,
        // Scale the whole block, including background padding and item gaps.
        overallScale: style.overallScale * factor,
      ),
    );
  }

  static double contentWidth({
    required double viewportWidth,
    required double fontSize,
    double presetWidth = 1,
  }) => math.min(
    viewportWidth * math.min(maxWidthFraction, presetWidth),
    fontSize * maxLineEms,
  );
}
