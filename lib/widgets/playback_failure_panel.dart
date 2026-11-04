import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class PlaybackFailurePanel extends StatelessWidget {
  const PlaybackFailurePanel({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70),
            const SizedBox(height: 8),
            Text(
              message,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            DesktopButtonClickRegion(
              child: FilledButton(
                key: const ValueKey('playback-retry'),
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
