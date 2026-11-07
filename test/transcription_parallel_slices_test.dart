import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/public_asr_quota.dart';
import 'package:video_player_app/services/transcription_reliability.dart';

SubtitleItem cue(int from, int to, String text) => SubtitleItem(
  index: 0,
  startTime: Duration(milliseconds: from),
  endTime: Duration(milliseconds: to),
  text: text,
);

Future<void> until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 3)) {
      fail('Slice operation did not settle');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

Future<List<SubtitleItem>> run({
  required TranscriptionTaskCheckpoint checkpoint,
  required Future<List<SubtitleItem>> Function(TranscriptionSlice) transcribe,
  Duration duration = const Duration(minutes: 31),
  Future<void> Function(TranscriptionPieceRecord)? save,
  void Function()? stop,
  bool Function(Object)? cancelPeersOnError,
  void Function(String, double)? progress,
}) => SliceRecognitionSession.run(
  duration: duration,
  checkpoint: checkpoint,
  concurrency: 3,
  transcribe: (slice, _, inner) {
    inner(.7, '等待识别结果');
    return transcribe(slice);
  },
  onPiece: save ?? (_) async {},
  onProgress: progress ?? (_, _) {},
  waitBetween: (_, _) async => fail('Normal pieces have no inter-slice delay'),
  checkCancelled: () {},
  stopInFlight: stop,
  cancelPeersOnError: cancelPeersOnError,
);

void main() {
  test(
    'three workers persist out-of-order results and deduplicate in timeline order',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1);
      final pending = <int, Completer<List<SubtitleItem>>>{};
      final snapshots = <String>[];
      final messages = <String>[];
      var active = 0, peak = 0;
      final result = run(
        checkpoint: checkpoint,
        progress: (message, _) => messages.add(message),
        save: (_) async => snapshots.add(jsonEncode(checkpoint.toJson())),
        transcribe: (slice) async {
          active++;
          if (active > peak) peak = active;
          checkpoint.remoteTasks[slice.taskKey] = GongyiAsrTaskCheckpoint(
            taskId: 'task-${slice.start.inSeconds}',
            leadingContext: slice.leadingContext,
          );
          final done = pending[slice.start.inSeconds] =
              Completer<List<SubtitleItem>>();
          try {
            return await done.future;
          } finally {
            active--;
          }
        },
      );
      await until(() => pending.length == 3);
      expect(pending.keys, [0, 600, 1190]);
      pending[600]!.complete([cue(8000, 12000, '共同片段，第二段')]);
      await until(() => pending.length == 4);
      expect(pending.keys.last, 1780);
      expect(snapshots, hasLength(1));
      final restoredEarly = TranscriptionTaskCheckpoint.tryParse(
        jsonDecode(snapshots.first),
      )!;
      expect(
        restoredEarly.pieces.single.leadingContext,
        const Duration(seconds: 10),
      );
      expect(restoredEarly.remoteTasks['0:600000:words']!.taskId, 'task-0');
      pending[1190]!.complete([cue(13000, 14000, '第三段')]);
      pending[1780]!.complete([cue(13000, 14000, '第四段')]);
      await until(() => active == 1);
      pending[0]!.complete([cue(599000, 600000, '共同片段')]);
      final captions = await result;
      expect(peak, 3);
      expect(active, 0);
      expect(captions.map((c) => c.text), ['共同片段', '第二段', '第三段', '第四段']);
      expect(captions[1].startTime, const Duration(minutes: 10));
      expect(captions[2].startTime, const Duration(seconds: 1193));
      expect(
        messages.every(
          (m) => !m.contains('秒后') && !m.contains('–') && !m.contains('累计'),
        ),
        isTrue,
      );
      final resumed = TranscriptionTaskCheckpoint.tryParse(
        jsonDecode(jsonEncode(checkpoint.toJson())),
      )!;
      final again = await run(
        checkpoint: resumed,
        transcribe: (_) async =>
            fail('Completed pieces must not be uploaded again'),
      );
      expect(
        again.map((c) => c.toTimingJson()),
        captions.map((c) => c.toTimingJson()),
      );
    },
  );

  test(
    'a restriction stops scheduling, drains peers, and keeps completed pieces and task IDs',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1);
      final pending = <int, Completer<List<SubtitleItem>>>{};
      var active = 0, stopped = 0;
      final result = run(
        checkpoint: checkpoint,
        stop: () {
          stopped++;
          for (final item in pending.values) {
            if (!item.isCompleted) {
              item.completeError(StateError('peer stopped'));
            }
          }
        },
        transcribe: (slice) async {
          active++;
          checkpoint.remoteTasks[slice.taskKey] = GongyiAsrTaskCheckpoint(
            taskId: 'task-${slice.start.inSeconds}',
            leadingContext: slice.leadingContext,
          );
          final done = pending[slice.start.inSeconds] =
              Completer<List<SubtitleItem>>();
          try {
            return await done.future;
          } finally {
            active--;
          }
        },
      );
      final failure = expectLater(
        result,
        throwsA(
          isA<GongyiAsrException>().having(
            (error) => error.statusCode,
            'original restriction',
            429,
          ),
        ),
      );
      await until(() => pending.length == 3);
      pending[1190]!.complete([cue(13000, 14000, '保留的第三段')]);
      await until(() => pending.length == 4);
      pending[600]!.completeError(
        const GongyiAsrException(
          GongyiAsrFailureKind.riskControl,
          '请求过于频繁',
          statusCode: 429,
        ),
      );
      await failure;
      expect(stopped, 1);
      expect(active, 0);
      expect(pending, hasLength(4));
      expect(checkpoint.pieces.single.startMs, 1190000);
      final restored = TranscriptionTaskCheckpoint.tryParse(
        jsonDecode(jsonEncode(checkpoint.toJson())),
      )!;
      expect(restored.remoteTasks['600000:590000:words']!.taskId, 'task-600');
      final requested = <int>[];
      final captions = await run(
        checkpoint: restored,
        transcribe: (slice) async {
          requested.add(slice.start.inSeconds);
          final context = slice.leadingContext.inMilliseconds;
          return [
            cue(context + 3000, context + 4000, '恢复 ${slice.start.inSeconds}'),
          ];
        },
      );
      expect(requested, isNot(contains(1190)));
      expect(captions.map((c) => c.text), contains('保留的第三段'));
    },
  );

  test(
    'quota exhaustion drains submitted work and saves it before returning the limit',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1);
      checkpoint.remoteTasks['0:600000:words'] = GongyiAsrTaskCheckpoint(
        taskId: 'already-submitted',
      );
      final first = Completer<List<SubtitleItem>>();
      var limited = false, cancelled = false;
      final result = run(
        checkpoint: checkpoint,
        duration: const Duration(minutes: 11),
        stop: () {
          cancelled = true;
          first.completeError(StateError('cancelled'));
        },
        cancelPeersOnError: (error) => error is! PublicAsrQuotaException,
        transcribe: (slice) async {
          if (slice.start == Duration.zero) return first.future;
          limited = true;
          throw const PublicAsrQuotaException('额度不足');
        },
      );
      final failure = expectLater(
        result,
        throwsA(isA<PublicAsrQuotaException>()),
      );
      await until(() => limited);
      expect(cancelled, isFalse);
      first.complete([cue(3000, 4000, '已经提交的结果')]);
      await failure;
      expect(checkpoint.pieces.single.cues.single.text, '已经提交的结果');
      expect(
        checkpoint.remoteTasks['0:600000:words']!.taskId,
        'already-submitted',
      );
    },
  );

  test(
    'old completed ranges and pending remote ranges survive the concurrent policy',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(1, 1)
        ..addPiece(
          TranscriptionPieceRecord(
            startMs: 0,
            lengthMs: 1800000,
            cues: [cue(1799000, 1800000, '旧片段')],
          ),
        );
      checkpoint.remoteTasks['1800000:1800000:words'] = GongyiAsrTaskCheckpoint(
        taskId: 'old-task',
      );
      final requested = <TranscriptionSlice>[];
      final captions = await run(
        checkpoint: checkpoint,
        duration: const Duration(minutes: 61),
        transcribe: (slice) async {
          requested.add(slice);
          if (slice.start == const Duration(minutes: 30)) {
            expect(slice.taskKey, '1800000:1800000:words');
            expect(checkpoint.remoteTasks[slice.taskKey]!.taskId, 'old-task');
            return [cue(3000, 4000, '旧任务结果')];
          }
          return [cue(13000, 14000, '新片段')];
        },
      );
      expect(requested, hasLength(2));
      expect(captions.map((c) => c.text), ['旧片段', '旧任务结果', '新片段']);
      expect(captions.last.startTime, const Duration(minutes: 60, seconds: 3));
    },
  );
}
