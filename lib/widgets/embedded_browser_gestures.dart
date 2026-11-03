import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Recognizers that make an embedded browser win its pointer sequence immediately.
///
/// An empty set leaves the platform view waiting until every ancestor rejects
/// the gesture. A [PageView] or scrollable accepts a drag first, so a captcha
/// slider and in-page pan never see the movement. [EagerGestureRecognizer]
/// claims the sequence at pointer-down, before those ancestors can take it.
const Set<Factory<OneSequenceGestureRecognizer>>
embeddedBrowserGestureRecognizers = <Factory<OneSequenceGestureRecognizer>>{
  Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
};

/// Keeps ancestor page and scroll gestures off a browser surface.
///
/// Android and iOS only forward a pointer sequence to the native view when
/// one of [embeddedBrowserGestureRecognizers] wins, so those views must set
/// that set themselves. This boundary covers engines that watch pointers with
/// a [Listener] and ignore platform-view recognizers, which is how the
/// Windows texture WebView is embedded. The child is hit-tested first, so a
/// platform view that also claims the gesture still wins and receives it.
/// Flutter controls outside [child] keep their own taps and page swipes.
class EmbeddedBrowserGestureBoundary extends StatelessWidget {
  const EmbeddedBrowserGestureBoundary({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.deferToChild,
      gestures: <Type, GestureRecognizerFactory>{
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              EagerGestureRecognizer.new,
              (_) {},
            ),
      },
      child: child,
    );
  }
}

/// Removes an Android hybrid-composition browser when its route starts leaving.
///
/// That native view ignores the page fade, so the rest of the page is gone
/// and the browser then cuts away on its own. Unmounting it on the first
/// reverse tick leaves the page color in the zoom instead. Windows and iOS
/// draw the browser inside the route fade; removing it there would cut the
/// picture instead of fading it with the page.
class EmbeddedBrowserRouteExit extends StatelessWidget {
  const EmbeddedBrowserRouteExit({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) return child;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null) return child;
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final leaving =
            animation.status == AnimationStatus.reverse && animation.value < 1;
        if (!leaving) return child!;
        return ColoredBox(color: Theme.of(context).colorScheme.surface);
      },
      child: child,
    );
  }
}
