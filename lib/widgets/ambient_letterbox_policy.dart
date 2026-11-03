import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Decisions for the experimental landscape letterbox matte.
///
/// The matte is a property of the player column, not of the user's zoom,
/// pan, or rotation. Those transforms move only the sharp picture, so the
/// eye keeps one rectangle to lock onto.
class AmbientLetterboxPolicy {
  const AmbientLetterboxPolicy._();

  static const Duration sampleInterval = Duration(seconds: 1);

  /// Downscale before the blur. A full-frame blur would compete with decode.
  static const int targetWidth = 96;

  /// Keeps the sharp frame brighter than the matte so it stays the subject.
  static const Color scrim = Color(0x73000000);

  /// Near-upright rotations (including a half turn) still cover like a
  /// rectangle. Anything else reveals the matte at the corners.
  static const double uprightRotationEpsilon = 0.02;

  /// Backdrop rect in the player column.
  ///
  /// [userScale], [userRotation], and [userOffset] describe the sharp picture
  /// and are intentionally unused: applying them here would make the matte a
  /// second moving image.
  static Rect backdropRect({
    required Size columnSize,
    double userScale = 1,
    double userRotation = 0,
    Offset userOffset = Offset.zero,
  }) {
    if (columnSize.width <= 0 || columnSize.height <= 0) return Rect.zero;
    return Offset.zero & columnSize;
  }

  /// Sidebar width and handedness only change the column size. The existing
  /// image is refit by the layer; [previous] and [next] are not a capture.
  static bool requestsFrameForColumnResize(Size previous, Size next) {
    return false;
  }

  /// True when the sharp picture does not cover the column, so the matte
  /// would actually be seen.
  static bool hasVisibleGap({
    required Size columnSize,
    required Size containedVideoSize,
    required double userScale,
    required double userRotation,
    required Offset userOffset,
  }) {
    if (columnSize.width <= 0 || columnSize.height <= 0) return false;
    if (containedVideoSize.width <= 0 || containedVideoSize.height <= 0) {
      return true;
    }
    if (!_isUpright(userRotation)) return true;
    final scale = userScale.isFinite && userScale > 0 ? userScale : 1.0;
    final scaledWidth = containedVideoSize.width * scale;
    final scaledHeight = containedVideoSize.height * scale;
    final overflowX = (scaledWidth - columnSize.width) / 2;
    final overflowY = (scaledHeight - columnSize.height) / 2;
    if (userOffset.dx.abs() > overflowX + 0.5) return true;
    if (userOffset.dy.abs() > overflowY + 0.5) return true;
    return scaledWidth + 0.5 < columnSize.width ||
        scaledHeight + 0.5 < columnSize.height;
  }

  /// Sampling rides the one-second clock. Layout changes and in-flight
  /// captures are not extra reasons to ask the decoder for a frame.
  static bool shouldSample({
    required bool enabled,
    required bool hasPlayableVideo,
    required bool visibleGap,
    required bool seeking,
    required bool buffering,
    required bool transforming,
    required bool captureInFlight,
  }) {
    if (!enabled || !hasPlayableVideo || !visibleGap) return false;
    if (seeking || buffering || transforming || captureInFlight) return false;
    return true;
  }

  static bool _isUpright(double radians) {
    if (!radians.isFinite) return true;
    final wrapped = radians.abs() % (2 * math.pi);
    if (wrapped < uprightRotationEpsilon) return true;
    if ((wrapped - math.pi).abs() < uprightRotationEpsilon) return true;
    if ((wrapped - 2 * math.pi).abs() < uprightRotationEpsilon) return true;
    return false;
  }
}

/// Two box-blur passes on a stamp-sized RGBA buffer.
///
/// The widget then scales this image up, so the blur stays off the video
/// decode path and off the full player-column resolution.
Uint8List blurAmbientRgba({
  required Uint8List pixels,
  required int width,
  required int height,
  int radius = 4,
}) {
  final count = width * height * 4;
  if (width <= 1 || height <= 1 || pixels.length < count) {
    return Uint8List.fromList(pixels);
  }
  final span = radius.clamp(1, 12);
  var current = Uint8List.sublistView(pixels, 0, count);
  for (var pass = 0; pass < 2; pass++) {
    current = _boxBlur(current, width, height, span, horizontal: true);
    current = _boxBlur(current, width, height, span, horizontal: false);
  }
  return current;
}

Uint8List _boxBlur(
  Uint8List source,
  int width,
  int height,
  int radius, {
  required bool horizontal,
}) {
  final dest = Uint8List(width * height * 4);
  final window = radius * 2 + 1;
  final major = horizontal ? height : width;
  final minor = horizontal ? width : height;
  for (var line = 0; line < major; line++) {
    var red = 0;
    var green = 0;
    var blue = 0;
    var alpha = 0;
    int indexAt(int position) {
      final clamped = position < 0
          ? 0
          : (position >= minor ? minor - 1 : position);
      final x = horizontal ? clamped : line;
      final y = horizontal ? line : clamped;
      return (y * width + x) * 4;
    }

    for (var i = -radius; i <= radius; i++) {
      final pixel = indexAt(i);
      red += source[pixel];
      green += source[pixel + 1];
      blue += source[pixel + 2];
      alpha += source[pixel + 3];
    }
    for (var position = 0; position < minor; position++) {
      final pixel = indexAt(position);
      dest[pixel] = red ~/ window;
      dest[pixel + 1] = green ~/ window;
      dest[pixel + 2] = blue ~/ window;
      dest[pixel + 3] = alpha ~/ window;
      final remove = indexAt(position - radius);
      final add = indexAt(position + radius + 1);
      red += source[add] - source[remove];
      green += source[add + 1] - source[remove + 1];
      blue += source[add + 2] - source[remove + 2];
      alpha += source[add + 3] - source[remove + 3];
    }
  }
  return dest;
}
