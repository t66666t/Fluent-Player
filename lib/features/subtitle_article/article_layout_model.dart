import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

@immutable
class ArticleLayoutKey {
  const ArticleLayoutKey({
    required this.documentGeneration,
    required this.width,
    required this.style,
    required this.textDirection,
    required this.textScaler,
  });

  final int documentGeneration;
  final double width;
  final TextStyle style;
  final TextDirection textDirection;
  final TextScaler textScaler;

  @override
  bool operator ==(Object other) {
    return other is ArticleLayoutKey &&
        other.documentGeneration == documentGeneration &&
        (other.width - width).abs() < 0.01 &&
        other.style == style &&
        other.textDirection == textDirection &&
        other.textScaler == textScaler;
  }

  @override
  int get hashCode => Object.hash(
    documentGeneration,
    width.toStringAsFixed(2),
    style,
    textDirection,
    textScaler,
  );
}

@immutable
class ArticleLineRecord {
  const ArticleLineRecord({
    required this.start,
    required this.paintStart,
    required this.end,
    required this.height,
    required this.sentenceIndices,
  });

  final int start;

  /// First code unit that is actually painted for this visual line.
  ///
  /// Flutter keeps wrapping separator spaces in the logical line range, but
  /// does not visibly indent the next line with those spaces. Since continuous
  /// mode paints natural lines independently, retain [start] for indexing and
  /// skip only those wrapping spaces when painting.
  final int paintStart;
  final int end;
  final double height;
  final List<int> sentenceIndices;
}

@immutable
class ArticleLayout {
  const ArticleLayout({
    required this.key,
    required this.lines,
    required this.sentenceToLine,
  });

  final ArticleLayoutKey key;
  final List<ArticleLineRecord> lines;
  final List<int> sentenceToLine;

  /// Reuses these line breaks for a document that has the same body but a new
  /// generation, so a list refresh does not throw away a finished layout.
  ArticleLayout withDocumentGeneration(int generation) {
    if (key.documentGeneration == generation) return this;
    return ArticleLayout(
      key: ArticleLayoutKey(
        documentGeneration: generation,
        width: key.width,
        style: key.style,
        textDirection: key.textDirection,
        textScaler: key.textScaler,
      ),
      lines: lines,
      sentenceToLine: sentenceToLine,
    );
  }

  int lineForSentence(int sentenceIndex) {
    if (sentenceIndex < 0 || sentenceIndex >= sentenceToLine.length) return -1;
    return sentenceToLine[sentenceIndex];
  }
}
