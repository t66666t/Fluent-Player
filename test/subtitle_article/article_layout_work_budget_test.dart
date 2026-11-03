import 'dart:collection';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_engine.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_model.dart';

class _CountingLines extends ListBase<ArticleLineRecord> {
  _CountingLines(this.values);
  final List<ArticleLineRecord> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  ArticleLineRecord operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, ArticleLineRecord value) =>
      throw UnsupportedError('immutable');
}

ArticleLayoutKey _key(int generation) => ArticleLayoutKey(
  documentGeneration: generation,
  width: 380,
  style: const TextStyle(fontSize: 15, height: 1.5),
  textDirection: TextDirection.ltr,
  textScaler: TextScaler.noScaling,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'incremental indexes preserve spanning sentences and empty-cue fallbacks',
    (tester) async {
      const engine = ArticleLayoutEngine(windowCodeUnits: 64);
      var document = ArticleDocument.fromDisplayTexts(
        generation: 1,
        displayTexts: ['', 'A long sentence ${'read this text ' * 80}', '', ''],
      );
      var layout = engine.layout(document: document, key: _key(1));
      for (var batch = 0; batch < 12; batch++) {
        document = document.appendDisplayTexts(
          generation: batch + 2,
          displayTexts: batch.isEven
              ? ['', 'New $batch, 你好世界 👩🏽‍💻 ${'words ' * 60}', '', '']
              : ['', '', ''],
        );
        var done = false;
        final future = engine.layoutIncrementally(
          document: document,
          key: _key(batch + 2),
          appendTo: layout,
          frameBudget: Duration.zero,
          isInteracting: () => true,
        )..then((_) => done = true);
        for (var frame = 0; frame < 500 && !done; frame++) {
          await tester.pump(const Duration(milliseconds: 8));
        }
        layout = (await future)!;
        final expected = engine.layout(
          document: document,
          key: _key(batch + 2),
        );
        expect(
          layout.sentenceToLine,
          expected.sentenceToLine,
          reason: 'Append $batch',
        );
        expect(
          layout.lines.map((line) => (line.start, line.end)),
          expected.lines.map((line) => (line.start, line.end)),
        );
      }
    },
  );

  testWidgets(
    'cancelling sliced layout discards work without changing a published prefix',
    (tester) async {
      const engine = ArticleLayoutEngine(windowCodeUnits: 64);
      final document = ArticleDocument.fromDisplayTexts(
        generation: 1,
        displayTexts: ['Original text.'],
      );
      final prefix = engine.layout(document: document, key: _key(1));
      final oldIndex = prefix.sentenceToLine.toList();
      var cancelled = false;
      final future = engine.layoutIncrementally(
        document: document.appendDisplayTexts(
          generation: 2,
          displayTexts: List.filled(1000, 'A new generated sentence.'),
        ),
        key: _key(2),
        appendTo: prefix,
        frameBudget: Duration.zero,
        isCancelled: () => cancelled,
      );
      cancelled = true;
      await tester.pump();
      expect(await future, isNull);
      expect(prefix.sentenceToLine, oldIndex);
    },
  );
  testWidgets('an append indexes its new tail without scanning all old lines', (
    tester,
  ) async {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: List.generate(
        6000,
        (i) => 'Sentence $i, with enough words to wrap naturally.',
      ),
    );
    const engine = ArticleLayoutEngine();
    final original = engine.layout(document: document, key: _key(1));
    final lines = _CountingLines(original.lines);
    final next = document.appendDisplayTexts(
      generation: 2,
      displayTexts: ['The newly generated sentence.'],
    );
    final future = engine.layoutIncrementally(
      document: next,
      key: _key(2),
      appendTo: ArticleLayout(
        key: original.key,
        lines: lines,
        sentenceToLine: original.sentenceToLine,
      ),
    );
    var completed = false;
    future.then((_) => completed = true);
    for (var i = 0; i < 200 && !completed; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final result = await future;
    expect(result, isNotNull);
    expect(
      lines.reads,
      lessThan(50),
      reason: 'Old line reads must stay bounded as the transcript grows.',
    );
    final expected = engine.layout(document: next, key: _key(2));
    expect(result!.sentenceToLine, expected.sentenceToLine);
    expect(
      result.lines.map((line) => (line.start, line.end)),
      expected.lines.map((line) => (line.start, line.end)),
    );
  });
}
