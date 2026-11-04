import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/ocr_runtime_cache.dart';

void main() {
  test(
    'pressure trims idle sessions even when the requested model is cached',
    () async {
      final released = <Object>[];
      final cache = OcrRuntimeCache<Object>(
        dispose: (value) async => released.add(value),
      );
      final first = Object(), second = Object();
      expect(
        await cache.obtain('first', capacity: 2, create: () async => first),
        same(first),
      );
      await cache.obtain('second', capacity: 2, create: () async => second);
      expect(released, isEmpty);
      expect(
        await cache.obtain(
          'second',
          capacity: 1,
          create: () async => fail('cached session rebuilt'),
        ),
        same(second),
      );
      expect(released, [first]);
      await cache.clear();
      await cache.clear();
      expect(released, [first, second]);
    },
  );

  test(
    'eviction finishes before admission, and failed creation is not cached',
    () async {
      final released = <Object>[];
      final cache = OcrRuntimeCache<Object>(
        dispose: (value) async => released.add(value),
      );
      final first = Object();
      await cache.obtain('first', capacity: 1, create: () async => first);
      await expectLater(
        cache.obtain(
          'second',
          capacity: 1,
          create: () async {
            expect(released, [first]);
            throw StateError('admission refused');
          },
        ),
        throwsStateError,
      );
      final second = Object();
      expect(
        await cache.obtain('second', capacity: 1, create: () async => second),
        same(second),
      );
      await cache.clear();
      expect(released, [first, second]);
    },
  );

  test(
    'raw reads preserve offsets and independent regions across chunk replacement',
    () async {
      final root = await Directory.systemTemp.createTemp('ocr reader ');
      final reader = OcrRawFrameReader();
      try {
        final first = File('${root.path}/first.rgb');
        final next = File('${root.path}/next.rgb');
        await first.writeAsBytes(List.generate(12, (i) => i));
        await next.writeAsBytes([91, 92, 93]);
        Future<List<int>> read(
          int track,
          int offset, {
          String? path,
          int length = 3,
        }) => reader.read(
          track: track,
          path: path ?? first.path,
          offset: offset,
          length: length,
        );
        expect(await read(1, 0), [0, 1, 2]);
        expect(await read(1, 3), [3, 4, 5]);
        expect(await read(2, 9), [9, 10, 11]);
        expect(await read(1, 0), [0, 1, 2]);
        expect(await read(1, 0, path: next.path), [91, 92, 93]);
        await expectLater(read(2, 11), throwsStateError);
        expect(await read(2, 6), [6, 7, 8]);
        await reader.close();
        // In particular, Windows chunk deletion must not leave held file handles.
        await first.delete();
        await next.delete();
      } finally {
        await reader.close();
        await root.delete(recursive: true);
      }
    },
  );
}
