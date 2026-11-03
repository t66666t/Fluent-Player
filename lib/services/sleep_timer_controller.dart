import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SleepTimerMode {
  off,
  afterDuration,
  afterPlaybackDuration,
  endOfCurrentItem,
  endOfQueue,
  afterItemCount,
  atTime,
}

/// Page-independent sleep timer driven by the global playback session.
class SleepTimerController extends ChangeNotifier {
  SleepTimerController({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String _modeKey = 'sleepTimer.mode';
  static const String _deadlineKey = 'sleepTimer.deadlineMs';
  static const String _playbackRemainingKey = 'sleepTimer.playbackRemainingMs';
  static const String _remainingItemsKey = 'sleepTimer.remainingItemCount';
  static const String _scheduledItemsKey = 'sleepTimer.scheduledItemCount';
  static const String _awaitingCurrentKey = 'sleepTimer.awaitingCurrentItemEnd';
  static const String _countOnlyKey = 'sleepTimer.countOnlyWhilePlaying';
  static const String _customMinutesKey = 'sleepTimer.customMinutes';
  static const String _customItemCountKey = 'sleepTimer.customItemCount';
  static const int minCustomItemCount = 1;
  static const int maxCustomItemCount = 999;
  static const Duration _heartbeatInterval = Duration(milliseconds: 500);
  static const Duration _playbackPersistInterval = Duration(seconds: 5);

  final DateTime Function() _now;
  Timer? _heartbeat;
  Listenable? _playbackListenable;
  bool Function()? _isPlaybackRunning;
  Future<void> Function()? _onExpired;
  DateTime _lastSettledAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPlaybackPersistAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wasPlaybackRunning = false;
  int _lastNotifiedSecond = -1;
  Future<void> _persistenceTail = Future<void>.value();

  SleepTimerMode _mode = SleepTimerMode.off;
  DateTime? _deadline;
  Duration _playbackRemaining = Duration.zero;
  int _remainingItemCount = 0;
  int _scheduledItemCount = 0;
  bool _awaitingCurrentItemEnd = false;
  bool _countOnlyWhilePlaying = false;
  int _customMinutes = 30;
  int _customItemCount = 3;

  SleepTimerMode get mode => _mode;
  bool get isActive => _mode != SleepTimerMode.off;
  DateTime? get deadline => _deadline;
  int get remainingItemCount => _remainingItemCount;
  int get scheduledItemCount => _scheduledItemCount;
  bool get awaitingCurrentItemEnd => _awaitingCurrentItemEnd;
  bool get countOnlyWhilePlaying => _countOnlyWhilePlaying;
  Future<void> flushPreferencesForTrial() => _persistenceTail;
  Future<void> reloadPreferencesForTrial() async {
    await _persistenceTail;
    final prefs = await SharedPreferences.getInstance();
    _countOnlyWhilePlaying = prefs.getBool(_countOnlyKey) ?? false;
    _customMinutes = (prefs.getInt(_customMinutesKey) ?? 30).clamp(1, 1440);
    _customItemCount = (prefs.getInt(_customItemCountKey) ?? 3).clamp(
      minCustomItemCount,
      maxCustomItemCount,
    );
    notifyListeners();
  }

  int get customMinutes => _customMinutes;
  int get customItemCount => _customItemCount;

  bool get tracksItemCompletion =>
      _mode == SleepTimerMode.endOfCurrentItem ||
      _mode == SleepTimerMode.endOfQueue ||
      _mode == SleepTimerMode.afterItemCount;

  Duration get remaining {
    if (!isActive) return Duration.zero;
    if (_mode == SleepTimerMode.afterDuration ||
        _mode == SleepTimerMode.atTime) {
      final value = _deadline?.difference(_now()) ?? Duration.zero;
      return value.isNegative ? Duration.zero : value;
    }
    if (_mode == SleepTimerMode.afterPlaybackDuration) {
      var value = _playbackRemaining;
      if (_wasPlaybackRunning) value -= _now().difference(_lastSettledAt);
      return value.isNegative ? Duration.zero : value;
    }
    return Duration.zero;
  }

  String get statusText {
    switch (_mode) {
      case SleepTimerMode.off:
        return '未设置';
      case SleepTimerMode.afterDuration:
        return '将在 ${_formatDuration(remaining)} 后暂停';
      case SleepTimerMode.afterPlaybackDuration:
        return '再播放 ${_formatDuration(remaining)} 后暂停';
      case SleepTimerMode.endOfCurrentItem:
        return '当前内容结束后暂停';
      case SleepTimerMode.endOfQueue:
        return '当前队列结束后暂停';
      case SleepTimerMode.afterItemCount:
        if (_awaitingCurrentItemEnd) {
          return '当前结束后再播放 $_remainingItemCount 个';
        }
        return '再播放 $_remainingItemCount 个内容后暂停';
      case SleepTimerMode.atTime:
        final target = _deadline;
        if (target == null) return '未设置';
        return '${_twoDigits(target.hour)}:${_twoDigits(target.minute)} 暂停';
    }
  }

  Future<void> initialize({
    required Listenable playbackListenable,
    required bool Function() isPlaybackRunning,
    required Future<void> Function() onExpired,
  }) async {
    _playbackListenable?.removeListener(_handlePlaybackStateChanged);
    _playbackListenable = playbackListenable;
    _isPlaybackRunning = isPlaybackRunning;
    _onExpired = onExpired;
    _wasPlaybackRunning = isPlaybackRunning();
    _lastSettledAt = _now();
    playbackListenable.addListener(_handlePlaybackStateChanged);
    // A previous session can leave its preference write unfinished when the
    // preferences store is replaced. New commands must not wait on that chain.
    _persistenceTail = Future<void>.value();

    final preferences = await SharedPreferences.getInstance();
    _countOnlyWhilePlaying = preferences.getBool(_countOnlyKey) ?? false;
    final storedMinutes = preferences.getInt(_customMinutesKey);
    if (storedMinutes != null && storedMinutes >= 1 && storedMinutes <= 1440) {
      _customMinutes = storedMinutes;
    }
    final storedItemCount = preferences.getInt(_customItemCountKey);
    if (storedItemCount != null &&
        storedItemCount >= minCustomItemCount &&
        storedItemCount <= maxCustomItemCount) {
      _customItemCount = storedItemCount;
    }

    final storedMode = preferences.getInt(_modeKey);
    if (storedMode != null &&
        storedMode >= 0 &&
        storedMode < SleepTimerMode.values.length) {
      final restoredMode = SleepTimerMode.values[storedMode];
      final restored = _restoreActiveTimer(preferences, restoredMode);
      if (!restored) await _clearActivePersistence(preferences);
    }
    notifyListeners();
  }

  bool _restoreActiveTimer(
    SharedPreferences preferences,
    SleepTimerMode restoredMode,
  ) {
    switch (restoredMode) {
      case SleepTimerMode.off:
        return false;
      case SleepTimerMode.afterDuration:
      case SleepTimerMode.atTime:
        final storedDeadlineMs = preferences.getInt(_deadlineKey);
        if (storedDeadlineMs == null) return false;
        final restoredDeadline = DateTime.fromMillisecondsSinceEpoch(
          storedDeadlineMs,
        );
        if (!restoredDeadline.isAfter(_now())) return false;
        _mode = restoredMode;
        _deadline = restoredDeadline;
        _ensureHeartbeat();
        return true;
      case SleepTimerMode.afterPlaybackDuration:
        final remainingMs = preferences.getInt(_playbackRemainingKey) ?? 0;
        if (remainingMs <= 0) return false;
        _mode = restoredMode;
        _playbackRemaining = Duration(milliseconds: remainingMs);
        _lastSettledAt = _now();
        _wasPlaybackRunning = _isPlaybackRunning?.call() ?? false;
        _ensureHeartbeat();
        return true;
      case SleepTimerMode.endOfCurrentItem:
      case SleepTimerMode.endOfQueue:
        _mode = restoredMode;
        return true;
      case SleepTimerMode.afterItemCount:
        final remaining = preferences.getInt(_remainingItemsKey) ?? 0;
        if (remaining <= 0) return false;
        _mode = restoredMode;
        _remainingItemCount = remaining;
        _scheduledItemCount =
            preferences.getInt(_scheduledItemsKey) ?? remaining;
        _awaitingCurrentItemEnd =
            preferences.getBool(_awaitingCurrentKey) ?? false;
        return true;
    }
  }

  Future<void> scheduleAfter(
    Duration duration, {
    bool countOnlyWhilePlaying = false,
  }) async {
    if (duration <= Duration.zero) return;
    _settlePlaybackTime();
    _mode = countOnlyWhilePlaying
        ? SleepTimerMode.afterPlaybackDuration
        : SleepTimerMode.afterDuration;
    _deadline = countOnlyWhilePlaying ? null : _now().add(duration);
    _playbackRemaining = countOnlyWhilePlaying ? duration : Duration.zero;
    _remainingItemCount = 0;
    _scheduledItemCount = 0;
    _awaitingCurrentItemEnd = false;
    _lastSettledAt = _now();
    _wasPlaybackRunning = _isPlaybackRunning?.call() ?? false;
    _lastNotifiedSecond = -1;
    _ensureHeartbeat();
    await _persist();
    notifyListeners();
  }

  /// Saves the countdown switch and, when a duration timer is running,
  /// converts that timer in place without changing the time left.
  Future<void> setCountOnlyWhilePlaying(bool value) async {
    _countOnlyWhilePlaying = value;
    _settlePlaybackTime();
    if (_mode == SleepTimerMode.afterDuration && value) {
      final left = remaining;
      _mode = SleepTimerMode.afterPlaybackDuration;
      _deadline = null;
      _playbackRemaining = left;
      _lastSettledAt = _now();
      _wasPlaybackRunning = _isPlaybackRunning?.call() ?? false;
      _ensureHeartbeat();
    } else if (_mode == SleepTimerMode.afterPlaybackDuration && !value) {
      final left = remaining;
      _mode = SleepTimerMode.afterDuration;
      _playbackRemaining = Duration.zero;
      _deadline = _now().add(left);
      _ensureHeartbeat();
    }
    _lastNotifiedSecond = -1;
    notifyListeners();
    await Future<void>.delayed(Duration.zero);
    await _persist();
  }

  Future<void> setCustomMinutes(int minutes) async {
    final next = minutes.clamp(1, 1440);
    if (_customMinutes == next) return;
    _customMinutes = next;
    await _persistPreferences();
  }

  Future<void> setCustomItemCount(int count) async {
    final next = count.clamp(minCustomItemCount, maxCustomItemCount);
    if (_customItemCount == next) return;
    _customItemCount = next;
    await _persistPreferences();
  }

  Future<void> scheduleAt(DateTime time) async {
    if (!time.isAfter(_now())) return;
    _mode = SleepTimerMode.atTime;
    _deadline = time;
    _playbackRemaining = Duration.zero;
    _remainingItemCount = 0;
    _scheduledItemCount = 0;
    _awaitingCurrentItemEnd = false;
    _lastNotifiedSecond = -1;
    _ensureHeartbeat();
    await _persist();
    notifyListeners();
  }

  Future<void> scheduleAtEndOfCurrentItem() =>
      _scheduleCompletionMode(SleepTimerMode.endOfCurrentItem);

  Future<void> scheduleAtEndOfQueue() =>
      _scheduleCompletionMode(SleepTimerMode.endOfQueue);

  Future<void> scheduleAfterItems(int count) async {
    if (count <= 0) return;
    await _scheduleCompletionMode(SleepTimerMode.afterItemCount, count: count);
  }

  Future<void> _scheduleCompletionMode(
    SleepTimerMode mode, {
    int count = 0,
  }) async {
    _mode = mode;
    _deadline = null;
    _playbackRemaining = Duration.zero;
    _remainingItemCount = count;
    _scheduledItemCount = count;
    _awaitingCurrentItemEnd = mode == SleepTimerMode.afterItemCount;
    _lastNotifiedSecond = -1;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _persist();
    notifyListeners();
  }

  Future<void> extend(Duration duration) async {
    if (!isActive || duration <= Duration.zero) return;
    _settlePlaybackTime();
    if (_mode == SleepTimerMode.afterDuration ||
        _mode == SleepTimerMode.atTime) {
      _deadline = (_deadline ?? _now()).add(duration);
    } else if (_mode == SleepTimerMode.afterPlaybackDuration) {
      _playbackRemaining += duration;
      _lastSettledAt = _now();
    } else {
      return;
    }
    _lastNotifiedSecond = -1;
    await _persist();
    notifyListeners();
  }

  Future<void> cancel() async {
    _clearInMemory();
    await _persist();
    notifyListeners();
  }

  /// Called before the normal auto-play-on-completion decision, and before a
  /// manual skip actually opens another item.
  bool consumeItemCompletion({required bool hasNextItem}) {
    if (!tracksItemCompletion) return false;
    var shouldStop = false;
    switch (_mode) {
      case SleepTimerMode.endOfCurrentItem:
        shouldStop = true;
      case SleepTimerMode.endOfQueue:
        shouldStop = !hasNextItem;
      case SleepTimerMode.afterItemCount:
        if (_awaitingCurrentItemEnd) {
          _awaitingCurrentItemEnd = false;
        } else {
          if (_remainingItemCount > 0) _remainingItemCount--;
          shouldStop = _remainingItemCount <= 0;
        }
      case SleepTimerMode.off:
      case SleepTimerMode.afterDuration:
      case SleepTimerMode.afterPlaybackDuration:
      case SleepTimerMode.atTime:
        break;
    }
    if (shouldStop) _clearInMemory();
    unawaited(_persist());
    notifyListeners();
    return shouldStop;
  }

  /// Reconciles an overdue wall-clock timer immediately after foregrounding.
  void checkNow() => _heartbeatTick(forcePersist: true);

  void _handlePlaybackStateChanged() {
    final wasRunning = _wasPlaybackRunning;
    _settlePlaybackTime();
    _wasPlaybackRunning = _isPlaybackRunning?.call() ?? false;
    _lastSettledAt = _now();
    if (_mode == SleepTimerMode.afterPlaybackDuration &&
        wasRunning &&
        !_wasPlaybackRunning) {
      _rememberPlaybackPersistTime();
      unawaited(_persist(settle: false));
    }
  }

  void _settlePlaybackTime() {
    final now = _now();
    if (_mode == SleepTimerMode.afterPlaybackDuration && _wasPlaybackRunning) {
      final elapsed = now.difference(_lastSettledAt);
      if (!elapsed.isNegative) _playbackRemaining -= elapsed;
    }
    _lastSettledAt = now;
  }

  void _ensureHeartbeat() {
    _heartbeat ??= Timer.periodic(_heartbeatInterval, (_) => _heartbeatTick());
  }

  void _heartbeatTick({bool forcePersist = false}) {
    if (!isActive) {
      _heartbeat?.cancel();
      _heartbeat = null;
      return;
    }
    final wasRunning = _wasPlaybackRunning;
    _settlePlaybackTime();
    _wasPlaybackRunning = _isPlaybackRunning?.call() ?? false;
    _lastSettledAt = _now();
    if (_mode == SleepTimerMode.afterPlaybackDuration) {
      final stopped = wasRunning && !_wasPlaybackRunning;
      _maybePersistPlaybackRemaining(force: forcePersist || stopped);
    }
    final value = remaining;
    if ((_mode == SleepTimerMode.afterDuration ||
            _mode == SleepTimerMode.afterPlaybackDuration ||
            _mode == SleepTimerMode.atTime) &&
        value <= Duration.zero) {
      unawaited(_expire());
      return;
    }
    final seconds = value.inSeconds;
    if (seconds != _lastNotifiedSecond) {
      _lastNotifiedSecond = seconds;
      notifyListeners();
    }
  }

  void _maybePersistPlaybackRemaining({required bool force}) {
    final now = _now();
    if (!force &&
        now.difference(_lastPlaybackPersistAt) < _playbackPersistInterval) {
      return;
    }
    _rememberPlaybackPersistTime();
    unawaited(_persist(settle: false));
  }

  void _rememberPlaybackPersistTime() {
    _lastPlaybackPersistAt = _now();
  }

  Future<void> _expire() async {
    if (!isActive) return;
    // Clearing first makes this timer expire once. A subsequent timer must not
    // be blocked by the old timer's pending native pause or preference write.
    _clearInMemory();
    // Record the pause intent before any disk I/O. Foreground recovery and
    // completion callbacks must already see the expired timer's decision.
    final expiration = Future<void>.sync(() async => _onExpired?.call());
    notifyListeners();
    await Future.wait<void>([
      expiration,
      _persist(settle: false).catchError((Object error) {
        debugPrint('Sleep timer persistence failed after expiry: $error');
      }),
    ]);
  }

  void _clearInMemory() {
    _mode = SleepTimerMode.off;
    _deadline = null;
    _playbackRemaining = Duration.zero;
    _remainingItemCount = 0;
    _scheduledItemCount = 0;
    _awaitingCurrentItemEnd = false;
    _lastNotifiedSecond = -1;
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  Future<void> _persist({bool settle = true}) async {
    if (settle) _settlePlaybackTime();
    final snapshot = _TimerSnapshot.capture(this);
    final operation = _persistenceTail.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      await _writePreferences(preferences, snapshot);
      await _writeActiveTimer(preferences, snapshot);
    });
    _persistenceTail = operation.catchError((Object _) {});
    await operation;
  }

  Future<void> _persistPreferences() async {
    final snapshot = _TimerSnapshot.capture(this);
    final operation = _persistenceTail.then((_) async {
      final preferences = await SharedPreferences.getInstance();
      await _writePreferences(preferences, snapshot);
    });
    _persistenceTail = operation.catchError((Object _) {});
    await operation;
  }

  Future<void> _writePreferences(
    SharedPreferences preferences,
    _TimerSnapshot snapshot,
  ) async {
    await preferences.setBool(_countOnlyKey, snapshot.countOnlyWhilePlaying);
    await preferences.setInt(_customMinutesKey, snapshot.customMinutes);
    await preferences.setInt(_customItemCountKey, snapshot.customItemCount);
  }

  Future<void> _writeActiveTimer(
    SharedPreferences preferences,
    _TimerSnapshot snapshot,
  ) async {
    switch (snapshot.mode) {
      case SleepTimerMode.afterDuration:
      case SleepTimerMode.atTime:
        final deadline = snapshot.deadline;
        if (deadline == null) {
          await _clearActivePersistence(preferences);
          return;
        }
        await preferences.setInt(_modeKey, snapshot.mode.index);
        await preferences.setInt(_deadlineKey, deadline.millisecondsSinceEpoch);
        await _removePlaybackAndItemKeys(preferences);
      case SleepTimerMode.afterPlaybackDuration:
        if (snapshot.playbackRemainingMs <= 0) {
          await _clearActivePersistence(preferences);
          return;
        }
        await preferences.setInt(_modeKey, snapshot.mode.index);
        await preferences.setInt(
          _playbackRemainingKey,
          snapshot.playbackRemainingMs,
        );
        await preferences.remove(_deadlineKey);
        await _removeItemKeys(preferences);
      case SleepTimerMode.endOfCurrentItem:
      case SleepTimerMode.endOfQueue:
        await preferences.setInt(_modeKey, snapshot.mode.index);
        await preferences.remove(_deadlineKey);
        await _removePlaybackAndItemKeys(preferences);
      case SleepTimerMode.afterItemCount:
        if (snapshot.remainingItemCount <= 0) {
          await _clearActivePersistence(preferences);
          return;
        }
        await preferences.setInt(_modeKey, snapshot.mode.index);
        await preferences.setInt(
          _remainingItemsKey,
          snapshot.remainingItemCount,
        );
        await preferences.setInt(
          _scheduledItemsKey,
          snapshot.scheduledItemCount,
        );
        await preferences.setBool(
          _awaitingCurrentKey,
          snapshot.awaitingCurrentItemEnd,
        );
        await preferences.remove(_deadlineKey);
        await preferences.remove(_playbackRemainingKey);
      case SleepTimerMode.off:
        await _clearActivePersistence(preferences);
    }
  }

  Future<void> _removePlaybackAndItemKeys(SharedPreferences preferences) async {
    await preferences.remove(_playbackRemainingKey);
    await _removeItemKeys(preferences);
  }

  Future<void> _removeItemKeys(SharedPreferences preferences) async {
    await preferences.remove(_remainingItemsKey);
    await preferences.remove(_scheduledItemsKey);
    await preferences.remove(_awaitingCurrentKey);
  }

  Future<void> _clearActivePersistence(SharedPreferences preferences) async {
    await preferences.remove(_modeKey);
    await preferences.remove(_deadlineKey);
    await _removePlaybackAndItemKeys(preferences);
  }

  static String _formatDuration(Duration duration) {
    final totalMinutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes.remainder(60);
    if (hours > 0) {
      return '$hours:${_twoDigits(minutes)}:${_twoDigits(seconds)}';
    }
    return '$minutes:${_twoDigits(seconds)}';
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');

  @override
  void dispose() {
    _heartbeat?.cancel();
    _playbackListenable?.removeListener(_handlePlaybackStateChanged);
    super.dispose();
  }
}

class _TimerSnapshot {
  const _TimerSnapshot({
    required this.mode,
    required this.deadline,
    required this.playbackRemainingMs,
    required this.remainingItemCount,
    required this.scheduledItemCount,
    required this.awaitingCurrentItemEnd,
    required this.countOnlyWhilePlaying,
    required this.customMinutes,
    required this.customItemCount,
  });

  final SleepTimerMode mode;
  final DateTime? deadline;
  final int playbackRemainingMs;
  final int remainingItemCount;
  final int scheduledItemCount;
  final bool awaitingCurrentItemEnd;
  final bool countOnlyWhilePlaying;
  final int customMinutes;
  final int customItemCount;

  factory _TimerSnapshot.capture(SleepTimerController timer) {
    return _TimerSnapshot(
      mode: timer._mode,
      deadline: timer._deadline,
      playbackRemainingMs: timer._playbackRemaining.inMilliseconds,
      remainingItemCount: timer._remainingItemCount,
      scheduledItemCount: timer._scheduledItemCount,
      awaitingCurrentItemEnd: timer._awaitingCurrentItemEnd,
      countOnlyWhilePlaying: timer._countOnlyWhilePlaying,
      customMinutes: timer._customMinutes,
      customItemCount: timer._customItemCount,
    );
  }
}
