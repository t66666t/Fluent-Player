import 'dart:convert';

import 'model_adapters.dart';

String localTranslationSinglePrompt({
  required String engine,
  required String source,
  required String targetLanguage,
  required String targetLabel,
  String glossary = '',
  bool hasProtectedText = false,
}) => localTranslationUsesEnglishPrompt(engine, targetLanguage)
    ? 'Translate the following subtitle into ${localTranslationEnglishTarget(targetLanguage, targetLabel)}. '
          'Output the translation only. Preserve HTML tags, placeholders and line breaks.'
          '${glossary.isEmpty ? '' : '\nTerminology and requirements: ${String.fromCharCodes(glossary.runes.take(500))}'}'
          '\n\n$source'
    : '${glossary.isEmpty ? '' : '术语和要求：${String.fromCharCodes(glossary.runes.take(500))}\n'}'
          '将以下文本翻译为$targetLabel，注意只需要输出翻译后的结果，不要额外解释。'
          '${hasProtectedText ? '保留所有字幕标签与占位符。' : ''}\n\n$source';

/// Preserve initial prompts and sampling. A Qwen Korean-to-Chinese repair uses
/// an explicit Chinese instruction after the existing validator rejected output.
String localTranslationSingleRetryPrompt({
  required String initialPrompt,
  required String engine,
  required String source,
  required String targetLanguage,
  required String targetLabel,
  String glossary = '',
}) {
  if (engine != 'qwen3' ||
      !targetLanguage.startsWith('zh') ||
      RegExp(r'[\uac00-\ud7af]').allMatches(source).length < 8) {
    return initialPrompt;
  }
  return '${glossary.isEmpty ? '' : '术语和要求：${String.fromCharCodes(glossary.runes.take(500))}\n'}'
      '将以下韩语字幕翻译为$targetLabel。只输出中文译文，不要重复韩语原文，不要解释。'
      '保留字幕标签、占位符和换行。\n\n$source';
}

/// Compact JSON rows cost fewer output tokens than objects with repeated key
/// names. Each row keeps an explicit ID, including when the cue has newlines.
String localTranslationBatchPrompt({
  required Map<int, String> texts,
  required String target,
  String context = '',
  String glossary = '',
  bool english = false,
}) =>
    (english
        ? 'Translate the subtitle text (second element) in each JSON row into $target. '
              'Return one [id,"translation"] row per input, keeping every numeric ID. '
              'Translate text inside HTML tags, keeping tags, placeholders and line breaks. '
              'Use valid JSON with ASCII quotes. No explanations.'
              '${glossary.isEmpty ? '' : '\nTerminology and requirements: ${String.fromCharCodes(glossary.runes.take(500))}'}'
              '${context.isEmpty ? '' : '\nContext (do not translate): $context'}'
              '\nSubtitles:\n'
        : '将以下 JSON 行中每行的第二项字幕文本翻译成$target。逐行输出 [编号,"译文"]，保留每个原编号。'
              '标签内的文本也需要翻译，保留标签、占位符和换行。只输出 JSON 行，不要解释。'
              '${glossary.isEmpty ? '' : '\n术语和要求：${String.fromCharCodes(glossary.runes.take(500))}'}'
              '${context.isEmpty ? '' : '\n背景（不要翻译）：$context'}'
              '\n字幕：\n') +
    texts.entries.map((e) => jsonEncode([e.key, e.value])).join('\n');

String localTranslationEnglishTarget(String code, String fallback) {
  final normalized = code.toLowerCase().replaceAll('_', '-');
  if (const ['zh-tw', 'zh-hk', 'zh-hant'].contains(normalized)) {
    return 'Traditional Chinese';
  }
  if (normalized.startsWith('zh')) return 'Simplified Chinese';
  return const {
        'en': 'English',
        'fr': 'French',
        'pt': 'Portuguese',
        'es': 'Spanish',
        'ja': 'Japanese',
        'tr': 'Turkish',
        'ru': 'Russian',
        'ar': 'Arabic',
        'ko': 'Korean',
        'th': 'Thai',
        'it': 'Italian',
        'de': 'German',
        'vi': 'Vietnamese',
        'ms': 'Malay',
        'id': 'Indonesian',
        'tl': 'Filipino',
        'hi': 'Hindi',
        'pl': 'Polish',
        'cs': 'Czech',
        'nl': 'Dutch',
        'km': 'Khmer',
        'my': 'Burmese',
        'fa': 'Persian',
        'gu': 'Gujarati',
        'ur': 'Urdu',
        'te': 'Telugu',
        'mr': 'Marathi',
        'he': 'Hebrew',
        'bn': 'Bengali',
        'ta': 'Tamil',
        'uk': 'Ukrainian',
        'bo': 'Tibetan',
        'kk': 'Kazakh',
        'mn': 'Mongolian',
        'ug': 'Uyghur',
        'yue': 'Cantonese',
      }[normalized.split('-').first] ??
      fallback;
}

