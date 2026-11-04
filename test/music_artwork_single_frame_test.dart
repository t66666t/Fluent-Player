import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image_lib;
import 'package:video_player_app/services/music_artwork_backdrop_cache.dart';

void main() {
  for (final format in ['gif', 'apng']) {
    test(
      '$format backdrop matches the original composited first frame',
      () async {
        final animation = _animation();
        final encoded = format == 'gif'
            ? image_lib.encodeGif(animation)
            : image_lib.encodePng(animation);
        final original = image_lib.decodeImage(encoded)!;
        expect(original.numFrames, 5);
        await _matchesOriginalFirstFrame(encoded, original);
      },
    );
  }

  for (final alpha in [false, true]) {
    test(
      'indexed APNG preserves original resize representation; alpha=$alpha',
      () async {
        final encoded = _indexedAnimation(alpha: alpha);
        final original = image_lib.decodePng(encoded)!;
        final first = image_lib.decodePng(encoded, frame: 0)!;
        expect(original.numFrames, 2);
        expect(first.hasPalette, isTrue);
        expect(original.hasPalette, isFalse);
        expect(original.numChannels, alpha ? 4 : 3);
        // Identical source colors alone are insufficient: copyResize forces
        // nearest sampling for palettes, while the original APNG decoder
        // expands the first frame and permits the existing average filter.
        await _matchesOriginalFirstFrame(encoded, original);
      },
    );
  }

  test(
    'static indexed PNG retains its original palette resize policy',
    () async {
      final encoded = image_lib.encodePng(_indexedChecker(alpha: true));
      final original = image_lib.decodePng(encoded)!;
      expect(original.numFrames, 1);
      expect(original.hasPalette, isTrue);
      await _matchesOriginalFirstFrame(encoded, original);
    },
  );

  test(
    'a static GIF backdrop does not decode the unused animation frames',
    () async {
      // Repeat encoded frame blocks, avoiding a large allocation in the fixture
      // itself. Every frame is valid; decoding all 257 1024x1024 frames would
      // exceed the installed decoder's total-animation pixel budget.
      final source = image_lib.fill(
        image_lib.Image(width: 1024, height: 1024),
        color: image_lib.ColorRgb8(60, 90, 150),
      );
      final single = image_lib.encodeGif(source);
      expect(single[10] & 0x80, 0, reason: 'fixture uses local color tables');
      final frames = BytesBuilder(copy: false)..add(single.sublist(0, 13));
      final block = single.sublist(13, single.length - 1);
      for (var i = 0; i < 257; i++) {
        frames.add(block);
      }
      frames.addByte(0x3b);
      final encoded = frames.takeBytes();
      final decoder = image_lib.GifDecoder();
      expect(decoder.startDecode(encoded)!.numFrames, 257);
      expect(
        () => image_lib.decodeGif(encoded),
        throwsA(isA<image_lib.ImageException>()),
      );
      final first = image_lib.decodeGif(encoded, frame: 0)!;
      expect(first.width, 1024);
      expect(first.height, 1024);
      await _matchesOriginalFirstFrame(encoded, first);
    },
  );

  test(
    'partial-frame animated WebP retains the existing canvas composition',
    () async {
      final encoded = _partialWebp();
      final original = image_lib.decodeImage(encoded)!;
      final fragment = image_lib.decodeImage(encoded, frame: 0)!;
      expect(original.numFrames, 2);
      expect((original.width, original.height), (32, 24));
      expect((fragment.width, fragment.height), (12, 10));
      // Selecting raw frame zero here would lose its offset and full canvas.
      // Keep this format on the established decoder path.
      await _matchesOriginalFirstFrame(encoded, original);
    },
  );
}

Uint8List _indexedAnimation({required bool alpha}) {
  // The convenience animated encoder requantizes palettes to RGB. Write the
  // already indexed frames directly so the alpha fixture retains its tRNS.
  final encoder = image_lib.PngEncoder()
    ..start(2)
    ..addFrame(_indexedChecker(alpha: alpha))
    ..addFrame(_indexedChecker(alpha: alpha));
  return encoder.finish()!;
}

