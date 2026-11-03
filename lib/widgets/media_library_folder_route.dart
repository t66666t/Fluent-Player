import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_page_transitions.dart';
import '../theme/app_tokens.dart';
import '../theme/live_page_transition.dart';
import 'route_keyboard_viewport.dart';

/// Route name for one library folder. Breadcrumbs pop back to this name.
@visibleForTesting
String mediaLibraryFolderRouteName(String folderId) =>
    'media-library-folder:$folderId';

/// Opens a folder with the same live fade and subtle scale as video playback.
///
/// The previous level stays still. Retained paint layers and a stationary
/// background preserve the covered-grid paint optimization without a snapshot.
/// Navigation starts immediately; optional thumbnail warmup belongs to the page
/// after its entry, rather than a forced pre-animation paint frame.
///
/// [restored] is the cold-start reopen of the last folder: the page is shown
/// immediately, with no entrance animation.
class MediaLibraryFolderRoute<T> extends AppMaterialPageRoute<T> {
  MediaLibraryFolderRoute({
    required super.builder,
    super.settings,
    this.restored = false,
  });

  final bool restored;

  @override
  Duration get transitionDuration =>
      restored ? Duration.zero : livePageTransitionDuration;

  @override
  Duration get reverseTransitionDuration => livePageReverseTransitionDuration;

  @override
  DelegatedTransitionBuilder get delegatedTransition => _keepParentStill;

  static Widget? _keepParentStill(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) => AnimatedBuilder(
    animation: secondaryAnimation,
    child: child,
    builder: (context, child) {
      // Once the child's full-viewport background is opaque, the previous
      // grid is completely covered. Keep its state and layout but stop
      // rasterizing it. Return immediately makes it live again.
      final covered =
          secondaryAnimation.isCompleted ||
          (secondaryAnimation.status == AnimationStatus.forward &&
              secondaryAnimation.value >= livePageOpacityEnd);
      return Opacity(opacity: covered ? 0 : 1, child: child);
    },
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => RouteKeyboardViewport(
    child: LivePageTransition(
      animation: animation,
      backgroundColor: AppTokens.bgBase,
      // On high-resolution Android surfaces the extra full-page image filter
      // increases GPU work. Native transform painting keeps the same live fade
      // and scale; desktop keeps its existing filtered-layer optimization.
      filterQuality: defaultTargetPlatform == TargetPlatform.android
          ? null
          : allowSnapshotting
          ? FilterQuality.low
          : null,
      child: _keepParentStill(
        context,
        animation,
        secondaryAnimation,
        allowSnapshotting,
        child,
      )!,
    ),
  );
}

Route<T> buildMediaLibraryFolderRoute<T>({
  required WidgetBuilder builder,
  String? folderId,
  bool restored = false,
}) {
  return MediaLibraryFolderRoute<T>(
    builder: builder,
    restored: restored,
    settings: RouteSettings(
      name: folderId == null ? null : mediaLibraryFolderRouteName(folderId),
    ),
  );
}

/// Drops every folder above [folderId] in one turn, without playing each exit.
///
/// [Navigator.popUntil] keeps a route present while its exit animation runs, so
/// a deep jump paints the page underneath (often the library home) before the
/// target. Removing those routes outright leaves the tapped folder on screen.
///
/// Returns whether [folderId] was found. When it was not, the navigator is
/// already on the first route and the caller can place that folder directly.
bool popMediaLibraryToFolder(NavigatorState navigator, {String? folderId}) {
  final target = folderId == null
      ? null
      : mediaLibraryFolderRouteName(folderId);
  final foundRoot = folderId == null;
  for (var guard = 0; guard < 64; guard++) {
    Route<dynamic>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    final route = top;
    if (route == null) return foundRoot;
    if (target != null && route.settings.name == target) return true;
    if (route.isFirst) return foundRoot;
    navigator.removeRoute(route);
  }
  return foundRoot;
}
