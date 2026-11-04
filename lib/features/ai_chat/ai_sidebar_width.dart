import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../widgets/landscape_sidebar_layout.dart';

/// Persist the user's preferred width; only clamp its displayed size when the
/// viewport shrinks, so returning to a larger screen restores that preference.
abstract final class AiSidebarWidth {
  static const dividerWidth = 12.0;
  static const minimumWidth = 240.0;
  static const minimumPlayerWidth = 120.0;

  static double resolve(Size viewport, {double preference = 0}) {
    final preferred = preference.isFinite && preference > 0
        ? preference
        : viewport.shortestSide < 600 || viewport.width < 1000
        ? LandscapeSidebarLayout.functionalWidthFor(viewport)
        : (viewport.width * .36).clamp(420.0, 560.0);
    return clamp(viewport, preferred);
  }

  static double clamp(Size viewport, double width) {
    final maximum = math.max(
      0.0,
      viewport.width - dividerWidth - minimumPlayerWidth,
    );
    return width.clamp(math.min(minimumWidth, maximum), maximum).toDouble();
  }
}
