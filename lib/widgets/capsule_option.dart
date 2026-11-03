import 'package:flutter/material.dart';
import 'desktop_button_click_region.dart';

/// The fill, hover, focus and pressed ink share the same capsule boundary.
class CapsuleOption extends StatelessWidget {
  const CapsuleOption({
    super.key,
    required this.child,
    required this.onTap,
    this.color = Colors.transparent,
    this.side = BorderSide.none,
    this.padding = EdgeInsets.zero,
    this.borderRadius,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Color color;
  final BorderSide side;
  final EdgeInsetsGeometry padding;
  final BorderRadiusGeometry? borderRadius;

  @override
  Widget build(BuildContext context) {
    final ShapeBorder shape = borderRadius == null
        ? StadiumBorder(side: side)
        : RoundedRectangleBorder(borderRadius: borderRadius!, side: side);
    return DesktopButtonClickRegion(
      enabled: onTap != null,
      child: Material(
        color: color,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
