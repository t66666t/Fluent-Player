import 'package:characters/characters.dart';

import '../../models/subtitle_asr_info.dart';
import '../../models/subtitle_model.dart';

final _boundaryPunctuation = RegExp(
  r'''[\s，。！？、,.!?;；:："“”'‘’（）()\[\]【】\-—…]''',
);
final _cjk = RegExp(r'[\u2e80-\u9fff\uac00-\ud7af]');
final _latinWord = RegExp(r'[a-zA-Z0-9]');
final _sentenceEnding = RegExp(r'[\s。，,.!?！？;；:：]');

class _BoundaryText {
  _BoundaryText(String text) {
    var at = 0;
    for (final char in text.characters) {
      final start = at;
      at += char.length;
      if (_boundaryPunctuation.hasMatch(char)) continue;
      chars.add(char.toLowerCase());
      starts.add(start);
      ends.add(at);
    }
  }
  final chars = <String>[];
  final starts = <int>[], ends = <int>[];
  String get normalized => chars.join();
}

bool _sameSpeaker(SubtitleItem a, SubtitleItem b) =>
    a.asrInfo.speaker.isEmpty ||
    b.asrInfo.speaker.isEmpty ||
    a.asrInfo.speaker == b.asrInfo.speaker;

SubtitleAsrInfo _reviewInfo(SubtitleAsrInfo a, SubtitleAsrInfo b) =>
    SubtitleAsrInfo(
      language: a.language.isNotEmpty ? a.language : b.language,
      speaker: a.speaker.isNotEmpty ? a.speaker : b.speaker,
      alignmentScore: a.alignmentScore == null
          ? b.alignmentScore
          : b.alignmentScore == null
          ? a.alignmentScore
          : (a.alignmentScore! < b.alignmentScore!
                ? a.alignmentScore
                : b.alignmentScore),
      reviewReason: {
        a.reviewReason,
        b.reviewReason,
      }.where((s) => s.isNotEmpty).join('；'),
      alternateText: {
        a.alternateText,
        b.alternateText,
      }.where((s) => s.isNotEmpty).join('\n'),
      notes: {...a.notes, ...b.notes}.toList(),
      backend: a.backend.isNotEmpty ? a.backend : b.backend,
      weights: a.weights.isNotEmpty ? a.weights : b.weights,
    );

SubtitleItem? _joinBoundary(SubtitleItem a, SubtitleItem b) {
  if (!_sameSpeaker(a, b) ||
      a.endTime <= b.startTime ||
      b.endTime <= a.startTime) {
    return null;
  }
  final left = _BoundaryText(a.text), right = _BoundaryText(b.text);
  final l = left.normalized, r = right.normalized;
  if (l.isEmpty || r.isEmpty) return null;
  final start = a.startTime < b.startTime ? a.startTime : b.startTime;
  final end = a.endTime > b.endTime ? a.endTime : b.endTime;
  final contained =
      l == r ||
      ((left.chars.length >= 4 || left.chars.length >= 2 && _cjk.hasMatch(l)) &&
          r.contains(l)) ||
      ((right.chars.length >= 4 ||
              right.chars.length >= 2 && _cjk.hasMatch(r)) &&
          l.contains(r));
  if (contained) {
    final selected = l.length >= r.length ? a : b;
    return selected.copyWith(
      startTime: start,
      endTime: end,
      asrInfo: _reviewInfo(a.asrInfo, b.asrInfo),
    );
  }
  final limit = left.chars.length < right.chars.length
      ? left.chars.length
      : right.chars.length;
  for (var size = limit > 160 ? 160 : limit; size >= 2; size--) {
    final suffix = left.chars.skip(left.chars.length - size).join();
    if (suffix != right.chars.take(size).join()) continue;
    if (!_cjk.hasMatch(suffix)) {
      if (size < 8) continue;
      final from = left.starts[left.chars.length - size],
          to = right.ends[size - 1];
      if (from > 0 && _latinWord.hasMatch(a.text[from - 1]) ||
          to < b.text.length && _latinWord.hasMatch(b.text[to])) {
        continue;
      }
    }
    final cut = right.ends[size - 1];
    if (cut == b.text.length) continue;
    var leftEnd = a.text.length;
    while (leftEnd > 0 && _sentenceEnding.hasMatch(a.text[leftEnd - 1])) {
      leftEnd--;
    }
    final leftText = a.text.substring(0, leftEnd);
    final separator =
        _boundaryPunctuation.hasMatch(b.text[cut]) ||
            _cjk.hasMatch(leftText.substring(leftText.length - 1)) ||
            _cjk.hasMatch(b.text.substring(cut, cut + 1))
        ? ''
        : ' ';
    final offset = leftEnd + separator.length - cut;
    return a.copyWith(
      startTime: start,
      endTime: end,
      text: '$leftText$separator${b.text.substring(cut)}',
      timedSpans: [
        ...a.timedSpans.where((span) => span.textEnd <= leftEnd),
        for (final span in b.timedSpans)
          if (span.textStart >= cut)
            span.shifted(Duration.zero, textOffset: offset),
      ],
      asrInfo: _reviewInfo(a.asrInfo, b.asrInfo),
    );
  }
  return null;
}

