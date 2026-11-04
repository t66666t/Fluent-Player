import 'package:flutter/material.dart';

/// Centers a placeholder in the space above the page's bottom overlays.
/// The caller supplies any reservation not already consumed by a safe area.
class MediaLibraryEmptyViewport extends StatelessWidget {
  const MediaLibraryEmptyViewport({
    super.key,
    required this.child,
    this.bottomPadding = 0,
    this.padding = const EdgeInsets.all(24),
  }) : assert(bottomPadding >= 0);

  final Widget child;
  final double bottomPadding;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: bottomPadding),
    child: Center(
      child: SingleChildScrollView(
        primary: false,
        padding: padding,
        child: child,
      ),
    ),
  );
}
