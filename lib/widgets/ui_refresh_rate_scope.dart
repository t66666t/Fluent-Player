import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../utils/app_toast.dart';

/// Requests the fastest same-resolution UI refresh while its route is visible. Android
/// retains the final decision; leaving the route restores its prior policy.
class UiRefreshRateScope extends StatefulWidget {
  const UiRefreshRateScope({super.key, required this.child});
  final Widget child;

  @override
  State<UiRefreshRateScope> createState() => _UiRefreshRateScopeState();
}

class _UiRefreshRateScopeState extends State<UiRefreshRateScope>
    with WidgetsBindingObserver, RouteAware {
  static const _channel = MethodChannel(
    'com.example.video_player_app/playback_refresh_rate',
  );
  static int _sequence = 0;
  final int _owner = ++_sequence;
  PageRoute<dynamic>? _route;
  bool _visible = true;
  bool _foreground = true;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute && route != _route) {
      AppToast.routeObserver.unsubscribe(this);
      _route = route;
      _visible = route.isCurrent;
      AppToast.routeObserver.subscribe(this, route);
    }
    _sync();
  }

  void _sync() {
    final active = _visible && _foreground;
    if (_active == active) return;
    _active = active;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_send(active));
    }
  }

  Future<void> _send(bool active) async {
    try {
      await _channel.invokeMethod<void>('setActive', {
        'owner': _owner,
        'active': active,
      });
    } on MissingPluginException {
      // Older hosts and widget tests retain normal system-selected refresh.
    } on PlatformException {
      // An unsupported frame-rate hint must never interrupt playback.
    }
  }

  @override
  void didPush() {
    _visible = _route?.isCurrent ?? true;
    _sync();
  }

  @override
  void didPopNext() {
    _visible = true;
    _sync();
  }

  @override
  void didPushNext() {
    _visible = false;
    _sync();
  }

  // Retain the preference throughout this route's reverse transition.
  @override
  void didPop() {}

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    AppToast.routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _visible = false;
    _sync();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Compatibility name for the existing music-player entry point.
class MusicRefreshRateScope extends UiRefreshRateScope {
  const MusicRefreshRateScope({super.key, required super.child});
}
