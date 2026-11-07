import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../../models/subtitle_model.dart';
import 'asr_enhancement_options.dart';

final _punctuation = RegExp(r'^[\p{P}\s]+$', unicode: true);

String normalizeAsrLanguage(String value) {
  final tag = value
      .replaceAll('<|', '')
      .replaceAll('|>', '')
      .trim()
      .toLowerCase()
      .replaceAll('_', '-');
  return switch (tag) {
    'chinese' ||
    'mandarin' ||
    'zh-cn' ||
    'zh-tw' ||
    'zh-hans' ||
    'zh-hant' => 'zh',
    'english' || 'en-us' || 'en-gb' => 'en',
    'cantonese' => 'yue',
    'japanese' || 'jpn' || 'ja-jp' || '日语' || '日本語' => 'ja',
    'korean' || 'kor' || 'ko-kr' || 'ko-kp' || '韩语' || '한국어' => 'ko',
    'arabic' => 'ar',
    'german' => 'de',
    'french' => 'fr',
    'spanish' => 'es',
    'portuguese' => 'pt',
    'indonesian' => 'id',
    'italian' => 'it',
    'russian' => 'ru',
    'thai' => 'th',
    'vietnamese' => 'vi',
    'turkish' => 'tr',
    'hindi' => 'hi',
    'malay' => 'ms',
    'dutch' => 'nl',
    'swedish' => 'sv',
    'danish' => 'da',
    'finnish' => 'fi',
    'polish' => 'pl',
    'czech' => 'cs',
    'filipino' || 'tagalog' => 'fil',
    'persian' => 'fa',
    'greek' => 'el',
    'hungarian' => 'hu',
    'macedonian' => 'mk',
    'romanian' => 'ro',
    _ =>
      tag.startsWith('ja-')
          ? 'ja'
          : tag.startsWith('ko-')
          ? 'ko'
          : tag,
  };
}

String asrAlignmentLanguage(
  SubtitleItem cue,
  String fallback, {
  int? textProcessingVersion,
}) {
  final selected = normalizeAsrLanguage(fallback);
  final known = normalizeAsrLanguage(
    cue.asrInfo.language.isNotEmpty ? cue.asrInfo.language : fallback,
  );
  if (usesAsrTextProcessing(textProcessingVersion)) {
    if (selected.isNotEmpty && selected != 'auto' && selected != 'und') {
      return selected;
    }
    return known.isNotEmpty && known != 'auto' && known != 'und' ? known : '';
  }
  if (known != 'auto' && known.isNotEmpty) {
    return known == 'zh' || known == 'en' ? known : '';
  }
  if (RegExp(r'[\u3040-\u30ff\uac00-\ud7af]').hasMatch(cue.text)) return '';
  if (RegExp(r'[\u3400-\u9fff]').hasMatch(cue.text)) return 'zh';
  return RegExp(r'[a-zA-Z]').hasMatch(cue.text) ? 'en' : '';
}

String asrAlignmentModelId(
  SubtitleItem cue,
  String language, {
  String recognitionEngine = '',
  int? textProcessingVersion,
  Iterable<String> availableModels = const [],
}) {
  final resolved = asrAlignmentLanguage(
    cue,
    language,
    textProcessingVersion: textProcessingVersion,
  );
  if ((textProcessingVersion ?? 0) >= 2 &&
      recognitionEngine == 'qwen3-asr' &&
      resolved == 'en' &&
      availableModels.contains(AsrEnhancementOptions.alignmentEnglishId)) {
    return AsrEnhancementOptions.alignmentEnglishId;
  }
  if (usesAsrTextProcessing(textProcessingVersion) &&
      (recognitionEngine == 'qwen3-asr' ||
              recognitionEngine == 'cohere-asr' &&
                  resolved != 'zh' &&
                  resolved != 'en'
          ? AsrEnhancementOptions.qwenAlignmentLanguages.contains(resolved)
          : resolved == 'ja' || resolved == 'ko')) {
    return AsrEnhancementOptions.alignmentQwenId;
  }
  return switch (resolved) {
    'zh' => AsrEnhancementOptions.alignmentChineseId,
    'en' => AsrEnhancementOptions.alignmentEnglishId,
    _ => '',
  };
}

