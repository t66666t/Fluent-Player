import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';

/// A display-only break in UTF-16 offsets of the original caption. Whitespace
/// at a soft wrap is replaced by a newline; source text and cue timing stay put.
class SubtitleLineBreak {
  final int start;
  final int end;

  const SubtitleLineBreak(this.start, this.end);
}

class SubtitleTextLayout {
  final InlineSpan text;
  final List<SubtitleLineBreak> breaks;

  const SubtitleTextLayout(this.text, this.breaks);

  /// Also used by ASS export, before escaping the original track strings.
  String wrapText(String source, {int sourceOffset = 0}) =>
      _replaceBreaks(source, sourceOffset, breaks);
}

/// Wrap each explicit source line independently. This also keeps bilingual
/// tracks independent, even when their differently styled spans share a block.
/// Unicode word/grapheme boundaries come from the engine and `characters`;
/// punctuation and modest phrase preferences rank those boundaries. This is
/// deliberately not a language model or a promise of grammatical segmentation.
SubtitleTextLayout layoutSubtitleText(
  InlineSpan text, {
  required double maxWidth,
  TextDirection textDirection = TextDirection.ltr,
  Locale? locale,
}) {
  final plain = text.toPlainText(includeSemanticsLabels: false);
  if (!maxWidth.isFinite ||
      maxWidth <= 0 ||
      plain.isEmpty ||
      !_textOnly(text)) {
    return SubtitleTextLayout(text, const []);
  }
  final painter = TextPainter(
    text: text,
    textAlign: TextAlign.center,
    textDirection: textDirection,
    locale: locale,
  );
  TextPainter? unwrapped;
  try {
    painter.layout(maxWidth: maxWidth);
    final paragraphs = _paragraphs(plain);
    final native = <SubtitleLineBreak>[];
    final chosen = <SubtitleLineBreak>[];
    for (final paragraph in paragraphs) {
      final fallback = _nativeBreaks(painter, plain, paragraph);
      native.addAll(fallback);
      // A source line that already fits must never acquire a soft wrap.
      if (fallback.isEmpty) continue;
      if (paragraph.end - paragraph.start > 1024) {
        chosen.addAll(fallback);
        continue;
      }
      unwrapped ??= TextPainter(
        text: text,
        textDirection: textDirection,
        locale: locale,
      )..layout();
      chosen.addAll(
        _chooseBreaks(unwrapped, plain, paragraph, maxWidth, fallback),
      );
    }
    if (chosen.isEmpty) return SubtitleTextLayout(text, const []);
    var wrapped = _wrapSpan(text, chosen);
    painter.text = wrapped;
    painter.layout(maxWidth: maxWidth);
    // Shaping and bidi can change advances at a new line. Validate the chosen
    // cuts with the real engine and retain its safe wraps on a discrepancy.
    final wrappedPlain = wrapped.toPlainText(includeSemanticsLabels: false);
    if (_paragraphs(
      wrappedPlain,
    ).any((p) => _nativeBreaks(painter, wrappedPlain, p).isNotEmpty)) {
      wrapped = _wrapSpan(text, native);
      return SubtitleTextLayout(wrapped, List.unmodifiable(native));
    }
    return SubtitleTextLayout(wrapped, List.unmodifiable(chosen));
  } finally {
    painter.dispose();
    unwrapped?.dispose();
  }
}

final _hardBreak = RegExp(r'\r\n|[\n\r\u0085\u2028\u2029]');

List<TextRange> _paragraphs(String text) {
  final result = <TextRange>[];
  var start = 0;
  for (final match in _hardBreak.allMatches(text)) {
    result.add(TextRange(start: start, end: match.start));
    start = match.end;
  }
  result.add(TextRange(start: start, end: text.length));
  return result;
}

bool _space(int code) =>
    code == 0x20 ||
    code == 0x09 ||
    code == 0x1680 ||
    (code >= 0x2000 && code <= 0x200a && code != 0x2007) ||
    code == 0x205f ||
    code == 0x3000;

SubtitleLineBreak _at(String text, int offset, TextRange paragraph) {
  var start = offset, end = offset;
  while (start > paragraph.start && _space(text.codeUnitAt(start - 1))) {
    start--;
  }
  while (end < paragraph.end && _space(text.codeUnitAt(end))) {
    end++;
  }
  return SubtitleLineBreak(start, end);
}

