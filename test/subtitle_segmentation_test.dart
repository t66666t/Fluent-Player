import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_token_timing.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/transcription_reliability.dart';

SubtitleItem _glyphCue(String text, {int tick = 200, int offset = 0}) {
  final spans = <SubtitleTimedSpan>[];
  var at = 0;
  for (final glyph in text.characters) {
    spans.add(
      SubtitleTimedSpan(
        textStart: at,
        textEnd: at + glyph.length,
        startTime: Duration(milliseconds: offset + spans.length * tick),
        endTime: Duration(milliseconds: offset + (spans.length + 1) * tick),
        role: 'token',
      ),
    );
    at += glyph.length;
  }
  return SubtitleItem(
    index: 1,
    startTime: Duration(milliseconds: offset),
    endTime: Duration(milliseconds: offset + spans.length * tick),
    text: text,
    timedSpans: spans,
  );
}

void _valid(List<SubtitleItem> cues) {
  for (var i = 0; i < cues.length; i++) {
    final cue = cues[i];
    expect(cue.index, i + 1);
    expect(cue.endTime, greaterThan(cue.startTime));
    if (i > 0) expect(cue.startTime, greaterThanOrEqualTo(cues[i - 1].endTime));
    final boundaries = <int>{0};
    var at = 0;
    for (final glyph in cue.text.characters) {
      at += glyph.length;
      boundaries.add(at);
    }
    for (final span in cue.timedSpans) {
      expect(span.isValidFor(cue.text), isTrue);
      expect(boundaries, containsAll([span.textStart, span.textEnd]));
      expect(span.startTime, greaterThanOrEqualTo(cue.startTime));
      expect(span.endTime, lessThanOrEqualTo(cue.endTime));
    }
  }
}

