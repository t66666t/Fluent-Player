import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/widgets/route_keyboard_viewport.dart';

/// Frozen comparison implementation: a shared theme change must not silently
/// turn the previous-zoom benchmark into a second copy of the new transition.
class LegacyZoomPageRoute<T> extends AppMaterialPageRoute<T> {
  LegacyZoomPageRoute({
    required super.builder,
    super.allowSnapshotting,
    super.delayPushOneFrame,
  });

  static const _zoom = ZoomPageTransitionsBuilder(
    allowEnterRouteSnapshotting: false,
  );

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _zoom.delegatedTransition;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => RouteKeyboardViewport(
    child: _zoom.buildTransitions(
      this,
      context,
      animation,
      secondaryAnimation,
      child,
    ),
  );
}
