import '../models/media_library_continue_policy.dart';

/// One flushed write to library activity. [cycleId] lets stale async work
/// drop itself when media A has already been replaced by media B.
class LibraryWatchFlush {
  const LibraryWatchFlush({
    required this.mediaId,
    required this.cycleId,
    required this.deltaWatchMs,
    required this.enrolled,
    required this.uncomplete,
    required this.unhide,
    required this.completed,
    this.lastPlayedAtMs,
  });

  final String? mediaId;
  final int cycleId;
  final int deltaWatchMs;
  final bool enrolled;
  final bool uncomplete;
  final bool unhide;
  final bool completed;
  final int? lastPlayedAtMs;

  bool get hasActivityWrite =>
      deltaWatchMs > 0 ||
      uncomplete ||
      unhide ||
      completed ||
      lastPlayedAtMs != null;
}

/// Counts real watching toward continue-learning enrollment.
///
/// Time comes from a monotonic clock while the playhead actually advances.
/// Playback rate does not multiply the count: 10s at 2x is still 10s.
class LibraryWatchMeter {
  LibraryWatchMeter({int Function()? clockMs})
    : _clockMs = clockMs ?? _systemClockMs;

  static const int maxAcceptedDeltaMs = 6000;

  final int Function() _clockMs;

  static int _systemClockMs() => DateTime.now().millisecondsSinceEpoch;

  String? _mediaId;
  int _cycleId = 0;
  bool _userInitiated = false;
  bool _hidden = false;
  bool _completedAtStart = false;
  bool _enrolled = false;
  bool _uncompleteEmitted = false;
  bool _unhideEmitted = false;
  bool _blockedUnhide = false;
  bool _completedThisCycle = false;
  int _cycleWatchMs = 0;
  int _uncommittedDeltaMs = 0;
  int? _durationMs;
  int? _lastNowMs;
  int? _lastPositionMs;
  bool _playing = false;
  bool _buffering = false;
  bool _seeking = false;
  bool _missingSource = false;
  bool _startedPlaying = false;

  ContinueWatchPolicy _policy = ContinueWatchPolicy.defaults;

  String? get mediaId => _mediaId;
  int get cycleId => _cycleId;
  int get cycleWatchMs => _cycleWatchMs;
  bool get isEnrolled => _enrolled;
  bool get completedThisCycle => _completedThisCycle;
  bool get hasOpenCycle => _mediaId != null && !_completedThisCycle;
  /// True once the playhead was actually rolling (not loading/paused).
  bool get hasStartedPlaying => _startedPlaying;

  void setPolicy(ContinueWatchPolicy policy) {
    _policy = policy;
    _refreshEnrollment();
  }

  static int enrollmentThresholdMs(int? durationMs) {
    return ContinueWatchPolicy.defaults.shorterThresholdMs(durationMs);
  }

  void startCycle({
    required String mediaId,
    required bool userInitiated,
    required bool hidden,
    required bool completed,
    int? durationMs,
    int? nowMs,
  }) {
    _mediaId = mediaId;
    _cycleId += 1;
    _userInitiated = userInitiated;
    _hidden = hidden;
    _completedAtStart = completed;
    _enrolled = false;
    _uncompleteEmitted = false;
    _unhideEmitted = false;
    _blockedUnhide = false;
    _completedThisCycle = false;
    _cycleWatchMs = 0;
    _uncommittedDeltaMs = 0;
    _durationMs = durationMs;
    _lastNowMs = nowMs ?? _clockMs();
    _lastPositionMs = null;
    _playing = false;
    _buffering = false;
    _seeking = false;
    _missingSource = false;
    _startedPlaying = false;
  }

  /// Controller rebuilds keep the logical watch cycle.
  void retainCycle({int? durationMs, int? nowMs}) {
    if (durationMs != null && durationMs > 0) {
      _durationMs = durationMs;
    }
    _lastNowMs = nowMs ?? _clockMs();
    _lastPositionMs = null;
  }

  void noteHidden() {
    _hidden = true;
    _blockedUnhide = true;
  }

