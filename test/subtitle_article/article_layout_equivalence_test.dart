import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_engine.dart';
import 'package:video_player_app/features/subtitle_article/article_layout_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('window size does not create artificial line boundaries', () {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: const <String>[
        '第一句包含中文标点，也包含 English words.',
        'Second sentence keeps flowing naturally.',
        'emoji 👨‍👩‍👧‍👦 and e\u0301 stay intact.',
        '最后一句用于验证窗口边界。',
      ],
    );
    const style = TextStyle(fontSize: 14, height: 1.6);
    const key = ArticleLayoutKey(
      documentGeneration: 1,
      width: 180,
      style: style,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );

    final small = const ArticleLayoutEngine(
      windowCodeUnits: 24,
    ).layout(document: document, key: key);
    final large = const ArticleLayoutEngine(
      windowCodeUnits: 256,
    ).layout(document: document, key: key);

    expect(
      small.lines.map((line) => document.text.substring(line.start, line.end)),
      large.lines.map((line) => document.text.substring(line.start, line.end)),
    );
    expect(small.sentenceToLine, large.sentenceToLine);
    expect(
      small.lines.expand((line) => line.sentenceIndices),
      containsAll(<int>[0, 1, 2, 3]),
    );
  });

  test('empty sentence uses a neighboring reading anchor', () {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 2,
      displayTexts: const <String>['visible', '', 'tail'],
    );
    const style = TextStyle(fontSize: 14, height: 1.6);
    const key = ArticleLayoutKey(
      documentGeneration: 2,
      width: 240,
      style: style,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    final layout = const ArticleLayoutEngine().layout(
      document: document,
      key: key,
    );
    expect(layout.lineForSentence(1), layout.lineForSentence(2));
  });

  test('multiple short sentences on one natural line share its geometry', () {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 3,
      displayTexts: const <String>['one', 'two', 'three'],
    );
    const style = TextStyle(fontSize: 14, height: 1.6);
    const key = ArticleLayoutKey(
      documentGeneration: 3,
      width: 800,
      style: style,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    final layout = const ArticleLayoutEngine().layout(
      document: document,
      key: key,
    );
    expect(layout.lines, hasLength(1));
    expect(layout.sentenceToLine, <int>[0, 0, 0]);
  });

  test(
    'wrapped connector spaces are indexed but not painted as indentation',
    () {
      final document = ArticleDocument.fromDisplayTexts(
        generation: 4,
        displayTexts: List<String>.filled(20, 'word'),
      );
      const style = TextStyle(fontSize: 14, height: 1.6);
      const key = ArticleLayoutKey(
        documentGeneration: 4,
        width: 48,
        style: style,
        textDirection: TextDirection.ltr,
        textScaler: TextScaler.noScaling,
      );
      final layout = const ArticleLayoutEngine().layout(
        document: document,
        key: key,
      );

      expect(layout.lines.length, greaterThan(1));
      for (final line in layout.lines) {
        final painted = document.text.substring(line.paintStart, line.end);
        expect(painted.startsWith(' '), isFalse);
        expect(line.paintStart, greaterThanOrEqualTo(line.start));
      }
    },
  );

  test('generation retarget keeps the same line breaks', () {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 2,
      displayTexts: const <String>['alpha beta', 'gamma'],
    );
    const style = TextStyle(fontSize: 16, height: 1.4);
    const key = ArticleLayoutKey(
      documentGeneration: 2,
      width: 120,
      style: style,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    final layout = const ArticleLayoutEngine().layout(
      document: document,
      key: key,
    );
    final retargeted = layout.withDocumentGeneration(9);

    expect(retargeted.key.documentGeneration, 9);
    expect(retargeted.key.width, key.width);
    expect(retargeted.lines, same(layout.lines));
    expect(retargeted.sentenceToLine, layout.sentenceToLine);
    expect(identical(layout.withDocumentGeneration(2), layout), isTrue);
  });
}
