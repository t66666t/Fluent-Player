import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Travel smaller than this is treated as a fixed axis so we never divide by it.
const double kSubtitlePositionEpsilon = 0.5;

/// Capture / release / guide distances in logical pixels of the subtitle surface.
/// These are product feel values, not Flutter constants.
const SubtitleSnapThresholds kSubtitleSnapThresholds = SubtitleSnapThresholds(
  capture: 5,
  release: 12,
  guide: 22,
);

const double kSubtitleEditFrameStroke = 2;
const double kSubtitleEditHitSlop = 12;

@immutable
class SubtitleSnapThresholds {
  final double capture;
  final double release;
  final double guide;

  const SubtitleSnapThresholds({
    required this.capture,
    required this.release,
    required this.guide,
  });
}

/// Per-axis snap latch. The raw origin is stored separately and is never
/// replaced by the snapped output, so a slow 1px drag can leave the center.
@immutable
class SubtitleSnapMemory {
  final bool capturedX;
  final bool capturedY;

  const SubtitleSnapMemory({this.capturedX = false, this.capturedY = false});

  SubtitleSnapMemory copyWith({bool? capturedX, bool? capturedY}) {
    return SubtitleSnapMemory(
      capturedX: capturedX ?? this.capturedX,
      capturedY: capturedY ?? this.capturedY,
    );
  }
}

@immutable
class SubtitleAxisRange {
  final double min;
  final double max;

  const SubtitleAxisRange(this.min, this.max);

  bool get movable =>
      min.isFinite && max.isFinite && (max - min) > kSubtitlePositionEpsilon;

  double clamp(double value) {
    if (!value.isFinite) return min.isFinite ? min : 0;
    if (!movable) return min.isFinite ? min : 0;
    return value.clamp(min, max).toDouble();
  }
}

/// Inclusive origin range for the content box. Display and commit share it.
@immutable
class SubtitleMoveSpace {
  final Rect viewport;
  final Size content;
  final SubtitleAxisRange x;
  final SubtitleAxisRange y;

  const SubtitleMoveSpace({
    required this.viewport,
    required this.content,
    required this.x,
    required this.y,
  });

  factory SubtitleMoveSpace.fromViewport(Rect viewport, Size content) {
    final double width = content.width.isFinite ? math.max(0, content.width) : 0;
    final double height = content.height.isFinite
        ? math.max(0, content.height)
        : 0;
    final double travelX = math.max(0, viewport.width - width);
    final double travelY = math.max(0, viewport.height - height);
    return SubtitleMoveSpace(
      viewport: viewport,
      content: Size(width, height),
      x: SubtitleAxisRange(viewport.left, viewport.left + travelX),
      y: SubtitleAxisRange(viewport.top, viewport.top + travelY),
    );
  }

  Offset alignmentToOrigin(Alignment alignment, {double bottomInset = 0}) {
    final double left = x.movable
        ? x.min + (x.max - x.min) * ((alignment.x + 1) / 2)
        : x.min;
    double top = y.movable
        ? y.min + (y.max - y.min) * ((alignment.y + 1) / 2)
        : y.min;
    if (bottomInset.isFinite && bottomInset != 0) {
      top = (top - bottomInset).clamp(y.min, y.movable ? y.max : y.min).toDouble();
    }
    return Offset(
      left.isFinite ? left : 0,
      top.isFinite ? top : 0,
    );
  }

  /// [preserved] keeps the semantic value of an axis that cannot move.
  Alignment originToAlignment(Offset origin, {Alignment preserved = Alignment.center}) {
    final double ax = x.movable
        ? (2 * (origin.dx - x.min) / (x.max - x.min) - 1)
        : preserved.x;
    final double ay = y.movable
        ? (2 * (origin.dy - y.min) / (y.max - y.min) - 1)
        : preserved.y;
    if (!ax.isFinite || !ay.isFinite) return preserved;
    return Alignment(ax.clamp(-1.0, 1.0).toDouble(), ay.clamp(-1.0, 1.0).toDouble());
  }
}

@immutable
class SubtitleSnapDecision {
  final Offset displayOrigin;
  final SubtitleSnapMemory memory;
  final bool snappedX;
  final bool snappedY;
  final bool guideX;
  final bool guideY;

  const SubtitleSnapDecision({
    required this.displayOrigin,
    required this.memory,
    required this.snappedX,
    required this.snappedY,
    required this.guideX,
    required this.guideY,
  });
}

