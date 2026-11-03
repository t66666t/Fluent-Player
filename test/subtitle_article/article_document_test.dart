import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/subtitle_article/article_document.dart';

void main() {
  test(
    'persistent text ranges and branches match UTF-16 strings across appends',
    () {
      var document = ArticleDocument.fromDisplayTexts(
        generation: 1,
        displayTexts: ['前缀 👩🏽‍💻 العربية'],
      );
      final original = document;
      var expected = document.text;
      for (var i = 0; i < 40; i++) {
        final next = i.isEven ? '句子 $i 🇨🇳 e\u0301' : '';
        document = document.appendDisplayTexts(
          generation: i + 2,
          displayTexts: [next],
        );
        if (next.isNotEmpty) expected += ' $next';
        expect(document.textLength, expected.length);
        for (var offset = 0; offset < expected.length; offset += 7) {
          final end = (offset + 23).clamp(0, expected.length);
          expect(
            document.textBetween(offset, end),
            expected.substring(offset, end),
          );
          expect(document.codeUnitAt(offset), expected.codeUnitAt(offset));
        }
      }
      expect(document.text, expected);
      expect(original.text, '前缀 👩🏽‍💻 العربية');
      final branch = original.appendDisplayTexts(
        generation: 99,
        displayTexts: ['新分支'],
      );
      expect(branch.text, '${original.text} 新分支');
      expect(document.text, expected);
      expect(() => document.textBetween(-1, 2), throwsRangeError);
      expect(() => document.codeUnitAt(document.textLength), throwsRangeError);
      expect(
        document.textBetween(document.textLength, document.textLength),
        '',
      );
    },
  );

  test(
    'empty text chunks preserve empty cue offsets without adding separators',
    () {
      var document = ArticleDocument.fromDisplayTexts(
        generation: 0,
        displayTexts: ['', ''],
      );
      document = document.appendDisplayTexts(
        generation: 1,
        displayTexts: ['', ''],
      );
      document = document.appendDisplayTexts(
        generation: 2,
        displayTexts: ['visible'],
      );
      expect(document.textBetween(0, document.textLength), 'visible');
      expect(document.displayIndexAtOffset(0), 4);
      expect(
        document.sentences.take(4).every((sentence) => !sentence.hasText),
        isTrue,
      );
    },
  );
  test('normalizes text and keeps reversible sentence ranges', () {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 7,
      displayTexts: const <String>['  first\nline  ', '', '第二句', 'image'],
    );

    expect(document.text, 'first line  第二句  image');
    expect(document.sentenceForDisplayIndex(0)!.hasText, isTrue);
    expect(document.sentenceForDisplayIndex(1)!.hasText, isFalse);
    expect(document.displayIndexAtOffset(1), 0);
    expect(document.displayIndexAtOffset(document.text.indexOf('第二')), 2);
    expect(document.displayIndexAtOffset(document.text.indexOf('  ')), isNull);
  });

  test('same body ignores generation and rejects a text change', () {
    final first = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: const <String>['alpha', 'beta'],
    );
    final rebuilt = ArticleDocument.fromDisplayTexts(
      generation: 4,
      displayTexts: const <String>['alpha', 'beta'],
    );
    final edited = ArticleDocument.fromDisplayTexts(
      generation: 4,
      displayTexts: const <String>['alpha', 'beta!'],
    );

    expect(rebuilt.hasSameBody(first), isTrue);
    expect(edited.hasSameBody(first), isFalse);
  });

  test('image subtitle gets an explicit readable placeholder', () {
    final document = ArticleDocument.fromDisplayTexts(
      generation: 1,
      displayTexts: const <String>[''],
      imageSubtitleFlags: const <bool>[true],
    );
    expect(document.text, '[图片字幕]');
    expect(document.displayIndexAtOffset(0), 0);
  });
}
