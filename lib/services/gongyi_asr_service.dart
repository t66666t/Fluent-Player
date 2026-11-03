import 'dart:convert';
import 'package:video_player_app/services/network/network_http.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import '../utils/timed_subtitle_parser.dart';

enum GongyiAsrFailureKind {
  uploadSignature,
  riskControl,

  /// The server rejected the request without identifying the cause (e.g. 412).
  requestRejected,
  networkUnavailable,
  transient,
  rejected,

  /// 服务端因为音频太长或太大拒绝了这一次，调用方应改成更短的片段。
  tooLong,
}

class GongyiAsrException implements Exception {
  final GongyiAsrFailureKind kind;
  final String message;
  final int? statusCode;
  final int? apiCode;
  final String? serverMessage;
  final String? endpoint;
  final bool recoveryExhausted;
  final Duration? retryAfter;
  final bool taskFinished;

  /// Polling already applied its own bounded retries. The queue must not reset
  /// that budget by wrapping it in another automatic retry cycle.
  final bool queryRetryExhausted;

  const GongyiAsrException(
    this.kind,
    this.message, {
    this.statusCode,
    this.apiCode,
    this.serverMessage,
    this.endpoint,
    this.retryAfter,
    this.taskFinished = false,
    this.queryRetryExhausted = false,
    this.recoveryExhausted = false,
  });

  bool get isRiskControl => kind == GongyiAsrFailureKind.riskControl;
  bool get isAccessDenied =>
      isRiskControl || kind == GongyiAsrFailureKind.requestRejected;
  bool get isRateLimited =>
      statusCode == 429 ||
      apiCode?.abs() == 429 ||
      GongyiAsrService._looksLikeRateLimit(serverMessage ?? message);

  String get diagnosticSummary => [
    if (statusCode != null) 'HTTP $statusCode',
    if (apiCode != null) '接口码 $apiCode',
    if (serverMessage?.isNotEmpty == true) '服务端：$serverMessage',
  ].join('；');

  bool get suggestsSegmentation => kind == GongyiAsrFailureKind.tooLong;

  bool get remoteTaskMissing {
    if (statusCode == 404 || statusCode == 410) return true;
    final detail = '$message ${serverMessage ?? ''}';
    return RegExp(
      r'任务.*(不存在|过期|失效|未找到)|未找到.*任务|task.*(not found|expired|does not exist|not exist)',
      caseSensitive: false,
    ).hasMatch(detail);
  }

  @override
  String toString() => message;
}

/// Persisted by the transcription queue, scoped to one source and time slice.
/// A completed upload must not be repeated merely because result polling failed.
/// The queue invalidates its ID on an explicit retry of a failed job.
class GongyiAsrTaskCheckpoint {
  GongyiAsrTaskCheckpoint({
    this.taskId,
    this.onChanged,
    this.lastQueryFailure,
    this.normalizeAudio = false,
  });
  String? taskId;

  /// Also retained after expiry so a compatibility retry cannot revert to the
  /// same original format after a pause or restart.
  bool normalizeAudio;
  Map<String, Object?>? lastQueryFailure;
  Future<void> Function()? onChanged;
  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    if (normalizeAudio) 'normalizeAudio': true,
    if (lastQueryFailure != null) 'lastQueryFailure': lastQueryFailure,
  };
  factory GongyiAsrTaskCheckpoint.fromJson(Map value) =>
      GongyiAsrTaskCheckpoint(
        taskId: value['taskId'] is String ? value['taskId'] as String : null,
        normalizeAudio: value['normalizeAudio'] == true,
        lastQueryFailure: value['lastQueryFailure'] is Map
            ? Map<String, Object?>.from(value['lastQueryFailure'] as Map)
            : null,
      );
  Future<void> setTask(String? id) async {
    taskId = id;
    await onChanged?.call();
  }

  Future<void> recordQueryFailure(GongyiAsrException error) async {
    // Only error metadata: no request headers, cookies, upload URLs or transcript.
    lastQueryFailure = {
      'at': DateTime.now().toUtc().toIso8601String(),
      'kind': error.kind.name,
      if (error.statusCode != null) 'httpStatus': error.statusCode,
      if (error.apiCode != null) 'apiCode': error.apiCode,
      if (error.serverMessage != null) 'serverMessage': error.serverMessage,
      if (error.endpoint != null) 'endpoint': error.endpoint,
    };
    await onChanged?.call();
  }
}

/// Per invocation: concurrent chunks share the selected recovery route, while
/// unrelated tasks and saved settings remain untouched.
class _GongyiRequestSession {
  bool direct = false;
  bool authorizationRefreshed = false;
  String uploadContentType = 'application/octet-stream';

  Map<String, dynamic> get extra => {
    if (direct) NetworkHttp.speechRecognitionDirectRecoveryKey: true,
  };

  bool tryDirect(Object error) {
    if (direct || error is! DioException) return false;
    final context = error.requestOptions.extra['appNetworkContext'];
    if (context is! RequestNetworkContext ||
        context.mode == NetworkMode.direct) {
      return false;
    }
    final failure = GongyiAsrService.classifyDioException(error);
    final selectedRouteUnavailable =
        error.response?.statusCode == 502 &&
        error.response?.headers.value('x-app-network-error') ==
            'selected-route-unavailable';
    if (failure.kind != GongyiAsrFailureKind.networkUnavailable &&
        failure.kind != GongyiAsrFailureKind.uploadSignature &&
        !selectedRouteUnavailable &&
        error.type != DioExceptionType.sendTimeout &&
        error.type != DioExceptionType.receiveTimeout) {
      return false;
    }
    direct = true;
    return true;
  }
}

class GongyiAsrService {
  static const String _baseUrl =
      "https://member.bilibili.com/x/bcut/rubick-interface";
  // Retain the established browser UA. A 412 alone does not identify its cause.
  static const String _userAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

  late final Dio _dio;

  /// 查询结果时遇到访问限制，最多再隔一段时间查几次。
  /// 隔离测试设为 0：第一次拒绝就停，避免连续探测。
  final int maxPollRiskWaits;
  final List<Duration> uploadRetryDelays;
  final Duration resultQueryTimeout;
  final Future<void> Function(Duration)? _resultQueryDelay;

