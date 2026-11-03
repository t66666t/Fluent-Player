import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../services/network/network_dio_stream.dart';

class _ParallelRangeUnsupported implements Exception {}

/// Bounded parallel ranges with a contiguous on-disk checkpoint. A sliding
/// window buffers at most four 8 MiB chunks; no sparse file looks like a complete
/// model after a crash. Servers without ranges/strong validators use one stream.
class ModelFileTransfer {
  ModelFileTransfer({
    required this.dio,
    this.parallelism = 4,
    this.chunkBytes = 8 * 1024 * 1024,
    this.minimumParallelBytes = 8 * 1024 * 1024,
    this.idleTimeout = const Duration(seconds: 20),
  });

  final Dio dio;
  final int parallelism, chunkBytes, minimumParallelBytes;
  final Duration idleTimeout;

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
      String? validator,
    ) {
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

      Future<Uint8List> read(
        Response<ResponseBody> response,
        int length,
      ) async {
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.data!.stream.timeout(idleTimeout)) {
          checkCancelled();
          if (bytes.length + chunk.length > length) {
            throw const FormatException('下载内容超过请求范围');
          }
          bytes.add(chunk);
          received += chunk.length;
          onBytes(received);
        }
        if (bytes.length != length) throw const HttpException('模型分段未下载完整');
        return bytes.takeBytes();
      }

      final initial = await read(first, firstEnd - offset + 1);
      await sink.addStream(Stream.value(initial));
      var committed = firstEnd + 1;
      var next = committed;
      Object? failure;
      final pending = <Future<Uint8List?>>[];
      Future<Uint8List?> fetch(int start) async {
        try {
          final end = math.min(start + rangeBytes, total) - 1;
          final response = await open(start, end, etag);
          if (response.statusCode != 206) {
            await response.data!.stream.listen((_) {}).cancel();
            throw _ParallelRangeUnsupported();
          }
          await validate(response, start, end);
          if (response.headers.value('etag') != etag) {
            await response.data!.stream.listen((_) {}).cancel();
            throw const FormatException('分段下载校验已变化');
          }
          return await read(response, end - start + 1);
        } catch (error) {
          failure ??= error;
          local.cancel('停止当前来源的分段下载');
          return null;
        }
      }

      void fill() {
        while (failure == null &&
            pending.length < parallelism &&
            next < total) {
          pending.add(fetch(next));
          next += rangeBytes;
        }
      }

      try {
        fill();
        while (pending.isNotEmpty) {
          // Commit in order, then immediately refill this slot instead of
          // waiting for the entire batch. The look-ahead remains bounded even
          // when the earliest chunk stalls.
          final chunk = await pending.first;
          pending.removeAt(0);
          if (chunk == null) throw failure!;
          checkCancelled();
          await sink.addStream(Stream.value(chunk));
          committed += chunk.length;
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
