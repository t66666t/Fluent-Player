import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Reveals a lazy task body as one clipped surface, without squeezing each row
/// or laying out every episode to measure the expanded card.
class SliverTaskReveal extends SingleChildRenderObjectWidget {
  const SliverTaskReveal({
    super.key,
    required this.progress,
    required Widget sliver,
  }) : super(child: sliver);

  final Animation<double> progress;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSliverTaskReveal(progress);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _RenderSliverTaskReveal).progress = progress;
  }
}

class _RenderSliverTaskReveal extends RenderProxySliver {
  _RenderSliverTaskReveal(this._progress);

  Animation<double> _progress;

  set progress(Animation<double> value) {
    if (_progress == value) return;
    if (attached) _progress.removeListener(_update);
    _progress = value;
    if (attached) _progress.addListener(_update);
    _update();
  }

  void _update() {
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(_update);
  }

  @override
  void detach() {
    _progress.removeListener(_update);
    super.detach();
  }

  @override
  void performLayout() {
    assert(constraints.axisDirection == AxisDirection.down);
    child!.layout(constraints, parentUsesSize: true);
    final childGeometry = child!.geometry!;
    if (childGeometry.scrollOffsetCorrection != null) {
      geometry = childGeometry;
      return;
    }
    final factor = _progress.value.clamp(0.0, 1.0);
    final extent = childGeometry.scrollExtent * factor;
    final paintExtent = math.min(
      childGeometry.paintExtent,
      calculatePaintOffset(constraints, from: 0, to: extent),
    );
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintOrigin: childGeometry.paintOrigin,
      paintExtent: paintExtent,
      layoutExtent: math.min(childGeometry.layoutExtent, paintExtent),
      maxPaintExtent: childGeometry.maxPaintExtent * factor,
      cacheExtent: math.min(
        childGeometry.cacheExtent,
        calculateCacheOffset(constraints, from: 0, to: extent),
      ),
      hitTestExtent: paintExtent,
      hasVisualOverflow: factor < 1 || childGeometry.hasVisualOverflow,
    );
  }

  Rect get _paintClip => Rect.fromLTWH(
    0,
    geometry!.paintOrigin,
    constraints.crossAxisExtent,
    geometry!.paintExtent,
  );

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!geometry!.visible) return;
    final showsBottom =
        constraints.scrollOffset + geometry!.paintExtent >=
        geometry!.scrollExtent;
    final radius = showsBottom ? const Radius.circular(12) : Radius.zero;
    context.pushClipRRect(
      needsCompositing,
      offset,
      _paintClip,
      RRect.fromRectAndCorners(
        _paintClip,
        bottomLeft: radius,
        bottomRight: radius,
      ),
      super.paint,
    );
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject child) => _paintClip;

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (geometry?.visible ?? false) super.visitChildrenForSemantics(visitor);
  }
}
