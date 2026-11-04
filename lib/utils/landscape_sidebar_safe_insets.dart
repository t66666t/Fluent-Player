import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Insets the landscape sidebar away from both physical cutouts/system bars
/// and Android edge-gesture regions.
EdgeInsets resolveLandscapeSidebarSafePadding({
  required EdgeInsets viewPadding,
  required EdgeInsets systemGestureInsets,
  required bool isLeftHandedMode,
}) {
  final double left = math.max(viewPadding.left, systemGestureInsets.left);
  final double right = math.max(viewPadding.right, systemGestureInsets.right);
  return EdgeInsets.only(
    left: isLeftHandedMode ? left : 0,
    right: isLeftHandedMode ? 0 : right,
  );
}
