import 'package:markdown/markdown.dart' as md;

const aiInlineMathTag = 'ai-math-inline';
const aiDisplayMathTag = 'ai-math-display';

/// Delimiters are read inside Markdown's parser, never rewritten globally:
/// fenced/inline code, escaped dollars, links and ordinary prices stay intact.
class AiMathInlineSyntax extends md.InlineSyntax {
  AiMathInlineSyntax() : super(r'\$\$|\$|\\[([]');

  /// Reports the exact source span accepted by this syntax. A containing block
  /// parser can preserve math tokens before its own separator processing,
  /// without duplicating the delimiter, escaping, or bounded-scan rules.
  void onParsedMathSpan(int start, int end, {required bool complete}) {}

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final opening = match[0]!;
    final start = match.end;
    final source = parser.source;
    final closing = switch (opening) {
      r'\(' => r'\)',
      r'\[' => r'\]',
      _ => opening,
    };
    final singleDollar = opening == r'$';
    if (singleDollar &&
        (start == source.length || _space(source.codeUnitAt(start)))) {
      parser.addNode(md.Text(opening));
      return true;
    }
    // A short bounded scan avoids regex backtracking on malformed model text.
    var end = source.indexOf(closing, start);
    final limit = (start + 8192).clamp(0, source.length);
    while (end >= 0 && end <= limit) {
      final after = end + closing.length;
      if (singleDollar &&
          !_escaped(source, end) &&
          after < source.length &&
          _digit(source.codeUnitAt(after))) {
        parser.addNode(md.Text(opening));
        return true;
      }
      if (!_escaped(source, end) &&
          (!singleDollar ||
              (end > start &&
                  !_space(source.codeUnitAt(end - 1)) &&
                  (after == source.length ||
                      !_digit(source.codeUnitAt(after)))))) {
        break;
      }
      end = source.indexOf(closing, after);
    }
    if (end > limit ||
        (singleDollar &&
            end >= 0 &&
            source.substring(start, end).contains('\n'))) {
      end = -1;
    }
    if (end < 0) {
      // Explicit TeX delimiters are unambiguous. A dangling dollar is treated
      // as math only when the remaining text looks mathematical, not a price.
      final remaining = source.substring(start);
      if (singleDollar && !_looksLikeFormula(remaining)) {
        parser.addNode(md.Text(opening));
        return true;
      }
      parser.addNode(
        _element(aiInlineMathTag, remaining, complete: false)
          ..attributes['copy-source'] = source.substring(match.start),
      );
      onParsedMathSpan(match.start, source.length, complete: false);
      parser.consume(source.length - match.start);
      return false;
    }
    final body = source.substring(start, end);
    if (singleDollar && _hasDollar(body)) {
      parser.addNode(md.Text(opening));
      return true;
    }
    final node = _element(aiInlineMathTag, body);
    node.attributes['copy-source'] = source.substring(
      match.start,
      end + closing.length,
    );
    node.attributes['display'] = '${opening == r'$$' || opening == r'\['}';
    parser.addNode(node);
    onParsedMathSpan(match.start, end + closing.length, complete: true);
    parser.consume(end + closing.length - match.start);
    return false;
  }
}

class AiMathBlockSyntax extends md.BlockSyntax {
  const AiMathBlockSyntax();
  static final _opening = RegExp(
    r'^ {0,3}(\$\$|\\\[|\\begin\{(?:equation\*?|align\*?|aligned|gather\*?|gathered|pmatrix|bmatrix|matrix|cases)\})',
  );

  @override
  RegExp get pattern => _opening;

  @override
  bool canParse(md.BlockParser parser) {
    final match = pattern.firstMatch(parser.current.content);
    if (match == null) return false;
    final delimiter = match[1]!;
    final closing = _closing(delimiter);
    final end = parser.current.content.indexOf(closing, match.end);
    // Keep same-line explanatory text in the surrounding Markdown paragraph.
    return end < 0 ||
        parser.current.content.substring(end + closing.length).trim().isEmpty;
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final first = pattern.firstMatch(parser.current.content)!;
    final opening = first[1]!;
    final closing = _closing(opening);
    final environment = opening.startsWith(r'\begin');
    final body = StringBuffer(environment ? opening : '');
    final original = StringBuffer(opening);
    var hasClosing = false;
    var scanned = 0;
    for (var ahead = 0; ahead < 128; ahead++) {
      final candidate = parser.peek(ahead)?.content;
      if (candidate == null || (scanned += candidate.length) > 8192) break;
      if (candidate.indexOf(closing, ahead == 0 ? first.end : 0) >= 0) {
        hasClosing = true;
        break;
      }
    }
    var line = parser.current.content.substring(first.end);
    var complete = false;
    var suffix = '';
    while (!parser.isDone) {
      var end = line.indexOf(closing);
      while (end >= 0 && _escaped(line, end)) {
        end = line.indexOf(closing, end + closing.length);
      }
      if (end >= 0) {
        original.write(line.substring(0, end + closing.length));
        body.write(line.substring(0, end));
        if (environment) body.write(closing);
        suffix = line.substring(end + closing.length).trim();
        parser.advance();
        complete = true;
        break;
      }
      body.writeln(line);
      original.write(line);
      parser.advance();
      if (parser.isDone ||
          body.length > 8192 ||
          (!hasClosing && parser.current.content.trim().isEmpty)) {
        break;
      }
      original.writeln();
      line = parser.current.content;
    }
    final node = _element(
      aiDisplayMathTag,
      body.toString().trim(),
      complete: complete,
    );
    node.attributes['copy-source'] = original.toString();
    if (suffix.isNotEmpty) node.attributes['suffix'] = suffix;
    return node;
  }

  static String _closing(String opening) => switch (opening) {
    r'$$' => r'$$',
    r'\[' => r'\]',
    _ => opening.replaceFirst(r'\begin', r'\end'),
  };
}

md.Element _element(String tag, String source, {bool complete = true}) =>
    md.Element.text(tag, source)..attributes['complete'] = '$complete';

bool _escaped(String source, int index) {
  var slashes = 0;
  for (var i = index - 1; i >= 0 && source.codeUnitAt(i) == 92; i--) {
    slashes++;
  }
  return slashes.isOdd;
}

bool _digit(int char) => char >= 48 && char <= 57;
bool _space(int char) => char == 32 || char == 9 || char == 10 || char == 13;
bool _hasDollar(String source) {
  for (var i = 0; i < source.length; i++) {
    if (source.codeUnitAt(i) == 36 && !_escaped(source, i)) return true;
  }
  return false;
}

bool _looksLikeFormula(String source) {
  if (source.isEmpty || source.length > 4096) return false;
  bool letter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
  if (!letter(source.codeUnitAt(0)) && source.codeUnitAt(0) != 92) return false;
  for (var i = 0; i < source.length; i++) {
    final c = source.codeUnitAt(i);
    if (!letter(c) &&
        !_digit(c) &&
        !'_ ^=+-*/{}().,\\'.contains(String.fromCharCode(c))) {
      return false;
    }
  }
  return true;
}