/// Constrain *syntax and IDs*, never the translation vocabulary. This removes
/// format repair requests and makes complete rows safe to consume while the
/// native decoder is still generating the rest of the batch.
String localTranslationBatchGrammar(Iterable<int> ids) {
  final rows = ids.toList();
  if (rows.isEmpty ||
      rows.any((id) => id < 0) ||
      rows.toSet().length != rows.length) {
    throw ArgumentError.value(rows, 'ids');
  }
  final root = rows
      .map((id) => '${jsonEncode('[$id,')} string "]"')
      .join(' "\\n" ');
  return '''root ::= $root
string ::= "\\"" char* "\\""
char ::= [^"\\\\\\x00-\\x1F] | "\\\\" (["\\\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
''';
}

/// Invalid/duplicated IDs are never assigned by list position. Valid rows may
/// still be retained when another row was omitted or truncated.
Map<int, String> parseLocalTranslationBatch(
  String response,
  Set<int> expected, {
  bool allowMissingClosingQuote = false,
  bool allowMissingClosingBracket = false,
}) {
  final result = <int, String>{};
  final seen = <int>{};
  void row(Object? value) {
    if (value is List && value.length == 2 && value[1] is String) {
      final key = value[0];
      final id = key is int
          ? key
          : key is String
          ? int.tryParse(key)
          : null;
      if (id == null || !expected.contains(id)) return;
      if (!seen.add(id)) {
        result.remove(id);
        return;
      }
      result[id] = value[1] as String;
    }
  }

  void document(Object? value) {
    if (value is List && value.every((v) => v is List)) {
      for (final entry in value) {
        row(entry);
      }
    } else {
      row(value);
    }
  }

  try {
    document(jsonDecode(response));
    return result;
  } on FormatException {
    // The normal response has one JSON record per line. Some models wrap the
    // same ID-bearing records in an array or add a comma after each record.
  }
  for (var line in const LineSplitter().convert(response)) {
    try {
      line = line.trim();
      if (line.endsWith(',')) line = line.substring(0, line.length - 1);
      Object? value;
      try {
        value = jsonDecode(line);
      } on FormatException {
        // A natural EOS may omit only the outer row delimiter after a fully
        // closed JSON string. Decode it normally before accepting its ID and
        // content; escaped/unclosed quotes and truncated responses still fail.
        if (allowMissingClosingBracket && line.endsWith('"')) {
          try {
            document(jsonDecode('$line]'));
            continue;
          } on FormatException {
            // Other malformed frames still use the stricter repair below.
          }
        }
        // Translation models sometimes localize only the JSON punctuation.
        // Repair the outer frame, keeping ID and translated text unchanged.
        final frame = RegExp(
          r'^\[\s*(\d+)\s*[,，]\s*([\s\S]*)\]$',
        ).firstMatch(line);
        if (frame == null) continue;
        final content = frame[2]!.trim();
        if (content.length < 2 || !const ['"', '“', '「'].contains(content[0])) {
          continue;
        }
        final closes = const [
          '"',
          '”',
          '」',
        ].contains(content[content.length - 1]);
        if (!closes && !allowMissingClosingQuote) continue;
        // Only natural EOS responses may repair a missing quote before an
        // explicit row-ending bracket. A token-limited response cannot.
        final end = closes ? content.length - 1 : content.length;
        value = jsonDecode('[${frame[1]},"${content.substring(1, end)}"]');
      }
      document(value);
    } on FormatException {
      // Explanations, fences and unfinished rows are not translations.
    }
  }
  return result;
}

int localTranslationThreadBudget({
  required int requested,
  required int processors,
  required bool mobile,
}) {
  final available = (processors - (processors / 4).ceil()).clamp(
    1,
    mobile ? 6 : 12,
  );
  if (requested > 0) return requested.clamp(1, available);
  // Decoding is often memory-bandwidth-bound. Oversubscribing all logical
  // cores can slow it down and makes playback/the UI compete for CPU time.
  return (processors ~/ 2).clamp(1, mobile ? 4 : 6);
}
