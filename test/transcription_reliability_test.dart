import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/transcription_reliability.dart';

void main() {
  SubtitleItem cue(int startMs, int endMs, String text) {
    return SubtitleItem(
      index: 0,
      startTime: Duration(milliseconds: startMs),
      endTime: Duration(milliseconds: endMs),
      text: text,
    );
  }

  test(
    'new task context survives persistence without changing legacy task keys',
    () {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1);
      checkpoint.remoteTasks['600000:590000:words'] = GongyiAsrTaskCheckpoint(
        taskId: 'submitted',
        leadingContext: const Duration(seconds: 10),
      );
      final restored = TranscriptionTaskCheckpoint.tryParse(
        jsonDecode(jsonEncode(checkpoint.toJson())),
      )!;
      final slice = TranscriptionSlicePlanner.nextUnfinished(
        start: const Duration(minutes: 10),
        duration: const Duration(minutes: 20),
        checkpoint: restored,
      )!;
      expect(slice.taskKey, '600000:590000:words');
      expect(slice.start, const Duration(minutes: 10));
      expect(slice.audioStart, const Duration(minutes: 9, seconds: 50));
      expect(slice.audioLength, const Duration(minutes: 10));
      expect(restored.remoteTasks[slice.taskKey]!.taskId, 'submitted');
      expect(GongyiAsrTaskCheckpoint.fromJson({'taskId': 'old'}).toJson(), {
        'taskId': 'old',
      });
    },
  );

  test(
    'context word timings remove repeated boundary words and retain new text',
    () {
      final prior = cue(599800, 600000, '上文').copyWith(
        timedSpans: const [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: 2,
            startTime: Duration(milliseconds: 599800),
            endTime: Duration(seconds: 600),
          ),
        ],
      );
      final relative = cue(9800, 11200, '上文新内容').copyWith(
        timedSpans: const [
          SubtitleTimedSpan(
            textStart: 0,
            textEnd: 2,
            startTime: Duration(milliseconds: 9800),
            endTime: Duration(milliseconds: 10200),
          ),
          SubtitleTimedSpan(
            textStart: 2,
            textEnd: 5,
            startTime: Duration(milliseconds: 10200),
            endTime: Duration(milliseconds: 11200),
          ),
        ],
      );
      final placed = TranscriptionSubtitleMerger.placeSlice(
        relative: [relative],
        sliceStart: const Duration(seconds: 590),
        sliceLength: const Duration(minutes: 10),
        overlap: Duration.zero,
        leadingContext: const Duration(seconds: 10),
        preceding: [prior],
      );
      expect(placed.single.text, '新内容');
      expect(placed.single.startTime, const Duration(milliseconds: 600200));
      expect(placed.single.timedSpans.single.textStart, 0);
      expect(placed.single.timedSpans.single.textEnd, 3);
      expect(
        placed.single.timedSpans.single.startTime,
        const Duration(milliseconds: 600200),
      );
      expect(
        TranscriptionSubtitleMerger.finish([
          prior,
          ...placed,
        ]).map((c) => c.text),
        ['上文', '新内容'],
      );
    },
  );

  test(
    'context without word timings trims only time-aligned duplicate prefixes',
    () {
      final prior = cue(595000, 600000, '共同片段');
      final placed = TranscriptionSubtitleMerger.placeSlice(
        relative: [
          cue(0, 9000, '共同片段'),
          cue(8000, 12000, '共同片段，后文'),
          cue(13000, 14000, '共同片段'),
        ],
        sliceStart: const Duration(seconds: 590),
        sliceLength: const Duration(minutes: 10),
        overlap: Duration.zero,
        leadingContext: const Duration(seconds: 10),
        preceding: [prior],
      );
      expect(placed.map((c) => c.text), ['后文', '共同片段']);
      expect(placed.first.startTime, const Duration(minutes: 10));
      expect(placed.last.startTime, const Duration(seconds: 603));
      final onlyDuplicate = TranscriptionSubtitleMerger.placeSlice(
        relative: [cue(8000, 11000, '共同片段。')],
        sliceStart: const Duration(seconds: 590),
        sliceLength: const Duration(minutes: 10),
        overlap: Duration.zero,
        leadingContext: const Duration(seconds: 10),
        preceding: [prior],
      );
      expect(onlyDuplicate, isEmpty);
    },
  );

  test(
    'short media stays one slice and long media stays within the safe length',
    () async {
      final short = TranscriptionTiming.durationFromProbe(
        seconds: 42,
        fileBytes: 999999,
      );
      expect(TranscriptionTiming.estimateSliceCount(short), 1);

      final slices = <TranscriptionSlice>[];
      final waits = <Duration>[];
      await SliceRecognitionSession.run(
        duration: const Duration(hours: 5),
        checkpoint: TranscriptionTaskCheckpoint.empty(1, 1),
        transcribe: (slice, label, onInner) async {
          slices.add(slice);
          onInner(0.5, '上传音频中');
          return [cue(0, 1000, '第${slices.length}段')];
        },
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (delay, _) async => waits.add(delay),
        checkCancelled: () {},
      );

      expect(slices.length, greaterThan(1));
      expect(waits, isEmpty);
      expect(
        slices.every(
          (slice) => slice.audioLength <= TranscriptionTiming.safeSliceLength,
        ),
        isTrue,
      );
      expect(slices.first.start, Duration.zero);
      expect(slices.first.overlap, Duration.zero);
      expect(slices.last.end, const Duration(hours: 5));
      for (var i = 1; i < slices.length; i++) {
        expect(slices[i].start, slices[i - 1].end);
        expect(slices[i].overlap, Duration.zero);
      }
    },
  );

  test('a slice the server calls too long is halved and then merged', () async {
    final lengths = <int>[];
    final waits = <Duration>[];
    final cues = await SliceRecognitionSession.run(
      duration: TranscriptionTiming.safeSliceLength,
      checkpoint: TranscriptionTaskCheckpoint.empty(1, 1),
      transcribe: (slice, label, onInner) async {
        lengths.add(slice.length.inMilliseconds);
        if (slice.length >= TranscriptionTiming.safeSliceLength) {
          throw const GongyiAsrException(
            GongyiAsrFailureKind.tooLong,
            '音频时长超出限制',
          );
        }
        final context = slice.leadingContext.inMilliseconds;
        return [cue(context + 500, context + 1500, '你好世界')];
      },
      onProgress: (_, _) {},
      onPiece: (_) async {},
      waitBetween: (delay, _) async => waits.add(delay),
      checkCancelled: () {},
    );

    expect(lengths.first, TranscriptionTiming.safeSliceLength.inMilliseconds);
    expect(lengths.skip(1).every((length) => length < lengths.first), isTrue);
    expect(cues, isNotEmpty);
    expect(cues.first.text, '你好世界');
    expect(waits, isEmpty);
  });

  test('uncertain submissions retain their exact saved slice range', () {
    final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1);
    checkpoint.remoteTasks['60000:120000:words'] = GongyiAsrTaskCheckpoint(
      submissionUncertain: true,
    );
    final restored = TranscriptionTaskCheckpoint.tryParse(checkpoint.toJson())!;
    expect(restored.hasProgress, isTrue);
    final slice = TranscriptionSlicePlanner.nextUnfinished(
      start: const Duration(minutes: 1),
      duration: const Duration(minutes: 5),
      checkpoint: restored,
    )!;
    expect(slice.start, const Duration(minutes: 1));
    expect(slice.length, const Duration(minutes: 2));
  });

  test(
    'a long service cooldown pauses without another automatic attempt',
    () async {
      var attempts = 0;
      final waits = <Duration>[];
      await expectLater(
        TranscriptionAttemptRunner.run(
          attempt: () async {
            attempts++;
            throw const GongyiAsrException(
              GongyiAsrFailureKind.riskControl,
              'Too Many Requests',
              statusCode: 429,
              retryAfter: Duration(minutes: 10),
            );
          },
          delay: (delay) async => waits.add(delay),
          onWaiting: (_) {},
        ),
        throwsA(isA<GongyiAsrException>()),
      );
      expect(attempts, 1);
      expect(waits, isEmpty);
    },
  );

  test(
    'segment progress keeps the range, stage and completed cue count',
    () async {
      final messages = <String>[];
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1);
      final cues = await SliceRecognitionSession.run(
        duration: const Duration(minutes: 110),
        checkpoint: checkpoint,
        transcribe: (slice, label, onInner) async {
          onInner(0.1, '准备音频 50%');
          onInner(0.7, '等待识别结果 · 已等待 00:12');
          final context = slice.leadingContext.inMilliseconds;
          return [
            cue(context + 3000, context + 4000, '片段 ${slice.start.inSeconds}'),
          ];
        },
        onProgress: (message, _) => messages.add(message),
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      );
      expect(cues, hasLength(12));
      expect(cues.last.startTime, const Duration(minutes: 108, seconds: 23));
      expect(messages, contains('第 1/12 段 · 00:00–10:00 · 准备音频 50%'));
      expect(messages, contains('第 2/12 段 · 10:00–19:50 · 等待识别结果 · 已等待 00:12'));
      expect(messages.last, contains('已完成，累计 12 条字幕'));

      messages.clear();
      final resumed = await SliceRecognitionSession.run(
        duration: const Duration(minutes: 110),
        checkpoint: checkpoint,
        transcribe: (_, _, _) async =>
            fail('Finished slices must not be prepared again'),
        onProgress: (message, _) => messages.add(message),
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      );
      expect(resumed.map((cue) => cue.text), cues.map((cue) => cue.text));
      expect(messages.last, contains('复用已完成片段，累计 12 条字幕'));
    },
  );

  test('completed slices are reused and not uploaded again', () async {
    final checkpoint = TranscriptionTaskCheckpoint.empty(8, 8);
    var failNext = true;
    Future<List<SubtitleItem>> transcribe(
      TranscriptionSlice slice,
      String? label,
      void Function(double inner, String message) onInner,
    ) async {
      if (failNext && slice.start > Duration.zero) {
        failNext = false;
        throw const GongyiAsrException(
          GongyiAsrFailureKind.rejected,
          '创建转录任务失败：参数错误',
        );
      }
      return [cue(0, 800, '已识别')];
    }

    await expectLater(
      SliceRecognitionSession.run(
        duration: const Duration(hours: 5),
        checkpoint: checkpoint,
        transcribe: transcribe,
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      ),
      throwsA(isA<GongyiAsrException>()),
    );
    expect(checkpoint.pieces, hasLength(1));

    final uploadedStarts = <int>[];
    var sawResume = false;
    final cues = await SliceRecognitionSession.run(
      duration: const Duration(hours: 5),
      checkpoint: checkpoint,
      transcribe: (slice, label, onInner) async {
        uploadedStarts.add(slice.start.inMilliseconds);
        final context = slice.leadingContext.inMilliseconds;
        return [cue(context + 3000, context + 4000, '续上')];
      },
      onProgress: (message, _) {
        if (message.contains('继续上次')) sawResume = true;
      },
      onPiece: (_) async {},
      waitBetween: (_, _) async {},
      checkCancelled: () {},
    );

    expect(sawResume, isTrue);

    expect(uploadedStarts, isNot(contains(0)));
    expect(uploadedStarts, hasLength(30));
    expect(cues.map((item) => item.text), containsAll(['已识别', '续上']));
  });

  test(
    'ten-minute uploads carry ten seconds of context without a longer tail',
    () async {
      for (final minutes in [9, 10, 11, 19, 20, 21, 29, 30, 31, 60, 61, 180]) {
        final duration = Duration(minutes: minutes);
        final slices = <TranscriptionSlice>[];
        await SliceRecognitionSession.run(
          duration: duration,
          checkpoint: TranscriptionTaskCheckpoint.empty(1, 1),
          transcribe: (slice, _, _) async {
            slices.add(slice);
            return [];
          },
          onProgress: (_, _) {},
          onPiece: (_) async {},
          waitBetween: (_, _) async {},
          checkCancelled: () {},
        );
        final count = minutes <= 10
            ? 1
            : 1 + ((minutes * 60 - 600) / 590).ceil();
        expect(slices, hasLength(count), reason: '$minutes min');
        expect(TranscriptionTiming.estimateSliceCount(duration), slices.length);
        expect(slices.last.end, duration);
        expect(
          slices.fold<Duration>(
            Duration.zero,
            (total, slice) => total + slice.length,
          ),
          duration,
        );
        for (var i = 0; i < slices.length; i++) {
          expect(slices[i].audioStart, Duration(seconds: i * 590));
          expect(slices[i].leadingContext, Duration(seconds: i == 0 ? 0 : 10));
          expect(slices[i].overlap, Duration.zero);
          expect(
            slices[i].audioLength,
            lessThanOrEqualTo(const Duration(minutes: 10)),
          );
        }
      }
    },
  );

  test(
    'submitted hour-long tasks are polled before applying the new policy',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1);
      const oldKey = '0:3600000:words';
      checkpoint.remoteTasks[oldKey] = GongyiAsrTaskCheckpoint(
        taskId: 'old-task',
      );
      final restored = TranscriptionTaskCheckpoint.tryParse(
        checkpoint.toJson(),
      )!;
      final slices = <TranscriptionSlice>[];
      await SliceRecognitionSession.run(
        duration: const Duration(minutes: 120),
        checkpoint: restored,
        transcribe: (slice, _, _) async {
          slices.add(slice);
          if (slices.length == 1) {
            expect(slice.taskKey, oldKey);
            expect(restored.remoteTasks[slice.taskKey]!.taskId, 'old-task');
          }
          final context = slice.leadingContext.inMilliseconds;
          return [cue(context + 3000, context + 4000, '片段 ${slices.length}')];
        },
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      );
      expect(slices, hasLength(8));
      expect(slices[0].length, const Duration(hours: 1));
      expect(slices[1].start, const Duration(minutes: 60));
      expect(slices[1].length, const Duration(minutes: 9, seconds: 50));
      expect(slices[1].leadingContext, const Duration(seconds: 10));
      expect(slices.last.end, const Duration(hours: 2));
    },
  );

  test(
    'new adjacent slices retain speech at the very start of each segment',
    () async {
      final slices = <TranscriptionSlice>[];
      final cues = await SliceRecognitionSession.run(
        duration: const Duration(minutes: 11),
        checkpoint: TranscriptionTaskCheckpoint.empty(1, 1),
        transcribe: (slice, _, _) async {
          slices.add(slice);
          return slice.start == Duration.zero
              ? [cue(599000, 600000, '切点之前')]
              : [cue(0, 800, '切点之前'), cue(10000, 10800, '切点之后')];
        },
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      );
      expect(slices, hasLength(2));
      expect(slices[0].end, slices[1].start);
      expect(slices[1].overlap, Duration.zero);
      expect(cues.map((cue) => cue.text), ['切点之前', '切点之后']);
      expect(slices[1].leadingContext, const Duration(seconds: 10));
      expect(cues[1].startTime, const Duration(minutes: 10));
    },
  );

  test('adaptive shorter uploads also meet without overlap', () {
    final halves = TranscriptionSlicePlanner.halve(
      const TranscriptionSlice(
        start: Duration.zero,
        length: Duration(minutes: 30),
        overlap: Duration.zero,
      ),
    );
    expect(halves[0].end, halves[1].start);
    expect(halves[1].overlap, Duration.zero);
    expect(halves[1].end, const Duration(minutes: 30));
  });

  test(
    'legacy overlapping tasks and completed records still resume without reupload',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1)
        ..addPiece(
          TranscriptionPieceRecord(
            startMs: 0,
            lengthMs: 1800000,
            cues: [cue(1799000, 1800000, '上段结尾')],
          ),
        );
      const legacyKey = '1798000:1802000:words';
      checkpoint.remoteTasks[legacyKey] = GongyiAsrTaskCheckpoint(
        taskId: 'saved-task',
      );
      final requested = <TranscriptionSlice>[];
      final cues = await SliceRecognitionSession.run(
        duration: const Duration(minutes: 61),
        checkpoint: checkpoint,
        transcribe: (slice, _, _) async {
          requested.add(slice);
          if (slice.taskKey == legacyKey) {
            expect(checkpoint.remoteTasks[slice.taskKey]!.taskId, 'saved-task');
            expect(slice.overlap, const Duration(seconds: 2));
            return [cue(0, 800, '上段结尾'), cue(3000, 4000, '旧任务余下的内容')];
          }
          expect(slice.start, const Duration(minutes: 60));
          expect(slice.overlap, Duration.zero);
          return [cue(10000, 10800, '新段开头')];
        },
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      );
      expect(requested, hasLength(2));
      expect(cues.map((cue) => cue.text), ['上段结尾', '旧任务余下的内容', '新段开头']);
      final restored = TranscriptionTaskCheckpoint.tryParse(
        checkpoint.toJson(),
      )!;
      final resumed = await SliceRecognitionSession.run(
        duration: const Duration(minutes: 61),
        checkpoint: restored,
        transcribe: (_, _, _) async =>
            fail('Completed legacy audio must not be uploaded'),
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      );
      expect(resumed.map((cue) => cue.text), cues.map((cue) => cue.text));
    },
  );

  test(
    'new slices stop at a later submitted range instead of uploading over it',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1);
      const key = '898000:3600000:words';
      checkpoint.remoteTasks[key] = GongyiAsrTaskCheckpoint(
        taskId: 'already-uploaded',
      );
      final slices = <TranscriptionSlice>[];
      await SliceRecognitionSession.run(
        duration: const Duration(minutes: 90),
        checkpoint: checkpoint,
        transcribe: (slice, _, _) async {
          slices.add(slice);
          return [];
        },
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      );
      expect(slices[0].end, const Duration(minutes: 10));
      expect(slices[1].end, const Duration(minutes: 14, seconds: 58));
      expect(slices[2].taskKey, key);
      expect(slices.last.end, const Duration(minutes: 90));
    },
  );

  test(
    'expired overlapping tasks are replaced only from the unfinished position',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1)
        ..addPiece(
          TranscriptionPieceRecord(
            startMs: 0,
            lengthMs: 1800000,
            cues: [cue(1799000, 1800000, '已经完成')],
          ),
        );
      const oldKey = '1798000:1802000:words';
      checkpoint.remoteTasks[oldKey] = GongyiAsrTaskCheckpoint(
        taskId: 'expired',
      );
      final replacementUploads = <TranscriptionSlice>[];
      final cues = await SliceRecognitionSession.run(
        duration: const Duration(hours: 1),
        checkpoint: checkpoint,
        transcribe: (slice, _, _) async {
          if (slice.taskKey == oldKey) {
            checkpoint.remoteTasks[oldKey]!.taskId = null;
            throw const GongyiAsrException(
              GongyiAsrFailureKind.tooLong,
              '旧任务已失效，按无重叠时长重新切分',
            );
          }
          if (slice.audioLength > const Duration(minutes: 10)) {
            throw const GongyiAsrException(
              GongyiAsrFailureKind.tooLong,
              '旧范围需要缩短',
            );
          }
          replacementUploads.add(slice);
          final context = slice.leadingContext.inMilliseconds;
          return [cue(context, context + 800, '未完成的开头')];
        },
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
      );
      expect(replacementUploads, hasLength(4));
      expect(replacementUploads.first.start, const Duration(minutes: 30));
      expect(
        replacementUploads.every(
          (s) => s.audioLength <= const Duration(minutes: 10),
        ),
        isTrue,
      );
      expect(replacementUploads.last.end, const Duration(hours: 1));
      expect(cues.first.text, '已经完成');
      expect(cues.skip(1).map((cue) => cue.text), List.filled(4, '未完成的开头'));
    },
  );

  test(
    'legacy overlap head is dropped and duplicate boundary text collapses',
    () {
      final placed = TranscriptionSubtitleMerger.placeSlice(
        relative: [cue(0, 800, '上一段已经有的'), cue(1800, 3200, '新句子')],
        sliceStart: const Duration(seconds: 358),
        overlap: const Duration(seconds: 2),
        sliceLength: const Duration(minutes: 6),
      );
      expect(placed, hasLength(1));
      expect(placed.single.text, '新句子');
      expect(
        placed.single.startTime,
        const Duration(milliseconds: 358000 + 1800),
      );

      final merged = TranscriptionSubtitleMerger.finish([
        cue(0, 2000, '你好'),
        cue(1500, 3600, '你好世界'),
        cue(8000, 9000, '下一句'),
      ]);
      expect(merged.map((item) => item.text), ['你好世界', '下一句']);
      expect(merged.map((item) => item.index), [1, 2]);
    },
  );

  test(
    'retry waits grow by failure kind and permanent rejection does not wait',
    () async {
      final waits = <Duration>[];
      final cues = await TranscriptionAttemptRunner.run(
        attempt: () async {
          if (waits.length < 2) {
            throw const GongyiAsrException(
              GongyiAsrFailureKind.networkUnavailable,
              'offline',
            );
          }
          return [cue(0, 1000, '恢复了')];
        },
        delay: (delay) async => waits.add(delay),
        onWaiting: (_) {},
      );
      expect(waits, TranscriptionRetryPolicy.networkDelays.take(2));
      expect(cues.single.text, '恢复了');

      final riskWaits = <Duration>[];
      await expectLater(
        TranscriptionAttemptRunner.run(
          attempt: () async {
            throw const GongyiAsrException(
              GongyiAsrFailureKind.riskControl,
              '412',
            );
          },
          delay: (delay) async => riskWaits.add(delay),
          onWaiting: (message) {
            expect(message, contains('访问限制'));
            expect(message, contains('自动重试'));
          },
        ),
        throwsA(
          isA<GongyiAsrException>().having(
            (error) => error.kind,
            'kind',
            GongyiAsrFailureKind.riskControl,
          ),
        ),
      );
      expect(riskWaits, TranscriptionRetryPolicy.riskDelays);

      var rejectedWaits = 0;
      await expectLater(
        TranscriptionAttemptRunner.run(
          attempt: () async {
            throw const GongyiAsrException(
              GongyiAsrFailureKind.rejected,
              '创建转录任务失败：参数错误',
            );
          },
          delay: (_) async => rejectedWaits++,
          onWaiting: (_) {},
        ),
        throwsA(isA<GongyiAsrException>()),
      );
      expect(rejectedWaits, 0);
    },
  );

  test(
    'checkpoint json keeps finished pieces and ignores a replaced source file',
    () {
      final book = TranscriptionCheckpointBook();
      final task = TranscriptionTaskCheckpoint.empty(100, 200);
      task.addPiece(
        TranscriptionPieceRecord(
          startMs: 0,
          lengthMs: 360000,
          cues: [cue(0, 1000, '你好')],
        ),
      );
      book.tasks['id:video'] = task;

      final restored = TranscriptionCheckpointBook.decode(book.encode());
      final saved = restored.tasks['id:video']!;
      expect(saved.matches(100, 200), isTrue);
      expect(saved.matches(100, 201), isFalse);
      expect(saved.pieceStartingAt(0)?.cues.single.text, '你好');
      expect(TranscriptionCheckpointBook.decode('not json').tasks, isEmpty);
      expect(jsonDecode(book.encode())['version'], 1);
    },
  );

  test(
    'watchdog stays at 30 minutes for short media and grows for long media',
    () {
      expect(
        TranscriptionTiming.watchdogForLabel('03:00'),
        const Duration(minutes: 30),
      );
      expect(
        TranscriptionTiming.watchdogForLabel(''),
        const Duration(hours: 3),
      );
      expect(
        TranscriptionTiming.parseClockLabel('90:00'),
        const Duration(minutes: 90),
      );
      expect(
        TranscriptionTiming.watchdogForLabel('120:00'),
        greaterThan(const Duration(minutes: 30)),
      );
      expect(
        TranscriptionTiming.watchdogForLabel('1:02:03'),
        greaterThan(const Duration(minutes: 30)),
      );
    },
  );

  test('failure text shown to the user explains the next step', () {
    expect(
      TranscriptionUserMessage.describe(Exception('Exception: 转录任务失败')),
      isNot(contains('Exception')),
    );
    expect(
      TranscriptionUserMessage.describe(
        const GongyiAsrException(GongyiAsrFailureKind.riskControl, '412'),
      ),
      contains('已完成的片段会接着用'),
    );
    expect(
      TranscriptionUserMessage.describe(
        const GongyiAsrException(
          GongyiAsrFailureKind.networkUnavailable,
          'offline',
        ),
      ),
      contains('检查网络'),
    );
    expect(
      TranscriptionUserMessage.describe(Exception('媒体无音轨，无法生成字幕')),
      '这个文件没有音轨，无法生成字幕',
    );
    expect(
      TranscriptionTiming.describePlan(const Duration(minutes: 42), 8),
      contains('分成 8 段'),
    );
  });
}
