import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Retains the trigger so an open menu can follow a resized window or viewport.
class AnchoredMenuPosition {
  AnchoredMenuPosition.fromContext(
    BuildContext context, {
    Offset offset = Offset.zero,
  }) : _context = context,
       _offset = offset,
       _globalBounds = _bounds(context).shift(offset);

  AnchoredMenuPosition.fromRect(Rect bounds)
    : _context = null,
      _offset = Offset.zero,
      _globalBounds = bounds;

  final BuildContext? _context;
  final Offset _offset;
  Rect _globalBounds;

  static Rect _bounds(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return Rect.zero;
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
  }

  Rect get globalBounds => _globalBounds;

  bool refresh() {
    if (_context?.mounted != true) return false;
    final bounds = _bounds(_context!).shift(_offset);
    if (bounds == _globalBounds) return false;
    _globalBounds = bounds;
    return true;
  }

  Rect boundsIn(BuildContext menuContext) {
    final bounds = globalBounds;
    final overlay = Navigator.of(
      menuContext,
    ).overlay?.context.findRenderObject();
    if (overlay is! RenderBox) return bounds;
    return Rect.fromPoints(
      overlay.globalToLocal(bounds.topLeft),
      overlay.globalToLocal(bounds.bottomRight),
    );
  }
}

Rect anchoredMenuSafeBounds(
  MediaQueryData media,
  Size size, {
  double margin = 8,
}) {
  final left = math.max(media.padding.left, media.viewInsets.left) + margin;
  final top = math.max(media.padding.top, media.viewInsets.top) + margin;
  return Rect.fromLTRB(
    left,
    top,
    math.max(
      left,
      size.width -
          math.max(media.padding.right, media.viewInsets.right) -
          margin,
    ),
    math.max(
      top,
      size.height -
          math.max(media.padding.bottom, media.viewInsets.bottom) -
          margin,
    ),
  );
}

double anchoredMenuAvailableHeight(Rect anchor, Rect safe, {double gap = 6}) {
  final below = math.max(0.0, safe.bottom - anchor.bottom - gap);
  final above = math.max(0.0, anchor.top - safe.top - gap);
  // A legacy caller may supply a page-sized context instead of a button.
  return below == 0 && above == 0
      ? safe.height
      : math.min(safe.height, math.max(below, above));
}

/// Places a scrollable menu next to its trigger, within the current safe area.
class AnchoredMenuLayout extends StatefulWidget {
  const AnchoredMenuLayout({
    super.key,
    required this.position,
    required this.width,
    required this.child,
    this.maxHeight = 560,
    this.preferAbove = false,
    this.alignLeft = false,
    this.margin = 8,
    this.gap = 6,
  });

  final AnchoredMenuPosition position;
  final double width, maxHeight, margin, gap;
  final bool preferAbove, alignLeft;
  final Widget child;

  @override
  State<AnchoredMenuLayout> createState() => _AnchoredMenuLayoutState();
}

class _AnchoredMenuLayoutState extends State<AnchoredMenuLayout> {
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Read trigger transforms after its route has finished layout; fractional
    // transforms cannot safely be measured from another route's layout pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.position.refresh()) setState(() {});
    });
    final anchor = widget.position.boundsIn(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: LayoutBuilder(
          builder: (context, constraints) => CustomSingleChildLayout(
            delegate: _AnchoredMenuDelegate(
              anchor: anchor,
              safe: anchoredMenuSafeBounds(
                media,
                constraints.biggest,
                margin: widget.margin,
              ),
              width: widget.width,
              maxHeight: widget.maxHeight,
              preferAbove: widget.preferAbove,
              alignLeft: widget.alignLeft,
              gap: widget.gap,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _AnchoredMenuDelegate extends SingleChildLayoutDelegate {
  const _AnchoredMenuDelegate({
    required this.anchor,
    required this.safe,
    required this.width,
    required this.maxHeight,
    required this.preferAbove,
    required this.alignLeft,
    required this.gap,
  });

  final Rect anchor;
  final Rect safe;
  final double width, maxHeight, gap;
  final bool preferAbove, alignLeft;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        minWidth: math.min(width, safe.width),
        maxWidth: math.min(width, safe.width),
        maxHeight: math.min(
          maxHeight,
          anchoredMenuAvailableHeight(anchor, safe, gap: gap),
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = anchor;
    final below = safe.bottom - bounds.bottom - gap;
    final above = bounds.top - safe.top - gap;
    final openAbove = preferAbove
        ? above >= childSize.height || above > below
        : below < childSize.height && above > below;
    final top = openAbove
        ? bounds.top - gap - childSize.height
        : bounds.bottom + gap;
    return Offset(
      (alignLeft ? bounds.left : bounds.right - childSize.width).clamp(
        safe.left,
        math.max(safe.left, safe.right - childSize.width),
      ),
      top.clamp(safe.top, math.max(safe.top, safe.bottom - childSize.height)),
    );
  }

  @override
  bool shouldRelayout(_AnchoredMenuDelegate oldDelegate) => true;
}
