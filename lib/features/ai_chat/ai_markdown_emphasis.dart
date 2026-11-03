import 'package:markdown/markdown.dart' as md;

/// CJK-friendly delimiter boundaries without rewriting the Markdown source.
///
/// CommonMark treats the curly quotes in `以**“重点”**为` as punctuation,
/// preventing either delimiter from matching. The CJK-friendly proposal allows
/// punctuation next to CJK text while retaining Markdown's delimiter stack,
/// nesting, escaping, and rule of three. Non-CJK runs use the upstream run.
///
/// https://github.com/tats-u/markdown-cjk-friendly/blob/main/specification.md
class AiMarkdownEmphasisSyntax extends md.DelimiterSyntax {
  AiMarkdownEmphasisSyntax() : super(r'\*+|_+', requiresDelimiterRun: true);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final start = parser.pos;
    final end = start + match[0]!.length;
    final node = md.Text(parser.source.substring(start, end));
    final intraWord = parser.source.codeUnitAt(start) == 0x2a;
    final tags = [md.DelimiterTag('em', 1), md.DelimiterTag('strong', 2)];
    final native = md.DelimiterRun.tryParse(
      parser,
      start,
      end,
      syntax: this,
      node: node,
      allowIntraWord: intraWord,
      tags: tags,
    )!;

    final (previous, previousStart) = _previousCodePoint(parser.source, start);
    var previousMain = previous;
    int? variationSelector;
    if (previous >= 0xfe00 && previous <= 0xfe0e) {
      final (base, _) = _previousCodePoint(parser.source, previousStart);
      // A variation selector does not hide its base's boundary class. A
      // selector immediately after Unicode space is unspecified by the draft;
      // keep the upstream behavior in that case.
      if (!_whiteSpace(base)) {
        variationSelector = previous;
        previousMain = base;
      }
    }
    final following = _codePointAt(parser.source, end);
    final previousCjk =
        _isCjk(previousMain) ||
        (previousMain >= 0xe0100 && previousMain <= 0xe01ef) ||
        (variationSelector == 0xfe01 &&
            const {0x2018, 0x2019, 0x201c, 0x201d}.contains(previousMain));
    final adjacentCjk = previousCjk || _isCjk(following);
    if (!adjacentCjk) {
      parser.pushDelimiter(native);
      parser.addNode(node);
      return true;
    }

    final previousWhiteSpace = _whiteSpace(previousMain);
    final followingWhiteSpace = _whiteSpace(following);
    final previousPunctuation = _punctuation(previousMain);
    final followingPunctuation = _punctuation(following);
    final leftFlanking =
        !followingWhiteSpace &&
        (!followingPunctuation ||
            previousWhiteSpace ||
            previousPunctuation ||
            adjacentCjk);
    final rightFlanking =
        !previousWhiteSpace &&
        (!previousPunctuation ||
            followingWhiteSpace ||
            followingPunctuation ||
            adjacentCjk);
    parser.pushDelimiter(
      _CjkDelimiterRun(
        node: node,
        char: native.char,
        syntax: this,
        tags: tags,
        allowIntraWord: intraWord,
        canOpen:
            leftFlanking &&
            (!rightFlanking || intraWord || previousPunctuation),
        canClose:
            rightFlanking &&
            (!leftFlanking || intraWord || followingPunctuation),
      ),
    );
    parser.addNode(node);
    return true;
  }
}

/// Implementing the public interface lets InlineParser own all pairing logic.
/// Its run length must follow the mutable node as nested delimiters are used.
class _CjkDelimiterRun implements md.DelimiterRun {
  _CjkDelimiterRun({
    required this.node,
    required this.char,
    required this.syntax,
    required this.tags,
    required this.allowIntraWord,
    required this.canOpen,
    required this.canClose,
  });

  @override
  md.Text node;
  @override
  final int char;
  @override
  final md.DelimiterSyntax syntax;
  @override
  final List<md.DelimiterTag> tags;
  @override
  final bool allowIntraWord;
  @override
  final bool canOpen;
  @override
  final bool canClose;
  @override
  bool isActive = true;
  @override
  int get length => node.text.length;
}

bool _whiteSpace(int codePoint) =>
    md.DelimiterRun.unicodeWhitespace.contains(String.fromCharCode(codePoint));

