import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'page_shortcut_keys.dart';

/// Keeps the OS input method attached only while a text field is editing.
///
/// Letter shortcuts otherwise start CJK composition, because the window itself
/// stays an IME target on Windows, Linux, and some keyboard-attached phones.
/// Detaching the IME leaves both Chinese and English modes as raw key events.
/// Focusing a real text field attaches it again, and shortcut handlers already
/// ignore keys in that state.
class ImeShortcutGate with WidgetsBindingObserver {
  ImeShortcutGate._();

  static final ImeShortcutGate instance = ImeShortcutGate._();

  static const MethodChannel channel = MethodChannel(
    'com.example.video_player_app/ime_gate',
  );

  static bool _installed = false;
  bool? _lastReported;

  static void install() {
    if (_installed || kIsWeb) return;
    _installed = true;
    FocusManager.instance.addListener(instance._onFocusChanged);
    WidgetsBinding.instance.addObserver(instance);
    instance._onFocusChanged();
  }

  @visibleForTesting
  static void debugReset() {
    if (_installed) {
      FocusManager.instance.removeListener(instance._onFocusChanged);
      WidgetsBinding.instance.removeObserver(instance);
    }
    _installed = false;
    instance._lastReported = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _lastReported = null;
      _onFocusChanged();
    }
  }

  void _onFocusChanged() {
    _report(isEditableTextFocused());
  }

  void _report(bool textInputActive) {
    if (_lastReported == textInputActive) return;
    _lastReported = textInputActive;
    unawaited(
      channel.invokeMethod<void>('setTextInputActive', textInputActive).then(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (error is PlatformException) {
            _lastReported = null;
          }
        },
      ),
    );
  }
}
