import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../debug/debug_log_overlay.dart';

/// Turns the mouse "back" side button into the app's back action.
///
/// It does what the system back does on the app navigator: close the debug
/// console when it is open, otherwise ask the top route to pop, so a page's
/// own back handling (a dialog, the player's docked panel, the library frame
/// stepping out of a folder) runs exactly as for the back key. At the first
/// page nothing happens. The "forward" side button does nothing.
///
/// Desktop only: Android already turns the mouse back button into a system
/// back press, and handling it here too would go back twice.
class MouseBackButtonListener extends StatelessWidget {
  const MouseBackButtonListener({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.enabled,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  /// Defaults to desktop platforms.
  final bool? enabled;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// The back action for the mouse button, shared with tests.
  static Future<void> goBack(NavigatorState? navigator) async {
    if (DebugLogOverlay.isOpen) {
      DebugLogOverlay.closePanel();
      return;
    }
    await navigator?.maybePop();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if ((event.buttons & kBackMouseButton) == 0) return;
    unawaited(goBack(navigatorKey.currentState));
  }

  @override
  Widget build(BuildContext context) {
    if (!(enabled ?? _isDesktop)) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      child: child,
    );
  }
}
