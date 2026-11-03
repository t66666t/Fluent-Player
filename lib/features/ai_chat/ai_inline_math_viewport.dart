import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A horizontal viewport that preserves the child's mathematical baseline.
///
/// Unlike [SingleChildScrollView], the viewport reports its child's actual
/// baseline. Horizontal scrolling never changes that vertical coordinate.
/// The child is measured at its natural width, and short formulas occupy only
/// that width. Intrinsic and dry measurements do not depend on a build pass.
class AiInlineMathViewport extends StatelessWidget {
  const AiInlineMathViewport({super.key, this.controller, required this.child});

  final ScrollController? controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return Scrollable(
      axisDirection: AxisDirection.right,
      controller: controller,
      physics: const ClampingScrollPhysics(),
      // ScrollPosition enables the horizontal recognizer only when there is
      // overflow. Ordinary formulas therefore leave selection drags alone.
      scrollBehavior: behavior.copyWith(
        scrollbars: false,
        overscroll: false,
        dragDevices: {...behavior.dragDevices, PointerDeviceKind.mouse},
      ),
      viewportBuilder: (context, offset) =>
          _InlineMathViewport(offset: offset, child: child),
    );
  }
}

class _InlineMathViewport extends SingleChildRenderObjectWidget {
  const _InlineMathViewport({required this.offset, required super.child});

  final ViewportOffset offset;

  @override
  RenderAiInlineMathViewport createRenderObject(BuildContext context) =>
      RenderAiInlineMathViewport(offset: offset);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAiInlineMathViewport renderObject,
  ) => renderObject.offset = offset;
}

/// The public render type allows layout/baseline regressions to be inspected
/// without depending on implementation details of [Scrollable].
class RenderAiInlineMathViewport extends RenderProxyBox
    implements RenderAbstractViewport {
  RenderAiInlineMathViewport({required ViewportOffset offset})
    : _offset = offset;

  ViewportOffset _offset;
  final LayerHandle<ClipRectLayer> _clipLayer = LayerHandle<ClipRectLayer>();

  ViewportOffset get offset => _offset;

  set offset(ViewportOffset value) {
    if (identical(value, _offset)) return;
    if (attached) _offset.removeListener(_handleScroll);
    _offset = value;
    if (attached) _offset.addListener(_handleScroll);
    markNeedsLayout();
  }

  void _handleScroll() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_handleScroll);
  }

  @override
  void detach() {
    _offset.removeListener(_handleScroll);
    super.detach();
  }

  @override
  void dispose() {
    _clipLayer.layer = null;
    super.dispose();
  }

  BoxConstraints _childConstraints(BoxConstraints constraints) =>
      constraints.heightConstraints();

  double get _scrollExtent =>
      child == null ? 0 : math.max(0, child!.size.width - size.width);

  Offset get _paintOffset => Offset(-_offset.pixels, 0);

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    child?.getDryLayout(_childConstraints(constraints)) ?? Size.zero,
  );

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => child?.getDryBaseline(_childConstraints(constraints), baseline);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      child?.getDistanceToActualBaseline(baseline);

  @override
  void performLayout() {
    final box = child;
    if (box == null) {
      size = constraints.smallest;
    } else {
      box.layout(_childConstraints(constraints), parentUsesSize: true);
      size = constraints.constrain(box.size);
    }
    if (_offset.hasPixels) {
      if (_offset.pixels < 0) {
        _offset.correctBy(-_offset.pixels);
      } else if (_offset.pixels > _scrollExtent) {
        _offset.correctBy(_scrollExtent - _offset.pixels);
      }
    }
    _offset.applyViewportDimension(size.width);
    _offset.applyContentDimensions(0, _scrollExtent);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    void paintChild(PaintingContext context, Offset offset) =>
        context.paintChild(child!, offset + _paintOffset);
    if (_scrollExtent > 0) {
      _clipLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        paintChild,
        clipBehavior: Clip.hardEdge,
        oldLayer: _clipLayer.layer,
      );
    } else {
      _clipLayer.layer = null;
      paintChild(context, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      child != null &&
      result.addWithPaintOffset(
        offset: _paintOffset,
        position: position,
        hitTest: (result, transformed) =>
            child!.hitTest(result, position: transformed),
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) =>
      transform.translateByDouble(_paintOffset.dx, 0, 0, 1);

  @override
  Rect? describeApproximatePaintClip(RenderObject child) =>
      _scrollExtent > 0 ? Offset.zero & size : null;

  @override
  RevealedOffset getOffsetToReveal(
    RenderObject target,
    double alignment, {
    Rect? rect,
    Axis? axis,
  }) {
    if (child == null || target is! RenderBox) {
      return RevealedOffset(
        offset: _offset.pixels,
        rect: rect ?? target.paintBounds,
      );
    }
    final bounds = MatrixUtils.transformRect(
      target.getTransformTo(child),
      rect ?? target.paintBounds,
    );
    final targetOffset = bounds.left - (size.width - bounds.width) * alignment;
    return RevealedOffset(
      offset: targetOffset,
      rect: bounds.shift(Offset(-targetOffset, 0)),
    );
  }

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (!_offset.allowImplicitScrolling) {
      super.showOnScreen(
        descendant: descendant,
        rect: rect,
        duration: duration,
        curve: curve,
      );
      return;
    }
    final revealed = RenderViewportBase.showInViewport(
      descendant: descendant,
      viewport: this,
      offset: _offset,
      rect: rect,
      duration: duration,
      curve: curve,
    );
    super.showOnScreen(rect: revealed, duration: duration, curve: curve);
  }
}
