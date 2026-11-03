import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'hardware_keyboard_shortcuts.dart';

/// Presentation policy only. Shortcut dispatch stays enabled so connecting a
/// keyboard never requires reopening a page or re-registering its commands.
class HardwareKeyboardPresence extends ChangeNotifier
    with WidgetsBindingObserver {
  HardwareKeyboardPresence({TargetPlatform? platform, MethodChannel? channel})
    : _platform = platform ?? defaultTargetPlatform,
      _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'com.example.video_player_app/keyboard_presence';

  final TargetPlatform _platform;
  final MethodChannel _channel;
  bool _connected = false;
  bool _started = false;
  bool _disposed = false;
  int _request = 0;
  int _revision = 0;

  static bool desktopShowsHints(TargetPlatform platform) =>
      !kIsWeb &&
      (platform == TargetPlatform.windows ||
          platform == TargetPlatform.macOS ||
          platform == TargetPlatform.linux);

  bool get _isMobile =>
      !kIsWeb &&
      (_platform == TargetPlatform.android || _platform == TargetPlatform.iOS);

  bool get showHints =>
      desktopShowsHints(_platform) || (_isMobile && _connected);

  void start() {
    if (_started || _disposed) return;
    _started = true;
    if (!_isMobile) return;
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (_disposed || call.method != 'keyboardChanged') return;
      final connected = call.arguments;
      if (connected is! bool) return;
      // A newer native notification wins over any outstanding startup/resume
      // query, even when the notification repeats the current value.
      _revision++;
      _setConnected(connected);
    });
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (!_isMobile || !_started || _disposed) return;
    final request = ++_request;
    final revision = _revision;
    try {
      final connected = await _channel.invokeMethod<bool>(
        'isKeyboardConnected',
      );
      if (_disposed || request != _request || revision != _revision) return;
      if (connected != null) _setConnected(connected);
    } on MissingPluginException {
      // Older hosts and widget tests have no native device inventory. Keep
      // touch-only presentation; receiving a key is not proof of attachment
      // because IMEs and media controls can generate key events as well.
    } on PlatformException {
      // A failed refresh must not erase a confirmed connection.
    }
  }

  void _setConnected(bool connected) {
    if (_connected == connected) return;
    _connected = connected;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started && _isMobile) {
      WidgetsBinding.instance.removeObserver(this);
      _channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}

/// Above the app Navigator so pages, sheets, dialogs and popup routes share
/// the same live device state. Only widgets reading [of] rebuild on a change.
class KeyboardShortcutHints extends StatefulWidget {
  const KeyboardShortcutHints({super.key, required this.child, this.presence});

  final Widget child;
  final HardwareKeyboardPresence? presence;

  static bool of(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<_ShortcutHintsData>();
    if (element != null) {
      final data =
          context.dependOnInheritedElement(element) as _ShortcutHintsData;
      return data.notifier!.showHints;
    }
    // A missing optional scope must not register an unsatisfied dependency:
    // that would rebuild standalone pages on unrelated inherited/IME changes.
    final platform = currentNativeTargetPlatform;
    return platform != null &&
        HardwareKeyboardPresence.desktopShowsHints(platform);
  }

  @override
  State<KeyboardShortcutHints> createState() => _KeyboardShortcutHintsState();
}

class _KeyboardShortcutHintsState extends State<KeyboardShortcutHints> {
  late HardwareKeyboardPresence _presence;

  @override
  void initState() {
    super.initState();
    _presence = widget.presence ?? HardwareKeyboardPresence();
    _presence.start();
  }

  @override
  void didUpdateWidget(KeyboardShortcutHints oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.presence == widget.presence) return;
    if (oldWidget.presence == null) _presence.dispose();
    _presence = widget.presence ?? HardwareKeyboardPresence();
    _presence.start();
  }

  @override
  void dispose() {
    if (widget.presence == null) _presence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _ShortcutHintsData(notifier: _presence, child: widget.child);
}

class _ShortcutHintsData extends InheritedNotifier<HardwareKeyboardPresence> {
  const _ShortcutHintsData({required super.notifier, required super.child});
}

/// For compound chords as well as simple keys; keeps the action label intact
/// when the keyboard hint is unavailable.
String shortcutHintLabel(BuildContext context, String label, String shortcut) {
  return shortcut.isNotEmpty && KeyboardShortcutHints.of(context)
      ? '$label ($shortcut)'
      : label;
}