  GongyiAsrService({
    Dio? dio,
    this.maxPollRiskWaits = 4,
    this.uploadRetryDelays = const [Duration(seconds: 1), Duration(seconds: 2)],
    this.resultQueryTimeout = const Duration(minutes: 5),
    Future<void> Function(Duration)? resultQueryDelay,
  }) : _resultQueryDelay = resultQueryDelay {
    _dio =
        dio ??
        NetworkHttp.instance.createDio(
          scope: NetworkScope.speechRecognition,
          options: BaseOptions(
            headers: {
              "User-Agent": _userAgent,
              "Content-Type": "application/json",
              "Accept": "application/json, text/plain, */*",
              "Cache-Control": "no-cache",
            },
            // 增加超时时间，因为上传可能较慢
            sendTimeout: const Duration(minutes: 5),
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(minutes: 5),
          ),
        );
    for (final entry in const {
      'Accept': 'application/json, text/plain, */*',
      'Cache-Control': 'no-cache',
    }.entries) {
      _dio.options.headers.putIfAbsent(entry.key, () => entry.value);
    }
  }

  /// Resolves [prepareAudio] at most once, only when an upload is necessary.
  /// The caller retains ownership of the resulting file and its cleanup.
  Future<List<SubtitleItem>> transcribeAudio(
    String audioPath, {
    bool needWordTimestamp = false,
    bool includeWordTimings = false,
    Function(double progress, String status)? onProgress,
    CancelToken? cancelToken,
    GongyiAsrTaskCheckpoint? checkpoint,
    Future<String> Function()? prepareAudio,
  }) async {
    final session = _GongyiRequestSession();
    File? audioFile;
    int? audioLength;
    try {
      _throwIfCancelled(cancelToken);

      for (var resumeAttempt = 0; ; resumeAttempt++) {
        var taskId = checkpoint?.taskId;
        final resuming = taskId != null && taskId.isNotEmpty;
        if (!resuming) {
          // Poll a saved task first. Only an upload (including an expired
          // task's replacement) needs local extraction or even a local file.
          if (audioFile == null) {
            final path = await prepareAudio?.call() ?? audioPath;
            _throwIfCancelled(cancelToken);
            onProgress?.call(0.0, '检查音频文件...');
            audioFile = File(path);
            if (!await audioFile.exists()) {
              throw const GongyiAsrException(
                GongyiAsrFailureKind.rejected,
                '待识别音频不存在',
              );
            }
            audioLength = await audioFile.length();
            if (audioLength <= 0) {
              throw const GongyiAsrException(
                GongyiAsrFailureKind.rejected,
                '待识别音频为空文件',
              );
            }
          }
          _throwIfCancelled(cancelToken);
          final downloadUrl = await _uploadWithRecovery(
            audioFile,
            audioLength!,
            session,
            cancelToken: cancelToken,
            onProgress: onProgress,
          );

          onProgress?.call(0.6, "创建转录任务...");

          // 5. 创建ASR任务
          // Task creation is outside upload recovery: an uncertain submission
          // must not be blindly replayed on another route.
          taskId = await _createTask(
            downloadUrl,
            session: session,
            cancelToken: cancelToken,
          );
          await checkpoint?.setTask(taskId);
        } else {
          onProgress?.call(0.7, '继续查询上次已提交的识别任务，不会重新上传');
        }

        onProgress?.call(0.7, "等待转录结果...");
        final recognitionWatch = Stopwatch()..start();

        // 6. 查询任务结果
        try {
          final result = await _queryTaskResult(
            taskId,
            (retryCount, maxRetries) {
              // The service exposes no completion percentage. Polls are not work.
              final elapsed = recognitionWatch.elapsed;
              final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
              final seconds = (elapsed.inSeconds % 60).toString().padLeft(
                2,
                '0',
              );
              onProgress?.call(0.7, '等待识别结果 · 已等待 $minutes:$seconds');
            },
            cancelToken: cancelToken,
            session: session,
            onFailure: checkpoint?.recordQueryFailure,
            onStatus: (message) {
              final elapsed = recognitionWatch.elapsed;
              final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
              final seconds = (elapsed.inSeconds % 60).toString().padLeft(
                2,
                '0',
              );
              onProgress?.call(0.7, '$message · 已等待 $minutes:$seconds');
            },
          );

          onProgress?.call(0.9, "解析字幕结果...");

          // 7. 解析结果
          return _parseSubtitleResult(
            result,
            needWordTimestamp,
            includeWordTimings,
          );
        } on GongyiAsrException catch (error) {
          final missing = error.remoteTaskMissing;
          if (error.taskFinished || missing) await checkpoint?.setTask(null);
          if (missing && resuming && resumeAttempt == 0) {
            onProgress?.call(0.1, '上次识别任务已过期，正在使用本地音频重新提交');
            continue;
          }
          rethrow;
        }
      }
    } catch (e) {
      // 简单的错误处理
      if (e is DioException && CancelToken.isCancel(e)) {
        rethrow;
      }
      if (e is DioException) throw classifyDioException(e);
      rethrow;
    }
  }

