import 'package:flutter/foundation.dart';
import '../playback_startup.dart';

export '../playback_startup.dart'
    show PlaybackStartupContext, PlaybackStartupPhase;

typedef BilibiliStartupPhase = PlaybackStartupPhase;
typedef BilibiliStartupCancelled = PlaybackStartupCancelled;

/// Geometry belongs to this video/attempt, never the previously playing item.
/// Cover dimensions describe the poster, not the video rectangle: Bilibili
/// covers can be square or cropped even when the actual video is widescreen.
class BilibiliStartupGeometry extends ChangeNotifier {
  double? _videoAspectRatio;
  double? _coverAspectRatio;
  double? get videoAspectRatio => _videoAspectRatio;
  double? get coverAspectRatio => _coverAspectRatio;
  double get aspectRatio => _videoAspectRatio ?? 16 / 9;

  void reportVideo(double? ratio) {
    if (ratio == null ||
        !ratio.isFinite ||
        ratio <= 0 ||
        ratio == _videoAspectRatio) {
      return;
    }
    _videoAspectRatio = ratio;
    notifyListeners();
  }

  void reportCover(double ratio) {
    if (!ratio.isFinite || ratio <= 0 || ratio == _coverAspectRatio) return;
    _coverAspectRatio = ratio;
    notifyListeners();
  }

  void copyFrom(BilibiliStartupGeometry other) {
    reportVideo(other.videoAspectRatio);
    final cover = other.coverAspectRatio;
    if (cover != null) reportCover(cover);
  }
}

/// Bilibili keeps its poster geometry while sharing transport readiness with
/// every online source. Existing callers retain the Bilibili API.
class BilibiliStartupContext extends PlaybackStartupContext {
  @override
  String get mediaLabel => '视频';
  BilibiliStartupContext({
    super.limit,
    super.elapsed,
    super.onMark,
    super.coverUrl,
  }) : super(logName: 'BilibiliStartup');

  BilibiliStartupContext._continuation(BilibiliStartupContext previous)
    : super.continuation(previous, logName: 'BilibiliStartup') {
    geometry.copyFrom(previous.geometry);
  }

  final geometry = BilibiliStartupGeometry();
  static const indicatorDelay = PlaybackStartupContext.indicatorDelay;
  static const coverFadeDuration = PlaybackStartupContext.coverFadeDuration;
  static const positionTolerance = PlaybackStartupContext.positionTolerance;
  static const resumeFrameRecoveryDelay =
      PlaybackStartupContext.resumeFrameRecoveryDelay;

  @override
  BilibiliStartupContext continueOnNewNetwork() =>
      BilibiliStartupContext._continuation(this);
}
