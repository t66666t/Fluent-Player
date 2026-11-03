import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../../utils/append_buffer.dart';

/// A subtitle sentence in the normalized article text.
@immutable
class ArticleSentenceRef {
  const ArticleSentenceRef({
    required this.displayIndex,
    required this.start,
    required this.end,
  });

  final int displayIndex;
  final int start;
  final int end;

  bool get hasText => end > start;
  bool contains(int offset) => offset >= start && offset < end;
}

/// Immutable text and range index used by the continuous article renderer.
@immutable
class ArticleDocument {
  const ArticleDocument._({
    required this.generation,
    required _ArticleText body,
    required this.sentences,
  }) : _body = body;

  factory ArticleDocument.fromDisplayTexts({
    required int generation,
    required List<String> displayTexts,
    List<bool>? imageSubtitleFlags,
    String sentenceSeparator = '\u0020\u0020',
  }) {
    final builder = _ArticleDocumentBuilder(sentenceSeparator);
    for (var index = 0; index < displayTexts.length; index++) {
      builder.add(
        displayTexts[index],
        image:
            imageSubtitleFlags != null &&
            index < imageSubtitleFlags.length &&
            imageSubtitleFlags[index],
      );
    }
    return builder.finish(generation);
  }

  /// Keep cold document preparation out of the panel's first frame and yield
  /// between bounded batches. Hidden/replaced media abandon their own result;
  /// gestures and sidebar motion retain the foreground work budget.
  static Future<ArticleDocument?> fromDisplayTextsIncrementally({
    required int generation,
    required List<String> displayTexts,
    List<bool>? imageSubtitleFlags,
    String sentenceSeparator = '\u0020\u0020',
    bool Function()? isCancelled,
    bool Function()? isInteracting,
    Duration frameBudget = const Duration(milliseconds: 2),
    ArticleDocument? appendTo,
  }) async {
    Future<void> yieldFrame() {
      SchedulerBinding.instance.ensureVisualUpdate();
      return SchedulerBinding.instance.endOfFrame;
    }

    await yieldFrame();
    final builder = _ArticleDocumentBuilder(
      sentenceSeparator,
      prefix: appendTo,
    );
    final count = displayTexts.length;
    var index = appendTo?.sentences.length ?? 0;
    if (index > count) return null;
    final work = Stopwatch();
    while (index < count) {
      if (isCancelled?.call() ?? false) return null;
      if (isInteracting?.call() ?? false) {
        await yieldFrame();
        continue;
      }
      work
        ..reset()
        ..start();
      var batch = 0;
      do {
        builder.add(
          displayTexts[index],
          image:
              imageSubtitleFlags != null &&
              index < imageSubtitleFlags.length &&
              imageSubtitleFlags[index],
        );
        index++;
        batch++;
      } while (index < count && batch < 128 && work.elapsed < frameBudget);
      work.stop();
      if (index < count) await yieldFrame();
    }
    if (isCancelled?.call() ?? false) return null;
    return builder.finish(generation);
  }

  final int generation;
  final _ArticleText _body;

  /// Full text is materialized only for consumers that actually need it, such
  /// as export. Streaming layout and hit testing read bounded ranges instead.
  String get text => _body.text;
  int get textLength => _body.length;
  String textBetween(int start, int end) => _body.substring(start, end);
  int codeUnitAt(int offset) => _body.codeUnitAt(offset);
  final List<ArticleSentenceRef> sentences;

  ArticleDocument appendDisplayTexts({
    required int generation,
    required List<String> displayTexts,
    String sentenceSeparator = ' ',
  }) {
    final body = StringBuffer();
    final refs = AppendBuffer<ArticleSentenceRef>.fromPrefix(
      sentences,
      sentences.length,
      shareImmutablePrefix: true,
    );
    var hasText = textLength > 0;
    for (var i = 0; i < displayTexts.length; i++) {
      final next = normalizeArticleSentence(displayTexts[i]);
      if (next.isNotEmpty && hasText) body.write(sentenceSeparator);
      final start = textLength + body.length;
      body.write(next);
      refs.addAll([
        ArticleSentenceRef(
          displayIndex: sentences.length + i,
          start: start,
          end: textLength + body.length,
        ),
      ]);
      if (next.isNotEmpty) hasText = true;
    }
    return ArticleDocument._(
      generation: generation,
      body: _body.append(body.toString()),
      sentences: refs.snapshot,
    );
  }

