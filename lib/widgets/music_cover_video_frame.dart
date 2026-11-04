import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// How a video sits inside the landscape music cover slot.
///
/// The slot height is always the existing cover edge. Only the width changes,
/// so the title, transport and lyrics below and beside the cover stay put.
class MusicCoverVideoFrame {
  const MusicCoverVideoFrame({
    required this.width,
    required this.height,
    required this.fit,
    required this.usesBackdrop,
  });

  final double width;
  final double height;
  final BoxFit fit;

  /// Blurred artwork fills the gaps when the picture is letterboxed.
  final bool usesBackdrop;
}

const double _portraitAspect = 0.92;
const double _squareAspect = 1.18;
const double _maxLayoutAspect = 2.6;
const double _coverCropTolerance = 0.08;

/// Places [aspectRatio] (width / height) in a cover of [coverSize].
///
/// [maxWidth] is the left panel's inner width. Landscape pictures grow toward
/// it; they never grow taller than the cover, and extreme ratios are clamped
/// so a pathological file cannot cross into the lyric column.
MusicCoverVideoFrame layoutMusicCoverVideoFrame({
  required double coverSize,
  required double maxWidth,
  required double aspectRatio,
}) {
  final height = coverSize <= 0 ? 0.0 : coverSize;
  final upper = !maxWidth.isFinite || maxWidth <= 0
      ? height
      : math.max(maxWidth, height);
  if (!aspectRatio.isFinite || aspectRatio <= 0 || height == 0) {
    return MusicCoverVideoFrame(
      width: height,
      height: height,
      fit: BoxFit.cover,
      usesBackdrop: false,
    );
  }

  // Portrait and nearly square pictures keep the cover's footprint. A tall
  // frame stays fully visible; a square frame fills the card the way the
  // artwork already does, so the flip has almost no change in size.
  if (aspectRatio <= _squareAspect) {
    final portrait = aspectRatio < _portraitAspect;
    return MusicCoverVideoFrame(
      width: height,
      height: height,
      fit: portrait ? BoxFit.contain : BoxFit.cover,
      usesBackdrop: portrait,
    );
  }

  final layoutAspect = math.min(aspectRatio, _maxLayoutAspect);
  final idealWidth = height * layoutAspect;
  if (idealWidth <= upper + 0.5) {
    final matchesCard = (aspectRatio - layoutAspect).abs() < 0.001;
    return MusicCoverVideoFrame(
      width: idealWidth,
      height: height,
      fit: matchesCard ? BoxFit.fill : BoxFit.contain,
      usesBackdrop: !matchesCard,
    );
  }

  // Wider than the panel. Crop only when the lost sliver is tiny; otherwise
  // show the whole frame on a blurred cover so faces and titles stay intact.
  final boxAspect = upper / height;
  final cropLoss = 1 - (boxAspect / aspectRatio);
  final coverCrop = cropLoss >= 0 && cropLoss <= _coverCropTolerance;
  return MusicCoverVideoFrame(
    width: upper,
    height: height,
    fit: coverCrop ? BoxFit.cover : BoxFit.contain,
    usesBackdrop: !coverCrop,
  );
}
