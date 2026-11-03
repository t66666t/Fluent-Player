import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/models/subtitle_punctuation.dart';
import 'package:video_player_app/services/streaming_subtitle_store.dart';
import 'package:video_player_app/services/subtitle_output_preparer.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import 'package:video_player_app/utils/subtitle_parser.dart';

import 'support/subtitle_punctuation_reference.dart' as reference;

class _BrokenInfo extends SubtitleAsrInfo {
  const _BrokenInfo() : super(language: 'en');
  @override
  Map<String, Object> toJson() =>
      throw StateError('simulated worker encoding failure');
}

class _ProbedInfo extends SubtitleAsrInfo {
  const _ProbedInfo({super.notes}) : super(language: 'zh');
  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'encodingIsolate': Isolate.current.hashCode,
  };
}

SubtitleItem cue(int i) => SubtitleItem(
  index: 100 + i,
  startTime: Duration(milliseconds: i * 3456),
  endTime: Duration(milliseconds: i * 3456 + 2345),
  text: i.isEven ? '“Hello, 世界🙂。”' : 'مرحبا، بالعالم؟',
  asrInfo: i % 3 == 0
      ? const SubtitleAsrInfo(language: 'auto', reviewReason: 'review')
      : const SubtitleAsrInfo(),
  timedSpans: i.isEven
      ? [
          SubtitleTimedSpan(
            textStart: 1,
            textEnd: 6,
            startTime: Duration(milliseconds: i * 3456),
            endTime: Duration(milliseconds: i * 3456 + 500),
            role: 'aligned',
          ),
        ]
      : const [],
);

// These baseline fixtures end in a full stop or question mark, so the new mode
// has the same expected output as the frozen full-stop-only rule. Comma output
// across worker batches is checked separately below.
reference.SubtitlePunctuation referenceMode(SubtitlePunctuation mode) =>
    mode == SubtitlePunctuation.removeTrailingFullStopsAndCommas
    ? reference.SubtitlePunctuation.removeTrailingFullStops
    : reference.SubtitlePunctuation.values.byName(mode.name);

