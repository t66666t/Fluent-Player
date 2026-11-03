import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../utils/ui_interaction_budget.dart';
import '../utils/responsive_transition_vsync.dart';

/// One interruptible clock for the dock, reading surfaces and mobile overlay.
/// Retargeting samples the displayed values before changing any endpoints.
/// Only render/transition widgets listen to this clock, never the player page.
class PlayerSidebarMotion with WidgetsBindingObserver {
  PlayerSidebarMotion({required TickerProvider vsync})
    : _vsync = ResponsiveTransitionVsync(
        vsync,
        Duration(microseconds: (1000000 / _displayRate()).round()),
        protectFirstAdvance: false,
      ) {
    _clock = AnimationController(vsync: _vsync, value: 1);
    _extent = _SidebarChannel(_clock, 0, 0);
    _clock.addStatusListener(_statusChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  static const openDuration = Duration(milliseconds: 160);
  static const switchDuration = Duration(milliseconds: 120);
  static const feedbackDuration = Duration(milliseconds: 100);
  static const controlDuration = Duration(milliseconds: 120);
  static const subtitleSurface = ('reading', 'subtitles');
  static const chatSurface = ('reading', 'chat');
  static const overlaySurface = ('overlay', 'bilibili');

  static double _displayRate() {
    final rate = WidgetsBinding
        .instance
        .platformDispatcher
        .views
        .firstOrNull
        ?.display
        .refreshRate;
    return rate != null && rate.isFinite && rate > 0 ? rate : 60;
  }

  final ResponsiveTransitionVsync _vsync;
  late final AnimationController _clock;
  final Map<Object, _SidebarChannel> _surfaces = {};
  late final _SidebarChannel _extent;
  Animation<double> get extent => _extent;
  final Set<Completer<bool>> _settled = {};
  Set<Object> _visible = {};
  Object? _target;
  double _targetExtent = 0;
  bool _initialized = false;
  bool _disposed = false;
  VoidCallback? _releaseBudget;
  int _budgetRevision = 0;

  bool get isAnimating => _clock.isAnimating;
  double get targetExtent => _targetExtent;

  Animation<double> opacityFor(Object surface) => _surfaces.putIfAbsent(
    surface,
    () => _SidebarChannel(_clock, 0, _visible.contains(surface) ? 1 : 0),
  );

  void configure({
    required Object? target,
    required double dockExtent,
    required Set<Object> visibleSurfaces,
    bool immediate = false,
  }) {
    assert(dockExtent.isFinite && dockExtent >= 0);
    final changed =
        !_initialized ||
        target != _target ||
        dockExtent != _targetExtent ||
        !setEquals(_visible, visibleSurfaces);
    if (!changed) {
      if (immediate && isAnimating) finish();
      return;
    }
    final duration = target == null || _target == null
        ? openDuration
        : switchDuration;
    final interrupted = isAnimating;
    final snap = !_initialized || immediate;
    _target = target;
    _targetExtent = dockExtent;
    _visible = Set.of(visibleSurfaces);
    _initialized = true;
    var remaining = 0.0;
    for (final entry in _surfaces.entries) {
      final channel = entry.value;
      final value = channel.value;
      final end = _visible.contains(entry.key) ? 1.0 : 0.0;
      remaining = math.max(remaining, (value - end).abs());
      channel.retarget(value, end);
    }
    final width = extent.value;
    remaining = math.max(
      remaining,
      (width - dockExtent).abs() / math.max(1, math.max(width, dockExtent)),
    );
    _extent.retarget(width, dockExtent);
    // An incoming surface may be mounted only after configure() returns.
    // Its channel still has the full transition, even at an unchanged width.
    final entering = visibleSurfaces.any((id) => !_surfaces.containsKey(id));
    if (entering) remaining = 1;
    if (!interrupted) remaining = 1;
    _clock.stop();
    _clock.value = 0;
    if (snap || remaining <= .000001) {
      _clock.value = 1;
      _releaseInteraction();
    } else {
      _clock.duration = duration * remaining.clamp(0.0, 1.0);
      _vsync.start(alignFirstTick: false);
      _clock.forward();
      final revision = ++_budgetRevision;
      // configure may run while an ancestor is building. Do not notify the
      // resource governor synchronously from that build.
      scheduleMicrotask(() {
        if (!_disposed && revision == _budgetRevision && isAnimating) {
          _releaseBudget ??= UiInteractionBudget.instance.acquire();
        }
      });
    }
  }

  void _statusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _releaseInteraction();
      _completeWaiters(true);
    }
  }

  Future<bool> whenSettled() {
    if (_disposed) return Future.value(false);
    if (!isAnimating) return Future.value(true);
    final done = Completer<bool>();
    _settled.add(done);
    return done.future;
  }

  void _completeWaiters(bool ready) {
    final pending = _settled.toList();
    _settled.clear();
    for (final done in pending) {
      done.complete(ready);
    }
  }

  void _releaseInteraction() {
    _budgetRevision++;
    final release = _releaseBudget;
    _releaseBudget = null;
    if (release != null) scheduleMicrotask(release);
  }

  void finish() {
    _clock.stop();
    _clock.value = 1;
    _releaseInteraction();
    _completeWaiters(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) finish();
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _releaseInteraction();
    _completeWaiters(false);
    _clock.dispose();
  }
}

class _SidebarChannel extends Animation<double> {
  _SidebarChannel(this.clock, this.begin, this.end);
  final AnimationController clock;
  double begin, end;
  void retarget(double from, double to) {
    begin = from;
    end = to;
  }

  @override
  double get value =>
      begin + (end - begin) * Curves.easeOutCubic.transform(clock.value);
  @override
  AnimationStatus get status => value == 0
      ? AnimationStatus.dismissed
      : value == 1
      ? AnimationStatus.completed
      : end < begin
      ? AnimationStatus.reverse
      : AnimationStatus.forward;
  @override
  void addListener(VoidCallback listener) => clock.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => clock.removeListener(listener);
  @override
  void addStatusListener(AnimationStatusListener listener) =>
      clock.addStatusListener(listener);
  @override
  void removeStatusListener(AnimationStatusListener listener) =>
      clock.removeStatusListener(listener);
}
