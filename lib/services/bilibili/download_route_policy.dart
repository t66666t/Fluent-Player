import 'dart:convert';

import '../../debug/developer_log.dart' as developer;
import 'media_connection_pool.dart';

/// A slow connection remains usable. Try a different URL a bounded number of
/// times, then keep downloading rather than turning a slow network into a failure.
class BilibiliDownloadRoutePolicy {
  const BilibiliDownloadRoutePolicy({
    this.warmUp = const Duration(seconds: 5),
    this.sampleWindow = const Duration(seconds: 12),
    this.minimumBytesPerSecond = 512 * 1024,
    this.minimumRemainingBytes = 1024 * 1024,
    this.maxSlowSwitches = 2,
    this.diagnosticInterval = const Duration(seconds: 5),
  }) : assert(minimumBytesPerSecond > 0),
       assert(minimumRemainingBytes >= 0),
       assert(maxSlowSwitches >= 0);

  final Duration warmUp;
  final Duration sampleWindow;
  final int minimumBytesPerSecond;
  final int minimumRemainingBytes;
  final int maxSlowSwitches;
  final Duration diagnosticInterval;
}

/// Samples only bytes received during this request, using monotonic elapsed time.
/// Queueing, URL resolution and previously downloaded bytes are not throughput.
class BilibiliDownloadSpeedWindow {
  BilibiliDownloadSpeedWindow(this.policy)
    : assert(policy.warmUp >= Duration.zero),
      assert(policy.sampleWindow > Duration.zero),
      assert(policy.diagnosticInterval > Duration.zero);

  final BilibiliDownloadRoutePolicy policy;
  Duration? _baselineTime;
  int _baselineBytes = 0;

  double? sample(int transferredBytes, Duration elapsed) {
    if (elapsed < policy.warmUp) return null;
    final baselineTime = _baselineTime;
    if (baselineTime == null || transferredBytes < _baselineBytes) {
      _baselineTime = elapsed;
      _baselineBytes = transferredBytes;
      return null;
    }
    final window = elapsed - baselineTime;
    if (window < policy.sampleWindow) return null;
    final speed =
        (transferredBytes - _baselineBytes) *
        Duration.microsecondsPerSecond /
        window.inMicroseconds;
    _baselineTime = elapsed;
    _baselineBytes = transferredBytes;
    return speed;
  }
}

class BilibiliSlowRouteException implements Exception {
  const BilibiliSlowRouteException(this.bytesPerSecond);
  final double bytesPerSecond;

  @override
  String toString() =>
      'BilibiliSlowRouteException(${bytesPerSecond.round()} B/s)';
}

/// Scoped to one sequential track or one range part. Concurrent parts cannot
/// spend each other's retry budget or cancel each other's response streams.
class BilibiliDownloadRouteBudget {
  BilibiliDownloadRouteBudget(
    Iterable<String> urls,
    this.policy, {
    this.reconnectSameSource = false,
  }) : urls = urls.toSet().toList(growable: false);

  final List<String> urls;
  final BilibiliDownloadRoutePolicy policy;
  // URLSession's opaque resume data belongs to its original request URL. A
  // native low-speed recovery reconnects that URL once without discarding it.
  final bool reconnectSameSource;
  final Set<String> _slow = {};
  int slowSwitches = 0;

  bool get hasSlowSource => _slow.isNotEmpty;

  bool canSwitch(String current) =>
      slowSwitches < policy.maxSlowSwitches &&
      !_slow.contains(current) &&
      (reconnectSameSource ||
          urls.any((url) => url != current && !_slow.contains(url)));

  bool markSlow(String current) {
    if (!canSwitch(current)) return false;
    _slow.add(current);
    slowSwitches++;
    return true;
  }
}

typedef BilibiliDownloadDiagnostic = void Function(Map<String, Object?> event);

int _attemptSeed = 0;
String _nextAttemptId() {
  var value = _attemptSeed++;
  var result = '';
  do {
    result = String.fromCharCode(97 + value % 26) + result;
    value ~/= 26;
  } while (value > 0);
  return result;
}

/// Shareable diagnostics intentionally contain the host, never the URL path,
/// query, cookies, user title or local path. Sampling is throttled independently
/// of the progress callbacks used by the UI.
class BilibiliDownloadAttempt {
  BilibiliDownloadAttempt({
    required String url,
    required this.track,
    required this.transport,
    required this.requestedConnections,
    required this.budget,
    this.onDiagnostic,
    this.trace,
  }) : host = Uri.tryParse(url)?.host ?? 'unknown',
       _url = url,
       _window = BilibiliDownloadSpeedWindow(budget.policy);

