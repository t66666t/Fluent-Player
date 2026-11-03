import 'dart:ui';

import 'package:media_kit/media_kit.dart';

/// Presentation dimensions, independent of the native texture allocation.
abstract final class VideoDisplayGeometry {
  static Size? fromVideoParams(VideoParams params) {
    var width = params.dw?.toDouble();
    var height = params.dh?.toDouble();
    if (width == null || height == null || width <= 0 || height <= 0) {
      final codedWidth = params.w;
      final codedHeight = params.h;
      if (codedWidth == null ||
          codedHeight == null ||
          codedWidth <= 0 ||
          codedHeight <= 0) {
        return null;
      }
      // Paused HLS can publish demuxer dimensions before dw/dh exist. Waiting
      // for the decoded display dimensions here deadlocks initialize(), since
      // quality handoff starts muted decoding only AFTER initialize completes.
      // Actual frame readiness is still checked by the handoff before commit.
      height = codedHeight.toDouble();
      final aspect = params.aspect;
      final par = params.par;
      width = aspect != null && aspect.isFinite && aspect > 0
          ? height * aspect
          : codedWidth * (par != null && par.isFinite && par > 0 ? par : 1.0);
    }
    final rotation = (params.rotate ?? 0) % 360;
    return rotation == 90 || rotation == 270
        ? Size(height, width)
        : Size(width, height);
  }

  static bool hasMotionVideo(Tracks tracks) => tracks.video.any(
    (track) =>
        track.id != 'auto' &&
        track.id != 'no' &&
        track.image != true &&
        track.albumart != true,
  );

  /// Elapsed time alone cannot distinguish slow video decoding from audio.
  static bool canInitializeWithoutVideo({
    required bool knownAudioOnly,
    required bool videoIntentionallyDisabled,
    required Tracks tracks,
  }) =>
      knownAudioOnly ||
      videoIntentionallyDisabled ||
      (!hasMotionVideo(tracks) &&
          tracks.audio.any((track) => track.id != 'auto' && track.id != 'no'));
}