/// Snaps in the same logical-pixel space the pointer uses.
///
/// Only a sample whose raw center is inside the capture distance latches.
/// A fast sample that jumps past the center is not pulled back.
SubtitleSnapDecision resolveSubtitlePixelSnap({
  required Offset boundedOrigin,
  required Size content,
  required Rect viewport,
  required SubtitleSnapMemory memory,
  SubtitleSnapThresholds thresholds = kSubtitleSnapThresholds,
}) {
  final SubtitleMoveSpace space = SubtitleMoveSpace.fromViewport(
    viewport,
    content,
  );
  final Offset center = viewport.center;
  final double rawCenterX = boundedOrigin.dx + content.width / 2;
  final double rawCenterY = boundedOrigin.dy + content.height / 2;
  final _Axis axisX = _snapAxis(
    rawCenter: rawCenterX,
    viewCenter: center.dx,
    captured: memory.capturedX,
    movable: space.x.movable,
    thresholds: thresholds,
  );
  final _Axis axisY = _snapAxis(
    rawCenter: rawCenterY,
    viewCenter: center.dy,
    captured: memory.capturedY,
    movable: space.y.movable,
    thresholds: thresholds,
  );
  final double displayX = axisX.snapped
      ? space.x.clamp(center.dx - content.width / 2)
      : boundedOrigin.dx;
  final double displayY = axisY.snapped
      ? space.y.clamp(center.dy - content.height / 2)
      : boundedOrigin.dy;
  return SubtitleSnapDecision(
    displayOrigin: Offset(displayX, displayY),
    memory: SubtitleSnapMemory(capturedX: axisX.captured, capturedY: axisY.captured),
    snappedX: axisX.snapped,
    snappedY: axisY.snapped,
    guideX: axisX.guide,
    guideY: axisY.guide,
  );
}

class _Axis {
  final bool captured;
  final bool snapped;
  final bool guide;
  const _Axis({required this.captured, required this.snapped, required this.guide});
}

_Axis _snapAxis({
  required double rawCenter,
  required double viewCenter,
  required bool captured,
  required bool movable,
  required SubtitleSnapThresholds thresholds,
}) {
  if (!movable || !rawCenter.isFinite || !viewCenter.isFinite) {
    return const _Axis(captured: false, snapped: false, guide: false);
  }
  final double distance = (rawCenter - viewCenter).abs();
  final bool stay = captured && distance <= thresholds.release;
  final bool latch = !captured && distance <= thresholds.capture;
  final bool snapped = stay || latch;
  return _Axis(
    captured: snapped,
    snapped: snapped,
    guide: snapped || distance <= thresholds.guide,
  );
}

/// One pointer sample. [grab] is updated when an edge consumes slack so the
/// next 1px in the opposite direction moves immediately.
@immutable
class SubtitleDragSample {
  final Offset grab;
  final Offset displayOrigin;
  final Offset boundedOrigin;
  final SubtitleSnapMemory memory;
  final bool snappedX;
  final bool snappedY;
  final bool guideX;
  final bool guideY;

  const SubtitleDragSample({
    required this.grab,
    required this.displayOrigin,
    required this.boundedOrigin,
    required this.memory,
    required this.snappedX,
    required this.snappedY,
    required this.guideX,
    required this.guideY,
  });
}

SubtitleDragSample sampleSubtitleDrag({
  required Offset pointerLocal,
  required Offset grab,
  required SubtitleSnapMemory memory,
  required Rect viewport,
  required Size content,
  SubtitleSnapThresholds thresholds = kSubtitleSnapThresholds,
}) {
  final SubtitleMoveSpace space = SubtitleMoveSpace.fromViewport(
    viewport,
    content,
  );
  final Offset raw = pointerLocal - grab;
  final double boundedX = space.x.clamp(raw.dx);
  final double boundedY = space.y.clamp(raw.dy);
  var nextGrab = grab;
  // Drop the distance the edge already consumed. The raw snap accumulator
  // still sees [bounded], not the snapped display point.
  if (boundedX != raw.dx) {
    nextGrab = Offset(pointerLocal.dx - boundedX, nextGrab.dy);
  }
  if (boundedY != raw.dy) {
    nextGrab = Offset(nextGrab.dx, pointerLocal.dy - boundedY);
  }
  final Offset bounded = Offset(boundedX, boundedY);
  final SubtitleSnapDecision decision = resolveSubtitlePixelSnap(
    boundedOrigin: bounded,
    content: content,
    viewport: viewport,
    memory: memory,
    thresholds: thresholds,
  );
  return SubtitleDragSample(
    grab: nextGrab,
    displayOrigin: decision.displayOrigin,
    boundedOrigin: bounded,
    memory: decision.memory,
    snappedX: decision.snappedX,
    snappedY: decision.snappedY,
    guideX: decision.guideX,
    guideY: decision.guideY,
  );
}