List<SubtitleLineBreak> _nativeBreaks(
  TextPainter painter,
  String text,
  TextRange paragraph,
) {
  final breaks = <SubtitleLineBreak>[];
  var offset = paragraph.start;
  while (offset < paragraph.end) {
    final end = painter.getLineBoundary(TextPosition(offset: offset)).end;
    if (end >= paragraph.end) break;
    if (end <= offset) {
      offset++;
      continue;
    }
    final cut = _at(text, end, paragraph);
    if (cut.start > paragraph.start && cut.end < paragraph.end) {
      breaks.add(cut);
    }
    offset = math.max(end, cut.end);
  }
  return breaks;
}

class _Node {
  final SubtitleLineBreak cut;
  final double penalty;
  const _Node(this.cut, this.penalty);
}

final _opening = RegExp(r'[\p{Ps}\p{Pi}]', unicode: true);
final _closing = RegExp(r'[\p{Pe}\p{Pf}]', unicode: true);
final _currency = RegExp(r'\p{Sc}', unicode: true);
final _eastAsian = RegExp(r'[\u2e80-\u9fff\uac00-\ud7af\uff66-\uff9f]');
const _nonStarters =
    ',.!?:;%‰-‐‑、。，．？！：；・،؛؟℃℉'
    '々ヽヾゝゞーぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ'
    'ㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿｧｨｩｪｫｯｬｭｮｰ';
final _noBreak = RegExp('[\u00a0\u2007\u202f\u2060\ufeff]');
final _numberUnit = RegExp(
  r'[0-9０-９]+(?:[.,．:/：-][0-9０-９]+)*'
  r'(?:[ \t\u2009\u202f]*(?:km/h|m/s|kWh|kHz|MHz|GHz|fps|px|kg|mg|km|cm|mm|ms|mL|ml|MB|GB|TB|Hz|'
  r'°[CFＣＦ]?|℃|℉|%|％|‰|公斤|千克|公里|厘米|毫米|小时|小時|分钟|分鐘|'
  r'元|円|岁|歲|年|月|日|天|秒|米|克|시간|개월|초|분|원|년|명|개|g\b|m\b|s\b|h\b|L\b))?',
);

bool _allowed(String text, SubtitleLineBreak cut, List<RegExpMatch> units) {
  final left = text[cut.start - 1], right = text[cut.end];
  if (_opening.hasMatch(left) ||
      _currency.hasMatch(left) ||
      _closing.hasMatch(right) ||
      _nonStarters.contains(right) ||
      _noBreak.hasMatch(text.substring(cut.start - 1, cut.end + 1))) {
    return false;
  }
  bool openingQuote(int at) =>
      at == 0 || text[at - 1].trim().isEmpty || _opening.hasMatch(text[at - 1]);
  if ((left == '"' || left == "'") && openingQuote(cut.start - 1)) {
    return false;
  }
  if ((right == '"' || right == "'") && !openingQuote(cut.end)) {
    return false;
  }
  if ((left == '…' || left == '—') && right == left) return false;
  return !units.any((u) => cut.start > u.start && cut.end < u.end);
}

final _latinWord = RegExp(r"[A-Za-zÀ-ž]+(?:['’][A-Za-zÀ-ž]+)?$");
final _nextLatinWord = RegExp(r'^[A-Za-zÀ-ž]+');
const _attachedWords = {
  'a',
  'an',
  'the',
  'my',
  'your',
  'his',
  'her',
  'our',
  'their',
  'le',
  'la',
  'les',
  'un',
  'une',
  'el',
  'los',
  'las',
};
const _clauseStarts = {
  'and',
  'but',
  'or',
  'because',
  'when',
  'while',
  'if',
  'although',
  'where',
  'which',
  'that',
};

