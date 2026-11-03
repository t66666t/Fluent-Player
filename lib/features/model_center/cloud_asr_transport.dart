import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../services/network/network_http.dart';
import 'cloud_asr_types.dart';

extension CloudAsrCancellation on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) throw cancelError!;
  }
}

class _Waiter {
  final ready = Completer<void>();
  bool abandoned = false;
}

/// Shared by profiles using the same account; never logs/stores the key.
class CloudAsrBudget {
  static final _accounts = <String, CloudAsrBudget>{};
  static CloudAsrBudget account(CloudAsrConnection connection) {
    final identity = sha256
        .convert(
          utf8.encode(
            '${connection.provider.name}:${connection.endpoint}:${connection.apiKey}',
          ),
        )
        .toString();
    final budget = _accounts.putIfAbsent(identity, CloudAsrBudget.new);
    budget._users++;
    return budget;
  }

  int _users = 0;
  void releaseSession() {
    if (--_users == 0) {
      _accounts.removeWhere((_, value) => identical(value, this));
    }
  }

  final uploads = CloudAsrGate(1);
  final segments = CloudAsrGate(2);
  DateTime? coolingUntil;
  void limited(Duration delay) {
    segments.limit = 1;
    final until = DateTime.now().add(delay);
    if (coolingUntil == null || coolingUntil!.isBefore(until)) {
      coolingUntil = until;
    }
  }

  Future<void> wait(CancelToken token) async {
    while (true) {
      final until = coolingUntil;
      if (until == null) return;
      final left = until.difference(DateTime.now());
      if (left <= Duration.zero) return;
      await cloudDelay(left, token);
    }
  }
}

class CloudAsrGate {
  CloudAsrGate(this.limit);
  int limit;
  int _active = 0;
  final _queue = Queue<_Waiter>();
  Future<void Function()> acquire(CancelToken token) async {
    token.throwIfCancellationRequested();
    final waiter = _Waiter();
    _queue.add(waiter);
    _wake();
    try {
      await Future.any([
        waiter.ready.future,
        token.whenCancel.then<void>((e) => throw e),
      ]);
      token.throwIfCancellationRequested();
    } catch (_) {
      waiter.abandoned = true;
      if (waiter.ready.isCompleted) _active--;
      _wake();
      rethrow;
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      _active--;
      _wake();
    };
  }

  void _wake() {
    while (_active < limit && _queue.isNotEmpty) {
      final next = _queue.removeFirst();
      if (next.abandoned) continue;
      _active++;
      next.ready.complete();
    }
  }
}

Future<void> cloudDelay(Duration delay, CancelToken token) async {
  token.throwIfCancellationRequested();
  Timer? timer;
  final done = Completer<void>();
  timer = Timer(delay, done.complete);
  try {
    await Future.any([
      done.future,
      token.whenCancel.then<void>((e) => throw e),
    ]);
  } finally {
    timer.cancel();
  }
  token.throwIfCancellationRequested();
}

Duration cloudPollingDelay({
  required String status,
  required int unchangedQueries,
  required Duration age,
  String? retryAfter,
}) {
  final base = Duration(
    seconds: status == 'queued' && age > const Duration(minutes: 1)
        ? 5
        : unchangedQueries.clamp(1, 3),
  );
  final minimum = CloudAsrTransport.retryAfter(retryAfter);
  return minimum != null && minimum > base ? minimum : base;
}

typedef CloudAsrProgress =
    void Function(String phase, String message, double? fraction);

class CloudAsrTransport {
  CloudAsrTransport(
    this.connection, {
    Dio? dio,
    this.uploadIdle = const Duration(seconds: 90),
  }) : dio =
           dio ??
           NetworkHttp.instance.createDio(
             scope: NetworkScope.cloudTranscription,
           ),
       budget = CloudAsrBudget.account(connection) {
    this.dio.options.connectTimeout = const Duration(seconds: 20);
    this.dio.options.sendTimeout = null;
    this.dio.options.receiveTimeout = const Duration(seconds: 30);
  }
  final CloudAsrConnection connection;
  final Dio dio;
  final CloudAsrBudget budget;
  final Duration uploadIdle;
  bool _closed = false;

