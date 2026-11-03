import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/transcription_audio_prefetcher.dart';
import 'package:video_player_app/services/transcription_reliability.dart';

TranscriptionSlice slice(int start, {int length = 1800}) => TranscriptionSlice(
  start: Duration(seconds: start),
  length: Duration(seconds: length),
  overlap: Duration.zero,
);

void main() {
  test(
    'prepares one slice ahead and reuses it with the latest progress',
    () async {
      final started = <String>[];
      final released = <String>[];
      final gate = Completer<String>();
      final prefetcher = TranscriptionAudioPrefetcher<String>(
        prepare: (slice, progress, _) {
          started.add(slice.taskKey);
          progress(.75);
          return gate.future;
        },
        release: (path) async => released.add(path),
      );
      final next = slice(1800);
      prefetcher.prefetch(next);
      prefetcher.prefetch(slice(3600));
      expect(started, [next.taskKey]);
      gate.complete('prepared-audio');
      final progress = <double>[];
      expect(await prefetcher.take(next, progress.add), 'prepared-audio');
      expect(progress.first, .75);
      expect(started, [next.taskKey]);
      await prefetcher.close();
      expect(released, isEmpty, reason: 'Taken audio belongs to the caller');
    },
  );

  test(
    'a changed adaptive range cancels and drains before preparing again',
    () async {
      var active = 0, maxActive = 0;
      final events = <String>[];
      final first = slice(1800);
      final replacement = slice(0, length: 900);
      final prefetcher = TranscriptionAudioPrefetcher<String>(
        prepare: (slice, _, cancel) async {
          active++;
          if (active > maxActive) maxActive = active;
          events.add('start:${slice.taskKey}');
          if (slice.taskKey == first.taskKey) {
            await cancel;
            events.add('cancel:first');
          }
          active--;
          return slice.taskKey;
        },
        release: (path) async => events.add('release:$path'),
      );
      prefetcher.prefetch(first);
      expect(await prefetcher.take(replacement, (_) {}), replacement.taskKey);
      expect(maxActive, 1);
      expect(events, [
        'start:${first.taskKey}',
        'cancel:first',
        'release:${first.taskKey}',
        'start:${replacement.taskKey}',
      ]);
      await prefetcher.close();
    },
  );

  test(
    'closing cancels unfinished speculation and releases its result',
    () async {
      final released = <String>[];
      final prefetcher = TranscriptionAudioPrefetcher<String>(
        prepare: (_, _, cancel) async {
          await cancel;
          return 'unused';
        },
        release: (path) async => released.add(path),
      );
      prefetcher.prefetch(slice(1800));
      await prefetcher.close();
      await prefetcher.close();
      expect(released, ['unused']);
      await expectLater(prefetcher.take(slice(1800), (_) {}), throwsStateError);
    },
  );

  test(
    'speculative errors are held until that exact range is requested',
    () async {
      final error = StateError('preparation failed');
      final prefetcher = TranscriptionAudioPrefetcher<String>(
        prepare: (slice, _, _) async {
          if (slice.start > Duration.zero) throw error;
          return 'replacement';
        },
        release: (_) async {},
      );
      prefetcher.prefetch(slice(1800));
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        prefetcher.take(slice(1800), (_) {}),
        throwsA(same(error)),
      );
      prefetcher.prefetch(slice(1800));
      expect(await prefetcher.take(slice(0), (_) {}), 'replacement');
      await prefetcher.close();
    },
  );
}
