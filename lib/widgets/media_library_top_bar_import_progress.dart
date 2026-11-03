import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/library_service.dart';

/// AppBar overlay: a 3px line on the toolbar's bottom edge.
///
/// Uses [preferredSize] of zero so showing/hiding never resizes the scaffold.
class MediaLibraryTopBarImportProgress extends StatelessWidget
    implements PreferredSizeWidget {
  const MediaLibraryTopBarImportProgress({super.key});

  static const double barHeight = 3;

  @override
  Size get preferredSize => Size.zero;

  @override
  Widget build(BuildContext context) {
    final library = context.read<LibraryService>();
    return SizedBox(
      height: 0,
      width: double.infinity,
      child: OverflowBox(
        alignment: Alignment.bottomCenter,
        minHeight: barHeight,
        maxHeight: barHeight,
        child: IgnorePointer(
          child: ValueListenableBuilder<double>(
            valueListenable: library.importProgress,
            builder: (context, progress, _) {
              if (progress <= 0 || progress >= 1) {
                return const SizedBox.shrink();
              }
              return LinearProgressIndicator(
                key: const ValueKey('media-library-top-bar-import-progress'),
                value: progress,
                backgroundColor: Colors.transparent,
                minHeight: barHeight,
              );
            },
          ),
        ),
      ),
    );
  }
}
