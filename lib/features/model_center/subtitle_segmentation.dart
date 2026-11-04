import 'dart:isolate';
import 'dart:math' as math;

import 'package:characters/characters.dart';

import '../../models/subtitle_model.dart';
import '../../models/subtitle_asr_info.dart';

/// Display grouping is independent of the audio windows used by the recognizer.
/// Width uses approximate display cells: CJK/emoji = 2, Latin = 1.
class SubtitleSegmentationOptions {
  const SubtitleSegmentationOptions({
    this.enabled = true,
    this.maxDurationMs = 4000,
    this.maxWidth = 40,
    this.splitOnPunctuation = true,
    this.allowEstimatedTiming = false,
    this.naturalBreaks = false,
    this.maxLatinWidth,
  });

  static const short = SubtitleSegmentationOptions();
  static const natural = SubtitleSegmentationOptions(
    maxDurationMs: 6000,
    maxWidth: 40,
    maxLatinWidth: 80,
    naturalBreaks: true,
  );
  static const standard = SubtitleSegmentationOptions(
    maxDurationMs: 6000,
    maxWidth: 56,
  );
  static const original = SubtitleSegmentationOptions(enabled: false);

  final bool enabled, splitOnPunctuation, allowEstimatedTiming;
  final bool naturalBreaks;
  final int? maxLatinWidth;
  final int maxDurationMs, maxWidth;

  String get preset => !enabled
      ? 'original'
      : this == natural
      ? 'natural'
      : this == short
      ? 'short'
      : this == standard
      ? 'standard'
      : 'custom';

  String get summary => !enabled
      ? '保留原始语音段'
      : '${naturalBreaks ? '自然分句 · ' : ''}${(maxDurationMs / 1000).toStringAsFixed(maxDurationMs % 1000 == 0 ? 0 : 1)} 秒 · 中文约 ${maxWidth ~/ 2} 字 / 英文约 ${maxLatinWidth ?? maxWidth} 字符';

  SubtitleSegmentationOptions copyWith({
    bool? enabled,
    int? maxDurationMs,
    int? maxWidth,
    bool? splitOnPunctuation,
    bool? allowEstimatedTiming,
    bool? naturalBreaks,
    int? maxLatinWidth,
  }) => SubtitleSegmentationOptions(
    enabled: enabled ?? this.enabled,
    maxDurationMs: maxDurationMs ?? this.maxDurationMs,
    maxWidth: maxWidth ?? this.maxWidth,
    splitOnPunctuation: splitOnPunctuation ?? this.splitOnPunctuation,
    allowEstimatedTiming: allowEstimatedTiming ?? this.allowEstimatedTiming,
    naturalBreaks: naturalBreaks ?? this.naturalBreaks,
    maxLatinWidth: maxLatinWidth ?? this.maxLatinWidth,
  );

  Map<String, Object> toJson() => {
    'version': 2,
    'enabled': enabled,
    'maxDurationMs': maxDurationMs,
    'maxWidth': maxWidth,
    'splitOnPunctuation': splitOnPunctuation,
    'allowEstimatedTiming': allowEstimatedTiming,
    'naturalBreaks': naturalBreaks,
    'maxLatinWidth': ?maxLatinWidth,
  };

