import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/local_asr_boundary.dart';
import 'package:video_player_app/features/model_center/streaming_subtitle_assembler.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_asr_info.dart';
import 'package:video_player_app/models/subtitle_model.dart';

SubtitleItem cue(int start, int end, String text, {String speaker = ''}) =>
    SubtitleItem(
      index: 0,
      startTime: Duration(milliseconds: start),
      endTime: Duration(milliseconds: end),
      text: text,
      asrInfo: SubtitleAsrInfo(speaker: speaker),
    );

void main() {
  test(
    'Chinese suffix and prefix in overlapping windows are published only once',
    () {
      final merged = stitchLocalAsrBoundary(
        [cue(26000, 30000, '今天先介绍第一部分。')],
        [cue(28000, 33000, '第一部分，然后继续讨论。')],
      );
      expect(merged, hasLength(1));
      expect(merged.single.text, '今天先介绍第一部分，然后继续讨论。');
      expect(merged.single.startTime, const Duration(seconds: 26));
      expect(merged.single.endTime, const Duration(seconds: 33));
    },
  );

  test(
    'English boundary matching keeps whole words and preserves novel text',
    () {
      final merged = stitchLocalAsrBoundary(
        [cue(26000, 30000, 'We will discuss the next topic')],
        [cue(28000, 33000, 'the next topic in more detail.')],
      );
      expect(
        merged.single.text,
        'We will discuss the next topic in more detail.',
      );
      final repeated = stitchLocalAsrBoundary(
        [cue(0, 1000, 'Thank you')],
        [cue(1200, 2000, 'Thank you')],
      );
      expect(repeated, hasLength(2));
    },
  );

  test('word offsets survive removal of a duplicate prefix', () {
    final a = cue(26000, 30000, '我们讲第一部分').copyWith(
      timedSpans: [
        const SubtitleTimedSpan(
          textStart: 0,
          textEnd: 7,
          startTime: Duration(seconds: 26),
          endTime: Duration(seconds: 30),
        ),
      ],
    );
    final b = cue(28000, 33000, '第一部分然后继续').copyWith(
      timedSpans: [
        const SubtitleTimedSpan(
          textStart: 0,
          textEnd: 4,
          startTime: Duration(seconds: 28),
          endTime: Duration(seconds: 30),
        ),
        const SubtitleTimedSpan(
          textStart: 4,
          textEnd: 8,
          startTime: Duration(seconds: 30),
          endTime: Duration(seconds: 33),
        ),
      ],
    );
    final merged = stitchLocalAsrBoundary([a], [b]).single;
    expect(merged.text, '我们讲第一部分然后继续');
    expect(merged.timedSpans.last.textStart, 7);
    expect(merged.timedSpans.last.textEnd, merged.text.length);
    expect(merged.timedSpans.last.startTime, const Duration(seconds: 30));
  });

  test(
    'different boundary hypotheses do not leave overlapping caption intervals',
    () {
      final merged = stitchLocalAsrBoundary(
        [cue(26000, 30000, '第一句话')],
        [cue(29000, 33000, '接下来是新的内容')],
      );
      expect(merged, hasLength(2));
      expect(merged[0].endTime, merged[1].startTime);
      expect(merged[0].text, '第一句话');
      expect(merged[1].text, '接下来是新的内容');
    },
  );

  test('known speakers and repetitions inside one window remain distinct', () {
    expect(
      stitchLocalAsrBoundary(
        [cue(0, 3000, '你好', speaker: 'A')],
        [cue(1000, 2000, '你好', speaker: 'B')],
      ),
      hasLength(2),
    );
    expect(
      stitchLocalAsrBoundary([], [cue(0, 1000, '你好'), cue(1200, 2000, '你好')]),
      hasLength(2),
    );
  });

  test(
    'boundary repair changes only the unpublished tail; a silent EOF flushes it',
    () async {
      final assembler = StreamingSubtitleAssembler(
        SubtitleSegmentationOptions.original,
        version: 2,
      );
      final first = await assembler.add([
        cue(0, 2000, '已发布'),
        cue(27000, 30000, '我们介绍第一部分'),
      ], stableBefore: const Duration(seconds: 28));
      expect(first.map((c) => c.text), ['已发布']);
      final next = await assembler.add([
        cue(28000, 33000, '第一部分然后继续'),
      ], stableBefore: const Duration(seconds: 56));
      expect(next.single.text, '我们介绍第一部分然后继续');
      expect(next.single.index, 2);
      expect(first.single.text, '已发布');
      expect(
        await assembler.add(
          [],
          stableBefore: const Duration(seconds: 60),
          endOfInput: true,
        ),
        isEmpty,
      );
    },
  );

  test(
    'legacy generations retain their original ordinal assembly on resume',
    () async {
      final old = StreamingSubtitleAssembler(
        SubtitleSegmentationOptions.original,
        version: 1,
      );
      final next = StreamingSubtitleAssembler(
        SubtitleSegmentationOptions.original,
      );
      final input = [cue(0, 1000, 'Thank you'), cue(1200, 2000, 'Thank you')];
      expect(
        await old.add(
          input,
          stableBefore: const Duration(seconds: 30),
          endOfInput: true,
        ),
        hasLength(1),
      );
      expect(
        await next.add(
          input,
          stableBefore: const Duration(seconds: 30),
          endOfInput: true,
        ),
        hasLength(2),
      );
    },
  );
}
