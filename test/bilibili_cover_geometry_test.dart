import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/utils/bilibili_image_url.dart';
import 'package:video_player_app/widgets/bilibili_cover_geometry_image.dart';

class _DeferredCover extends ImageProvider<_DeferredCover> {
  final frame = Completer<ImageInfo>();
  int loads = 0;

  @override
  Future<_DeferredCover> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _DeferredCover key,
    ImageDecoderCallback decode,
  ) {
    loads++;
    return OneFrameImageStreamCompleter(frame.future);
  }

  Future<void> complete(int width, int height) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0xFF808080), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    frame.complete(ImageInfo(image: image));
  }
}

void main() {
  test(
    'natural cover resize removes an old crop without changing the allowed host rules',
    () {
      expect(
        bilibiliCoverNaturalUrl(
          'https://i0.hdslb.com/bfs/archive/cover.jpg@320w_200h_1c.webp',
          800,
        ),
        'https://i0.hdslb.com/bfs/archive/cover.jpg@960w.webp',
      );
      expect(
        bilibiliCoverNaturalUrl('https://untrusted.example/cover.jpg', 800),
        isNull,
      );
    },
  );

  testWidgets('a late previous image cannot change the new cover geometry', (
    tester,
  ) async {
    final oldCover = _DeferredCover();
    final newCover = _DeferredCover();
    final sizes = <double>[];
    Future<void> show(_DeferredCover image) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: BilibiliCoverGeometryImage(
          image: image,
          onAspectRatio: sizes.add,
        ),
      ),
    );
    await show(oldCover);
    await show(newCover);
    await tester.runAsync(() => oldCover.complete(9, 16));
    await tester.pump();
    expect(sizes, isEmpty);
    await tester.runAsync(() => newCover.complete(16, 9));
    await tester.pump();
    await tester.pump();
    expect(sizes, [16 / 9]);
    expect(
      newCover.loads,
      1,
      reason: 'The dimension observer and image share a single cache entry',
    );
    await tester.pumpWidget(const SizedBox());
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const ui.Size(9, 16),
    const ui.Size(1, 1),
    const ui.Size(4, 3),
  ]) {
    testWidgets(
      'a cached ${size.width}:${size.height} cover reports its own ratio once',
      (tester) async {
        final cover = _DeferredCover();
        final ratios = <double>[];
        await tester.runAsync(
          () => cover.complete(size.width.toInt(), size.height.toInt()),
        );
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: BilibiliCoverGeometryImage(
              image: cover,
              onAspectRatio: ratios.add,
            ),
          ),
        );
        await tester.pump();
        expect(ratios, [size.aspectRatio]);
        expect(cover.loads, 1);
        await tester.pumpWidget(const SizedBox());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      },
    );
  }
}
