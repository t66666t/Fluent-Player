import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'hardware_keyboard_shortcuts.dart';
import 'keyboard_shortcut_hints.dart';

/// The editable field that currently owns keyboard focus, if any.
EditableText? focusedEditableText() {
  final BuildContext? focusContext =
      FocusManager.instance.primaryFocus?.context;
  if (focusContext == null) return null;
  final widget = focusContext.widget;
  return widget is EditableText
      ? widget
      : focusContext.findAncestorWidgetOfExactType<EditableText>();
}

/// True when an editable field currently owns keyboard focus.
bool isEditableTextFocused() => focusedEditableText() != null;

/// Escape belongs to the IME while the user is choosing/composing characters.
bool isEditableTextComposing() {
  final composing = focusedEditableText()?.controller.value.composing;
  return composing != null && composing.isValid && !composing.isCollapsed;
}

bool hasBlockingKeyboardModifier() {
  return HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isAltPressed ||
      HardwareKeyboard.instance.isMetaPressed;
}

String formatShortcutKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.space) return 'Space';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return 'Enter';
  }
  if (key == LogicalKeyboardKey.arrowLeft) return 'Left';
  if (key == LogicalKeyboardKey.arrowRight) return 'Right';
  if (key == LogicalKeyboardKey.arrowUp) return 'Up';
  if (key == LogicalKeyboardKey.arrowDown) return 'Down';
  final String label = key.keyLabel;
  if (label.isEmpty) return '';
  return label.length == 1 ? label.toUpperCase() : label;
}

String tooltipWithShortcutKey(
  String label,
  LogicalKeyboardKey key, {
  BuildContext? context,
}) {
  if (context != null && !KeyboardShortcutHints.of(context)) return label;
  final String shortcut = formatShortcutKey(key);
  if (shortcut.isEmpty) return label;
  return '$label ($shortcut)';
}

/// Long-press and hover share a label. Mobile suffixes require an attached
/// physical keyboard; mouse presence alone does not enable them.
String hoverAwareShortcutTooltip(
  String label,
  LogicalKeyboardKey key, {
  required BuildContext context,
}) {
  if (!supportsHardwareKeyboardShortcutsOn(defaultTargetPlatform)) {
    return label;
  }
  return tooltipWithShortcutKey(label, key, context: context);
}
