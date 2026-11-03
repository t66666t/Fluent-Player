import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:video_player_app/services/music_artwork_backdrop_cache.dart';

void main() {
  test('backdrop is blurred off-thread and reused from memory', () async {
    final cache = MusicArtworkBackdropCache.instance..clearForTest();
    final tempDirectory = await Directory.systemTemp.createTemp(
      'music_backdrop_cache_test_',
    );
    addTearDown(() async {
      cache.clearForTest();
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
    });

    final source = image_lib.Image(width: 64, height: 64);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(x, y, x * 4, y * 4, 180);
      }
    }
    final sourceFile = File(
      '${tempDirectory.path}${Platform.pathSeparator}cover.png',
    );
    await sourceFile.writeAsBytes(image_lib.encodePng(source), flush: true);

    final generated = await cache.warm(sourceFile.path);
    final reused = cache.peek(sourceFile.path);

    expect(generated, isNotNull);
    expect(identical(generated, reused), isTrue);
    final decoded = image_lib.decodeImage(generated!);
    expect(decoded, isNotNull);
    expect(decoded!.width, 144);
    expect(decoded.height, 144);
  });

  test(
    'white and saturated highlights stay below the luminance ceiling',
    () async {
      final samples = <String, List<int>>{
        'white': [255, 255, 255],
        'ivory': [255, 252, 240],
        'pink': [255, 225, 235],
        'yellow': [255, 255, 0],
        'cyan': [0, 255, 255],
        'green': [0, 255, 0],
        'red': [255, 0, 0],
        'blue': [0, 0, 255],
      };
      for (final sample in samples.entries) {
        final source = _solid(sample.value);
        final backdrop = await _generate(source);
        for (final pixel in backdrop) {
          expect(
            Color.fromARGB(
              255,
              pixel.r.toInt(),
              pixel.g.toInt(),
              pixel.b.toInt(),
            ).computeLuminance(),
            lessThanOrEqualTo(0.09),
            reason: '${sample.key} at ${pixel.x}, ${pixel.y}',
          );
        }
        if (sample.key == 'white') {
          final pixel = backdrop.getPixel(72, 72);
          expect((pixel.r - pixel.g).abs(), lessThanOrEqualTo(1));
          expect((pixel.g - pixel.b).abs(), lessThanOrEqualTo(1));
        }
      }
    },
  );

  test('local white patches are limited even on a mostly dark cover', () async {
    final source = _solid([15, 20, 30]);
    for (var y = 20; y < 44; y++) {
      for (var x = 20; x < 44; x++) {
        source.setPixelRgb(x, y, 255, 255, 255);
      }
    }
    final backdrop = await _generate(source);
    for (final pixel in backdrop) {
      expect(
        Color.fromARGB(
          255,
          pixel.r.toInt(),
          pixel.g.toInt(),
          pixel.b.toInt(),
        ).computeLuminance(),
        lessThanOrEqualTo(0.09),
      );
    }
    expect(backdrop.getPixel(72, 72).r, greaterThan(backdrop.getPixel(0, 0).r));
  });

  test(
    'dark artwork keeps its exposure and bright colours keep their hue',
    () async {
      final dark = await _generate(_solid([26, 36, 50]));
      final darkPixel = dark.getPixel(72, 72);
      expect(darkPixel.r, closeTo(26, 3));
      expect(darkPixel.g, closeTo(36, 3));
      expect(darkPixel.b, closeTo(50, 3));

      final warm = await _generate(_solid([240, 160, 60]));
      final warmPixel = warm.getPixel(72, 72);
      expect(warmPixel.r, greaterThan(warmPixel.g));
      expect(warmPixel.g, greaterThan(warmPixel.b));
      expect(warmPixel.r - warmPixel.b, greaterThan(60));
    },
  );

  test(
    'transparent white pixels use the dark fallback before JPEG encoding',
    () async {
      final source = image_lib.Image(width: 64, height: 64, numChannels: 4);
      image_lib.fill(source, color: image_lib.ColorRgba8(255, 255, 255, 0));
      final backdrop = await _generate(source);
      final pixel = backdrop.getPixel(72, 72);
      expect(pixel.r, closeTo(36, 3));
      expect(pixel.g, closeTo(36, 3));
      expect(pixel.b, closeTo(40, 3));
    },
  );
}

image_lib.Image _solid(List<int> rgb) => image_lib.fill(
  image_lib.Image(width: 64, height: 64),
  color: image_lib.ColorRgb8(rgb[0], rgb[1], rgb[2]),
);

Future<image_lib.Image> _generate(image_lib.Image source) async {
  final cache = MusicArtworkBackdropCache.instance;
  final directory = await Directory.systemTemp.createTemp(
    'music_backdrop_luma_',
  );
  try {
    final file = File('${directory.path}/cover.png');
    final original = image_lib.encodePng(source);
    await file.writeAsBytes(original, flush: true);
    final bytes = await cache.warm(file.path);
    // Only the cached backdrop changes; the album cover remains untouched.
    expect(await file.readAsBytes(), orderedEquals(original));
    expect(bytes, isNotNull);
    return image_lib.decodeImage(bytes!)!;
  } finally {
    cache.clearForTest();
    await directory.delete(recursive: true);
  }
}
