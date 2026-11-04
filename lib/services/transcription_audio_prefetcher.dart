import 'dart:async';

import 'transcription_reliability.dart';

class _AudioResult<T> {
  _AudioResult.value(this.value) : error = null, stack = null;
  _AudioResult.error(this.error, this.stack) : value = null;
  final T? value;
  final Object? error;
  final StackTrace? stack;

  T unwrap() {
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value as T;
  }
}

class _PendingAudio<T> {
  _PendingAudio(this.slice);
  final TranscriptionSlice slice;
  final cancel = Completer<void>();
  late final Future<_AudioResult<T>> result;
  double progress = 0;
  void Function(double)? listener;
}

/// Prepares at most one local slice ahead, without making service requests.
/// A taken result belongs to the caller; superseded/unclaimed results are freed.
class TranscriptionAudioPrefetcher<T> {
  TranscriptionAudioPrefetcher({required this.prepare, required this.release});

  final Future<T> Function(
    TranscriptionSlice slice,
    void Function(double) onProgress,
    Future<void> cancelSignal,
  )
  prepare;
  final Future<void> Function(T) release;
  _PendingAudio<T>? _pending;
  bool _closed = false;

  void prefetch(TranscriptionSlice slice) {
    if (_closed || _pending != null) return;
    final pending = _pending = _PendingAudio<T>(slice);
    pending.result = () async {
      try {
        return _AudioResult<T>.value(
          await prepare(slice, (value) {
            pending.progress = value.clamp(0.0, 1.0);
            if (!_closed) pending.listener?.call(pending.progress);
          }, pending.cancel.future),
        );
      } catch (error, stack) {
        // A speculative failure is observed only if this exact slice is taken.
        return _AudioResult<T>.error(error, stack);
      }
    }();
  }

  Future<T> take(
    TranscriptionSlice slice,
    void Function(double) onProgress,
  ) async {
    if (_closed) throw StateError('音频准备已关闭');
    if (_pending != null && _pending!.slice.taskKey != slice.taskKey) {
      await _discard();
    }
    prefetch(slice);
    final pending = _pending!;
    pending.listener = onProgress;
    onProgress(pending.progress);
    try {
      return (await pending.result).unwrap();
    } finally {
      pending.listener = null;
      if (!pending.cancel.isCompleted) pending.cancel.complete();
      if (identical(_pending, pending)) _pending = null;
    }
  }

  Future<void> _discard() async {
    final pending = _pending;
    _pending = null;
    if (pending == null) return;
    pending.listener = null;
    if (!pending.cancel.isCompleted) pending.cancel.complete();
    final result = await pending.result;
    if (result.error == null) await release(result.value as T);
  }

  Future<void> close() async {
    _closed = true;
    await _discard();
  }
}
