import 'dart:io';

class _AudioResult {
  _AudioResult(this.path) : error = null, stack = null;
  _AudioResult.error(this.error, this.stack) : path = null;
  final String? path;
  final Object? error;
  final StackTrace? stack;
  String unwrap() {
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return path!;
  }
}

class _PendingAudio<K> {
  _PendingAudio(this.key);
  final K key;
  late Future<_AudioResult> result;
  double fraction = 0;
  void Function(double)? listener;
}

/// One audio preparation may run ahead of inference. A delivered path belongs
/// to the caller; close drains and deletes only the unclaimed preparation.
class AudioChunkPrefetcher<K> {
  AudioChunkPrefetcher({
    required Iterable<K> inputs,
    required this.prepare,
    this.onState,
    this.allowAhead,
  }) : _inputs = inputs.iterator;
  final Future<String> Function(K, void Function(double)) prepare;
  final void Function(K?, double, bool)? onState;
  final bool Function()? allowAhead;
  final Iterator<K> _inputs;
  _PendingAudio<K>? _pending;
  bool _closed = false;
  void _start() {
    if (_closed || _pending != null || !_inputs.moveNext()) return;
    final item = _pending = _PendingAudio(_inputs.current);
    onState?.call(item.key, 0, false);
    item.result = () async {
      try {
        final path = await prepare(item.key, (value) {
          item.fraction = value.clamp(0, 1);
          if (!_closed) {
            item.listener?.call(item.fraction);
            onState?.call(item.key, item.fraction, false);
          }
        });
        if (!_closed) onState?.call(item.key, 1, true);
        return _AudioResult(path);
      } catch (error, stack) {
        return _AudioResult.error(error, stack);
      }
    }();
  }

  Future<String> take(K key, void Function(double) onProgress) async {
    if (_closed) throw StateError('音频准备已关闭');
    _start();
    final item = _pending;
    if (item == null || item.key != key) throw StateError('音频准备顺序不匹配');
    item.listener = onProgress;
    onProgress(item.fraction);
    final path = (await item.result).unwrap();
    _pending = null;
    if (allowAhead?.call() != false) _start();
    if (_pending == null) onState?.call(null, 1, true);
    return path;
  }

  Future<void> close() async {
    _closed = true;
    final item = _pending;
    _pending = null;
    final path = (await item?.result)?.path;
    if (path != null && await File(path).exists()) await File(path).delete();
  }
}
