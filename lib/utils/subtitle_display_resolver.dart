import 'dart:math' as math;

import '../models/subtitle_model.dart';

class SubtitleTrackMatchResult {
  /// The strongest interval match for callers that need a single anchor.
  final Map<int, int> primaryToSecondary;
  final Map<int, int> secondaryToPrimary;

  /// All meaningful matches, in timeline order. A cue may occur in multiple
  /// rows when the tracks split the same sentence differently.
  final Map<int, List<int>> primaryToSecondaryIndices;
  final Map<int, List<int>> secondaryToPrimaryIndices;

  const SubtitleTrackMatchResult({
    required this.primaryToSecondary,
    required this.secondaryToPrimary,
    this.primaryToSecondaryIndices = const {},
    this.secondaryToPrimaryIndices = const {},
  });

  int get matchCount => primaryToSecondary.length;
  bool get hasMatches => primaryToSecondary.isNotEmpty;

  String secondaryTextForPrimary(
    int primaryIndex,
    List<SubtitleItem> secondarySubtitles, {
    String separator = '\n',
  }) {
    final indices =
        primaryToSecondaryIndices[primaryIndex] ??
        (primaryToSecondary.containsKey(primaryIndex)
            ? <int>[primaryToSecondary[primaryIndex]!]
            : const <int>[]);
    final texts = <String>[];
    String? previousText;
    for (final index in indices) {
      final text = secondarySubtitles[index].text.trim();
      if (text.isEmpty) continue;
      final normalized = text.replaceAll(RegExp(r'\s+'), ' ');
      // Identical adjacent OCR fragments should not repeat the translation.
      if (normalized != previousText) texts.add(text);
      previousText = normalized;
    }
    return texts.join(separator);
  }
}

class SubtitleDisplaySelection {
  final List<SubtitleItem> subtitles;
  final bool usesSecondaryTrack;

  const SubtitleDisplaySelection({
    required this.subtitles,
    required this.usesSecondaryTrack,
  });
}

SubtitleDisplaySelection resolveSubtitleDisplaySelection({
  required int lineFilterMode,
  required List<SubtitleItem> primarySubtitles,
  required List<SubtitleItem> secondarySubtitles,
}) {
  if (lineFilterMode == 2 && secondarySubtitles.isNotEmpty) {
    return SubtitleDisplaySelection(
      subtitles: secondarySubtitles,
      usesSecondaryTrack: true,
    );
  }
  return SubtitleDisplaySelection(
    subtitles: primarySubtitles,
    usesSecondaryTrack: false,
  );
}

