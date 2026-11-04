import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:video_player_app/platform/ambient_frame_thumbnail.dart';

AmbientFrameSnapshot _snapshot({
  VideoParams params = const VideoParams(
    w: 192,
    h: 108,
    dw: 192,
    dh: 108,
    par: 1,
    rotate: 0,
  ),
  Map<String, String> overrides = const {},
}) => AmbientFrameSnapshot(
  videoParams: params,
  outputProperties: {
    'video-out-params/w': '${params.w}',
    'video-out-params/h': '${params.h}',
    'video-out-params/dw': '${params.dw}',
    'video-out-params/dh': '${params.dh}',
    'video-out-params/par': '${params.par}',
    'video-out-params/rotate': '${params.rotate}',
    'vf': '',
    ...overrides,
  },
);

Uint8List _solid(
  int width,
  int height, {
  int red = 200,
  int green = 40,
  int blue = 12,
}) {
  final result = Uint8List(width * height * 4);
  for (var offset = 0; offset < result.length; offset += 4) {
    result[offset] = blue;
    result[offset + 1] = green;
    result[offset + 2] = red;
    result[offset + 3] = (offset ~/ 4) % 256;
  }
  return result;
}

VideoParams _sdrParams({
  String? gamma = 'bt.1886',
  String? primaries = 'bt.709',
  String? colormatrix = 'bt.709',
  String? colorlevels = 'limited',
  double? sigPeak = 1,
  String? light = 'display',
  String? alpha,
  int rotate = 0,
}) => VideoParams(
  w: 192,
  h: 108,
  dw: 192,
  dh: 108,
  par: 1,
  rotate: rotate,
  gamma: gamma,
  primaries: primaries,
  colormatrix: colormatrix,
  colorlevels: colorlevels,
  sigPeak: sigPeak,
  light: light,
  alpha: alpha,
);

