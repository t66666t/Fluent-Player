import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

import 'media_library_layout_profile.dart';

/// One row in the compact library popover (card ⋯, continue filter, etc.).
class MediaLibraryAnchorMenuEntry {
  const MediaLibraryAnchorMenuEntry({
    required this.value,
    required this.label,
    required this.icon,
    this.key,
    this.checked = false,
  });

  final String value;
  final String label;
  final IconData icon;
  final Key? key;
  final bool checked;
}

/// Phone / tablet / desktop sizes for the overflow popover.
///
/// The old 212–280 × 44 layout filled most of a phone and looked oversized
/// on a monitor. These caps stay readable without becoming a sheet.
class MediaLibraryAnchorMenuMetrics {
  const MediaLibraryAnchorMenuMetrics({
    required this.width,
    required this.rowHeight,
    required this.verticalPadding,
    required this.horizontalPadding,
    required this.iconSize,
    required this.iconGap,
    required this.fontSize,
    required this.radius,
  });

  final double width;
  final double rowHeight;
  final double verticalPadding;
  final double horizontalPadding;
  final double iconSize;
  final double iconGap;
  final double fontSize;
  final double radius;

  factory MediaLibraryAnchorMenuMetrics.of(Size size) {
    final cls = MediaLibraryLayoutDefaults.sizeClassFor(size);
    final double preferred;
    final double minWidth;
    final double maxWidth;
    final double rowHeight;
    final double fontSize;
    final double iconSize;
    final double radius;
    final double verticalPadding;
    final double horizontalPadding;
    final double iconGap;
    switch (cls) {
      case MediaLibrarySizeClass.phone:
        preferred = size.width * 0.56;
        minWidth = 164;
        maxWidth = 216;
        rowHeight = 38;
        fontSize = 14;
        iconSize = 16;
        radius = 12;
        verticalPadding = 4;
        horizontalPadding = 12;
        iconGap = 8;
      case MediaLibrarySizeClass.compactTablet:
        preferred = 200;
        minWidth = 176;
        maxWidth = 220;
        rowHeight = 36;
        fontSize = 14;
        iconSize = 16;
        radius = 12;
        verticalPadding = 4;
        horizontalPadding = 12;
        iconGap = 8;
      case MediaLibrarySizeClass.tablet:
        preferred = 208;
        minWidth = 184;
        maxWidth = 228;
        rowHeight = 36;
        fontSize = 14;
        iconSize = 16;
        radius = 12;
        verticalPadding = 4;
        horizontalPadding = 12;
        iconGap = 8;
      case MediaLibrarySizeClass.largeTablet:
        preferred = 216;
        minWidth = 192;
        maxWidth = 236;
        rowHeight = 36;
        fontSize = 14.5;
        iconSize = 16;
        radius = 12;
        verticalPadding = 5;
        horizontalPadding = 12;
        iconGap = 8;
      case MediaLibrarySizeClass.desktop:
        preferred = 196;
        minWidth = 172;
        maxWidth = 212;
        rowHeight = 32;
        fontSize = 13;
        iconSize = 15;
        radius = 10;
        verticalPadding = 4;
        horizontalPadding = 10;
        iconGap = 8;
    }
    final available = math.max(120.0, size.width - 24);
    final width = preferred
        .clamp(math.min(minWidth, available), math.min(maxWidth, available))
        .toDouble();
    return MediaLibraryAnchorMenuMetrics(
      width: width,
      rowHeight: rowHeight,
      verticalPadding: verticalPadding,
      horizontalPadding: horizontalPadding,
      iconSize: iconSize,
      iconGap: iconGap,
      fontSize: fontSize,
      radius: radius,
    );
  }

  double get dividerIndent => horizontalPadding + iconSize + iconGap;
}

/// Scales out of [anchor], same chrome as the card overflow menu.
class MediaLibraryAnchorMenu {
  const MediaLibraryAnchorMenu._();

  static Future<String?> show({
    required BuildContext context,
    required Rect anchor,
    required List<MediaLibraryAnchorMenuEntry> items,
    bool alignStart = false,
  }) {
    return Navigator.of(context, rootNavigator: true).push<String>(
      _AnchorMenuRoute(anchor: anchor, items: items, alignStart: alignStart),
    );
  }
}

class _AnchorMenuRoute extends PopupRoute<String> {
  _AnchorMenuRoute({
    required this.anchor,
    required this.items,
    required this.alignStart,
  });