/// Aligns complete cue intervals, independently of playback gap filling.
///
/// Overlap must cover at least half of the shorter cue. This allows both
/// split and merged sentences, while rejecting small overlaps at an adjacent
/// sentence boundary. Only otherwise unmatched cues can use the bounded,
/// mutually nearest boundary fallback.
SubtitleTrackMatchResult matchSubtitleTracks({
  required List<SubtitleItem> primarySubtitles,
  required List<SubtitleItem> secondarySubtitles,
  int maxGapMs = 1500,
  // Kept for source compatibility. Searches are time-bounded, not cue-bounded:
  // a long sentence can legitimately contain more than six translated cues.
  int lookAhead = 6,
}) {
  if (primarySubtitles.isEmpty || secondarySubtitles.isEmpty) {
    return const SubtitleTrackMatchResult(
      primaryToSecondary: <int, int>{},
      secondaryToPrimary: <int, int>{},
    );
  }

  final indexAlignedMatch = _tryBuildIndexAlignedMatch(
    primarySubtitles: primarySubtitles,
    secondarySubtitles: secondarySubtitles,
  );
  if (indexAlignedMatch != null) {
    return indexAlignedMatch;
  }

  final primary = _timedCues(primarySubtitles);
  final secondary = _timedCues(secondarySubtitles);
  final primaryMatches = <int, List<int>>{};
  final secondaryMatches = <int, List<int>>{};
  final primaryBest = <int, _CuePair>{};
  final secondaryBest = <int, _CuePair>{};

  void addMatch(_CuePair pair) {
    (primaryMatches[pair.primary.index] ??= []).add(pair.secondary.index);
    (secondaryMatches[pair.secondary.index] ??= []).add(pair.primary.index);
    if (pair.strongerThan(primaryBest[pair.primary.index])) {
      primaryBest[pair.primary.index] = pair;
    }
    if (pair.strongerThan(secondaryBest[pair.secondary.index])) {
      secondaryBest[pair.secondary.index] = pair;
    }
  }

  final gapLimit = math.max(0, maxGapMs);
  final fallbackCandidates = <_CuePair>[];
  _visitNearbyPairs(primary, secondary, gapLimit, (pair) {
    final shorterDuration = math.min(
      pair.primary.durationMs,
      pair.secondary.durationMs,
    );
    if (pair.overlapMs > 0 && pair.overlapMs * 2 >= shorterDuration) {
      addMatch(pair);
    } else if (gapLimit > 0 &&
        (pair.primary.startMs - pair.secondary.startMs).abs() <= gapLimit &&
        (pair.primary.endMs - pair.secondary.endMs).abs() <= gapLimit) {
      fallbackCandidates.add(pair);
    }
  });

  // Compute these simultaneously so an unmatched fragment cannot steal the
  // translation of a well-matched neighbouring sentence.
  final primaryFallback = <int, _CuePair>{};
  final secondaryFallback = <int, _CuePair>{};
  for (final pair in fallbackCandidates) {
    if (primaryMatches.containsKey(pair.primary.index) ||
        secondaryMatches.containsKey(pair.secondary.index)) {
      continue;
    }
    if (pair.nearerThan(primaryFallback[pair.primary.index])) {
      primaryFallback[pair.primary.index] = pair;
    }
    if (pair.nearerThan(secondaryFallback[pair.secondary.index])) {
      secondaryFallback[pair.secondary.index] = pair;
    }
  }
  for (final pair in primaryFallback.values) {
    if (identical(pair, secondaryFallback[pair.secondary.index])) {
      addMatch(pair);
    }
  }

  return SubtitleTrackMatchResult(
    primaryToSecondary: Map.unmodifiable({
      for (final entry in primaryBest.entries)
        entry.key: entry.value.secondary.index,
    }),
    secondaryToPrimary: Map.unmodifiable({
      for (final entry in secondaryBest.entries)
        entry.key: entry.value.primary.index,
    }),
    primaryToSecondaryIndices: _orderedMatches(
      primaryMatches,
      secondarySubtitles,
    ),
    secondaryToPrimaryIndices: _orderedMatches(
      secondaryMatches,
      primarySubtitles,
    ),
  );
}

SubtitleTrackMatchResult? _tryBuildIndexAlignedMatch({
  required List<SubtitleItem> primarySubtitles,
  required List<SubtitleItem> secondarySubtitles,
}) {
  if (primarySubtitles.length != secondarySubtitles.length) {
    return null;
  }
  if (primarySubtitles.isEmpty) {
    return const SubtitleTrackMatchResult(
      primaryToSecondary: <int, int>{},
      secondaryToPrimary: <int, int>{},
    );
  }

  const int startToleranceMs = 120;
  const int endToleranceMs = 180;
  for (int i = 0; i < primarySubtitles.length; i++) {
    final int startDeltaMs =
        (primarySubtitles[i].startTime.inMilliseconds -
                secondarySubtitles[i].startTime.inMilliseconds)
            .abs();
    final int endDeltaMs =
        (primarySubtitles[i].endTime.inMilliseconds -
                secondarySubtitles[i].endTime.inMilliseconds)
            .abs();
    // Every cue must agree. A 90% agreement shortcut used to force incorrect
    // index matches for the remaining cues even when they had no overlap.
    final overlapMs =
        math.min(
          primarySubtitles[i].endTime.inMilliseconds,
          secondarySubtitles[i].endTime.inMilliseconds,
        ) -
        math.max(
          primarySubtitles[i].startTime.inMilliseconds,
          secondarySubtitles[i].startTime.inMilliseconds,
        );
    if (startDeltaMs > startToleranceMs ||
        endDeltaMs > endToleranceMs ||
        overlapMs <= 0) {
      return null;
    }
  }

  final Map<int, int> primaryToSecondary = <int, int>{};
  final Map<int, int> secondaryToPrimary = <int, int>{};
  for (int i = 0; i < primarySubtitles.length; i++) {
    primaryToSecondary[i] = i;
    secondaryToPrimary[i] = i;
  }

  return SubtitleTrackMatchResult(
    primaryToSecondary: Map.unmodifiable(primaryToSecondary),
    secondaryToPrimary: Map.unmodifiable(secondaryToPrimary),
    primaryToSecondaryIndices: Map.unmodifiable({
      for (final index in primaryToSecondary.keys)
        index: List<int>.unmodifiable([index]),
    }),
    secondaryToPrimaryIndices: Map.unmodifiable({
      for (final index in secondaryToPrimary.keys)
        index: List<int>.unmodifiable([index]),
    }),
  );
}