  factory SubtitleSegmentationOptions.fromJson(
    Object? value, {
    bool migrateDefaults = false,
  }) {
    if (value is! Map) return natural;
    // Upgrade only the old recommended defaults, keeping custom/disabled and
    // explicitly saved v2 short presets intact. Frozen jobs do not opt in.
    if (migrateDefaults &&
        (value['version'] as num? ?? 1) < 2 &&
        value['enabled'] != false &&
        value['maxDurationMs'] == 4000 &&
        value['maxWidth'] == 40 &&
        value['splitOnPunctuation'] != false &&
        value['allowEstimatedTiming'] != true) {
      return natural;
    }
    return SubtitleSegmentationOptions(
      enabled: value['enabled'] != false,
      maxDurationMs: ((value['maxDurationMs'] as num?)?.toInt() ?? 4000).clamp(
        2000,
        12000,
      ),
      maxWidth: ((value['maxWidth'] as num?)?.toInt() ?? 40).clamp(16, 160),
      splitOnPunctuation: value['splitOnPunctuation'] != false,
      allowEstimatedTiming: value['allowEstimatedTiming'] == true,
      naturalBreaks: value['naturalBreaks'] == true,
      maxLatinWidth: (value['maxLatinWidth'] as num?)?.toInt().clamp(16, 160),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleSegmentationOptions &&
      other.enabled == enabled &&
      other.maxDurationMs == maxDurationMs &&
      other.maxWidth == maxWidth &&
      other.splitOnPunctuation == splitOnPunctuation &&
      other.naturalBreaks == naturalBreaks &&
      other.maxLatinWidth == maxLatinWidth &&
      other.allowEstimatedTiming == allowEstimatedTiming;

  @override
  int get hashCode => Object.hash(
    enabled,
    maxDurationMs,
    maxWidth,
    splitOnPunctuation,
    allowEstimatedTiming,
    naturalBreaks,
    maxLatinWidth,
  );
}

// Keep the isolate closure in its own scope, away from the runner's native
// worker, cancellation callbacks and services, which must not be transferred.
Future<List<SubtitleItem>> segmentAsrSubtitlesAsync(
  List<SubtitleItem> cues,
  SubtitleSegmentationOptions options,
) => Isolate.run(() => segmentAsrSubtitles(cues, options));

/// Regroup existing text without rewriting words or fabricating word timings.
/// Limits are targets: a complete word or an atomic native token may exceed
/// them. Without usable token alignment we leave a cue intact unless the user
/// explicitly opts into estimated sentence times.
List<SubtitleItem> segmentAsrSubtitles(
  List<SubtitleItem> cues,
  SubtitleSegmentationOptions options,
) {
  if (!options.enabled) return cues;
  final result = <SubtitleItem>[];
  for (final cue
      in options.naturalBreaks ? joinAsrContinuations(cues, options) : cues) {
    result.addAll(_splitCue(cue, options));
  }
  return [
    for (var i = 0; i < result.length; i++) result[i].copyWith(index: i + 1),
  ];
}

class _Boundary {
  const _Boundary(this.offset, this.width, this.end, this.nextStart, this.rank);
  final int offset, width, rank;
  final Duration end, nextStart;
}

bool _plainCue(SubtitleItem cue) =>
    cue.endTime > cue.startTime &&
    cue.text.trim().isNotEmpty &&
    !cue.isStructuredLyric &&
    cue.imageLoader == null &&
    !RegExp(r'<[^>]+>|\{\\[^}]*\}').hasMatch(cue.text);

bool _cueAligned(SubtitleItem cue) {
  final glyphs = cue.text.characters.toList();
  var at = 0;
  final boundaries = <int>{0};
  for (final glyph in glyphs) {
    at += glyph.length;
    boundaries.add(at);
  }
  return cue.timedSpans.isNotEmpty && _fullyAligned(cue, boundaries, glyphs);
}

/// Full native coverage with usable word/subword granularity. A single coarse
/// sentence token or a multi-word atomic token still benefits from alignment.
bool hasUsableAsrTiming(SubtitleItem cue) =>
    _plainCue(cue) &&
    _cueAligned(cue) &&
    cue.timedSpans.length >= 2 &&
    cue.timedSpans.every(
      (s) =>
          s.endTime - s.startTime <= const Duration(milliseconds: 2500) &&
          !RegExp(
            r'\p{L}\s+\p{L}',
            unicode: true,
          ).hasMatch(cue.text.substring(s.textStart, s.textEnd)) &&
          RegExp(
                r'[\u3400-\u9fff]',
              ).allMatches(cue.text.substring(s.textStart, s.textEnd)).length <=
              4,
    );

int _displayWidth(String text) =>
    text.characters.fold(0, (n, g) => n + _width(g));
int _targetWidth(String text, SubtitleSegmentationOptions options) =>
    text.runes.any(_isCjk)
    ? options.maxWidth
    : options.maxLatinWidth ?? options.maxWidth;

// VAD boundaries are audio windows, not grammatical sentence boundaries. Join
// close continuations before choosing captions; never invent word timestamps.
/// Also used before punctuation, so an unfinished VAD fragment is not supplied
/// to the punctuation model as if it were a complete sentence.
Iterable<SubtitleItem> joinAsrContinuations(
  List<SubtitleItem> cues,
  SubtitleSegmentationOptions options,
) sync* {
  SubtitleItem? current;
  var aligned = false;
  for (final raw in cues) {
    final cue = raw.trimmed();
    final nextAligned = _plainCue(cue) && _cueAligned(cue);
    if (current == null) {
      current = cue;
      aligned = nextAligned;
      continue;
    }
    final gap = cue.startTime - current.endTime;
    final tiny =
        RegExp(
              r"[\p{L}\p{N}]+(?:['’][\p{L}]+)?",
              unicode: true,
            ).allMatches(current.text).length <=
            3 &&
        current.endTime - current.startTime <
            const Duration(milliseconds: 1800);
    final endRank = _punctuationRank(
      current.text.characters.toList(),
      current.text.characters.length,
    );
    final separator = _joinSeparator(current.text, cue.text);
    final joinedText = '${current.text}$separator${cue.text}';
    final compatible =
        _plainCue(current) &&
        _plainCue(cue) &&
        (current.asrInfo.speaker.isEmpty ||
            cue.asrInfo.speaker.isEmpty ||
            current.asrInfo.speaker == cue.asrInfo.speaker) &&
        (current.asrInfo.language.isEmpty ||
            cue.asrInfo.language.isEmpty ||
            current.asrInfo.language == cue.asrInfo.language);
    final bounded = aligned && nextAligned
        ? cue.endTime - current.startTime <=
                  Duration(
                    milliseconds: math.max(24000, options.maxDurationMs * 3),
                  ) &&
              _displayWidth(joinedText) <= _targetWidth(joinedText, options) * 4
        : cue.endTime - current.startTime <=
                  Duration(milliseconds: options.maxDurationMs) &&
              _displayWidth(joinedText) <= _targetWidth(joinedText, options);
    if (!compatible ||
        gap < Duration.zero ||
        gap > Duration(milliseconds: tiny ? 1400 : 900) ||
        endRank == 2 && !tiny ||
        !bounded) {
      yield current;
      current = cue;
      aligned = nextAligned;
      continue;
    }
    final left = current.asrInfo, right = cue.asrInfo;
    current = current.copyWith(
      text: joinedText,
      endTime: cue.endTime,
      timedSpans: [
        ...current.timedSpans,
        ...cue.timedSpans.map(
          (s) => s.shifted(
            Duration.zero,
            textOffset: current!.text.length + separator.length,
          ),
        ),
      ],
      asrInfo: SubtitleAsrInfo(
        wordBoundaries:
            left.wordBoundaries.isNotEmpty && right.wordBoundaries.isNotEmpty
            ? [
                ...left.wordBoundaries,
                for (final at in right.wordBoundaries)
                  current.text.length + separator.length + at,
              ]
            : const [],
        backend: {left.backend, right.backend}
            .expand((v) => v.split(' + '))
            .where((v) => v.isNotEmpty)
            .toSet()
            .join(' + '),
        weights: {left.weights, right.weights}
            .expand((v) => v.split(' + '))
            .where((v) => v.isNotEmpty)
            .toSet()
            .join(' + '),
        language: left.language.isNotEmpty ? left.language : right.language,
        speaker: left.speaker.isNotEmpty ? left.speaker : right.speaker,
        alignmentScore: left.alignmentScore == null
            ? right.alignmentScore
            : right.alignmentScore == null
            ? left.alignmentScore
            : math.min(left.alignmentScore!, right.alignmentScore!),
        reviewReason: {
          left.reviewReason,
          right.reviewReason,
        }.where((v) => v.isNotEmpty).join('；'),
        alternateText: [
          left.alternateText,
          right.alternateText,
        ].where((v) => v.isNotEmpty).join(' '),
        notes: {...left.notes, ...right.notes}.toList(),
      ),
    );
    aligned = aligned && nextAligned;
  }
  if (current != null) yield current;
}

String _joinSeparator(String left, String right) {
  if (left.isEmpty || right.isEmpty) return '';
  final a = left.characters.last, b = right.characters.first;
  if (_closing.contains(b) ||
      _opening.contains(a) ||
      _isCjk(a.runes.first) && _isCjk(b.runes.first)) {
    return '';
  }
  return ' ';
}

List<int> _naturalCuts(
  List<_Boundary> candidates,
  SubtitleItem cue,
  SubtitleSegmentationOptions options,
) {
  final maxWidth = _targetWidth(cue.text, options);
  final best = List<double>.filled(candidates.length, double.infinity);
  final previous = List<int>.filled(candidates.length, -1);
  final strong = List<int>.filled(candidates.length, 0);
  final wordCounts = List<int>.filled(candidates.length, 0);
  final wordEnds = RegExp(
    r"[\p{L}\p{N}]+(?:['’][\p{L}]+)?",
    unicode: true,
  ).allMatches(cue.text).map((m) => m.end).toList();
  final latinText = !cue.text.runes.any(_isCjk);
  var wordCount = 0;
  final hanging = <bool>[];
  final startsClause = <bool>[];
  const weakEnd = {
    'a',
    'an',
    'the',
    'to',
    'of',
    'for',
    'in',
    'on',
    'at',
    'with',
    'by',
    'from',
    'my',
    'your',
    'his',
    'her',
    'our',
    'their',
    'and',
    'or',
    'but',
    'because',
    'if',
    'that',
    'which',
    'who',
    'when',
    'what',
    'where',
    'why',
    'how',
    'is',
    'are',
    'was',
    'were',
    'be',
    'been',
    'being',
    'have',
    'has',
    'had',
    'can',
    'could',
    'will',
    'would',
    'shall',
    'should',
    'must',
    'may',
    'might',
  };
  const clauses = {
    'but',
    'however',
    'because',
    'although',
    'when',
    'while',
    'if',
    'so',
    'and',
    'yet',
  };
  for (var i = 0; i < candidates.length; i++) {
    final at = candidates[i];
    while (wordCount < wordEnds.length && wordEnds[wordCount] <= at.offset) {
      wordCount++;
    }
    wordCounts[i] = wordCount;
    if (i > 0) strong[i] = strong[i - 1] + (at.rank == 2 ? 1 : 0);
    final left = cue.text.substring(math.max(0, at.offset - 40), at.offset);
    final right = cue.text.substring(
      at.offset,
      math.min(cue.text.length, at.offset + 40),
    );
    final lastWord = RegExp(
      r"([A-Za-z]+(?:['’][A-Za-z]+)?)\s*$",
    ).firstMatch(left)?.group(1)?.toLowerCase();
    final nextWord = RegExp(
      r'^\s*([A-Za-z]+)\b',
    ).firstMatch(right)?.group(1)?.toLowerCase();
    hanging.add(weakEnd.contains(lastWord));
    startsClause.add(clauses.contains(nextWord));
  }
  best[0] = 0;
  for (var end = 1; end < candidates.length; end++) {
    final at = candidates[end];
    for (var begin = end - 1; begin >= 0; begin--) {
      final first = candidates[begin];
      final ms = (at.end - first.nextStart).inMilliseconds;
      final width = at.width - first.width;
      final atomic = end == begin + 1;
      if (ms > options.maxDurationMs * 1.2 || width > maxWidth * 1.2) {
        if (!atomic) break;
      }
      if (!best[begin].isFinite || ms <= 0) continue;
      if (ms < 1000 && begin > 0 && !atomic) continue;
      var cost = 1.0;
      final ratio = math.max(ms / options.maxDurationMs, width / maxWidth);
      if (ratio > 1) cost += (ratio - 1) * (ratio - 1) * 40;
      if (width < maxWidth * .25 && ms < 1800) cost += 6;
      final words = wordCounts[end] - wordCounts[begin];
      if (words <= 2 && ms < 1800 && latinText) cost += 8;
      if (options.splitOnPunctuation) {
        cost += math.max(0, strong[end - 1] - strong[begin]) * 4;
      }
      if (end + 1 < candidates.length) {
        final pause = (at.nextStart - at.end).inMilliseconds;
        if (options.splitOnPunctuation && at.rank == 2) {
          // A complete sentence is preferred unless it creates tiny fragments.
        } else if (options.splitOnPunctuation && at.rank == 1) {
          cost += .7;
        } else if (pause >= 500) {
          cost += .8;
        } else if (startsClause[end]) {
          cost += 1.5;
        } else {
          cost += 4;
        }
        if (hanging[end] && pause < 700) cost += 12;
      }
      if (cost + best[begin] < best[end]) {
        best[end] = cost + best[begin];
        previous[end] = begin;
      }
    }
  }
  final cuts = <int>[];
  var at = candidates.length - 1;
  while (at > 0) {
    cuts.add(at);
    at = previous[at];
    if (at < 0) return [candidates.length - 1];
  }
  return cuts.reversed.toList();
}

Iterable<SubtitleItem> _splitCue(
  SubtitleItem cue,
  SubtitleSegmentationOptions options,
) sync* {
  // ASR emits plain text. Preserve marked-up/lyric inputs instead of producing
  // unbalanced tags or silently changing structured subtitle metadata.
  if (cue.endTime <= cue.startTime ||
      cue.text.isEmpty ||
      cue.isStructuredLyric ||
      RegExp(r'<[^>]+>|\{\\[^}]*\}').hasMatch(cue.text)) {
    yield cue;
    return;
  }
  final glyphs = cue.text.characters.toList();
  final offsets = <int>[0];
  final widths = <int>[0];
  for (final glyph in glyphs) {
    offsets.add(offsets.last + glyph.length);
    widths.add(widths.last + _width(glyph));
  }
  final spans = cue.timedSpans;
  final boundaries = offsets.toSet();
  final aligned = spans.isNotEmpty && _fullyAligned(cue, boundaries, glyphs);
  if (!aligned && !options.allowEstimatedTiming) {
    yield cue;
    return;
  }

  final candidates = <_Boundary>[
    _Boundary(0, 0, cue.startTime, cue.startTime, 0),
  ];
  var spanIndex = 0;
  for (var i = 1; i < glyphs.length; i++) {
    if (!_canBreak(glyphs, i)) continue;
    final offset = offsets[i];
    // Text boundaries only constrain existing acoustic cuts. They never
    // authorize estimated timing or splitting an atomic native token.
    final words = cue.asrInfo.wordBoundaries;
    if (words.isNotEmpty &&
        !words.contains(offset) &&
        _punctuationRank(glyphs, i) == 0 &&
        glyphs[i - 1].trim().isNotEmpty &&
        glyphs[i].trim().isNotEmpty) {
      continue;
    }
    Duration end, start;
    if (aligned) {
      while (spanIndex < spans.length && spans[spanIndex].textEnd <= offset) {
        spanIndex++;
      }
      if (spanIndex == 0 || spanIndex == spans.length) continue;
      final left = spans[spanIndex - 1];
      final right = spans[spanIndex];
      // Never split one native token or a non-monotonic timestamp group.
      if (right.textStart < offset || right.startTime <= left.startTime) {
        continue;
      }
      start = right.startTime;
      end = left.endTime < start ? left.endTime : start;
    } else {
      final fraction = widths[i] / math.max(1, widths.last);
      start = cue.startTime + (cue.endTime - cue.startTime) * fraction;
      end = start;
    }
    if (end <= cue.startTime || start >= cue.endTime) continue;
    candidates.add(
      _Boundary(offset, widths[i], end, start, _punctuationRank(glyphs, i)),
    );
  }
  candidates.add(
    _Boundary(cue.text.length, widths.last, cue.endTime, cue.endTime, 0),
  );

  var from = 0;
  final naturalCuts = options.naturalBreaks
      ? _naturalCuts(candidates, cue, options)
      : null;
  var cutIndex = 0;
  final minimum = const Duration(milliseconds: 800);
  final maxWidth = _targetWidth(cue.text, options);
  while (from < candidates.length - 1) {
    final first = candidates[from];
    var chosen = candidates.length - 1;
    var lastFit = -1;
    var softBreak = -1;
    if (naturalCuts != null) {
      chosen = naturalCuts[cutIndex++];
    } else {
      for (var i = from + 1; i < candidates.length; i++) {
        final at = candidates[i];
        final duration = at.end - first.nextStart;
        final width = at.width - first.width;
        final last = i == candidates.length - 1;
        // Avoid flashing fragments, including a tiny final remainder.
        if (!last &&
            (duration < minimum || cue.endTime - at.nextStart < minimum)) {
          continue;
        }
        final fits =
            duration.inMilliseconds <= options.maxDurationMs &&
            width <= maxWidth;
        if (!fits) {
          chosen = lastFit < 0 ? i : lastFit;
          if (options.splitOnPunctuation &&
              softBreak > from &&
              (candidates[softBreak].width - first.width >= maxWidth * .45 ||
                  (candidates[softBreak].end - first.nextStart)
                          .inMilliseconds >=
                      options.maxDurationMs * .45)) {
            chosen = softBreak;
          }
          break;
        }
        if (options.splitOnPunctuation && at.rank == 2 && !last) {
          chosen = i;
          break;
        }
        lastFit = i;
        if (at.rank > 0) softBreak = i;
      }
    }
    final next = candidates[chosen];
    final rawText = cue.text.substring(first.offset, next.offset);
    final text = rawText.trim();
    final leading = rawText.length - rawText.trimLeft().length;
    final textOffset = first.offset + leading;
    if (text.isNotEmpty && next.end > first.nextStart) {
      final keptSpans = <SubtitleTimedSpan>[];
      if (aligned) {
        for (final span in spans) {
          if (span.textStart < textOffset ||
              span.textEnd > textOffset + text.length) {
            continue;
          }
          final start = span.startTime < first.nextStart
              ? first.nextStart
              : span.startTime;
          final end = span.endTime > next.end ? next.end : span.endTime;
          if (end <= start) continue;
          keptSpans.add(
            SubtitleTimedSpan(
              textStart: span.textStart - textOffset,
              textEnd: span.textEnd - textOffset,
              startTime: start,
              endTime: end,
              role: span.role,
              agentId: span.agentId,
            ),
          );
        }
      }
      yield cue.copyWith(
        text: text,
        startTime: first.nextStart,
        endTime: next.end,
        timedSpans: keptSpans,
        asrInfo: cue.asrInfo.wordBoundaries.isEmpty
            ? cue.asrInfo
            : cue.asrInfo.copyWith(
                wordBoundaries: [
                  for (final at in cue.asrInfo.wordBoundaries)
                    if (at >= textOffset && at <= textOffset + text.length)
                      at - textOffset,
                ],
              ),
      );
    }
    from = chosen;
  }
}

bool _fullyAligned(SubtitleItem cue, Set<int> boundaries, List<String> glyphs) {
  var lastTextEnd = 0;
  var lastStart = cue.startTime;
  for (final span in cue.timedSpans) {
    if (!span.isValidFor(cue.text) ||
        span.textStart < lastTextEnd ||
        !boundaries.contains(span.textStart) ||
        !boundaries.contains(span.textEnd) ||
        span.startTime < lastStart ||
        span.startTime < cue.startTime ||
        span.endTime > cue.endTime) {
      return false;
    }
    lastTextEnd = span.textEnd;
    lastStart = span.startTime;
  }
  var offset = 0;
  var at = 0;
  for (final glyph in glyphs) {
    final end = offset + glyph.length;
    while (at < cue.timedSpans.length && cue.timedSpans[at].textEnd <= offset) {
      at++;
    }
    if (glyph.trim().isNotEmpty && !_punctuation.contains(glyph)) {
      if (at == cue.timedSpans.length ||
          cue.timedSpans[at].textStart > offset ||
          cue.timedSpans[at].textEnd < end) {
        return false;
      }
    }
    offset = end;
  }
  return true;
}

const _punctuation = '，。！？；：、,.!?;:…—-「」『』“”‘’"\'（）()[]【】';
const _closing = '，。！？；：、,.!?;:…」』”’"\'）)]】';
const _opening = '「『“‘（([【';

bool _canBreak(List<String> glyphs, int i) {
  final left = glyphs[i - 1], right = glyphs[i];
  if (right.trim().isEmpty) return false;
  if (_closing.contains(right) || _opening.contains(left)) return false;
  if (left.trim().isEmpty || _punctuationRank(glyphs, i) > 0) return true;
  return _isCjk(left.runes.first) || _isCjk(right.runes.first);
}

int _punctuationRank(List<String> glyphs, int i) {
  var end = i;
  while (end > 0 &&
      (glyphs[end - 1].trim().isEmpty ||
          '」』”’"\'）)]】'.contains(glyphs[end - 1]))) {
    end--;
  }
  if (end == 0) return 0;
  final last = glyphs[end - 1];
  if ('。！？!?'.contains(last)) return 2;
  if ('，；：、,;:'.contains(last)) return 1;
  if (last != '.') return 0;
  // Decimal numbers, URLs, initials and common abbreviations are not sentences.
  if (i < glyphs.length && RegExp(r'[0-9a-z]').hasMatch(glyphs[i])) return 0;
  var start = end - 1;
  while (start > 0 && RegExp(r'[A-Za-z.]').hasMatch(glyphs[start - 1])) {
    start--;
  }
  final word = glyphs.sublist(start, end - 1).join().toLowerCase();
  if (word.length == 1 ||
      word.contains('.') ||
      const {
        'mr',
        'mrs',
        'ms',
        'dr',
        'prof',
        'sr',
        'jr',
        'st',
        'vs',
        'etc',
        'no',
        'fig',
      }.contains(word)) {
    return 0;
  }
  return 2;
}

int _width(String glyph) {
  final value = glyph.runes.first;
  return _isCjk(value) || value >= 0xff01 && value <= 0xff60 || value >= 0x1f000
      ? 2
      : 1;
}

bool _isCjk(int rune) =>
    rune >= 0x2e80 && rune <= 0xa4cf ||
    rune >= 0xac00 && rune <= 0xd7af ||
    rune >= 0xf900 && rune <= 0xfaff ||
    rune >= 0x20000 && rune <= 0x323af;