  /// True when both documents paint the same sentences at the same offsets.
  ///
  /// Generation is ignored. A new subtitle list instance with unchanged text
  /// can keep an already built layout instead of looking like a new article.
  bool hasSameBody(ArticleDocument other) {
    if (identical(this, other)) return true;
    if (text != other.text || sentences.length != other.sentences.length) {
      return false;
    }
    for (var i = 0; i < sentences.length; i++) {
      final ArticleSentenceRef a = sentences[i];
      final ArticleSentenceRef b = other.sentences[i];
      if (a.displayIndex != b.displayIndex ||
          a.start != b.start ||
          a.end != b.end) {
        return false;
      }
    }
    return true;
  }

  ArticleSentenceRef? sentenceForDisplayIndex(int index) {
    if (index < 0 || index >= sentences.length) return null;
    return sentences[index];
  }

  /// Returns null for the single-space separator and for document padding.
  int? displayIndexAtOffset(int offset) {
    var low = 0;
    var high = sentences.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final sentence = sentences[mid];
      if (offset < sentence.start) {
        high = mid - 1;
      } else if (offset >= sentence.end) {
        low = mid + 1;
      } else {
        return sentence.hasText ? sentence.displayIndex : null;
      }
    }
    return null;
  }
}

String normalizeArticleSentence(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _ArticleDocumentBuilder {
  _ArticleDocumentBuilder(this.separator, {ArticleDocument? prefix})
    : _prefix = prefix,
      _sentences = [...?prefix?.sentences],
      _hasText = (prefix?.textLength ?? 0) > 0;
  final String separator;
  final ArticleDocument? _prefix;
  final StringBuffer _body = StringBuffer();
  final List<ArticleSentenceRef> _sentences;
  bool _hasText;

  void add(String value, {required bool image}) {
    var text = normalizeArticleSentence(value);
    if (text.isEmpty && image) text = '[图片字幕]';
    if (text.isNotEmpty && _hasText) _body.write(separator);
    final start = (_prefix?.textLength ?? 0) + _body.length;
    _body.write(text);
    _sentences.add(
      ArticleSentenceRef(
        displayIndex: _sentences.length,
        start: start,
        end: (_prefix?.textLength ?? 0) + _body.length,
      ),
    );
    if (text.isNotEmpty) _hasText = true;
  }

  ArticleDocument finish(int generation) => ArticleDocument._(
    generation: generation,
    body:
        _prefix?._body.append(_body.toString()) ??
        _ArticleText.fromString(_body.toString()),
    sentences: List<ArticleSentenceRef>.unmodifiable(_sentences),
  );
}

class _ArticleTextChunk {
  const _ArticleTextChunk(this.start, this.text);
  final int start;
  final String text;
  int get end => start + text.length;
}

/// Persistent immutable UTF-16 chunks. Appending generated text never copies
/// the old article; a layout window only reads the few chunks it intersects.
class _ArticleText {
  _ArticleText(this.chunks, this.length, {String? text}) : _text = text;
  factory _ArticleText.fromString(String text) => _ArticleText(
    text.isEmpty ? const [] : [_ArticleTextChunk(0, text)],
    text.length,
    text: text,
  );

  final List<_ArticleTextChunk> chunks;
  final int length;
  String? _text;
  String get text => _text ??= substring(0, length);

  _ArticleText append(String suffix) {
    if (suffix.isEmpty) return this;
    final buffer = AppendBuffer<_ArticleTextChunk>.fromPrefix(
      chunks,
      chunks.length,
      shareImmutablePrefix: true,
    )..addAll([_ArticleTextChunk(length, suffix)]);
    return _ArticleText(buffer.snapshot, length + suffix.length);
  }

  int _chunkAt(int offset) {
    var low = 0;
    var high = chunks.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (chunks[mid].end <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  int codeUnitAt(int offset) {
    RangeError.checkValidIndex(offset, this, 'offset', length);
    final chunk = chunks[_chunkAt(offset)];
    return chunk.text.codeUnitAt(offset - chunk.start);
  }

  String substring(int start, int end) {
    RangeError.checkValidRange(start, end, length);
    if (start == end) return '';
    final index = _chunkAt(start);
    final first = chunks[index];
    if (end <= first.end) {
      return first.text.substring(start - first.start, end - first.start);
    }
    final buffer = StringBuffer();
    for (var i = index; i < chunks.length; i++) {
      final chunk = chunks[i];
      buffer.write(
        chunk.text.substring(
          (start - chunk.start).clamp(0, chunk.text.length),
          (end - chunk.start).clamp(0, chunk.text.length),
        ),
      );
      if (end <= chunk.end) break;
    }
    return buffer.toString();
  }
}
