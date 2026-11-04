import 'dart:async';
import 'dart:io';

import 'network_recovery.dart';
import 'network_response.dart';

/// One representation, several CDN URLs. Resume only when both the validator
/// and Content-Range still identify the same bytes; otherwise restart safely.
class ResumableMediaDownload {
  const ResumableMediaDownload({
    required this.createClient,
    this.retryDelays = NetworkRecovery.retryDelays,
    this.headerTimeout = const Duration(seconds: 25),
    this.idleTimeout = const Duration(seconds: 30),
  });

  final HttpClient Function() createClient;
  final List<Duration> retryDelays;
  final Duration headerTimeout;
  final Duration idleTimeout;

  Future<void> download({
    required List<Uri> urls,
    required File partial,
    required Map<String, String> headers,
    required void Function() checkCancelled,
    void Function(HttpClient)? onClient,
    void Function(HttpClient)? onClientClosed,
    void Function(int received, int? total)? onBytes,
    void Function(Duration delay, Object error)? onRetry,
  }) async {
    if (urls.isEmpty) throw const FormatException('没有可用的媒体地址');
    String? validator;
    int? expectedTotal;
    var urlIndex = 0;
    for (var attempt = 0; ; attempt++) {
      checkCancelled();
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset > 0 && validator == null) offset = 0;
      final client = createClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 15);
      onClient?.call(client);
      IOSink? sink;
      Object? failure;
      var fallback = false;
      try {
        final request = await openNetworkRequest(
          client,
          'GET',
          urls[urlIndex],
          timeout: headerTimeout,
        );
        headers.forEach(request.headers.set);
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (offset > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
          request.headers.set(HttpHeaders.ifRangeHeader, validator!);
        }
        final response = await request.close().timeout(headerTimeout);
        if (response.statusCode != 200 && response.statusCode != 206) {
          await response.listen((_) {}).cancel();
          fallback = urlIndex + 1 < urls.length;
          throw HttpException('CDN 返回 ${response.statusCode}');
        }
        final encoding = response.headers.value(
          HttpHeaders.contentEncodingHeader,
        );
        if (encoding != null && encoding != 'identity') {
          throw const FormatException('媒体来源返回了压缩数据，无法安全续传');
        }
        final etag = response.headers.value(HttpHeaders.etagHeader);
        final nextValidator = etag != null && !etag.startsWith('W/')
            ? etag
            : response.headers.value(HttpHeaders.lastModifiedHeader);
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
          response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
        );
        if (response.statusCode == 206 &&
            (range == null ||
                int.parse(range[1]!) != offset ||
                offset > 0 &&
                    (nextValidator != validator ||
                        expectedTotal != null &&
                            int.parse(range[3]!) != expectedTotal))) {
          // Do not append an unverified suffix, including when changing CDN.
          validator = null;
          expectedTotal = null;
          if (await partial.exists()) await partial.delete();
          throw const HttpException('续传校验发生变化，重新获取当前媒体');
        }
        if (response.statusCode == 200) offset = 0;
        validator = nextValidator;
        expectedTotal = response.statusCode == 206
            ? int.parse(range![3]!)
            : response.contentLength >= 0
            ? response.contentLength
            : null;
        var received = offset;
        sink = partial.openWrite(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        await for (final chunk in response.timeout(idleTimeout)) {
          checkCancelled();
          sink.add(chunk);
          received += chunk.length;
          onBytes?.call(received, expectedTotal);
        }
        await sink.flush();
        await sink.close();
        sink = null;
        checkCancelled();
        if (received == 0 ||
            expectedTotal != null && received != expectedTotal) {
          throw const HttpException('媒体数据尚未完整接收');
        }
        return;
      } catch (error) {
        failure = error;
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
        client.close(force: true);
        onClientClosed?.call(client);
      }
      checkCancelled();
      fallback =
          fallback ||
          NetworkRecovery.isTransient(failure) && urlIndex + 1 < urls.length;
      if (fallback) {
        urlIndex++;
        continue;
      }
      if (attempt >= retryDelays.length ||
          !NetworkRecovery.isTransient(failure)) {
        throw failure;
      }
      final delay = retryDelays[attempt];
      onRetry?.call(delay, failure);
      await NetworkRecovery.wait(delay, checkCancelled: checkCancelled);
    }
  }
}
