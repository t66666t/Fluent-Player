import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart' show VideoParams;

/// The public raw screenshot API drops mpv's width, height and stride fields.
/// Only interpret its bytes when both decoder and output geometry are known,
/// square-pixel, unrotated and unchanged across the capture.
class AmbientFrameSnapshot {
  AmbientFrameSnapshot({
    required this.videoParams,
    required Map<String, String> outputProperties,
  }) : outputProperties = Map.unmodifiable(outputProperties);

  static const outputPropertyNames = <String>[
    'video-out-params/w',
    'video-out-params/h',
    'video-out-params/dw',
    'video-out-params/dh',
    'video-out-params/par',
    'video-out-params/rotate',
    'vf',
  ];

  final VideoParams videoParams;
  final Map<String, String> outputProperties;

  /// The SDR combination validated on Android hardware. Unknown transfer,
  /// gamut, peak, lighting or alpha metadata keeps the original renderer.
  bool get isVerifiedSdr =>
      videoParams.gamma == 'bt.1886' &&
      videoParams.primaries == 'bt.709' &&
      videoParams.colormatrix == 'bt.709' &&
      videoParams.colorlevels == 'limited' &&
      videoParams.sigPeak == 1.0 &&
      videoParams.light == 'display' &&
      videoParams.alpha == null;

  AmbientThumbnailGeometry? geometry({int targetWidth = 96}) {
    final p = videoParams;
    final w = p.w;
    final h = p.h;
    if (targetWidth < 1 ||
        targetWidth > 96 ||
        w == null ||
        h == null ||
        w <= 0 ||
        h <= 0 ||
        w > 16384 ||
        h > 16384 ||
        p.dw != w ||
        p.dh != h ||
        p.par != 1.0 ||
        p.rotate != 0 ||
        (p.stereoIn != null && p.stereoIn != 'mono')) {
      return null;
    }
    final aspect = p.aspect;
    if (aspect != null &&
        (!aspect.isFinite || (aspect - w / h).abs() > 0.000001)) {
      return null;
    }
    int? integer(String name) => int.tryParse(outputProperties[name] ?? '');
    final filters = outputProperties['vf'];
    if (integer('video-out-params/w') != w ||
        integer('video-out-params/h') != h ||
        integer('video-out-params/dw') != w ||
        integer('video-out-params/dh') != h ||
        double.tryParse(outputProperties['video-out-params/par'] ?? '') !=
            1.0 ||
        integer('video-out-params/rotate') != 0 ||
        (filters != '' && filters != '[]')) {
      return null;
    }
    final outputWidth = math.min(w, targetWidth);
    final outputHeight = math.max(1, (h * outputWidth + w ~/ 2) ~/ w);
    // Extreme aspect ratios are not useful stamp-sized backgrounds. Keep the
    // original screenshot behavior instead of creating a long image here.
    if (outputHeight > 1024 || (outputWidth == w && outputHeight == h)) {
      return null;
    }
    return AmbientThumbnailGeometry(w, h, outputWidth, outputHeight);
  }

  bool matches(AmbientFrameSnapshot? other) =>
      other != null &&
      videoParams == other.videoParams &&
      mapEquals(outputProperties, other.outputProperties);
}

class AmbientThumbnailGeometry {
  const AmbientThumbnailGeometry(
    this.width,
    this.height,
    this.outputWidth,
    this.outputHeight,
  );

  final int width;
  final int height;
  final int outputWidth;
  final int outputHeight;

  bool accepts(Uint8List bytes) => bytes.length == width * height * 4;
}

class AmbientBgraThumbnail {
  const AmbientBgraThumbnail(this.bytes, this.geometry);

  final Uint8List bytes;
  final AmbientThumbnailGeometry geometry;
}

