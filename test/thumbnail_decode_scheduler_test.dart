import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/thumbnail_decode_scheduler.dart';

class _ControlledImage extends ImageProvider<_ControlledImage> {
  _ControlledImage(this.name, this.started);

  final String name;
  final List<String> started;
  final Completer<ImageInfo> image = Completer<ImageInfo>();

  @override
  Future<_ControlledImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ControlledImage key,
    ImageDecoderCallback decode,
  ) {
    started.add(name);
    return OneFrameImageStreamCompleter(image.future);
  }

  void complete(ui.Image pixels) =>
      image.complete(ImageInfo(image: pixels.clone()));
}

Future<ui.Image> _pixel(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder);
    return recorder.endRecording().toImage(1, 1);
  }))!;
}

void main() {
  testWidgets('visible decodes outrank prefetches and share a bounded slot', (
    tester,
  ) async {
    final pixel = await _pixel(tester);
    final scheduler = ThumbnailDecodeScheduler(maxConcurrent: 2);
    final started = <String>[];
    final ahead = _ControlledImage('ahead', started);
    final first = _ControlledImage('first', started);
    final second = _ControlledImage('second', started);
    final next = _ControlledImage('next', started);
    const config = ImageConfiguration.empty;

    final prefetch = scheduler.request(
      ahead,
      config,
      priority: ThumbnailDecodeScheduler.prefetchPriority,
    );
    final one = scheduler.request(first, config, priority: 0);
    final shared = scheduler.request(first, config, priority: 0);
    final two = scheduler.request(second, config, priority: 1);
    final three = scheduler.request(next, config, priority: 2);
    await tester.pump();
    expect(started, ['first', 'second']);
    expect(scheduler.activeCount, 2);

    one.dispose();
    expect(await one.ready, isFalse);
    first.complete(pixel);
    await tester.pump();
    expect(await shared.ready, isTrue);
    expect(started, ['first', 'second', 'next']);
    expect(scheduler.activeCount, 2);

    prefetch.dispose();
    second.complete(pixel);
    next.complete(pixel);
    await tester.pump();
    expect(await two.ready, isTrue);
    expect(await three.ready, isTrue);
    expect(await prefetch.ready, isFalse);
    expect(started, isNot(contains('ahead')));
    expect(scheduler.activeCount, 0);

    final cached = scheduler.request(first, config);
    await tester.pump();
    expect(await cached.ready, isTrue);
    expect(started.where((name) => name == 'first').length, 1);
    for (final request in [shared, two, three, cached]) {
      request.dispose();
    }
    PaintingBinding.instance.imageCache.clear();
    pixel.dispose();
  });

  testWidgets('abandoned active work keeps its slot until decoding finishes', (
    tester,
  ) async {
    final pixel = await _pixel(tester);
    final scheduler = ThumbnailDecodeScheduler(maxConcurrent: 2);
    final started = <String>[];
    final providers = List.generate(
      200,
      (i) => _ControlledImage('$i', started),
    );
    final requests = [
      for (final provider in providers)
        scheduler.request(provider, ImageConfiguration.empty),
    ];
    await tester.pump();
    expect(started.length, 2);
    for (final request in requests) {
      request.dispose();
    }
    await tester.pump();
    expect(scheduler.pendingCount, 0);
    expect(scheduler.activeCount, 2);
    providers[0].complete(pixel);
    providers[1].complete(pixel);
    await tester.pump();
    expect(scheduler.activeCount, 0);
    expect(started.length, 2);
    PaintingBinding.instance.imageCache.clear();
    pixel.dispose();
  });

  testWidgets('defers expensive work during fast scrolling and resumes', (
    tester,
  ) async {
    final pixel = await _pixel(tester);
    final scheduler = ThumbnailDecodeScheduler(maxConcurrent: 1);
    final started = <String>[];
    final provider = _ControlledImage('visible', started);
    var scrollingFast = true;
    final request = scheduler.request(
      provider,
      ImageConfiguration.empty,
      shouldDefer: () => scrollingFast,
    );
    await tester.pump();
    expect(started, isEmpty);
    scrollingFast = false;
    await tester.pump(const Duration(milliseconds: 40));
    expect(started, ['visible']);
    provider.complete(pixel);
    await tester.pump();
    expect(await request.ready, isTrue);
    request.dispose();
    PaintingBinding.instance.imageCache.clear();
    pixel.dispose();
  });

  testWidgets('a large queue completes without exceeding its decode budget', (
    tester,
  ) async {
    final pixel = await _pixel(tester);
    final scheduler = ThumbnailDecodeScheduler(maxConcurrent: 3);
    final started = <String>[];
    final providers = List.generate(
      200,
      (i) => _ControlledImage('$i', started),
    );
    final requests = [
      for (final provider in providers)
        scheduler.request(provider, ImageConfiguration.empty),
    ];
    var completed = 0;
    while (completed < providers.length) {
      await tester.pump();
      expect(scheduler.activeCount, lessThanOrEqualTo(3));
      expect(started.length, greaterThan(completed));
      final end = started.length;
      for (; completed < end; completed++) {
        providers[int.parse(started[completed])].complete(pixel);
      }
    }
    await tester.pump();
    expect(
      await Future.wait(requests.map((request) => request.ready)),
      everyElement(isTrue),
    );
    expect(scheduler.activeCount, 0);
    for (final request in requests) {
      request.dispose();
    }
    PaintingBinding.instance.imageCache.clear();
    pixel.dispose();
  });

  testWidgets('a failed decode releases its slot for the next image', (
    tester,
  ) async {
    final pixel = await _pixel(tester);
    final scheduler = ThumbnailDecodeScheduler(maxConcurrent: 1);
    final started = <String>[];
    final broken = _ControlledImage('broken', started);
    final next = _ControlledImage('next', started);
    final first = scheduler.request(broken, ImageConfiguration.empty);
    final second = scheduler.request(next, ImageConfiguration.empty);
    await tester.pump();
    expect(started, ['broken']);
    broken.image.completeError(const FormatException('bad image'));
    await tester.pump();
    expect(await first.ready, isFalse);
    expect(started, ['broken', 'next']);
    next.complete(pixel);
    await tester.pump();
    expect(await second.ready, isTrue);
    expect(scheduler.activeCount, 0);
    first.dispose();
    second.dispose();
    PaintingBinding.instance.imageCache.clear();
    pixel.dispose();
  });
}