double _penalty(String text, SubtitleLineBreak cut, TextRange paragraph) {
  var left = cut.start - 1;
  while (left > paragraph.start && _closing.hasMatch(text[left])) {
    left--;
  }
  if ('.!?。！？…؟।'.contains(text[left])) return 0;
  if (',，、;；:：،؛'.contains(text[left])) return .08;
  var penalty = cut.end > cut.start ? .5 : .85;
  final before = text.substring(paragraph.start, cut.start);
  final after = text.substring(cut.end, paragraph.end);
  final word = _latinWord.firstMatch(before)?.group(0)?.toLowerCase();
  final next = _nextLatinWord.firstMatch(after)?.group(0)?.toLowerCase();
  if (_attachedWords.contains(word)) penalty += 1.2;
  if (_clauseStarts.contains(next)) penalty -= .25;
  // Soft preferences, not a dictionary: CJK word boundaries in some Flutter
  // runtimes are single ideographs. Punctuation remains the strongest signal.
  if ('的地得'.contains(text[cut.start - 1])) penalty += .5;
  if ('はがをにへとで'.contains(text[cut.end])) penalty += .35;
  return penalty;
}

List<SubtitleLineBreak> _chooseBreaks(
  TextPainter painter,
  String text,
  TextRange paragraph,
  double maxWidth,
  List<SubtitleLineBreak> fallback,
) {
  final graphemes = <int>{paragraph.start};
  var position = paragraph.start;
  for (final glyph
      in text.substring(paragraph.start, paragraph.end).characters) {
    position += glyph.length;
    graphemes.add(position);
  }
  final units = _numberUnit
      .allMatches(text, paragraph.start)
      .takeWhile((u) => u.start < paragraph.end)
      .toList();
  final nodesByOffset = <int, _Node>{
    paragraph.start: _Node(
      SubtitleLineBreak(paragraph.start, paragraph.start),
      0,
    ),
    paragraph.end: _Node(SubtitleLineBreak(paragraph.end, paragraph.end), 0),
  };
  for (var at = paragraph.start; at < paragraph.end;) {
    final end = painter.getWordBoundary(TextPosition(offset: at)).end;
    if (end <= at) break;
    at = end;
    if (end >= paragraph.end || !graphemes.contains(end)) continue;
    final cut = _at(text, end, paragraph);
    if (cut.start <= paragraph.start ||
        cut.end >= paragraph.end ||
        !_allowed(text, cut, units)) {
      continue;
    }
    nodesByOffset[cut.end] = _Node(cut, _penalty(text, cut, paragraph));
  }
  var nodes = nodesByOffset.values.toList()
    ..sort((a, b) => a.cut.end.compareTo(b.cut.end));
  double width(int start, int end) => painter
      .getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end))
      .fold(0.0, (sum, box) => sum + (box.right - box.left).abs());

  // A word longer than the whole available width may use native emergency
  // breaks. Ordinary Korean/Latin words, NBSP groups and units stay intact.
  for (var i = 1; i < nodes.length; i++) {
    final start = nodes[i - 1].cut.end, end = nodes[i].cut.start;
    if (width(start, end) <= maxWidth + .01) continue;
    // UAX #29 groups a whole Katakana word. When that word itself is too
    // wide, use safe character boundaries rather than a native cut before
    // a small kana or prolonged sound mark.
    for (final offset in graphemes) {
      if (offset <= start ||
          offset >= end ||
          !_eastAsian.hasMatch(text.substring(offset - 1, offset + 1))) {
        continue;
      }
      final cut = _at(text, offset, paragraph);
      if (_allowed(text, cut, const [])) {
        nodesByOffset.putIfAbsent(cut.end, () => _Node(cut, 3));
      }
    }
    for (final cut in fallback) {
      if (cut.start > start &&
          cut.end < end &&
          graphemes.contains(cut.start) &&
          graphemes.contains(cut.end) &&
          _allowed(text, cut, const [])) {
        nodesByOffset.putIfAbsent(cut.end, () => _Node(cut, 3));
      }
    }
  }
  nodes = nodesByOffset.values.toList()
    ..sort((a, b) => a.cut.end.compareTo(b.cut.end));
  // Measure each adjacent fragment once. Prefix advances avoid O(n²) native
  // layout/selection calls during the bounded dynamic-programming search.
  final offsets = {
    for (final n in nodes) ...[n.cut.start, n.cut.end],
  }.toList()..sort();
  final advances = <int, double>{offsets.first: 0};
  for (var i = 1; i < offsets.length; i++) {
    advances[offsets[i]] =
        advances[offsets[i - 1]]! + width(offsets[i - 1], offsets[i]);
  }
  double lineWidth(int from, int to) =>
      advances[nodes[to].cut.start]! - advances[nodes[from].cut.end]!;
  final count = List<int>.filled(nodes.length, 100000);
  count[0] = 0;
  for (var to = 1; to < nodes.length; to++) {
    for (var from = to - 1; from >= 0; from--) {
      if (lineWidth(from, to) > maxWidth + .01) break;
      count[to] = math.min(count[to], count[from] + 1);
    }
  }
  final lines = count.last;
  if (lines == 100000) return fallback;
  if (lines > 8) {
    // Long captions still use legal word/punctuation boundaries; skip only
    // the aesthetic optimisation, never the content or the remaining lines.
    final result = <SubtitleLineBreak>[];
    var to = nodes.length - 1;
    while (to > 0) {
      if (to < nodes.length - 1) result.add(nodes[to].cut);
      var from = to - 1;
      while (from >= 0 &&
          (count[from] + 1 != count[to] ||
              lineWidth(from, to) > maxWidth + .01)) {
        from--;
      }
      if (from < 0) return fallback;
      to = from;
    }
    return result.reversed.toList();
  }
  final ideal = advances[offsets.last]! / lines;
  final costs = List.generate(
    lines + 1,
    (_) => List<double>.filled(nodes.length, double.infinity),
  );
  final previous = List.generate(
    lines + 1,
    (_) => List<int>.filled(nodes.length, -1),
  );
  costs[0][0] = 0;
  for (var line = 1; line <= lines; line++) {
    for (var to = line; to < nodes.length; to++) {
      for (var from = to - 1; from >= 0; from--) {
        final w = lineWidth(from, to);
        if (w > maxWidth + .01) break;
        if (!costs[line - 1][from].isFinite || w <= 0) continue;
        final balance = .6 * math.pow((w - ideal) / maxWidth, 2);
        final short = w / maxWidth < .28
            ? 6 * math.pow((.28 - w / maxWidth) / .28, 2)
            : 0;
        final score =
            costs[line - 1][from] + nodes[to].penalty + balance + short;
        if (score < costs[line][to]) {
          costs[line][to] = score;
          previous[line][to] = from;
        }
      }
    }
  }
  if (!costs.last.last.isFinite) return fallback;
  final result = <SubtitleLineBreak>[];
  var to = nodes.length - 1;
  for (var line = lines; line > 0; line--) {
    if (to < nodes.length - 1) result.add(nodes[to].cut);
    to = previous[line][to];
  }
  return result.reversed.toList();
}

