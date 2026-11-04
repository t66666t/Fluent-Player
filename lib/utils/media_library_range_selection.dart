import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Album-style library selection: a contiguous index range in reading order.
class MediaLibraryRangeSelection {
  const MediaLibraryRangeSelection._();

  /// Keeps items that were already selected, then adds every item from
  /// [startIndex] through [currentIndex] (inclusive, either direction).
  static Set<String> mergeSnapshotWithIndexRange({
    required Set<String> snapshot,
    required int startIndex,
    required int currentIndex,
    required int itemCount,
    required String? Function(int index) idAt,
  }) {
    final selected = Set<String>.from(snapshot);
    if (itemCount <= 0) return selected;
    final start = startIndex.clamp(0, itemCount - 1);
    final current = currentIndex.clamp(0, itemCount - 1);
    final from = start < current ? start : current;
    final to = start < current ? current : start;
    for (var i = from; i <= to; i++) {
      final id = idAt(i);
      if (id != null) selected.add(id);
    }
    return selected;
  }

  /// Height of the mini player overlay that sits on top of the list viewport.
  static double miniPlayerOverlayHeight({
    required bool visible,
    required double cardHeight,
    required double cardBottomInset,
  }) {
    if (!visible) return 0;
    return cardHeight + cardBottomInset;
  }

  /// Keeps a selection hit inside the visible list.
  ///
  /// A finger or mouse past the top or bottom used to be converted with the raw
  /// coordinate, so the row index clamped to item 0 or the last item and the
  /// whole catalog became selected. Clamping to the viewport edge selects the
  /// row currently sitting on that edge; auto-scroll then walks the range, and
  /// moving back inside shrinks it again.
  static Offset clampPointerToVerticalViewport({
    required Offset global,
    required double viewportTop,
    required double viewportBottom,
  }) {
    if (viewportBottom < viewportTop) return global;
    if (global.dy < viewportTop) return Offset(global.dx, viewportTop);
    if (global.dy > viewportBottom) return Offset(global.dx, viewportBottom);
    return global;
  }

  /// Rubber-band box select is a mouse gesture on every platform, including a
  /// mouse plugged into a phone or tablet.
  static bool isMouseBoxGesture({
    required PointerDeviceKind? pointerKind,
    required int pointerCount,
  }) {
    return pointerCount == 1 && pointerKind == PointerDeviceKind.mouse;
  }
}

/// Edge-driven auto-scroll while a selection drag is held.
class MediaLibrarySelectionAutoScroll {
  const MediaLibrarySelectionAutoScroll._();

  static const double edgeExtent = 64;
  static const double maxSpeedPxPerSecond = 1400;
  static const Duration tick = Duration(milliseconds: 16);

  /// Negative velocity scrolls toward earlier items (up); positive scrolls down.
  static double velocityPxPerSecond({
    required double pointerY,
    required double viewportTop,
    required double viewportBottom,
  }) {
    if (viewportBottom <= viewportTop) return 0;
    if (pointerY <= viewportTop) return -maxSpeedPxPerSecond;
    if (pointerY >= viewportBottom) return maxSpeedPxPerSecond;
    // Landscape and large-text layouts can leave less than two edge bands.
    // Keep the upper/lower bands separate so the bottom never scrolls upward.
    final edge = ((viewportBottom - viewportTop) / 2).clamp(0.0, edgeExtent);
    if (pointerY < viewportTop + edge) {
      final t = (viewportTop + edge - pointerY) / edge;
      return -maxSpeedPxPerSecond * t.clamp(0.0, 1.0);
    }
    if (pointerY > viewportBottom - edge) {
      final t = (pointerY - (viewportBottom - edge)) / edge;
      return maxSpeedPxPerSecond * t.clamp(0.0, 1.0);
    }
    return 0;
  }
}