  final Rect anchor;
  final List<MediaLibraryAnchorMenuEntry> items;
  final bool alignStart;

  static const double _margin = 10;
  static const double _gap = 6;
  static const double _separator = 0.5;
  static const Cubic _openCurve = Cubic(0.22, 1, 0.36, 1);
  static const Cubic _closeCurve = Cubic(0.4, 0, 1, 1);

  @override
  Color? get barrierColor => const Color(0x12000000);

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭菜单';

  @override
  bool get opaque => false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 280);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 180);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _AnchorMenuPanel(
      items: items,
      metrics: MediaLibraryAnchorMenuMetrics.of(MediaQuery.sizeOf(context)),
      onChoose: (value) => Navigator.of(context).pop(value),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final safe = media.padding + media.viewInsets;
    final metrics = MediaLibraryAnchorMenuMetrics.of(screen);
    final width = metrics.width;
    final height =
        metrics.verticalPadding * 2 +
        items.length * metrics.rowHeight +
        math.max(0, items.length - 1) * _separator;
    final menuSize = Size(width, height);
    final origin = _clampOrigin(screen: screen, safe: safe, menuSize: menuSize);
    final fromAbove = origin.dy + height / 2 < anchor.center.dy;
    final fromLeft = origin.dx + width / 2 < anchor.center.dx;
    final alignment = Alignment(fromLeft ? 1.0 : -1.0, fromAbove ? 1.0 : -1.0);
    final curved = CurvedAnimation(
      parent: animation,
      curve: _openCurve,
      reverseCurve: _closeCurve,
    );
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      child: SizedBox.expand(
        child: Stack(
          children: [
            Positioned(
              left: origin.dx,
              top: origin.dy,
              width: width,
              child: FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  alignment: alignment,
                  scale: Tween<double>(begin: 0.86, end: 1).animate(curved),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Offset _clampOrigin({
    required Size screen,
    required EdgeInsets safe,
    required Size menuSize,
  }) {
    final minX = safe.left + _margin;
    final minY = safe.top + _margin;
    final maxX = screen.width - safe.right - _margin - menuSize.width;
    final maxY = screen.height - safe.bottom - _margin - menuSize.height;
    var x = alignStart ? anchor.left : anchor.right - menuSize.width;
    var y = anchor.bottom + _gap;
    if (y > maxY) {
      y = anchor.top - _gap - menuSize.height;
    }
    if (maxX < minX) {
      x = minX;
    } else {
      x = x.clamp(minX, maxX);
    }
    if (maxY < minY) {
      y = minY;
    } else {
      y = y.clamp(minY, maxY);
    }
    return Offset(x, y);
  }
}

class _AnchorMenuPanel extends StatelessWidget {
  const _AnchorMenuPanel({
    required this.items,
    required this.metrics,
    required this.onChoose,
  });

  final List<MediaLibraryAnchorMenuEntry> items;
  final MediaLibraryAnchorMenuMetrics metrics;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    final radius = metrics.radius;
    return Semantics(
      namesRoute: true,
      label: '菜单',
      child: Material(
        color: Colors.transparent,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.38),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppTokens.bgOverlay,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: metrics.verticalPadding,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0)
                        Divider(
                          height: 0.5,
                          thickness: 0.5,
                          color: const Color(0x22FFFFFF),
                          indent: metrics.dividerIndent,
                        ),
                      _AnchorMenuRow(
                        entry: items[i],
                        metrics: metrics,
                        onTap: () => onChoose(items[i].value),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AnchorMenuRow extends StatelessWidget {
  const _AnchorMenuRow({
    required this.entry,
    required this.metrics,
    required this.onTap,
  });

  final MediaLibraryAnchorMenuEntry entry;
  final MediaLibraryAnchorMenuMetrics metrics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: entry.key,
      onTap: onTap,
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.pressed)
            ? Colors.transparent
            : const Color(0x22FFFFFF),
      ),
      child: SizedBox(
        height: metrics.rowHeight,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.horizontalPadding),
          child: Row(
            children: [
              Icon(entry.icon, size: metrics.iconSize, color: Colors.white),
              SizedBox(width: metrics.iconGap),
              Expanded(
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: metrics.fontSize,
                    height: 1.15,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (entry.checked)
                Icon(
                  Icons.check,
                  size: metrics.iconSize,
                  color: AppTokens.accent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
