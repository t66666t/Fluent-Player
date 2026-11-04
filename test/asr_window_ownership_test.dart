import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/asr_window_ownership.dart';
import 'package:video_player_app/features/model_center/streaming_subtitle_assembler.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/subtitle_timeline_resolver.dart';

Duration ms(int value) => Duration(milliseconds: value);
SubtitleItem cue(
  int start,
  int end,
  String text, {
  List<SubtitleTimedSpan> spans = const [],
}) => SubtitleItem(
  index: 0,
  startTime: ms(start),
  endTime: ms(end),
  text: text,
  timedSpans: spans,
);
SubtitleTimedSpan word(int from, int to, int start, int end) =>
    SubtitleTimedSpan(
      textStart: from,
      textEnd: to,
      startTime: ms(start),
      endTime: ms(end),
      role: 'aligned',
    );

void main() {
  for (final engine in ['sensevoice', 'dolphin', 'parakeet', 'zipformer']) {
    for (final role in ['token', 'aligned']) {
      test(
        '$engine / $role: a phonetically different duplicate cannot steal the previous utterance',
        () async {
          final assembler = StreamingSubtitleAssembler(
            SubtitleSegmentationOptions.original,
          );
          final previous = cue(
            26000,
            29400,
            '咱还能谈谈吗？',
            spans: [
              word(0, 2, 26000, 27000),
              word(2, 4, 27000, 28100),
              word(4, 6, 28100, 29400),
            ],
          );
          expect(
            await assembler.add(
              [previous],
              stableBefore: ms(28000),
              windowStart: ms(0),
              windowEnd: ms(30000),
            ),
            isEmpty,
          );
          var repairs = 0;
          final result = await assembler.add(
            [
              cue(
                28100,
                34000,
                '看忙，接着说。',
                spans: [
                  for (final span in [
                    word(0, 1, 28100, 28600),
                    word(1, 2, 28600, 29200),
                    word(3, 4, 30200, 30900),
                    word(4, 5, 31000, 31800),
                    word(5, 6, 32000, 33700),
                  ])
                    SubtitleTimedSpan(
                      textStart: span.textStart,
                      textEnd: span.textEnd,
                      startTime: span.startTime,
                      endTime: span.endTime,
                      role: role,
                    ),
                ],
              ),
            ],
            stableBefore: ms(56000),
            windowStart: ms(28000),
            windowEnd: ms(58000),
            recognizeBoundary: (_, _) async {
              repairs++;
              return [];
            },
          );
          expect(result.map((c) => c.text), ['咱还能谈谈吗？', '接着说。']);
          expect(result.first.endTime, previous.endTime);
          expect(result.last.startTime, ms(30200));
          expect(result.last.timedSpans.first.textStart, 0);
          expect(result.last.timedSpans.last.textEnd, 3);
          expect(repairs, 0);
          final timeline = SubtitleTimelineResolver(result);
          expect(timeline.activeIndicesAtMs(28900), contains(0));
          expect(timeline.activeIndicesAtMs(28900), isNot(contains(1)));
        },
      );
    }
  }

  test(
    'coarse timing re-decodes one complete audio interval rather than guessing characters',
    () async {
      final requests = <(Duration, Duration)>[];
      final previous = cue(26000, 29400, '咱还能谈谈吗？');
      final result = await ownAsrWindow(
        held: [previous],
        incoming: [cue(28100, 34000, '看忙，接着说。'), cue(35000, 36000, '后面的内容')],
        windowStart: ms(28000),
        windowEnd: ms(58000),
        previousWindowEnd: ms(30000),
        publishedThrough: ms(25000),
        recognizeBoundary: (start, end) async {
          requests.add((start, end));
          return [previous, cue(30200, 34000, '接着说。')];
        },
      );
      expect(requests, [(ms(25800), ms(34200))]);
      expect(result.map((c) => c.text), ['咱还能谈谈吗？', '接着说。', '后面的内容']);
      expect(result.first.endTime, ms(29400));
    },
  );

  test(
    'a word cut at the end of the old window is decoded with the complete continuation',
    () async {
      var repairs = 0;
      final result = await ownAsrWindow(
        held: [cue(26000, 30000, '这个句子还没说')],
        incoming: [cue(28000, 34000, '还没说完，请听下一句。')],
        windowStart: ms(28000),
        windowEnd: ms(58000),
        previousWindowEnd: ms(30000),
        publishedThrough: ms(24000),
        recognizeBoundary: (start, end) async {
          repairs++;
          expect(start, ms(25800));
          return [cue(26000, 34000, '这个句子还没说完，请听下一句。')];
        },
      );
      expect(repairs, 1);
      expect(result.single.text, '这个句子还没说完，请听下一句。');
    },
  );

  test(
    'original VAD cut survives an enhancement that moves the displayed end earlier',
    () async {
      var repairs = 0;
      final result = await ownAsrWindow(
        held: [cue(26000, 29400, '咱还能谈谈')],
        incoming: [cue(28100, 34000, '看忙，接着说。')],
        windowStart: ms(28000),
        windowEnd: ms(58000),
        previousWindowEnd: ms(30000),
        previousWindowOpen: true,
        publishedThrough: ms(25000),
        recognizeBoundary: (_, _) async {
          repairs++;
          return [cue(26000, 30300, '咱还能谈谈吗？'), cue(30500, 34000, '接着说。')];
        },
      );
      expect(repairs, 1);
      expect(result.first.text, '咱还能谈谈吗？');
      expect(result.first.endTime, ms(30300));
    },
  );

  test(
    'a forcibly cut VAD utterance is held even when enhancement ends it before the normal frontier',
    () async {
      final assembler = StreamingSubtitleAssembler(
        SubtitleSegmentationOptions.original,
      );
      final pending = await assembler.add(
        [cue(24000, 27000, '这个句子还没说')],
        stableBefore: ms(28000),
        windowStart: ms(0),
        windowEnd: ms(30000),
        windowOpen: true,
      );
      expect(pending, isEmpty);
      final result = await assembler.add(
        [],
        stableBefore: ms(33000),
        windowStart: ms(28000),
        windowEnd: ms(35000),
        endOfInput: true,
        recognizeBoundary: (start, end) async {
          expect(end, ms(35000));
          return [cue(24000, 31000, '这个句子还没说完。')];
        },
      );
      expect(result.single.text, '这个句子还没说完。');
      expect(result.single.index, 1);
    },
  );

  test('actual repetitions at different acoustic times are retained', () async {
    final result = await ownAsrWindow(
      held: [cue(28000, 28500, '谈吗？')],
      incoming: [cue(29000, 30000, '谈吗？'), cue(31000, 32000, '谈吗？')],
      windowStart: ms(28000),
      windowEnd: ms(58000),
      previousWindowEnd: ms(30000),
      publishedThrough: ms(26000),
    );
    expect(result, hasLength(3));
  });

  test(
    'raw audio ownership catches a residual word whose enhanced timestamp drifted beyond the old cue',
    () async {
      final assembler = StreamingSubtitleAssembler(
        SubtitleSegmentationOptions.original,
      );
      expect(
        await assembler.add(
          [cue(24000, 27000, '咱还能谈谈吗？')],
          stableBefore: ms(28000),
          windowStart: ms(0),
          windowEnd: ms(30000),
          pendingAudioStart: ms(24000),
        ),
        isEmpty,
      );
      var repairs = 0;
      final result = await assembler.add(
        [cue(30200, 34000, '看忙，接着说。')],
        stableBefore: ms(56000),
        windowStart: ms(28000),
        windowEnd: ms(58000),
        overlapSpeech: true,
        recognizeBoundary: (_, _) async {
          repairs++;
          return [cue(24000, 29400, '咱还能谈谈吗？'), cue(30500, 34000, '接着说。')];
        },
      );
      expect(repairs, 1);
      expect(result.map((c) => c.text), ['咱还能谈谈吗？', '接着说。']);
      expect(SubtitleTimelineResolver(result).activeIndicesAtMs(28900), [0]);
    },
  );

  test(
    'a real next word inside VAD padding is kept and only proven silence is trimmed',
    () async {
      final result = await ownAsrWindow(
        held: [
          cue(
            26000,
            29400,
            '刚说完。',
            spans: [word(0, 1, 26000, 27000), word(1, 3, 27000, 29000)],
          ),
        ],
        incoming: [
          cue(
            29100,
            29800,
            '是的。',
            spans: [word(0, 1, 29100, 29300), word(1, 2, 29300, 29700)],
          ),
        ],
        windowStart: ms(28000),
        windowEnd: ms(58000),
        previousWindowEnd: ms(30000),
        publishedThrough: ms(25000),
      );
      expect(result.map((c) => c.text), ['刚说完。', '是的。']);
      expect(result.first.endTime, ms(29100));
      expect(result.last.timedSpans, hasLength(2));
      expect(SubtitleTimelineResolver(result).activeIndicesAtMs(29300), [1]);
    },
  );

  test(
    'failed or cancelled boundary recognition cannot advance publication',
    () async {
      final assembler = StreamingSubtitleAssembler(
        SubtitleSegmentationOptions.original,
      );
      await assembler.add(
        [cue(26000, 29400, '咱还能谈谈吗？')],
        stableBefore: ms(28000),
        windowStart: ms(0),
        windowEnd: ms(30000),
      );
      Future<List<SubtitleItem>> next(RecognizeAsrBoundary recognize) =>
          assembler.add(
            [cue(28100, 34000, '看忙，接着说。')],
            stableBefore: ms(56000),
            windowStart: ms(28000),
            windowEnd: ms(58000),
            recognizeBoundary: recognize,
          );
      await expectLater(
        next((_, _) async => throw StateError('cancelled')),
        throwsStateError,
      );
      await expectLater(next((_, _) async => []), throwsStateError);
      final resumed = await next(
        (_, _) async => [
          cue(26000, 29400, '咱还能谈谈吗？'),
          cue(30200, 34000, '接着说。'),
        ],
      );
      expect(resumed.map((c) => c.index), [1, 2]);
      expect(resumed.map((c) => c.text), ['咱还能谈谈吗？', '接着说。']);
    },
  );
}
