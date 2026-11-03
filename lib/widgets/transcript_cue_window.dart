import '../models/subtitle_model.dart';
import '../services/subtitle_timeline_resolver.dart';

/// Reuse a reading cursor between cue boundaries, including overlapping tracks.
/// The cache expires at every start or active end, rather than sampling less
/// often and delaying the highlight on displays with a high refresh rate.
class TranscriptCueWindow {
  SubtitleTimelineResolver? _resolver;
  List<SubtitleItem>? _subtitles;
  int _length = 0;
  int? _fromMs;
  int? _untilMs;
  List<int> _indices = const [];

  void clear() {
    _resolver = null;
    _subtitles = null;
    _fromMs = null;
    _untilMs = null;
    _length = 0;
    _indices = const [];
  }

  List<int> activeIndicesAtMs(
    SubtitleTimelineResolver resolver,
    List<SubtitleItem> subtitles,
    int positionMs,
  ) {
    if (identical(resolver, _resolver) &&
        identical(subtitles, _subtitles) &&
        resolver.length == _length &&
        _fromMs != null &&
        positionMs >= _fromMs! &&
        (_untilMs == null || positionMs < _untilMs!)) {
      return _indices;
    }

    final active = resolver.activeIndicesAtMs(
      positionMs,
      extendToNextStart: true,
    );
    final next = resolver.firstStartAfterMs(positionMs);
    int? until = next < subtitles.length
        ? subtitles[next].startTime.inMilliseconds
        : null;
    for (final index in active) {
      final end = subtitles[index].endTime.inMilliseconds;
      // An original end in the past belongs to gap-filled coverage. The next
      // start already bounds it; do not create a perpetually expired window.
      if (end > positionMs && (until == null || end < until)) until = end;
    }
    _resolver = resolver;
    _subtitles = subtitles;
    _length = resolver.length;
    _fromMs = positionMs;
    _untilMs = until;
    return _indices = active;
  }
}
