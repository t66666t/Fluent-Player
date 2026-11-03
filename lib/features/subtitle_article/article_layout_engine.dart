import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import 'article_document.dart';
import 'article_layout_model.dart';
import '../../utils/append_buffer.dart';

/// Produces natural-line records without ever laying out the entire article as
/// one native paragraph. The final line of each bounded window is carried into
/// the next window, so an internal batch boundary cannot become a visual line.
class ArticleLayoutEngine {
  const ArticleLayoutEngine({this.windowCodeUnits = 2048});

  final int windowCodeUnits;

  ArticleLayout layout({
    required ArticleDocument document,
    required ArticleLayoutKey key,
  }) {
    final builder = _IncrementalArticleLayoutBuilder(
      document: document,
      key: key,
      windowCodeUnits: windowCodeUnits,
    );
    while (builder.layoutNextWindow()) {}
    return builder.finish();
  }

  /// Performs the same exact layout as [layout], but returns to the frame
  /// scheduler between bounded native paragraph layouts. This lets the mode
  /// switch paint immediately even for long subtitle documents.
  Future<ArticleLayout?> layoutIncrementally({
    required ArticleDocument document,
    required ArticleLayoutKey key,
    bool Function()? isCancelled,
    bool Function()? isInteracting,
    Duration frameBudget = const Duration(milliseconds: 2),
    ArticleLayout? appendTo,
  }) async {
    // Starting from a LayoutBuilder must not shape a cold paragraph before the
    // mode switch has even painted. TextPainter stays on the UI isolate, but
    // its bounded work runs after the current frame and yields between batches.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      await SchedulerBinding.instance.endOfFrame;
    }
    if (isCancelled?.call() ?? false) return null;
    final builder = _IncrementalArticleLayoutBuilder(
      document: document,
      key: key,
      windowCodeUnits: windowCodeUnits,
      prefix:
          appendTo != null &&
              appendTo.key.width == key.width &&
              appendTo.key.style == key.style &&
              appendTo.key.textDirection == key.textDirection &&
              appendTo.key.textScaler == key.textScaler &&
              appendTo.sentenceToLine.length <= document.sentences.length &&
              (appendTo.lines.isEmpty ||
                  appendTo.lines.last.end <= document.textLength)
          ? appendTo
          : null,
    );
    final stopwatch = Stopwatch()..start();
    while (builder.layoutNextWindow()) {
      if (isCancelled?.call() ?? false) return null;
      if (stopwatch.elapsed >= _workBudget(frameBudget, isInteracting)) {
        SchedulerBinding.instance.ensureVisualUpdate();
        await SchedulerBinding.instance.endOfFrame;
        stopwatch.reset();
        if (isCancelled?.call() ?? false) return null;
      }
    }
    if (isCancelled?.call() ?? false) return null;
    return builder.finishIncrementally(
      frameBudget: frameBudget,
      isCancelled: isCancelled,
      isInteracting: isInteracting,
    );
  }
}

class _IncrementalArticleLayoutBuilder {
  _IncrementalArticleLayoutBuilder({
    required this.document,
    required this.key,
    required this.windowCodeUnits,
    ArticleLayout? prefix,
  }) {
    _prefix = prefix;
    if (prefix != null && prefix.lines.isNotEmpty) {
      _lines = AppendBuffer<ArticleLineRecord>.fromPrefix(
        prefix.lines,
        prefix.lines.length - 1,
        shareImmutablePrefix: true,
      );
      _firstChangedLine = prefix.lines.length - 1;
      cursor = prefix.lines.last.start;
    }
  }

  final ArticleDocument document;
  final ArticleLayoutKey key;
  final int windowCodeUnits;
  var _lines = AppendBuffer<ArticleLineRecord>();
  ArticleLayout? _prefix;
  int _firstChangedLine = 0;
  List<ArticleLineRecord> get lines => _lines.snapshot;
  int cursor = 0;

  bool layoutNextWindow() {
    if (document.textLength == 0 ||
        key.width <= 0 ||
        cursor >= document.textLength) {
      return false;
    }
    var windowEnd = _safeDocumentBoundary(
      document,
      cursor,
      math.min(document.textLength, cursor + windowCodeUnits),
    );
    if (windowEnd <= cursor) windowEnd = document.textLength;

    late List<TextRange> ranges;
    late TextPainter painter;
    while (true) {
      painter = TextPainter(
        text: TextSpan(
          text: document.textBetween(cursor, windowEnd),
          style: key.style,
        ),
        textDirection: key.textDirection,
        textScaler: key.textScaler,
      )..layout(maxWidth: key.width);
      ranges = _lineRanges(painter, windowEnd - cursor);
      final hasCommittedLine =
          windowEnd == document.textLength || ranges.length > 1;
      if (hasCommittedLine) break;
      painter.dispose();
      final nextEnd = _safeDocumentBoundary(
        document,
        cursor,
        math.min(document.textLength, cursor + (windowEnd - cursor) * 2),
      );
      windowEnd = nextEnd <= windowEnd ? document.textLength : nextEnd;
    }

    final metrics = painter.computeLineMetrics();
    final commitCount = windowEnd == document.textLength
        ? ranges.length
        : ranges.length - 1;
    for (var i = 0; i < commitCount; i++) {
      final range = ranges[i];
      final start = cursor + range.start;
      final end = cursor + range.end;
      if (end <= start) continue;
      var paintStart = start;
      while (paintStart < end && document.codeUnitAt(paintStart) == 0x20) {
        paintStart++;
      }
      _lines.addAll([
        ArticleLineRecord(
          start: start,
          paintStart: paintStart,
          end: end,
          height: i < metrics.length ? metrics[i].height : painter.height,
          sentenceIndices: _sentencesIntersecting(document, start, end),
        ),
      ]);
    }
    final nextCursor = cursor + ranges[commitCount - 1].end;
    painter.dispose();
    if (nextCursor <= cursor) {
      cursor = document.textLength;
      return false;
    }
    cursor = nextCursor;
    return cursor < document.textLength;
  }

