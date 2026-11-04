import 'dart:math' as math;

import '../models/subtitle_model.dart';

/// Normalizes the sliding, overlapping cue timeline used by some automatic
/// captions (commonly seen in YouTube exports).
///
/// The decision is made from the subtitle timeline itself. This lets old,
/// renamed, moved, and manually imported subtitle files benefit as well.
class YouTubeAutoCaptionNormalizer {
  static bool shouldNormalize(List<SubtitleItem> subtitles) {
    if (subtitles.any((cue) => cue.isStructuredLyric)) return false;
    // Three overlapping transitions need at least four cues. This prevents a
    // short piece of ordinary overlapping dialogue from being rewritten.
    if (subtitles.length < 4) return false;
    return _looksLikeSlidingWindowAutoCaptions(subtitles);
  }

  static List<SubtitleItem> normalize(List<SubtitleItem> subtitles) {
    if (subtitles.length < 2) return subtitles;

    final normalized = <SubtitleItem>[];
    for (var i = 0; i < subtitles.length; i++) {
      final current = subtitles[i];
      final currentStartMs = current.startTime.inMilliseconds;
      final currentEndMs = current.endTime.inMilliseconds;
      final nextStartMs = i + 1 < subtitles.length
          ? subtitles[i + 1].startTime.inMilliseconds
          : currentEndMs;
      // End the older cue as soon as the next cue begins. The display layer
      // can therefore render only the newest active sentence.
      final cappedEndMs = math.min(currentEndMs, nextStartMs);
      if (cappedEndMs <= currentStartMs) continue;
      normalized.add(
        current.copyWith(index: normalized.length + 1,
          endTime: Duration(milliseconds: cappedEndMs),
          timedSpans: current.shiftedSpans(Duration.zero, current.startTime,
            Duration(milliseconds: cappedEndMs))),
      );
    }
    return normalized.isEmpty ? subtitles : normalized;
  }

  static bool _looksLikeSlidingWindowAutoCaptions(
    List<SubtitleItem> subtitles,
  ) {
    var overlapCount = 0;
    var sameEndOverlapCount = 0;
    var textPairCount = 0;
    for (var i = 0; i + 1 < subtitles.length; i++) {
      final current = subtitles[i];
      final next = subtitles[i + 1];
      if (current.imageLoader != null || next.imageLoader != null) continue;
      if (current.text.trim().isEmpty || next.text.trim().isEmpty) continue;

      textPairCount++;
      final currentStartMs = current.startTime.inMilliseconds;
      final currentEndMs = current.endTime.inMilliseconds;
      final nextStartMs = next.startTime.inMilliseconds;
      final nextEndMs = next.endTime.inMilliseconds;
      if (nextStartMs > currentStartMs && nextStartMs < currentEndMs) {
        overlapCount++;
        if (currentEndMs == nextEndMs) sameEndOverlapCount++;
      }
    }

    if (overlapCount < 3 || textPairCount < 3) return false;
    // Equal end times are a strong signal. Otherwise demand a dense run of
    // overlaps: occasional overlaps in normal dialogue must not be changed.
    if (sameEndOverlapCount >= 2) return true;
    return overlapCount * 4 >= textPairCount * 3;
  }
}
