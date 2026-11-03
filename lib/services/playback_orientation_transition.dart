import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';

enum PlaybackViewportOrientation { portrait, landscape }

typedef PlaybackViewportSizeReader = Size Function();
typedef PlaybackFrameWaiter = Future<void> Function();
typedef PlaybackStabilitySignatureReader = Object Function();

/// Waits for Android's real Flutter viewport before the playback route is
/// changed.
///
/// The platform orientation call completes when the request has been sent,
/// not when WindowManager has finished resizing the app. Keeping route changes
/// behind this boundary prevents portrait controls from being painted into a
/// landscape window (and vice versa).
class PlaybackOrientationTransition {
  const PlaybackOrientationTransition._();

  static bool matches(Size size, PlaybackViewportOrientation target) {
    if (size.isEmpty) return false;
    return switch (target) {
      PlaybackViewportOrientation.portrait => size.height >= size.width,
      PlaybackViewportOrientation.landscape => size.width > size.height,
    };
  }

  /// Captures every window metric which can move playback controls during an
  /// orientation change. A size-only check can finish while Android is still
  /// animating status/navigation bars.
  static Object metricsSignature(FlutterView view) => (
    view.physicalSize,
    view.devicePixelRatio,
    view.padding.left,
    view.padding.top,
    view.padding.right,
    view.padding.bottom,
    view.viewPadding.left,
    view.viewPadding.top,
    view.viewPadding.right,
    view.viewPadding.bottom,
    view.viewInsets.left,
    view.viewInsets.top,
    view.viewInsets.right,
    view.viewInsets.bottom,
    view.systemGestureInsets.left,
    view.systemGestureInsets.top,
    view.systemGestureInsets.right,
    view.systemGestureInsets.bottom,
  );

  static Future<bool> waitForViewport({
    required PlaybackViewportSizeReader readSize,
    required PlaybackFrameWaiter waitForFrame,
    required PlaybackViewportOrientation target,
    PlaybackStabilitySignatureReader? readStabilitySignature,
    Duration timeout = const Duration(milliseconds: 1200),
    int stableFrames = 2,
  }) async {
    assert(stableFrames > 0);
    final stopwatch = Stopwatch()..start();
    Object? previousMatch;
    var consecutiveMatches = 0;

    while (stopwatch.elapsed < timeout) {
      final size = readSize();
      if (matches(size, target)) {
        final signature = readStabilitySignature?.call() ?? size;
        if (signature == previousMatch) {
          consecutiveMatches++;
        } else {
          previousMatch = signature;
          consecutiveMatches = 1;
        }
        if (consecutiveMatches >= stableFrames) return true;
      } else {
        previousMatch = null;
        consecutiveMatches = 0;
      }

      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      await Future.any<void>(<Future<void>>[
        waitForFrame(),
        Future<void>.delayed(
          remaining < const Duration(milliseconds: 32)
              ? remaining
              : const Duration(milliseconds: 32),
        ),
      ]);
    }
    return false;
  }
}