  _ArticleIndexBuilder _indexBuilder() => _ArticleIndexBuilder(
    document: document,
    lines: _lines.snapshot,
    prefix: _prefix,
    firstChangedLine: _firstChangedLine,
  );

  ArticleLayout _finish(_ArticleIndexBuilder index) {
    return ArticleLayout(
      key: key,
      lines: _lines.snapshot,
      sentenceToLine: index.result,
    );
  }

  ArticleLayout finish() {
    final index = _indexBuilder();
    for (final _ in index.steps()) {}
    return _finish(index);
  }

  Future<ArticleLayout?> finishIncrementally({
    required Duration frameBudget,
    bool Function()? isCancelled,
    bool Function()? isInteracting,
  }) async {
    final index = _indexBuilder();
    final watch = Stopwatch()..start();
    for (final _ in index.steps()) {
      if (isCancelled?.call() ?? false) return null;
      if (watch.elapsed >= _workBudget(frameBudget, isInteracting)) {
        SchedulerBinding.instance.ensureVisualUpdate();
        await SchedulerBinding.instance.endOfFrame;
        watch.reset();
      }
    }
    if (isCancelled?.call() ?? false) return null;
    return _finish(index);
  }

  List<TextRange> _lineRanges(TextPainter painter, int textLength) {
    final result = <TextRange>[];
    var offset = 0;
    while (offset < textLength) {
      final range = painter.getLineBoundary(TextPosition(offset: offset));
      if (range.end <= offset) break;
      result.add(range);
      offset = range.end;
    }
    return result;
  }

  List<int> _sentencesIntersecting(
    ArticleDocument document,
    int start,
    int end,
  ) {
    final result = <int>[];
    var low = 0;
    var high = document.sentences.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (document.sentences[mid].end <= start) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    for (var i = low; i < document.sentences.length; i++) {
      final sentence = document.sentences[i];
      if (sentence.start >= end) break;
      if (!sentence.hasText) continue;
      result.add(sentence.displayIndex);
    }
    return List<int>.unmodifiable(result);
  }
}

/// Extend only the affected sentence suffix. Old lines and the old index remain
/// immutable and shared, including when one long sentence spans many lines.
class _ArticleIndexBuilder {
  _ArticleIndexBuilder({
    required this.document,
    required this.lines,
    required this.prefix,
    required this.firstChangedLine,
  });

  final ArticleDocument document;
  final List<ArticleLineRecord> lines;
  final ArticleLayout? prefix;
  final int firstChangedLine;
  late List<int> result;

  Iterable<void> steps() sync* {
    var first = 0;
    final old = prefix;
    if (old != null && old.lines.isNotEmpty) {
      final start = old.lines.last.start;
      var high = math.min(old.sentenceToLine.length, document.sentences.length);
      while (first < high) {
        final mid = (first + high) >> 1;
        if (document.sentences[mid].end <= start) {
          first = mid + 1;
        } else {
          high = mid;
        }
      }
      // Empty cues before the reflowing sentence may now resolve to a new
      // following line instead of the old final line.
      while (first > 0 && !document.sentences[first - 1].hasText) {
        first--;
        if (first % 512 == 0) yield null;
      }
    }
    final tail = List<int>.filled(document.sentences.length - first, -1);
    if (old != null) {
      for (var i = first; i < old.sentenceToLine.length; i++) {
        final line = old.sentenceToLine[i];
        if (document.sentences[i].hasText && line < firstChangedLine) {
          tail[i - first] = line;
        }
        if (i % 512 == 0) yield null;
      }
    }
    for (var line = firstChangedLine; line < lines.length; line++) {
      for (final sentence in lines[line].sentenceIndices) {
        if (sentence >= first && tail[sentence - first] < 0) {
          tail[sentence - first] = line;
        }
      }
      if (line % 128 == 0) yield null;
    }
    var next = -1;
    for (var i = tail.length - 1; i >= 0; i--) {
      if (tail[i] >= 0) next = tail[i];
      if (tail[i] < 0) tail[i] = next;
      if (i % 512 == 0) yield null;
    }
    var previous = first > 0 ? old!.sentenceToLine[first - 1] : -1;
    final buffer = old == null
        ? AppendBuffer<int>()
        : AppendBuffer<int>.fromPrefix(
            old.sentenceToLine,
            first,
            shareImmutablePrefix: true,
          );
    for (var i = 0; i < tail.length; i++) {
      if (tail[i] >= 0) previous = tail[i];
      buffer.addAll([tail[i] < 0 ? previous : tail[i]]);
      if (i % 512 == 0) yield null;
    }
    result = buffer.snapshot;
  }
}

int _safeDocumentBoundary(ArticleDocument document, int start, int offset) {
  if (offset >= document.textLength) return document.textLength;
  // The committed line starts at a grapheme boundary. Two code units beyond
  // the candidate provide right context without flattening the whole article.
  final probeEnd = math.min(document.textLength, offset + 2);
  final window = document.textBetween(start, probeEnd);
  return start + _safeBoundary(window, offset - start);
}

int _safeBoundary(String text, int offset) {
  if (offset <= 0 || offset >= text.length) return offset;
  return CharacterRange.at(text, offset).stringBeforeLength;
}

Duration _workBudget(Duration maximum, bool Function()? isInteracting) =>
    isInteracting?.call() == true && maximum.inMicroseconds > 500
    ? const Duration(microseconds: 500)
    : maximum;
