import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Shared by folder dragging and selection on the virtual library pages.
Duration get mediaLibraryLongPressDelay => switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.macOS => const Duration(milliseconds: 320),
  _ => const Duration(milliseconds: 160),
};

/// Enters selection at the folder-card deadline while allowing child taps,
/// secondary taps and scrolling to participate in the normal gesture arena.
class MediaLibrarySelectionLongPress extends StatelessWidget {
  const MediaLibrarySelectionLongPress({
    super.key,
    required this.child,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    if (onLongPress == null) return child;
    return RawGestureDetector(
      behavior: HitTestBehavior.deferToChild,
      gestures: <Type, GestureRecognizerFactory>{
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: mediaLibraryLongPressDelay,
              ),
              (recognizer) => recognizer.onLongPress = onLongPress,
            ),
      },
      child: child,
    );
  }
}
