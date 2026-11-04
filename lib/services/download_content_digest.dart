import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Computes a resumable transfer's content seal while bytes are already being
/// read or written. Callers publish it only after the output has closed and its
/// actual length matches [finish]. Replaced resources start with a new instance.
class DownloadContentDigest {
  final _result = _DownloadDigestResult();
  late final ByteConversionSink _input = sha256.startChunkedConversion(_result);
  var _finished = false;
  var _bytes = 0;

  int get bytes => _bytes;

  void add(List<int> chunk) {
    if (_finished) throw StateError('下载摘要已经结束');
    _input.add(chunk);
    _bytes += chunk.length;
  }

  Stream<List<int>> bind(
    Stream<List<int>> source, {
    void Function()? checkCancelled,
  }) => source.map((chunk) {
    checkCancelled?.call();
    add(chunk);
    return chunk;
  });

  Future<void> addStream(
    Stream<List<int>> source, {
    void Function()? checkCancelled,
  }) async {
    await for (final _ in bind(source, checkCancelled: checkCancelled)) {}
  }

  String finish(int expectedBytes) {
    if (_bytes != expectedBytes) {
      throw const FormatException('下载摘要的字节数与保存文件不一致');
    }
    if (!_finished) {
      _input.close();
      _finished = true;
    }
    return _result.value!.toString();
  }
}

class _DownloadDigestResult implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
