import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../models/subtitle_position.dart';
import '../services/subtitle_position_controller.dart';
import '../utils/subtitle_position_geometry.dart';

/// Positions one caption block, paints the edit frame, and hit-tests that
/// same rectangle. The frame is paint-only, so it cannot change text layout.
class SubtitlePositionViewport extends SingleChildRenderObjectWidget {
  final Alignment alignment;
  final double bottomInset;
  final bool hasPreset;
  final bool ghost;
  final bool hasPositionOverride;
  final SubtitlePositionController? controller;
  final bool showFrame;
  final bool acceptContentHits;
  final bool interactive;
  final EdgeInsets paintOutset;
  final double? playbackControlsTop;
  final List<Rect> playbackControlRects;
  final SubtitleGeometryHandle? geometryHandle;

  const SubtitlePositionViewport({
    super.key,
    required this.alignment,
    required this.bottomInset,
    required this.hasPreset,
    required this.ghost,
    required this.hasPositionOverride,
    required this.showFrame,
    required this.acceptContentHits,
    required this.interactive,
    required this.paintOutset,
    required this.playbackControlsTop,
    required this.playbackControlRects,
    this.controller,
    this.geometryHandle,
    super.child,
  });

  @override
  RenderSubtitlePositionViewport createRenderObject(BuildContext context) {
    return RenderSubtitlePositionViewport(
      alignment: alignment,
      bottomInset: bottomInset,
      hasPreset: hasPreset,
      ghost: ghost,
      hasPositionOverride: hasPositionOverride,
      controller: controller,
      showFrame: showFrame,
      acceptContentHits: acceptContentHits,
      interactive: interactive,
      paintOutset: paintOutset,
      playbackControlsTop: playbackControlsTop,
      playbackControlRects: playbackControlRects,
      geometryHandle: geometryHandle,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSubtitlePositionViewport renderObject,
  ) {
    renderObject
      ..alignment = alignment
      ..bottomInset = bottomInset
      ..hasPreset = hasPreset
      ..ghost = ghost
      ..hasPositionOverride = hasPositionOverride
      ..controller = controller
      ..showFrame = showFrame
      ..acceptContentHits = acceptContentHits
      ..interactive = interactive
      ..paintOutset = paintOutset
      ..playbackControlsTop = playbackControlsTop
      ..playbackControlRects = playbackControlRects
      ..geometryHandle = geometryHandle;
  }
}

class RenderSubtitlePositionViewport extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  RenderSubtitlePositionViewport({
    required Alignment alignment,
    required double bottomInset,
    required bool hasPreset,
    required bool ghost,
    required bool hasPositionOverride,
    required SubtitlePositionController? controller,
    required bool showFrame,
    required bool acceptContentHits,
    required bool interactive,
    required EdgeInsets paintOutset,
    required double? playbackControlsTop,
    required List<Rect> playbackControlRects,
    required SubtitleGeometryHandle? geometryHandle,
  }) : _alignment = alignment,
       _bottomInset = bottomInset,
       _hasPreset = hasPreset,
       _ghost = ghost,
       _hasPositionOverride = hasPositionOverride,
       _controller = controller,
       _showFrame = showFrame,
       _acceptContentHits = acceptContentHits,
       _interactive = interactive,
       _paintOutset = paintOutset,
       _playbackControlsTop = playbackControlsTop,
       _playbackControlRects = playbackControlRects,
       _geometryHandle = geometryHandle;

  Alignment _alignment;
  double _bottomInset;
  bool _hasPreset;
  bool _ghost;
  bool _hasPositionOverride;
  SubtitlePositionController? _controller;
  bool _showFrame;
  bool _acceptContentHits;
  bool _interactive;
  EdgeInsets _paintOutset;
  double? _playbackControlsTop;
  List<Rect> _playbackControlRects;
  SubtitleGeometryHandle? _geometryHandle;

  Offset _origin = Offset.zero;
  Rect _contentRect = Rect.zero;
  Rect _paintRect = Rect.zero;
  Rect _hitRect = Rect.zero;
  bool _presetDefault = false;

