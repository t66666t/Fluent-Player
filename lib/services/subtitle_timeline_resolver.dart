import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';

class SubtitleTimelineResolver {
  factory SubtitleTimelineResolver(List<SubtitleItem> subtitles) {
    final List<SubtitleItem> immutableSubtitles =
        subtitles is SubtitleCueSnapshot
        ? subtitles
        : List<SubtitleItem>.unmodifiable(subtitles);
    final List<int> startTimesMs = List<int>.of(
      subtitles.map((item) => item.startTime.inMilliseconds),
    );
    final List<int> endTimesMs = List<int>.unmodifiable(
      subtitles.map((item) => item.endTime.inMilliseconds),
    );
    final List<int> extendedEndTimesMs = List<int>.of(
      _buildGapFilledEndTimes(subtitles),
    );
    return SubtitleTimelineResolver._(
      subtitles: immutableSubtitles,
      startTimesMs: startTimesMs,
      extendedEndTimesMs: extendedEndTimesMs,
      prefixMaxEndTimesMs: _buildPrefixMax(endTimesMs),
      prefixMaxExtendedEndTimesMs: _buildPrefixMax(extendedEndTimesMs),
    );
  }

  SubtitleTimelineResolver._({
    required List<SubtitleItem> subtitles,
    required List<int> startTimesMs,
    required List<int> extendedEndTimesMs,
    required List<int> prefixMaxEndTimesMs,
    required List<int> prefixMaxExtendedEndTimesMs,
  }) : _subtitles = subtitles,
       _startTimesMs = startTimesMs,
       _extendedEndTimesMs = extendedEndTimesMs,
       _prefixMaxEndTimesMs = prefixMaxEndTimesMs,
       _prefixMaxExtendedEndTimesMs = prefixMaxExtendedEndTimesMs {
    for (var i = 0; i < subtitles.length; i++) {
      final cue = subtitles[i];
      if (cue.startTime.inMilliseconds > _tailGroupEnd) {
        _tailGroupStart = i;
        _tailGroupEnd = cue.endTime.inMilliseconds;
      } else if (cue.endTime.inMilliseconds > _tailGroupEnd) {
        _tailGroupEnd = cue.endTime.inMilliseconds;
      }
    }
  }

  List<SubtitleItem> _subtitles;
  int _tailGroupStart = 0, _tailGroupEnd = -1;
  final List<int> _startTimesMs;
  final List<int> _extendedEndTimesMs;
  final List<int> _prefixMaxEndTimesMs;
  final List<int> _prefixMaxExtendedEndTimesMs;

  bool get isEmpty => _subtitles.isEmpty;
  int get length => _subtitles.length;

  /// The caller supplies an immutable snapshot sharing the committed prefix.
  /// Only a previous trailing coverage group can gain gap-filled coverage.
  void append(List<SubtitleItem> next) {
    final oldLength = _subtitles.length;
    _subtitles = next;
    for (var i = oldLength; i < next.length; i++) {
      final start = next[i].startTime.inMilliseconds;
      final end = next[i].endTime.inMilliseconds;
      if (start > _tailGroupEnd) {
        for (var j = _tailGroupStart; j < i; j++) {
          if (next[j].endTime.inMilliseconds == _tailGroupEnd) {
            _extendedEndTimesMs[j] = start;
          }
          final before = j == 0 ? -1 : _prefixMaxExtendedEndTimesMs[j - 1];
          _prefixMaxExtendedEndTimesMs[j] = _extendedEndTimesMs[j] > before
              ? _extendedEndTimesMs[j]
              : before;
        }
        _tailGroupStart = i;
        _tailGroupEnd = end;
      } else if (end > _tailGroupEnd) {
        _tailGroupEnd = end;
      }
      _startTimesMs.add(start);
      _extendedEndTimesMs.add(end);
      _prefixMaxEndTimesMs.add(
        i == 0 || end > _prefixMaxEndTimesMs.last
            ? end
            : _prefixMaxEndTimesMs.last,
      );
      _prefixMaxExtendedEndTimesMs.add(
        i == 0 || end > _prefixMaxExtendedEndTimesMs.last
            ? end
            : _prefixMaxExtendedEndTimesMs.last,
      );
    }
  }

