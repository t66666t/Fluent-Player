import 'package:characters/characters.dart';

// Frozen pre-optimization implementation, used only for differential tests.
import 'package:video_player_app/models/subtitle_model.dart';

enum SubtitlePunctuation {
  preserve('保留全部标点', '保留识别和翻译结果中的标点。'),
  removeTrailingFullStops('去掉语末句号', '去掉字幕末尾的句号，保留问号、感叹号和省略号。'),
  removeTrailingPunctuation('去掉语末标点', '去掉字幕末尾的标点，保留句中的标点及闭合引号、括号。'),
  removeAll('去掉全部标点', '移除所有位置的标点，包含撇号、连字符和小数点。');

  const SubtitlePunctuation(this.label, this.description);
  final String label, description;
  static const defaultValue = removeTrailingFullStops;

  static SubtitlePunctuation fromStorage(
    Object? value, {
    SubtitlePunctuation fallback = defaultValue,
  }) => values.where((item) => item.name == value).firstOrNull ?? fallback;
}

final _punctuationGlyph = RegExp(r'^\p{P}\p{M}*$', unicode: true);
final _closingGlyph = RegExp(r'^[\p{Pe}\p{Pf}]\p{M}*$', unicode: true);
final _formatGlyph = RegExp(r'^\p{Cf}+$', unicode: true);
final _initialism = RegExp(r'(?:\b[A-Za-z]\.){2,}$');
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

/// Output-only transformation. Recognition, segmentation and translation keep
/// their original text; UTF-16 word ranges are mapped to the saved text once.
SubtitleItem applySubtitlePunctuation(
  SubtitleItem cue,
  SubtitlePunctuation mode,
) {
  if (mode == SubtitlePunctuation.preserve || cue.text.isEmpty) return cue;
  final glyphs = cue.text.characters.toList();
  final remove = List<bool>.filled(glyphs.length, false);
  final markup = _subtitleMarkup.allMatches(cue.text).toList();
  final protected = List<bool>.filled(glyphs.length, false);
  var offset = 0, tag = 0;
  for (var i = 0; i < glyphs.length && tag < markup.length; i++) {
    while (tag < markup.length && offset >= markup[tag].end) {
      tag++;
    }
    protected[i] = tag < markup.length && offset >= markup[tag].start;
    offset += glyphs[i].length;
  }
  if (mode == SubtitlePunctuation.removeAll) {
    for (var i = 0; i < glyphs.length; i++) {
      // A keycap is an emoji grapheme, not a naked # or * punctuation mark.
      remove[i] =
          !protected[i] &&
          !glyphs[i].contains('\u20e3') &&
          _punctuationGlyph.hasMatch(glyphs[i]);
    }
  } else {
    for (var i = glyphs.length - 1; i >= 0; i--) {
      final glyph = glyphs[i];
      if (protected[i] ||
          glyph.trim().isEmpty ||
          _formatGlyph.hasMatch(glyph) ||
          _closingGlyph.hasMatch(glyph) ||
          glyph == '"' ||
          glyph == "'") {
        continue;
      }
      if (mode == SubtitlePunctuation.removeTrailingFullStops) {
        if (!_fullStops.contains(glyph.runes.first)) break;
        // Preserve ASCII ellipses and lexical initialisms such as U.S.
        if (glyph == '.' &&
            (i > 0 && glyphs[i - 1] == '.' ||
                _initialism.hasMatch(glyphs.take(i + 1).join()))) {
          break;
        }
      } else if (!_punctuationGlyph.hasMatch(glyph)) {
        break;
      }
      remove[i] = true;
    }
  }
  if (!remove.contains(true)) return cue;
  final out = StringBuffer();
  final offsets = List<int>.filled(cue.text.length + 1, 0);
  var old = 0, next = 0;
  for (var i = 0; i < glyphs.length; i++) {
    final glyph = glyphs[i];
    for (var unit = 0; unit < glyph.length; unit++) {
      offsets[old + unit] = next + (remove[i] ? 0 : unit);
    }
    old += glyph.length;
    if (!remove[i]) {
      out.write(glyph);
      next += glyph.length;
    }
    offsets[old] = next;
  }
  return cue.copyWith(
    text: out.toString(),
    asrInfo: cue.asrInfo,
    timedSpans: [
      for (final span in cue.timedSpans)
        if (offsets[span.textEnd] > offsets[span.textStart])
          SubtitleTimedSpan(
            textStart: offsets[span.textStart],
            textEnd: offsets[span.textEnd],
            startTime: span.startTime,
            endTime: span.endTime,
            role: span.role,
            agentId: span.agentId,
          ),
    ],
  );
}