  Alignment get alignment => _alignment;
  set alignment(Alignment value) {
    if (_alignment == value) return;
    _alignment = value;
    markNeedsLayout();
  }

  double get bottomInset => _bottomInset;
  set bottomInset(double value) {
    if (_bottomInset == value) return;
    _bottomInset = value;
    markNeedsLayout();
  }

  bool get hasPreset => _hasPreset;
  set hasPreset(bool value) {
    if (_hasPreset == value) return;
    _hasPreset = value;
    markNeedsLayout();
  }

  bool get ghost => _ghost;
  set ghost(bool value) {
    if (_ghost == value) return;
    _ghost = value;
    markNeedsLayout();
  }

  bool get hasPositionOverride => _hasPositionOverride;
  set hasPositionOverride(bool value) {
    if (_hasPositionOverride == value) return;
    _hasPositionOverride = value;
    markNeedsLayout();
  }

  SubtitlePositionController? get controller => _controller;
  set controller(SubtitlePositionController? value) {
    if (_controller == value) return;
    _controller?.removeListener(markNeedsLayout);
    _controller = value;
    if (attached) _controller?.addListener(markNeedsLayout);
    markNeedsLayout();
  }

  bool get showFrame => _showFrame;
  set showFrame(bool value) {
    if (_showFrame == value) return;
    _showFrame = value;
    markNeedsPaint();
  }

  bool get acceptContentHits => _acceptContentHits;
  set acceptContentHits(bool value) {
    if (_acceptContentHits == value) return;
    _acceptContentHits = value;
    markNeedsPaint();
  }

  bool get interactive => _interactive;
  set interactive(bool value) {
    if (_interactive == value) return;
    _interactive = value;
    markNeedsLayout();
  }

  EdgeInsets get paintOutset => _paintOutset;
  set paintOutset(EdgeInsets value) {
    if (_paintOutset == value) return;
    _paintOutset = value;
    markNeedsLayout();
  }

  double? get playbackControlsTop => _playbackControlsTop;
  set playbackControlsTop(double? value) {
    if (_playbackControlsTop == value) return;
    _playbackControlsTop = value;
    markNeedsLayout();
  }

  List<Rect> get playbackControlRects => _playbackControlRects;
  set playbackControlRects(List<Rect> value) {
    if (_sameRects(_playbackControlRects, value)) return;
    _playbackControlRects = value;
    markNeedsLayout();
  }

  SubtitleGeometryHandle? get geometryHandle => _geometryHandle;
  set geometryHandle(SubtitleGeometryHandle? value) {
    if (_geometryHandle == value) return;
    _geometryHandle = value;
    markNeedsLayout();
  }