/// Audio GGUF weights are mapped on CPU. GPU loading can retain a host and a
/// device copy. Reserve a bounded 25-second compute arena separately instead
/// of charging three copies of mapped FP16 weights as physical memory.
int qwenAudioWorkingSetBytes(int weightBytes, {bool gpu = false}) =>
    weightBytes <= 0 ? 0 : weightBytes * (gpu ? 2 : 1) + 1024 * 1024 * 1024;

int asrAlignmentWorkingSetBytes(
  String id,
  int weightBytes, {
  int? textProcessingVersion,
  String recognitionEngine = '',
  bool gpu = false,
}) =>
    (id == AsrEnhancementOptions.alignmentQwenId
        ? qwenAudioWorkingSetBytes(weightBytes, gpu: gpu)
        : weightBytes * 3) +
    ((textProcessingVersion ?? 0) >= 2 &&
            recognitionEngine == 'qwen3-asr' &&
            id == AsrEnhancementOptions.alignmentEnglishId
        ? 128 * 1024 * 1024
        : 0);

/// Reserve frozen, prepared candidates before audio language ID has run.
/// Only one alignment model is kept resident when a batch changes language.
List<String> asrAlignmentModelCandidates(
  SubtitleItem cue,
  String language, {
  required Iterable<String> availableModels,
  String recognitionEngine = '',
  int? textProcessingVersion,
  bool languagesResolved = false,
}) {
  final id = asrAlignmentModelId(
    cue,
    language,
    recognitionEngine: recognitionEngine,
    textProcessingVersion: textProcessingVersion,
    availableModels: availableModels,
  );
  if (id.isNotEmpty) return [id];
  if (!languagesResolved &&
      usesAsrTextProcessing(textProcessingVersion) &&
      asrAlignmentLanguage(
        cue,
        language,
        textProcessingVersion: textProcessingVersion,
      ).isEmpty) {
    return availableModels
        .where(AsrEnhancementOptions.isAlignmentModel)
        .toList();
  }
  return const [];
}

bool canRestoreAsrPunctuation(
  SubtitleItem cue,
  String selectedLanguage,
  String engine, {
  int? textProcessingVersion,
}) {
  final known = usesAsrTextProcessing(textProcessingVersion)
      ? asrAlignmentLanguage(cue, selectedLanguage, textProcessingVersion: 1)
      : normalizeAsrLanguage(
          cue.asrInfo.language.isNotEmpty
              ? cue.asrInfo.language
              : selectedLanguage,
        );
  if (usesAsrTextProcessing(textProcessingVersion) && known.isEmpty) {
    return false;
  }
  if (known == 'zh' || known == 'en') return true;
  if (known.isNotEmpty && known != 'auto') return false;
  if (RegExp(r'[\u3040-\u30ff\uac00-\ud7af]').hasMatch(cue.text)) return false;
  if (RegExp(r'[\u3400-\u9fff]').hasMatch(cue.text)) return true;
  // Latin spelling does not establish English (e.g. Dolphin's Vietnamese).
  // With no native language ID, require a bilingual engine or accepted CTC.
  return engine == 'zipformer' ||
      engine == 'firered2' ||
      cue.timedSpans.any((s) => s.role == 'aligned');
}

List<SubtitleItem> guardAsrAlignmentBoundaries(
  List<SubtitleItem> original,
  List<SubtitleItem> aligned, {
  required bool review,
}) {
  assert(original.length == aligned.length);
  final conflicts = <int>{};
  for (var i = 1; i < original.length; i++) {
    if (original[i - 1].endTime <= original[i].startTime &&
        aligned[i - 1].endTime > aligned[i].startTime) {
      conflicts.addAll([i - 1, i]);
    }
  }
  return [
    for (var i = 0; i < original.length; i++)
      if (conflicts.contains(i))
        original[i].copyWith(
          asrInfo: aligned[i].asrInfo.copyWith(
            reviewReason: review ? '相邻片段的精校时间冲突，保留原始时间轴' : '',
            notes: [...aligned[i].asrInfo.notes, '精校边界冲突，未采用新的词级时间'],
          ),
        )
      else
        aligned[i],
  ];
}