bool _textOnly(InlineSpan span) =>
    span is TextSpan && (span.children?.every(_textOnly) ?? true);

String _replaceBreaks(
  String source,
  int offset,
  List<SubtitleLineBreak> breaks,
) {
  final out = StringBuffer();
  var at = 0;
  for (final cut in breaks) {
    if (cut.end < offset) continue;
    if (cut.start > offset + source.length) break;
    final start = (cut.start - offset).clamp(0, source.length);
    final end = (cut.end - offset).clamp(0, source.length);
    if (start > at) out.write(source.substring(at, start));
    // The preceding span owns an insertion at a style-run boundary.
    if (cut.start > offset && cut.start <= offset + source.length) {
      out.write('\n');
    }
    at = math.max(at, end);
  }
  out.write(source.substring(at));
  return out.toString();
}

InlineSpan _wrapSpan(InlineSpan span, List<SubtitleLineBreak> breaks) {
  var offset = 0;
  TextSpan visit(TextSpan node) {
    final source = node.text;
    final updated = source == null
        ? null
        : _replaceBreaks(source, offset, breaks);
    offset += source?.length ?? 0;
    return TextSpan(
      text: updated,
      style: node.style,
      children: node.children?.map((c) => visit(c as TextSpan)).toList(),
      recognizer: node.recognizer,
      mouseCursor: node.mouseCursor,
      onEnter: node.onEnter,
      onExit: node.onExit,
      semanticsLabel: node.semanticsLabel,
      semanticsIdentifier: node.semanticsIdentifier,
      locale: node.locale,
      spellOut: node.spellOut,
    );
  }

  return visit(span as TextSpan);
}
