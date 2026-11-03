import 'package:flutter/widgets.dart';

import 'debug_log_buffer.dart';

/// Writes page changes into the debug ball.
///
/// Most screens do not log their own open or close, but those transitions are
/// visible while a debug session is attached to the navigator.
class DebugLogNavigatorObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    DebugLogBuffer.instance.add('打开 ${_label(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    DebugLogBuffer.instance.add('返回 ${_label(previousRoute ?? route)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    DebugLogBuffer.instance.add('替换 ${_label(newRoute ?? oldRoute)}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    DebugLogBuffer.instance.add('移除 ${_label(route)}');
  }

  String _label(Route<dynamic>? route) {
    if (route == null) return '未知页面';
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    return '${route.runtimeType}';
  }
}
