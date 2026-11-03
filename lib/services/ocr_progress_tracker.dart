import 'dart:math' as math;

import '../models/ocr_subtitle_models.dart';

/// Preparing inputs is a separate phase; OCR starts at zero. Reserve only the
/// last percent for saving, without stretching earlier video positions.
class OcrTaskProgressTracker {
  static const double processingEnd = 0.99;
  final int totalMs;
  int _lastPublishedPercent = -1;

  OcrTaskProgressTracker({required this.totalMs}) : assert(totalMs > 0);

  static int percentFor(double progress) =>
      progress.isFinite ? (progress.clamp(0, 1) * 100 + 1e-7).floor() : 0;

  double progressFor(int completedMs) =>
      math.min(processingEnd, completedMs.clamp(0, totalMs) / totalMs);

  bool shouldPublish(int completedMs) {
    final percent = percentFor(progressFor(completedMs));
    if (percent <= _lastPublishedPercent) return false;
    _lastPublishedPercent = percent;
    return true;
  }
}

/// Counts completed timeline coverage separately for each region. Queue order,
/// faster parallel workers and sparse/duplicate frames cannot advance another
/// region's counter. All timestamps are relative to the selected time range.
class OcrRegionProgressTracker {
  OcrRegionProgressTracker({
    required this.startMs,
    required this.spanMs,
    required Iterable<int> tracks,
  }) : _completed = {for (final track in tracks) track: 0},
       _progress = OcrTaskProgressTracker(totalMs: spanMs * tracks.length);

  final int startMs, spanMs;
  final Map<int, int> _completed;
  final OcrTaskProgressTracker _progress;
  final Map<int, int> _publishedSeconds = {};

  void completedThrough(int track, int absoluteMs) {
    final previous = _completed[track];
    if (previous == null) throw ArgumentError.value(track, 'track');
    _completed[track] = math.max(
      previous,
      (absoluteMs - startMs).clamp(0, spanMs),
    );
  }

  double get progress => _progress.progressFor(
    _completed.values.fold<int>(0, (sum, value) => sum + value),
  );

  OcrRecognitionProgress get snapshot => OcrRecognitionProgress(
    total: Duration(milliseconds: spanMs),
    completedByTrack: {
      for (final entry in _completed.entries)
        entry.key: Duration(milliseconds: entry.value),
    },
  );

  bool shouldPublish() {
    final percentChanged = _progress.shouldPublish(
      _completed.values.fold<int>(0, (sum, value) => sum + value),
    );
    final secondsChanged = _completed.entries.any(
      (entry) => _publishedSeconds[entry.key] != entry.value ~/ 1000,
    );
    if (!percentChanged && !secondsChanged) return false;
    _publishedSeconds.addAll({
      for (final entry in _completed.entries) entry.key: entry.value ~/ 1000,
    });
    return true;
  }
}
