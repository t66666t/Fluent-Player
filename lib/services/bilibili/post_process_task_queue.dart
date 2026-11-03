import 'dart:async';

class PostProcessTimeoutException implements Exception {
  const PostProcessTimeoutException(this.phase, this.timeout);

  final String phase;
  final Duration timeout;

  @override
  String toString() =>
      'PostProcessTimeoutException($phase, ${timeout.inSeconds}s)';
}

class PostProcessFailureException implements Exception {
  const PostProcessFailureException(this.phase, [this.details]);

  final String phase;
  final String? details;

  @override
  String toString() => details == null
      ? 'PostProcessFailureException($phase)'
      : 'PostProcessFailureException($phase): $details';
}

class SerialPostProcessQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> enqueue<T>(
    Future<T> Function() task, {
    required String phase,
    required Duration timeout,
    FutureOr<void> Function()? onTimeout,
  }) {
    final result = Completer<T>();
    final previous = _tail;
    final next = previous.then<void>(
      (_) => _run(
        task,
        result,
        phase: phase,
        timeout: timeout,
        onTimeout: onTimeout,
      ),
      onError: (_) => _run(
        task,
        result,
        phase: phase,
        timeout: timeout,
        onTimeout: onTimeout,
      ),
    );
    _tail = next.catchError((_) {});
    return result.future;
  }

  Future<void> _run<T>(
    Future<T> Function() task,
    Completer<T> result, {
    required String phase,
    required Duration timeout,
    FutureOr<void> Function()? onTimeout,
  }) async {
    try {
      final value = await task().timeout(
        timeout,
        onTimeout: () {
          if (onTimeout != null) {
            unawaited(Future<void>.sync(onTimeout));
          }
          throw PostProcessTimeoutException(phase, timeout);
        },
      );
      if (!result.isCompleted) result.complete(value);
    } catch (error, stackTrace) {
      if (!result.isCompleted) result.completeError(error, stackTrace);
    }
  }
}
