import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/thumbnail_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'visible file work bypasses and can promote queued prefetches',
    () async {
      final cache = ThumbnailCacheService()..clearMemoryCache();
      final pending = <String, Completer<String?>>{};
      final started = <String>[];
      cache.setMissingThumbnailResolver((id) {
        started.add(id);
        final result = Completer<String?>();
        pending[id] = result;
        return result.future;
      });
      final requests = <ThumbnailLoadRequest>[];
      try {
        for (var i = 0; i < 5; i++) {
          requests.add(
            cache.requestThumbnail('ahead-$i', null, prefetch: true),
          );
        }
        expect(started, ['ahead-0', 'ahead-1']);
        await Future<void>.delayed(Duration.zero);

        final promoted = cache.requestThumbnail('ahead-2', null);
        requests.add(promoted);
        final visible = cache.requestThumbnail('visible', null);
        requests.add(visible);
        expect(started, ['ahead-0', 'ahead-1', 'ahead-2', 'visible']);

        requests[3].dispose();
        expect(await requests[3].image, isNull);
        expect(started, isNot(contains('ahead-3')));
        pending['ahead-0']!.complete(null);
        await Future<void>.delayed(Duration.zero);
        expect(started, contains('ahead-4'));

        for (final result in pending.values) {
          if (!result.isCompleted) result.complete(null);
        }
        await Future.wait(requests.map((request) => request.image));
      } finally {
        for (final result in pending.values) {
          if (!result.isCompleted) result.complete(null);
        }
        for (final request in requests) {
          request.dispose();
        }
        cache.setMissingThumbnailResolver(null);
        cache.clearMemoryCache();
      }
    },
  );

  test('slow missing-cover repairs do not block existing files', () async {
    final root = await Directory.systemTemp.createTemp(
      'thumbnail-file-priority-',
    );
    final file = await File('${root.path}/ready.png').writeAsBytes([1, 2, 3]);
    final cache = ThumbnailCacheService()..clearMemoryCache();
    final pending = <String, Completer<String?>>{};
    cache.setMissingThumbnailResolver((id) {
      final result = Completer<String?>();
      pending[id] = result;
      return result.future;
    });
    final requests = <ThumbnailLoadRequest>[];
    try {
      for (var i = 0; i < 4; i++) {
        requests.add(cache.requestThumbnail('slow-$i', null));
      }
      expect(pending.length, 4);
      await Future<void>.delayed(Duration.zero);
      final abandoned = cache.requestThumbnail('abandoned-repair', null);
      requests.add(abandoned);
      abandoned.dispose();
      expect(await abandoned.image, isNull);
      expect(pending, isNot(contains('abandoned-repair')));

      final ready = cache.requestThumbnail('ready-file', file.path);
      requests.add(ready);
      expect(
        await ready.image.timeout(const Duration(seconds: 1)),
        isA<FileImage>(),
      );
      expect(pending.values.every((result) => !result.isCompleted), isTrue);
      for (final result in pending.values) {
        result.complete(null);
      }
      await Future.wait(requests.map((request) => request.image));
    } finally {
      for (final result in pending.values) {
        if (!result.isCompleted) result.complete(null);
      }
      for (final request in requests) {
        request.dispose();
      }
      cache.setMissingThumbnailResolver(null);
      cache.clearMemoryCache();
      await root.delete(recursive: true);
    }
  });
}
