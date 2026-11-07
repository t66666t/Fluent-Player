import 'dart:async';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

/// Owns only the displayed swipe position. Playback is sought by the caller,
/// once, on release. Native ticks cannot move the preview under a still finger.
class SwipeSeekProgress extends ChangeNotifier {
  SwipeSeekProgress({
    required TickerProvider vsync,
    required this.readPosition,
    required this.readDuration,
  }) {
    _return = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 180),
    )..addListener(notifyListeners);
    _return.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _preview = null;
        _returning = false;
        notifyListeners();
      }
    });
  }

  final ValueGetter<Duration> readPosition;
  final ValueGetter<Duration> readDuration;
  late final AnimationController _return;
  Timer? _landingTimeout;
  Duration? _preview;
  bool _waitingForLanding = false;
  bool _returning = false;
  bool _animateLanding = true;
  Duration _landingOrigin = Duration.zero;

  Duration _clamp(Duration position) {
    final max = readDuration().inMicroseconds;
    return Duration(
      microseconds: position.inMicroseconds.clamp(0, max < 0 ? 0 : max),
    );
  }

  Duration get position {
    final preview = _preview;
    if (preview == null) return readPosition();
    if (!_returning) return _clamp(preview);
    final t = Curves.easeOutCubic.transform(_return.value);
    return _clamp(
      Duration(
        microseconds:
            (preview.inMicroseconds +
                    (readPosition().inMicroseconds - preview.inMicroseconds) *
                        t)
                .round(),
      ),
    );
  }

  Duration begin() {
    // A second swipe starts exactly where the first is being displayed, even
    // if its native seek or cancellation animation has not finished yet.
    final start = _clamp(position);
    reset();
    _preview = start;
    notifyListeners();
    return start;
  }

  void update(Duration position) {
    _preview = _clamp(position);
    notifyListeners();
  }

  void finish({required bool commit, required bool animate}) {
    if (_preview == null) return;
    _animateLanding = animate;
    if (commit) {
      _landingOrigin = readPosition();
      _waitingForLanding = true;
      // A failed or interrupted seek must never pin the progress bar forever.
      _landingTimeout = Timer(const Duration(seconds: 3), () {
        _waitingForLanding = false;
        _returnToPlayback(animate: animate);
      });
    } else {
      _returnToPlayback(animate: animate);
    }
  }

  void observePlayback() {
    if (!_waitingForLanding || _preview == null) return;
    final distance = (_preview! - _landingOrigin).inMicroseconds.abs();
    // A sub-second seek must not mistake the old position for its landing.
    final tolerance = (distance ~/ 4).clamp(1000, 500000);
    if ((readPosition() - _preview!).inMicroseconds.abs() <= tolerance) {
      _landingTimeout?.cancel();
      _landingTimeout = null;
      _waitingForLanding = false;
      // Blend the small native landing discrepancy, rather than snapping to
      // the decoder's first position sample.
      _returnToPlayback(animate: _animateLanding);
    }
  }

  void _returnToPlayback({required bool animate}) {
    if (!animate) {
      reset();
      return;
    }
    _returning = true;
    _return.forward(from: 0);
  }

  void reset() {
    if (_preview == null && _landingTimeout == null) return;
    _landingTimeout?.cancel();
    _landingTimeout = null;
    _return.stop();
    _waitingForLanding = false;
    _returning = false;
    _preview = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _landingTimeout?.cancel();
    _return.dispose();
    super.dispose();
  }
}
