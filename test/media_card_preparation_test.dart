import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/media_cache/media_cache_hooks.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/services/thumbnail_cache_service.dart';
import 'package:video_player_app/widgets/cached_thumbnail_widget.dart';
import 'package:video_player_app/widgets/media_library_grid_card.dart';
import 'package:video_player_app/widgets/media_card_preparation.dart';
import 'media_cache_service_test.dart' show FakeBackend, source;

Future<File> _cover(Directory root) async {
  final recorder = ui.PictureRecorder();
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = Colors.green);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return File(
    '${root.path}/cover.png',
  ).writeAsBytes(bytes!.buffer.asUint8List());
}

Future<List<int>> _pixel(WidgetTester tester, GlobalKey boundary) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 1);
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final offset = (20 * image.width + 20) * 4;
    final pixel = data.buffer.asUint8List().sublist(offset, offset + 4);
    image.dispose();
    return pixel;
  }))!;
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File cover;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('prepared-card-');
    cover = await _cover(root);
    ThumbnailCacheService().clearMemoryCache();
  });
  tearDown(() async {
    ThumbnailCacheService().setMissingThumbnailResolver(null);
    ThumbnailCacheService().clearMemoryCache();
    await root.delete(recursive: true);
  });

  testWidgets(
    'decoded cover, text and verified badge share their first paint',
    (tester) async {
      final previous = MediaCacheService.instance;
      final discover = MediaCacheHooks.discover;
      final material = Completer<List<CacheVariant>>();
      final service = MediaCacheService(
        backend: FakeBackend(root),
        journal: File('${root.path}/journal.json'),
        observeNetwork: false,
      );
      MediaCacheService.instance = service;
      MediaCacheHooks.discover = (_) => material.future;
      final boundary = GlobalKey();
      var taps = 0;
      final item = source().toItem();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundary,
                child: SizedBox(
                  width: 240,
                  height: 160,
                  child: MediaLibraryGridCard(
                    radius: 8,
                    isSelected: false,
                    cacheItem: item,
                    onTap: () => taps++,
                    child: Column(
                      children: [
                        SizedBox(
                          height: 110,
                          width: 240,
                          child: CachedThumbnailWidget(
                            videoId: item.id,
                            thumbnailPath: cover.path,
                          ),
                        ),
                        const Text('complete title'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await _flush(tester);
        expect(await _pixel(tester, boundary), [29, 31, 35, 255]);
        await tester.tap(find.text('complete title'), warnIfMissed: false);
        expect(taps, 0);
        final file = await tester.runAsync(
          () => File('${root.path}/media.mp4').writeAsBytes([1, 2, 3, 4]),
        );
        material.complete([
          CacheVariant(
            source: source(),
            quality: const CacheQuality(id: '720', label: '720P'),
            path: file!.path,
            bytes: 4,
            createdAt: 1,
          ),
        ]);
        await _flush(tester);
        expect(find.byKey(const ValueKey('cache-card-badge')), findsOneWidget);
        expect(await _pixel(tester, boundary), [76, 175, 80, 255]);
        await tester.tap(find.text('complete title'));
        expect(taps, 1);
        expect(
          service.ready,
          isFalse,
          reason: 'Painting a card must not start the queue',
        );
      } finally {
        if (!material.isCompleted) material.complete([]);
        await tester.pumpWidget(const SizedBox.shrink());
        MediaCacheHooks.discover = discover;
        MediaCacheService.instance = previous;
        service.dispose();
      }
    },
  );

  testWidgets('late thumbnail replaces two-second fallback without scrolling', (
    tester,
  ) async {
    final pending = Completer<String?>();
    ThumbnailCacheService().setMissingThumbnailResolver((_) => pending.future);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox.square(
              dimension: 100,
              child: MediaCardPreparationHost(
                child: CachedThumbnailWidget(
                  videoId: 'late',
                  errorWidget: const ColoredBox(color: Colors.red),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _flush(tester);
    expect(await _pixel(tester, boundary), [29, 31, 35, 255]);
    await tester.pump(const Duration(seconds: 2));
    expect(await _pixel(tester, boundary), [244, 67, 54, 255]);
    pending.complete(cover.path);
    await _flush(tester);
    expect(await _pixel(tester, boundary), [76, 175, 80, 255]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recycling an unresolved card cannot replace its new cover', (
    tester,
  ) async {
    final pending = Completer<String?>();
    ThumbnailCacheService().setMissingThumbnailResolver((_) => pending.future);
    final boundary = GlobalKey();
    Widget card(String id, String? path) => MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: boundary,
          child: SizedBox.square(
            dimension: 100,
            child: MediaCardPreparationHost(
              child: CachedThumbnailWidget(videoId: id, thumbnailPath: path),
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(card('old', null));
    await _flush(tester);
    await tester.pumpWidget(card('new', cover.path));
    await _flush(tester);
    expect(await _pixel(tester, boundary), [76, 175, 80, 255]);
    pending.complete(null);
    await _flush(tester);
    expect(await _pixel(tester, boundary), [76, 175, 80, 255]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