/// Owns the periodic [jumpTo] used while the pointer stays in an edge band.
class MediaLibrarySelectionAutoScroller {
  MediaLibrarySelectionAutoScroller({
    required this.scrollController,
    required this.onScrolled,
  });

  final ScrollController scrollController;
  final VoidCallback onScrolled;

  Timer? _timer;
  double _velocity = 0;

  void update({
    required double pointerY,
    required double viewportTop,
    required double viewportBottom,
  }) {
    _velocity = MediaLibrarySelectionAutoScroll.velocityPxPerSecond(
      pointerY: pointerY,
      viewportTop: viewportTop,
      viewportBottom: viewportBottom,
    );
    if (_velocity == 0) {
      stop();
      return;
    }
    _timer ??= Timer.periodic(MediaLibrarySelectionAutoScroll.tick, (_) {
      _tick();
    });
  }

  void _tick() {
    if (!scrollController.hasClients) {
      stop();
      return;
    }
    final position = scrollController.position;
    final delta =
        _velocity *
        (MediaLibrarySelectionAutoScroll.tick.inMilliseconds / 1000);
    final next = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) return;
    scrollController.jumpTo(next);
    onScrolled();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _velocity = 0;
  }

  void dispose() => stop();
}

/// Tracks which pointers are still down for a library selection drag.
///
/// The checkbox that started the drag can scroll out of the cache and take its
/// [GestureDetector] with it. Move and up events then never reach `onPanEnd`,
/// so edge auto-scroll keeps the last out-of-bounds point and the page stays
/// locked in that direction. A [Listener] above the list still sees the same
/// pointer; this session tells it when the gesture is actually over.
class MediaLibrarySelectionPointerSession {
  final Set<int> _down = <int>{};

  void down(int pointer) {
    _down.add(pointer);
  }

  /// True when [pointer] is one of the buttons or fingers still held.
  bool move(int pointer) => _down.contains(pointer);

  /// True when the last held pointer has lifted or been cancelled.
  bool up(int pointer) {
    if (!_down.remove(pointer)) return false;
    return _down.isEmpty;
  }

  void clear() => _down.clear();
}

/// 选择模式下拖拽卡片换位置时的指针身份。
///
/// 列表被边缘自动滚动推走之后，手指并没有移动，Flutter 的拖拽替身不会重新
/// 做命中测试，落点高亮会停在滚动前的那张卡片上。这里在下一帧补发一次
/// 位移为 0 的移动事件：替身会按当前坐标重新命中 [DragTarget]，又因为位移
/// 为 0 而不会再次回调 `onDragUpdate`，所以不会把自动滚动再触发一遍。
class MediaLibraryReorderDragSession {
  int? _pointer;
  int? _viewId;
  PointerDeviceKind? _kind;
  Offset? _position;
  bool _refreshScheduled = false;

  bool get isActive => _pointer != null;

  int? get pointer => _pointer;

  void update({
    required Offset globalPosition,
    required int pointer,
    required int viewId,
    required PointerDeviceKind kind,
  }) {
    _pointer = pointer;
    _viewId = viewId;
    _kind = kind;
    _position = globalPosition;
  }

  void end() {
    _pointer = null;
    _viewId = null;
    _kind = null;
    _position = null;
    _refreshScheduled = false;
  }

  /// 滚动已经改过偏移之后调用。布局要等这一帧结束才反映到 RenderBox 上。
  void scheduleHitRefresh() {
    if (!isActive || _refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      if (!isActive) return;
      final pointer = _pointer;
      final viewId = _viewId;
      final kind = _kind;
      final position = _position;
      if (pointer == null ||
          viewId == null ||
          kind == null ||
          position == null) {
        return;
      }
      GestureBinding.instance.handlePointerEvent(
        PointerMoveEvent(
          viewId: viewId,
          pointer: pointer,
          kind: kind,
          position: position,
          delta: Offset.zero,
          synthesized: true,
        ),
      );
    });
  }
}
