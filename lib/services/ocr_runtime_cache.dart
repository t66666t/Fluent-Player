import 'dart:io';
import 'dart:typed_data';

/// Only the worker accesses this cache; disposal always happens between runs.
class OcrRuntimeCache<T extends Object> {
  OcrRuntimeCache({required this.dispose});
  final Future<void> Function(T) dispose;
  final _values = <String, T>{};

  Future<T> obtain(
    String key, {
    required int capacity,
    required Future<T> Function() create,
  }) async {
    final previous = _values.remove(key);
    final limit = capacity.clamp(1, 2);
    // Trim on hits too: a reduced memory budget must reclaim idle sessions.
    while (_values.length >= limit) {
      await dispose(_values.remove(_values.keys.first)!);
    }
    if (previous != null) {
      _values[key] = previous;
      return previous;
    }
    final value = await create();
    _values[key] = value;
    return value;
  }

  Future<void> remove(T value) async {
    _values.removeWhere((_, entry) => identical(entry, value));
    await dispose(value);
  }

  Future<void> clear() async {
    final values = _values.values.toList();
    _values.clear();
    for (final value in values) {
      await dispose(value);
    }
  }
}

/// Keep at most one file per region open, and avoid a seek on sequential reads.
/// The manager closes these handles before the extractor removes a chunk.
class OcrRawFrameReader {
  final _files = <int, ({String path, RandomAccessFile file, int offset})>{};

  Future<Uint8List> read({
    required int track,
    required String path,
    required int offset,
    required int length,
  }) async {
    if (offset < 0 || length <= 0) throw StateError('OCR 原始帧尺寸无效');
    var entry = _files[track];
    if (entry == null || entry.path != path) {
      _files.remove(track);
      await entry?.file.close();
      entry = (path: path, file: await File(path).open(), offset: 0);
    }
    try {
      if (entry.offset != offset) await entry.file.setPosition(offset);
      final bytes = await entry.file.read(length);
      if (bytes.length != length) throw StateError('OCR 原始帧不完整');
      _files[track] = (path: path, file: entry.file, offset: offset + length);
      return bytes;
    } catch (_) {
      _files.remove(track);
      await entry.file.close();
      rethrow;
    }
  }

  Future<void> close() async {
    final files = _files.values.toList();
    _files.clear();
    for (final entry in files) {
      await entry.file.close();
    }
  }
}