  bool _sameRects(List<Rect> a, List<Rect> b) {
    if (identical(a, b) || a.length != b.length) {
      return identical(a, b);
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller?.addListener(markNeedsLayout);
  }

  @override
  void detach() {
    _controller?.removeListener(markNeedsLayout);
    super.detach();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void performResize() {
    size = constraints.biggest;
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      _origin = Offset.zero;
      _contentRect = Rect.zero;
      _paintRect = Rect.zero;
      _hitRect = Rect.zero;
      return;
    }
    if (!_hasPreset || _ghost || _hasPositionOverride) {
      _controller?.acknowledgePlacement(_alignment);
    }
    // A live draft means the preset inset has already been baked into the
    // pointer origin. Reapplying it, or the control avoidance, would jump.
    final bool drafting = _controller?.draftOrigin != null;
    final PresetLayoutDecision decision = resolvePresetSubtitleLayout(
      hasPreset: _hasPreset,
      ghost: _ghost,
      hasPositionOverride: _hasPositionOverride || drafting,
      requestedAlignment: _alignment,
      presetBottomInset: _bottomInset,
    );
    _presetDefault = _hasPreset && !_ghost && !decision.custom;
    final double maxHeight = _presetDefault
        ? (size.height - decision.bottomInset)
              .clamp(0.0, size.height)
              .toDouble()
        : size.height;
    child.layout(
      BoxConstraints(maxWidth: size.width, maxHeight: maxHeight),
      parentUsesSize: true,
    );
    final Offset resolved = drafting
        ? _controller!.draftOrigin!
        : resolveSubtitleOverlayOffset(
            viewportSize: size,
            subtitleSize: child.size,
            alignment: decision.alignment,
            bottomInset: decision.bottomInset,
            playbackControlsTop: _playbackControlsTop,
            playbackControlRects: _playbackControlRects,
          );
    _origin = resolved;
    final BoxParentData parentData = child.parentData! as BoxParentData;
    parentData.offset = _origin;
    _contentRect = _origin & child.size;
    _paintRect = expandRect(_contentRect, _paintOutset);
    _hitRect = _contentRect.inflate(kSubtitleEditHitSlop);
    _geometryHandle?.update(
      SubtitleLaidOutGeometry(
        viewport: size,
        contentSize: child.size,
        origin: _origin,
        contentRect: _contentRect,
        paintRect: _paintRect,
        hitRect: _hitRect,
        presetDefault: _presetDefault,
      ),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? child = this.child;
    if (child != null) {
      context.paintChild(child, offset + _origin);
    }
    if (_acceptContentHits && attached) {
      final Offset topLeft = localToGlobal(Offset.zero);
      SubtitleDragPointerOwner.globalHitRect = _hitRect.shift(topLeft);
      SubtitleDragPointerOwner.editing =
          _interactive || (_controller?.editing ?? false);
    }
    final Canvas canvas = context.canvas;
    if (_showFrame && !_contentRect.isEmpty) {
      final Paint frame = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = kSubtitleEditFrameStroke
        ..color = const Color(0xFF69F0AE);
      canvas.drawRect(_paintRect.shift(offset), frame);
      _paintGuide(canvas, offset, horizontal: true);
      _paintGuide(canvas, offset, horizontal: false);
    }
  }

  void _paintGuide(Canvas canvas, Offset offset, {required bool horizontal}) {
    final bool show = horizontal
        ? (_controller?.guideX ?? false)
        : (_controller?.guideY ?? false);
    if (!show) return;
    final bool strong = horizontal
        ? (_controller?.snappedX ?? false)
        : (_controller?.snappedY ?? false);
    final Paint paint = Paint()
      ..color = const Color(0xFFFFFFFF).withValues(alpha: strong ? 0.52 : 0.22)
      ..strokeWidth = strong ? 2 : 1;
    final Offset center = offset + Offset(size.width / 2, size.height / 2);
    if (horizontal) {
      canvas.drawLine(
        Offset(center.dx, offset.dy),
        Offset(center.dx, offset.dy + size.height),
        paint,
      );
    } else {
      canvas.drawLine(
        Offset(offset.dx, center.dy),
        Offset(offset.dx + size.width, center.dy),
        paint,
      );
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    final bool childHit = hitTestChildren(result, position: position);
    final bool inContent =
        _acceptContentHits && _contentRect.contains(position);
    final bool inSlop = _interactive && _hitRect.contains(position);
    if (childHit || inContent || inSlop) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? child = this.child;
    if (child == null) return false;
    final BoxParentData parentData = child.parentData! as BoxParentData;
    return result.addWithPaintOffset(
      offset: parentData.offset,
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) {
        return child.hitTest(result, position: transformed);
      },
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final BoxParentData parentData = child.parentData! as BoxParentData;
    transform.translateByDouble(
      parentData.offset.dx,
      parentData.offset.dy,
      0,
      1,
    );
  }
}

/// Immediate drag for a subtitle surface after entering position editing.
/// A second finger is ignored.
class SubtitlePositionGestures extends StatefulWidget {
  final SubtitlePositionController? controller;
  final bool interactive;
  final void Function(int pointer)? onPointerClaimed;
  final Widget child;

  const SubtitlePositionGestures({
    super.key,
    required this.controller,
    required this.interactive,
    required this.onPointerClaimed,
    required this.child,
  });

  @override
  State<SubtitlePositionGestures> createState() =>
      _SubtitlePositionGesturesState();
}

class _SubtitlePositionGesturesState extends State<SubtitlePositionGestures> {
  late final _ImmediateSubtitleDragRecognizer _drag;
  bool _cursorDragging = false;

  @override
  void initState() {
    super.initState();
    _drag = _ImmediateSubtitleDragRecognizer();
    widget.controller?.addListener(_onController);
  }

  @override
  void didUpdateWidget(SubtitlePositionGestures oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onController);
      widget.controller?.addListener(_onController);
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onController);
    // RawGestureDetector owns and disposes the recognizer instances.
    super.dispose();
  }

  void _onController() {
    final bool dragging = widget.controller?.dragging ?? false;
    if (dragging != _cursorDragging && mounted) {
      setState(() => _cursorDragging = dragging);
    }
  }

  Offset? _local(Offset global) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final Offset local = box.globalToLocal(global);
    if (!local.dx.isFinite || !local.dy.isFinite) return null;
    return local;
  }

