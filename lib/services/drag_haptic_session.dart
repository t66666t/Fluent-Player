import 'dart:async';

import 'package:flutter/gestures.dart';

import 'app_haptics.dart';
import 'settings_service.dart';

/// Feedback for one user drag, independent of playback clocks and rebuilds.
/// Values are normalized for seeking and logical pixels for sidebar resizing.
class DragHapticSession {
  DragHapticSession({
    this.step = 0.02,
    this.minimumInterval = const Duration(milliseconds: 80),
    Duration Function()? elapsed,
  }) : assert(step > 0),
       _elapsed = elapsed ?? _clock();

  static Duration Function() _clock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final double step;
  final Duration minimumInterval;
  final Duration Function() _elapsed;

  bool _active = false;
  bool _canceling = false;
  bool _moved = false;
  bool _changed = false;
  double _value = 0;
  double _tickValue = 0;
  Duration _lastFeedback = Duration.zero;
  int? _boundary;
  int? _pointer;
  Offset? _origin;

  void pointerDown(PointerDownEvent event) {
    if (_pointer != null) return;
    reset();
    _pointer = event.pointer;
    _origin = event.position;
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    if ((event.position - _origin!).distance >
        computeHitSlop(event.kind, null)) {
      _moved = true;
    }
  }

  void begin(double value, {bool dragging = false, int? boundary}) {
    if (_active || !value.isFinite) return;
    _active = true;
    _canceling = false;
    _changed = false;
    _moved = _moved || dragging;
    _value = _tickValue = value;
    _boundary = boundary;
    _lastFeedback = _elapsed();
    unawaited(AppHaptics.dragStarted(SettingsService()));
  }

  void update(double value, {bool checkpoint = false, int? boundary}) {
    if (!_active || !value.isFinite) return;
    _changed = _changed || (value - _value).abs() > 0.000001;
    _value = value;
    if (_canceling) {
      _tickValue = value;
      return;
    }
    final reachedBoundary = boundary != null && boundary != _boundary;
    _boundary = boundary;
    if (reachedBoundary) {
      _tickValue = value;
      _lastFeedback = _elapsed();
      unawaited(AppHaptics.resizeBoundaryReached(SettingsService()));
      return;
    }
    if (!_moved ||
        (!checkpoint && (value - _tickValue).abs() + 0.000001 < step) ||
        _elapsed() - _lastFeedback < minimumInterval) {
      return;
    }
    _tickValue = value;
    _lastFeedback = _elapsed();
    unawaited(AppHaptics.dragTick(SettingsService()));
  }

  void setCanceling(bool canceling) {
    if (!_active || _canceling == canceling) return;
    _canceling = canceling;
    _tickValue = _value;
    _lastFeedback = _elapsed();
    unawaited(
      canceling
          ? AppHaptics.cancelAreaEntered(SettingsService())
          : AppHaptics.selectionClick(SettingsService()),
    );
  }

  void end({bool committed = true}) {
    if (_active && committed && !_canceling && _moved && _changed) {
      // Releasing at a just-announced hard stop needs only one confirmation.
      if (_boundary == null || _elapsed() - _lastFeedback >= minimumInterval) {
        unawaited(AppHaptics.dragCommitted(SettingsService()));
      }
    }
    reset();
  }

  void reset() {
    _active = _canceling = _moved = _changed = false;
    _pointer = null;
    _origin = null;
    _boundary = null;
  }
}
