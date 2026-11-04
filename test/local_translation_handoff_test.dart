import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/local_translation_handoff.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/models/subtitle_model.dart';

StableAsrBatch _batch(int first, int count, int through) => StableAsrBatch(
  [
    for (var n = first; n < first + count; n++)
      SubtitleItem(
        index: n,
        startTime: Duration(seconds: n * 2),
        endTime: Duration(seconds: n * 2 + 1),
        text: '<i>Subtitle $n</i>',
      ),
  ],
  Duration(seconds: through),
  null,
  nativePipeline: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'first resident batch is timely, later small windows fill native rows',
    () {
      final buffer = LocalTranslationHandoffBuffer()..add(_batch(1, 2, 6));
      expect(buffer.ready(keepResident: true), isTrue);
      final first = buffer.drain(retainConsumerModels: true);
      expect(first.cues.map((c) => c.index), [1, 2]);
      for (final at in [3, 5, 7]) {
        buffer.add(_batch(at, 2, (at + 2) * 2));
        expect(buffer.ready(keepResident: true), isFalse);
        expect(
          buffer.ready(
            keepResident: true,
            processedThrough: const Duration(seconds: 51),
          ),
          isTrue,
        );
      }
      buffer.add(_batch(9, 2, 22));
      expect(buffer.ready(keepResident: true), isTrue);
      final combined = buffer.drain(retainConsumerModels: true);
      expect(combined.cues.map((c) => c.index), List.generate(8, (n) => n + 3));
      expect(combined.cues.first.text, '<i>Subtitle 3</i>');
      expect(combined.cues.last.endTime, const Duration(seconds: 21));
      expect(combined.processedThrough, const Duration(seconds: 22));
      expect(combined.nativePipeline, isTrue);
      expect(buffer.isEmpty, isTrue);
    },
  );

  test(
    'resident buffering is bounded by audio coverage, pressure and manual rows',
    () {
      final buffer = LocalTranslationHandoffBuffer()..add(_batch(1, 1, 5));
      buffer.drain(retainConsumerModels: true);
      buffer.add(_batch(2, 1, 48));
      expect(buffer.ready(keepResident: true), isFalse);
      buffer.add(_batch(3, 1, 49));
      expect(buffer.ready(keepResident: true), isTrue);
      buffer.drain(retainConsumerModels: true);
      buffer.add(_batch(4, 1, 50));
      expect(buffer.ready(keepResident: true, batchLimit: 1), isTrue);
      expect(buffer.ready(keepResident: false, protective: true), isTrue);
      expect(buffer.ready(keepResident: false, endOfInput: true), isTrue);
    },
  );

  test('alternate residency coalesces at most 32 rows or 90 seconds', () {
    final buffer = LocalTranslationHandoffBuffer()..add(_batch(1, 16, 34));
    expect(buffer.ready(keepResident: false), isFalse);
    buffer.add(_batch(17, 16, 66));
    expect(buffer.ready(keepResident: false), isTrue);
    expect(buffer.wouldOverflow(_batch(33, 1, 68)), isTrue);
    expect(buffer.drain(retainConsumerModels: true).cues.length, 32);
    buffer.add(_batch(34, 1, 70));
    expect(buffer.wouldOverflow(_batch(35, 1, 159)), isTrue);
    expect(buffer.ready(keepResident: false), isFalse);
    expect(buffer.ready(keepResident: false, endOfInput: true), isTrue);
  });

  test(
    'one oversized input drains without dropping or splitting any subtitle',
    () {
      final buffer = LocalTranslationHandoffBuffer()..add(_batch(1, 40, 100));
      expect(buffer.ready(keepResident: false), isTrue);
      final cues = buffer.drain(retainConsumerModels: true).cues;
      expect(cues.length, 40);
      expect(cues.map((c) => c.index), List.generate(40, (n) => n + 1));
      expect(() => cues.clear(), throwsUnsupportedError);
      expect(buffer.ready(keepResident: true, endOfInput: true), isFalse);
    },
  );

  test(
    'cannot combine unordered cues or work belonging to a different lease',
    () async {
      final buffer = LocalTranslationHandoffBuffer()..add(_batch(2, 1, 6));
      expect(() => buffer.add(_batch(1, 1, 8)), throwsStateError);
      expect(() => buffer.add(_batch(3, 1, 5)), throwsStateError);
      await InferenceScheduler().run(() async {
        final next = _batch(3, 1, 8);
        expect(
          () => buffer.add(
            StableAsrBatch(
              next.cues,
              next.processedThrough,
              InferenceScheduler.instance.currentReservation,
            ),
          ),
          throwsStateError,
        );
      });
      expect(buffer.cueCount, 1);
    },
  );
}
