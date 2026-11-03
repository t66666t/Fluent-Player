import 'dart:async';
import 'dart:math' as math;

enum WebMediaTransferStage { downloading, merging, validating }

class WebMediaTransferBlock {
  const WebMediaTransferBlock({
    required this.id,
    required this.received,
    this.total,
    this.complete = false,
    this.active = false,
    this.weight = 1,
  });
  final String id;
  final int received;
  final int? total;
  final bool complete, active;
  final double weight;
  double get fraction => complete
      ? 1
      : total == null || total! <= 0
      ? 0
      : (received / total!).clamp(0, 1);
}

class WebMediaTransferSnapshot {
  WebMediaTransferSnapshot({
    this.stage = WebMediaTransferStage.downloading,
    this.received = 0,
    this.total,
    this.progress,
    this.timeBased = false,
    this.activeConnections = 0,
    this.retrying = false,
    Iterable<WebMediaTransferBlock> blocks = const [],
  }) : blocks = List.unmodifiable(blocks);
  final WebMediaTransferStage stage;
  final int received, activeConnections;
  final int? total;
  final double? progress;
  final bool timeBased, retrying;
  final List<WebMediaTransferBlock> blocks;

  WebMediaTransferSnapshot._status(
    WebMediaTransferSnapshot source, {
    required this.stage,
    required this.activeConnections,
    required this.retrying,
    required this.progress,
    required this.timeBased,
  }) : received = source.received,
       total = source.total,
       blocks = source.blocks;

  /// Connection and phase notifications share the immutable progress data.
  WebMediaTransferSnapshot withStatus({
    required WebMediaTransferStage stage,
    required int activeConnections,
    required bool retrying,
  }) => WebMediaTransferSnapshot._status(
    this,
    stage: stage,
    activeConnections: activeConnections,
    retrying: retrying,
    progress: progress,
    timeBased: timeBased,
  );

  WebMediaTransferSnapshot withProgress(
    double? progress, {
    required WebMediaTransferStage stage,
  }) => WebMediaTransferSnapshot._status(
    this,
    stage: stage,
    activeConnections: activeConnections,
    retrying: false,
    progress: progress,
    timeBased: false,
  );
}

/// A monotonic effective-byte meter. Old resume bytes form the baseline and
/// retries of an already observed resource/offset never increase this counter.
class WebMediaSpeedMeter {
  WebMediaSpeedMeter({int Function()? nowMilliseconds})
    : _now =
          nowMilliseconds ?? (Stopwatch()..start()).elapsedMillisecondsGetter;
  final int Function() _now;
  final List<({int at, int bytes})> _samples = [];
  final Map<String, int> _highWater = {};
  int _bytes = 0;
  bool hasObserved(String id) => _highWater.containsKey(id);
  void observe(String id, int received, {bool baseline = false}) {
    final previous = _highWater.putIfAbsent(id, () => 0);
    if (received > previous) {
      if (!baseline) _bytes += received - previous;
      _highWater[id] = received;
    }
  }

  double? sample() {
    final now = _now();
    _samples.add((at: now, bytes: _bytes));
    final cutoff = now - 10000;
    while (_samples.length > 1 && _samples[1].at <= cutoff) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final elapsed = now - first.at;
    if (elapsed < 2000) return null;
    return math.max(0, (_bytes - first.bytes) * 1000 / elapsed);
  }
}

extension on Stopwatch {
  int Function() get elapsedMillisecondsGetter =>
      () => elapsedMilliseconds;
}

/// Shared by every browser transfer. Short slices keep cancellation and live
/// rate changes responsive; the budget includes bytes discarded by retries.
class WebMediaBandwidthBudget {
  final Stopwatch _clock = Stopwatch()..start();
  int _limit = 0;
  double _tokens = 0;
  int _last = 0;
  int get limit => _limit;
  set limit(int value) {
    _limit = math.max(0, value);
    _tokens = 0;
    _last = _clock.elapsedMicroseconds;
  }

  Future<void> consume(
    int bytes, {
    required void Function() checkCancelled,
  }) async {
    var remaining = bytes.toDouble();
    while (remaining > 0 && _limit > 0) {
      checkCancelled();
      final now = _clock.elapsedMicroseconds;
      _tokens = math.min(
        _limit * .1,
        _tokens + (now - _last) * _limit / 1000000,
      );
      _last = now;
      final take = math.min(remaining, _tokens);
      remaining -= take;
      _tokens -= take;
      if (remaining > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    checkCancelled();
  }
}

/// FIFO process budget; cancelled waiters relinquish their reservation before
/// reporting cancellation so they cannot strand a connection or merge slot.
class WebMediaWorkGate {
  WebMediaWorkGate(this.limit);
  final int limit;
  int _active = 0;
  final List<Completer<void>> _waiting = [];
  Future<void> acquire(void Function() checkCancelled) async {
    checkCancelled();
    if (_active < limit) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    try {
      while (!waiter.isCompleted) {
        await Future.any([
          waiter.future,
          Future<void>.delayed(const Duration(milliseconds: 50)),
        ]);
        checkCancelled();
      }
      checkCancelled();
    } catch (_) {
      if (!_waiting.remove(waiter)) release();
      rethrow;
    }
  }

  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _active--;
    }
  }
}

/// Work-conserving connection budget. Each transfer can borrow every idle slot;
/// at the next response boundary the least-served waiting transfer goes first.
/// Reservations are keyed by transfer, so 32 workers cannot jump ahead of a
/// newer task simply by registering more waiters.
class WebMediaConnectionPool {
  WebMediaConnectionPool({this.limit = 32}) : assert(limit > 0);
  final int limit;
  int _active = 0;
  final List<_ConnectionLease> _leases = [];
  WebMediaWorkGate forTransfer() {
    final lease = _ConnectionLease(this);
    _leases.add(lease);
    return lease;
  }

  void _drain() {
    while (_active < limit) {
      _ConnectionLease? next;
      for (final lease in _leases) {
        if (lease.waiters.isEmpty) continue;
        if (next == null || lease.active < next.active) next = lease;
      }
      if (next == null) break;
      _leases.remove(next);
      _leases.add(
        next,
      ); // Round-robin ties, including newly arriving transfers.
      _active++;
      next.active++;
      next.waiters.removeAt(0).complete();
    }
    _leases.removeWhere((lease) => lease.active == 0 && lease.waiters.isEmpty);
  }
}

class _ConnectionLease extends WebMediaWorkGate {
  _ConnectionLease(this.pool) : super(pool.limit);
  final WebMediaConnectionPool pool;
  int active = 0;
  final waiters = <Completer<void>>[];

  @override
  Future<void> acquire(void Function() checkCancelled) async {
    checkCancelled();
    final waiter = Completer<void>();
    if (!pool._leases.contains(this)) pool._leases.add(this);
    waiters.add(waiter);
    pool._drain();
    try {
      while (!waiter.isCompleted) {
        await Future.any([
          waiter.future,
          Future<void>.delayed(const Duration(milliseconds: 50)),
        ]);
        checkCancelled();
      }
      checkCancelled();
    } catch (_) {
      if (!waiters.remove(waiter)) {
        release();
      } else {
        pool._drain();
      }
      rethrow;
    }
  }

  @override
  void release() {
    assert(active > 0);
    active--;
    pool._active--;
    pool._drain();
  }
}
