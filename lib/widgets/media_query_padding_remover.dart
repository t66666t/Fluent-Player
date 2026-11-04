import 'package:flutter/widgets.dart';

/// Removes consumed safe-area padding at a small boundary. Copying MediaQuery
/// with a page's context would subscribe that entire page to every IME frame.
class MediaQueryPaddingRemover extends StatelessWidget {
  const MediaQueryPaddingRemover({
    super.key,
    this.left = false,
    this.top = false,
    this.right = false,
    this.bottom = false,
    required this.child,
  });

  final bool left, top, right, bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery.removePadding(
    context: context,
    removeLeft: left,
    removeTop: top,
    removeRight: right,
    removeBottom: bottom,
    child: child,
  );
}
