import 'package:flutter/material.dart';

import '../services/clipboard_detection_routes.dart';
import 'clipboard_detection_scope.dart';

/// Compatibility shell for local file drag/drop. Website clipboard monitoring
/// is retired: startup/focus never read the clipboard or open a media route.
class AppClipboardListener extends StatelessWidget {
  const AppClipboardListener({
    super.key,
    required this.navigatorKey,
    required this.routes,
    required this.child,
  });
  final GlobalKey<NavigatorState> navigatorKey;
  final ClipboardDetectionRoutes routes;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipboardDetectionScope(
    routes: routes,
    completeStartup: () async {},
    acceptDroppedLinks: (_, _) => false,
    textDragChanged: (_, {suppressClipboard = false}) {},
    child: child,
  );
}