  void setTransport({
    required bool playing,
    required bool buffering,
    required bool seeking,
    required bool missingSource,
  }) {
    _playing = playing;
    _buffering = buffering;
    _seeking = seeking;
    _missingSource = missingSource;
    if (!_canCount) {
      _lastPositionMs = null;
    } else {
      // Mini-card / notification / skip-next all share this transport. History
      // follows the session, not whichever page is visible.
      _startedPlaying = true;
    }
  }

  void beginSeek() {
    _seeking = true;
    _lastPositionMs = null;
  }

  void endSeek({int? positionMs, int? nowMs}) {
    _seeking = false;
    _lastPositionMs = positionMs;
    _lastNowMs = nowMs ?? _clockMs();
  }

  /// Returns true when this sample crossed the enrollment threshold.
  bool sample({
    required String mediaId,
    required int cycleId,
    required int positionMs,
    int? nowMs,
    int? durationMs,
  }) {
    if (mediaId != _mediaId || cycleId != _cycleId) return false;
    if (durationMs != null && durationMs > 0) {
      _durationMs = durationMs;
    }
    final now = nowMs ?? _clockMs();
    final wasEnrolled = _enrolled;
    if (!_canCount) {
      _lastNowMs = now;
      _lastPositionMs = positionMs;
      return false;
    }
    final lastPos = _lastPositionMs;
    final lastNow = _lastNowMs;
    _lastPositionMs = positionMs;
    _lastNowMs = now;
    if (lastPos == null || lastNow == null) return false;
    if (positionMs <= lastPos) return false;
    final dt = now - lastNow;
    if (dt <= 0 || dt > maxAcceptedDeltaMs) return false;
    _cycleWatchMs += dt;
    _uncommittedDeltaMs += dt;
    _refreshEnrollment();
    return _enrolled && !wasEnrolled;
  }

  LibraryWatchFlush flush({int? nowMs}) {
    final now = nowMs ?? _clockMs();
    _refreshEnrollment();
    final delta = _uncommittedDeltaMs;
    _uncommittedDeltaMs = 0;
    return _buildFlush(
      now: now,
      deltaWatchMs: delta,
      completed: false,
    );
  }

  LibraryWatchFlush onConfirmedComplete({int? nowMs}) {
    final now = nowMs ?? _clockMs();
    _refreshEnrollment();
    _completedThisCycle = true;
    final delta = _uncommittedDeltaMs;
    _uncommittedDeltaMs = 0;
    return _buildFlush(
      now: now,
      deltaWatchMs: delta,
      completed: true,
    );
  }

  void reset() {
    _mediaId = null;
    _cycleId = 0;
    _completedThisCycle = false;
    _uncommittedDeltaMs = 0;
    _cycleWatchMs = 0;
    _lastNowMs = null;
    _lastPositionMs = null;
  }

  bool get _canCount =>
      _mediaId != null &&
      !_completedThisCycle &&
      _playing &&
      !_buffering &&
      !_seeking &&
      !_missingSource;

  void _refreshEnrollment() {
    if (_enrolled) return;
    if (_policy.hasReachedWatchGate(_cycleWatchMs, _durationMs)) {
      _enrolled = true;
    }
  }

  LibraryWatchFlush _buildFlush({
    required int now,
    required int deltaWatchMs,
    required bool completed,
  }) {
    final uncomplete =
        _enrolled && _completedAtStart && !_uncompleteEmitted && !completed;
    final unhide =
        _enrolled &&
        _userInitiated &&
        _hidden &&
        !_blockedUnhide &&
        !_unhideEmitted &&
        !completed;
    if (uncomplete) _uncompleteEmitted = true;
    if (unhide) _unhideEmitted = true;
    // History is YouTube/Plex "recently played": stamp once the item actually
    // started playing from any surface. Continue-learning still uses
    // [enrolled] (≈30s or 20%). Completing also counts with 0 extra delta.
    final stampHistory =
        deltaWatchMs > 0 || _enrolled || completed || _startedPlaying;
    return LibraryWatchFlush(
      mediaId: _mediaId,
      cycleId: _cycleId,
      deltaWatchMs: deltaWatchMs,
      enrolled: _enrolled,
      uncomplete: uncomplete,
      unhide: unhide,
      completed: completed,
      lastPlayedAtMs: stampHistory ? now : null,
    );
  }
}