void main() {
  test(
    'automatic refinement accepts complete native timing and rejects coarse or incomplete timing',
    () {
      final cue = _glyphCue('A complete sentence with native time.', tick: 60);
      expect(hasUsableAsrTiming(cue), isTrue);
      expect(
        hasUsableAsrTiming(cue.copyWith(timedSpans: cue.timedSpans.sublist(1))),
        isFalse,
      );
      expect(
        hasUsableAsrTiming(
          cue.copyWith(
            timedSpans: [
              SubtitleTimedSpan(
                textStart: 0,
                textEnd: cue.text.length,
                startTime: cue.startTime,
                endTime: cue.endTime,
              ),
            ],
          ),
        ),
        isFalse,
      );
    },
  );
  test('TDT zero-duration frame groups retain text and remain atomic', () {
    const text = 'The country. We agree.';
    final spans = alignModelTokens(
      text: text,
      tokens: ['The', ' coun', 'tr', 'y', '.', ' We', ' agree', '.'],
      starts: [0, .4, .8, 1, 1, 1.4, 1.8, 2.4],
      ends: [.4, .8, 1, 1, 1.4, 1.8, 2.4, 2.5],
      cueEnd: 2.6,
    );
    expect(spans, hasLength(8));
    expect(spans[3].startTime, const Duration(seconds: 1));
    expect(spans[3].endTime, const Duration(milliseconds: 1400));
    final source = SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: const Duration(milliseconds: 2600),
      text: text,
      timedSpans: spans,
    );
    final result = segmentAsrSubtitles([
      source,
    ], SubtitleSegmentationOptions.natural);
    expect(result.map((c) => c.text).join(' '), text);
    expect(result.any((c) => c.text.contains('country.')), isTrue);
    _valid(result);
  });

  test('equal native onsets without durations keep complete English words', () {
    final spans = alignModelTokens(
      text: 'We agree.',
      tokens: ['We', ' ag', 'ree', '.'],
      starts: [0, .4, .4, 1],
      cueEnd: 1.2,
    );
    expect(spans, hasLength(4));
    expect(spans[1].startTime, spans[2].startTime);
    expect(spans[1].endTime, const Duration(seconds: 1));
  });

  test(
    'natural English captions prefer clauses instead of a 40-character cut',
    () {
      final source = _glyphCue(
        'I think we should start with the basic question of what this means, because there is an important distinction that people often miss.',
        tick: 50,
      );
      final result = segmentAsrSubtitles([
        source,
      ], SubtitleSegmentationOptions.natural);
      expect(result, hasLength(2));
      expect(result.first.text, endsWith('means,'));
      expect(result.last.text, startsWith('because'));
      expect(result.map((c) => c.text).join(' '), source.text);
      _valid(result);
    },
  );

  test(
    'natural grouping reconnects adjacent VAD fragments with reliable times',
    () {
      final source = [
        _glyphCue('When you look at', tick: 70),
        _glyphCue('the whole picture,', tick: 70, offset: 1200),
        _glyphCue('the answer becomes clear.', tick: 70, offset: 2600),
      ];
      final result = segmentAsrSubtitles(
        source,
        SubtitleSegmentationOptions.natural,
      );
      expect(result, hasLength(1));
      expect(
        result.single.text,
        'When you look at the whole picture, the answer becomes clear.',
      );
      expect(
        result.single.timedSpans.length,
        source.fold(0, (n, c) => n + c.timedSpans.length),
      );
      _valid(result);
    },
  );

  test(
    'natural segmentation avoids hanging English function words and orphan tails',
    () {
      final source = _glyphCue(
        'We should look at the important reasons why this approach is useful for everyone today.',
        tick: 75,
      );
      final result = segmentAsrSubtitles([
        source,
      ], SubtitleSegmentationOptions.natural.copyWith(maxLatinWidth: 56));
      expect(result.length, greaterThan(1));
      expect(result.map((c) => c.text).join(' '), source.text);
      for (final cue in result) {
        expect(
          RegExp(
            r'\b(the|a|an|to|of|for|with|at)$',
            caseSensitive: false,
          ).hasMatch(cue.text),
          isFalse,
        );
        expect(cue.text.split(' ').length, greaterThan(2));
      }
      _valid(result);
    },
  );

  test(
    'natural regrouping respects long silence and does not fabricate word timings',
    () {
      SubtitleItem untimed(String text, int start, int end) => SubtitleItem(
        index: 1,
        startTime: Duration(milliseconds: start),
        endTime: Duration(milliseconds: end),
        text: text,
      );
      final result = segmentAsrSubtitles([
        untimed('I think', 0, 500),
        untimed('we can begin.', 650, 1900),
        untimed('A new topic.', 4000, 5300),
      ], SubtitleSegmentationOptions.natural);
      expect(result.map((c) => c.text), [
        'I think we can begin.',
        'A new topic.',
      ]);
      expect(result.every((c) => c.timedSpans.isEmpty), isTrue);
      _valid(result);
    },
  );

  test('only old recommended preferences migrate to natural captions', () {
    final old = {...SubtitleSegmentationOptions.short.toJson(), 'version': 1};
    expect(
      SubtitleSegmentationOptions.fromJson(old, migrateDefaults: true),
      SubtitleSegmentationOptions.natural,
    );
    expect(
      SubtitleSegmentationOptions.fromJson(old),
      SubtitleSegmentationOptions.short,
    );
    expect(
      SubtitleSegmentationOptions.fromJson(
        SubtitleSegmentationOptions.short.toJson(),
        migrateDefaults: true,
      ),
      SubtitleSegmentationOptions.short,
    );
    final custom = {...old, 'maxWidth': 56};
    expect(
      SubtitleSegmentationOptions.fromJson(
        custom,
        migrateDefaults: true,
      ).maxWidth,
      56,
    );
  });

  test(
    'join VAD continuations before an isolated phrase receives punctuation',
    () {
      final first = _glyphCue('Ask not', tick: 100, offset: 3500);
      final next = _glyphCue(
        'What your country can do for you.',
        tick: 65,
        offset: 5300,
      );
      final prepared = joinAsrContinuations([
        first,
        next,
      ], SubtitleSegmentationOptions.natural).toList();
      expect(prepared, hasLength(1));
      expect(prepared.single.text, 'Ask not What your country can do for you.');
      final captions = segmentAsrSubtitles(
        prepared,
        SubtitleSegmentationOptions.natural,
      );
      expect(captions, hasLength(1));
      _valid(captions);
    },
  );
  test('continuous Chinese uses display width and real token times', () {
    final source = _glyphCue(
      '这是一段连续讲话用来检查字幕分句在没有标点符号的情况下也能保持合适长度并且保留完整文字和正确的时间轴' * 2,
    );
    final cues = segmentAsrSubtitles([
      source,
    ], SubtitleSegmentationOptions.short);
    expect(cues.length, greaterThan(4));
    expect(cues.map((c) => c.text).join(), source.text);
    expect(cues.every((c) => c.text.characters.length <= 20), isTrue);
    expect(
      cues.every((c) => (c.endTime - c.startTime).inMilliseconds <= 4000),
      isTrue,
    );
    expect(cues.first.startTime, source.startTime);
    expect(cues.last.endTime, source.endTime);
    _valid(cues);
  });

  test(
    'sentence punctuation includes closing quotes and rebases token ranges',
    () {
      final source = _glyphCue('欢迎来到这里。”接下来我们查看字幕，确认长句可以自然拆分。', offset: 90000);
      final cues = segmentAsrSubtitles([
        source,
      ], SubtitleSegmentationOptions.standard);
      expect(cues.first.text, '欢迎来到这里。”');
      expect(cues[1].text, startsWith('接下来'));
      expect(cues.map((c) => c.text).join(), source.text);
      expect(cues[1].timedSpans.first.textStart, 0);
      expect(cues[1].timedSpans.first.startTime.inMilliseconds, 91600);
      _valid(cues);
    },
  );

  test(
    'native subwords never split an English word, decimal or abbreviation',
    () {
      final source = _glyphCue(
        'Dr. Smith paid 3.14 dollars. That extraordinarilylongword stays whole.',
        tick: 100,
      );
      final cues = segmentAsrSubtitles([
        source,
      ], const SubtitleSegmentationOptions(maxWidth: 24, maxDurationMs: 12000));
      expect(cues.map((c) => c.text).join(' '), source.text);
      expect(cues.first.text, startsWith('Dr. Smith'));
      expect(cues.any((c) => c.text.contains('3.14')), isTrue);
      expect(
        cues.any((c) => c.text.contains('extraordinarilylongword')),
        isTrue,
      );
      _valid(cues);
    },
  );

  test('punctuation can be disabled independently of length targets', () {
    final source = _glyphCue('这是第一句话。这是第二句话。');
    final enabled = segmentAsrSubtitles([
      source,
    ], SubtitleSegmentationOptions.standard);
    final disabled = segmentAsrSubtitles(
      [source],
      SubtitleSegmentationOptions.standard.copyWith(splitOnPunctuation: false),
    );
    expect(enabled, hasLength(2));
    expect(disabled, hasLength(1));
  });

  test(
    'Latin width applies to custom settings even without natural regrouping',
    () {
      final source = _glyphCue(
        'We want to read the complete sentence with fewer breaks and keep every word.',
        tick: 60,
      );
      const options = SubtitleSegmentationOptions(
        maxDurationMs: 12000,
        maxWidth: 40,
        maxLatinWidth: 80,
        splitOnPunctuation: false,
      );
      expect(segmentAsrSubtitles([source], options), hasLength(1));
      expect(
        segmentAsrSubtitles([
          source,
        ], SubtitleSegmentationOptions.short.copyWith(maxDurationMs: 12000)),
        hasLength(greaterThan(1)),
      );
    },
  );

  test('duration target applies even to slow speech with little text', () {
    final source = _glyphCue('让我们慢慢说话保持字幕简短', tick: 700);
    final cues = segmentAsrSubtitles([
      source,
    ], SubtitleSegmentationOptions.short);
    expect(cues.length, greaterThan(2));
    expect(cues.map((c) => c.text).join(), source.text);
    expect(
      cues.every((c) => (c.endTime - c.startTime).inMilliseconds <= 4000),
      isTrue,
    );
    _valid(cues);
  });

  test('one atomic model token may exceed the target without losing text', () {
    final source = SubtitleItem(
      index: 1,
      startTime: Duration.zero,
      endTime: const Duration(seconds: 9),
      text: '这是一个不可拆开的模型词块必须保持完整。',
      timedSpans: const [
        SubtitleTimedSpan(
          textStart: 0,
          textEnd: 20,
          startTime: Duration.zero,
          endTime: Duration(seconds: 9),
        ),
      ],
    );
    final cues = segmentAsrSubtitles([
      source,
    ], SubtitleSegmentationOptions.short);
    expect(cues, hasLength(1));
    expect(cues.single.text, source.text);
  });

  test(
    'untimed and partial alignments stay intact unless estimates are enabled',
    () {
      final timed = _glyphCue('这是一条没有完整词级时间的字幕所以默认不能假装已经获得准确的断句时间轴');
      for (final spans in [
        <SubtitleTimedSpan>[],
        timed.timedSpans.sublist(5),
      ]) {
        final source = timed.copyWith(timedSpans: spans);
        expect(
          segmentAsrSubtitles([
            source,
          ], SubtitleSegmentationOptions.short).single.text,
          source.text,
        );
        final estimated = segmentAsrSubtitles(
          [source],
          SubtitleSegmentationOptions.short.copyWith(
            allowEstimatedTiming: true,
          ),
        );
        expect(estimated.length, greaterThan(1));
        expect(estimated.map((c) => c.text).join(), source.text);
        expect(estimated.every((c) => c.timedSpans.isEmpty), isTrue);
        _valid(estimated);
      }
    },
  );

  test('graphemes survive emoji sequences and combining characters', () {
    final source = _glyphCue(
      '字幕测试👨‍👩‍👧‍👦继续检查中文和e\u0301组合字符以及𝄞音乐符号不被截断。' * 2,
    );
    final cues = segmentAsrSubtitles([
      source,
    ], SubtitleSegmentationOptions.short);
    expect(cues.length, greaterThan(1));
    expect(cues.map((c) => c.text).join(), source.text);
    expect(cues.any((c) => c.text.contains('👨‍👩‍👧‍👦')), isTrue);
    expect(cues.any((c) => c.text.contains('e\u0301')), isTrue);
    _valid(cues);
  });

  test('non-monotonic times and tokens inside graphemes are not trusted', () {
    final source = _glyphCue('这条字幕会使用不可靠的时间信息进行检查。');
    final reversed = source.copyWith(
      timedSpans: source.timedSpans.reversed.toList(),
    );
    expect(
      segmentAsrSubtitles([
        reversed,
      ], SubtitleSegmentationOptions.short).single.text,
      source.text,
    );
    final unicode = _glyphCue('👨‍👩‍👧‍👦这是没有完整字素时间范围的测试字幕');
    final broken = unicode.copyWith(
      timedSpans: [
        const SubtitleTimedSpan(
          textStart: 0,
          textEnd: 1,
          startTime: Duration.zero,
          endTime: Duration(milliseconds: 200),
        ),
        ...unicode.timedSpans.skip(1),
      ],
    );
    expect(
      segmentAsrSubtitles([
        broken,
      ], SubtitleSegmentationOptions.short).single.text,
      unicode.text,
    );
  });

  test('markup and structured lyrics are preserved', () {
    final source = _glyphCue('<b>这是带标签的文字。需要保持标签完整。</b>');
    expect(
      segmentAsrSubtitles([
        source,
      ], SubtitleSegmentationOptions.short).single.text,
      source.text,
    );
    expect(
      identical(
        segmentAsrSubtitles([
          source,
        ], SubtitleSegmentationOptions.original).single,
        source,
      ),
      isTrue,
    );
  });

  test('trailing short text does not become a flashing cue', () {
    final source = _glyphCue('字幕不能在句子末尾留下闪烁的短词。', tick: 150);
    final cues = segmentAsrSubtitles([
      source,
    ], const SubtitleSegmentationOptions(maxDurationMs: 2000, maxWidth: 24));
    expect(cues.map((c) => c.text).join(), source.text);
    expect(
      cues.every(
        (c) => c.endTime - c.startTime >= const Duration(milliseconds: 800),
      ),
      isTrue,
    );
    _valid(cues);
  });

  test(
    'slice deduplication runs before regrouping and preserves absolute times',
    () {
      final source = _glyphCue('前一个切片已经识别了这一段内容。后面的文字属于接下来的短句。');
      final merged = TranscriptionSubtitleMerger.finish([
        ...TranscriptionSubtitleMerger.placeSlice(
          relative: [source],
          sliceStart: const Duration(minutes: 2),
          overlap: Duration.zero,
          sliceLength: const Duration(minutes: 2),
        ),
        ...TranscriptionSubtitleMerger.placeSlice(
          relative: [source],
          sliceStart: const Duration(minutes: 2),
          overlap: Duration.zero,
          sliceLength: const Duration(minutes: 2),
        ),
      ]);
      final cues = segmentAsrSubtitles(
        merged,
        SubtitleSegmentationOptions.short,
      );
      expect(cues.map((c) => c.text).join(), source.text);
      expect(cues.first.startTime, const Duration(minutes: 2));
      _valid(cues);
    },
  );

  test('job snapshots freeze grouping without invalidating raw ASR cache', () {
    const profile = ModelServiceProfile(
      id: 'local:test',
      name: 'test',
      kind: TranscriptionServiceKind.local,
      model: 'test',
    );
    const oldJob = ModelJobSpec(profile: profile, artifactIdentity: 'revision');
    const shortJob = ModelJobSpec(
      profile: profile,
      artifactIdentity: 'revision',
      subtitleSegmentation: SubtitleSegmentationOptions.short,
    );
    const standardJob = ModelJobSpec(
      profile: profile,
      artifactIdentity: 'revision',
      subtitleSegmentation: SubtitleSegmentationOptions.standard,
    );
    expect(
      ModelJobSpec.fromJson(
        jsonDecode(jsonEncode(oldJob.toJson())),
      ).fingerprint,
      oldJob.fingerprint,
    );
    expect(
      ModelJobSpec.fromJson(
        jsonDecode(jsonEncode(shortJob.toJson())),
      ).subtitleSegmentation,
      SubtitleSegmentationOptions.short,
    );
    expect(shortJob.fingerprint, isNot(standardJob.fingerprint));
    expect(shortJob.recognitionFingerprint, standardJob.recognitionFingerprint);
    expect(shortJob.recognitionFingerprint, oldJob.recognitionFingerprint);
    expect(
      jsonDecode(shortJob.recognitionFingerprint),
      isNot(contains('translation')),
    );
    expect(shortJob.recognitionCacheFingerprints, contains(oldJob.fingerprint));
    expect(
      const ModelJobSpec(
        profile: profile,
        artifactIdentity: 'different',
      ).recognitionFingerprint,
      isNot(oldJob.recognitionFingerprint),
    );
  });

  test('grouping runs in its own isolate', () async {
    final source = _glyphCue('这是一段用来检查后台处理的字幕文本。它应该能够分成更短的字幕。');
    final cues = await segmentAsrSubtitlesAsync([
      source,
    ], SubtitleSegmentationOptions.short);
    expect(cues.length, greaterThan(1));
    expect(cues.map((c) => c.text).join(), source.text);
    _valid(cues);
  });
}
