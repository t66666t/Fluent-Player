import 'package:flutter/material.dart';

/// Extends a pane's colors through the space reserved by its inner SafeArea.
/// Place inside that pane's width constraint, outside its SafeArea, so tablet
/// gutters and neighboring panes retain their own backgrounds.
class MobileSystemBarSurface extends StatelessWidget {
  const MobileSystemBarSurface({
    super.key,
    required this.child,
    this.topColor,
    this.bottomColor,
    this.insets,
  });

  final Widget child;
  final Color? topColor;
  final Color? bottomColor;
  final EdgeInsets? insets;

  @override
  Widget build(BuildContext context) {
    final padding = insets ?? MediaQuery.paddingOf(context);
    return Stack(
      fit: StackFit.passthrough,
      children: [
        child,
        if (topColor != null && padding.top > 0)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: padding.top,
            child: IgnorePointer(child: ColoredBox(color: topColor!)),
          ),
        if (bottomColor != null && padding.bottom > 0)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: padding.bottom,
            child: IgnorePointer(child: ColoredBox(color: bottomColor!)),
          ),
      ],
    );
  }
}