/// Keeps native capture under media_kit's existing transport/dispose lock.
/// The raw result is an owned Dart copy, so resizing and JPEG encoding can
/// run afterwards without holding that lock or retaining an mpv node.
Future<Uint8List?> captureAmbientThumbnail({
  required Future<AmbientFrameSnapshot?> Function() readSnapshot,
  required Future<Uint8List?> Function() captureRaw,
  required Future<Uint8List?> Function() captureJpeg,
  required bool Function() isCurrent,
  Future<Uint8List?> Function(AmbientBgraThumbnail)? encodeThumbnail,
  bool softwareForVerifiedSdr = false,
  Future<String> Function()? readSoftwareOption,
  Future<void> Function(String value)? writeSoftwareOption,
  VoidCallback? onSoftwareRestoreFailure,
}) async {
  Future<Uint8List?> fallback() async {
    if (!isCurrent()) return null;
    try {
      final jpeg = await captureJpeg();
      return isCurrent() ? jpeg : null;
    } catch (_) {
      return null;
    }
  }

  if (!isCurrent()) return null;
  try {
    final before = await readSnapshot();
    if (!isCurrent()) return null;
    final geometry = before?.geometry();
    if (geometry == null) return fallback();
    Uint8List? bytes;
    if (softwareForVerifiedSdr) {
      if (!before!.isVerifiedSdr ||
          readSoftwareOption == null ||
          writeSoftwareOption == null) {
        return fallback();
      }
      final captured = await withAmbientSoftwareCapture<Uint8List>(
        readOption: readSoftwareOption,
        writeOption: writeSoftwareOption,
        capture: captureRaw,
        isCurrent: isCurrent,
        onRestoreFailure: onSoftwareRestoreFailure,
      );
      if (!isCurrent() || captured.restoreError != null) return null;
      bytes = captured.value;
    } else {
      bytes = await captureRaw();
    }
    if (!isCurrent()) return null;
    final after = await readSnapshot();
    if (!isCurrent()) return null;
    if (bytes == null || !geometry.accepts(bytes) || !before!.matches(after)) {
      return fallback();
    }
    final request = AmbientBgraThumbnail(bytes, geometry);
    final thumbnail =
        await (encodeThumbnail?.call(request) ??
            compute(encodeAmbientBgraThumbnail, request));
    if (!isCurrent()) return null;
    final finished = await readSnapshot();
    if (!isCurrent()) return null;
    if (thumbnail == null || !before.matches(finished)) return fallback();
    return thumbnail;
  } catch (_) {
    return fallback();
  }
}

