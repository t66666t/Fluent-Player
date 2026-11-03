import 'package:flutter/widgets.dart';

import '../services/clipboard_detection_routes.dart';

/// Startup may finish on the library, but subsequent checks belong to the app.
class ClipboardDetectionScope extends InheritedWidget {
  const ClipboardDetectionScope({
    super.key,
    required this.routes,
    required this.completeStartup,
    this.acceptDroppedLinks,
    this.textDragChanged,
    this.inspectClipboard,
    required super.child,
  });

  final ClipboardDetectionRoutes routes;
  final Future<void> Function() completeStartup;
  final bool Function(String? text, List<String> urls)? acceptDroppedLinks;
  final void Function(bool active, {bool suppressClipboard})? textDragChanged;
  final VoidCallback? inspectClipboard;

  static ClipboardDetectionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ClipboardDetectionScope>();

  @override
  bool updateShouldNotify(ClipboardDetectionScope oldWidget) =>
      !identical(routes, oldWidget.routes);
}
