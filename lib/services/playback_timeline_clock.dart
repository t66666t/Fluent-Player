typedef MonotonicMicroseconds = int Function();

/// A single, monotonic media timeline for frame-driven UI.
///
/// By default, playback-rate changes preserve the exact current media position
/// and native samples adjust its slope without moving it. Network audio can
/// opt into bounded, native-led interpolation with `maxNativeExtrapolation` in
/// [reset], so a stalled decoder cannot keep lyrics advancing just because the
/// transport still reports "playing".
class PlaybackTimelineClock {
  PlaybackTimelineClock({MonotonicMicroseconds? nowMicroseconds})
    : _nowMicroseconds = nowMicroseconds ?? _defaultNowMicroseconds;

  static final Stopwatch _stopwatch = Stopwatch()..start();

  static int _defaultNowMicroseconds() => _stopwatch.elapsedMicroseconds;

  final MonotonicMicroseconds _nowMicroseconds;
  Duration _anchorPosition = Duration.zero;
  int _anchorTimeUs = 0;
  Duration _duration = Duration.zero;
  double _rate = 1.0;
  double _driftCorrection = 0.0;
  bool _running = false;
  bool _initialized = false;
  bool _frameDriven = false;
  bool _wallClockUntilNextFrame = false;
  int? _lastFrameTimestampUs;
  int _lastFrameIntervalUs = 16667;
  double _frameRemainderUs = 0;
  int _ignoredNativeSamples = 0;
  int _driftConfirmationSamples = 0;
  int _lastDriftSign = 0;
  Duration? _maxNativeExtrapolation;
  Duration _nativePosition = Duration.zero;
  bool _nativeProgressConfirmed = false;
  bool _nativeExtrapolationExhausted = false;

  bool get isInitialized => _initialized;
  bool get isRunning => _running;
  double get rate => _rate;
  double get effectiveRate => _rate * (1 + _driftCorrection);

  Duration get position {
    // Once the display pipeline starts sampling this clock, the last sampled
    // position is the only position which has actually been presented. Do not
    // mix callback execution time into it: scheduler jitter would otherwise
    // become visible as horizontal danmaku jitter.
    if (_frameDriven) return _limitToNative(_clamp(_anchorPosition));
    if (!_initialized || !_running) {
      return _limitToNative(_clamp(_anchorPosition));
    }
    final elapsedUs = (_nowMicroseconds() - _anchorTimeUs).clamp(0, 1 << 62);
    return _limitToNative(
      _clamp(
        _anchorPosition +
            Duration(microseconds: (elapsedUs * effectiveRate).round()),
      ),
    );
  }

  /// Advances the media clock using Flutter's VSync timestamp.
  ///
  /// Consecutive frame timestamps describe presentation time, unlike the wall
  /// time at which a Dart callback happened to execute. A missed frame advances
  /// by the complete missed interval, so the next presented position remains
  /// time-linear and no delayed catch-up is introduced.
  Duration sampleFrame(Duration frameTimestamp) {
    final timestampUs = frameTimestamp.inMicroseconds;
    if (!_frameDriven && _wallClockUntilNextFrame) {
      // There was no visible consumer during this interval. Enter the first
      // new frame at the continuously running wall clock, rather than adding
      // the entire off-page interval at the latest rate. Ordinary resets keep
      // their existing first-frame semantics.
      _anchorPosition = position;
      _wallClockUntilNextFrame = false;
    }
    _frameDriven = true;
    // This timestamp is used only if presentation consumers subsequently
    // leave. Retaining it avoids losing the fraction of a frame between the
    // last presentation callback and that removal; visible motion continues
    // to use VSync timestamps exclusively.
    _anchorTimeUs = _nowMicroseconds();
    if (!_initialized) {
      _initialized = true;
    }

    final previousTimestampUs = _lastFrameTimestampUs;
    _lastFrameTimestampUs = timestampUs;
    if (!_running || previousTimestampUs == null) {
      return _limitToNative(_clamp(_anchorPosition));
    }

    final elapsedUs = timestampUs - previousTimestampUs;
    if (elapsedUs <= 0) return _limitToNative(_clamp(_anchorPosition));
    _lastFrameIntervalUs = elapsedUs.clamp(5000, 50000);
    // Carry sub-microsecond media time instead of rounding every frame
    // independently. Otherwise fractional rates accumulate refresh-dependent
    // drift over long sessions, especially on high-refresh displays.
    final exactAdvanceUs = elapsedUs * effectiveRate + _frameRemainderUs;
    final advanceUs = exactAdvanceUs.round();
    final candidate = _anchorPosition + Duration(microseconds: advanceUs);
    _anchorPosition = _limitToNative(_clamp(candidate));
    _frameRemainderUs = _anchorPosition == candidate
        ? exactAdvanceUs - advanceUs
        : 0;
    return _anchorPosition;
  }

