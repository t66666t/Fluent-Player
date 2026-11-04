import 'package:flutter/widgets.dart';

/// Reserves only keyboard space that has not been consumed by the parent.
/// Descendants see a zero bottom inset, so a nested panel cannot reserve it
/// again. Native IME frames are followed directly without another animation.
class KeyboardInsetPadding extends StatelessWidget {
  const KeyboardInsetPadding({
    super.key,
    this.padding = EdgeInsets.zero,
    required this.child,
  });

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: padding.add(EdgeInsets.only(bottom: bottom)),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: child,
      ),
    );
  }
}
