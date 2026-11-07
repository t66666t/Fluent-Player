import 'dart:ui' show TextDirection;

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/subtitle_font_preview.dart';

void main() {
  test('CJK specimens stay compact and include Latin when supported', () {
    final examples = {
      'zh-Hans': '字幕预览',
      'zh-Hant': '字幕預覽',
      'ja': '字幕プレビュー',
      'ko': '자막 미리보기',
    };
    for (final entry in examples.entries) {
      final sample = subtitleFontPreviewSample(['en', entry.key]);
      expect(sample.language, entry.key);
      expect(sample.primary, '${entry.value} Aa');
      expect(sample.secondary, isNull);
      expect(sample.text, isNot(contains('\n')));
      expect(subtitleFontPreviewSample([entry.key]).primary, entry.value);
    }
  });

  test('active language filter chooses the matching supported specimen', () {
    final sample = subtitleFontPreviewSample([
      'en',
      'zh-Hans',
      'zh-Hant',
      'ja',
    ], preferredLanguage: 'zh_TW');
    expect(sample.language, 'zh-Hant');
    expect(sample.primary, '字幕預覽 Aa');
    expect(
      subtitleFontPreviewSample(['en', 'ja'], preferredLanguage: 'ja').language,
      'ja',
    );
  });

  test(
    'native specimens respect script direction and catalog language support',
    () {
      final arabic = subtitleFontPreviewSample(['ar']);
      expect(arabic.direction, TextDirection.rtl);
      expect(arabic.secondary, isNull);
      final english = subtitleFontPreviewSample([
        'en',
      ], preferredLanguage: 'ja');
      expect(english.language, 'en');
      expect(english.primary, 'Subtitle preview Aa');
      expect(english.text, isNot(contains('字幕')));
      final french = subtitleFontPreviewSample(['en'], preferredLanguage: 'fr');
      expect(french.primary, 'Aperçu des sous-titres Aa');
      expect(french.languageLabel, contains('法语'));
    },
  );
  test('additional catalog scripts use native specimens', () {
    for (final code in ['km', 'lo', 'my', 'ta', 'xlc']) {
      final sample = subtitleFontPreviewSample([code]);
      expect(sample.language, code);
      expect(sample.primary.runes.any((rune) => rune > 127), isTrue);
      expect(sample.secondary, isNull);
      expect(sample.languageLabel, isNot('英语'));
    }
    final lycian = subtitleFontPreviewSample(['xlc']);
    expect(lycian.primary.runes.first, 0x10280);
  });

  test('symbol families show their actual symbol repertoire', () {
    final allkin = subtitleFontPreviewSample([], fontName: 'Allkin');
    expect(allkin.primary.runes.first, 0xe000);
    expect(allkin.languageLabel, '图形符号');
    expect(
      subtitleFontPreviewSample([
        'en',
      ], fontName: 'Libre Barcode EAN13 Text').primary,
      '0123456789',
    );
    for (final name in ['Noto Emoji', 'Noto Color Emoji']) {
      final sample = subtitleFontPreviewSample([], fontName: name);
      expect(sample.languageLabel, '表情符号');
      expect(sample.primary, contains('😀'));
      expect(sample.secondary, isNull);
    }
    expect(
      subtitleFontPreviewSample([], fontName: 'Noto Sans Math').primary,
      '∑ ∫ √ π ∞',
    );
    for (final name in ['Linefont', 'Wavefont']) {
      final sample = subtitleFontPreviewSample([], fontName: name);
      expect(sample.languageLabel, '图形符号');
      expect(sample.primary, 'abcdefghijklm');
      expect(sample.secondary, isNull);
    }
  });
}
