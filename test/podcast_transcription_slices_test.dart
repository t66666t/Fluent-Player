import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/gongyi_asr_service.dart';
import 'package:video_player_app/services/transcription_reliability.dart';

void main() {
  test(
    'a two-hour podcast uses adjacent thirty-minute slices and resumes only the unfinished timeline',
    () async {
      const duration = Duration(hours: 2);
      final book = TranscriptionCheckpointBook();
      book.tasks['episode'] = TranscriptionTaskCheckpoint.empty(123, 456);
      final requested = <TranscriptionSlice>[];
      var fail = true;
      Future<List<SubtitleItem>> run(TranscriptionTaskCheckpoint checkpoint) =>
          SliceRecognitionSession.run(
            duration: duration,
            checkpoint: checkpoint,
            onProgress: (_, _) {},
            onPiece: (_) async {},
            waitBetween: (_, _) async {},
            checkCancelled: () {},
            transcribe: (slice, _, report) async {
              requested.add(slice);
              if (fail && requested.length == 2) {
                throw const GongyiAsrException(
                  GongyiAsrFailureKind.networkUnavailable,
                  'offline',
                );
              }
              report(0.5, '识别中');
              return [
                SubtitleItem(
                  index: 1,
                  startTime: const Duration(seconds: 3),
                  endTime: const Duration(seconds: 4),
                  text: '片段 ${slice.start.inMilliseconds}',
                ),
              ];
            },
          );
      await expectLater(
        run(book.tasks['episode']!),
        throwsA(isA<GongyiAsrException>()),
      );
      expect(book.tasks['episode']!.pieces, hasLength(1));
      final restored = TranscriptionCheckpointBook.decode(
        book.encode(),
      ).tasks['episode']!;
      final firstMissing = requested.last.start;
      requested.clear();
      fail = false;
      final subtitles = await run(restored);
      expect(requested.first.start, firstMissing);
      expect(restored.pieces, hasLength(4));
      expect(subtitles, hasLength(4));
      expect(restored.pieces.last.endMs, duration.inMilliseconds);
      expect(
        restored.pieces.every(
          (p) => p.lengthMs <= const Duration(minutes: 30).inMilliseconds,
        ),
        isTrue,
      );
      for (var i = 1; i < restored.pieces.length; i++) {
        expect(restored.pieces[i].startMs, restored.pieces[i - 1].endMs);
      }
    },
  );

  test(
    'remote task identifiers survive restart and invalid source fingerprints discard their reuse',
    () {
      final checkpoint = TranscriptionTaskCheckpoint.empty(100, 200);
      checkpoint.remoteTasks['0:900000:words'] = GongyiAsrTaskCheckpoint(
        taskId: 'submitted',
      );
      final book = TranscriptionCheckpointBook(tasks: {'episode': checkpoint});
      final restored = TranscriptionCheckpointBook.decode(
        book.encode(),
      ).tasks['episode']!;
      expect(restored.hasProgress, isTrue);
      expect(restored.remoteTasks['0:900000:words']!.taskId, 'submitted');
      expect(restored.matches(100, 200), isTrue);
      expect(restored.matches(100, 201), isFalse);
    },
  );

  test(
    'older completed fifteen-minute slices are reused before applying the unified policy',
    () async {
      final checkpoint = TranscriptionTaskCheckpoint.empty(100, 200)
        ..addPiece(
          TranscriptionPieceRecord(startMs: 0, lengthMs: 900000, cues: []),
        );
      final requested = <TranscriptionSlice>[];
      await SliceRecognitionSession.run(
        duration: const Duration(hours: 2),
        checkpoint: checkpoint,
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
        transcribe: (slice, _, _) async {
          requested.add(slice);
          return [];
        },
      );
      expect(requested.first.start, const Duration(minutes: 15));
      expect(requested.first.length, const Duration(minutes: 30));
      expect(requested, hasLength(4));
      expect(
        requested.every((s) => s.length <= const Duration(minutes: 30)),
        isTrue,
      );
    },
  );

  test(
    'a three-hour podcast uses six recognition tasks without a tiny seventh tail',
    () async {
      final requested = <TranscriptionSlice>[];
      await SliceRecognitionSession.run(
        duration: const Duration(hours: 3),
        checkpoint: TranscriptionTaskCheckpoint.empty(100, 200),
        onProgress: (_, _) {},
        onPiece: (_) async {},
        waitBetween: (_, _) async {},
        checkCancelled: () {},
        transcribe: (slice, _, _) async {
          requested.add(slice);
          return [];
        },
      );
      expect(requested, hasLength(6));
      expect(requested.first.length, const Duration(minutes: 30));
      expect(requested.last.end, const Duration(hours: 3));
    },
  );
}
