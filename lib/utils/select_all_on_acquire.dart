import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Selects [controller]'s whole value and parks the caret at the start.
///
/// A long URL then stays scrolled to its beginning instead of jumping to the
/// end. Empty text is left as it is, so the caret does not get a fake range.
void selectEntireValue(TextEditingController controller) {
  final text = controller.text;
  if (text.isEmpty) return;
  controller.selection = TextSelection(
    baseOffset: text.length,
    extentOffset: 0,
  );
}

/// Builder for the text field whose acquiring tap should select everything.
typedef SelectAllOnAcquireBuilder =
    Widget Function(BuildContext context, GestureTapCallback onTap);

/// Selects a field's whole value only on the gesture that gives it focus.
///
/// Browser address bars work this way. The click or tap that enters the field
/// selects everything, so the next keystroke replaces it. A later click places
/// the caret. A drag, double-click, long-press, or Shift-click keeps the
/// selection that gesture made. The field has to set `selectAllOnFocus` for
/// Tab and other keyboard focus; a pointer click is an internal focus change,
/// so that flag does not cover it, and deciding inside [TextField.onTap] alone
/// is too late because the field is already focused by then.
class SelectAllOnAcquire extends StatefulWidget {
  const SelectAllOnAcquire({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.builder,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final SelectAllOnAcquireBuilder builder;

  @override
  State<SelectAllOnAcquire> createState() => _SelectAllOnAcquireState();
}

class _SelectAllOnAcquireState extends State<SelectAllOnAcquire> {
  var _armed = false;
  var _secondary = false;
  var _epoch = 0;
  Offset? _origin;

  bool _shiftPressed() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
  }

  /// Touch has no button bitmask on some devices. Mouse and trackpad only
  /// acquire the field on the primary or secondary button.
  bool _activates(PointerDownEvent event) {
    switch (event.kind) {
      case PointerDeviceKind.touch:
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
        return true;
      case PointerDeviceKind.mouse:
      case PointerDeviceKind.trackpad:
      case PointerDeviceKind.unknown:
        return event.buttons == kPrimaryButton ||
            event.buttons == kSecondaryButton;
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _epoch++;
    _origin = event.position;
    _secondary = event.buttons == kSecondaryButton;
    // Sample focus before the text field's own recognizer requests it.
    _armed =
        !widget.focusNode.hasFocus && _activates(event) && !_shiftPressed();
  }

  void _onPointerMove(PointerMoveEvent event) {
    final origin = _origin;
    if (!_armed || origin == null) return;
    if ((event.position - origin).distance > kTouchSlop) _armed = false;
  }

  void _onPointerUp(PointerUpEvent event) {
    final epoch = _epoch;
    final secondary = _secondary;
    // Primary taps select from [TextField.onTap], which runs after the caret
    // is placed. A long-press never calls onTap and must keep its word
    // selection, so this microtask only covers right-click, which also skips
    // onTap and would otherwise leave the caret where the menu opened.
    scheduleMicrotask(() {
      if (!mounted || epoch != _epoch) return;
      if (_armed && secondary) selectEntireValue(widget.controller);
      _armed = false;
      _origin = null;
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _armed = false;
    _origin = null;
    _epoch++;
  }

  void _selectIfArmed() {
    if (!_armed) return;
    _armed = false;
    selectEntireValue(widget.controller);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onPointerDown,
    onPointerMove: _onPointerMove,
    onPointerUp: _onPointerUp,
    onPointerCancel: _onPointerCancel,
    child: widget.builder(context, _selectIfArmed),
  );
}
