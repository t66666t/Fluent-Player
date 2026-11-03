import 'package:flutter/material.dart';

import '../widgets/route_keyboard_viewport.dart';
import 'app_page_transitions.dart';
import 'live_page_transition.dart';

/// A small, live transition for pages that can contain a video texture.
///
/// Only compositing properties change: the player keeps its layout and native
/// texture throughout entry and exit. The browsing page stays still underneath
/// instead of running a second zoom or reading its contents back into an image.
class PlaybackPageRoute<T> extends AppMaterialPageRoute<T> {
  PlaybackPageRoute({
    required super.builder,
    super.settings,
    super.fullscreenDialog,
    super.delayPushOneFrame = false,
  }) : super(allowSnapshotting: false);

  @override
  Duration get transitionDuration => livePageTransitionDuration;

  @override
  Duration get reverseTransitionDuration => livePageReverseTransitionDuration;

  @override
  DelegatedTransitionBuilder get delegatedTransition => _keepSourceStill;

  static Widget? _keepSourceStill(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) => child;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => RouteKeyboardViewport(
    child: LivePageTransition(animation: animation, child: child),
  );
}