void main() {
  test(
    'verified Android SDR captures restore the original renderer before encoding',
    () async {
      var option = 'no';
      final writes = <String>[];
      final snapshot = _snapshot(params: _sdrParams());
      final result = await captureAmbientThumbnail(
        readSnapshot: () async => snapshot,
        captureRaw: () async {
          expect(option, 'yes');
          return _solid(192, 108);
        },
        captureJpeg: () async =>
            fail('Verified SDR uses the small raw encoder'),
        isCurrent: () => true,
        softwareForVerifiedSdr: true,
        readSoftwareOption: () async => option,
        writeSoftwareOption: (value) async {
          writes.add(value);
          option = value;
        },
        encodeThumbnail: (_) async {
          expect(option, 'no');
          return Uint8List.fromList([1]);
        },
      );
      expect(result, [1]);
      expect(writes, ['yes', 'no']);
      expect(option, 'no');
    },
  );

  test(
    'unknown SDR metadata, HDR, rotation and alpha retain the original JPEG renderer',
    () async {
      for (final params in [
        _sdrParams(gamma: null),
        _sdrParams(gamma: 'pq'),
        _sdrParams(gamma: 'hlg'),
        _sdrParams(primaries: 'bt.2020'),
        _sdrParams(colormatrix: 'bt.2020-ncl'),
        _sdrParams(colorlevels: null),
        _sdrParams(sigPeak: null),
        _sdrParams(sigPeak: 10),
        _sdrParams(light: null),
        _sdrParams(alpha: 'premul'),
        _sdrParams(rotate: 90),
      ]) {
        var jpegCalls = 0;
        final result = await captureAmbientThumbnail(
          readSnapshot: () async => _snapshot(params: params),
          captureRaw: () async =>
              fail('Unverified media must not request software raw capture'),
          captureJpeg: () async {
            jpegCalls++;
            return Uint8List.fromList([3]);
          },
          isCurrent: () => true,
          softwareForVerifiedSdr: true,
          readSoftwareOption: () async =>
              fail('Unverified media must not query the renderer option'),
          writeSoftwareOption: (_) async =>
              fail('Unverified media must not change renderer options'),
        );
        expect(result, [3]);
        expect(jpegCalls, 1);
      }
    },
  );

  test(
    'other platforms retain their renderer while using the existing small conversion',
    () async {
      final result = await captureAmbientThumbnail(
        readSnapshot: () async => _snapshot(params: _sdrParams()),
        captureRaw: () async => _solid(192, 108),
        captureJpeg: () async =>
            fail('A safe raw frame still supports the small encoder'),
        isCurrent: () => true,
        softwareForVerifiedSdr: false,
        readSoftwareOption: () async =>
            fail('The renderer is unchanged outside the Android policy'),
        writeSoftwareOption: (_) async =>
            fail('The renderer is unchanged outside the Android policy'),
        encodeThumbnail: (_) async => Uint8List.fromList([4]),
      );
      expect(result, [4]);
    },
  );

  test(
    'unknown screenshot option falls back without writing a guessed original',
    () async {
      final result = await captureAmbientThumbnail(
        readSnapshot: () async => _snapshot(params: _sdrParams()),
        captureRaw: () async =>
            fail('Unknown options must not request raw capture'),
        captureJpeg: () async => Uint8List.fromList([5]),
        isCurrent: () => true,
        softwareForVerifiedSdr: true,
        readSoftwareOption: () async => '',
        writeSoftwareOption: (_) async =>
            fail('Unknown options remain untouched'),
      );
      expect(result, [5]);
    },
  );

  test(
    'a simultaneous full cover and diagnostic wait for the thumbnail option restore',
    () async {
      final queue = AmbientCaptureQueue();
      var option = 'no';
      final entered = Completer<void>();
      final raw = Completer<Uint8List?>();
      final events = <String>[];
      final thumbnail = queue.run<Uint8List>(
        isCurrent: () => true,
        capture: () => captureAmbientThumbnail(
          readSnapshot: () async => _snapshot(params: _sdrParams()),
          captureRaw: () {
            events.add('raw:$option');
            entered.complete();
            return raw.future;
          },
          captureJpeg: () async => fail('No fallback expected'),
          isCurrent: () => true,
          softwareForVerifiedSdr: true,
          readSoftwareOption: () async => option,
          writeSoftwareOption: (value) async {
            option = value;
            events.add('option:$value');
          },
          encodeThumbnail: (_) async {
            events.add('encode:$option');
            return Uint8List.fromList([1]);
          },
        ),
      );
      await entered.future;
      final cover = queue.run<Uint8List>(
        isCurrent: () => true,
        capture: () async {
          events.add('full-cover:$option');
          return Uint8List.fromList([2, 2]);
        },
      );
      final diagnostic = queue.run<int>(
        isCurrent: () => true,
        capture: () async {
          events.add('diagnostic:$option');
          return 3;
        },
      );
      expect(events, ['option:yes', 'raw:yes']);
      raw.complete(_solid(192, 108));
      expect(await thumbnail, [1]);
      expect(await cover, [2, 2]);
      expect(await diagnostic, 3);
      expect(events, [
        'option:yes',
        'raw:yes',
        'option:no',
        'encode:no',
        'full-cover:no',
        'diagnostic:no',
      ]);
    },
  );

  test(
    'failed restoration suppresses the current fallback and later cover captures',
    () async {
      final queue = AmbientCaptureQueue();
      var option = 'no';
      var jpegCalls = 0;
      var coverCalls = 0;
      final result = await queue.run<Uint8List>(
        isCurrent: () => true,
        capture: () => captureAmbientThumbnail(
          readSnapshot: () async => _snapshot(params: _sdrParams()),
          captureRaw: () async => _solid(192, 108),
          captureJpeg: () async {
            jpegCalls++;
            return Uint8List(1);
          },
          isCurrent: () => true,
          softwareForVerifiedSdr: true,
          readSoftwareOption: () async => option,
          // Simulate a native setter silently failing to restore the old value.
          writeSoftwareOption: (value) async {
            if (value == 'yes') option = value;
          },
          onSoftwareRestoreFailure: queue.block,
          encodeThumbnail: (_) async =>
              fail('A failed restore must not publish a frame'),
        ),
      );
      expect(result, isNull);
      expect(jpegCalls, 0);
      final cover = await queue.run<Uint8List>(
        isCurrent: () => true,
        capture: () async {
          coverCalls++;
          return Uint8List(1);
        },
      );
      expect(cover, isNull);
      expect(coverCalls, 0);
    },
  );

  test(
    'failed software setup or raw capture restores before the legacy JPEG fallback',
    () async {
      for (final failure in ['setup', 'capture']) {
        var option = 'no';
        final writes = <String>[];
        var jpegCalls = 0;
        final result = await captureAmbientThumbnail(
          readSnapshot: () async => _snapshot(params: _sdrParams()),
          captureRaw: () async {
            expect(failure, 'capture');
            expect(option, 'yes');
            throw StateError('raw capture failed');
          },
          captureJpeg: () async {
            expect(option, 'no');
            jpegCalls++;
            return Uint8List.fromList([6]);
          },
          isCurrent: () => true,
          softwareForVerifiedSdr: true,
          readSoftwareOption: () async => option,
          writeSoftwareOption: (value) async {
            writes.add(value);
            if (failure == 'setup' && value == 'yes') {
              throw StateError('setter failed');
            }
            option = value;
          },
        );
        expect(result, [6]);
        expect(writes, ['yes', 'no']);
        expect(jpegCalls, 1);
      }
    },
  );

  test(
    'capture serialization is per player and skips retired queued sessions',
    () async {
      final first = AmbientCaptureQueue();
      final second = AmbientCaptureQueue();
      final gate = Completer<int?>();
      var current = true;
      var staleCalls = 0;
      final pending = first.run<int>(
        isCurrent: () => current,
        capture: () => gate.future,
      );
      final independent = second.run<int>(
        isCurrent: () => true,
        capture: () async => 2,
      );
      expect(await independent, 2);
      final stale = first.run<int>(
        isCurrent: () => current,
        capture: () async {
          staleCalls++;
          return 3;
        },
      );
      current = false;
      gate.complete(1);
      await pending;
      expect(await stale, isNull);
      expect(staleCalls, 0);
    },
  );

  test('only explicit unchanged square-pixel output supports raw geometry', () {
    final before = _snapshot();
    final geometry = before.geometry()!;
    expect(geometry.width, 192);
    expect(geometry.height, 108);
    expect(geometry.outputWidth, 96);
    expect(geometry.outputHeight, 54);
    expect(before.matches(_snapshot()), isTrue);
    expect(geometry.accepts(Uint8List(192 * 108 * 4)), isTrue);
    expect(geometry.accepts(Uint8List(192 * 108 * 4 + 16)), isFalse);
    expect(geometry.accepts(Uint8List(192 * 108 * 4 - 1)), isFalse);
  });

  test(
    'unknown, SAR, rotation, output filters and changed dimensions fall back',
    () {
      for (final params in [
        const VideoParams(),
        const VideoParams(w: 192, h: 108, dw: 192, dh: 108, rotate: 0),
        const VideoParams(w: 192, h: 108, dw: 192, dh: 108, par: 1),
        const VideoParams(
          w: 192,
          h: 108,
          dw: 256,
          dh: 108,
          par: 4 / 3,
          rotate: 0,
        ),
        const VideoParams(w: 192, h: 108, dw: 108, dh: 192, par: 1, rotate: 90),
        const VideoParams(
          w: 192,
          h: 108,
          dw: 192,
          dh: 108,
          par: 1,
          rotate: 180,
        ),
        const VideoParams(
          w: 192,
          h: 108,
          dw: 192,
          dh: 108,
          par: 1,
          rotate: 0,
          aspect: 1,
        ),
        const VideoParams(
          w: -192,
          h: 108,
          dw: -192,
          dh: 108,
          par: 1,
          rotate: 0,
        ),
        const VideoParams(
          w: 192,
          h: 108,
          dw: 192,
          dh: 108,
          par: 1,
          rotate: 0,
          stereoIn: 'sbs2l',
        ),
      ]) {
        expect(_snapshot(params: params).geometry(), isNull, reason: '$params');
      }
      for (final properties in <Map<String, String>>[
        {'video-out-params/par': ''},
        {'video-out-params/rotate': ''},
        {'video-out-params/w': ''},
        {'video-out-params/dh': '109'},
        {'video-out-params/par': 'NaN'},
        {'vf': 'scale=144:144'},
        // Same pixel count as 192x108, but a different packed row layout.
        {'video-out-params/w': '144', 'video-out-params/h': '144'},
      ]) {
        expect(_snapshot(overrides: properties).geometry(), isNull);
      }
      final missing = Map<String, String>.of(_snapshot().outputProperties)
        ..remove('vf');
      expect(
        AmbientFrameSnapshot(
          videoParams: _snapshot().videoParams,
          outputProperties: missing,
        ).geometry(),
        isNull,
      );
    },
  );

  test('BGR channel order ignores the unspecified fourth byte', () {
    final bytes = Uint8List.fromList([
      for (var y = 0; y < 2; y++) ...[
        0,
        0,
        255,
        0,
        0,
        0,
        255,
        73,
        255,
        0,
        0,
        255,
        255,
        0,
        0,
        3,
      ],
    ]);
    expect(
      downsampleAmbientBgra(
        AmbientBgraThumbnail(bytes, const AmbientThumbnailGeometry(4, 2, 2, 1)),
      ),
      [255, 0, 0, 0, 0, 255],
    );
  });

  test('integer blocks area-average fine detail instead of aliasing it', () {
    final bytes = Uint8List.fromList([
      for (var y = 0; y < 4; y++)
        for (var x = 0; x < 4; x++)
          for (final channel in [0, 1, 2, 3])
            channel == 3 ? 0 : ((x + y).isEven ? 0 : 255),
    ]);
    expect(
      downsampleAmbientBgra(
        AmbientBgraThumbnail(bytes, const AmbientThumbnailGeometry(4, 4, 2, 2)),
      ),
      List.filled(12, 128),
    );
  });

  test('fractional pixel coverage is included on both axes', () {
    final bytes = Uint8List.fromList([
      for (var y = 0; y < 3; y++) ...[
        0,
        0,
        255,
        0,
        0,
        255,
        0,
        128,
        255,
        0,
        0,
        255,
      ],
    ]);
    expect(
      downsampleAmbientBgra(
        AmbientBgraThumbnail(bytes, const AmbientThumbnailGeometry(3, 3, 2, 2)),
      ),
      [170, 85, 0, 0, 85, 170, 170, 85, 0, 0, 85, 170],
    );
  });

  test(
    'fractional area weights match an independent supersampled-grid reference',
    () {
      const width = 5;
      const height = 7;
      const outWidth = 3;
      const outHeight = 4;
      final bytes = Uint8List.fromList([
        for (var y = 0; y < height; y++)
          for (var x = 0; x < width; x++) ...[
            (x * 71 + y * 13) % 256,
            (x * 17 + y * 31) % 256,
            (x * 29 + y * 47) % 256,
            0,
          ],
      ]);
      // Expand each original pixel to outWidth x outHeight uniform cells, then
      // average sourceWidth x sourceHeight cell blocks. This reference uses no
      // interval-edge weights or branches from the production implementation.
      final expected = <int>[];
      for (var y = 0; y < outHeight; y++) {
        for (var x = 0; x < outWidth; x++) {
          for (final channel in [2, 1, 0]) {
            var sum = 0;
            for (var dy = 0; dy < height; dy++) {
              for (var dx = 0; dx < width; dx++) {
                final sx = (x * width + dx) ~/ outWidth;
                final sy = (y * height + dy) ~/ outHeight;
                sum += bytes[(sy * width + sx) * 4 + channel];
              }
            }
            expected.add((sum + width * height ~/ 2) ~/ (width * height));
          }
        }
      }
      expect(
        downsampleAmbientBgra(
          AmbientBgraThumbnail(
            bytes,
            const AmbientThumbnailGeometry(width, height, outWidth, outHeight),
          ),
        ),
        expected,
      );
    },
  );

  test(
    'only the small RGB image is JPEG encoded with the original proportions',
    () {
      final geometry = _snapshot().geometry()!;
      final jpeg = encodeAmbientBgraThumbnail(
        AmbientBgraThumbnail(_solid(192, 108), geometry),
      )!;
      final decoded = img.decodeJpg(jpeg)!;
      expect(decoded.width, 96);
      expect(decoded.height, 54);
      final pixel = decoded.getPixel(48, 27);
      expect(pixel.r, closeTo(200, 3));
      expect(pixel.g, closeTo(40, 3));
      expect(pixel.b, closeTo(12, 3));
      expect(
        encodeAmbientBgraThumbnail(
          AmbientBgraThumbnail(Uint8List(8), geometry),
        ),
        isNull,
      );
    },
  );

  test(
    'valid raw capture encodes after the public screenshot future completes',
    () async {
      final calls = <String>[];
      final raw = Completer<Uint8List?>();
      final result = captureAmbientThumbnail(
        readSnapshot: () async => _snapshot(),
        captureRaw: () {
          calls.add('raw');
          return raw.future;
        },
        captureJpeg: () async {
          calls.add('jpeg');
          return Uint8List(1);
        },
        isCurrent: () => true,
        encodeThumbnail: (_) async {
          calls.add('encode');
          return Uint8List.fromList([42]);
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['raw']);
      raw.complete(_solid(192, 108));
      expect(await result, [42]);
      expect(calls, ['raw', 'encode']);
    },
  );

  test('unknown metadata does not request raw pixels', () async {
    var rawCalls = 0;
    final result = await captureAmbientThumbnail(
      readSnapshot: () async => null,
      captureRaw: () async {
        rawCalls++;
        return _solid(192, 108);
      },
      captureJpeg: () async => Uint8List.fromList([7, 8]),
      isCurrent: () => true,
    );
    expect(result, [7, 8]);
    expect(rawCalls, 0);
  });

  test(
    'the production compute path encodes only the small owned image',
    () async {
      final jpeg = await captureAmbientThumbnail(
        readSnapshot: () async => _snapshot(),
        captureRaw: () async => _solid(192, 108),
        captureJpeg: () async =>
            fail('A verified packed frame must use the small encoder'),
        isCurrent: () => true,
      );
      final decoded = img.decodeJpg(jpeg!)!;
      expect(decoded.width, 96);
      expect(decoded.height, 54);
    },
  );

  test(
    'padding, truncated data and changing metadata keep the original JPEG fallback',
    () async {
      for (final mode in ['padding', 'truncated', 'changed']) {
        var reads = 0;
        var encodes = 0;
        var jpegCalls = 0;
        final result = await captureAmbientThumbnail(
          readSnapshot: () async => mode == 'changed' && reads++ > 0
              ? _snapshot(
                  overrides: {
                    'video-out-params/w': '144',
                    'video-out-params/h': '144',
                  },
                )
              : _snapshot(),
          captureRaw: () async => Uint8List(
            192 * 108 * 4 +
                (mode == 'padding'
                    ? 16
                    : mode == 'truncated'
                    ? -1
                    : 0),
          ),
          captureJpeg: () async {
            jpegCalls++;
            return Uint8List.fromList([9]);
          },
          isCurrent: () => true,
          encodeThumbnail: (_) async {
            encodes++;
            return Uint8List(1);
          },
        );
        expect(result, [9]);
        expect(encodes, 0);
        expect(jpegCalls, 1);
      }
    },
  );

  test(
    'retiring the session while raw capture is pending discards its owned copy',
    () async {
      var current = true;
      var encodes = 0;
      var jpegCalls = 0;
      final raw = Completer<Uint8List?>();
      final result = captureAmbientThumbnail(
        readSnapshot: () async => _snapshot(),
        captureRaw: () => raw.future,
        captureJpeg: () async {
          jpegCalls++;
          return Uint8List(1);
        },
        isCurrent: () => current,
        encodeThumbnail: (_) async {
          encodes++;
          return Uint8List(1);
        },
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      raw.complete(_solid(192, 108));
      expect(await result, isNull);
      expect(encodes, 0);
      expect(jpegCalls, 0);
    },
  );

  test(
    'retiring a session during encoding cannot publish its thumbnail',
    () async {
      var current = true;
      final entered = Completer<void>();
      final encoded = Completer<Uint8List?>();
      final result = captureAmbientThumbnail(
        readSnapshot: () async => _snapshot(),
        captureRaw: () async => _solid(192, 108),
        captureJpeg: () async =>
            fail('Disposed captures must not request fallback screenshots'),
        isCurrent: () => current,
        encodeThumbnail: (_) {
          entered.complete();
          return encoded.future;
        },
      );
      await entered.future;
      current = false;
      encoded.complete(Uint8List.fromList([1]));
      expect(await result, isNull);
    },
  );

  test(
    'geometry changing during encoding uses the original JPEG path',
    () async {
      var changed = false;
      final result = await captureAmbientThumbnail(
        readSnapshot: () async => changed
            ? _snapshot(overrides: {'vf': 'crop=144:144'})
            : _snapshot(),
        captureRaw: () async => _solid(192, 108),
        captureJpeg: () async => Uint8List.fromList([12]),
        isCurrent: () => true,
        encodeThumbnail: (_) async {
          changed = true;
          return Uint8List.fromList([2]);
        },
      );
      expect(result, [12]);
    },
  );

  test(
    'failed raw or JPEG capture is contained without releasing outside the native API',
    () async {
      final result = await captureAmbientThumbnail(
        readSnapshot: () async => _snapshot(),
        captureRaw: () async => throw StateError('raw unavailable'),
        captureJpeg: () async => throw StateError('native player disposed'),
        isCurrent: () => true,
      );
      expect(result, isNull);
    },
  );
}
