import 'package:flutter/widgets.dart';

/// Supplies the covering route during RouteAware.didPushNext, so a player can
/// distinguish browsing away from a handoff to another playback presentation.
class PageCoverRouteObserver extends RouteObserver<PageRoute<dynamic>> {
  Route<dynamic>? get coveringRoute => _coveringRoute;
  Route<dynamic>? _coveringRoute;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final previous = _coveringRoute;
    _coveringRoute = route;
    try {
      super.didPush(route, previousRoute);
    } finally {
      _coveringRoute = previous;
    }
  }
}