  Future<String> _uploadWithRecovery(
    File audioFile,
    int audioLength,
    _GongyiRequestSession session, {
    CancelToken? cancelToken,
    Function(double progress, String status)? onProgress,
  }) async {
    var progress = 0.1;
    void report(double next, String message) {
      if (next > progress) progress = next;
      onProgress?.call(progress, message);
    }

    while (true) {
      _throwIfCancelled(cancelToken);
      try {
        report(0.1, '请求上传授权...');
        final auth = await _requestUploadAuth(
          audioLength,
          fileType: audioFile.path.toLowerCase().endsWith('.mp3')
              ? 'mp3'
              : 'm4a',
          session: session,
          cancelToken: cancelToken,
        );
        report(0.2, '上传音频文件...');
        final etags = await _uploadAudioChunks(
          audioFile,
          audioLength,
          auth,
          (sent, total) => report(
            0.2 + sent / total * 0.3,
            '上传音频 ${(sent / total * 100).floor()}% · '
            '${(sent / (1024 * 1024)).toStringAsFixed(1)}/${(total / (1024 * 1024)).toStringAsFixed(1)} MB',
          ),
          session: session,
          cancelToken: cancelToken,
          onStatus: (message) => report(progress, message),
        );
        report(0.5, '提交上传...');
        return await _commitUpload(
          auth,
          etags,
          session: session,
          cancelToken: cancelToken,
        );
      } catch (error) {
        _throwIfCancelled(cancelToken);
        final failure = error is DioException
            ? classifyDioException(error)
            : error;
        // A changed/expired upload authorization is independent of proxy choice.
        // Refresh once on the original route before attempting another route.
        if (failure is GongyiAsrException &&
            failure.kind == GongyiAsrFailureKind.uploadSignature &&
            !session.authorizationRefreshed &&
            !session.direct) {
          session.authorizationRefreshed = true;
          report(progress, '上传授权校验失败，正在重新获取上传授权后重试');
          continue;
        }
        if (session.tryDirect(error)) {
          report(progress, '上传连接或授权校验异常，正在尝试不使用系统代理并重新获取上传授权');
          continue;
        }
        if (session.direct && failure is GongyiAsrException) {
          throw GongyiAsrException(
            failure.kind,
            '已尝试不使用系统代理，仍未完成上传：${failure.message}',
            statusCode: failure.statusCode,
            apiCode: failure.apiCode,
            serverMessage: failure.serverMessage,
            endpoint: failure.endpoint,
            recoveryExhausted: true,
          );
        }
        rethrow;
      }
    }
  }

