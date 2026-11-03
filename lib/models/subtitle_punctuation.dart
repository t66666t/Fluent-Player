import 'package:characters/characters.dart';

import 'subtitle_model.dart';

enum SubtitlePunctuation {
  preserve('保留全部标点', '保留识别和翻译结果中的标点。'),
  removeTrailingFullStops('去掉语末句号', '去掉字幕末尾的句号，保留逗号、问号、感叹号和省略号。'),
  removeTrailingFullStopsAndCommas(
    '去掉语末句号和逗号',
    '去掉字幕末尾的句号、逗号及顿号，保留问号、感叹号和省略号。',
  ),
  removeTrailingPunctuation('去掉语末标点', '去掉字幕末尾的标点，保留句中的标点及闭合引号、括号。'),
  removeAll('去掉全部标点', '移除所有位置的标点，包含撇号、连字符和小数点。');

  const SubtitlePunctuation(this.label, this.description);
  final String label, description;
  static const defaultValue = removeTrailingFullStopsAndCommas;

  static SubtitlePunctuation fromStorage(
    Object? value, {
    SubtitlePunctuation fallback = defaultValue,
  }) => values.where((item) => item.name == value).firstOrNull ?? fallback;
}

final _punctuationGlyph = RegExp(r'^\p{P}\p{M}*$', unicode: true);
final _closingGlyph = RegExp(r'^[\p{Pe}\p{Pf}]\p{M}*$', unicode: true);
final _formatGlyph = RegExp(r'^\p{Cf}+$', unicode: true);
final _subtitleMarkup = RegExp(
  r'</?(?:b|i|u|s|font|span|c|v|ruby|rt)(?:\s+[^<>]*|\.[^<>]*)?>|\{\\[^{}]*\}',
  caseSensitive: false,
);

// Full stops and danda/shad equivalents across scripts. Names/terminators:
// https://www.unicode.org/Public/17.0.0/ucd/auxiliary/SentenceBreakProperty.txt
// Question/exclamation marks and ellipses are deliberately excluded.
const _fullStops = {
  0x002e,
  0x0589,
  0x06d4,
  0x0701,
  0x0702,
  0x0964,
  0x0965,
  0x0f0d,
  0x0f0e,
  0x104b,
  0x1362,
  0x166e,
  0x1735,
  0x1736,
  0x17d4,
  0x17d5,
  0x1803,
  0x1809,
  0x1aa8,
  0x1aa9,
  0x1aaa,
  0x1aab,
  0x1b5e,
  0x1b5f,
  0x1c3b,
  0x1c3c,
  0x1c7e,
  0x1c7f,
  0x2024,
  0x2cf9,
  0x2cfe,
  0x2e3c,
  0x3002,
  0xa4ff,
  0xa60e,
  0xa6f3,
  0xa876,
  0xa877,
  0xa8ce,
  0xa8cf,
  0xa9c8,
  0xa9c9,
  0xaa5d,
  0xaa5e,
  0xaa5f,
  0xaaf0,
  0xaaf1,
  0xabeb,
  0xfe12,
  0xfe52,
  0xff0e,
  0xff61,
  0x10a56,
  0x10a57,
  0x11047,
  0x11048,
  0x110bf,
  0x110c0,
  0x110c1,
  0x11141,
  0x11142,
  0x111c5,
  0x111c6,
  0x11238,
  0x11239,
  0x113d4,
  0x113d5,
  0x1144b,
  0x1144c,
  0x115c2,
  0x115c3,
  0x11641,
  0x11642,
  0x11944,
  0x11a42,
  0x11a43,
  0x11a9b,
  0x11a9c,
  0x11c41,
  0x11c42,
  0x11f43,
  0x11f44,
  0x16a6e,
  0x16a6f,
  0x16af5,
  0x16d6e,
  0x16d6f,
  0x16e98,
  0x1bc9f,
  0x1da88,
};

// Unicode 17 punctuation named COMMA, including ideographic/width variants.
// Letter-like comma shapes and decimal/group separators are not comma marks.
// https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt
const _commas = {
  0x002c,
  0x055d,
  0x060c,
  0x07f8,
  0x1363,
  0x1802,
  0x1808,
  0x2e32,
  0x2e34,
  0x2e41,
  0x2e49,
  0x2e4c,
  0x3001,
  0xa4fe,
  0xa60d,
  0xa6f5,
  0xfe10,
  0xfe11,
  0xfe50,
  0xfe51,
  0xff0c,
  0xff64,
  0x1144d,
  0x1145a,
  0x16e97,
  0x1da87,
};

