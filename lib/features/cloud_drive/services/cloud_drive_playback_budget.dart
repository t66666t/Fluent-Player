import 'dart:async';

import '../providers/cloud_drive_http.dart';

/// One playback or quality switch shares this deadline across resolve,
/// gateway, initialize and handoff. A stage may not restart the full budget.
class CloudDrivePlaybackBudget {
  CloudDrivePlaybackBudget({
    this.total = const Duration(seconds: 30),
    DateTime Function()? clock,
    DateTime? started,
  }) : _clock = clock ?? DateTime.now,
       started = started ?? (clock ?? DateTime.now)();

  final Duration total;
  final DateTime Function() _clock;

  /// Monotonic origin for this operation. Tests inject [clock].
  final DateTime started;

  DateTime get now => _clock();
  DateTime get deadline => started.add(total);

  /// `min(stage cap, time left)`. Zero means the operation is already over.
  Duration remaining(Duration cap) {
    final left = deadline.difference(now);
    if (left <= Duration.zero || cap <= Duration.zero) return Duration.zero;
    return left < cap ? left : cap;
  }

  void ensure(String stage) {
    if (!now.isBefore(deadline)) {
      throw TimeoutException('网盘播放超时：$stage');
    }
  }
}

/// Initial stage caps. These are not a promise that a longer timeout is a fix.
const Duration cloudDriveResolveCap = Duration(seconds: 8);
const Duration cloudDriveInitializeCap = Duration(seconds: 16);
// HLS pre-roll can fill a segment before its clock advances. Keep room for
// the bounded clock alignment after that pre-roll, within the same 30s budget.
const Duration cloudDriveHandoffCap = Duration(seconds: 18);
const Duration cloudDriveHeaderCap = Duration(seconds: 8);

/// Waits only until [budget]. If the source future finishes later, [onLate]
/// releases whatever it produced so a timed-out open cannot leak a lease.
Future<T> bindCloudDriveStage<T>({
  required Future<T> future,
  required Duration budget,
  required Future<void> Function(T value) onLate,
  void Function()? onTimeout,
}) async {
  if (budget <= Duration.zero) {
    onTimeout?.call();
    unawaited(future.then(onLate, onError: (Object _, StackTrace _) {}));
    throw TimeoutException('网盘播放超时');
  }
  try {
    return await future.timeout(budget);
  } on TimeoutException {
    onTimeout?.call();
    unawaited(future.then(onLate, onError: (Object _, StackTrace _) {}));
    rethrow;
  }
}

class _FlightSlot<T> {
  _FlightSlot(this.future, this.token);
  final Future<T> future;
  final CloudDriveCancelToken token;
  var users = 0;
}

/// Several callers may share one upstream read. Cancelling the last caller
/// aborts the work; cancelling one of several leaves the others running.
class CloudDriveSingleFlight<T> {
  final Map<Object, _FlightSlot<T>> _inflight = {};

  Future<T> run(
    Object key,
    Future<T> Function(CloudDriveCancelToken token) action, {
    CloudDriveCancelToken? caller,
  }) {
    final existing = _inflight[key];
    if (existing != null) {
      existing.users++;
      caller?.onCancel(() => _leave(key, existing));
      return existing.future;
    }
    final token = CloudDriveCancelToken();
    final slot = _FlightSlot<T>(action(token), token);
    slot.users = 1;
    _inflight[key] = slot;
    caller?.onCancel(() => _leave(key, slot));
    slot.future.whenComplete(() {
      if (identical(_inflight[key], slot)) _inflight.remove(key);
    });
    return slot.future;
  }

  void _leave(Object key, _FlightSlot<T> slot) {
    if (slot.users > 0) slot.users--;
    if (slot.users > 0) return;
    slot.token.cancel();
    if (identical(_inflight[key], slot)) _inflight.remove(key);
  }
}
