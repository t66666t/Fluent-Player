import 'dart:async';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/thumbnail_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cache = ThumbnailCacheService();
  tearDown(() {
    cache.setMissingThumbnailResolver(null);
    cache.clearMemoryCache();
  });

  test(
    'queued requests are bounded, shared and abandoned before file repair',
    () async {
      cache.clearMemoryCache();
      final pending = <String, Completer<String?>>{};
      var active = 0, maximum = 0;
      cache.setMissingThumbnailResolver((id) async {
        active++;
        if (active > maximum) maximum = active;
        final result = pending[id] = Completer<String?>();
        try {
          return await result.future;
        } finally {
          active--;
        }
      });
      final requests = List.generate(
        4,
        (i) => cache.requestThumbnail('owned-$i', null),
      );
      final shared = cache.requestThumbnail('owned-0', null);
      requests[0].dispose();
      final abandoned = cache.requestThumbnail('abandoned', null)..dispose();
      try {
        for (var i = 0; pending.length < 4 && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        expect(pending.length, 4);
        expect(maximum, 4);
        expect(pending.keys, isNot(contains('abandoned')));
        for (final done in pending.values) {
          done.complete(null);
        }
        expect(await shared.image, isNull);
        expect(await abandoned.image, isNull);
        await Future.wait(requests.map((r) => r.image));
        expect(pending.length, 4);
      } finally {
        for (final done in pending.values) {
          if (!done.isCompleted) done.complete(null);
        }
        for (final request in requests) {
          request.dispose();
        }
        shared.dispose();
      }
    },
  );

  test(
    'predecode and display use identical size buckets and resize policies',
    () async {
      const image = AssetImage('thumbnail');
      final prepared = libraryThumbnailProvider(image, width: 201, height: 113);
      final displayed = libraryThumbnailProvider(
        image,
        width: 220,
        height: 120,
      );
      expect(
        await prepared.obtainKey(ImageConfiguration.empty),
        await displayed.obtainKey(ImageConfiguration.empty),
      );
      expect((prepared as ResizeImage).policy, ResizeImagePolicy.fit);
      expect(prepared.allowUpscaling, false);
    },
  );
}