/// Conservative paint padding around the layout box. A Gaussian blur has no
/// strict zero-alpha edge; two blur radii plus the shadow offset is the range
/// the green frame is allowed to claim.
EdgeInsets subtitlePaintOutset({
  required bool hasBorder,
  required double borderWidth,
  required bool hasShadow,
  required double shadowBlur,
  required Offset shadowOffset,
  double opticalShift = 0,
}) {
  double left = 0, top = 0, right = 0, bottom = 0;
  if (hasBorder && borderWidth.isFinite && borderWidth > 0) {
    final double half = borderWidth / 2;
    left = top = right = bottom = half;
  }
  if (hasShadow && shadowBlur.isFinite) {
    final double reach = math.max(0, shadowBlur) * 2;
    final double dx = shadowOffset.dx.isFinite ? shadowOffset.dx : 0;
    final double dy = shadowOffset.dy.isFinite ? shadowOffset.dy : 0;
    left = math.max(left, reach + math.max(0, -dx));
    right = math.max(right, reach + math.max(0, dx));
    top = math.max(top, reach + math.max(0, -dy));
    bottom = math.max(bottom, reach + math.max(0, dy));
  }
  if (opticalShift.isFinite && opticalShift != 0) {
    if (opticalShift > 0) {
      bottom += opticalShift;
    } else {
      top += -opticalShift;
    }
  }
  return EdgeInsets.fromLTRB(left, top, right, bottom);
}

EdgeInsets inflateEdgeInsets(EdgeInsets a, EdgeInsets b) {
  return EdgeInsets.fromLTRB(
    math.max(a.left, b.left),
    math.max(a.top, b.top),
    math.max(a.right, b.right),
    math.max(a.bottom, b.bottom),
  );
}

Rect expandRect(Rect rect, EdgeInsets outset) {
  return Rect.fromLTRB(
    rect.left - outset.left,
    rect.top - outset.top,
    rect.right + outset.right,
    rect.bottom + outset.bottom,
  );
}

/// Playback-control avoidance for a whole caption block.
///
/// The block moves only when its box actually crosses a control, and only by
/// the minimum distance. This is the same rule the overlay used before
/// position editing; drag drafts bypass it so the pointer does not jump.
Offset resolveSubtitleOverlayOffset({
  required Size viewportSize,
  required Size subtitleSize,
  required Alignment alignment,
  double bottomInset = 0,
  double? playbackControlsTop,
  List<Rect> playbackControlRects = const <Rect>[],
}) {
  final double availableX = (viewportSize.width - subtitleSize.width)
      .clamp(0.0, double.infinity)
      .toDouble();
  final double availableY = (viewportSize.height - subtitleSize.height)
      .clamp(0.0, double.infinity)
      .toDouble();
  final double dx = availableX * (alignment.x + 1) / 2;
  double dy = (availableY * (alignment.y + 1) / 2 - bottomInset)
      .clamp(0.0, availableY)
      .toDouble();

  final List<Rect> effectiveControlRects = <Rect>[
    ...playbackControlRects.where(
      (rect) =>
          rect.left.isFinite &&
          rect.top.isFinite &&
          rect.right.isFinite &&
          rect.bottom.isFinite &&
          !rect.isEmpty,
    ),
  ];
  if (playbackControlsTop != null && playbackControlsTop.isFinite) {
    final double safeTop = playbackControlsTop
        .clamp(0.0, viewportSize.height)
        .toDouble();
    effectiveControlRects.add(
      Rect.fromLTRB(0, safeTop, viewportSize.width, viewportSize.height),
    );
  }

  bool moved;
  do {
    moved = false;
    final Rect subtitleRect = Rect.fromLTWH(
      dx,
      dy,
      subtitleSize.width,
      subtitleSize.height,
    );
    for (final Rect controlRect in effectiveControlRects) {
      if (!subtitleRect.overlaps(controlRect)) continue;
      final double resolvedY = (controlRect.top - subtitleSize.height)
          .clamp(0.0, availableY)
          .toDouble();
      if (resolvedY < dy) {
        dy = resolvedY;
        moved = true;
        break;
      }
    }
  } while (moved);

  return Offset(dx, dy);
}

/// Last layout of one subtitle surface. Writers must not notify listeners.
class SubtitleGeometryHandle {
  SubtitleLaidOutGeometry? current;
  int generation = 0;

  void update(SubtitleLaidOutGeometry value) {
    final SubtitleLaidOutGeometry? previous = current;
    final bool changed =
        previous == null ||
        previous.viewport != value.viewport ||
        previous.contentSize != value.contentSize ||
        previous.origin != value.origin;
    current = value;
    if (changed) generation++;
  }
}

@immutable
class SubtitleLaidOutGeometry {
  final Size viewport;
  final Size contentSize;
  final Offset origin;
  final Rect contentRect;
  final Rect paintRect;
  final Rect hitRect;
  final bool presetDefault;

  const SubtitleLaidOutGeometry({
    required this.viewport,
    required this.contentSize,
    required this.origin,
    required this.contentRect,
    required this.paintRect,
    required this.hitRect,
    required this.presetDefault,
  });

  Rect get viewportRect => Offset.zero & viewport;
}
