import 'dart:async';

/// Runs asynchronous tasks strictly in submission order.
///
/// A failed task is reported to its own caller but does not poison the queue,
/// allowing later tasks to continue.
class SerialTaskQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> enqueue<T>(Future<T> Function() task) {
    final operation = _tail.then<T>((_) => task());
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }
}
