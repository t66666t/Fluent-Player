import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../services/network/network_http.dart';

class _ParallelRangeUnsupported implements Exception {}

class _RangeTooSlow implements Exception {}

/// Eight active ranges with at most sixteen 2 MiB chunks in flight/buffered.
/// Only a contiguous prefix reaches disk. Slow ranges reconnect independently,
/// retaining their bytes, without cancelling healthy workers or changing route.
class ModelFileTransfer {
  ModelFileTransfer({
    required this.dio,
    this.parallelism = 8,
    this.chunkBytes = 2 * 1024 * 1024,
    this.minimumParallelBytes = 8 * 1024 * 1024,
    this.idleTimeout = const Duration(seconds: 20),
    this.recoveryWindow = const Duration(seconds: 5),
    this.rangeRetries = 2,
  });

  final Dio dio;
  final int parallelism, chunkBytes, minimumParallelBytes;
  final Duration idleTimeout;
  final Duration recoveryWindow;
  final int rangeRetries;

  Future<void> download({
    required String url,
    required int total,
    required File partial,
    required int offset,
    required CancelToken cancel,
    required Future<void> Function(String? etag) onValidator,
    required void Function(int received) onBytes,
    String? ifRange,
  }) async {
    final local = CancelToken();
    var finished = false;
    var retrySequential = false;
    String? resumeValidator;
    unawaited(
      cancel.whenCancel.then((_) {
        if (!finished) local.cancel('已暂停');
      }),
    );
    void checkCancelled() {
      if (cancel.isCancelled) throw cancel.cancelError!;
    }

    Future<Response<ResponseBody>> open(
      int start,
      int? end,
      String? validator, {
      bool freshConnection = false,
    }) {
      checkCancelled();
      return openCancellableDioStream(
        (child) => dio.get<ResponseBody>(
          url,
          cancelToken: child,
          options: Options(
            responseType: ResponseType.stream,
            headers: {
              'Accept-Encoding': 'identity',
              if (start > 0 || end != null)
                'Range': 'bytes=$start-${end ?? ''}',
              if (start > 0 && validator != null) 'If-Range': validator,
            },
            receiveTimeout: idleTimeout,
            sendTimeout: const Duration(seconds: 15),
            extra: {
              if (freshConnection)
                NetworkHttp.modelDownloadFreshConnectionKey: true,
            },
            validateStatus: (status) => status == 200 || status == 206,
          ),
        ),
        cancelToken: local,
      );
    }

    Future<void> validate(
      Response<ResponseBody> response,
      int start,
      int end,
    ) async {
      try {
        final encoding = response.headers.value('content-encoding');
        if (response.headers.value('content-type')?.contains('text/html') ==
                true ||
            encoding != null && encoding != 'identity') {
          throw const FormatException('下载源返回了网页或压缩内容');
        }
        if (response.statusCode == 206) {
          final range = RegExp(
            r'^bytes (\d+)-(\d+)/(\d+)$',
          ).firstMatch(response.headers.value('content-range') ?? '');
          if (range == null ||
              int.parse(range[1]!) != start ||
              int.parse(range[2]!) != end ||
              int.parse(range[3]!) != total) {
            throw const FormatException('下载源返回了不一致的续传范围');
          }
        }
        final length = int.tryParse(
          response.headers.value('content-length') ?? '',
        );
        if (length != null &&
            length != (response.statusCode == 200 ? total : end - start + 1)) {
          throw const FormatException('下载文件大小与模型清单不一致');
        }
      } catch (_) {
        await response.data!.stream.listen((_) {}).cancel();
        rethrow;
      }
    }

    var received = offset;
    IOSink? sink;
    try {
      final parallel =
          parallelism > 1 && total - offset >= minimumParallelBytes;
      final rangeBytes = math.min(
        chunkBytes,
        math.max(1, ((total - offset) / (parallelism + 1)).ceil()),
      );
      final firstEnd = parallel
          ? math.min(offset + rangeBytes, total) - 1
          : total - 1;
      var first = await open(offset, parallel ? firstEnd : null, ifRange);
      await validate(first, offset, firstEnd);
      if (first.statusCode == 206 &&
          ifRange != null &&
          first.headers.value('etag') != null &&
          first.headers.value('etag') != ifRange) {
        await first.data!.stream.listen((_) {}).cancel();
        throw const FormatException('下载文件已变更，正在重新下载');
      }
      final etag = first.headers.value('etag');
      final useParallel =
          parallel &&
          first.statusCode == 206 &&
          etag != null &&
          !etag.startsWith('W/');
      if (parallel && first.statusCode == 206 && !useParallel) {
        await first.data!.stream.listen((_) {}).cancel();
        first = await open(offset, null, ifRange);
        await validate(first, offset, total - 1);
      }
      if (first.statusCode == 200) offset = 0;
      received = offset;
      await onValidator(first.headers.value('etag'));
      resumeValidator = first.headers.value('etag');
      checkCancelled();
      sink = partial.openWrite(
        mode: offset == 0 ? FileMode.write : FileMode.append,
      );

      if (!useParallel) {
        await for (final chunk in first.data!.stream.timeout(idleTimeout)) {
          checkCancelled();
          if (received + chunk.length > total) {
            throw const FormatException('下载内容超过模型清单大小');
          }
          sink.add(chunk);
          received += chunk.length;
          onBytes(received);
        }
        if (received != total) throw const HttpException('模型文件未下载完整');
        return;
      }

      var bestRangeSpeed = 0.0;
      Future<Uint8List> readRange(
        int start,
        int end, {
        Response<ResponseBody>? initial,
      }) async {
        final bytes = BytesBuilder(copy: false);
        var retries = 0;
        while (true) {
          checkCancelled();
          Timer? watchdog;
          var slow = false;
          try {
            final from = start + bytes.length;
            final response =
                initial ??
                await open(from, end, etag, freshConnection: retries > 0);
            initial = null;
            if (response.statusCode != 206) {
              await response.data!.stream.listen((_) {}).cancel();
              throw _ParallelRangeUnsupported();
            }
            await validate(response, from, end);
            if (response.headers.value('etag') != etag) {
              await response.data!.stream.listen((_) {}).cancel();
              throw const FormatException('分段下载校验已变化');
            }
            final clock = Stopwatch()..start();
            final baseline = bytes.length;
            var lastBytes = baseline;
            var lastTime = Duration.zero;
            var slowWindows = 0;
            if (retries < rangeRetries) {
              watchdog = Timer.periodic(recoveryWindow, (_) {
                final now = clock.elapsed;
                final speed =
                    (bytes.length - lastBytes) *
                    1000000 /
                    (now - lastTime).inMicroseconds;
                // Compare individual ranges rather than cancelling a whole
                // source when other models share the connection's bandwidth.
                final threshold = math.max(
                  16 * 1024,
                  math.min(1024 * 1024, bestRangeSpeed * .2),
                );
                slowWindows = speed < threshold ? slowWindows + 1 : 0;
                bestRangeSpeed = math.max(bestRangeSpeed, speed);
                lastBytes = bytes.length;
                lastTime = now;
                if (slowWindows >= 2) {
                  slow = true;
                  response.requestOptions.cancelToken?.cancel('分段持续降速，续传重连');
                  watchdog?.cancel();
                }
              });
            }
            await for (final chunk in response.data!.stream.timeout(
              idleTimeout,
            )) {
              checkCancelled();
              if (bytes.length + chunk.length > end - start + 1) {
                throw const FormatException('下载内容超过请求范围');
              }
              bytes.add(chunk);
              received += chunk.length;
              onBytes(received);
            }
            if (slow) throw _RangeTooSlow();
            if (bytes.length != end - start + 1) {
              throw const HttpException('模型分段未下载完整');
            }
            if (bytes.length - baseline >= 64 * 1024 &&
                clock.elapsedMilliseconds >= 5) {
              bestRangeSpeed = math.max(
                bestRangeSpeed,
                (bytes.length - baseline) * 1000000 / clock.elapsedMicroseconds,
              );
            }
            return bytes.takeBytes();
          } catch (error) {
            watchdog?.cancel();
            checkCancelled();
            if (local.isCancelled) rethrow;
            // Cancellation may race the final stream-done event. The validated
            // range is already complete if every expected byte was delivered.
            if (slow && bytes.length == end - start + 1) {
              return bytes.takeBytes();
            }
            final transient =
                error is TimeoutException ||
                error is IOException ||
                error is _RangeTooSlow ||
                error is DioException &&
                    (const {
                          DioExceptionType.connectionTimeout,
                          DioExceptionType.sendTimeout,
                          DioExceptionType.receiveTimeout,
                          DioExceptionType.connectionError,
                        }.contains(error.type) ||
                        error.type == DioExceptionType.unknown &&
                            (error.error is IOException ||
                                error.error is TimeoutException));
            if (retries >= rangeRetries || (!slow && !transient)) rethrow;
            retries++;
            // A local reconnect discards the cancelled socket. The explicit
            // fresh request also avoids picking another throttled pooled one.
            if (!slow) {
              await Future<void>.delayed(Duration(milliseconds: 200 * retries));
            }
          } finally {
            watchdog?.cancel();
          }
        }
      }

      var next = firstEnd + 1;
      var active = 0;
      Object? failure;
      final pending = <Future<Uint8List?>>[];
      late void Function() fill;
      Future<Uint8List?> fetch(
        int start, {
        Response<ResponseBody>? initial,
      }) async {
        active++;
        try {
          final end = math.min(start + rangeBytes, total) - 1;
          return await readRange(start, end, initial: initial);
        } catch (error) {
          failure ??= error;
          local.cancel('停止当前来源的分段下载');
          return null;
        } finally {
          active--;
          fill();
        }
      }

      fill = () {
        while (failure == null &&
            !local.isCancelled &&
            pending.length < parallelism * 2 &&
            active < parallelism &&
            next < total) {
          pending.add(fetch(next));
          next += rangeBytes;
        }
      };

      try {
        pending.add(fetch(offset, initial: first));
        fill();
        while (pending.isNotEmpty) {
          // Completion refills network slots even before this ordered write.
          // The bounded look-ahead and per-range recovery prevent a slow early
          // range from leaving all other connections idle indefinitely.
          final chunk = await pending.first;
          if (chunk == null) throw failure!;
          checkCancelled();
          await sink.addStream(Stream.value(chunk));
          pending.removeAt(0);
          fill();
        }
        if (failure != null) throw failure!;
      } finally {
        // Never let an old worker outlive pause, fallback or its file handle.
        local.cancel('分段传输结束');
        await Future.wait(pending);
      }
    } on _ParallelRangeUnsupported {
      retrySequential = true;
    } finally {
      finished = true;
      local.cancel('传输结束');
      try {
        await sink?.flush();
      } finally {
        await sink?.close();
      }
    }
    checkCancelled();
    if (retrySequential) {
      await ModelFileTransfer(
        dio: dio,
        parallelism: 1,
        idleTimeout: idleTimeout,
      ).download(
        url: url,
        total: total,
        partial: partial,
        offset: await partial.length(),
        ifRange: resumeValidator,
        cancel: cancel,
        onValidator: onValidator,
        onBytes: onBytes,
      );
    }
  }
}
