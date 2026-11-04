import 'package:markdown/markdown.dart' as md;

import 'ai_math_syntax.dart';

/// Keeps LaTeX absolute-value/norm bars inside their Markdown table cell.
///
/// GFM splits table rows before inline syntaxes run, so an ordinary TableSyntax
/// treats `\(|x|\)` as three cells and can silently discard later columns.
/// Probe the same inline math syntax first, protect only its complete spans
/// during the upstream row split, and restore cell AST content before the real
/// inline parse. The source and its original TeX escapes remain unchanged.
class AiMathTableSyntax extends md.TableSyntax {
  const AiMathTableSyntax();

  @override
  md.Node? parse(md.BlockParser parser) {
    final start = parser.lines.indexOf(parser.current);
    var end = start;
    while (end < parser.lines.length && !parser.lines[end].isBlankLine) {
      end++;
    }
    final candidates = parser.lines.sublist(start, end);
    var counter = 0;
    String token;
    do {
      token = '\ufdd0AI_MATH_PIPE_${counter++}\ufdd1';
    } while (candidates.any((line) => line.content.contains(token)));

    final originals = <(int, md.Line)>[];
    try {
      for (var index = start; index < end; index++) {
        final original = parser.lines[index];
        final protected = _protectMathPipes(
          original.content,
          token,
          parser.document,
        );
        if (protected == original.content) continue;
        originals.add((index, original));
        parser.lines[index] = md.Line(
          protected,
          tabRemaining: original.tabRemaining,
        );
      }
      final table = super.parse(parser);
      if (originals.isNotEmpty && table != null) {
        _restoreCellContent(table, token);
      }
      return table;
    } finally {
      for (final (index, line) in originals) {
        parser.lines[index] = line;
      }
    }
  }
}

String _protectMathPipes(String source, String token, md.Document document) {
  if (!source.contains('|') ||
      (!source.contains(r'$') &&
          !source.contains(r'\(') &&
          !source.contains(r'\['))) {
    return source;
  }
  final syntax = _MathSpanProbe();
  final probe = md.Document(
    inlineSyntaxes: [syntax],
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  )..linkReferences.addAll(document.linkReferences);
  // Markdown's own code/escape/link parsing prevents interpreting apparent
  // delimiters inside code spans or destinations as mathematical content.
  probe.parseInline(source);
  if (syntax.spans.isEmpty) return source;
  final buffer = StringBuffer();
  var previous = 0;
  for (final (start, end) in syntax.spans) {
    buffer.write(source.substring(previous, start));
    buffer.write(source.substring(start, end).replaceAll('|', token));
    previous = end;
  }
  buffer.write(source.substring(previous));
  return buffer.toString();
}

class _MathSpanProbe extends AiMathInlineSyntax {
  final spans = <(int, int)>[];

  @override
  void onParsedMathSpan(int start, int end, {required bool complete}) {
    // Never let an unclosed streaming span claim the remaining separators.
    if (complete) spans.add((start, end));
  }
}

void _restoreCellContent(md.Node node, String token) {
  if (node is! md.Element || node.children == null) return;
  final children = node.children!;
  for (var i = 0; i < children.length; i++) {
    final child = children[i];
    if (child is md.UnparsedContent) {
      children[i] = md.UnparsedContent(
        child.textContent.replaceAll(token, '|'),
      );
    } else {
      _restoreCellContent(child, token);
    }
  }
}
