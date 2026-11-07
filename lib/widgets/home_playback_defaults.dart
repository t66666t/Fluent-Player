import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/settings_service.dart';

/// Capture the first home window, including split-screen, after it is laid out.
/// Listening to settings also retries if preferences finish loading later.
class HomePlaybackDefaults extends StatelessWidget {
  const HomePlaybackDefaults({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    final homeSize = MediaQuery.sizeOf(context);
    // Register before the child's startup callbacks so restored playback uses
    // the same entry page as a tap on the home screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      unawaited(settings.initializeSkipPortraitPlayerForHome(homeSize));
    });
    return child;
  }
}
