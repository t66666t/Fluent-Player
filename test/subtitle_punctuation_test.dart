import 'package:flutter_test/flutter_test.dart';
import 'dart:math';
import 'package:characters/characters.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';
import 'support/subtitle_punctuation_reference.dart' as reference;

SubtitleItem cue(String text) => SubtitleItem(
  index: 1,
  startTime: Duration.zero,
  endTime: const Duration(seconds: 3),
  text: text,
  asrInfo: const SubtitleAsrInfo(language: 'auto', reviewReason: 'review'),
);

String apply(String text, SubtitlePunctuation mode) =>
    applySubtitlePunctuation(cue(text), mode).text;

void main() {
  const fullStops = SubtitlePunctuation.removeTrailingFullStops;
  const stopsAndCommas = SubtitlePunctuation.removeTrailingFullStopsAndCommas;
  const trailing = SubtitlePunctuation.removeTrailingPunctuation;
  const all = SubtitlePunctuation.removeAll;
  test(
    'optimized paths preserve the prior output and word ranges across random Unicode mixtures',
    () {
      final random = Random(20261020);
      const tokens = [
        'a',
        'U.S.',
        'AB.C.',
        'e.g.',
        '_A.B.',
        '3.14',
        '中文',
        'مرحبا',
        'हिन्दी',
        'བོད་',
        'Русский',
        '👨‍👩‍👧‍👦',
        '#️⃣',
        '‼️',
        '🙂',
        'a\u0301',
        '.\u0301',
        '\u0600',
        '\u200f',
        '\u200d',
        '\u0301',
        '。',
        '.',
        '...',
        '！？',
        '،',
        '؟',
        '।',
        '\u{16af5}',
        '“',
        '”',
        '(',
        ')',
        "'",
        ' ',
        '\n',
        '<i>',
        '</i>',
        r'{\an8}',
        '<font color="red">',
        '</font>',
        '<',
        '>',
        '!',
        '@',
        '/',
        '\\',
      ];
      final samples = <String>[
        for (var c = 0; c < 128; c++) 'x${String.fromCharCode(c)}',
        ...List.generate(
          3000,
          (_) => List.generate(
            1 + random.nextInt(24),
            (_) => tokens[random.nextInt(tokens.length)],
          ).join(),
        ),
      ];
      for (final text in samples) {
        final spans = <SubtitleTimedSpan>[];
        var at = 0;
        for (final glyph in text.characters) {
          if (random.nextBool()) {
            spans.add(
              SubtitleTimedSpan(
                textStart: at,
                textEnd: at + glyph.length,
                startTime: Duration.zero,
                endTime: const Duration(seconds: 1),
                role: 'aligned',
              ),
            );
          }
          at += glyph.length;
        }
        final source = cue(text).copyWith(timedSpans: spans);
        // Keep the frozen implementation as the oracle for its original modes.
        for (final mode in SubtitlePunctuation.values.where(
          (mode) => mode != stopsAndCommas,
        )) {
          final expected = reference.applySubtitlePunctuation(
            source,
            reference.SubtitlePunctuation.values.byName(mode.name),
          );
          final actual = applySubtitlePunctuation(source, mode);
          expect(
            actual.toTimingJson(),
            expected.toTimingJson(),
            reason: '$mode / $text',
          );
          expect(applySubtitlePunctuationText(text, mode), actual.text);
        }
      }
    },
  );
  test(
    'default and persisted choices are stable and unknown settings migrate',
    () {
      expect(SubtitlePunctuation.defaultValue, stopsAndCommas);
      for (final mode in SubtitlePunctuation.values) {
        expect(SubtitlePunctuation.fromStorage(mode.name), mode);
      }
      expect(SubtitlePunctuation.fromStorage(null), stopsAndCommas);
      expect(SubtitlePunctuation.fromStorage('future'), stopsAndCommas);
      expect(
        SubtitlePunctuation.fromStorage(
          null,
          fallback: SubtitlePunctuation.preserve,
        ),
        SubtitlePunctuation.preserve,
      );
    },
  );
  final languages = {
    '中文。': '中文',
    '日本語｡': '日本語',
    '한국어.': '한국어',
    'English.': 'English',
    'Français.': 'Français',
    'Русский.': 'Русский',
    'Tiếng Việt.': 'Tiếng Việt',
    'مرحبا۔': 'مرحبا',
    'Հայերեն։': 'Հայերեն',
    'हिन्दी।': 'हिन्दी',
    'বাংলা॥': 'বাংলা',
    'မြန်မာ။': 'မြန်မာ',
    'አማርኛ።': 'አማርኛ',
    'монгол᠃': 'монгол',
    'བོད་ཡིག།': 'བོད་ཡིག',
    'ᐃᓄᒃᑎᑐᑦ᙮': 'ᐃᓄᒃᑎᑐᑦ',
    'text\u{16af5}': 'text',
  };
  for (final entry in languages.entries) {
    test('full stop output is independent of language: ${entry.key}', () {
      expect(apply(entry.key, fullStops), entry.value);
      expect(apply(entry.key, stopsAndCommas), entry.value);
      expect(apply(entry.key, trailing), entry.value);
      expect(
        apply(entry.key, all),
        entry.key == 'བོད་ཡིག།' ? 'བོདཡིག' : entry.value,
      );
    });
  }
  test(
    'new default removes terminal comma variants without changing old mode',
    () {
      const commas = [
        0x002c,
        0x055d,
        0x060c,
        0x07f8,
        0x1363,
        0x1802,
        0x1808,
        0x2e32,
        0x2e34,
        0x2e41,
        0x2e49,
        0x2e4c,
        0x3001,
        0xa4fe,
        0xa60d,
        0xa6f5,
        0xfe10,
        0xfe11,
        0xfe50,
        0xfe51,
        0xff0c,
        0xff64,
        0x1144d,
        0x1145a,
        0x16e97,
        0x1da87,
      ];
      for (final code in commas) {
        final comma = String.fromCharCode(code);
        final text = '“Hello, 世界🙂$comma”  ';
        expect(apply(text, stopsAndCommas), '“Hello, 世界🙂”  ');
        expect(apply(text, fullStops), text);
        expect(apply('$text?', stopsAndCommas), '$text?');
      }
      expect(apply('你好。，', stopsAndCommas), '你好');
      expect(apply('你好，。', stopsAndCommas), '你好');
      expect(
        apply('<i>مرحبا،</i>\u200f', stopsAndCommas),
        '<i>مرحبا</i>\u200f',
      );
      expect(apply(r'{\an8}你好，', stopsAndCommas), r'{\an8}你好');
      expect(apply('第一行，\n第二行，', stopsAndCommas), '第一行，\n第二行');
      for (final text in [
        'Hello, world',
        '你好，世界',
        '等待……',
        'Wait...,',
        'U.S.,',
        'e.g.,',
        '你好？',
        'Hello!',
        'hello;',
        'hello:',
        '1,234',
        '3.14',
        '١٫٢',
        '١٬٢',
        'text\u02bb',
        'text\ua4fd',
      ]) {
        expect(
          apply(text, stopsAndCommas),
          text.endsWith(',') ? text.substring(0, text.length - 1) : text,
        );
      }
    },
  );
  test(
    'new default remaps trailing comma ranges without changing cue identity or timing',
    () {
      final original = cue('“🙂,。”').copyWith(
        timedSpans: const [
          SubtitleTimedSpan(
            textStart: 1,
            textEnd: 3,
            startTime: Duration.zero,
            endTime: Duration(seconds: 1),
          ),
          SubtitleTimedSpan(
            textStart: 3,
            textEnd: 4,
            startTime: Duration(seconds: 1),
            endTime: Duration(seconds: 2),
          ),
          SubtitleTimedSpan(
            textStart: 4,
            textEnd: 5,
            startTime: Duration(seconds: 2),
            endTime: Duration(seconds: 3),
          ),
          SubtitleTimedSpan(
            textStart: 5,
            textEnd: 6,
            startTime: Duration(seconds: 3),
            endTime: Duration(seconds: 4),
          ),
        ],
      );
      final result = applySubtitlePunctuation(original, stopsAndCommas);
      expect(result.text, '“🙂”');
      expect(result.index, original.index);
      expect(result.startTime, original.startTime);
      expect(result.endTime, original.endTime);
      expect(result.asrInfo, same(original.asrInfo));
      expect(result.timedSpans, hasLength(2));
      expect(result.timedSpans.first, same(original.timedSpans.first));
      expect(result.timedSpans.last.textStart, 3);
      expect(result.timedSpans.last.textEnd, 4);
      expect(
        result.timedSpans.last.startTime,
        original.timedSpans.last.startTime,
      );
      expect(result.timedSpans.last.endTime, original.timedSpans.last.endTime);
      expect(
        applySubtitlePunctuationText(original.text, stopsAndCommas),
        result.text,
      );
    },
  );
  test(
    'sentence ends retain quotes, brackets, bidi marks and inner punctuation',
    () {
      expect(apply('他说：“你好，世界。”', fullStops), '他说：“你好，世界”');
      expect(apply('“Hello.”  ', fullStops), '“Hello”  ');
      expect(apply('(مرحبا۔)\u200f', fullStops), '(مرحبا)\u200f');
      expect(apply('第一行。\n第二行。', fullStops), '第一行。\n第二行');
      expect(apply('“你好吗？！”', trailing), '“你好吗”');
      expect(apply('«مرحبا، كيف حالك؟»', trailing), '«مرحبا، كيف حالك»');
      expect(apply('¿Cómo estás?', trailing), '¿Cómo estás');
    },
  );
  test('default keeps questions, exclamations, ellipses and lexical dots', () {
    for (final text in [
      '好吗？',
      'Hello!',
      'مرحبا؟',
      '等待……',
      'Wait...',
      'U.S.',
      '3.14',
      'https://example.com',
      'e.g.',
      'Coptic\u2cfa',
    ]) {
      expect(apply(text, fullStops), text);
      expect(apply(text, stopsAndCommas), text);
    }
    expect(apply('Version 1.2.', fullStops), 'Version 1.2');
    expect(apply('Wait...', trailing), 'Wait');
  });
  test(
    'all punctuation removes Unicode marks but preserves scripts and emoji',
    () {
      expect(apply('你好，世界！', all), '你好世界');
      expect(apply("Don't re-enter: 3.14.", all), 'Dont reenter 314');
      expect(apply('¿Cómo estás? «Très bien!»', all), 'Cómo estás Très bien');
      expect(
        apply('الْعَرَبِيَّةُ، नَمَسْتे। 👨‍👩‍👧‍👦 #️⃣ ❤️！', all),
        'الْعَرَبِيَّةُ नَمَسْتे 👨‍👩‍👧‍👦 #️⃣ ❤️',
      );
      expect(apply('“مرحبا، بالعالم؟”', all), 'مرحبا بالعالم');
    },
  );
  test(
    'word timings survive UTF-16 punctuation removal and file round trips',
    () {
      const text = '“你，好🙂。”';
      final original = cue(text).copyWith(
        timedSpans: const [
          SubtitleTimedSpan(
            textStart: 1,
            textEnd: 2,
            startTime: Duration.zero,
            endTime: Duration(seconds: 1),
            role: 'aligned',
          ),
          SubtitleTimedSpan(
            textStart: 3,
            textEnd: 4,
            startTime: Duration(seconds: 1),
            endTime: Duration(seconds: 2),
            agentId: 'A',
          ),
          SubtitleTimedSpan(
            textStart: 4,
            textEnd: 6,
            startTime: Duration(seconds: 2),
            endTime: Duration(seconds: 3),
          ),
        ],
      );
      final result = applySubtitlePunctuation(original, all);
      expect(result.text, '你好🙂');
      expect(
        result.timedSpans.map(
          (s) => result.text.substring(s.textStart, s.textEnd),
        ),
        ['你', '好', '🙂'],
      );
      for (var i = 0; i < result.timedSpans.length; i++) {
        expect(
          result.timedSpans[i].startTime,
          original.timedSpans[i].startTime,
        );
        expect(result.timedSpans[i].endTime, original.timedSpans[i].endTime);
      }
      expect(result.index, original.index);
      expect(result.asrInfo, same(original.asrInfo));
      final srt = encodeStreamingSrt([result]);
      final restored = SubtitleWordTimingStore.decode(
        srt,
        SubtitleWordTimingStore.encode(srt, [result]),
        SubtitleParser.parse(srt),
      );
      expect(restored.single.text, result.text);
      expect(restored.single.timedSpans, result.timedSpans);
    },
  );
  test('punctuation-only rows keep their stable ordinal and empty output', () {
    final rows = [cue('？！'), cue('正文。').copyWith(index: 2)];
    final output = [
      for (final item in rows) applySubtitlePunctuation(item, all),
    ];
    expect(output.map((c) => c.index), [1, 2]);
    final loaded = SubtitleParser.parse(encodeStreamingSrt(output));
    expect(loaded.map((c) => c.text), ['', '正文']);
    expect(loaded.map((c) => c.index), [1, 2]);
  });
  test('formatting tags are preserved while their visible text is cleaned', () {
    expect(apply('<i>“Hello, world.”</i>', fullStops), '<i>“Hello, world”</i>');
    expect(apply('<b>你好，世界！</b>', all), '<b>你好世界</b>');
    expect(apply(r'{\an8}你好，世界。', all), r'{\an8}你好世界');
    expect(apply('Price < 5.0.', fullStops), 'Price < 5.0');
  });
  test('output modes are idempotent across multilingual mixtures', () {
    for (final text in [
      ...languages.keys,
      '“Hello, 世界！”',
      '👋🏽。',
      '？！',
      'first.\nsecond?',
      'a\u0301.',
      'text\u{1da88}',
      '“你好，世界🙂，。”',
      'مرحبا،',
    ]) {
      for (final mode in SubtitlePunctuation.values) {
        final once = applySubtitlePunctuation(cue(text), mode);
        expect(applySubtitlePunctuation(once, mode).text, once.text);
      }
    }
  });
}