bool _insideMarkup(int offset, List<RegExpMatch> markup) {
  var low = 0, high = markup.length;
  while (low < high) {
    final mid = (low + high) >> 1;
    if (markup[mid].start <= offset) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low > 0 && offset < markup[low - 1].end;
}

bool _asciiLetter(int c) => c >= 65 && c <= 90 || c >= 97 && c <= 122;
bool _asciiWord(int c) => _asciiLetter(c) || c >= 48 && c <= 57 || c == 95;
bool _asciiPunctuation(int c) => switch (c) {
  33 ||
  34 ||
  35 ||
  37 ||
  38 ||
  39 ||
  40 ||
  41 ||
  42 ||
  44 ||
  45 ||
  46 ||
  47 ||
  58 ||
  59 ||
  63 ||
  64 ||
  91 ||
  92 ||
  93 ||
  95 ||
  123 ||
  125 => true,
  _ => false,
};
bool _initialismAt(String text, int end) {
  var count = 0;
  while (end >= 2 &&
      text.codeUnitAt(end - 1) == 46 &&
      _asciiLetter(text.codeUnitAt(end - 2))) {
    if (end > 2 && _asciiWord(text.codeUnitAt(end - 3))) break;
    if (++count == 2) return true;
    end -= 2;
  }
  return false;
}

typedef _Edit = ({String text, List<(int, int)> removed});

_Edit _editPunctuation(String text, SubtitlePunctuation mode) {
  // Plain transcripts do not need markup matching, glyph lists or per-character
  // masks. The common terminal-only modes inspect graphemes from the tail.
  final markup = text.contains('<') || text.contains(r'{\')
      ? _subtitleMarkup.allMatches(text).toList()
      : const <RegExpMatch>[];
  final ranges = <(int, int)>[];
  final removeCommas =
      mode == SubtitlePunctuation.removeTrailingFullStopsAndCommas;
  if (mode == SubtitlePunctuation.removeAll) {
    var offset = 0;
    for (final glyph in text.characters) {
      final start = offset;
      offset += glyph.length;
      final first = glyph.codeUnitAt(0);
      if (first < 128 && !_asciiPunctuation(first) ||
          first >= 0x3400 && first <= 0x9fff ||
          _insideMarkup(start, markup)) {
        continue;
      }
      if (!glyph.contains('\u20e3') &&
          (first < 128 && glyph.length == 1 ||
              _punctuationGlyph.hasMatch(glyph))) {
        ranges.add((start, offset));
      }
    }
  } else {
    final range = text.characters.iteratorAtEnd;
    while (range.moveBack()) {
      final glyph = range.current;
      final start = range.stringBeforeLength, end = start + glyph.length;
      if (_insideMarkup(start, markup) ||
          glyph.trim().isEmpty ||
          _formatGlyph.hasMatch(glyph) ||
          _closingGlyph.hasMatch(glyph) ||
          glyph == '"' ||
          glyph == "'") {
        continue;
      }
      if (mode == SubtitlePunctuation.removeTrailingFullStops || removeCommas) {
        final code = glyph.runes.first;
        if (!_fullStops.contains(code) &&
            !(removeCommas && _commas.contains(code))) {
          break;
        }
        if (glyph == '.') {
          final previous = range.copy();
          if (previous.moveBack() && previous.current == '.' ||
              _initialismAt(text, end)) {
            break;
          }
        }
      } else if (!_punctuationGlyph.hasMatch(glyph)) {
        break;
      }
      ranges.add((start, end));
    }
  }
  if (ranges.isEmpty) return (text: text, removed: const []);
  final ordered = mode == SubtitlePunctuation.removeAll
      ? ranges
      : ranges.reversed;
  final removed = <(int, int)>[];
  for (final range in ordered) {
    if (removed.isNotEmpty && removed.last.$2 == range.$1) {
      removed[removed.length - 1] = (removed.last.$1, range.$2);
    } else {
      removed.add(range);
    }
  }
  final out = StringBuffer();
  var cursor = 0;
  for (final range in removed) {
    out.write(text.substring(cursor, range.$1));
    cursor = range.$2;
  }
  out.write(text.substring(cursor));
  return (text: out.toString(), removed: removed);
}

/// String-only output avoids temporary subtitle/timing objects for translations.
String applySubtitlePunctuationText(String text, SubtitlePunctuation mode) =>
    mode == SubtitlePunctuation.preserve || text.isEmpty
    ? text
    : _editPunctuation(text, mode).text;

/// Recognition/translation retain raw text. Only removed ranges need storage;
/// unchanged word spans are reused, with no full UTF-16 offset table.
SubtitleItem applySubtitlePunctuation(
  SubtitleItem cue,
  SubtitlePunctuation mode,
) {
  if (mode == SubtitlePunctuation.preserve || cue.text.isEmpty) return cue;
  final edit = _editPunctuation(cue.text, mode);
  if (edit.removed.isEmpty) return cue;
  final spans = <SubtitleTimedSpan>[];
  if (cue.timedSpans.isNotEmpty) {
    final removedBefore = <int>[];
    var total = 0;
    for (final range in edit.removed) {
      removedBefore.add(total);
      total += range.$2 - range.$1;
    }
    int mapped(int offset) {
      var low = 0, high = edit.removed.length;
      while (low < high) {
        final mid = (low + high) >> 1;
        if (edit.removed[mid].$1 <= offset) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      if (low == 0) return offset;
      final i = low - 1, range = edit.removed[i];
      return offset -
          removedBefore[i] -
          (offset < range.$2 ? offset - range.$1 : range.$2 - range.$1);
    }

    for (final span in cue.timedSpans) {
      final start = mapped(span.textStart), end = mapped(span.textEnd);
      if (end <= start) continue;
      spans.add(
        start == span.textStart && end == span.textEnd
            ? span
            : SubtitleTimedSpan(
                textStart: start,
                textEnd: end,
                startTime: span.startTime,
                endTime: span.endTime,
                role: span.role,
                agentId: span.agentId,
              ),
      );
    }
  }
  return cue.copyWith(text: edit.text, timedSpans: spans, asrInfo: cue.asrInfo);
}
