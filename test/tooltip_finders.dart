import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Matches a [Tooltip] whose message is [label] or `label (shortcut)`.
Finder findTooltipLabeled(String label) {
  return find.byWidgetPredicate((widget) {
    if (widget is! Tooltip) return false;
    final message = widget.message;
    if (message == null) return false;
    return message == label || message.startsWith('$label (');
  }, description: 'Tooltip labeled "$label"');
}