  bool _contains(Offset local) {
    final Rect? hit = widget.controller?.geometry.current?.hitRect;
    final Rect? content = widget.controller?.geometry.current?.contentRect;
    if (widget.interactive) {
      return hit?.contains(local) ?? content?.contains(local) ?? false;
    }
    return content?.contains(local) ?? hit?.contains(local) ?? false;
  }

  void _claim(int pointer) => widget.onPointerClaimed?.call(pointer);

  @override
  Widget build(BuildContext context) {
    _drag.enabled = widget.interactive && widget.controller != null;
    _drag.allow = (Offset global) {
      final Offset? local = _local(global);
      return local != null && _contains(local);
    };
    _drag.onDown = (PointerDownEvent event) {
      final Offset? local = _local(event.position);
      if (local == null) return;
      final bool started =
          widget.controller?.pointerDown(
            pointer: event.pointer,
            local: local,
          ) ??
          false;
      if (started) _claim(event.pointer);
    };
    _drag.onMove = (PointerMoveEvent event) {
      final Offset? local = _local(event.position);
      if (local == null) return;
      widget.controller?.pointerMove(pointer: event.pointer, local: local);
    };
    _drag.onEnd = (PointerEvent event) {
      final Offset? local = _local(event.position);
      if (event is PointerCancelEvent) {
        widget.controller?.pointerCancel(pointer: event.pointer);
      } else {
        widget.controller?.pointerUp(pointer: event.pointer, local: local);
      }
    };
    final bool listening = widget.controller != null;
    return MouseRegion(
      // This widget spans the player, but only the laid-out caption accepts
      // input. MouseRegion's opaque default would cover every control below
      // it as soon as a cue appears, for touch as well as mouse clicks.
      hitTestBehavior: HitTestBehavior.deferToChild,
      cursor: widget.interactive
          ? (_cursorDragging
                ? SystemMouseCursors.grabbing
                : SystemMouseCursors.grab)
          : MouseCursor.defer,
      child: RawGestureDetector(
        behavior: HitTestBehavior.deferToChild,
        gestures: listening
            ? <Type, GestureRecognizerFactory>{
                _ImmediateSubtitleDragRecognizer:
                    GestureRecognizerFactoryWithHandlers<
                      _ImmediateSubtitleDragRecognizer
                    >(() => _drag, (_) {}),
              }
            : const <Type, GestureRecognizerFactory>{},
        child: widget.child,
      ),
    );
  }
}

class _ImmediateSubtitleDragRecognizer extends OneSequenceGestureRecognizer {
  _ImmediateSubtitleDragRecognizer() : super();

  bool enabled = false;
  bool Function(Offset global)? allow;
  void Function(PointerDownEvent event)? onDown;
  void Function(PointerMoveEvent event)? onMove;
  void Function(PointerEvent event)? onEnd;
  int? _pointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (!enabled || _pointer != null) return;
    if (allow != null && !allow!(event.position)) return;
    _pointer = event.pointer;
    startTrackingPointer(event.pointer, event.transform);
    resolve(GestureDisposition.accepted);
    onDown?.call(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent) {
      onMove?.call(event);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      onEnd?.call(event);
      stopTrackingPointer(event.pointer);
      _pointer = null;
    }
  }

  @override
  String get debugDescription => 'subtitle-position-drag';

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
  }
}