  /// Keeps media time running without requesting display frames.
  ///
  /// Called only when the last presentation consumer leaves. Preserve the
  /// native-led stall allowance, transport state and current rate; resetting
  /// the clock here would incorrectly treat a stalled podcast as audible.
  void useMonotonicTime() {
    if (_frameDriven) {
      _anchorPosition = position;
      _frameDriven = false;
      _lastFrameTimestampUs = null;
      _frameRemainderUs = 0;
    }
    _wallClockUntilNextFrame = true;
  }

  /// In the default mode, observes native position without moving the presented
  /// position directly. Small, sustained drift is removed by changing the
  /// slope by at most 0.5%; coarse video-frame samples and transient samples
  /// around play/rate transitions therefore cannot make overlays jump. In
  /// native-led mode, authoritative samples also re-anchor after a stall.
  void observeNativePosition(Duration nativePosition) {
    if (_maxNativeExtrapolation != null) {
      _observeAuthoritativeNativePosition(_clamp(nativePosition));
      return;
    }
    if (!_initialized || !_running || !_frameDriven) return;
    if (_ignoredNativeSamples > 0) {
      _ignoredNativeSamples--;
      return;
    }

    final errorUs =
        nativePosition.inMicroseconds - _anchorPosition.inMicroseconds;
    final deadBandUs = _maxInt(_lastFrameIntervalUs, 8333);
    final absoluteErrorUs = errorUs.abs();
    if (absoluteErrorUs <= deadBandUs) {
      _driftConfirmationSamples = 0;
      _lastDriftSign = 0;
      _driftCorrection *= 0.75;
      if (_driftCorrection.abs() < 0.00001) _driftCorrection = 0;
      return;
    }

    // A large mismatch is a seek/discontinuity candidate. Callers reset the
    // clock only after the seek itself is confirmed; treating it as drift here
    // would create a visible speed surge.
    if (absoluteErrorUs > 100000) {
      _driftConfirmationSamples = 0;
      _lastDriftSign = 0;
      return;
    }

    final sign = errorUs.sign.toInt();
    if (sign != _lastDriftSign) {
      _lastDriftSign = sign;
      _driftConfirmationSamples = 1;
      return;
    }
    _driftConfirmationSamples++;
    if (_driftConfirmationSamples < 3) return;

    final nominalRate = _rate <= 0 ? 1.0 : _rate;
    final targetRelativeCorrection = (errorUs / (2000000 * nominalRate)).clamp(
      -0.005,
      0.005,
    );
    _driftCorrection =
        _driftCorrection * 0.75 + targetRelativeCorrection * 0.25;
  }

  void reset(
    Duration position, {
    required bool running,
    required double rate,
    Duration? duration,
    Duration? maxNativeExtrapolation,
  }) {
    if (duration != null) _duration = duration;
    _rate = _validRate(rate);
    _driftCorrection = 0;
    _anchorPosition = _clamp(position);
    _maxNativeExtrapolation = maxNativeExtrapolation;
    _nativePosition = _anchorPosition;
    _nativeProgressConfirmed = false;
    _nativeExtrapolationExhausted = false;
    _anchorTimeUs = _nowMicroseconds();
    _running = running;
    _initialized = true;
    _frameDriven = false;
    _wallClockUntilNextFrame = false;
    _lastFrameTimestampUs = null;
    _lastFrameIntervalUs = 16667;
    _frameRemainderUs = 0;
    _ignoredNativeSamples = 4;
    _driftConfirmationSamples = 0;
    _lastDriftSign = 0;
  }

