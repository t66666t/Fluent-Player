import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/thumbnail_cache_service.dart';
import 'package:video_player_app/widgets/media_library_card_preload.dart';
import 'package:video_player_app/widgets/media_list_layout_metrics.dart';

void main() {
  testWidgets('optional thumbnail work waits for route entry and resumes', (
    tester,
  ) async {
    final cache = ThumbnailCacheService()..clearMemoryCache();
    final requests = <String>[];
    cache.setMissingThumbnailResolver((id) async {
      requests.add(id);
      return null;
    });
    addTearDown(() {
      cache.setMissingThumbnailResolver(null);
      cache.clearMemoryCache();
    });
    final navigator = GlobalKey<NavigatorState>();
    final scroll = ScrollController();
    final coverId = ValueNotifier('deferred-cover');
    addTearDown(coverId.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox()),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: coverId,
            builder: (_, id, _) => MediaLibraryCardPreload(
              controller: scroll,
              contents: [
                VideoCollection(
                  id: id,
                  name: 'folder',
                  createTime: 0,
                  thumbnailPath: 'missing-motion-test.png',
                ),
              ],
              geometry: const MediaLibraryGridGeometry(
                crossAxisCount: 1,
                itemWidth: 100,
                itemHeight: 100,
                horizontalSpacing: 0,
                verticalSpacing: 0,
                horizontalPadding: 0,
                topPadding: 0,
              ),
              thumbnailWidth: 100,
              thumbnailHeight: 100,
              child: ListView(
                controller: scroll,
                children: const [SizedBox(height: 100)],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    expect(requests, isEmpty);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(requests, ['deferred-cover']);

    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const SizedBox()),
    );
    await tester.pumpAndSettle();
    // New optional work on the covered page must also wait for pop to finish.
    coverId.value = 'return-cover';
    await tester.pump();
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    expect(requests, ['deferred-cover']);
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(requests, ['deferred-cover', 'return-cover']);
    await tester.pumpWidget(const SizedBox());
  });
}
