import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// A typeset formula is one selection unit, so copying never yields a broken
/// fragment of a fraction/matrix or the renderer's internal glyph order.
/// Uses Flutter's SelectionArea protocol, shared with the surrounding prose.
class AiSelectableMath extends SingleChildRenderObjectWidget {
  const AiSelectableMath({
    super.key,
    required this.source,
    required super.child,
  });

  final String source;

  @override
  RenderAiSelectableMath createRenderObject(BuildContext context) =>
      RenderAiSelectableMath(
        source: source,
        color:
            DefaultSelectionStyle.of(context).selectionColor ??
            Theme.of(context).colorScheme.primary.withValues(alpha: .3),
      )..registrar = SelectionContainer.maybeOf(context);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderAiSelectableMath renderObject,
  ) {
    renderObject
      ..source = source
      ..color =
          DefaultSelectionStyle.of(context).selectionColor ??
          Theme.of(context).colorScheme.primary.withValues(alpha: .3)
      ..registrar = SelectionContainer.maybeOf(context);
  }
}

class RenderAiSelectableMath extends RenderProxyBox
    with Selectable, SelectionRegistrant {
  RenderAiSelectableMath({required String source, required Color color})
    : _source = source,
      _color = color;

  String _source;
  Color _color;
  int? _start, _end;
  LayerLink? _startHandle, _endHandle;
  final _listeners = <VoidCallback>{};
  SelectionRegistrar? _targetRegistrar;

  @override
  set registrar(SelectionRegistrar? value) {
    _targetRegistrar = value;
    super.registrar = attached ? value : null;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    super.registrar = _targetRegistrar;
  }

  @override
  void detach() {
    super.registrar = null;
    _start = _end = null;
    super.detach();
  }

  @override
  void performLayout() {
    final oldSize = hasSize ? size : null;
    super.performLayout();
    if (oldSize != size && _start != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (attached) notifyListeners();
      });
    }
  }

  @override
  void dispose() {
    super.registrar = null;
    _listeners.clear();
    super.dispose();
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void notifyListeners() {
    for (final listener in _listeners.toList(growable: false)) {
      if (_listeners.contains(listener)) listener();
    }
  }

  set source(String value) {
    if (value == _source) return;
    _source = value;
    // Stream updates must not leave a selection referring to old source.
    _start = _end = null;
    markNeedsPaint();
    notifyListeners();
  }

  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  int get contentLength => _source.length;

  @override
  List<Rect> get boundingBoxes => [Offset.zero & size];

  bool get _selected => _start != null && _end != null && _start != _end;

  SelectionPoint _point(int edge, TextSelectionHandleType type) =>
      SelectionPoint(
        localPosition: Offset(edge == 0 ? 0 : size.width, size.height),
        lineHeight: size.height,
        handleType: type,
      );

  @override
  SelectionGeometry get value {
    final reversed = (_start ?? 0) > (_end ?? 0);
    return SelectionGeometry(
      hasContent: _source.isNotEmpty,
      status: _start == null || _end == null
          ? SelectionStatus.none
          : _selected
          ? SelectionStatus.uncollapsed
          : SelectionStatus.collapsed,
      startSelectionPoint: _start == null || !hasSize
          ? null
          : _point(
              _start!,
              reversed
                  ? TextSelectionHandleType.right
                  : TextSelectionHandleType.left,
            ),
      endSelectionPoint: _end == null || !hasSize
          ? null
          : _point(
              _end!,
              reversed
                  ? TextSelectionHandleType.left
                  : TextSelectionHandleType.right,
            ),
      selectionRects: _selected && hasSize ? boundingBoxes : const [],
    );
  }

  @override
  SelectedContent? getSelectedContent() =>
      _selected ? SelectedContent(plainText: _source) : null;

  @override
  SelectedContentRange? getSelection() => _start == null || _end == null
      ? null
      : SelectedContentRange(startOffset: _start!, endOffset: _end!);

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (_startHandle == startHandle && _endHandle == endHandle) return;
    _startHandle = startHandle;
    _endHandle = endHandle;
    if (attached) {
      markNeedsCompositingBitsUpdate();
      markNeedsPaint();
    }
  }

  @override
  bool get alwaysNeedsCompositing =>
      _startHandle != null ||
      _endHandle != null ||
      super.alwaysNeedsCompositing;

  SelectionResult _edge(Offset globalPosition, {required bool isEnd}) {
    final point = globalToLocal(globalPosition);
    final result = SelectionUtils.getResultBasedOnRect(
      Offset.zero & size,
      point,
    );
    final edge = switch (result) {
      SelectionResult.previous => 0,
      SelectionResult.next => contentLength,
      _ => point.dx < size.width / 2 ? 0 : contentLength,
    };
    if (isEnd) {
      _end = edge;
      _start ??= edge;
    } else {
      _start = edge;
      _end ??= edge;
    }
    return result;
  }

  SelectionResult _extend({required bool forward, required bool isEnd}) {
    final edge = forward ? contentLength : 0;
    final old = isEnd ? _end : _start;
    if (isEnd) {
      _start ??= forward ? 0 : contentLength;
      _end = edge;
    } else {
      _end ??= forward ? 0 : contentLength;
      _start = edge;
    }
    return old == edge
        ? forward
              ? SelectionResult.next
              : SelectionResult.previous
        : SelectionResult.end;
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final oldStart = _start, oldEnd = _end;
    var result = SelectionResult.none;
    switch (event.type) {
      case SelectionEventType.clear:
        _start = _end = null;
      case SelectionEventType.selectAll:
        _start = 0;
        _end = contentLength;
      case SelectionEventType.selectWord:
      case SelectionEventType.selectParagraph:
        final point = event is SelectWordSelectionEvent
            ? event.globalPosition
            : (event as SelectParagraphSelectionEvent).globalPosition;
        if (event is SelectParagraphSelectionEvent && event.absorb) {
          _start = 0;
          _end = contentLength;
          result = SelectionResult.next;
        } else if ((Offset.zero & size).contains(globalToLocal(point))) {
          _start = 0;
          _end = contentLength;
        }
      case SelectionEventType.startEdgeUpdate:
      case SelectionEventType.endEdgeUpdate:
        result = _edge(
          (event as SelectionEdgeUpdateEvent).globalPosition,
          isEnd: event.type == SelectionEventType.endEdgeUpdate,
        );
      case SelectionEventType.granularlyExtendSelection:
        final extend = event as GranularlyExtendSelectionEvent;
        result = _extend(forward: extend.forward, isEnd: extend.isEnd);
      case SelectionEventType.directionallyExtendSelection:
        final extend = event as DirectionallyExtendSelectionEvent;
        switch (extend.direction) {
          case SelectionExtendDirection.nextLine:
          case SelectionExtendDirection.previousLine:
            final forward =
                extend.direction == SelectionExtendDirection.nextLine;
            _extend(forward: forward, isEnd: extend.isEnd);
            result = forward ? SelectionResult.next : SelectionResult.previous;
          case SelectionExtendDirection.forward:
          case SelectionExtendDirection.backward:
            _edge(
              Offset(extend.dx, localToGlobal(Offset(0, size.height / 2)).dy),
              isEnd: extend.isEnd,
            );
            result = SelectionResult.end;
        }
    }
    if (oldStart != _start || oldEnd != _end) {
      markNeedsPaint();
      notifyListeners();
    }
    return result;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_selected) {
      context.canvas.drawRect(offset & size, Paint()..color = _color);
    }
    super.paint(context, offset);
    for (final handle in [
      (_startHandle, value.startSelectionPoint),
      (_endHandle, value.endSelectionPoint),
    ]) {
      if (handle.$1 != null && handle.$2 != null) {
        context.pushLayer(
          LeaderLayer(
            link: handle.$1!,
            offset: offset + handle.$2!.localPosition,
          ),
          (context, offset) {},
          Offset.zero,
        );
      }
    }
  }
}
