import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/media_chapter.dart';

class ChapterSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  final List<MediaChapter> chapters;
  final int durationMs;

  const ChapterSliderTrackShape({
    required this.chapters,
    required this.durationMs,
  });

  @override
  bool get isRounded => true;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 0;
    if (trackHeight <= 0 || durationMs <= 0) return;
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (trackRect.width <= 0) return;

    final activePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledActiveTrackColor,
        end: sliderTheme.activeTrackColor,
      ).evaluate(enableAnimation)!;
    final inactivePaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledInactiveTrackColor,
        end: sliderTheme.inactiveTrackColor,
      ).evaluate(enableAnimation)!;
    final secondaryPaint = Paint()
      ..color = ColorTween(
        begin: sliderTheme.disabledSecondaryActiveTrackColor,
        end: sliderTheme.secondaryActiveTrackColor,
      ).evaluate(enableAnimation)!;

    final boundaries = <double>[0];
    for (final chapter in chapters.skip(1)) {
      final fraction = chapter.startMs / durationMs;
      if (fraction > 0 && fraction < 1) boundaries.add(fraction);
    }
    boundaries.add(1);
    boundaries.sort();

    final thumbFraction = textDirection == TextDirection.ltr
        ? ((thumbCenter.dx - trackRect.left) / trackRect.width).clamp(0.0, 1.0)
        : ((trackRect.right - thumbCenter.dx) / trackRect.width).clamp(
            0.0,
            1.0,
          );
    final secondaryFraction = secondaryOffset == null
        ? thumbFraction
        : (textDirection == TextDirection.ltr
                  ? (secondaryOffset.dx - trackRect.left) / trackRect.width
                  : (trackRect.right - secondaryOffset.dx) / trackRect.width)
              .clamp(thumbFraction, 1.0);
    // The visual separator scales with the actual player width. A 0.24%
    // separator stays subtle on phones while remaining visible on wide windows.
    final gapFraction = 0.0024;

    for (var index = 0; index < boundaries.length - 1; index++) {
      var start = boundaries[index];
      var end = boundaries[index + 1];
      if (index > 0) start += gapFraction / 2;
      if (index < boundaries.length - 2) end -= gapFraction / 2;
      if (end <= start) continue;

      final activeEnd = math.min(end, thumbFraction);
      if (activeEnd > start) {
        _paintFractionRange(
          context.canvas,
          trackRect,
          start,
          activeEnd,
          activePaint,
          textDirection,
        );
      }
      final bufferedStart = math.max(start, thumbFraction);
      final bufferedEnd = math.min(end, secondaryFraction);
      if (bufferedEnd > bufferedStart) {
        _paintFractionRange(
          context.canvas,
          trackRect,
          bufferedStart,
          bufferedEnd,
          secondaryPaint,
          textDirection,
        );
      }
      final inactiveStart = math.max(start, secondaryFraction);
      if (end > inactiveStart) {
        _paintFractionRange(
          context.canvas,
          trackRect,
          inactiveStart,
          end,
          inactivePaint,
          textDirection,
        );
      }
    }
  }

  void _paintFractionRange(
    Canvas canvas,
    Rect trackRect,
    double start,
    double end,
    Paint paint,
    TextDirection textDirection,
  ) {
    final startX = textDirection == TextDirection.ltr
        ? trackRect.left + trackRect.width * start
        : trackRect.right - trackRect.width * start;
    final endX = textDirection == TextDirection.ltr
        ? trackRect.left + trackRect.width * end
        : trackRect.right - trackRect.width * end;
    final rect = Rect.fromLTRB(
      math.min(startX, endX),
      trackRect.top,
      math.max(startX, endX),
      trackRect.bottom,
    );
    if (rect.width <= 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(trackRect.height / 2)),
      paint,
    );
  }
}