/// mpv screenshot-raw defaults to BGR0. The fourth byte is unspecified and is
/// intentionally ignored, matching media_kit 1.2.6's existing JPEG conversion.
/// Only the small RGB result is converted to an image object for encoding.
Uint8List? encodeAmbientBgraThumbnail(AmbientBgraThumbnail request) {
  final rgb = downsampleAmbientBgra(request);
  if (rgb == null) return null;
  final geometry = request.geometry;
  final image = img.Image.fromBytes(
    width: geometry.outputWidth,
    height: geometry.outputHeight,
    bytes: rgb.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
  return img.encodeJpg(image, quality: 90);
}

/// Area averages the original packed BGR pixels, including fractional edge
/// coverage. Sampling a single pixel per block would alias fine video detail.
Uint8List? downsampleAmbientBgra(AmbientBgraThumbnail request) {
  final g = request.geometry;
  if (g.width <= 0 ||
      g.height <= 0 ||
      g.outputWidth <= 0 ||
      g.outputHeight <= 0 ||
      g.outputWidth > g.width ||
      g.outputHeight > g.height ||
      !g.accepts(request.bytes)) {
    return null;
  }
  final output = Uint8List(g.outputWidth * g.outputHeight * 3);
  final source = request.bytes;
  if (g.width % g.outputWidth == 0 && g.height % g.outputHeight == 0) {
    final spanX = g.width ~/ g.outputWidth;
    final spanY = g.height ~/ g.outputHeight;
    final area = spanX * spanY;
    var dest = 0;
    for (var y = 0; y < g.outputHeight; y++) {
      for (var x = 0; x < g.outputWidth; x++) {
        var red = 0;
        var green = 0;
        var blue = 0;
        for (var sy = y * spanY; sy < (y + 1) * spanY; sy++) {
          var offset = (sy * g.width + x * spanX) * 4;
          for (var sx = 0; sx < spanX; sx++, offset += 4) {
            blue += source[offset];
            green += source[offset + 1];
            red += source[offset + 2];
          }
        }
        output[dest++] = (red + area ~/ 2) ~/ area;
        output[dest++] = (green + area ~/ 2) ~/ area;
        output[dest++] = (blue + area ~/ 2) ~/ area;
      }
    }
    return output;
  }

  final columns = _coverage(g.width, g.outputWidth);
  final rows = _coverage(g.height, g.outputHeight);
  final totalWeight = g.width * g.height;
  var dest = 0;
  for (final row in rows) {
    for (final column in columns) {
      var red = 0;
      var green = 0;
      var blue = 0;
      for (var y = 0; y < row.weights.length; y++) {
        var offset = ((row.start + y) * g.width + column.start) * 4;
        final weightY = row.weights[y];
        for (var x = 0; x < column.weights.length; x++, offset += 4) {
          final weight = weightY * column.weights[x];
          blue += source[offset] * weight;
          green += source[offset + 1] * weight;
          red += source[offset + 2] * weight;
        }
      }
      output[dest++] = (red + totalWeight ~/ 2) ~/ totalWeight;
      output[dest++] = (green + totalWeight ~/ 2) ~/ totalWeight;
      output[dest++] = (blue + totalWeight ~/ 2) ~/ totalWeight;
    }
  }
  return output;
}

class _AreaCoverage {
  const _AreaCoverage(this.start, this.weights);

  final int start;
  final List<int> weights;
}

List<_AreaCoverage> _coverage(int sourceSize, int outputSize) => [
  for (var dest = 0; dest < outputSize; dest++)
    _AreaCoverage(dest * sourceSize ~/ outputSize, [
      for (
        var source = dest * sourceSize ~/ outputSize;
        source < ((dest + 1) * sourceSize + outputSize - 1) ~/ outputSize;
        source++
      )
        math.min((dest + 1) * sourceSize, (source + 1) * outputSize) -
            math.max(dest * sourceSize, source * outputSize),
    ]),
];

/// Per-player outer serialization protects screenshot options across full
/// cover captures, ambient thumbnails and explicit diagnostics. It does not
/// replace or bypass media_kit's own native transport/dispose lock.
class AmbientCaptureQueue {
  Future<void> _tail = Future<void>.value();
  bool _blocked = false;

  void block() => _blocked = true;

  Future<T?> run<T>({
    required bool Function() isCurrent,
    required Future<T?> Function() capture,
  }) {
    final result = _tail.then<T?>((_) async {
      if (_blocked || !isCurrent()) return null;
      return capture();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class AmbientSoftwareCaptureResult<T> {
  String? original;
  String? during;
  String? restored;
  T? value;
  Object? error;
  Object? restoreError;
  bool captureAttempted = false;
  bool restoreAttempted = false;
}

/// Unknown options are not changed. Restoration is verified before a caller
/// can release its capture queue to a full-resolution cover request.
Future<AmbientSoftwareCaptureResult<T>> withAmbientSoftwareCapture<T>({
  required Future<String> Function() readOption,
  required Future<void> Function(String value) writeOption,
  required Future<T?> Function() capture,
  required bool Function() isCurrent,
  VoidCallback? onRestoreFailure,
}) async {
  final result = AmbientSoftwareCaptureResult<T>();
  var restore = false;
  try {
    if (!isCurrent()) return result;
    result.original = await readOption();
    if (!isCurrent()) return result;
    if (result.original != 'yes' && result.original != 'no') return result;
    restore = result.original != 'yes';
    if (restore) await writeOption('yes');
    if (!isCurrent()) return result;
    result.during = await readOption();
    if (!isCurrent() || result.during != 'yes') return result;
    result.captureAttempted = true;
    result.value = await capture();
  } catch (error) {
    result.error = error;
  } finally {
    if (restore && isCurrent()) {
      result.restoreAttempted = true;
      try {
        await writeOption(result.original!);
        if (isCurrent()) {
          result.restored = await readOption();
          if (result.restored != result.original) {
            throw StateError('Screenshot option restoration was not confirmed');
          }
        }
      } catch (error) {
        result.restoreError = error;
        result.value = null;
        if (isCurrent()) onRestoreFailure?.call();
      }
    }
    if (!isCurrent()) result.value = null;
  }
  return result;
}

/// Explicit diagnostic formatting reuses the same typed option guard as
/// production. No production decision is made from this diagnostic map.
Future<Map<String, Object?>> probeAmbientSoftwareCapture({
  required Future<String> Function() readOption,
  required Future<void> Function(String value) writeOption,
  required Future<int?> Function() captureRawByteLength,
  required bool Function() isCurrent,
  VoidCallback? onRestoreFailure,
}) async {
  final result = <String, Object?>{
    'softwareCaptureRequested': true,
    'rawAttempted': false,
    'screenshotSwRestoreAttempted': false,
  };
  final captured = await withAmbientSoftwareCapture<int>(
    readOption: readOption,
    writeOption: writeOption,
    isCurrent: isCurrent,
    onRestoreFailure: onRestoreFailure,
    capture: () async {
      final watch = Stopwatch()..start();
      result['rawAttempted'] = true;
      try {
        return await captureRawByteLength();
      } finally {
        watch.stop();
        result['rawElapsedMs'] = watch.elapsedMilliseconds;
      }
    },
  );
  result['screenshotSwBefore'] = captured.original;
  result['screenshotSwDuring'] = captured.during;
  result['screenshotSwRestoreAttempted'] = captured.restoreAttempted;
  if (captured.restored != null) {
    result['screenshotSwRestored'] = captured.restored;
  }
  if (captured.captureAttempted) result['rawByteLength'] = captured.value;
  if (captured.error != null) {
    result['softwareCaptureError'] = '${captured.error}';
  }
  if (captured.restoreError != null) {
    result['screenshotSwRestoreError'] = '${captured.restoreError}';
  }
  if (captured.original != null &&
      captured.original != 'yes' &&
      captured.original != 'no') {
    result['softwareCaptureSkipped'] = 'unknown_original_option';
  } else if (captured.during != null && captured.during != 'yes') {
    result['softwareCaptureSkipped'] = 'software_option_not_confirmed';
  }
  return result;
}
