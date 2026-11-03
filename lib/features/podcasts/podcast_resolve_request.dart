import 'dart:async';
import 'dart:io';

class PodcastResolveCancelled implements Exception {
  const PodcastResolveCancelled();
}

/// One preview operation, including redirects, retries and network detection.
/// Closing its sockets does not affect searches, playback or downloads.
class PodcastResolveRequest {
  PodcastResolveRequest({this.budget = const Duration(seconds: 20)}) {
    _timer = Timer(budget, () => _stop(timedOut: true));
  }

  final Duration budget;
  final _elapsed = Stopwatch()..start();
  final _stopped = Completer<void>();
  final _clients = <HttpClient>{};
  late final Timer _timer;
  bool _timedOut = false;

  bool get isStopped => _stopped.isCompleted;
  Duration get remaining {
    final value = budget - _elapsed.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  void check() {
    if (_timedOut) throw TimeoutException('播客预览加载超时', budget);
    if (isStopped) throw const PodcastResolveCancelled();
  }

  void attach(HttpClient client) {
    if (isStopped) {
      client.close(force: true);
      check();
    }
    _clients.add(client);
  }

  Future<T> wait<T>(Future<T> operation) {
    check();
    return Future.any<T>([
      operation,
      _stopped.future.then<T>((_) {
        check();
        throw const PodcastResolveCancelled();
      }),
    ]);
  }

  Future<void> delay(Duration duration) async {
    final done = Completer<void>();
    final timer = Timer(duration, done.complete);
    try {
      await wait(done.future);
    } finally {
      timer.cancel();
    }
  }

  void cancel() => _stop();
  void dispose() => _stop();

  void _stop({bool timedOut = false}) {
    if (isStopped) return;
    _timedOut = timedOut;
    _timer.cancel();
    _elapsed.stop();
    _stopped.complete();
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
