import 'package:flutter/painting.dart';

final _latinLetter = RegExp(r'[A-Za-z\u00c0-\u024f\u1e00-\u1eff]');
final _letter = RegExp(r'\p{L}', unicode: true);

bool isLatinSubtitleText(String text) {
  if (!_latinLetter.hasMatch(text)) return false;
  if (RegExp(
    r'[\u{1f000}-\u{1faff}\u2600-\u27bf]',
    unicode: true,
  ).hasMatch(text)) {
    return false;
  }
  return _letter
      .allMatches(text)
      .every((match) => _latinLetter.hasMatch(match.group(0)!));
}

/// Uses a stable font body, rather than the current cue's ink bounds. Upper
/// case, x-height text and descenders therefore retain one alphabetic baseline.
/// Mixed-script paragraphs keep their common baseline without per-word shifts.
double subtitleLatinOpticalShift(
  InlineSpan text,
  TextPainter painter, {
  required double? Function(String family, int weight) bodyCenter,
}) {
  final plain = text.toPlainText(includeSemanticsLabels: false);
  if (!isLatinSubtitleText(plain)) return 0;
  if (RegExp(r'^[ \t]*[\r\n]').hasMatch(plain)) return 0;
  var weightedCenter = 0.0, totalLetters = 0, maxFontSize = 0.0;
  var unknown = false;
  void visit(InlineSpan span, TextStyle inherited) {
    if (span is! TextSpan) {
      unknown = true;
      return;
    }
    final style = inherited.merge(span.style);
    final letters = _latinLetter.allMatches(span.text ?? '').length;
    if (letters > 0) {
      var weight = style.fontWeight?.value ?? 400;
      for (final variation in style.fontVariations ?? const <FontVariation>[]) {
        if (variation.axis == 'wght') weight = variation.value.round();
      }
      final center = bodyCenter(style.fontFamily ?? 'System', weight);
      final size = style.fontSize ?? 14;
      if (center == null || !center.isFinite) {
        unknown = true;
      } else {
        weightedCenter += center * size * letters;
        totalLetters += letters;
        if (size > maxFontSize) maxFontSize = size;
      }
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, style);
    }
  }

  visit(text, const TextStyle());
  if (unknown || totalLetters == 0) return 0;
  final lines = painter.computeLineMetrics();
  if (lines.isEmpty) return 0;
  final first = lines.first;
  final shift =
      first.height / 2 - first.baseline + weightedCenter / totalLetters;
  return shift.clamp(-maxFontSize * .25, maxFontSize * .25);
}
