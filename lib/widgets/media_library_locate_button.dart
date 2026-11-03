import 'package:flutter/material.dart';
import 'media_library_tooltip.dart';

/// Transparent "show in parent folder" hit target. Chrome lives on the dock.
class MediaLibraryLocateButton extends StatelessWidget {
  const MediaLibraryLocateButton({
    super.key,
    required this.onPressed,
  });

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MediaLibraryTooltip(
      message: '显示所在目录',
      child: Semantics(
        button: true,
        label: '显示所在目录',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const ValueKey('show-in-parent-folder-button'),
            onTap: onPressed,
            hoverColor: Colors.white.withValues(alpha: 0.07),
            splashColor: Colors.blueAccent.withValues(alpha: 0.14),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}