bool _punctuation(int codePoint) => md.DelimiterRun.unicodePunctuationPattern
    .hasMatch(String.fromCharCode(codePoint));

(int, int) _previousCodePoint(String source, int end) {
  if (end == 0) return (0x20, 0);
  final last = source.codeUnitAt(end - 1);
  if (last >= 0xdc00 && last <= 0xdfff && end > 1) {
    final first = source.codeUnitAt(end - 2);
    if (first >= 0xd800 && first <= 0xdbff) {
      return (0x10000 + ((first - 0xd800) << 10) + last - 0xdc00, end - 2);
    }
  }
  return (last, end - 1);
}

int _codePointAt(String source, int start) {
  if (start == source.length) return 0x20;
  final first = source.codeUnitAt(start);
  if (first >= 0xd800 && first <= 0xdbff && start + 1 < source.length) {
    final last = source.codeUnitAt(start + 1);
    if (last >= 0xdc00 && last <= 0xdfff) {
      return 0x10000 + ((first - 0xd800) << 10) + last - 0xdc00;
    }
  }
  return first;
}

bool _isCjk(int codePoint) {
  var low = 0;
  var high = _cjkRanges.length ~/ 2;
  while (low < high) {
    final middle = (low + high) ~/ 2;
    final start = _cjkRanges[middle * 2];
    final end = _cjkRanges[middle * 2 + 1];
    if (codePoint < start) {
      high = middle;
    } else if (codePoint > end) {
      low = middle + 1;
    } else {
      return true;
    }
  }
  return false;
}

// Unicode 16.0 East_Asian_Width W/F/H, excluding Emoji_Presentation for W,
// plus neutral Hangul Jamo U+1160..U+11FF, as required by the CJK proposal.
// Generated from the Unicode Character Database (Unicode-3.0 license):
// https://www.unicode.org/Public/16.0.0/ucd/EastAsianWidth.txt
// https://www.unicode.org/Public/16.0.0/ucd/emoji/emoji-data.txt
// https://www.unicode.org/license.txt
const _cjkRanges = <int>[
  0x1100,
  0x11ff,
  0x20a9,
  0x20a9,
  0x2329,
  0x232a,
  0x2630,
  0x2637,
  0x268a,
  0x268f,
  0x2e80,
  0x2e99,
  0x2e9b,
  0x2ef3,
  0x2f00,
  0x2fd5,
  0x2ff0,
  0x303e,
  0x3041,
  0x3096,
  0x3099,
  0x30ff,
  0x3105,
  0x312f,
  0x3131,
  0x318e,
  0x3190,
  0x31e5,
  0x31ef,
  0x321e,
  0x3220,
  0x3247,
  0x3250,
  0xa48c,
  0xa490,
  0xa4c6,
  0xa960,
  0xa97c,
  0xac00,
  0xd7a3,
  0xf900,
  0xfaff,
  0xfe10,
  0xfe19,
  0xfe30,
  0xfe52,
  0xfe54,
  0xfe66,
  0xfe68,
  0xfe6b,
  0xff01,
  0xffbe,
  0xffc2,
  0xffc7,
  0xffca,
  0xffcf,
  0xffd2,
  0xffd7,
  0xffda,
  0xffdc,
  0xffe0,
  0xffe6,
  0xffe8,
  0xffee,
  0x16fe0,
  0x16fe4,
  0x16ff0,
  0x16ff1,
  0x17000,
  0x187f7,
  0x18800,
  0x18cd5,
  0x18cff,
  0x18d08,
  0x1aff0,
  0x1aff3,
  0x1aff5,
  0x1affb,
  0x1affd,
  0x1affe,
  0x1b000,
  0x1b122,
  0x1b132,
  0x1b132,
  0x1b150,
  0x1b152,
  0x1b155,
  0x1b155,
  0x1b164,
  0x1b167,
  0x1b170,
  0x1b2fb,
  0x1d300,
  0x1d356,
  0x1d360,
  0x1d376,
  0x1f200,
  0x1f200,
  0x1f202,
  0x1f202,
  0x1f210,
  0x1f219,
  0x1f21b,
  0x1f22e,
  0x1f230,
  0x1f231,
  0x1f237,
  0x1f237,
  0x1f23b,
  0x1f23b,
  0x1f240,
  0x1f248,
  0x1f260,
  0x1f265,
  0x20000,
  0x2fffd,
  0x30000,
  0x3fffd,
];