  void setRate(double rate) {
    final nextRate = _validRate(rate);
    if ((_rate - nextRate).abs() < 0.0001) return;
    final current = position;
    _anchorPosition = current;
    _anchorTimeUs = _nowMicroseconds();
    _rate = nextRate;
    _driftCorrection = 0;
    _ignoredNativeSamples = 4;
    _driftConfirmationSamples = 0;
    _lastDriftSign = 0;
    _initialized = true;
  }

  void setRunning(bool running, {Duration? position}) {
    if (_running == running && position == null) return;
    _anchorPosition = _clamp(
      position ??
          (_maxNativeExtrapolation != null ? _nativePosition : this.position),
    );
    if (_maxNativeExtrapolation != null) {
      // Neither a play intent nor bufferingEnd proves that audio is audible.
      // Resume only after a new, advancing native sample arrives.
      _nativePosition = _anchorPosition;
      _nativeProgressConfirmed = false;
      _nativeExtrapolationExhausted = false;
    }
    _anchorTimeUs = _nowMicroseconds();
    _running = running;
    _driftCorrection = 0;
    _ignoredNativeSamples = running ? 4 : 0;
    _driftConfirmationSamples = 0;
    _lastDriftSign = 0;
    _initialized = true;
    // The next VSync becomes the new presentation-time baseline. This keeps a
    // paused interval out of the first frame after resume without moving the
    // last position that was actually drawn.
    _lastFrameTimestampUs = null;
    _frameRemainderUs = 0;
  }

  void setDuration(Duration duration) {
    _duration = duration < Duration.zero ? Duration.zero : duration;
    final previousPosition = _anchorPosition;
    _anchorPosition = _clamp(_anchorPosition);
    if (_anchorPosition != previousPosition) _frameRemainderUs = 0;
    _nativePosition = _clamp(_nativePosition);
  }

  void _observeAuthoritativeNativePosition(Duration nativePosition) {
    if (!_initialized) return;
    final previousNativePosition = _nativePosition;
    final advanced = nativePosition > previousNativePosition;
    final discontinuity = nativePosition < previousNativePosition;
    final wasStalled =
        !_nativeProgressConfirmed || _nativeExtrapolationExhausted;
    _nativePosition = nativePosition;

    // Duplicate samples (including repeated zeroes at startup) never renew
    // the interpolation allowance. A missing buffering event is thus bounded.
    if (!advanced && !discontinuity && _running) return;
    if (!_running || discontinuity) {
      _nativeProgressConfirmed = false;
    } else if (advanced) {
      _nativeProgressConfirmed = true;
    }

    final errorUs = (nativePosition - _anchorPosition).inMicroseconds.abs();
    if (!_running || discontinuity || wasStalled || errorUs > 100000) {
      // Loading time is never part of media time. In particular, resume at
      // time-pos, not at the last extrapolated frame from before the stall.
      _anchorPosition = nativePosition;
      _anchorTimeUs = _nowMicroseconds();
      _lastFrameTimestampUs = null;
      _frameRemainderUs = 0;
      _driftCorrection = 0;
    }
    _nativeExtrapolationExhausted = false;
  }

  Duration _limitToNative(Duration value) {
    final allowance = _maxNativeExtrapolation;
    if (allowance == null) return value;
    if (!_nativeProgressConfirmed || !_running) return _nativePosition;
    final ceiling = _clamp(
      _nativePosition +
          Duration(microseconds: (allowance.inMicroseconds * _rate).round()),
    );
    if (value >= ceiling) {
      _nativeExtrapolationExhausted = true;
      return ceiling;
    }
    return value;
  }

  double _validRate(double value) {
    return value.isFinite && value > 0 ? value : 1.0;
  }

  Duration _clamp(Duration value) {
    if (value < Duration.zero) return Duration.zero;
    if (_duration > Duration.zero && value > _duration) return _duration;
    return value;
  }
}

int _maxInt(int left, int right) => left > right ? left : right;
