import '../../models/subtitle_model.dart';
import '../../services/transcription_reliability.dart';
import 'subtitle_segmentation.dart';
import 'local_asr_boundary.dart';
import 'asr_window_ownership.dart';

/// Only the overlap and the last possible continuation remain mutable. All
/// other cues are assigned permanent ordinals before translation/publication.
class StreamingSubtitleAssembler {
  StreamingSubtitleAssembler(this.options, {this.version = 3});
  final SubtitleSegmentationOptions? options;
  final int version;
  List<SubtitleItem> _tail = [];
  int _ordinal = 0;
  Duration? _windowEnd;
  Duration _publishedThrough = Duration.zero;
  bool _windowOpen = false;

  Future<List<SubtitleItem>> add(
    List<SubtitleItem> absolute, {
    required Duration stableBefore,
    bool endOfInput = false,
    Duration? windowStart,
    Duration? windowEnd,
    RecognizeAsrBoundary? recognizeBoundary,
    bool windowOpen = false,
    bool overlapSpeech = false,
    Duration? pendingAudioStart,
  }) async {
    final merged = version >= 3
        ? await ownAsrWindow(
            held: _tail,
            incoming: absolute,
            windowStart: windowStart ?? _windowEnd ?? Duration.zero,
            windowEnd: windowEnd ?? stableBefore + const Duration(seconds: 2),
            previousWindowEnd: _windowEnd,
            publishedThrough: _publishedThrough,
            previousWindowOpen: _windowOpen,
            overlapSpeech: overlapSpeech,
            recognizeBoundary: recognizeBoundary,
          )
        : version >= 2
        ? stitchLocalAsrBoundary(_tail, absolute)
        : TranscriptionSubtitleMerger.finish([..._tail, ...absolute]);
    var split = merged.length;
    if (!endOfInput && merged.isNotEmpty) {
      split = merged.indexWhere(
        (cue) =>
            cue.endTime >= stableBefore - const Duration(milliseconds: 400),
      );
      if (split < 0) split = merged.length;
      if (version >= 3 && pendingAudioStart != null) {
        final pending = merged.indexWhere(
          (cue) => cue.endTime > pendingAudioStart,
        );
        if (pending >= 0 && pending < split) split = pending;
      }
      if (version >= 3 && windowOpen && split == merged.length) {
        // Alignment may shorten a forcibly flushed VAD segment by seconds.
        // It remains unfinished speech even if the enhanced caption appears
        // before the ordinary two-second publication frontier.
        split = merged.length - 1;
      }
      // Keep the last natural continuation as a unit, rather than publishing
      // an artificial sentence boundary at an audio-block boundary.
      if (options?.enabled == true && options!.naturalBreaks) {
        final groups = joinAsrContinuations(merged, options!).toList();
        final last = groups.last;
        final boundary = merged.indexWhere(
          (cue) => cue.endTime > last.startTime,
        );
        if (last.endTime + const Duration(milliseconds: 1400) >= stableBefore &&
            boundary >= 0 &&
            boundary < split) {
          split = boundary;
        }
      }
    }
    final stable = merged.take(split).toList();
    _tail = merged.skip(split).toList();
    final segmented = options?.enabled == true
        ? await segmentAsrSubtitlesAsync(stable, options!)
        : stable;
    final output = version == 2
        ? normalizeLocalAsrTimeline(segmented)
        : segmented;
    _windowEnd = windowEnd ?? stableBefore + const Duration(seconds: 2);
    _windowOpen = windowOpen;
    if (output.isNotEmpty) _publishedThrough = output.last.endTime;
    return [for (final cue in output) cue.copyWith(index: ++_ordinal)];
  }
}
