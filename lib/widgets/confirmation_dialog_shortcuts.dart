import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/keyboard_shortcut_hints.dart';
import '../utils/page_shortcut_keys.dart';

/// Opt-in commands for a single confirmation dialog, never its underlying page.
/// The initially focused scope uses Enter for confirmation. Once a control is
/// focused, that control owns Enter and Space as usual.
class ConfirmationDialogShortcuts extends StatefulWidget {
  const ConfirmationDialogShortcuts({
    super.key,
    required this.child,
    required this.onCancel,
    this.confirmKey,
    this.onConfirm,
  });

  final Widget child;
  final VoidCallback? onCancel;
  final LogicalKeyboardKey? confirmKey;
  final VoidCallback? onConfirm;

  @override
  State<ConfirmationDialogShortcuts> createState() =>
      _ConfirmationDialogShortcutsState();
}

class _ConfirmationDialogShortcutsState
    extends State<ConfirmationDialogShortcuts> {
  final FocusNode _focus = FocusNode(debugLabel: 'confirmation shortcuts');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!supportsNativeHardwareKeyboardShortcuts ||
        !(ModalRoute.of(context)?.isCurrent ?? true) ||
        !TickerMode.valuesOf(context).enabled) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (hasBlockingKeyboardModifier() || keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (isEditableTextFocused()) {
      if (key != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      if (isEditableTextComposing()) {
        // Let the platform IME cancel composition without dismissing a dialog.
        return KeyEventResult.skipRemainingHandlers;
      }
      if (event is KeyDownEvent) _focus.requestFocus();
      return KeyEventResult.handled;
    }
    final cancel = key == LogicalKeyboardKey.escape;
    final confirm =
        (node.hasPrimaryFocus &&
            (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter)) ||
        (widget.confirmKey != null && key == widget.confirmKey);
    if (!cancel && !confirm) return KeyEventResult.ignored;
    // Key-up and repeat never dispatch a second action. A null callback also
    // consumes the key, e.g. while an irreversible operation is running.
    if (event is KeyDownEvent) {
      if (cancel) {
        widget.onCancel?.call();
      } else {
        widget.onConfirm?.call();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _handleKey,
    child: widget.child,
  );
}

/// Keeps the ordinary button label intact and displays the key when a
/// hardware keyboard is available, following the app's existing hint policy.
class ConfirmationShortcutLabel extends StatelessWidget {
  const ConfirmationShortcutLabel(this.label, this.shortcut, {super.key});

  final String label;
  final String shortcut;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    children: [
      Text(label),
      if (KeyboardShortcutHints.of(context)) Text(' ($shortcut)'),
    ],
  );
}
