import 'package:flutter/material.dart';
import '../widgets/route_keyboard_viewport.dart';
import '../utils/responsive_transition_vsync.dart';
import 'app_tokens.dart';
import 'live_page_transition.dart';

/// Shared live transition for ordinary full-page navigation on every platform.
///
/// Uses playback's live fade and subtle scale for consistent navigation.
/// Loading states and artwork stay live without capturing a page image.
const PageTransitionsTheme appPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: AppPageTransitionsBuilder(),
    TargetPlatform.iOS: AppPageTransitionsBuilder(),
    TargetPlatform.macOS: AppPageTransitionsBuilder(),
    TargetPlatform.windows: AppPageTransitionsBuilder(),
    TargetPlatform.linux: AppPageTransitionsBuilder(),
    TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
  },
);

class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Duration get transitionDuration => livePageTransitionDuration;

  @override
  Duration get reverseTransitionDuration => livePageReverseTransitionDuration;

  @override
  DelegatedTransitionBuilder get delegatedTransition => _keepPreviousStill;

  static Widget? _keepPreviousStill(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) => child;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => RouteKeyboardViewport(
    child: LivePageTransition(
      animation: animation,
      backgroundColor: AppTokens.bgBase,
      child: child,
    ),
  );
}

/// [MaterialPageRoute] using playback's immediate navigation clock by default.
/// A cold build cannot consume the first visible movement: its first advance
/// is bounded to one display period. This protects the entrance without holding
/// a second zero-progress frame for full-page prepainting.
class AppMaterialPageRoute<T> extends MaterialPageRoute<T> {
  AppMaterialPageRoute({
    required super.builder,
    super.settings,
    super.requestFocus,
    super.maintainState,
    super.fullscreenDialog,
    super.allowSnapshotting,
    super.barrierDismissible,
    super.traversalEdgeBehavior,
    super.directionalTraversalEdgeBehavior,
    bool delayPushOneFrame = false,
  }) : _delayPushOneFrame = delayPushOneFrame;

  final bool _delayPushOneFrame;
  late final ResponsiveTransitionVsync _transitionVsync;

  /// Video routes retain their immediate entrance clock.
  @protected
  @visibleForTesting
  bool get delayPushOneFrame => _delayPushOneFrame;

  @override
  AnimationController createAnimationController() {
    final hz = View.of(navigator!.context).display.refreshRate;
    _transitionVsync = ResponsiveTransitionVsync(
      navigator!,
      Duration(microseconds: (1000000 / (hz > 0 ? hz : 60)).round()),
    );
    return AnimationController(
      vsync: _transitionVsync,
      duration: transitionDuration,
      reverseDuration: reverseTransitionDuration,
      debugLabel: debugLabel,
    );
  }

  @override
  TickerFuture didPush() {
    _transitionVsync.start(alignFirstTick: delayPushOneFrame);
    return super.didPush();
  }

  @override
  bool didPop(T? result) {
    // A local-history entry may consume Back without reversing the route.
    if (!willHandlePopInternally) {
      _transitionVsync.start(alignFirstTick: true);
    }
    return super.didPop(result);
  }
}
