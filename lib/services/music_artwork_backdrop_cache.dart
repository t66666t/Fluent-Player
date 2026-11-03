import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image_lib;

/// Produces a small, heavily blurred artwork bitmap off the UI isolate.
///
/// Stretching this cached bitmap behind the player is substantially cheaper
/// than applying a large real-time blur to a full-screen layer. The small
/// source also creates a stronger Apple Music-like colour wash. Highlights
/// are compressed before caching so white-heavy covers cannot wash out the
/// player's white lyrics, even in the lightest part of its gradient scrim.
class MusicArtworkBackdropCache {
  MusicArtworkBackdropCache._();

  static final MusicArtworkBackdropCache instance =
      MusicArtworkBackdropCache._();

  static const int _maxEntries = 12;
  static const int _targetSize = 144;
  static const int _blurRadius = 22;

  final LinkedHashMap<String, Uint8List> _memory =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List?>> _inFlight =
      <String, Future<Uint8List?>>{};

  Uint8List? peek(String? rawPath) {
    final path = _normalizePath(rawPath);
    if (path == null) return null;
    final bytes = _memory.remove(path);
    if (bytes != null) _memory[path] = bytes;
    return bytes;
  }

  Future<Uint8List?> warm(String? rawPath) {
    final path = _normalizePath(rawPath);
    if (path == null) return Future<Uint8List?>.value(null);

    final cached = peek(path);
    if (cached != null) return Future<Uint8List?>.value(cached);

    final running = _inFlight[path];
    if (running != null) return running;

    final future = _build(path);
    _inFlight[path] = future;
    future.whenComplete(() => _inFlight.remove(path));
    return future;
  }

  Future<Uint8List?> _build(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;

    try {
      final bytes = await compute<Map<String, Object>, Uint8List?>(
        _decodeBlurredArtwork,
        <String, Object>{
          'path': path,
          'targetSize': _targetSize,
          'blurRadius': _blurRadius,
        },
        debugLabel: 'music-artwork-backdrop',
      );
      if (bytes == null) return null;

      _memory[path] = bytes;
      while (_memory.length > _maxEntries) {
        _memory.remove(_memory.keys.first);
      }
      return bytes;
    } catch (error) {
      debugPrint('Music artwork backdrop generation failed: $error');
      return null;
    }
  }

  static String? _normalizePath(String? rawPath) {
    if (rawPath == null || rawPath.trim().isEmpty) return null;
    final value = rawPath.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return null;
    }
    if (value.startsWith('file://')) {
      try {
        return Uri.parse(value).toFilePath(windows: Platform.isWindows);
      } catch (_) {
        return null;
      }
    }
    return value;
  }

  @visibleForTesting
  void clearForTest() {
    _memory.clear();
    _inFlight.clear();
  }

  @visibleForTesting
  void seedForTest(String rawPath, Uint8List bytes) {
    final path = _normalizePath(rawPath);
    if (path != null) _memory[path] = bytes;
  }
}

Uint8List? _decodeBlurredArtwork(Map<String, Object> request) {
  final path = request['path']! as String;
  final targetSize = request['targetSize']! as int;
  final blurRadius = request['blurRadius']! as int;

  final sourceBytes = File(path).readAsBytesSync();
  final decoder = image_lib.findDecoderForData(sourceBytes);
  // The backdrop uses only the first frame. GIF and APNG can decode that
  // frame directly, avoiding full-size buffers for every unused frame.
  // Animated WebP frame zero can be only an offset fragment; retain its
  // established canvas composition, as well as other formats' decoding.
  var decoded =
      decoder is image_lib.GifDecoder || decoder is image_lib.PngDecoder
      ? decoder?.decode(sourceBytes, frame: 0)
      : decoder?.decode(sourceBytes);
  if (decoded == null) return null;
  if (decoder is image_lib.PngDecoder &&
      decoder.info.isAnimated &&
      decoded.hasPalette) {
    // The full APNG decoder expands its first palette frame before resizing.
    // Match that representation so copyResize keeps the existing average
    // interpolation; static indexed PNGs and GIFs retain their palette policy.
    decoded = decoded.convert(numChannels: decoded.numChannels);
  }

  final resized = image_lib.copyResize(
    decoded,
    width: targetSize,
    height: targetSize,
    interpolation: image_lib.Interpolation.average,
  );
  // Flatten transparency at the small working size before blurring. Hidden
  // white RGB values in a transparent PNG must not become a bright backdrop
  // when the result is encoded as an opaque JPEG.
  final opaque = image_lib.Image(width: targetSize, height: targetSize);
  for (final pixel in resized) {
    final alpha = pixel.aNormalized;
    opaque.setPixelRgb(
      pixel.x,
      pixel.y,
      (pixel.rNormalized * 255 * alpha + 36 * (1 - alpha)).round(),
      (pixel.gNormalized * 255 * alpha + 36 * (1 - alpha)).round(),
      (pixel.bNormalized * 255 * alpha + 40 * (1 - alpha)).round(),
    );
  }
  final blurred = image_lib.gaussianBlur(opaque, radius: blurRadius);
  _compressBackdropHighlights(blurred);
  return image_lib.encodeJpg(blurred, quality: 88);
}

/// A soft shoulder in linear-light luminance preserves shadows and colour
/// ratios, unlike clipping RGB channels or darkening every cover uniformly.
/// Limit every pixel, rather than the average: a small bright patch can still
/// sit directly behind a lyric. The existing screen scrim darkens this further.
void _compressBackdropHighlights(image_lib.Image image) {
  const knee = 0.035;
  // Leave headroom for the screen's saturation matrix and JPEG rounding, so
  // even 70%-white translations/controls retain at least 4.5:1 contrast.
  const ceiling = 0.085;
  const shoulder = ceiling - knee;
  final linear = List<double>.generate(256, (channel) {
    final srgb = channel / 255;
    return srgb <= 0.04045
        ? srgb / 12.92
        : math.pow((srgb + 0.055) / 1.055, 2.4).toDouble();
  });

  int encode(double value) {
    final srgb = value <= 0.0031308
        ? value * 12.92
        : 1.055 * math.pow(value, 1 / 2.4) - 0.055;
    return (srgb * 255).round().clamp(0, 255);
  }

  for (final pixel in image) {
    final r = linear[pixel.r.toInt()];
    final g = linear[pixel.g.toInt()];
    final b = linear[pixel.b.toInt()];
    final luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    if (luminance <= knee) continue;

    final excess = luminance - knee;
    final compressed = knee + shoulder * excess / (shoulder + excess);
    final exposure = compressed / luminance;
    pixel
      ..r = encode(r * exposure)
      ..g = encode(g * exposure)
      ..b = encode(b * exposure);
  }
}
