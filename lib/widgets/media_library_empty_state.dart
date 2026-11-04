import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'media_library_empty_viewport.dart';
import 'quiet_empty_state_visuals.dart';

/// A quiet empty surface that stays usable in short windows and with large text.
/// The caller supplies the same bottom reservation as its populated content.
class MediaLibraryEmptyState extends StatelessWidget {
  const MediaLibraryEmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.bottomPadding = 0,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final double bottomPadding;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = constraints.maxWidth < 360 ? 20.0 : 32.0;
        final compact = constraints.maxHeight - bottomPadding < 280;
        final vertical = compact ? 16.0 : 32.0;
        return MediaLibraryEmptyViewport(
          bottomPadding: bottomPadding,
          padding: EdgeInsets.symmetric(
            horizontal: horizontal,
            vertical: vertical,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    icon,
                    size: compact ? 28 : 36,
                    color: AppTokens.text4,
                  ),
                ),
                SizedBox(height: compact ? 12 : 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppTokens.text2,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
                if (actionLabel != null && onAction != null) ...[
                  const SizedBox(height: 20),
                  QuietEmptyAction(label: actionLabel!, onPressed: onAction!),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
