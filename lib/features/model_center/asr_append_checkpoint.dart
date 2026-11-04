import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Native stages replace a complete chunk payload once. Capture those writes
/// instead of re-encoding and backing up an ever-growing transcript map.
class AsrChunkMap extends MapBase<String, dynamic> {
  final _values = <String, dynamic>{};
  final changed = <String, dynamic>{};
  @override
  dynamic operator [](Object? key) => _values[key];
  @override
  void operator []=(String key, dynamic value) {
    _values[key] = value;
    changed[key] = value;
  }

  @override
  Iterable<String> get keys => _values.keys;
  @override
  dynamic remove(Object? key) {
    changed.remove(key);
    return _values.remove(key);
  }

  @override
  void clear() {
    _values.clear();
    changed.clear();
  }

  Map<String, dynamic> takeChanges() {
    final result = Map<String, dynamic>.of(changed);
    changed.clear();
    return result;
  }
}

Future<Map<String, dynamic>?> readAsrAppendCheckpoint(File file) async {
  if (!await file.exists()) return null;
  return _restoreAsrAppendCheckpoint(file.path);
}

Future<Map<String, dynamic>> _restoreAsrAppendCheckpoint(String path) =>
    Isolate.run(() => _readAsrAppendCheckpoint(File(path)));

Future<Map<String, dynamic>> _readAsrAppendCheckpoint(File file) async {
  final bytes = await file.readAsBytes();
  final pieces = <String, dynamic>{}, enhanced = <String, dynamic>{};
  int? chunkMs;
  var at = 0;
  while (at < bytes.length) {
    final end = bytes.indexOf(10, at);
    if (end < 0) break;
    try {
      final record = jsonDecode(utf8.decode(bytes.sublist(at, end))) as Map;
      pieces.addAll(Map<String, dynamic>.from(record['pieces'] as Map? ?? {}));
      enhanced.addAll(
        Map<String, dynamic>.from(record['enhanced'] as Map? ?? {}),
      );
      chunkMs = record['chunkDurationMs'] as int? ?? chunkMs;
    } on FormatException {
      break;
    }
    at = end + 1;
  }
  if (at < bytes.length) {
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.truncate(at);
    } finally {
      await handle.close();
    }
  }
  return {'pieces': pieces, 'enhanced': enhanced, 'chunkDurationMs': chunkMs};
}