  final String host;
  final String _url;
  final String track;
  final String transport;
  final int requestedConnections;
  final BilibiliDownloadRouteBudget budget;
  final BilibiliDownloadDiagnostic? onDiagnostic;
  final String? trace;
  // Letter IDs keep the existing debug buffer's numeric repeat compression
  // from merging different connections to the same CDN into a single entry.
  final String _attemptId = _nextAttemptId();
  final BilibiliDownloadSpeedWindow _window;
  final Stopwatch _clock = Stopwatch();
  Duration _lastDiagnostic = Duration.zero;
  int _lastDiagnosticBytes = 0;
  int _transferred = 0;
  int _resumedBytes = 0;
  int? _expectedBytes;
  int? _status;
  bool? _resumeSupported;
  bool _started = false;
  bool _finished = false;
  bool _reportedSlow = false;

  void recordResponse(int status, {required bool resumeSupported}) {
    _status = status;
    _resumeSupported = resumeSupported;
  }

  void start({
    required int resumedBytes,
    int? expectedBytes,
    int? status,
    bool? resumeSupported,
  }) {
    if (_started) return;
    _started = true;
    _resumedBytes = resumedBytes;
    _expectedBytes = expectedBytes;
    _status = status;
    _resumeSupported = resumeSupported;
    _clock.start();
    _window.sample(0, Duration.zero);
    _emit('started', 0);
  }

  /// Call after the bytes have been accepted by the target file. Throwing exits
  /// the consumer stream, which cancels only the current Dio child request.
  void addBytes(int length, {bool allowRecovery = true}) {
    if (!_started || _finished || length <= 0) return;
    _transferred += length;
    final elapsed = _clock.elapsed;
    final diagnosticElapsed = elapsed - _lastDiagnostic;
    if (diagnosticElapsed >= budget.policy.diagnosticInterval) {
      _emit(
        'sample',
        (_transferred - _lastDiagnosticBytes) *
            Duration.microsecondsPerSecond /
            diagnosticElapsed.inMicroseconds,
      );
      _lastDiagnostic = elapsed;
      _lastDiagnosticBytes = _transferred;
    }
    final speed = _window.sample(_transferred, elapsed);
    if (speed == null || speed >= budget.policy.minimumBytesPerSecond) return;
    final remaining = _expectedBytes == null
        ? null
        : _expectedBytes! - _transferred;
    // Finishing a small tail is cheaper than opening another connection. With
    // unknown length we cannot prove a worthwhile, safe range handoff either.
    final worthwhile =
        _resumeSupported == true &&
        remaining != null &&
        remaining > budget.policy.minimumRemainingBytes;
    if (allowRecovery && worthwhile && budget.markSlow(_url)) {
      _emit(
        budget.reconnectSameSource ? 'slow_reconnect' : 'slow_switch',
        speed,
      );
      throw BilibiliSlowRouteException(speed);
    }
    if (!_reportedSlow) {
      _reportedSlow = true;
      _emit('slow_continue', speed);
    }
  }

  void finish(String reason) {
    if (_finished) return;
    _finished = true;
    final elapsed = _clock.elapsedMicroseconds;
    _emit(
      reason,
      elapsed <= 0
          ? 0
          : _transferred * Duration.microsecondsPerSecond / elapsed,
    );
    _clock.stop();
  }

  void _emit(String event, double bytesPerSecond) {
    final pool = BilibiliMediaConnectionPool.shared;
    final record = <String, Object?>{
      'event': event,
      'request': _attemptId,
      if (trace != null) 'trace': trace,
      'track': track,
      'transport': transport,
      'host': host,
      'status': _status,
      'sourceIndex': budget.urls.indexOf(_url),
      'rangeSupported': _resumeSupported,
      'requestedConnections': requestedConnections,
      'activeConnections': pool.activeConnections,
      'connectionBudget': pool.limit,
      'waitingConnections': pool.waitingRequests,
      'resumedBytes': _resumedBytes,
      'transferredBytes': _transferred,
      'expectedBytes': _expectedBytes,
      'elapsedMs': _clock.elapsedMilliseconds,
      'bytesPerSecond': bytesPerSecond.round(),
      'slowSwitches': budget.slowSwitches,
    };
    developer.log(jsonEncode(record), name: 'BilibiliTransfer');
    onDiagnostic?.call(record);
  }
}
