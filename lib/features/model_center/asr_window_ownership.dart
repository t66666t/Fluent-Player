import '../../models/subtitle_model.dart';
import 'subtitle_segmentation.dart';

typedef RecognizeAsrBoundary =
    Future<List<SubtitleItem>> Function(Duration start, Duration end);

bool _sameVoice(SubtitleItem a, SubtitleItem b) =>
    a.asrInfo.speaker.isEmpty ||
    b.asrInfo.speaker.isEmpty ||
    a.asrInfo.speaker == b.asrInfo.speaker;

const _jitter = Duration(milliseconds: 120);
const _padding = Duration(milliseconds: 200);

/// A window is an alternative observation of the same audio, not new speech.
/// Keep the earlier complete utterance and remove the later observation by
/// acoustic time, even when the two recognitions have completely different text.
/// An incomplete utterance/coarse token is decoded once with both sides of the
/// boundary instead of guessing text offsets or shortening the earlier cue.
Future<List<SubtitleItem>> ownAsrWindow({
  required List<SubtitleItem> held,
  required List<SubtitleItem> incoming,
  required Duration windowStart,
  required Duration windowEnd,
  required Duration? previousWindowEnd,
  required Duration publishedThrough,
  bool previousWindowOpen = false,
  bool overlapSpeech = false,
  RecognizeAsrBoundary? recognizeBoundary,
}) async {
  final left = held.where((c) => c.text.isNotEmpty).toList();
  final right = incoming.where((c) => c.text.isNotEmpty).toList();
  if (previousWindowEnd == null ||
      left.isEmpty ||
      right.isEmpty && !previousWindowOpen) {
    return [...left, ...right];
  }
  final last = left.last;
  final firstRight = right.firstOrNull;
  final touchesCut =
      previousWindowOpen || last.endTime >= previousWindowEnd - _padding;
  var repair =
      (firstRight == null || _sameVoice(last, firstRight)) &&
      (overlapSpeech ||
          touchesCut &&
              (firstRight == null ||
                  firstRight.startTime <
                      previousWindowEnd + const Duration(seconds: 1)));
  final retained = <SubtitleItem>[];
  for (final cue in right) {
    final owner = left
        .where(
          (old) =>
              _sameVoice(old, cue) &&
              old.endTime > cue.startTime - _jitter &&
              old.startTime < cue.endTime,
        )
        .lastOrNull;
    if (owner == null) {
      retained.add(cue);
      continue;
    }
    if (hasUsableAsrTiming(cue) && hasUsableAsrTiming(owner)) {
      final ownedEnd = owner.timedSpans.fold<Duration>(
        Duration.zero,
        (end, span) => span.endTime > end ? span.endTime : end,
      );
      final spans = cue.timedSpans;
      var cut = 0;
      while (cut < spans.length && spans[cut].endTime <= ownedEnd) {
        cut++;
      }
      if (cut == spans.length) continue;
      if (spans[cut].startTime >= ownedEnd) {
        final offset = cut == 0 ? 0 : spans[cut].textStart;
        final start = spans[cut].startTime;
        // Only trim padding when both native word ranges prove it is silence.
        // A real next word inside the previous cue's padding must be retained.
        if (owner.endTime > start) {
          left[left.indexOf(owner)] = owner.copyWith(endTime: start);
        }
        retained.add(
          cue
              .copyWith(
                text: cue.text.substring(offset),
                startTime: start,
                timedSpans: [
                  for (final span
                      in cue
                          .shiftedSpans(Duration.zero, start, cue.endTime)
                          .where((span) => span.textStart >= offset))
                    span.shifted(Duration.zero, textOffset: -offset),
                ],
                asrInfo: cue.asrInfo,
              )
              .trimmed(),
        );
        continue;
      }
    }
    // Never use proportional character timing, spelling/phonetic guesses or
    // the next cue's start to overwrite the previous utterance's actual end.
    repair = true;
    retained.add(cue);
  }
  if (!repair) return [...left, ...retained];

  var from = left.indexWhere(
    (cue) =>
        cue.endTime > windowStart - _padding &&
        (firstRight == null || _sameVoice(cue, firstRight)),
  );
  if (from < 0) from = left.length - 1;
  var through = 0;
  final seam = last.endTime > previousWindowEnd
      ? last.endTime
      : previousWindowEnd;
  while (through < right.length && right[through].startTime < seam + _padding) {
    through++;
  }
  if (through == 0 && right.isNotEmpty) through = 1;
  var start = firstRight == null || left[from].startTime < firstRight.startTime
      ? left[from].startTime
      : firstRight.startTime;
  start -= _padding;
  final lower = from == 0 ? publishedThrough : left[from - 1].endTime;
  if (start < lower) start = lower;
  var end = through == 0
      ? windowEnd
      : right[through - 1].endTime > last.endTime
      ? right[through - 1].endTime
      : last.endTime;
  end += _padding;
  final upper = through < right.length ? right[through].startTime : windowEnd;
  if (end > upper) end = upper;
  // Checkpoints store cue bounds in milliseconds. Use the same audio range on
  // first execution and replay, including after a process restart.
  start = Duration(milliseconds: start.inMilliseconds);
  end = Duration(milliseconds: end.inMilliseconds);
  if (recognizeBoundary == null || end <= start) {
    throw StateError('重叠区需要完整音频重新识别，未发布有冲突的字幕');
  }
  final repaired = await recognizeBoundary(start, end);
  if (repaired.isEmpty) {
    throw StateError('重叠区重新识别未返回字幕，已保留此前进度');
  }
  return [...left.take(from), ...repaired, ...right.skip(through)];
}
