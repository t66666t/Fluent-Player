import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/audio_chunk_prefetcher.dart';

void main() {
  test(
    'prepares only one next chunk and deletes unclaimed audio on close',
    () async {
      final root = await Directory.systemTemp.createTemp('asr-prefetch-');
      final calls = <int>[];
      final entered = Completer<void>(), release = Completer<void>();
      final prefetch = AudioChunkPrefetcher<int>(
        inputs: [0, 1, 2],
        prepare: (id, progress) async {
          calls.add(id);
          if (id == 1) {
            entered.complete();
            await release.future;
          }
          final file = File('${root.path}/$id.wav');
          await file.writeAsBytes([id]);
          return file.path;
        },
      );
      try {
        final first = await prefetch.take(0, (_) {});
        await entered.future;
        expect(calls, [0, 1]);
        final closing = prefetch.close();
        release.complete();
        await closing;
        expect(await File(first).exists(), isTrue);
        expect(await File('${root.path}/1.wav').exists(), isFalse);
        expect(calls, [0, 1]);
        await File(first).delete();
      } finally {
        await prefetch.close();
        await root.delete();
      }
    },
  );
  test('a prefetched error is captured and reported when requested', () async {
    final root = await Directory.systemTemp.createTemp('asr-prefetch-error-');
    final prefetch = AudioChunkPrefetcher<int>(
      inputs: [0, 1],
      prepare: (id, progress) async {
        if (id == 1) throw StateError('prepare failed');
        final file = File('${root.path}/0.wav');
        await file.writeAsBytes([0]);
        return file.path;
      },
    );
    try {
      final path = await prefetch.take(0, (_) {});
      await Future<void>.delayed(Duration.zero);
      await expectLater(prefetch.take(1, (_) {}), throwsStateError);
      await File(path).delete();
    } finally {
      await prefetch.close();
      await root.delete();
    }
  });
}