  static GongyiAsrException classifyDioException(DioException error) {
    final status = error.response?.statusCode;
    final body = error.response?.data;
    final detail = _serverDetail(body);
    final apiCode = body is Map ? _parseApiCode(body['code']) : null;
    final endpoint = error.requestOptions.uri.path;
    final retryAfter = parseRetryAfter(
      error.response?.headers.value('retry-after'),
    );
    if (status == 403 && _isUploadAuthorizationFailure(body)) {
      return GongyiAsrException(
        GongyiAsrFailureKind.uploadSignature,
        '音频上传授权校验失败（HTTP 403）。可能是签名请求头不匹配、授权失效或代理链路影响，不能仅凭此错误确定是网络问题',
        statusCode: status,
        apiCode: apiCode,
        serverMessage: detail,
        endpoint: endpoint,
      );
    }
    final denied = _classifyServerRejection(
      statusCode: status,
      apiCode: apiCode,
      detail: detail,
      endpoint: endpoint,
      retryAfter: retryAfter,
    );
    if (denied != null) return denied;
    if (_looksLikeTooLong(detail)) {
      return GongyiAsrException(
        GongyiAsrFailureKind.tooLong,
        '音频超过了服务端长度限制${status == null ? '' : ' ($status)'}',
        statusCode: status,
        apiCode: apiCode,
        serverMessage: detail,
        endpoint: endpoint,
        retryAfter: retryAfter,
      );
    }
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.error is SocketException ||
        error.error is HandshakeException ||
        error.error is TlsException) {
      return GongyiAsrException(
        GongyiAsrFailureKind.networkUnavailable,
        '当前网络不可用或无法连接到字幕服务，请检查网络后重试',
        endpoint: endpoint,
      );
    }
    // 上传或查询超时通常是链路慢，不是这段音频本身不能识别。
    // 以前会落到“永久拒绝”，任务不会自动重试。
    if (error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        status == 408) {
      return GongyiAsrException(
        GongyiAsrFailureKind.transient,
        '字幕服务响应超时，请稍后重试',
        statusCode: status,
        apiCode: apiCode,
        serverMessage: detail,
        endpoint: endpoint,
        retryAfter: retryAfter,
      );
    }
    final kind = status != null && status >= 500
        ? GongyiAsrFailureKind.transient
        : GongyiAsrFailureKind.rejected;
    return GongyiAsrException(
      kind,
      '字幕服务请求失败${status == null ? '' : ' (HTTP $status)'}'
      '${detail.isEmpty ? '' : '：$detail'}',
      statusCode: status,
      apiCode: apiCode,
      serverMessage: detail,
      endpoint: endpoint,
      retryAfter: retryAfter,
    );
  }

  static bool _isUploadAuthorizationFailure(Object? body) {
    final text = body is String
        ? body
        : body is Map
        ? jsonEncode(body)
        : '';
    return RegExp(
      r'SignatureDoesNotMatch|RequestExpired|ExpiredToken|RequestTimeTooSkewed',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// Only accept the unambiguous V2 PUT string-to-sign layout. Do not guess
  /// headers from a generic 403 or echo server-provided paths/credentials.
  static String? _expectedUploadContentType(Object? body) {
    String? value;
    if (body is String) {
      value = RegExp(
        r'<StringToSign>([\s\S]*?)</StringToSign>',
      ).firstMatch(body)?.group(1);
      if (value?.startsWith('<![CDATA[') == true && value!.endsWith(']]>')) {
        value = value.substring(9, value.length - 3);
      }
      value = value?.replaceAll('&#10;', '\n').replaceAll('&#13;', '\r');
    } else if (body is Map) {
      value = body['StringToSign'] is String
          ? body['StringToSign'] as String
          : null;
    }
    final lines = value?.replaceAll('\r\n', '\n').split('\n');
    if (lines == null ||
        lines.length < 5 ||
        lines[0] != 'PUT' ||
        lines[1].isNotEmpty ||
        !RegExp(r'^\d+$').hasMatch(lines[3]) ||
        !lines[4].startsWith('/')) {
      return null;
    }
    final type = lines[2];
    if (type.isEmpty) return '';
    return type.length <= 128 &&
            RegExp(r'^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$').hasMatch(type)
        ? type
        : null;
  }

  static int? _parseApiCode(Object? code) =>
      code is int ? code : int.tryParse(code?.toString() ?? '');

  /// A server's minimum wait must not be shortened by our local backoff.
  static Duration? parseRetryAfter(String? value, {DateTime? now}) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) {
      return seconds < 0 ? null : Duration(seconds: seconds.clamp(0, 86400));
    }
    try {
      final delay = HttpDate.parse(value).difference(now ?? DateTime.now());
      return delay > Duration.zero ? delay : Duration.zero;
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  static GongyiAsrException? _classifyServerRejection({
    int? statusCode,
    int? apiCode,
    required String detail,
    String? endpoint,
    Duration? retryAfter,
  }) {
    final limited =
        statusCode == 429 ||
        apiCode?.abs() == 429 ||
        _looksLikeRateLimit(detail);
    final explicitRisk = _looksLikeRiskControl(detail);
    final unconfirmed = statusCode == 412 || apiCode?.abs() == 412;
    // Prefer an explicit media-length failure over guessing what 412 means.
    if (!limited && !explicitRisk && unconfirmed && _looksLikeTooLong(detail)) {
      return null;
    }
    if (!limited && !explicitRisk && !unconfirmed) return null;
    final reason = limited
        ? '服务端限制了请求频率'
        : explicitRisk
        ? '服务端报告安全拦截'
        : '服务端拒绝了请求（412，原因尚未确认）';
    return GongyiAsrException(
      limited || explicitRisk
          ? GongyiAsrFailureKind.riskControl
          : GongyiAsrFailureKind.requestRejected,
      '$reason${detail.isEmpty ? '' : '：$detail'}',
      statusCode: statusCode,
      apiCode: apiCode,
      serverMessage: detail,
      endpoint: endpoint,
      retryAfter: retryAfter,
    );
  }

  static String _serverDetail(Object? body, {bool includeResult = false}) {
    var text = body is Map
        ? [
            for (final key in [
              'message',
              'msg',
              'error',
              'remark',
              if (includeResult) 'result',
            ])
              if (body[key] != null) _payloadDetail(body[key]),
          ].join(' ')
        : body is String
        ? body
        : '';
    text = text
        .replaceAll(
          RegExp(
            r'<(script|style)\b[^>]*>.*?</\1>',
            caseSensitive: false,
            dotAll: true,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'https?://\S+'), '[链接]')
        .replaceAll(
          RegExp(
            r'\b(?:proxy-)?authorization\s*[=:]\s*(?:(?:basic|bearer)\s+)?[^\s;,]+',
            caseSensitive: false,
          ),
          '[凭据已隐藏]',
        )
        .replaceAll(
          RegExp(
            r'\b(SESSDATA|bili_jct|token|cookie|authorization|task_id)\s*[=:]\s*[^\s;,]+',
            caseSensitive: false,
          ),
          '[凭据已隐藏]',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return text.length > 180 ? '${text.substring(0, 180)}…' : text;
  }

  /// 把任务查询接口里 state=5 的正文还原成可区分的失败，而不是一句“转录任务失败”。
  static GongyiAsrException classifyTaskPayload(Object? payload) {
    final detail = _serverDetail(payload, includeResult: true);
    final denied = _classifyServerRejection(
      detail: detail,
      apiCode: payload is Map ? _parseApiCode(payload['code']) : null,
    );
    if (denied != null) return denied;
    if (_looksLikeTooLong(detail)) {
      return GongyiAsrException(
        GongyiAsrFailureKind.tooLong,
        detail.isEmpty ? '音频超过了服务端长度限制' : detail,
      );
    }
    final lower = detail.toLowerCase();
    if (lower.contains('超时') ||
        lower.contains('timeout') ||
        lower.contains('繁忙')) {
      return GongyiAsrException(
        GongyiAsrFailureKind.transient,
        detail.isEmpty ? '转录等待超时，可稍后重试' : detail,
      );
    }
    if (detail.isEmpty) {
      return const GongyiAsrException(
        GongyiAsrFailureKind.rejected,
        '服务端拒绝了这段音频，没有说明原因',
      );
    }
    return GongyiAsrException(GongyiAsrFailureKind.rejected, detail);
  }

  static bool _looksLikeRiskControl(String value) {
    final normalized = _withoutNegatedRisk(value);
    return RegExp(
          r'风控.{0,12}(拦截|拒绝|限制|失败|未通过)|触发.{0,12}风控|被.{0,4}风控',
        ).hasMatch(normalized) ||
        normalized.contains('security control policy') ||
        normalized.contains('request was banned') ||
        _looksLikeRateLimit(normalized);
  }

  static String _withoutNegatedRisk(String value) =>
      value.toLowerCase().replaceAll(
        RegExp(
          r'(未|没有)(触发)?风控|not\s+(rate[- ]?limited|blocked)|no\s+rate\s+limit',
        ),
        '',
      );

  static bool _looksLikeRateLimit(String value) {
    final normalized = _withoutNegatedRisk(value);
    return normalized.contains('请求过于频繁') ||
        normalized.contains('访问过于频繁') ||
        normalized.contains('请求频繁') ||
        normalized.contains('访问频繁') ||
        normalized.contains('too many requests') ||
        RegExp(
          r'\brate[- ]limit(?:ed|\s+(?:exceeded|reached))\b',
        ).hasMatch(normalized);
  }

  /// 时长和体积要同时像“超限”才算。单看“文件”会把“文件不存在”误判成过长。
  static bool _looksLikeTooLong(String value) {
    final normalized = value.toLowerCase();
    final mentionsMedia =
        normalized.contains('音频') ||
        normalized.contains('时长') ||
        normalized.contains('文件') ||
        normalized.contains('资源') ||
        normalized.contains('audio') ||
        normalized.contains('duration') ||
        normalized.contains('length');
    final mentionsLimit =
        normalized.contains('过长') ||
        normalized.contains('太长') ||
        normalized.contains('超出') ||
        normalized.contains('超过') ||
        normalized.contains('限制') ||
        normalized.contains('too long') ||
        normalized.contains('exceed');
    return mentionsMedia && mentionsLimit;
  }

  static String _payloadDetail(Object? payload) {
    if (payload == null) return '';
    if (payload is Map) {
      final parts = <String>[
        for (final key in ['remark', 'message', 'msg', 'error', 'result'])
          if (payload[key] != null) _payloadDetail(payload[key]),
      ].where((part) => part.isNotEmpty);
      return parts.join(' ').trim();
    }
    final text = payload.toString().trim();
    if (text.startsWith('{') && text.length < 2000) {
      try {
        return _payloadDetail(jsonDecode(text));
      } catch (_) {
        return text;
      }
    }
    if (text.length > 180) return text.substring(0, 180);
    return text;
  }

  Never _throwApiFailure(
    String operation,
    Object? code,
    Object? message, {
    int? statusCode,
    String? endpoint,
    Duration? retryAfter,
  }) {
    final text = _serverDetail({'message': message});
    final apiCode = _parseApiCode(code);
    final denied = _classifyServerRejection(
      apiCode: apiCode,
      detail: text,
      statusCode: statusCode,
      endpoint: endpoint,
      retryAfter: retryAfter,
    );
    if (denied != null) throw denied;
    if (_looksLikeTooLong(text)) {
      throw GongyiAsrException(
        GongyiAsrFailureKind.tooLong,
        text.isEmpty ? '$operation时音频超过了服务端长度限制' : text,
      );
    }
    if (apiCode == 139201 || text.contains('第三方服务异常')) {
      throw GongyiAsrException(
        GongyiAsrFailureKind.transient,
        '$operation时第三方存储服务暂时异常，请稍后重试'
        '${code == null ? '' : ' (Code: $code)'}',
        apiCode: apiCode,
        serverMessage: text,
        statusCode: statusCode,
        endpoint: endpoint,
        retryAfter: retryAfter,
      );
    }
    if (text.isEmpty || text == '未知错误') {
      throw GongyiAsrException(
        GongyiAsrFailureKind.rejected,
        '$operation失败，服务端没有说明原因',
      );
    }
    throw GongyiAsrException(
      GongyiAsrFailureKind.rejected,
      '$operation失败：$text${code == null ? '' : ' (Code: $code)'}',
      apiCode: apiCode,
      serverMessage: text,
      statusCode: statusCode,
      endpoint: endpoint,
      retryAfter: retryAfter,
    );
  }

  // 请求上传授权
  Future<Map<String, dynamic>> _requestUploadAuth(
    int fileSize, {
    String fileType = 'm4a',
    required _GongyiRequestSession session,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post(
      "$_baseUrl/resource/create",
      options: Options(extra: session.extra),
      data: jsonEncode({
        "type": 2,
        "name": "audio.$fileType",
        "size": fileSize,
        "ResourceFileType": fileType,
        "model_id": "8",
      }),
      cancelToken: cancelToken,
    );

    final body = _expectJsonBody(response.data, '请求上传授权');
    if (body['code'] != 0) {
      _throwApiFailure('请求上传授权', body['code'], body['message']);
    }
    final data = body['data'];
    if (data is! Map) {
      throw const GongyiAsrException(
        GongyiAsrFailureKind.transient,
        '请求上传授权返回了无法识别的数据',
      );
    }
    return Map<String, dynamic>.from(data);
  }

  Map<String, dynamic> _expectJsonBody(Object? data, String operation) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw GongyiAsrException(
      GongyiAsrFailureKind.transient,
      '$operation返回了无法识别的数据',
    );
  }

  // 分块上传音频
  Future<List<String>> _uploadAudioChunks(
    File audioFile,
    int audioLength,
    Map<String, dynamic> uploadAuth,
    Function(int uploaded, int total) onProgress, {
    required _GongyiRequestSession session,
    CancelToken? cancelToken,
    void Function(String message)? onStatus,
  }) async {
    final urlsRaw = uploadAuth['upload_urls'];
    final perSizeRaw = uploadAuth['per_size'];
    if (urlsRaw is! List || perSizeRaw is! num) {
      throw const GongyiAsrException(
        GongyiAsrFailureKind.rejected,
        '服务端返回了无效的分块上传参数',
      );
    }
    final int clips = urlsRaw.length;
    final int perSize = perSizeRaw.round();
    final List<String> uploadUrls = List<String>.from(urlsRaw);
    if (clips <= 0 ||
        perSize <= 0 ||
        (audioLength + perSize - 1) ~/ perSize != clips) {
      throw const GongyiAsrException(
        GongyiAsrFailureKind.rejected,
        '服务端返回了无效的分块上传参数',
      );
    }

    // Storage uploads are independent; keep at most two buffers/requests in
    // flight. ASR task creation and result polling remain sequential.
    final etags = List<String>.filled(clips, '');
    final sent = List<int>.filled(clips, 0);
    var nextIndex = 0;
    var stopped = false;
    var totalUploaded = 0;
    var progressBytes = 0;
    var lastProgressMs = -100;
    final progressClock = Stopwatch()..start();
    void report(int index, int bytes) {
      final offset = index * perSize;
      final size = audioLength - offset < perSize
          ? audioLength - offset
          : perSize;
      final value = bytes.clamp(0, size);
      if (value <= sent[index]) return;
      progressBytes += value - sent[index];
      sent[index] = value;
      final now = progressClock.elapsedMilliseconds;
      if (progressBytes == audioLength || now - lastProgressMs >= 100) {
        lastProgressMs = now;
        onProgress(progressBytes, audioLength);
      }
    }

    Future<void> worker() async {
      final reader = await audioFile.open();
      try {
        while (!stopped && nextIndex < clips) {
          final i = nextIndex++;
          _throwIfCancelled(cancelToken);
          final offset = i * perSize;
          final remaining = audioLength - offset;
          final chunkSize = remaining < perSize ? remaining : perSize;
          await reader.setPosition(offset);
          final Uint8List chunk = await reader.read(chunkSize);
          if (chunk.length != chunkSize) {
            throw const GongyiAsrException(
              GongyiAsrFailureKind.rejected,
              '读取待上传音频时提前到达文件末尾',
            );
          }

          late Response<dynamic> response;
          var headerCorrected = false;
          for (var attempt = 0; ; attempt++) {
            _throwIfCancelled(cancelToken);
            if (stopped) return;
            try {
              final request =
                  Options(
                    method: 'PUT',
                    sendTimeout: const Duration(minutes: 2),
                    receiveTimeout: const Duration(seconds: 45),
                    contentType: session.uploadContentType,
                    headers: {'Content-Length': chunk.length},
                    responseType: ResponseType.plain,
                    followRedirects: false,
                    extra: session.extra,
                  ).compose(
                    _dio.options,
                    uploadUrls[i],
                    data: chunk,
                    cancelToken: cancelToken,
                    onSendProgress: (count, _) => report(i, count),
                  );
              // Keep API credentials/query defaults out of signed storage PUTs.
              request.queryParameters.clear();
              request.headers.removeWhere(
                (name, _) =>
                    [
                      'authorization',
                      'cookie',
                      'proxy-authorization',
                    ].contains(name.toLowerCase()) ||
                    name.toLowerCase() == Headers.contentTypeHeader &&
                        session.uploadContentType.isEmpty,
              );
              response = await _dio.fetch<dynamic>(request);
              if (response.headers.value('etag') == null) {
                throw const GongyiAsrException(
                  GongyiAsrFailureKind.transient,
                  '上传分块没有返回校验值',
                );
              }
              break;
            } catch (error) {
              if (error is DioException && CancelToken.isCancel(error)) rethrow;
              final classified = error is DioException
                  ? classifyDioException(error)
                  : error;
              if (!headerCorrected &&
                  error is DioException &&
                  classified is GongyiAsrException &&
                  classified.kind == GongyiAsrFailureKind.uploadSignature) {
                final expected = _expectedUploadContentType(
                  error.response?.data,
                );
                if (expected != null &&
                    expected != (error.requestOptions.contentType ?? '')) {
                  headerCorrected = true;
                  session.uploadContentType = expected;
                  onStatus?.call('上传签名要求的请求头与当前值不同，正在校正后重试这一块');
                  continue;
                }
              }
              final retryable =
                  classified is GongyiAsrException &&
                  [
                    GongyiAsrFailureKind.networkUnavailable,
                    GongyiAsrFailureKind.transient,
                  ].contains(classified.kind);
              if (!retryable ||
                  stopped ||
                  attempt >= uploadRetryDelays.length) {
                rethrow;
              }
              onStatus?.call('上传第 ${i + 1}/$clips 块时网络中断，正在重试这一块，已完成的块会保留');
              await _cancelableDelay(uploadRetryDelays[attempt], cancelToken);
            }
          }

          String? etag = response.headers.value('etag');
          if (etag != null) {
            // 提交时使用不带引号的 ETag 值。
            etag = etag.replaceAll('"', '');
            etags[i] = etag;
          } else {
            throw GongyiAsrException(
              GongyiAsrFailureKind.transient,
              '分块 ${i + 1} 上传后没有返回校验值，请稍后重试',
            );
          }

          totalUploaded += chunk.length;
          report(i, chunk.length);
        }
      } catch (_) {
        stopped = true;
        rethrow;
      } finally {
        await reader.close();
      }
    }

    // Wait for both workers to settle before retrying or deleting the file.
    await Future.wait([worker(), if (clips > 1) worker()]);

    if (etags.any((etag) => etag.isEmpty) || totalUploaded != audioLength) {
      throw GongyiAsrException(
        GongyiAsrFailureKind.transient,
        '上传校验失败: 分块数量不匹配 (${etags.length}/$clips)，请稍后重试',
      );
    }

    return etags;
  }

  // 提交上传
  Future<String> _commitUpload(
    Map<String, dynamic> uploadAuth,
    List<String> etags, {
    required _GongyiRequestSession session,
    CancelToken? cancelToken,
  }) async {
    // ETags 按上传协议使用逗号分隔的字符串，JSON 数组格式会触发 139201。
    final primary = await _commitUploadAttempt(
      uploadAuth,
      etags.join(','),
      session: session,
      cancelToken: cancelToken,
    );
    final primaryBody = _expectJsonBody(primary.data, '提交上传');
    if (primaryBody['code'] == 0) {
      final data = primaryBody['data'];
      final url = data is Map ? data['download_url']?.toString() : null;
      if (url == null || url.isEmpty) {
        throw const GongyiAsrException(
          GongyiAsrFailureKind.transient,
          '提交上传成功，但没有返回音频地址',
        );
      }
      return url;
    }

    final firstCode = primaryBody['code'];
    final firstMessage = primaryBody['message']?.toString() ?? '';
    if (!_shouldTryAlternateEtags(firstCode, firstMessage)) {
      _throwApiFailure('提交上传', firstCode, firstMessage);
    }

    // 给对象存储的分片状态一点传播时间，然后只做一次格式兼容重试。
    // 取消信号在等待期间仍然有效，不会阻塞“暂停全部”。
    await _cancelableDelay(const Duration(milliseconds: 800), cancelToken);
    final fallback = await _commitUploadAttempt(
      uploadAuth,
      jsonEncode(etags),
      session: session,
      cancelToken: cancelToken,
    );
    final fallbackBody = _expectJsonBody(fallback.data, '提交上传');
    if (fallbackBody['code'] == 0) {
      final data = fallbackBody['data'];
      final url = data is Map ? data['download_url']?.toString() : null;
      if (url == null || url.isEmpty) {
        throw const GongyiAsrException(
          GongyiAsrFailureKind.transient,
          '提交上传成功，但没有返回音频地址',
        );
      }
      return url;
    }
    _throwApiFailure('提交上传', fallbackBody['code'], fallbackBody['message']);
  }

  Future<Response<dynamic>> _commitUploadAttempt(
    Map<String, dynamic> uploadAuth,
    String etags, {
    required _GongyiRequestSession session,
    CancelToken? cancelToken,
  }) {
    return _dio.post(
      "$_baseUrl/resource/create/complete",
      options: Options(extra: session.extra),
      data: {
        "InBossKey": uploadAuth['in_boss_key'],
        "ResourceId": uploadAuth['resource_id'],
        "Etags": etags,
        "UploadId": uploadAuth['upload_id'],
        "model_id": "8",
      },
      cancelToken: cancelToken,
    );
  }

  bool _shouldTryAlternateEtags(Object? code, String message) {
    if (code == 139201) return true;
    if (code == -412 || code == 412 || code == 429) return false;
    final normalized = message.toLowerCase();
    if (_looksLikeRiskControl(normalized)) return false;
    return normalized.contains('etag') ||
        normalized.contains('参数') ||
        normalized.contains('格式') ||
        normalized.contains('第三方服务异常');
  }

  // 创建ASR任务
  Future<String> _createTask(
    String downloadUrl, {
    required _GongyiRequestSession session,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.post(
      "$_baseUrl/task",
      options: Options(extra: session.extra),
      data: {"resource": downloadUrl, "model_id": "8"},
      cancelToken: cancelToken,
    );

    final body = _expectJsonBody(response.data, '创建转录任务');
    if (body['code'] != 0) {
      _throwApiFailure('创建转录任务', body['code'], body['message']);
    }
    final data = body['data'];
    final taskId = data is Map ? data['task_id']?.toString() : null;
    if (taskId == null || taskId.isEmpty) {
      throw const GongyiAsrException(
        GongyiAsrFailureKind.transient,
        '创建转录任务成功，但没有返回任务编号',
      );
    }
    return taskId;
  }

  // 查询任务结果。音频已经上传成功，查询阶段的断网或风控只重试这一次查询，
  // 避免把同一段音频再传一遍。
  Future<Map<String, dynamic>> _queryTaskResult(
    String taskId,
    Function(int retryCount, int maxRetries) onRetry, {
    required _GongyiRequestSession session,
    CancelToken? cancelToken,
    void Function(String message)? onStatus,
    Future<void> Function(GongyiAsrException)? onFailure,
  }) async {
    int retryCount = 0;
    int transportFailures = 0;
    int riskWaits = 0;
    int rejectedWaits = 0;
    const maxRetries = 120;
    const maxTransportFailures = 6;
    final watch = Stopwatch()..start();
    GongyiAsrFailureKind? lastFailureKind;
    int? lastStatusCode;
    GongyiAsrException? lastFailure;
    final queryCancellation = CancelToken();
    _throwIfCancelled(cancelToken);
    cancelToken?.whenCancel.then((error) => queryCancellation.cancel(error));

    GongyiAsrException stopped(
      GongyiAsrFailureKind kind,
      String reason,
    ) => GongyiAsrException(
      kind,
      '$reason${lastFailure?.diagnosticSummary.isNotEmpty == true ? '（${lastFailure!.diagnosticSummary}）' : ''}'
      '，已停止本次查询。识别任务已保留，失败后点重试将重新提交未完成片段',
      statusCode: lastStatusCode,
      apiCode: lastFailure?.apiCode,
      serverMessage: lastFailure?.serverMessage,
      endpoint: lastFailure?.endpoint,
      retryAfter: lastFailure?.retryAfter,
      queryRetryExhausted: true,
    );

    Duration remainingBudget() {
      _throwIfCancelled(queryCancellation);
      final remaining = resultQueryTimeout - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw stopped(
          lastFailureKind ?? GongyiAsrFailureKind.transient,
          '获取结果已达到等待时限',
        );
      }
      return remaining;
    }

    Future<void> waitBeforeQuery(Duration delay, String reason) async {
      var remaining = delay;
      while (remaining > Duration.zero) {
        final budget = remainingBudget();
        var step = remaining < const Duration(seconds: 1)
            ? remaining
            : const Duration(seconds: 1);
        if (step > budget) step = budget;
        final seconds = (remaining.inMicroseconds / 1000000).ceil();
        onStatus?.call('$reason · $seconds 秒后继续查询');
        await _cancelableDelay(
          step,
          queryCancellation,
          delay: _resultQueryDelay,
        );
        remaining -= step;
      }
    }

    try {
      while (retryCount < maxRetries) {
        final budget = remainingBudget();
        try {
          // Include connection stalls and slow responses in the same deadline,
          // and abort the in-flight request when that deadline expires.
          final response = await _dio
              .get<dynamic>(
                "$_baseUrl/task/result",
                options: Options(
                  receiveTimeout: const Duration(seconds: 30),
                  extra: session.extra,
                ),
                queryParameters: {"model_id": "8", "task_id": taskId},
                cancelToken: queryCancellation,
              )
              .timeout(
                budget,
                onTimeout: () {
                  queryCancellation.cancel('结果查询达到等待时限');
                  throw stopped(
                    lastFailureKind ?? GongyiAsrFailureKind.transient,
                    '获取结果已达到等待时限',
                  );
                },
              );

          final body = response.data;
          if (body is! Map) {
            throw const GongyiAsrException(
              GongyiAsrFailureKind.transient,
              '字幕服务返回了无法识别的结果',
            );
          }
          final code = body['code'];
          if (code != null && _parseApiCode(code) != 0) {
            _throwApiFailure(
              '查询转录结果',
              code,
              body['message'],
              statusCode: response.statusCode,
              endpoint: response.requestOptions.uri.path,
              retryAfter: parseRetryAfter(
                response.headers.value('retry-after'),
              ),
            );
          }
          final data = body['data'];
          if (data is! Map) {
            throw const GongyiAsrException(
              GongyiAsrFailureKind.transient,
              '字幕服务返回了无法识别的结果',
            );
          }
          if (data['state'] == 4) {
            return _decodeResultMap(data['result']);
          }
          if (data['state'] == 5) {
            final failure = classifyTaskPayload(data);
            throw GongyiAsrException(
              failure.kind,
              failure.message,
              statusCode: failure.statusCode,
              apiCode: failure.apiCode,
              serverMessage: failure.serverMessage ?? failure.message,
              endpoint: response.requestOptions.uri.path,
              taskFinished: true,
            );
          }

          retryCount++;
          transportFailures = 0;
          lastFailureKind = null;
          lastStatusCode = null;
          lastFailure = null;
          onRetry(retryCount, maxRetries);
          final reason = switch (data['state']) {
            1 => '服务器正在排队',
            2 => '服务器正在识别',
            _ => '等待识别结果',
          };
          final delaySeconds = 2 + (retryCount ~/ 10).clamp(0, 4);
          await waitBeforeQuery(Duration(seconds: delaySeconds), reason);
        } catch (error) {
          if (error is DioException && CancelToken.isCancel(error)) rethrow;
          final failure = error is DioException
              ? classifyDioException(error)
              : error;
          if (failure is! GongyiAsrException) rethrow;
          if (failure.queryRetryExhausted ||
              failure.taskFinished ||
              failure.remoteTaskMissing) {
            if (!failure.queryRetryExhausted) await onFailure?.call(failure);
            throw failure;
          }
          if (session.tryDirect(error)) {
            onStatus?.call('结果查询连接异常，正在尝试不使用系统代理，继续查询已提交任务，不会重新上传');
            continue;
          }
          lastFailureKind = failure.kind;
          lastStatusCode = failure.statusCode;
          lastFailure = failure;
          await onFailure?.call(failure);
          String withEvidence(String reason) =>
              failure.diagnosticSummary.isEmpty
              ? reason
              : '$reason（${failure.diagnosticSummary}）';
          Duration advisedWait(Duration fallback) =>
              failure.retryAfter != null && failure.retryAfter! > fallback
              ? failure.retryAfter!
              : fallback;
          if (failure.isRiskControl) {
            riskWaits++;
            if (riskWaits > maxPollRiskWaits) {
              throw stopped(
                failure.kind,
                failure.isRateLimited ? '查询结果持续受到频率限制' : '查询结果持续被服务端安全策略拦截',
              );
            }
            const waitSeconds = [15, 30, 60, 90];
            final index = (riskWaits - 1).clamp(0, waitSeconds.length - 1);
            await waitBeforeQuery(
              advisedWait(Duration(seconds: waitSeconds[index])),
              withEvidence(
                failure.isRateLimited
                    ? '查询结果受到频率限制，等待后重查，不会重新上传'
                    : '查询结果被服务端安全策略拦截，等待后重查，不会重新上传',
              ),
            );
          } else if (failure.kind == GongyiAsrFailureKind.requestRejected) {
            // An unexplained 412 is not proof of rate limiting. Only one short
            // retry; repeating identical refused requests rarely helps.
            rejectedWaits++;
            if (rejectedWaits > 1 || maxPollRiskWaits == 0) {
              throw stopped(failure.kind, '查询请求再次被拒绝，原因尚未确认');
            }
            await waitBeforeQuery(
              advisedWait(const Duration(seconds: 3)),
              withEvidence('查询请求被拒绝，原因尚未确认，准备重查'),
            );
          } else if (failure.kind == GongyiAsrFailureKind.networkUnavailable ||
              failure.kind == GongyiAsrFailureKind.transient) {
            transportFailures++;
            if (transportFailures > maxTransportFailures) {
              throw stopped(failure.kind, '结果查询连续失败：${failure.message}');
            }
            await waitBeforeQuery(
              advisedWait(
                Duration(seconds: (2 * transportFailures).clamp(2, 20)),
              ),
              withEvidence(
                failure.kind == GongyiAsrFailureKind.networkUnavailable
                    ? '结果查询被网络打断，等待重新查询'
                    : '结果查询暂时异常，等待重新查询',
              ),
            );
          } else {
            throw failure;
          }
        }
      }
      throw stopped(GongyiAsrFailureKind.transient, '服务端尚未返回结果');
    } finally {
      watch.stop();
      queryCancellation.cancel('本轮结果查询已结束');
    }
  }

  Map<String, dynamic> _decodeResultMap(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        throw const GongyiAsrException(
          GongyiAsrFailureKind.rejected,
          '字幕结果无法解析',
        );
      }
    }
    return <String, dynamic>{};
  }

  void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled == true) {
      throw DioException(
        requestOptions: RequestOptions(path: ''),
        type: DioExceptionType.cancel,
        error: cancelToken?.cancelError,
      );
    }
  }

  Future<void> _cancelableDelay(
    Duration duration,
    CancelToken? cancelToken, {
    Future<void> Function(Duration)? delay,
  }) async {
    if (cancelToken == null) {
      await (delay?.call(duration) ?? Future<void>.delayed(duration));
      return;
    }
    _throwIfCancelled(cancelToken);
    await Future.any<void>([
      delay?.call(duration) ?? Future<void>.delayed(duration),
      cancelToken.whenCancel.then<void>((_) => _throwIfCancelled(cancelToken)),
    ]);
  }

  // 解析字幕结果。缺字段的句子跳过，避免一次坏数据让整段任务崩溃。
  List<SubtitleItem> _parseSubtitleResult(
    Map<String, dynamic> result,
    bool needWordTimestamp,
    bool includeWordTimings,
  ) {
    final List<SubtitleItem> subtitles = [];
    int index = 0;
    final utterances = result['utterances'];
    if (utterances is! List) return subtitles;

    if (needWordTimestamp) {
      for (final utterance in utterances) {
        if (utterance is! Map) continue;
        final words = utterance['words'];
        if (words is! List) continue;
        for (final word in words) {
          if (word is! Map) continue;
          final timing = _cueTiming(word['start_time'], word['end_time']);
          final text = word['label']?.toString().trim() ?? '';
          if (timing == null || text.isEmpty) continue;
          subtitles.add(
            SubtitleItem(
              index: ++index,
              startTime: timing.$1,
              endTime: timing.$2,
              text: text,
            ),
          );
        }
      }
    } else {
      for (final utterance in utterances) {
        if (utterance is! Map) continue;
        final timing = _cueTiming(
          utterance['start_time'],
          utterance['end_time'],
        );
        final text = utterance['transcript']?.toString().trim() ?? '';
        if (timing == null || text.isEmpty) continue;
        subtitles.add(
          SubtitleItem(
            index: ++index,
            startTime: timing.$1,
            endTime: timing.$2,
            text: text,
            timedSpans: includeWordTimings
                ? TimedSubtitleParser.alignWords(text, [
                    for (final word
                        in (utterance['words'] is List
                            ? utterance['words'] as List
                            : const []))
                      if (word is Map &&
                          _cueTiming(word['start_time'], word['end_time']) !=
                              null)
                        TimedSubtitleWord(
                          (word['label'] ?? word['text'] ?? '').toString(),
                          _cueTiming(word['start_time'], word['end_time'])!.$1,
                          _cueTiming(word['start_time'], word['end_time'])!.$2,
                        ),
                  ])
                : const [],
          ),
        );
      }
    }

    return subtitles;
  }

  (Duration, Duration)? _cueTiming(Object? startRaw, Object? endRaw) {
    if (startRaw is! num ||
        endRaw is! num ||
        !startRaw.isFinite ||
        !endRaw.isFinite) {
      return null;
    }
    final startMs = startRaw.round();
    final endMs = endRaw.round();
    if (endMs <= startMs || startMs < 0) return null;
    return (Duration(milliseconds: startMs), Duration(milliseconds: endMs));
  }
}