/// Accept punctuation/whitespace edits only. Restore original lexical glyphs
/// even if a punctuation model also changes capitalization.
SubtitleItem restoreAsrPunctuation(
  SubtitleItem cue,
  String punctuated, {
  String language = '',
}) {
  // The bilingual CT-Transformer exports Chinese punctuation classes even for
  // English. Keep the chosen language's punctuation style.
  if (normalizeAsrLanguage(language) == 'en') {
    const marks = {
      '。': '.',
      '，': ',',
      '？': '?',
      '！': '!',
      '；': ';',
      '：': ':',
      '、': ',',
    };
    for (final entry in marks.entries) {
      punctuated = punctuated.replaceAll(entry.key, entry.value);
    }
    punctuated = punctuated.replaceAllMapped(
      RegExp(r'([,;:!?])(?=[A-Za-z0-9])'),
      (m) => '${m[1]} ',
    );
  }
  final original = <({String glyph, int start})>[];
  var at = 0;
  for (final glyph in cue.text.characters) {
    if (!_punctuation.hasMatch(glyph)) original.add((glyph: glyph, start: at));
    at += glyph.length;
  }
  final output = StringBuffer();
  final mapping = <int, (int, int)>{};
  var index = 0, length = 0;
  for (final glyph in punctuated.characters) {
    if (_punctuation.hasMatch(glyph)) {
      output.write(glyph);
      length += glyph.length;
      continue;
    }
    if (index >= original.length ||
        original[index].glyph.toLowerCase() != glyph.toLowerCase()) {
      return cue;
    }
    final source = original[index++];
    mapping[source.start] = (length, length + source.glyph.length);
    output.write(source.glyph);
    length += source.glyph.length;
  }
  if (index != original.length || index == 0) return cue;
  final text = output.toString();
  final spans = <SubtitleTimedSpan>[];
  for (final span in cue.timedSpans) {
    final positions = mapping.entries
        .where((e) => e.key >= span.textStart && e.key < span.textEnd)
        .toList();
    if (positions.isEmpty) continue;
    spans.add(
      SubtitleTimedSpan(
        textStart: positions.first.value.$1,
        textEnd: positions.last.value.$2,
        startTime: span.startTime,
        endTime: span.endTime,
        role: span.role,
        agentId: span.agentId,
      ),
    );
  }
  return cue
      .copyWith(text: text, timedSpans: spans, asrInfo: cue.asrInfo)
      .trimmed();
}

double asrTextAgreement(String a, String b) {
  String norm(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\p{P}\s]', unicode: true), '');
  final left = norm(a).runes.toList(), right = norm(b).runes.toList();
  if (left.isEmpty || right.isEmpty) return 0;
  var previous = List.generate(right.length + 1, (i) => i);
  for (var i = 0; i < left.length; i++) {
    final row = List<int>.filled(right.length + 1, 0);
    row[0] = i + 1;
    for (var j = 0; j < right.length; j++) {
      row[j + 1] = math.min(
        previous[j + 1] + 1,
        math.min(row[j] + 1, previous[j] + (left[i] == right[j] ? 0 : 1)),
      );
    }
    previous = row;
  }
  return (1 - previous.last / math.max(left.length, right.length)).clamp(0, 1);
}

SubtitleItem trimAsrSilence(SubtitleItem cue, Float32List audio) {
  final from = (cue.startTime.inMicroseconds * 16000 ~/ 1000000).clamp(
    0,
    audio.length,
  );
  final to = (cue.endTime.inMicroseconds * 16000 ~/ 1000000).clamp(
    from,
    audio.length,
  );
  if (to - from < 12800) return cue;
  final energies = <double>[];
  for (var at = from; at < to; at += 320) {
    var sum = 0.0;
    final end = math.min(to, at + 320);
    for (var i = at; i < end; i++) {
      sum += audio[i] * audio[i];
    }
    energies.add(math.sqrt(sum / math.max(1, end - at)));
  }
  final sorted = [...energies]..sort();
  final peak = sorted.last;
  if (peak < .00005) return cue;
  final threshold = math.min(
    peak * .12,
    math.max(.0003, sorted[sorted.length ~/ 10] * 2),
  );
  final first = energies.indexWhere((v) => v >= threshold);
  final last = energies.lastIndexWhere((v) => v >= threshold);
  if (first < 0 || last < first) return cue;
  var start = Duration(
    microseconds: ((from + math.max(0, first * 320 - 1280)) * 1000000 / 16000)
        .round(),
  );
  var end = Duration(
    microseconds:
        ((from + math.min(to - from, (last + 1) * 320 + 1280)) *
                1000000 /
                16000)
            .round(),
  );
  if (cue.timedSpans.isNotEmpty) {
    // Preserve known onsets, and protect actual CTC word ends. Native ASR's
    // interpolated final token end is not evidence that silence is speech.
    if (start > cue.timedSpans.first.startTime) {
      start = cue.timedSpans.first.startTime;
    }
    for (final span in cue.timedSpans.where((s) => s.role == 'aligned')) {
      if (end < span.endTime) end = span.endTime;
    }
  }
  if (start < cue.startTime) start = cue.startTime;
  if (end > cue.endTime) end = cue.endTime;
  if (end - start < const Duration(milliseconds: 600)) return cue;
  return cue.copyWith(
    startTime: start,
    endTime: end,
    timedSpans: cue.shiftedSpans(Duration.zero, start, end),
  );
}

