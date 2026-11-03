import 'package:flutter/widgets.dart';

import '../services/settings_service.dart';
import 'media_library_layout_profile.dart';

/// Lay out all card contents at one design width, then scale the whole card.
/// Fixed icon sizes, strokes, radii and padding therefore share the exact same
/// ratio as the text. Legacy settings retain their original rendering.
class MediaLibraryCardScale extends StatelessWidget {
  const MediaLibraryCardScale({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: SettingsService(),
    builder: (context, _) {
      if (!SettingsService().mediaLibraryReadableCardDefaults ||
          context.dependOnInheritedWidgetOfExactType<_CardScaleScope>() !=
              null) {
        return builder(context);
      }
      return LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.hasBoundedWidth ||
              !constraints.hasBoundedHeight ||
              constraints.maxWidth <= 0 ||
              constraints.maxHeight <= 0) {
            return builder(context);
          }
          final scale =
              constraints.maxWidth /
              MediaLibraryLayoutDefaults.proportionalCardWidth;
          return FittedBox(
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: MediaLibraryLayoutDefaults.proportionalCardWidth,
              height: constraints.maxHeight / scale,
              child: _CardScaleMediaQuery(
                scale: scale,
                child: _CardScaleScope(child: Builder(builder: builder)),
              ),
            ),
          );
        },
      );
    },
  );
}

/// Copy live media data without rerunning the card builder on every IME frame.
class _CardScaleMediaQuery extends StatelessWidget {
  const _CardScaleMediaQuery({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MediaQuery(
      // Image caches need the final visual resolution, including this
      // transform, rather than a 150px thumbnail on very wide cards.
      data: media.copyWith(devicePixelRatio: media.devicePixelRatio * scale),
      child: child,
    );
  }
}

class _CardScaleScope extends InheritedWidget {
  const _CardScaleScope({required super.child});

  @override
  bool updateShouldNotify(_CardScaleScope oldWidget) => false;
}
