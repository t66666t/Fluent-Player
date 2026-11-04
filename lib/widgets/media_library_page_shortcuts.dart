import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/settings_service.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';
import 'media_library_shell.dart';

/// Route-scoped keyboard commands shared by library browsing pages.
class MediaLibraryPageShortcuts extends StatefulWidget {
  const MediaLibraryPageShortcuts({
    super.key,
    required this.child,
    this.enabled = true,
    this.bindings = const {},
    this.onEscape,
    this.onSelectAll,
    this.captureUnfocusedKeys = true,
  });

  final Widget child;
  final bool enabled;
  final Map<LogicalKeyboardKey, VoidCallback> bindings;
  final bool Function()? onEscape;
  final VoidCallback? onSelectAll;

  /// Floating panels must only receive commands while their own subtree has
  /// focus, so a native browser or another panel keeps its keyboard events.
  final bool captureUnfocusedKeys;

  @override
  State<MediaLibraryPageShortcuts> createState() =>
      _MediaLibraryPageShortcutsState();
}

class _MediaLibraryPageShortcutsState extends State<MediaLibraryPageShortcuts> {
  final _focus = FocusNode(debugLabel: 'library page shortcuts');
  final _androidKeyDeduplicator = AndroidHardwareKeyDeduplicator();

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_fallback);
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_fallback);
    AndroidHardwareInputBridge.removeKeyListener(_handleAndroidKey);
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _fallback(KeyEvent event) {
    if (_focus.hasFocus || !widget.captureUnfocusedKeys) {
      return KeyEventResult.ignored;
    }
    return _handle(event);
  }

  void _handleAndroidKey(AndroidHardwareKeyMessage message) {
    if (!widget.captureUnfocusedKeys && !_focus.hasFocus) return;
    _handle(
      message.toKeyEvent(),
      fromNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
      shiftPressedOverride: message.isShiftPressed,
    );
  }

  KeyEventResult _handle(
    KeyEvent event, {
    bool fromNativeBridge = false,
    bool? hasBlockingModifierOverride,
    bool? shiftPressedOverride,
  }) {
    if (!mounted ||
        !widget.enabled ||
        !TickerMode.valuesOf(context).enabled ||
        !isMediaLibraryRouteCurrent(context)) {
      return KeyEventResult.ignored;
    }
    final platform = currentNativeTargetPlatform;
    if (platform == null || !supportsHardwareKeyboardShortcutsOn(platform)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final blockingModifier =
        hasBlockingModifierOverride ?? hasBlockingKeyboardModifier();
    final shiftPressed = shiftPressedOverride ?? keyboard.isShiftPressed;
    final editing = isEditableTextFocused();
    if (editing) {
      // Editing keeps all letter, navigation and selection shortcuts. Escape
      // first releases the input rather than backing out of the whole page.
      if (key != LogicalKeyboardKey.escape ||
          blockingModifier ||
          shiftPressed ||
          isEditableTextComposing()) {
        return KeyEventResult.ignored;
      }
      if (event is KeyDownEvent) FocusManager.instance.primaryFocus?.unfocus();
      return KeyEventResult.handled;
    }
    final selectAll =
        !fromNativeBridge &&
        key == LogicalKeyboardKey.keyA &&
        !keyboard.isAltPressed &&
        !keyboard.isShiftPressed &&
        (keyboard.isControlPressed || keyboard.isMetaPressed);
    if (!selectAll && (blockingModifier || shiftPressed)) {
      return KeyEventResult.ignored;
    }
    final desktop =
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.linux;
    final fullScreen =
        desktop &&
        (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11);
    final callback = selectAll
        ? widget.onSelectAll
        : widget.bindings[key] ??
              (key == LogicalKeyboardKey.keyA ? widget.onSelectAll : null);
    if (!fullScreen && key != LogicalKeyboardKey.escape && callback == null) {
      return KeyEventResult.ignored;
    }
    // Only commands accepted by this scope participate in bridge de-duplication.
    if (platform == TargetPlatform.android &&
        !_androidKeyDeduplicator.shouldDispatch(
          event,
          fromNativeBridge: fromNativeBridge,
        )) {
      return KeyEventResult.handled;
    }
    if (fullScreen) {
      if (event is KeyDownEvent) {
        unawaited(SettingsService().toggleFullScreen());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (event is! KeyDownEvent) return KeyEventResult.handled;
      if (widget.onEscape?.call() == true) return KeyEventResult.handled;
      final settings = SettingsService();
      if (desktop && settings.isFullScreen) {
        unawaited(settings.toggleFullScreen());
        return KeyEventResult.handled;
      }
      final navigator = Navigator.of(context);
      if (!navigator.canPop()) return KeyEventResult.ignored;
      unawaited(navigator.maybePop());
      return KeyEventResult.handled;
    }
    if (callback == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) callback();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus:
        widget.captureUnfocusedKeys &&
        widget.enabled &&
        TickerMode.valuesOf(context).enabled,
    canRequestFocus: widget.enabled && TickerMode.valuesOf(context).enabled,
    onKeyEvent: (_, event) => _handle(event),
    child: widget.child,
  );
}