void main() {
  const preparer = SubtitleOutputPreparer();
  for (final count in [0, 2, 64, 257]) {
    for (final mode in SubtitlePunctuation.values) {
      test(
        'prepared transcript/companion matches previous bytes: $count / ${mode.name}',
        () async {
          final source = List.generate(count, cue);
          final before = source.map((c) => c.toTimingJson()).toList();
          final expected = [
            for (var i = 0; i < source.length; i++)
              reference
                  .applySubtitlePunctuation(source[i], referenceMode(mode))
                  .copyWith(index: i + 1),
          ];
          final expectedSrt = encodeStreamingSrt(expected);
          final result = await preparer.transcript(
            source,
            mode,
            keepTranslationInput: true,
          );
          expect(result.srt, expectedSrt);
          expect(
            result.translationInput,
            encodeStreamingSrt([
              for (var i = 0; i < source.length; i++)
                source[i].copyWith(index: i + 1),
            ]),
          );
          if (source.isEmpty) {
            expect(result.wordTiming, isNull);
          } else {
            expect(
              jsonDecode(result.wordTiming!),
              jsonDecode(SubtitleWordTimingStore.encode(expectedSrt, expected)),
            );
            final parsed = await preparer.parse(result.srt);
            final attached = SubtitleWordTimingStore.decode(
              result.srt,
              result.wordTiming!,
              parsed,
            );
            // Plain SRT parsing strips formatting quotes only when they are tags;
            // the generated test text contains literal Unicode quotes.
            expect(
              attached.map((c) => c.toTimingJson()),
              expected.map((c) => c.toTimingJson()),
            );
          }
          expect(source.map((c) => c.toTimingJson()), before);
        },
      );
    }
  }
  for (final eol in ['\n', '\r\n']) {
    test(
      'translated output preserves numbered timing, trims only output, and obeys EOL $eol',
      () async {
        final source = List.generate(96, cue);
        final translations = [
          for (var i = 0; i < source.length; i++) '  你好，世界。  ',
        ];
        for (final mode in SubtitlePunctuation.values) {
          final srt = await preparer.translation(
            source,
            translations,
            mode,
            lineEnding: eol,
          );
          final expected = [
            for (var i = 0; i < source.length; i++)
              source[i].copyWith(
                index: i + 1,
                text: reference
                    .applySubtitlePunctuation(
                      source[i].copyWith(text: translations[i]),
                      referenceMode(mode),
                    )
                    .text
                    .trim(),
              ),
          ];
          expect(srt, encodeStreamingSrt(expected).replaceAll('\n', eol));
        }
        expect(translations.first, '  你好，世界。  ');
        expect(
          () => preparer.translation(source, [], SubtitlePunctuation.preserve),
          throwsStateError,
        );
      },
    );
  }
  test(
    'comma output preserves word timing and raw input across worker batches',
    () async {
      final source = List.generate(257, (i) {
        final original = cue(i);
        return original.copyWith(
          text: '“Hello, 世界🙂，”',
          timedSpans: original.timedSpans,
          asrInfo: original.asrInfo,
        );
      });
      final output = await preparer.transcript(
        source,
        SubtitlePunctuation.defaultValue,
        keepTranslationInput: true,
      );
      final parsed = SubtitleParser.parse(output.srt);
      expect(parsed.map((c) => c.text), everyElement('“Hello, 世界🙂”'));
      expect(parsed.map((c) => c.index), List.generate(257, (i) => i + 1));
      expect(
        SubtitleParser.parse(output.translationInput!).map((c) => c.text),
        everyElement('“Hello, 世界🙂，”'),
      );
      final attached = SubtitleWordTimingStore.decode(
        output.srt,
        output.wordTiming!,
        parsed,
      );
      expect(attached.first.timedSpans.single.textStart, 1);
      expect(attached.first.timedSpans.single.textEnd, 6);
      final translated = SubtitleParser.parse(
        await preparer.translation(
          source,
          List.filled(257, '你好，世界，'),
          SubtitlePunctuation.defaultValue,
        ),
      );
      expect(translated.map((c) => c.text), everyElement('你好，世界'));
    },
  );
  test(
    'large preparation and parsing leave the event loop available',
    () async {
      final source = List.generate(10000, cue);
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        ticks++;
      });
      try {
        final output = await preparer.transcript(
          source,
          SubtitlePunctuation.removeAll,
        );
        expect(ticks, greaterThan(0));
        ticks = 0;
        final parsed = await preparer.parse(output.srt);
        expect(ticks, greaterThan(0));
        expect(parsed, hasLength(source.length));
        expect(parsed.first.text, 'Hello 世界🙂');
        expect(parsed.last.index, source.length);
        expect(output.translationInput, isNull);
      } finally {
        timer.cancel();
      }
    },
  );
  test(
    'one enormous cue takes the worker path and no metadata means no companion',
    () async {
      final output = await preparer.transcript([
        SubtitleItem(
          index: 1,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 30),
          text: '正文，' * 30000,
        ),
      ], SubtitlePunctuation.removeAll);
      expect(output.wordTiming, isNull);
      expect(SubtitleParser.parse(output.srt).single.text, '正文' * 30000);
    },
  );
  test('large review metadata is prepared away from the caller', () async {
    final source = cue(
      0,
    ).copyWith(asrInfo: _ProbedInfo(notes: List.filled(1000, '复核内容' * 40)));
    final result = await preparer.transcript([
      source,
    ], SubtitlePunctuation.removeTrailingFullStops);
    expect(
      jsonDecode(result.wordTiming!)['cues'].single['asr']['encodingIsolate'],
      isNot(Isolate.current.hashCode),
    );
    expect(
      jsonDecode(result.wordTiming!)['cues'].single['asr']['notes'],
      source.asrInfo.notes,
    );
  });
  test('worker errors propagate and the next job still completes', () async {
    final source = List.generate(512, cue);
    source[source.length - 1] = source.last.copyWith(
      asrInfo: const _BrokenInfo(),
    );
    await expectLater(
      preparer
          .transcript(source, SubtitlePunctuation.preserve)
          .timeout(const Duration(seconds: 5)),
      throwsA(isA<RemoteError>()),
    );
    final result = await preparer.transcript(
      List.generate(512, cue),
      SubtitlePunctuation.removeAll,
    );
    expect(SubtitleParser.parse(result.srt), hasLength(512));
  });
  test(
    'failed dispatch closes its worker without poisoning later jobs',
    () async {
      final port = ReceivePort();
      try {
        final source = List.generate(512, cue);
        source[0] = SubtitleItem(
          index: 1,
          startTime: Duration.zero,
          endTime: const Duration(seconds: 1),
          text: 'Hello.',
          imageLoader: () async {
            port.sendPort.send(1);
            return null;
          },
        );
        await expectLater(
          preparer
              .transcript(source, SubtitlePunctuation.preserve)
              .timeout(const Duration(seconds: 5)),
          throwsArgumentError,
        );
      } finally {
        port.close();
      }
      final result = await preparer.translation(
        List.generate(512, cue),
        List.filled(512, '你好。'),
        SubtitlePunctuation.removeAll,
      );
      expect(SubtitleParser.parse(result).last.text, '你好');
    },
  );
}