/// Internal low-energy gaps, not a second model. Segmentation can snap a
/// sentence cut onto a real pause when the recognizer has no word times.
SubtitleItem attachAsrPauseAnchors(SubtitleItem cue, Float32List audio) {
  final from = (cue.startTime.inMicroseconds * 16000 ~/ 1000000).clamp(
    0,
    audio.length,
  );
  final to = (cue.endTime.inMicroseconds * 16000 ~/ 1000000).clamp(
    from,
    audio.length,
  );
  if (to - from < 16000) return cue;
  final energies = <double>[];
  for (var at = from; at < to; at += 320) {
    var sum = 0.0;
    final end = math.min(to, at + 320);
    for (var i = at; i < end; i++) {
      sum += audio[i] * audio[i];
    }
    energies.add(math.sqrt(sum / math.max(1, end - at)));
  }
  if (energies.length < 16) return cue;
  final sorted = [...energies]..sort();
  final peak = sorted.last;
  if (peak < .00005) return cue;
  final threshold = math.min(
    peak * .12,
    math.max(.0003, sorted[sorted.length ~/ 10] * 2),
  );
  final pauses = <List<int>>[];
  var run = 0;
  for (var i = 0; i < energies.length; i++) {
    final edge = i < 10 || i >= energies.length - 10;
    if (!edge && energies[i] < threshold) {
      run++;
      continue;
    }
    if (run >= 6) {
      final startFrame = i - run;
      final startUs = ((from + startFrame * 320) * 1000000 / 16000).round();
      final endUs = ((from + i * 320) * 1000000 / 16000).round();
      if (endUs > startUs) pauses.add([startUs, endUs]);
    }
    run = 0;
  }
  if (pauses.isEmpty) return cue;
  return cue.copyWith(asrInfo: cue.asrInfo.copyWith(pauses: pauses));
}

/// Validate that hotwords have a path through the model vocabulary. The native
/// recognizer must still receive source phrases and its own BPE vocabulary:
/// feeding this diagnostic token sequence back would encode word markers twice.
String encodeAsrHotwords(String input, String tokensFile) {
  final tokens = <String>{};
  for (final line in tokensFile.split('\n')) {
    final match = RegExp(r'^(.*)\s+\d+\s*$').firstMatch(line);
    if (match != null) tokens.add(match[1]!);
  }
  final result = <String>[];
  for (final phrase
      in input
          .split(RegExp(r'[\r\n]+'))
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)) {
    if (phrase.length > 120 || RegExp(r'[:#]').hasMatch(phrase)) {
      throw const FormatException('热词每行最多 120 个字符，不包含 : 或 #');
    }
    List<String>? pieces;
    for (final variant in {
      phrase,
      phrase.toLowerCase(),
      phrase.toUpperCase(),
    }) {
      final value = '▁${variant.replaceAll(RegExp(r'\s+'), '▁')}';
      final found = <String>[];
      var at = 0;
      while (at < value.length) {
        String? chosen;
        for (var end = value.length; end > at; end--) {
          final candidate = value.substring(at, end);
          if (tokens.contains(candidate)) {
            chosen = candidate;
            break;
          }
        }
        if (chosen == null) {
          if (value[at] == '▁' &&
              at + 1 < value.length &&
              RegExp(r'[\u3400-\u9fff]').hasMatch(value[at + 1])) {
            at++;
            continue;
          }
          break;
        }
        found.add(chosen);
        at += chosen.length;
      }
      if (at == value.length) {
        pieces = found;
        break;
      }
    }
    if (pieces == null) throw FormatException('模型词表无法编码热词「$phrase」');
    result.add(pieces.join(' '));
  }
  if (result.length > 100) throw const FormatException('最多配置 100 条热词');
  return result.join('\n');
}
