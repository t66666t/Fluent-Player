import 'dart:math' as math;

import 'package:flutter/widgets.dart';

double progressValueFromLocalDx({
  required double localDx,
  required double width,
  required double maxValue,
  required double trackInset,
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (!width.isFinite || width <= 0 || !maxValue.isFinite || maxValue <= 0) {
    return 0;
  }
  final inset = trackInset.isFinite
      ? trackInset.clamp(0.0, width / 2).toDouble()
      : 0.0;
  final usableWidth = math.max(1.0, width - (inset * 2));
  var fraction = ((localDx - inset) / usableWidth).clamp(0.0, 1.0);
  if (textDirection == TextDirection.rtl) fraction = 1 - fraction;
  return fraction * maxValue;
}

double progressLocalDxFromValue({
  required double value,
  required double width,
  required double maxValue,
  required double trackInset,
  TextDirection textDirection = TextDirection.ltr,
}) {
  if (!width.isFinite || width <= 0 || !maxValue.isFinite || maxValue <= 0) {
    return 0;
  }
  final inset = trackInset.isFinite
      ? trackInset.clamp(0.0, width / 2).toDouble()
      : 0.0;
  var fraction = (value / maxValue).clamp(0.0, 1.0);
  if (textDirection == TextDirection.rtl) fraction = 1 - fraction;
  return inset + ((width - (inset * 2)) * fraction);
}
