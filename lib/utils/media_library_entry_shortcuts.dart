import 'package:flutter/services.dart';

/// Returns an index in the current visible entry order, never a fixed page ID.
int? mediaLibraryEntryShortcutIndex(
  LogicalKeyboardKey key, {
  required int currentIndex,
  required int count,
  bool control = false,
  bool shift = false,
  bool alt = false,
  bool meta = false,
}) {
  if (count <= 0 || alt || meta) return null;
  if (control) {
    if (key != LogicalKeyboardKey.tab) return null;
    return (currentIndex + (shift ? -1 : 1)) % count;
  }
  if (shift) return null;
  const digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
  ];
  const numpad = [
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
  ];
  final index = digits.contains(key)
      ? digits.indexOf(key)
      : numpad.indexOf(key);
  return index >= 0 && index < count ? index : null;
}

String mediaLibraryEntryShortcutTooltip(String label, int index) =>
    '$label（${index + 1}）\n上一个：Ctrl + Shift + Tab\n下一个：Ctrl + Tab';
