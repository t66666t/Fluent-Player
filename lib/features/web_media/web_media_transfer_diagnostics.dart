// Community edition: executable downloader implementation removed.
part of 'web_media_download_service.dart';

/// A shareable summary deliberately excludes URLs, cookies, paths and titles.
class WebMediaTransferDiagnostics {
  String protocol = 'HTTP';
  int requestedConnections = 32;
  int connectionLimit = 1;
  int activeConnections = 0;
  int retries = 0;
  int reconnects = 0;
  int refreshes = 0;
  bool? rangeSupported;
  bool? validatedResume;
  String? note;
  String? errorCode;
  int? storageErrorNumber;

  String get connectionLabel =>
      '活动连接 $activeConnections · 当前上限 $connectionLimit · 设置上限 $requestedConnections';
  String get summary => [
    '传输方式：$protocol',
    connectionLabel,
    if (rangeSupported != null) 'HTTP 分段：${rangeSupported! ? '支持' : '不支持'}',
    if (validatedResume != null) '校验续传：${validatedResume! ? '支持' : '不可用'}',
    '重试次数：$retries · 链接刷新：$refreshes',
    if (reconnects > 0) '自动续传次数：$reconnects',
    ?note,
    if (errorCode != null) '最近错误：$errorCode',
    if (storageErrorNumber != null) '系统文件错误码：$storageErrorNumber',
  ].join('\n');
}

class _TransferLimiter {
  _TransferLimiter(this.owner, int limit) : limit = limit.clamp(1, 32);
  final WebMediaDownloadService owner;
  int limit;
  int active = 0;
  int generation = 0;
  int _successes = 0;
  final _stability = Stopwatch()..start();
  int _reserved = 0;
  final List<Completer<void>> waiting = [];

  Future<void> acquire() async {}

  void release({bool acquiredBudget = true}) {}

  void resize(int value) {}

  void lower(int attemptedLimit, int? attemptedGeneration) {}

  void succeeded(int attemptedLimit, int attemptedGeneration) {}

  void _publish() {}
}

extension _TransferFeedback on WebMediaDownloadService {
  ({String code, String message}) _storageFailure(FileSystemException error) {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  void _publishDiagnostics() {}

  void _retry(Object error) {}

  bool _serverThrottled(Object error) {
    return false;
  }

  Duration _readRetryDelay(int attempt, Object error) {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  bool _certificateFailure(Object error) {
    return false;
  }

  Future<void> _backoff(int attempt) async {}

  String _failureCode(Object error) {
    return '';
  }

  String _failureMessage(Object error) {
    return '';
  }

  WebMediaDownloadException _downloadFailure(Object error) {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Stream<List<int>> _body(Response<ResponseBody> response) {
    return const Stream.empty();
  }

  bool _transient(Object error) {
    return false;
  }
}
