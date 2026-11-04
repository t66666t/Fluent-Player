import 'package:flutter/widgets.dart';

/// Changes the presentation size without laying out the live video subtree.
/// The reference size is the video fitted to the whole page, independent of
/// the active sidebar. FittedBox updates its paint transform as space changes;
/// the texture, poster and native video view retain their layout constraints.
class StableVideoSurface extends StatelessWidget {
  const StableVideoSurface({
    super.key,
    required this.referenceSize,
    required this.child,
  });

  final Size referenceSize;
  final Widget child;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.contain,
    child: SizedBox.fromSize(
      size: referenceSize,
      child: RepaintBoundary(child: child),
    ),
  );
}