Map<int, List<int>> _orderedMatches(
  Map<int, List<int>> matches,
  List<SubtitleItem> subtitles,
) {
  return Map.unmodifiable(
    matches.map((index, values) {
      values.sort((a, b) {
        final byStart = subtitles[a].startTime.compareTo(
          subtitles[b].startTime,
        );
        return byStart != 0 ? byStart : a.compareTo(b);
      });
      return MapEntry(index, List<int>.unmodifiable(values));
    }),
  );
}

class _TimedCue {
  final int index;
  final int startMs;
  final int endMs;

  const _TimedCue(this.index, this.startMs, this.endMs);
  int get durationMs => endMs - startMs;
}

List<_TimedCue> _timedCues(List<SubtitleItem> subtitles) {
  final ordered = List<int>.generate(subtitles.length, (index) => index);
  ordered.sort((a, b) {
    final byStart = subtitles[a].startTime.compareTo(subtitles[b].startTime);
    return byStart != 0 ? byStart : a.compareTo(b);
  });
  return List<_TimedCue>.generate(ordered.length, (position) {
    final index = ordered[position];
    final start = subtitles[index].startTime.inMilliseconds;
    var end = subtitles[index].endTime.inMilliseconds;
    // Timestamp-only formats may omit an end. Real non-empty intervals are
    // never extended into silence just to manufacture a translation match.
    if (end <= start) {
      end = position + 1 < ordered.length
          ? math.max(
              start + 1,
              subtitles[ordered[position + 1]].startTime.inMilliseconds,
            )
          : start + 1;
    }
    return _TimedCue(index, start, end);
  });
}

class _CuePair {
  final _TimedCue primary;
  final _TimedCue secondary;

  const _CuePair(this.primary, this.secondary);

  int get overlapMs => math.max(
    0,
    math.min(primary.endMs, secondary.endMs) -
        math.max(primary.startMs, secondary.startMs),
  );
  int get boundaryDistance =>
      (primary.startMs - secondary.startMs).abs() +
      (primary.endMs - secondary.endMs).abs();
  int get gapMs => math.max(
    0,
    math.max(primary.startMs, secondary.startMs) -
        math.min(primary.endMs, secondary.endMs),
  );

  bool strongerThan(_CuePair? other) {
    if (other == null) return true;
    if (overlapMs != other.overlapMs) return overlapMs > other.overlapMs;
    return nearerThan(other);
  }

  bool nearerThan(_CuePair? other) {
    if (other == null) return true;
    final distance = boundaryDistance + gapMs * 2;
    final otherDistance = other.boundaryDistance + other.gapMs * 2;
    if (distance != otherDistance) return distance < otherDistance;
    if (primary.index != other.primary.index) {
      return primary.index < other.primary.index;
    }
    return secondary.index < other.secondary.index;
  }
}

void _visitNearbyPairs(
  List<_TimedCue> primary,
  List<_TimedCue> secondary,
  int maxGapMs,
  void Function(_CuePair) visit,
) {
  // Prefix ends retain long/overlapping cues even after shorter cues expire.
  final prefixEnds = <int>[];
  var latestEnd = secondary.first.endMs;
  for (final cue in secondary) {
    latestEnd = math.max(latestEnd, cue.endMs);
    prefixEnds.add(latestEnd);
  }
  for (final cue in primary) {
    var low = 0;
    var high = secondary.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (prefixEnds[mid] < cue.startMs - maxGapMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (var index = low; index < secondary.length; index++) {
      final candidate = secondary[index];
      if (candidate.startMs > cue.endMs + maxGapMs) break;
      if (candidate.endMs < cue.startMs - maxGapMs) continue;
      visit(_CuePair(cue, candidate));
    }
  }
}

int subtitleEffectiveEndTimeMs(List<SubtitleItem> subtitles, int index) {
  return _effectiveEndTimeMs(subtitles, index);
}

int _effectiveEndTimeMs(List<SubtitleItem> subtitles, int index) {
  final SubtitleItem item = subtitles[index];
  final int actualEndMs = item.endTime.inMilliseconds;
  if (index + 1 >= subtitles.length) {
    return actualEndMs;
  }
  final int nextStartMs = subtitles[index + 1].startTime.inMilliseconds;
  return nextStartMs < actualEndMs ? actualEndMs : nextStartMs;
}
