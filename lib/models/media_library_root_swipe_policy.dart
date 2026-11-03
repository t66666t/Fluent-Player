import 'package:flutter/gestures.dart';

import 'media_library_root_entry.dart';
import 'media_library_root_entry_order.dart';

/// Swipe between 继续学习 / 最近添加 / 文件夹.
///
/// One move still tracks the finger. Travel past a full page keeps going
/// into the page after that, and a flick back toward the page under the
/// finger returns there. Mouse and trackpad are never eligible: desktop
/// box-select, file drops, and wheel/trackpad pans would mis-fire. System
/// back lives on the screen edges, so those strips are also ignored. The
/// recognizer itself is a horizontal drag so a vertical list scroll keeps
/// the arena.
class MediaLibraryRootSwipePolicy {
  const MediaLibraryRootSwipePolicy._();

  /// Logical px kept for Android/iOS edge back.
  static const double systemEdgeGuard = 32;

  /// Fraction of width that commits without a flick.
  static const double commitFraction = 0.36;

  /// px/s in the swipe direction that commits a shorter drag.
  static const double commitVelocity = 950;

  static bool isEligiblePointer(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus;
  }

  static bool isAwayFromSystemEdges({
    required double localX,
    required double width,
    double guard = systemEdgeGuard,
  }) {
    if (width <= guard * 2) return false;
    return localX >= guard && localX <= width - guard;
  }

  /// Finger moving left (negative [dx]) reveals the next chip to the right.
  static MediaLibraryRootEntry? neighbor({
    required MediaLibraryRootEntry current,
    required double dx,
    List<MediaLibraryRootEntry> order = MediaLibraryRootEntryOrder.defaults,
  }) {
    if (dx == 0) return null;
    final index = order.indexOf(current);
    if (index < 0) return null;
    final nextIndex = dx < 0 ? index + 1 : index - 1;
    if (nextIndex < 0 || nextIndex >= order.length) return null;
    return order[nextIndex];
  }

  static bool shouldCommit({
    required double dragDx,
    required double width,
    required double velocityDx,
  }) {
    if (width <= 0) return false;
    final towardNext = dragDx < 0;
    final distance = dragDx.abs();
    final flick = towardNext
        ? velocityDx < -commitVelocity
        : velocityDx > commitVelocity;
    if (flick && distance > 24) return true;
    return distance >= width * commitFraction;
  }

  /// Page to show after the finger lifts. Null stays on [current].
  ///
  /// A flick in the same direction as [dragDx], or a drag past
  /// [commitFraction], opens the neighbor on that side. A flick back
  /// toward [current] cancels, including after the drag has passed
  /// [commitFraction]. The finger has to actually cross onto the other
  /// side before that side can win.
  static MediaLibraryRootEntry? settleTarget({
    required MediaLibraryRootEntry current,
    required double dragDx,
    required double width,
    required double velocityDx,
    List<MediaLibraryRootEntry> order = MediaLibraryRootEntryOrder.defaults,
  }) {
    if (width <= 0) return null;
    if (_isOpposingFlick(dragDx: dragDx, velocityDx: velocityDx)) {
      return null;
    }
    if (!shouldCommit(dragDx: dragDx, width: width, velocityDx: velocityDx)) {
      return null;
    }
    return neighbor(current: current, dx: dragDx, order: order);
  }

  /// Moves the origin when the finger has traveled a full page.
  ///
  /// [indexDelta] is +1 when [dragDx] has reached the next chip
  /// (`<= -width`). [residualDx] is the same on-screen position measured
  /// from that chip, so the gesture can continue into the page after it.
  /// The caller repeats this once per page a single move crosses.
  static MediaLibraryRootSwipeShift? shiftOrigin({
    required double dragDx,
    required double width,
  }) {
    if (width <= 0) return null;
    if (dragDx <= -width) {
      return MediaLibraryRootSwipeShift(
        indexDelta: 1,
        residualDx: dragDx + width,
      );
    }
    if (dragDx >= width) {
      return MediaLibraryRootSwipeShift(
        indexDelta: -1,
        residualDx: dragDx - width,
      );
    }
    return null;
  }

  static bool _isOpposingFlick({
    required double dragDx,
    required double velocityDx,
  }) {
    if (velocityDx > commitVelocity) return dragDx < 0;
    if (velocityDx < -commitVelocity) return dragDx > 0;
    return false;
  }

  /// Resist sliding off the first/last tab.
  static double clampDrag({
    required double dx,
    required double width,
    required bool hasNeighbor,
  }) {
    if (width <= 0) return 0;
    if (!hasNeighbor) return dx.clamp(-width * 0.12, width * 0.12);
    return dx.clamp(-width, width);
  }

  /// Chip-row position in the current display order.
  static double highlightIndex({
    required MediaLibraryRootEntry current,
    required double dragDx,
    required double width,
    List<MediaLibraryRootEntry> order = MediaLibraryRootEntryOrder.defaults,
  }) {
    final index = order.indexOf(current).toDouble();
    if (index < 0) return 0;
    final last = (order.length - 1).toDouble().clamp(0.0, double.infinity);
    if (width <= 0) return index;
    return (index - dragDx / width).clamp(0.0, last);
  }

  /// How strongly chip [entryIndex] should look selected.
  static double chipWeight({
    required int entryIndex,
    required double highlightIndex,
  }) {
    return (1.0 - (highlightIndex - entryIndex).abs()).clamp(0.0, 1.0);
  }
}

/// One full page of travel, measured from the page the finger is now on.
class MediaLibraryRootSwipeShift {
  const MediaLibraryRootSwipeShift({
    required this.indexDelta,
    required this.residualDx,
  });

  /// +1 moves toward the next chip. -1 moves toward the previous chip.
  final int indexDelta;

  /// Finger offset after the origin moves, in the same coordinate space.
  final double residualDx;
}
