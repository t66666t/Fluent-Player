import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../../models/subtitle_model.dart';

class CtcAlignment {
  const CtcAlignment({
    this.spans = const [],
    this.score = 0,
    this.hypothesis = '',
    this.reason = '',
  });
  final List<SubtitleTimedSpan> spans;
  final double score;
  final String hypothesis, reason;
  bool get accepted => spans.isNotEmpty && reason.isEmpty;
}

class _Target {
  const _Target(this.id, this.from, this.to);
  final int id, from, to;
}

/// CTC Viterbi forced alignment. The target is the existing transcript; no
/// generated word replaces it. Backpointers are bounded by frames * target size.
CtcAlignment alignCtcLogits({
  required String text,
  required List<List<double>> logits,
  required Map<String, int> vocabulary,
  required Duration offset,
  required Duration audioDuration,
  int blankId = 0,
  bool uppercase = true,
  double minimumScore = .25,
}) {
  if (logits.isEmpty || vocabulary.isEmpty) {
    return const CtcAlignment(reason: '对齐模型没有返回声学数据');
  }
  final targets = <_Target>[];
  final lexical = RegExp(r'[\p{L}\p{N}]', unicode: true);
  final delimiter = vocabulary['|'] ?? vocabulary[' '];
  var at = 0;
  for (final glyph in text.characters) {
    final end = at + glyph.length;
    final value = uppercase ? glyph.toUpperCase() : glyph;
    if (glyph.trim().isEmpty) {
      if (delimiter != null &&
          targets.isNotEmpty &&
          targets.last.id != delimiter) {
        targets.add(_Target(delimiter, at, end));
      }
    } else if (lexical.hasMatch(glyph) || glyph == "'") {
      final id = vocabulary[value] ?? vocabulary[glyph];
      if (id == null || id == blankId) {
        return CtcAlignment(reason: '对齐词表不包含「$glyph」，保留原始时间轴');
      }
      targets.add(_Target(id, at, end));
    }
    at = end;
  }
  while (targets.isNotEmpty && targets.last.id == delimiter) {
    targets.removeLast();
  }
  if (targets.isEmpty || targets.length > 600 || logits.length > 1600) {
    return const CtcAlignment(reason: '对齐输入超出有界窗口');
  }
  final frames = logits.length;
  final states = targets.length * 2 + 1;
  var previous = Float64List(states)
    ..fillRange(0, states, double.negativeInfinity);
  previous[0] = 0;
  final back = Uint8List(frames * states);
  final first = Int32List(targets.length)..fillRange(0, targets.length, -1);
  final last = Int32List(targets.length);
  final probabilities = Float64List(targets.length);
  final counts = Int32List(targets.length);
  final frameNormalizers = Float64List(frames);
  final greedyIds = <int>[];
  var previousGreedy = -1;
  for (var t = 0; t < frames; t++) {
    final row = logits[t];
    if (blankId >= row.length || targets.any((v) => v.id >= row.length)) {
      return const CtcAlignment(reason: '模型词表与声学输出不匹配');
    }
    var maximum = double.negativeInfinity, argmax = 0;
    for (var j = 0; j < row.length; j++) {
      if (row[j] > maximum) {
        maximum = row[j];
        argmax = j;
      }
    }
    if (!maximum.isFinite) return const CtcAlignment(reason: '声学输出包含无效数值');
    var sum = 0.0;
    for (final v in row) {
      sum += math.exp(v - maximum);
    }
    final norm = maximum + math.log(sum);
    frameNormalizers[t] = norm;
    if (argmax != blankId && argmax != previousGreedy) greedyIds.add(argmax);
    previousGreedy = argmax;
    final current = Float64List(states)
      ..fillRange(0, states, double.negativeInfinity);
    for (var s = 0; s < states; s++) {
      var best = previous[s], step = 0;
      if (s > 0 && previous[s - 1] > best) {
        best = previous[s - 1];
        step = 1;
      }
      if (s > 1 &&
          s.isOdd &&
          targets[s ~/ 2].id != targets[s ~/ 2 - 1].id &&
          previous[s - 2] > best) {
        best = previous[s - 2];
        step = 2;
      }
      final id = s.isEven ? blankId : targets[s ~/ 2].id;
      current[s] = best + row[id] - norm;
      back[t * states + s] = step;
    }
    previous = current;
  }
  var state = previous[states - 1] >= previous[states - 2]
      ? states - 1
      : states - 2;
  if (!previous[state].isFinite) {
    return const CtcAlignment(reason: '音频帧数不足以对齐原文');
  }
  for (var t = frames - 1; t >= 0; t--) {
    if (state.isOdd) {
      final index = state ~/ 2;
      first[index] = t;
      if (counts[index] == 0) last[index] = t;
      probabilities[index] += math.exp(
        logits[t][targets[index].id] - frameNormalizers[t],
      );
      counts[index]++;
    }
    state -= back[t * states + state];
  }
  final inverse = <int, String>{
    for (final entry in vocabulary.entries) entry.value: entry.key,
  };
  final hypothesis = greedyIds
      .map((id) => inverse[id] ?? '')
      .join()
      .replaceAll('|', ' ')
      .trim();
  var total = 0.0, count = 0;
  final spans = <SubtitleTimedSpan>[];
  for (var i = 0; i < targets.length; i++) {
    if (first[i] < 0) {
      return CtcAlignment(hypothesis: hypothesis, reason: '原文存在未对齐字符');
    }
    if (targets[i].id == delimiter) continue;
    total += probabilities[i] / math.max(1, counts[i]);
    count++;
    // Wav2vec2's seven feature convolutions have a 320-sample stride and a
    // 400-sample receptive field at 16 kHz. Do not stretch frames over silence.
    final beginUs = math.min(audioDuration.inMicroseconds, first[i] * 20000);
    var endUs = math.min(audioDuration.inMicroseconds, last[i] * 20000 + 25000);
    if (i + 1 < targets.length) endUs = math.min(endUs, first[i + 1] * 20000);
    if (endUs <= beginUs) {
      endUs = math.min(audioDuration.inMicroseconds, beginUs + 1000);
    }
    if (endUs <= beginUs) {
      return CtcAlignment(hypothesis: hypothesis, reason: '对齐边界无效');
    }
    spans.add(
      SubtitleTimedSpan(
        textStart: targets[i].from,
        textEnd: targets[i].to,
        startTime: offset + Duration(microseconds: beginUs),
        endTime: offset + Duration(microseconds: endUs),
        role: 'aligned',
      ),
    );
  }
  final score = total / math.max(1, count);
  return CtcAlignment(
    spans: score >= minimumScore ? spans : const [],
    score: score,
    hypothesis: hypothesis,
    reason: score >= minimumScore ? '' : '声学对齐匹配度不足，保留原始时间轴',
  );
}

Float32List normalizeAlignmentAudio(Float32List samples) {
  if (samples.isEmpty) return Float32List(0);
  var mean = 0.0;
  for (final v in samples) {
    mean += v;
  }
  mean /= samples.length;
  var variance = 0.0;
  for (final v in samples) {
    variance += (v - mean) * (v - mean);
  }
  final scale = math.sqrt(variance / samples.length + 1e-7);
  return Float32List.fromList([for (final v in samples) (v - mean) / scale]);
}
