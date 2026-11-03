import 'package:flutter/services.dart';

enum DesktopTextDropInsertion { insert, appendLine, replaceAll }

/// Produces one user edit without splitting the logical line under the caret.
/// Visual word wrapping never affects the insertion position.
TextEditingValue insertDesktopDroppedText(
  TextEditingValue value,
  String dropped, {
  DesktopTextDropInsertion insertion = DesktopTextDropInsertion.insert,
  bool singleLine = false,
}) {
  var text = dropped.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = text.replaceAll('\u0000', '');
  if (singleLine) text = text.replaceAll(RegExp(r'\n+'), ' ');
  if (text.trim().isEmpty) return value;
  if (insertion == DesktopTextDropInsertion.appendLine) text = text.trim();

  final original = value.text;
  final selection = value.selection;
  final valid = selection.isValid && selection.end <= original.length;
  var start = valid ? selection.start : original.length;
  var end = valid ? selection.end : original.length;

  if (insertion == DesktopTextDropInsertion.replaceAll) {
    start = 0;
    end = original.length;
  } else if (insertion == DesktopTextDropInsertion.appendLine &&
      !singleLine &&
      (!valid || selection.isCollapsed)) {
    final caret = valid ? selection.extentOffset : original.length;
    final lineStart = caret == 0
        ? 0
        : original.lastIndexOf('\n', caret - 1) + 1;
    final nextBreak = original.indexOf('\n', caret);
    final lineEnd = nextBreak < 0 ? original.length : nextBreak;
    if (original.substring(lineStart, lineEnd).trim().isEmpty) {
      start = lineStart;
      end = lineEnd;
    } else if (lineEnd == original.length) {
      start = end = lineEnd;
      text = '\n$text';
    } else {
      start = end = lineEnd + 1;
      final nextEnd = original.indexOf('\n', start);
      final followingEnd = nextEnd < 0 ? original.length : nextEnd;
      if (original.substring(start, followingEnd).trim().isEmpty) {
        end = followingEnd;
      } else {
        text = '$text\n';
        // Park before the separator so the next drop follows the inserted text.
        return TextEditingValue(
          text: original.replaceRange(start, end, text),
          selection: TextSelection.collapsed(offset: start + text.length - 1),
        );
      }
    }
  }
  return TextEditingValue(
    text: original.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}
