/// Splits a video description into plain text and tappable links.
library;

enum BilibiliDescriptionSegmentKind { text, url, bvid, aid }

class BilibiliDescriptionSegment {
  final BilibiliDescriptionSegmentKind kind;
  final String text;

  const BilibiliDescriptionSegment(this.kind, this.text);

  bool get isLink => kind != BilibiliDescriptionSegmentKind.text;

  @override
  bool operator ==(Object other) =>
      other is BilibiliDescriptionSegment &&
      other.kind == kind &&
      other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => '${kind.name}:$text';
}

final RegExp _linkPattern = RegExp(
  r'(https?://[^\s，。！？、；“”‘’（）【】<>"]+)'
  r'|(?<![0-9A-Za-z])(BV[0-9A-Za-z]{10})(?![0-9A-Za-z])'
  r'|(?<![0-9A-Za-z])(av\d{1,19})(?![0-9A-Za-z])',
  caseSensitive: false,
);

List<BilibiliDescriptionSegment> splitBilibiliDescription(String text) {
  final out = <BilibiliDescriptionSegment>[];
  var cursor = 0;
  for (final match in _linkPattern.allMatches(text)) {
    if (match.start > cursor) {
      out.add(
        BilibiliDescriptionSegment(
          BilibiliDescriptionSegmentKind.text,
          text.substring(cursor, match.start),
        ),
      );
    }
    var value = match.group(0)!;
    var end = match.end;
    if (match.group(1) != null) {
      // Trailing ASCII punctuation is almost never part of the link.
      final trimmed = value.replaceAll(RegExp(r'[.,!?;:)\]]+$'), '');
      end -= value.length - trimmed.length;
      value = trimmed;
    }
    final kind = match.group(1) != null
        ? BilibiliDescriptionSegmentKind.url
        : match.group(2) != null
        ? BilibiliDescriptionSegmentKind.bvid
        : BilibiliDescriptionSegmentKind.aid;
    if (kind == BilibiliDescriptionSegmentKind.bvid &&
        !value.startsWith('BV')) {
      value = 'BV${value.substring(2)}';
    }
    out.add(BilibiliDescriptionSegment(kind, value));
    cursor = end;
  }
  if (cursor < text.length) {
    out.add(
      BilibiliDescriptionSegment(
        BilibiliDescriptionSegmentKind.text,
        text.substring(cursor),
      ),
    );
  }
  return out;
}
