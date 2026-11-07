import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'media_cover_reveal.dart';

/// Each asynchronous part owns one lease. Readiness affects paint, not layout:
/// the real image can decode while the fixed-size card placeholder is visible.
/// There is no second widget tree, opacity layer, ticker, or polling timer.
class MediaCardPreparation extends ChangeNotifier {
  final Set<Object> _pending = {};
  bool _disposed = false;
  bool get isReady => _pending.isEmpty;

  VoidCallback hold() {
    if (_disposed) return () {};
    final token = Object();
    final wasReady = isReady;
    _pending.add(token);
    if (wasReady) notifyListeners();
    return () {
      if (!_pending.remove(token) || _disposed) return;
      if (isReady) notifyListeners();
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _pending.clear();
    super.dispose();
  }
}

class MediaCardPreparationHost extends StatefulWidget {
  const MediaCardPreparationHost({
    super.key,
    required this.child,
    this.radius = 8,
  });
  final Widget child;
  final double radius;

  static MediaCardPreparation? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_PreparationScope>()
      ?.preparation;

  @override
  State<MediaCardPreparationHost> createState() =>
      _MediaCardPreparationHostState();
}

class _MediaCardPreparationHostState extends State<MediaCardPreparationHost> {
  final _preparation = MediaCardPreparation();
  @override
  Widget build(BuildContext context) => _PreparationScope(
    preparation: _preparation,
    child: _PreparedCardPaint(
      preparation: _preparation,
      radius: widget.radius,
      showCardWhilePreparing: MediaCoverRevealStamp.maybeOf(context) != null,
      child: widget.child,
    ),
  );

  @override
  void dispose() {
    _preparation.dispose();
    super.dispose();
  }
}

class _PreparationScope extends InheritedWidget {
  const _PreparationScope({required this.preparation, required super.child});
  final MediaCardPreparation preparation;
  @override
  bool updateShouldNotify(_PreparationScope oldWidget) =>
      preparation != oldWidget.preparation;
}

class _PreparedCardPaint extends SingleChildRenderObjectWidget {
  const _PreparedCardPaint({
    required this.preparation,
    required this.radius,
    required this.showCardWhilePreparing,
    required super.child,
  });
  final MediaCardPreparation preparation;
  final double radius;
  final bool showCardWhilePreparing;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPreparedCard(preparation, radius, showCardWhilePreparing);
  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPreparedCard renderObject,
  ) {
    renderObject.radius = radius;
    renderObject.showCardWhilePreparing = showCardWhilePreparing;
  }
}

class _RenderPreparedCard extends RenderProxyBox {
  _RenderPreparedCard(
    this.preparation,
    this.radius,
    this._showCardWhilePreparing,
  );
  final MediaCardPreparation preparation;
  double radius;
  bool _showCardWhilePreparing;
  set showCardWhilePreparing(bool value) {
    if (value == _showCardWhilePreparing) return;
    _showCardWhilePreparing = value;
    _changed();
  }

  bool get _showChild => _showCardWhilePreparing || preparation.isReady;
  void _changed() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    preparation.addListener(_changed);
  }

  @override
  void detach() {
    preparation.removeListener(_changed);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_showChild) {
      super.paint(context, offset);
    } else {
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(offset & size, Radius.circular(radius)),
        Paint()..color = const Color(0xFF1D1F23),
      );
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      _showChild && super.hitTest(result, position: position);
  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_showChild) super.visitChildrenForSemantics(visitor);
  }
}
