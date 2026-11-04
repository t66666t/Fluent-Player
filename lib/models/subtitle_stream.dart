import 'dart:collection';

import 'subtitle_model.dart';

typedef SubtitleGenerationStart = ({String mediaKey, String runId});

/// Snapshots share append-only pages. Publishing a batch never copies the
/// transcript prefix and an old snapshot can never observe a later append.
class SubtitleCueBuffer {
  static const _pageSize = 128;
  final List<List<SubtitleItem>> _pages = [];
  int _length = 0;
  SubtitleCueSnapshot get snapshot => SubtitleCueSnapshot._(this, _length);
  void addAll(Iterable<SubtitleItem> cues) {
    for (final cue in cues) {
      if (_length % _pageSize == 0) _pages.add([]);
      _pages.last.add(cue);
      _length++;
    }
  }
}

class SubtitleCueSnapshot extends ListBase<SubtitleItem> {
  SubtitleCueSnapshot._(this._buffer, this._length);
  final SubtitleCueBuffer _buffer;
  final int _length;
  Object get sourceIdentity => _buffer;
  @override
  int get length => _length;
  @override
  set length(int value) =>
      throw UnsupportedError('Immutable subtitle snapshot');
  @override
  SubtitleItem operator [](int index) {
    RangeError.checkValidIndex(index, this, null, _length);
    return _buffer._pages[index ~/ SubtitleCueBuffer._pageSize][index %
        SubtitleCueBuffer._pageSize];
  }

  @override
  void operator []=(int index, SubtitleItem value) =>
      throw UnsupportedError('Immutable subtitle snapshot');

  bool extendsSnapshot(List<SubtitleItem> previous) =>
      previous is SubtitleCueSnapshot &&
      identical(_buffer, previous._buffer) &&
      length >= previous.length;
}

bool isSubtitleAppend(List<SubtitleItem> previous, List<SubtitleItem> next) =>
    next is SubtitleCueSnapshot && next.extendsSnapshot(previous);

enum SubtitleStreamPhase { generating, stopping, paused, failed, complete }

class SubtitleStreamUpdate {
  const SubtitleStreamUpdate({
    required this.generationId,
    required this.mediaKey,
    required this.videoPath,
    required this.videoId,
    required this.revision,
    required this.primaryPath,
    required this.secondaryPath,
    required this.primary,
    required this.secondary,
    required this.addedPrimary,
    required this.addedSecondary,
    required this.primaryBytes,
    required this.secondaryBytes,
    required this.processedThrough,
    required this.phase,
    this.message = '',
    this.publishedCount,
    this.autoCache = false,
    this.primaryComplete = false,
    this.autoSelectSuppressed = false,
  });
  final String generationId, mediaKey, videoPath;
  final String? videoId;
  final int revision, primaryBytes, secondaryBytes;
  final String primaryPath;
  final String? secondaryPath;
  final SubtitleCueSnapshot primary, secondary;
  final List<SubtitleItem> addedPrimary, addedSecondary;
  final Duration processedThrough;
  final SubtitleStreamPhase phase;
  final String message;
  final int? publishedCount;
  final bool autoCache;
  final bool primaryComplete, autoSelectSuppressed;
  int get cueCount =>
      publishedCount ?? (primaryComplete ? secondary.length : primary.length);
  bool get complete => phase == SubtitleStreamPhase.complete;
  List<String> get paths => [
    primaryPath,
    if (!primaryComplete || secondaryBytes > 0) ?secondaryPath,
  ];

  SubtitleStreamUpdate compact() => SubtitleStreamUpdate(
    generationId: generationId,
    mediaKey: mediaKey,
    videoPath: videoPath,
    videoId: videoId,
    revision: revision,
    primaryPath: primaryPath,
    secondaryPath: secondaryPath,
    primary: SubtitleCueBuffer().snapshot,
    secondary: SubtitleCueBuffer().snapshot,
    addedPrimary: const [],
    addedSecondary: const [],
    primaryBytes: primaryBytes,
    secondaryBytes: secondaryBytes,
    processedThrough: processedThrough,
    phase: phase,
    message: message,
    publishedCount: cueCount,
    autoCache: autoCache,
    primaryComplete: primaryComplete,
    autoSelectSuppressed: autoSelectSuppressed,
  );
}
