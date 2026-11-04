import 'dart:async';

import 'package:flutter/widgets.dart';

/// The root navigator and visible nested navigators share one prompt gate.
/// Page changes are allowed; popups and unfinished transitions defer a check.
class ClipboardDetectionRoutes extends ChangeNotifier {
  ClipboardDetectionRoutes() {
    rootObserver = ClipboardDetectionNavigatorObserver._(this);
  }

  late final ClipboardDetectionNavigatorObserver rootObserver;
  final Set<ClipboardDetectionNavigatorObserver> _nested = {};
  bool _disposed = false;

  bool get canPresentPrompt =>
      !_disposed &&
      rootObserver._isSettledPage &&
      _nested.every((observer) {
        final host = observer._hostRoute?.call();
        return host == null || !host.isCurrent || observer._isSettledPage;
      });

  ClipboardDetectionNavigatorObserver observeNestedNavigator({
    required ModalRoute<dynamic>? Function() hostRoute,
  }) {
    final observer = ClipboardDetectionNavigatorObserver._(this, hostRoute);
    _nested.add(observer);
    return observer;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    rootObserver.dispose();
    for (final observer in _nested.toList()) {
      observer.dispose();
    }
    super.dispose();
  }
}

class ClipboardDetectionNavigatorObserver extends NavigatorObserver {
  ClipboardDetectionNavigatorObserver._(this._owner, [this._hostRoute]);

  final ClipboardDetectionRoutes _owner;
  final ModalRoute<dynamic>? Function()? _hostRoute;
  final Set<TransitionRoute<dynamic>> _retiring = {};
  Route<dynamic>? _top;
  Animation<double>? _animation;
  bool _gesturing = false;
  bool _disposed = false;

  Route<dynamic>? get topRoute => _top;

  bool get _isSettledPage =>
      !_disposed &&
      _top is PageRoute<dynamic> &&
      !_gesturing &&
      _retiring.isEmpty &&
      (_animation == null || _animation!.status == AnimationStatus.completed);

  void _animationChanged(AnimationStatus _) => _owner._changed();

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    if (_disposed) return;
    _animation?.removeStatusListener(_animationChanged);
    _top = topRoute;
    _animation = topRoute is TransitionRoute<dynamic>
        ? topRoute.animation
        : null;
    _animation?.addStatusListener(_animationChanged);
    _owner._changed();
  }

  void _waitForExit(Route<dynamic>? route) {
    if (_disposed || route is! TransitionRoute<dynamic>) return;
    _retiring.add(route);
    _owner._changed();
    unawaited(
      route.completed.then((_) {
        if (_disposed) return;
        _retiring.remove(route);
        _owner._changed();
      }),
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _waitForExit(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _waitForExit(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _waitForExit(oldRoute);

  @override
  void didStartUserGesture(
    Route<dynamic> route,
    Route<dynamic>? previousRoute,
  ) {
    _gesturing = true;
    _owner._changed();
  }

  @override
  void didStopUserGesture() {
    _gesturing = false;
    _owner._changed();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _animation?.removeStatusListener(_animationChanged);
    _animation = null;
    _top = null;
    _retiring.clear();
    _owner._nested.remove(this);
    _owner._changed();
  }
}
