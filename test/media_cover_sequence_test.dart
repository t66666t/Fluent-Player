import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/thumbnail_cache_service.dart';
import 'package:video_player_app/widgets/cached_thumbnail_widget.dart';
import 'package:video_player_app/widgets/media_card_preparation.dart';
import 'package:video_player_app/widgets/media_cover_reveal.dart';

Future<void> _flushImages(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

Future<File> _cover(Directory directory) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.green, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return File(
    '${directory.path}/cover.png',
  ).writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('reveal follows cell order and skips a slow earlier cover', (
    tester,
  ) async {
    final coordinator = MediaCoverRevealCoordinator();
    final order = <int>[];
    final first = coordinator.register(0, () => order.add(0));
    final second = coordinator.register(1, () => order.add(1));
    final third = coordinator.register(2, () => order.add(2));
    third.ready();
    second.ready();
    await tester.pump();
    expect(order, isEmpty);
    await tester.pump(const Duration(milliseconds: 100));
    expect(order, [1, 2]);
    first.ready();
    await tester.pump(const Duration(milliseconds: 18));
    expect(order, [1, 2, 0]);
  });

  testWidgets('disposed cells never delay or receive a reveal', (tester) async {
    final coordinator = MediaCoverRevealCoordinator();
    final order = <int>[];
    final old = coordinator.register(0, () => order.add(0));
    final current = coordinator.register(1, () => order.add(1));
    current.ready();
    await tester.pump();
    old.dispose();
    await tester.pump();
    expect(order, [1]);
  });

  testWidgets('grid cards stay interactive while a late cover loads', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('cover-sequence-'),
    ))!;
    final cover = (await tester.runAsync(() => _cover(root)))!;
    final cache = ThumbnailCacheService()..clearMemoryCache();
    final pending = <String, Completer<String?>>{};
    cache.setMissingThumbnailResolver((id) {
      final result = Completer<String?>();
      pending[id] = result;
      return result.future;
    });
    resetMediaCoverRevealMemory();
    var taps = 0;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
              ),
              itemCount: 3,
              itemBuilder: (_, index) => MediaCoverRevealStamp(
                index: index,
                crossAxisCount: 3,
                child: MediaCardPreparationHost(
                  child: InkWell(
                    onTap: () => taps++,
                    child: Column(
                      children: [
                        Expanded(
                          child: CachedThumbnailWidget(
                            videoId: 'sequence-$index',
                            placeholder: ColoredBox(
                              key: ValueKey('waiting-$index'),
                              color: Colors.black,
                            ),
                          ),
                        ),
                        Text('card $index'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _flushImages(tester);
      expect(pending.length, 3);
      await tester.tap(find.text('card 0'));
      expect(taps, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const ValueKey('waiting-0')), findsOneWidget);

      pending['sequence-1']!.complete(cover.path);
      pending['sequence-2']!.complete(cover.path);
      await _flushImages(tester);
      expect(find.byKey(const ValueKey('image_sequence-1')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 18));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('media-cover-opacity-sequence-1')),
            )
            .opacity,
        1,
      );
      expect(pending['sequence-0']!.isCompleted, isFalse);

      pending['sequence-0']!.complete(cover.path);
      await _flushImages(tester);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('image_sequence-0')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      for (final result in pending.values) {
        if (!result.isCompleted) result.complete(null);
      }
      cache.setMissingThumbnailResolver(null);
      cache.clearMemoryCache();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });

  testWidgets('thousands of cards stay lazy across large scroll jumps', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('cover-grid-'),
    ))!;
    final cover = (await tester.runAsync(() => _cover(root)))!;
    final scroll = ScrollController();
    final cache = ThumbnailCacheService()..clearMemoryCache();
    resetMediaCoverRevealMemory();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: GridView.builder(
            controller: scroll,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
            ),
            itemCount: 5000,
            itemBuilder: (_, index) => MediaCoverRevealStamp(
              index: index,
              crossAxisCount: 4,
              child: MediaCardPreparationHost(
                child: Column(
                  children: [
                    Expanded(
                      child: CachedThumbnailWidget(
                        videoId: 'large-$index',
                        thumbnailPath: cover.path,
                        placeholder: const ColoredBox(color: Colors.black),
                      ),
                    ),
                    Text('tile $index'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await _flushImages(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('tile 0'), findsOneWidget);
      expect(
        find.byType(CachedThumbnailWidget).evaluate().length,
        lessThan(80),
      );

      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await _flushImages(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('tile 4999'), findsOneWidget);
      expect(
        find.byType(CachedThumbnailWidget).evaluate().length,
        lessThan(80),
      );

      scroll.jumpTo(0);
      await tester.pump();
      await _flushImages(tester);
      expect(find.text('tile 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      scroll.dispose();
      cache.clearMemoryCache();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });

  testWidgets('reduced-motion preference shows a decoded cover immediately', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('cover-reduced-motion-'),
    ))!;
    final cover = (await tester.runAsync(() => _cover(root)))!;
    final cache = ThumbnailCacheService()..clearMemoryCache();
    resetMediaCoverRevealMemory();
    try {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: GridView.count(
            crossAxisCount: 1,
            children: [
              MediaCoverRevealStamp(
                index: 0,
                crossAxisCount: 1,
                child: MediaCardPreparationHost(
                  child: CachedThumbnailWidget(
                    videoId: 'reduced-motion',
                    thumbnailPath: cover.path,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await _flushImages(tester);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('media-cover-opacity-reduced-motion')),
            )
            .opacity,
        1,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      cache.clearMemoryCache();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });

  testWidgets('a corrupt cover falls back without blocking the next card', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('cover-invalid-'),
    ))!;
    final cover = (await tester.runAsync(() => _cover(root)))!;
    final broken = (await tester.runAsync(
      () => File('${root.path}/broken.png').writeAsBytes([1, 2, 3]),
    ))!;
    final cache = ThumbnailCacheService()..clearMemoryCache();
    resetMediaCoverRevealMemory();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: GridView.count(
            crossAxisCount: 2,
            children: [
              for (var i = 0; i < 2; i++)
                MediaCoverRevealStamp(
                  index: i,
                  crossAxisCount: 2,
                  child: MediaCardPreparationHost(
                    child: CachedThumbnailWidget(
                      videoId: 'invalid-$i',
                      thumbnailPath: i == 0 ? broken.path : cover.path,
                      errorWidget: const Text('cover unavailable'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      await _flushImages(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('cover unavailable'), findsOneWidget);
      expect(find.byKey(const ValueKey('image_invalid-1')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      cache.clearMemoryCache();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });

  testWidgets('resizing keeps the old cover visible while a new size decodes', (
    tester,
  ) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('cover-resize-'),
    ))!;
    final cover = (await tester.runAsync(() => _cover(root)))!;
    final cache = ThumbnailCacheService()..clearMemoryCache();
    resetMediaCoverRevealMemory();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: GridView.count(
            crossAxisCount: 1,
            children: [
              MediaCoverRevealStamp(
                index: 0,
                crossAxisCount: 1,
                child: MediaCardPreparationHost(
                  child: CachedThumbnailWidget(
                    videoId: 'resize-cover',
                    thumbnailPath: cover.path,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await _flushImages(tester);
      await tester.pump(const Duration(milliseconds: 350));
      final image = find.byKey(const ValueKey('image_resize-cover'));
      final opacity = find.byKey(
        const ValueKey('media-cover-opacity-resize-cover'),
      );
      expect(image, findsOneWidget);
      expect(tester.widget<Opacity>(opacity).opacity, 1);

      tester.view.physicalSize = const Size(400, 800);
      await tester.pump();
      expect(image, findsOneWidget);
      expect(tester.widget<Opacity>(opacity).opacity, 1);
      await _flushImages(tester);
      expect(image, findsOneWidget);
      expect(tester.widget<Opacity>(opacity).opacity, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      tester.view.reset();
      cache.clearMemoryCache();
      await tester.runAsync(() => root.delete(recursive: true));
    }
  });
}