image_lib.Image _indexedChecker({required bool alpha}) {
  final palette = image_lib.PaletteUint8(2, alpha ? 4 : 3)
    ..setRgba(0, 240, 10, 10, 255)
    ..setRgba(1, 10, 10, 240, alpha ? 0 : 255);
  final image = image_lib.Image(
    width: 288,
    height: 288,
    numChannels: 1,
    palette: palette,
  );
  for (final pixel in image) {
    image.setPixelIndex(pixel.x, pixel.y, (pixel.x + pixel.y) % 2);
  }
  return image;
}

image_lib.Image _animation() {
  final first = image_lib.Image(width: 32, height: 24, numChannels: 4);
  for (final pixel in first) {
    first.setPixelRgba(
      pixel.x,
      pixel.y,
      pixel.x * 7,
      pixel.y * 10,
      150,
      pixel.x < 8 ? 0 : 255,
    );
  }
  for (var i = 1; i < 5; i++) {
    first.addFrame(
      image_lib.fill(
        image_lib.Image(width: 32, height: 24, numChannels: 4),
        color: image_lib.ColorRgba8(210, 40 * i, 20, 255),
      ),
    );
  }
  return first;
}

Future<void> _matchesOriginalFirstFrame(
  Uint8List encoded,
  image_lib.Image original,
) async {
  final cache = MusicArtworkBackdropCache.instance..clearForTest();
  final directory = await Directory.systemTemp.createTemp('artwork-frame-');
  try {
    final animatedFile = File('${directory.path}/animated.image');
    final firstFile = File('${directory.path}/original-first.png');
    await animatedFile.writeAsBytes(encoded);
    // The original code resizes every animation frame, but its opaque pixel
    // loop reads only the first one. Preserve exactly those decoded pixels,
    // including palette/alpha handling, as the reference still image.
    await firstFile.writeAsBytes(
      image_lib.encodePng(original, singleFrame: true),
    );
    final expected = await cache.warm(firstFile.path);
    final actual = await cache.warm(animatedFile.path);
    expect(actual, isNotNull);
    expect(actual, orderedEquals(expected!));
    expect(await animatedFile.readAsBytes(), orderedEquals(encoded));
    expect(identical(cache.peek(animatedFile.path), actual), isTrue);
  } finally {
    cache.clearForTest();
    await directory.delete(recursive: true);
  }
}

Uint8List _partialWebp() {
  final image = image_lib.fill(
    image_lib.Image(width: 12, height: 10, numChannels: 4),
    color: image_lib.ColorRgba8(30, 200, 80, 128),
  );
  final frame = image_lib.encodeWebP(image).sublist(12);
  final extended = Uint8List(10)..[0] = 0x12;
  _write24(extended, 4, 31);
  _write24(extended, 7, 23);
  Uint8List animationFrame(int x, int y) {
    final header = Uint8List(16)..[15] = 2;
    _write24(header, 0, x ~/ 2);
    _write24(header, 3, y ~/ 2);
    _write24(header, 6, 11);
    _write24(header, 9, 9);
    _write24(header, 12, 100);
    return (BytesBuilder(copy: false)
          ..add(header)
          ..add(frame))
        .takeBytes();
  }

  final payload =
      (BytesBuilder(copy: false)
            ..add('WEBP'.codeUnits)
            ..add(_chunk('VP8X', extended))
            ..add(_chunk('ANIM', Uint8List(6)))
            ..add(_chunk('ANMF', animationFrame(4, 6)))
            ..add(_chunk('ANMF', animationFrame(12, 8))))
          .takeBytes();
  final length = ByteData(4)..setUint32(0, payload.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add('RIFF'.codeUnits)
        ..add(length.buffer.asUint8List())
        ..add(payload))
      .takeBytes();
}

Uint8List _chunk(String tag, Uint8List data) {
  final length = ByteData(4)..setUint32(0, data.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(tag.codeUnits)
        ..add(length.buffer.asUint8List())
        ..add(data)
        ..add(List.filled(data.length.isOdd ? 1 : 0, 0)))
      .takeBytes();
}

void _write24(Uint8List data, int offset, int value) {
  data[offset] = value & 0xff;
  data[offset + 1] = (value >> 8) & 0xff;
  data[offset + 2] = (value >> 16) & 0xff;
}