  int firstStartAfterMs(int positionMs) {
    if (_subtitles.isEmpty) return 0;

    int low = 0;
    int high = _startTimesMs.length - 1;
    int answer = _startTimesMs.length;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_startTimesMs[mid] > positionMs) {
        answer = mid;
        high = mid - 1;
      } else {
        low = mid + 1;
      }
    }
    return answer;
  }

  /// Returns every cue active at [positionMs], in source order.
  ///
  /// When [extendToNextStart] is enabled, overlapping cues are treated as one
  /// coverage group. Their original durations remain intact. Every cue that
  /// shares the group's latest original end is extended across the real gap
  /// before the next group, so duplicate same-end cues stay together while a
  /// short nested translation does not linger after a longer narration cue.
  /// Prefix maximum end times let the backwards scan stop as soon as no
  /// earlier cue can still be active.
  List<int> activeIndicesAtMs(
    int positionMs, {
    bool extendToNextStart = false,
  }) {
    if (_subtitles.isEmpty) return const <int>[];

    final int candidate = _lastStartAtOrBeforeMs(positionMs);
    if (candidate < 0) return const <int>[];

    final List<int> prefixMaxEndTimes = extendToNextStart
        ? _prefixMaxExtendedEndTimesMs
        : _prefixMaxEndTimesMs;
    final List<int> activeReversed = <int>[];
    for (int index = candidate; index >= 0; index--) {
      if (prefixMaxEndTimes[index] <= positionMs) break;
      if (_effectiveEndTimeMs(index, extendToNextStart) > positionMs) {
        activeReversed.add(index);
      }
    }
    return activeReversed.reversed.toList(growable: false);
  }

  int indexAtMs(int positionMs, {int? preferredIndex}) {
    if (_subtitles.isEmpty) return -1;

    final int? preferred = _normalizeIndex(preferredIndex);
    if (preferred != null && _containsPosition(preferred, positionMs)) {
      return preferred;
    }
    final int? next = preferred == null ? null : _normalizeIndex(preferred + 1);
    if (next != null && _containsPosition(next, positionMs)) {
      return next;
    }

    int low = 0;
    int high = _startTimesMs.length - 1;
    int answer = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_startTimesMs[mid] <= positionMs) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    if (answer < 0 || !_containsPosition(answer, positionMs)) {
      return -1;
    }
    return answer;
  }

  SubtitleItem? subtitleAt(Duration position, {int? preferredIndex}) {
    final index = indexAtMs(
      position.inMilliseconds,
      preferredIndex: preferredIndex,
    );
    if (index < 0) return null;
    return _subtitles[index];
  }

  Duration? nextBoundaryAfter(Duration position) {
    if (_subtitles.isEmpty) return null;

    final int positionMs = position.inMilliseconds;
    final int firstGreaterIndex = firstStartAfterMs(positionMs);
    if (firstGreaterIndex < _subtitles.length) {
      return _subtitles[firstGreaterIndex].startTime;
    }

    final lastSubtitle = _subtitles.last;
    if (positionMs < lastSubtitle.endTime.inMilliseconds) {
      return lastSubtitle.endTime;
    }
    return null;
  }

  int? _normalizeIndex(int? index) {
    if (index == null || index < 0 || index >= _subtitles.length) {
      return null;
    }
    return index;
  }

  bool _containsPosition(int index, int positionMs) {
    final int startMs = _startTimesMs[index];
    final int endMs = index + 1 < _subtitles.length
        ? _startTimesMs[index + 1]
        : _subtitles[index].endTime.inMilliseconds;
    return positionMs >= startMs && positionMs < endMs;
  }

  int _lastStartAtOrBeforeMs(int positionMs) {
    int low = 0;
    int high = _startTimesMs.length - 1;
    int answer = -1;
    while (low <= high) {
      final int mid = (low + high) >> 1;
      if (_startTimesMs[mid] <= positionMs) {
        answer = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return answer;
  }

  int _effectiveEndTimeMs(int index, bool extendToNextStart) {
    return extendToNextStart
        ? _extendedEndTimesMs[index]
        : _subtitles[index].endTime.inMilliseconds;
  }

  static List<int> _buildPrefixMax(List<int> values) {
    final List<int> result = <int>[];
    int prefixMax = -1;
    for (final int value in values) {
      if (value > prefixMax) prefixMax = value;
      result.add(prefixMax);
    }
    return result;
  }

  /// Extends coverage only across silent gaps, never by shortening overlaps.
  ///
  /// A coverage group is a run of cues whose original intervals union without
  /// a hole. When the next cue starts after that union, every cue whose
  /// original end equals the group's latest end is stretched to that start.
  static List<int> _buildGapFilledEndTimes(List<SubtitleItem> subtitles) {
    final List<int> originalEnds = List<int>.generate(
      subtitles.length,
      (int index) => subtitles[index].endTime.inMilliseconds,
      growable: false,
    );
    final List<int> result = List<int>.from(originalEnds);
    if (subtitles.length < 2) {
      return List<int>.unmodifiable(result);
    }

    int groupStart = 0;
    int groupLastEndMs = originalEnds.first;
    void closeGroup(int groupEndExclusive, int nextStartMs) {
      for (int index = groupStart; index < groupEndExclusive; index++) {
        if (originalEnds[index] == groupLastEndMs) {
          result[index] = nextStartMs;
        }
      }
    }

    for (int index = 1; index < subtitles.length; index++) {
      final int startMs = subtitles[index].startTime.inMilliseconds;
      final int endMs = originalEnds[index];
      if (startMs <= groupLastEndMs) {
        if (endMs > groupLastEndMs) {
          groupLastEndMs = endMs;
        }
        continue;
      }

      closeGroup(index, startMs);
      groupStart = index;
      groupLastEndMs = endMs;
    }
    return List<int>.unmodifiable(result);
  }
}
