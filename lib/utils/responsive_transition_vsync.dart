import 'package:flutter/scheduler.dart';

/// Keeps the owner's ticker lifecycle while discounting a cold initial frame.
/// After that first frame, animation time follows vsync without a frame cap.
/// This does not hide sustained slow frames or repeatedly extend transitions.
class ResponsiveTransitionVsync implements TickerProvider {
  ResponsiveTransitionVsync(
    this.delegate,
    this.framePeriod, {
    this.protectFirstAdvance = true,
  });

  final bool protectFirstAdvance;
  final TickerProvider delegate;
  final Duration framePeriod;
  bool _alignFirstTick = false;
  bool _awaitFirstAdvance = false;
  Duration? _origin;
  Duration? _previousElapsed;
  Duration _coldFrameOffset = Duration.zero;

  void start({required bool alignFirstTick}) {
    _alignFirstTick = alignFirstTick;
    _awaitFirstAdvance = true;
    _origin = null;
    _previousElapsed = null;
    _coldFrameOffset = Duration.zero;
  }

  @override
  Ticker createTicker(TickerCallback onTick) => delegate.createTicker((
    elapsed,
  ) {
    // A gesture can restart the controller directly, without didPush/pop.
    // Its new ticker starts at zero and must not inherit a cold offset.
    if (_previousElapsed != null && elapsed < _previousElapsed!) {
      _origin = null;
      _coldFrameOffset = Duration.zero;
      _awaitFirstAdvance = true;
    }
    _previousElapsed = elapsed;
    var clock = elapsed;
    if (_alignFirstTick) {
      _origin ??= elapsed;
      clock -= _origin!;
    }
    if (_awaitFirstAdvance && (!protectFirstAdvance || clock > Duration.zero)) {
      _awaitFirstAdvance = false;
      // Charge a slow cold frame once, before presentation starts, without
      // a forced wait at zero or a jump over most of the visible fade.
      // Later frames keep normal wall-clock timing; no repeating slowdown.
      if (clock > framePeriod * 2) {
        _coldFrameOffset = clock - framePeriod;
      }
    }
    onTick(clock - _coldFrameOffset);
  });
}
