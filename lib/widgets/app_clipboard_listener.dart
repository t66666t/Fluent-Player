import 'package:flutter/material.dart';
import '../services/clipboard_detection_routes.dart';
/// The community edition does not inspect the clipboard for website downloads.
class AppClipboardListener extends StatelessWidget {
  const AppClipboardListener({super.key, required this.navigatorKey, required this.routes, required this.child});
  final GlobalKey<NavigatorState> navigatorKey;
  final ClipboardDetectionRoutes routes;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}
