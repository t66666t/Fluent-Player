import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'android_hardware_input_bridge.dart';

/// Visual input mode only: switching modes never changes or clears focus.
class KeyboardFocusVisibility extends ValueNotifier<bool> {
  KeyboardFocusVisibility._() : super(false);

  static final instance = KeyboardFocusVisibility._();
  static const fadeDuration = Duration(milliseconds: 120);
  int _clients = 0;

  void _attach() {
    if (_clients++ != 0) return;
    value = false;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    FocusManager.instance.addEarlyKeyEventHandler(_onKey);
    AndroidHardwareInputBridge.addKeyListener(_onNativeKey);
  }

  void _detach() {
    if (--_clients != 0) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    FocusManager.instance.removeEarlyKeyEventHandler(_onKey);
    AndroidHardwareInputBridge.removeKeyListener(_onNativeKey);
    value = false;
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) value = false;
  }

  bool _isNavigation(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.tab;

  KeyEventResult _onKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        _isNavigation(event.logicalKey)) {
      value = true;
    }
    return KeyEventResult.ignored;
  }

  void _onNativeKey(AndroidHardwareKeyMessage event) {
    if (event.isDown &&
        !event.hasBlockingModifier &&
        _isNavigation(event.logicalKey)) {
      value = true;
    }
  }
}

/// Shares one listener across cards, toolbars, mini-player and popup routes.
class KeyboardFocusVisibilityBuilder extends StatefulWidget {
  const KeyboardFocusVisibilityBuilder({
    super.key,
    required this.builder,
    this.child,
  });

  final ValueWidgetBuilder<bool> builder;
  final Widget? child;

  @override
  State<KeyboardFocusVisibilityBuilder> createState() =>
      _KeyboardFocusVisibilityBuilderState();
}

class _KeyboardFocusVisibilityBuilderState
    extends State<KeyboardFocusVisibilityBuilder> {
  @override
  void initState() {
    super.initState();
    KeyboardFocusVisibility.instance._attach();
  }

  @override
  void dispose() {
    KeyboardFocusVisibility.instance._detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: KeyboardFocusVisibility.instance,
    builder: widget.builder,
    child: widget.child,
  );
}

/// Paints only the focus feedback; the child and its layout stay intact.
class KeyboardFocusHighlight extends StatelessWidget {
  const KeyboardFocusHighlight({
    super.key,
    required this.focused,
    required this.decoration,
    required this.child,
  });

  final bool focused;
  final BoxDecoration decoration;
  final Widget child;

  BoxDecoration get _hidden {
    BorderSide clear(BorderSide side) =>
        side.copyWith(color: side.color.withValues(alpha: 0));
    final border = switch (decoration.border) {
      Border b => Border(
        top: clear(b.top),
        right: clear(b.right),
        bottom: clear(b.bottom),
        left: clear(b.left),
      ),
      BorderDirectional b => BorderDirectional(
        top: clear(b.top),
        end: clear(b.end),
        bottom: clear(b.bottom),
        start: clear(b.start),
      ),
      _ => null,
    };
    return decoration.copyWith(
      color: decoration.color?.withValues(alpha: 0),
      border: border,
    );
  }

  @override
  Widget build(BuildContext context) => KeyboardFocusVisibilityBuilder(
    child: child,
    builder: (context, visible, child) => AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : KeyboardFocusVisibility.fadeDuration,
      curve: Curves.easeOut,
      foregroundDecoration: focused && visible ? decoration : _hidden,
      child: child,
    ),
  );
}
