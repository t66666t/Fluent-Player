import 'package:flutter/foundation.dart';

import 'listener_aware_value_notifier.dart';

/// Derives continuous danmaku motion from the shared playback timeline.
///
/// A play/pause acknowledgement can calibrate that timeline to a newer native
/// sample. Keep the last drawn position at that boundary, then consume the
/// difference at at most 10% of subsequent media-time advancement. There is no
/// separate timer: a paused or buffering timeline cannot move the comments.
/// Explicit seeks and media replacements still use [reset] immediately.
class DanmakuPresentationPosition extends ListenerAwareValueNotifier<Duration> {
  DanmakuPresentationPosition({super.onListenersChanged})
    : super(Duration.zero);

  Duration _lastSourcePosition = Duration.zero;
  int _offsetUs = 0;

  @override
  void addListener(VoidCallback listener) {
    // A newly opened overlay has no previous frame to preserve. In particular,
    // do not carry a paused page's visual offset into a different orientation.
    if (!hasActiveListeners) reset(_lastSourcePosition);
    super.addListener(listener);
  }

  void reset(Duration position) {
    _lastSourcePosition = position;
    _offsetUs = 0;
    value = position;
  }

  void reanchor(Duration position) {
    if (!hasActiveListeners) {
      reset(position);
      return;
    }
    _lastSourcePosition = position;
    _offsetUs = (value - position).inMicroseconds;
  }

  void advance(Duration position, {Duration? duration}) {
    if (!hasActiveListeners) {
      reset(position);
      return;
    }
    final elapsedUs = (position - _lastSourcePosition).inMicroseconds;
    if (elapsedUs < 0) {
      // A first VSync can trail the wall-clock read made at resume. Treat an
      // implicit clock rollback as calibration, preserving the last presented
      // frame and its outstanding offset. Explicit seeks always call reset.
      reanchor(position);
      return;
    }
    _lastSourcePosition = position;
    if (_offsetUs != 0 && elapsedUs > 0) {
      final correctionUs = elapsedUs ~/ 10;
      if (_offsetUs.abs() <= correctionUs) {
        _offsetUs = 0;
      } else {
        _offsetUs += _offsetUs < 0 ? correctionUs : -correctionUs;
      }
    }
    var presented = _offsetUs == 0
        ? position
        : position + Duration(microseconds: _offsetUs);
    if (presented < Duration.zero) presented = Duration.zero;
    if (duration != null && duration > Duration.zero && presented > duration) {
      presented = duration;
    }
    value = presented;
  }
}
