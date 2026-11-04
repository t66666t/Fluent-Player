import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/subtitle_layout.dart';

const _realStyle = TextStyle(fontFamily: 'SubtitleWrapTest', fontSize: 30);
const _monoStyle = TextStyle(fontFamily: 'Ahem', fontSize: 20);

String _plain(InlineSpan text) =>
    text.toPlainText(includeSemanticsLabels: false);
String _normalize(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

void _fits(
  SubtitleTextLayout result,
  double width, {
  TextDirection direction = TextDirection.ltr,
}) {
  final painter = TextPainter(text: result.text, textDirection: direction)
    ..layout(maxWidth: width);
  try {
    expect(
      painter.computeLineMetrics().every((l) => l.width <= width + .1),
      isTrue,
      reason: _plain(result.text),
    );
    expect(
      painter.computeLineMetrics().length,
      RegExp(
            r'\r\n|[\n\r\u0085\u2028\u2029]',
          ).allMatches(_plain(result.text)).length +
          1,
      reason: 'no additional implicit wraps: ${_plain(result.text)}',
    );
  } finally {
    painter.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('SubtitleWrapTest')
          ..addFont(rootBundle.load('assets/fonts/SweiGothicCJKsc-Bold.ttf')))
        .load();
  });

  test('Chinese prefers the comma over splitting 颜色 for visual balance', () {
    const source = '如果你只是想改变字幕的颜色，可以在设置里调整。';
    const span = TextSpan(text: source, style: _realStyle);
    final result = layoutSubtitleText(span, maxWidth: 460);
    expect(_plain(result.text), '如果你只是想改变字幕的颜色，\n可以在设置里调整。');
    expect(result.wrapText(source), _plain(result.text));
    expect(_plain(span), source);
    _fits(result, 460);
  });

  for (final text in ['字幕颜色', 'Subtitle color', '字幕の色', '자막 색상']) {
    test('a fitting line stays untouched: $text', () {
      final span = TextSpan(text: text, style: _realStyle);
      final result = layoutSubtitleText(span, maxWidth: 800);
      expect(result.text, same(span));
      expect(result.breaks, isEmpty);
    });
  }

  test('a punctuation preference does not leave a tiny orphan line', () {
    const source = '我们一起学习如何调整字幕的颜色，好。';
    final result = layoutSubtitleText(
      const TextSpan(text: source, style: _realStyle),
      maxWidth: 460,
    );
    expect(_plain(result.text), isNot(endsWith('\n好。')));
    _fits(result, 460);
  });

  test('Japanese prefers a clause boundary', () {
    const source = '字幕の色を変えたい場合は、設定画面で調整できます。';
    final result = layoutSubtitleText(
      const TextSpan(text: source, style: _realStyle),
      maxWidth: 460,
    );
    expect(_plain(result.text), contains('場合は、\n設定画面'));
    _fits(result, 460);
  });

  for (final width in [100.0, 140.0, 220.0, 320.0]) {
    test('Japanese kinsoku, small kana and long vowel marks at $width', () {
      const source = '今日は「コーヒーショップ」で、ゆっくり話しましょう。';
      final result = layoutSubtitleText(
        const TextSpan(text: source, style: _realStyle),
        maxWidth: width,
      );
      for (final line in _plain(result.text).split('\n')) {
        expect(
          RegExp(r'^[」』）】、。っゃゅょッャュョー]').hasMatch(line),
          isFalse,
          reason: line,
        );
        expect(RegExp(r'[「『（【]$').hasMatch(line), isFalse, reason: line);
      }
      _fits(result, width);
    });
  }

  test('Korean keeps space-delimited words together', () {
    const source = '자막의 색상을 변경하려면 설정에서 조정할 수 있습니다.';
    final result = layoutSubtitleText(
      const TextSpan(text: source, style: _realStyle),
      maxWidth: 300,
    );
    expect(_normalize(_plain(result.text)), source);
    for (final word in source.split(' ')) {
      expect(_plain(result.text), contains(word));
    }
    _fits(result, 300);
  });

  test('English keeps a determiner with the next word when possible', () {
    const source = 'We returned to the old station, where the journey began.';
    final result = layoutSubtitleText(
      const TextSpan(text: source, style: _realStyle),
      maxWidth: 480,
    );
    expect(_plain(result.text), isNot(contains('the\n')));
    expect(_normalize(_plain(result.text)), source);
    _fits(result, 480);
  });

  test('straight opening and closing quotes stay with the quoted text', () {
    const source = 'He said "come back tomorrow", and we waited for him.';
    for (final width in [200.0, 260.0, 400.0]) {
      final result = layoutSubtitleText(
        const TextSpan(text: source, style: _realStyle),
        maxWidth: width,
      );
      for (final cut in result.breaks) {
        expect(cut.start, isNot(source.indexOf('"come') + 1));
        expect(cut.end, isNot(source.indexOf('",')));
      }
      _fits(result, width);
    }
  });

  test('half-width Japanese small kana and long vowels obey kinsoku', () {
    const source = '今日は「ｺｰﾋｰｼｮｯﾌﾟ」で話しましょう。';
    final result = layoutSubtitleText(
      const TextSpan(text: source, style: _realStyle),
      maxWidth: 140,
    );
    for (final line in _plain(result.text).split('\n')) {
      expect(RegExp(r'^[ｧｨｩｪｫｯｬｭｮｰ」]').hasMatch(line), isFalse, reason: line);
    }
    _fits(result, 140);
  });

  for (final source in [
    'Bonjour à tous, nous rentrons à la maison ensemble.',
    'Wir gehen heute gemeinsam zum alten Bahnhof zurück.',
    'Volvemos a la estación, donde comenzó nuestro viaje.',
    'Сегодня мы снова встретились возле старого вокзала.',
    'مرحبا بالعالم هذا اختبار للنص العربي',
    'आज हम अपने पुराने घर वापस जा रहे हैं',
  ]) {
    test('Unicode word boundaries preserve words: $source', () {
      final direction = source.startsWith('مرحبا')
          ? TextDirection.rtl
          : TextDirection.ltr;
      final result = layoutSubtitleText(
        TextSpan(text: source, style: _monoStyle),
        maxWidth: 400,
        textDirection: direction,
      );
      expect(_normalize(_plain(result.text)), source);
      for (final word in source.split(' ')) {
        expect(_plain(result.text), contains(word));
      }
      _fits(result, 400, direction: direction);
    });
  }

  test('emoji, combining accents and decomposed Hangul stay in graphemes', () {
    const source =
        '你好👨‍👩‍👧‍👦，Cafe\u0301 👩🏽‍💻 和🇯🇵 \u1100\u1161\u11a8，再见。';
    final result = layoutSubtitleText(
      const TextSpan(text: source, style: _monoStyle),
      maxWidth: 220,
    );
    final boundaries = <int>{0};
    var offset = 0;
    for (final glyph in source.characters) {
      offset += glyph.length;
      boundaries.add(offset);
    }
    for (final cut in result.breaks) {
      expect(boundaries, contains(cut.start));
      expect(boundaries, contains(cut.end));
    }
    for (final glyph in [
      '👨‍👩‍👧‍👦',
      'e\u0301',
      '👩🏽‍💻',
      '🇯🇵',
      '\u1100\u1161\u11a8',
    ]) {
      expect(_plain(result.text), contains(glyph));
    }
    _fits(result, 220);
  });

  for (final unit in ['12.5 kg', '30 km/h', '25℃', '100 公里', '30 分钟', '5 시간']) {
    test('number and unit stay together: $unit', () {
      final source = 'We carried $unit for the entire journey.';
      final result = layoutSubtitleText(
        TextSpan(text: source, style: _monoStyle),
        maxWidth: 260,
      );
      expect(_plain(result.text), contains(unit));
      _fits(result, 260);
    });
  }

  test('nonbreaking spaces and word joiners retain their meaning', () {
    const source = 'Meet us in New\u00a0York or at word\u2060join tomorrow.';
    final result = layoutSubtitleText(
      const TextSpan(text: source, style: _monoStyle),
      maxWidth: 260,
    );
    expect(_plain(result.text), contains('New\u00a0York'));
    expect(_plain(result.text), contains('word\u2060join'));
    _fits(result, 260);
  });

  test('dates, time, fractions and currency stay together when they fit', () {
    for (final token in ['2026-10-26', '12:30', '1/2', '\$100']) {
      final result = layoutSubtitleText(
        TextSpan(text: 'The value is $token for today.', style: _monoStyle),
        maxWidth: 260,
      );
      expect(_plain(result.text), contains(token));
      _fits(result, 260);
    }
  });

  test('manual dialogue lines and blank CRLF lines are preserved', () {
    const source = '第一位：请在这里等我，我们马上回来。\r\n\r\n第二位：好的。';
    final result = layoutSubtitleText(
      const TextSpan(text: source, style: _realStyle),
      maxWidth: 360,
    );
    expect(_plain(result.text), contains('\r\n\r\n第二位：好的。'));
    expect(
      _plain(result.text).replaceAll('\n', '').replaceAll('\r', ''),
      source.replaceAll('\n', '').replaceAll('\r', ''),
    );
    _fits(result, 360);
  });

  test('primary and secondary paragraphs choose breaks independently', () {
    const primary = TextSpan(
      text: '如果你只是想改变字幕的颜色，可以在设置里调整。',
      style: _realStyle,
    );
    const secondary = TextSpan(
      text:
          'If you only want to change the subtitle color, adjust it in settings.',
      style: TextStyle(fontFamily: 'SubtitleWrapTest', fontSize: 20),
    );
    final joined = layoutSubtitleText(
      const TextSpan(
        children: [
          primary,
          TextSpan(text: '\n'),
          secondary,
        ],
      ),
      maxWidth: 460,
    );
    final p = layoutSubtitleText(primary, maxWidth: 460);
    final s = layoutSubtitleText(secondary, maxWidth: 460);
    expect(_plain(joined.text), '${_plain(p.text)}\n${_plain(s.text)}');
    expect(
      joined.wrapText(secondary.text!, sourceOffset: primary.text!.length + 1),
      _plain(s.text),
    );
    final children = (joined.text as TextSpan).children!;
    expect(children.first.style, same(_realStyle));
    expect(children.last.style!.fontSize, 20);
    _fits(joined, 460);
  });

  test('whitespace crossing styled runs is consumed only at chosen wraps', () {
    const source = TextSpan(
      style: _monoStyle,
      children: [
        TextSpan(text: 'Hello'),
        TextSpan(
          text: '  ',
          style: TextStyle(color: Color(0xffff0000)),
        ),
        TextSpan(text: 'world again longer'),
      ],
    );
    final result = layoutSubtitleText(source, maxWidth: 120);
    expect(_plain(result.text), 'Hello\nworld\nagain\nlonger');
    expect(result.wrapText(_plain(source)), _plain(result.text));
    _fits(result, 120);
  });

  for (final source in [
    'supercalifragilisticexpialidocious',
    '아주아주아주아주아주아주긴한글단어',
  ]) {
    test('an oversized word can wrap without truncation: $source', () {
      final result = layoutSubtitleText(
        TextSpan(text: source, style: _realStyle),
        maxWidth: 100,
      );
      expect(_plain(result.text).replaceAll('\n', ''), source);
      _fits(result, 100);
    });
  }

  test('very long captions retain all content with bounded work', () {
    final source = List.filled(60, '我们一起回家。Let us go home. 함께 갑시다.').join(' ');
    final result = layoutSubtitleText(
      TextSpan(text: source, style: _realStyle),
      maxWidth: 460,
    );
    expect(
      _plain(result.text).replaceAll(RegExp(r'\s+'), ''),
      source.replaceAll(RegExp(r'\s+'), ''),
    );
    expect(result.wrapText(source), _plain(result.text));
    expect(_plain(result.text).split('\n').length, greaterThan(8));
    _fits(result, 460);
  });

  test('nearby widths and proportional export sizes keep natural cuts', () {
    const span = TextSpan(text: '如果你只是想改变字幕的颜色，可以在设置里调整。', style: _realStyle);
    final baseline = _plain(layoutSubtitleText(span, maxWidth: 460).text);
    for (final width in [455.0, 480.0]) {
      expect(_plain(layoutSubtitleText(span, maxWidth: width).text), baseline);
    }
    final scaled = layoutSubtitleText(
      TextSpan(text: span.text, style: _realStyle.copyWith(fontSize: 60)),
      maxWidth: 920,
    );
    expect(_plain(scaled.text), baseline);
  });

  test('invalid widths leave text untouched', () {
    const span = TextSpan(text: 'First line\nSecond line', style: _monoStyle);
    for (final width in [0.0, -1.0, double.infinity, double.nan]) {
      expect(layoutSubtitleText(span, maxWidth: width).text, same(span));
    }
  });
}