  Future<Response<dynamic>> request(
    String method,
    String path,
    CancelToken token, {
    dynamic data,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    bool slow = false,
    void Function(int, int)? sent,
    void Function()? beforeSend,
    bool absolute = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      token.throwIfCancellationRequested();
      await budget.wait(token);
      try {
        beforeSend?.call();
        return await dio.request<dynamic>(
          absolute
              ? _trustedUpload(path).toString()
              : connection.url(path).toString(),
          data: data,
          queryParameters: query,
          cancelToken: token,
          onSendProgress: sent,
          options: Options(
            method: method,
            followRedirects: false,
            listFormat: ListFormat.multi,
            receiveTimeout: slow
                ? const Duration(minutes: 15)
                : const Duration(seconds: 30),
            headers: {...connection.headers, ...?headers},
            extra: const {'networkProtectSubmission': true},
          ),
        );
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) rethrow;
        final status = error.response?.statusCode;
        if (status == 429) {
          final delay =
              retryAfter(error.response?.headers.value('retry-after')) ??
              Duration(seconds: math.min(30, 2 << attempt));
          budget.limited(delay);
          // A stream or multipart body cannot be replayed; caller retains its
          // checkpoint and creates a fresh body on an explicit retry.
          if ((method == 'GET' || method == 'DELETE') && attempt < 3) continue;
        }
        if ((method == 'GET' || method == 'DELETE') &&
            attempt < 2 &&
            (status == null ||
                status == 502 ||
                status == 503 ||
                status == 504)) {
          await cloudDelay(Duration(seconds: 1 << attempt), token);
          continue;
        }
        throw safeError(error);
      }
    }
  }

  Uri _trustedUpload(String value) {
    final uri = Uri.parse(value), root = connection.url('/');
    if (uri.scheme != root.scheme ||
        uri.host != root.host ||
        uri.port != root.port ||
        uri.userInfo.isNotEmpty) {
      throw const CloudAsrException('上传会话返回了不可信的地址');
    }
    return uri;
  }

  CloudAsrException safeError(DioException error) {
    final status = error.response?.statusCode;
    final body = jsonEncode(error.response?.data ?? '').toLowerCase();
    final large =
        status == 413 ||
        [400, 422].contains(status) &&
            RegExp(
              r'audio_too_long|duration.{0,25}(limit|exceed)|file.{0,25}too.large',
            ).hasMatch(body);
    final format =
        [400, 415, 422].contains(status) &&
        RegExp(
          r'unsupported.{0,20}(audio|format)|invalid_audio_format|decode.{0,20}fail',
        ).hasMatch(body);
    final message = switch (status) {
      401 => '密钥无效或已失效',
      402 => '账户余额或预算不足',
      403 => '当前账号没有此模型或操作的权限',
      404 => '模型、文件或远端任务不可用，请刷新模型列表或核对账号',
      429 => '请求受限，已降低并发；稍后继续原任务',
      _ when large => '音频超过服务限制，需要重新分段',
      _ when format => '服务无法解码此音频格式',
      null => '网络连接中断或等待超时；已提交的任务将保留',
      _ => '请求失败（HTTP $status），请检查模型和所选选项',
    };
    return CloudAsrException(
      '${connection.provider.label}：$message',
      tooLarge: large,
      format: format,
      statusCode: status,
    );
  }

  Future<Response<dynamic>> upload(
    String path,
    String filePath,
    CancelToken parent, {
    Map<String, dynamic>? fields,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    bool binary = false,
    bool absolute = false,
    bool slow = false,
    required CloudAsrProgress progress,
  }) async {
    final release = await budget.uploads.acquire(parent);
    final token = CancelToken();
    var finished = false, bodySent = false;
    parent.whenCancel.then((e) {
      if (!finished) token.cancel(e);
    });
    Timer? watchdog;
    void touch() {
      watchdog?.cancel();
      if (!bodySent) {
        watchdog = Timer(uploadIdle, () => token.cancel('音频上传超过 90 秒无进展'));
      }
    }

    try {
      final file = File(filePath), bytes = await file.length();
      final mime = audioMime(filePath);
      final dynamic body;
      if (binary) {
        body = file.openRead();
      } else {
        body = FormData.fromMap({
          ...?fields,
          'file': await MultipartFile.fromFile(
            filePath,
            filename: file.uri.pathSegments.last,
            contentType: DioMediaType.parse(mime),
          ),
        }, ListFormat.multi);
      }
      progress('uploading', '正在上传音频', 0);
      return await request(
        'POST',
        path,
        token,
        data: body,
        query: query,
        slow: slow,
        absolute: absolute,
        // Cooldown and gate waits are not stalled uploads. Start the idle
        // clock only when this attempt is about to open/send its request.
        beforeSend: touch,
        headers: {
          if (binary) ...{'Content-Type': mime, 'Content-Length': bytes},
          ...?headers,
        },
        sent: (done, total) {
          if (total > 0 && done >= total) {
            bodySent = true;
            watchdog?.cancel();
            release();
            progress('waiting', '音频已上传，正在识别', null);
          } else {
            touch();
            progress('uploading', '正在上传音频', total > 0 ? done / total : null);
          }
        },
      );
    } on DioException catch (error) {
      if (parent.isCancelled) parent.throwIfCancellationRequested();
      if (token.isCancelled) {
        throw const CloudAsrException('音频上传长时间无进展，已保留任务状态');
      }
      throw safeError(error);
    } finally {
      finished = true;
      watchdog?.cancel();
      release();
    }
  }

  static Duration? retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) return Duration(seconds: math.max(0, seconds));
    try {
      final delay = HttpDate.parse(value).difference(DateTime.now());
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {
      return null;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    dio.close();
    budget.releaseSession();
  }
}

String audioMime(String path) => switch (path.split('.').last.toLowerCase()) {
  'mp3' => 'audio/mpeg',
  'wav' => 'audio/wav',
  'm4a' => 'audio/mp4',
  'aac' => 'audio/aac',
  'flac' => 'audio/flac',
  'ogg' || 'opus' => 'audio/ogg',
  'webm' => 'audio/webm',
  _ => throw const CloudAsrException('音频格式未适配，请重新准备音频'),
};
