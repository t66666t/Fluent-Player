import 'dart:async';

/// A native model owner accepts one call at a time. Preparation and subtitle
/// refinement can share this owner while recognition runs on another isolate.
class ModelStageQueue {
  Future<void> _tail = Future<void>.value();
  Future<T> run<T>(Future<T> Function() action) {
    final task = _tail.then((_) => action());
    _tail = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  Future<void> get drained => _tail;
}

/// A slow consumer may hold at most two text batches, while other native stages
/// continue between its compute requests. Capture failures immediately, cancel
/// peers, and surface the original error only after all consumer work drains.
class BoundedModelConsumer {
  BoundedModelConsumer({required this.onFailure, this.capacity = 2}) {
    if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  }
  final void Function() onFailure;
  final int capacity;
  final _pending = <Future<void>>[];
  Future<void> _tail = Future<void>.value();
  Object? _failure;
  StackTrace? _stack;

  void checkFailure() {
    if (_failure != null) Error.throwWithStackTrace(_failure!, _stack!);
  }

  Future<void> submit(Future<void> Function() work) async {
    checkFailure();
    while (_pending.length >= capacity) {
      await _pending.removeAt(0);
      checkFailure();
    }
    final task = _tail.then((_) async {
      if (_failure != null) return;
      try {
        await work();
      } catch (error, stack) {
        _failure = error;
        _stack = stack;
        onFailure();
      }
    });
    _tail = task;
    _pending.add(task);
  }

  Future<void> drain() async {
    await _tail;
    _pending.clear();
    checkFailure();
  }
}

/// Shared workflows may overlap. Model residency changes and seam repair take
/// an exclusive turn after active workflows drain. Native compute requests
/// additionally obey the reservation's shared thread budget.
class ModelStageBarrier {
  final _writers = ModelStageQueue();
  int _active = 0;
  bool _exclusive = false;
  Completer<void>? _idle, _resume;

  Future<T> shared<T>(Future<T> Function() action) async {
    while (_exclusive) {
      await _resume!.future;
    }
    _active++;
    try {
      return await action();
    } finally {
      _active--;
      if (_active == 0 && _idle?.isCompleted == false) _idle!.complete();
    }
  }

  Future<T> exclusive<T>(Future<T> Function() action) => _writers.run(() async {
    _exclusive = true;
    final resume = _resume = Completer<void>();
    try {
      if (_active != 0) {
        _idle = Completer<void>();
        await _idle!.future;
      }
      return await action();
    } finally {
      _idle = null;
      _exclusive = false;
      resume.complete();
    }
  });
}

/// One prepared input ahead of the caller, with ownership transferred on take.
/// Errors are held until take; close drains and disposes any unclaimed input.
class ModelStagePrefetcher<I, P> {
  ModelStagePrefetcher({
    required Iterable<I> inputs,
    required this.prepare,
    required this.dispose,
    this.allowAhead,
  }) : _inputs = inputs.iterator;
  final Iterator<I> _inputs;
  final Future<P> Function(I) prepare;
  final Future<void> Function(P) dispose;
  final bool Function()? allowAhead;
  I? _key;
  Future<_StageResult<P>>? _pending;
  bool _closed = false;

  void _start() {
    if (_closed || _pending != null || !_inputs.moveNext()) return;
    final input = _key = _inputs.current;
    _pending = () async {
      try {
        return _StageResult<P>.value(await prepare(input));
      } catch (error, stack) {
        return _StageResult<P>.error(error, stack);
      }
    }();
  }

  Future<P> take(I input) async {
    if (_closed) throw StateError('模型准备已关闭');
    _start();
    if (_pending == null || input != _key) throw StateError('模型准备顺序不匹配');
    final value = (await _pending!).unwrap();
    _pending = null;
    if (allowAhead?.call() != false) _start();
    return value;
  }

  Future<void> close() async {
    _closed = true;
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    final result = await pending;
    if (result.error == null) await dispose(result.value as P);
  }
}

class _StageResult<T> {
  _StageResult.value(this.value) : error = null, stack = null;
  _StageResult.error(this.error, this.stack) : value = null;
  final T? value;
  final Object? error;
  final StackTrace? stack;
  T unwrap() {
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value as T;
  }
}

/// At most [capacity] produced items may be awaiting/undergoing stage two.
/// Both stages are individually serial. Errors cancel peers, drain all work,
/// and dispose every produced item before returning the first failure.
Future<List<O>> runBoundedModelPipeline<I, P, O>({
  required Iterable<I> inputs,
  required Future<P> Function(I) produce,
  required Future<O> Function(I, P) consume,
  required Future<void> Function(I, P) dispose,
  required void Function() abort,
  int capacity = 2,
  int Function()? currentCapacity,
}) async {
  if (capacity < 1) throw ArgumentError.value(capacity, 'capacity');
  final pending = <Future<_StageResult<O>>>[];
  final output = <O>[];
  var tail = Future<void>.value();
  Object? failure;
  StackTrace? failureStack;
  void failed(Object error, StackTrace stack) {
    if (failure != null) return;
    failure = error;
    failureStack = stack;
    abort();
  }

  try {
    for (final input in inputs) {
      while (pending.isNotEmpty &&
          pending.length >=
              (currentCapacity?.call() ?? capacity).clamp(1, capacity)) {
        output.add((await pending.removeAt(0)).unwrap());
      }
      if (failure != null) break;
      final prepared = await produce(input);
      final task = tail
          .then((_) async {
            try {
              if (failure != null) {
                Error.throwWithStackTrace(failure!, failureStack!);
              }
              return _StageResult<O>.value(await consume(input, prepared));
            } catch (error, stack) {
              failed(error, stack);
              return _StageResult<O>.error(error, stack);
            } finally {
              await dispose(input, prepared);
            }
          })
          .then(
            (value) => value,
            onError: (Object error, StackTrace stack) {
              failed(error, stack);
              return _StageResult<O>.error(error, stack);
            },
          );
      tail = task.then((_) {});
      pending.add(task);
    }
    for (final task in pending) {
      output.add((await task).unwrap());
    }
  } catch (error, stack) {
    failed(error, stack);
  } finally {
    await tail;
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  return output;
}