/// Only hypotheses from different audio windows are deduplicated. Consecutive
/// repeated words in a single window remain real subtitles, not duplicates.
List<SubtitleItem> stitchLocalAsrBoundary(
  List<SubtitleItem> held,
  List<SubtitleItem> incoming,
) {
  final candidates = [
    for (final cue in held) (cue: cue.trimmed(), previous: true),
  ];
  for (final cue in incoming) {
    var next = cue.trimmed();
    if (next.text.isEmpty || next.endTime <= next.startTime) continue;
    var previous = false;
    for (var i = candidates.length - 1; i >= 0; i--) {
      final candidate = candidates[i];
      if (!candidate.previous) continue;
      final joined = candidate.cue.startTime <= next.startTime
          ? _joinBoundary(candidate.cue, next)
          : _joinBoundary(next, candidate.cue);
      if (joined == null) continue;
      next = joined;
      previous = true;
      candidates.removeAt(i);
    }
    candidates.add((cue: next, previous: previous));
  }
  return normalizeLocalAsrTimeline(candidates.map((c) => c.cue).toList());
}

/// Local recognizers use one speech stream. Slightly different boundary times
/// must not leave two captions active together after enhancement/segmentation.
List<SubtitleItem> normalizeLocalAsrTimeline(List<SubtitleItem> cues) {
  final sorted = [...cues]..sort((a, b) => a.startTime.compareTo(b.startTime));
  final result = <SubtitleItem>[];
  for (final cue in sorted) {
    if (cue.text.isEmpty || cue.endTime <= cue.startTime) continue;
    if (result.isNotEmpty &&
        _sameSpeaker(result.last, cue) &&
        result.last.endTime > cue.startTime) {
      final previous = result.last;
      if (previous.startTime == cue.startTime) {
        // Keep both texts when alignment gives distinct phrases the same start.
        // They occupy one caption rather than two independent overlapping cues.
        final end = previous.endTime > cue.endTime
            ? previous.endTime
            : cue.endTime;
        result[result.length - 1] = previous.copyWith(
          text: '${previous.text}\n${cue.text}',
          endTime: end,
          timedSpans: [
            ...previous.timedSpans,
            ...cue.timedSpans.map(
              (s) => s.shifted(
                Duration.zero,
                textOffset: previous.text.length + 1,
              ),
            ),
          ],
          asrInfo: _reviewInfo(previous.asrInfo, cue.asrInfo),
        );
        continue;
      }
      result[result.length - 1] = previous.copyWith(
        endTime: cue.startTime,
        timedSpans: previous.shiftedSpans(
          Duration.zero,
          previous.startTime,
          cue.startTime,
        ),
      );
    }
    result.add(cue);
  }
  return result;
}
