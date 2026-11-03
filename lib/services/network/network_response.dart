import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Dispose requests acquired after a timeout/cancellation without closing the
/// shared client. Route selection and retry remain the caller's responsibility.
Future<HttpClientRequest> openNetworkRequest(
  HttpClient client,
  String method,
  Uri uri, {
  required Duration timeout,
  Future<void>? cancelSignal,
  Object cancellationError = const HttpException('网络请求已取消'),
}) async {
  var abandoned = false;
  HttpClientRequest? acquired;
  final opening = client.openUrl(method, uri);
  unawaited(
    opening.then<void>((request) {
      acquired = request;
      if (abandoned) request.abort(cancellationError);
    }, onError: (Object _) {}),
  );
  try {
    return await Future.any<HttpClientRequest>([
      opening,
      if (cancelSignal != null)
        cancelSignal.then<HttpClientRequest>((_) => throw cancellationError),
    ]).timeout(timeout);
  } catch (_) {
    abandoned = true;
    acquired?.abort(cancellationError);
    rethrow;
  }
}

/// Cancel the real HTTP subscription on every exit, including an idle timeout.
Future<Uint8List> readNetworkResponseBytes(
  HttpClientResponse response, {
  int? maxBytes,
  Duration idleTimeout = const Duration(seconds: 30),
  Duration? totalTimeout,
  void Function(int received, int? total)? onBytes,
}) async {
  final iterator = StreamIterator<List<int>>(response);
  final bytes = BytesBuilder(copy: false);
  final deadline = totalTimeout == null
      ? null
      : DateTime.now().add(totalTimeout);
  final total =
      response.contentLength >= 0 &&
          response.compressionState !=
              HttpClientResponseCompressionState.decompressed
      ? response.contentLength
      : null;
  try {
    if (maxBytes != null && total != null && total > maxBytes) {
      throw const FormatException('网络响应超过读取上限');
    }
    while (true) {
      var wait = idleTimeout;
      final remaining = deadline?.difference(DateTime.now());
      if (remaining != null) {
        if (remaining <= Duration.zero) throw TimeoutException('网络响应读取超时');
        if (remaining < wait) wait = remaining;
      }
      if (!await iterator.moveNext().timeout(wait)) break;
      final chunk = iterator.current;
      if (maxBytes != null && bytes.length + chunk.length > maxBytes) {
        throw const FormatException('网络响应超过读取上限');
      }
      bytes.add(chunk);
      onBytes?.call(bytes.length, total);
    }
    return bytes.takeBytes();
  } finally {
    await iterator.cancel();
  }
}
