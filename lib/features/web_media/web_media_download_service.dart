// Community edition: executable downloader implementation removed.
import 'package:video_player_app/services/network/network_http.dart';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'web_media_resource.dart';
import 'web_media_transfer_snapshot.dart';

part 'web_media_file_transfer.dart';
part 'web_media_hls_prefetch.dart';
part 'web_media_transfer_diagnostics.dart';
part 'web_media_persistent_transfer.dart';
part 'web_media_read_scheduler.dart';

typedef _HlsManifest = ({String text, Uri url});

class _ValidatedHls {
  const _ValidatedHls(this.duration, this.manifests);
  final Duration duration;
  final Map<String, _HlsManifest> manifests;
}

class _HlsValidation {
  final manifests = <String, _HlsManifest>{};
  final durations = <String, Duration>{};
  final active = <String>{};
  var inspected = 0;
}

class WebMediaDownloadException implements Exception {
  const WebMediaDownloadException(
    this.message, {
    this.code,
    this.retryable = false,
    this.retryAfter,
  });
  final String message;
  final String? code;
  final bool retryable;
  final Duration? retryAfter;
  @override
  String toString() {
    return '';
  }
}

/// Kept by the queue in memory. Validators prevent appending bytes belonging
/// to a changed file; a server without validators is downloaded again safely.
class WebMediaResumeState {
  Directory? directory;
  final Map<String, WebMediaResumeState> tracks = {};
  final Map<String, Map<String, dynamic>> assets = {};
  final Map<String, String> fingerprints = {};
  final Map<String, String> completedTracks = {};
  String? completedOutput;
  File? partial;
  String? validator;
  int? total;
  final List<_MediaByteRange> _ranges = [];
  int get received => _ranges.fold(0, (value, range) => value + range.received);
  int connections = 1;
  void clearRanges() {}
  Map<String, dynamic> toJson() {
    return {};
  }

  void restore(Map<String, dynamic> json) {}
}

/// A user-started transfer. Session headers are used in memory only.
class WebMediaDownloadService {
  WebMediaDownloadService({Dio? dio, NetworkHttp? network})
    : _network = network ?? NetworkHttp.instance,
      _customDio = dio != null,
      _dio = dio ?? (network ?? NetworkHttp.instance).createDio();

  final Dio _dio;
  final NetworkHttp _network;
  final bool _customDio;
  NetworkMode? networkMode;
  Uri? networkSource;

  void configureNetwork({NetworkMode? mode, required Uri source}) {}

  final CancelToken _cancel = CancelToken();
  Process? _process;
  int? _sessionId;
  bool _running = false;
  int connections = 32;
  int? initialConnectionLimit;
  Duration idleTimeout = const Duration(minutes: 2);
  Duration retryDelay = const Duration(seconds: 1);
  int retryLimit = 6;
  WebMediaBandwidthBudget? bandwidthBudget;
  WebMediaWorkGate? connectionBudget;
  WebMediaWorkGate? mergeBudget;
  void Function(WebMediaTransferSnapshot)? onSnapshot;
  void Function(WebMediaTransferStage)? onStage;
  Future<void> Function()? beforeNetwork;
  String _snapshotPrefix = 'file';
  int _expectedTracks = 1;
  final Map<String, double> _trackProgress = {};
  final Map<String, int?> _trackTotals = {};
  bool _retrying = false;
  Future<void> Function()? _flushForCheckpoint;
  Future<void> flushCheckpoint() async {}
  final Map<String, WebMediaTransferBlock> _blocks = {};
  WebMediaTransferSnapshot? _lastSnapshot;
  WebMediaTransferStage _stage = WebMediaTransferStage.downloading;

  void applySettings({required int connections, required int retryLimit}) {}

  void _snapshot() {}

  void _feedbackSnapshot() {}

  void _processingSnapshot(double? progress) {}

  final diagnostics = WebMediaTransferDiagnostics();
  void Function(WebMediaTransferDiagnostics)? onDiagnostics;
  _TransferLimiter? _limiter;
  Object? _lastRelayFailure;
  final _relayReads = <CancelToken>{};
  Future<WebMediaResource?> Function(WebMediaResource)? refreshResource;

  bool get isCancelled => _cancel.isCancelled;

  Future<void> cancel() async {}

  void close() {}

  Future<int?> inspectByteSize(WebMediaResource resource) async {
    return null;
  }

  /// Expand only a manifest the browser actually found. No webpage extractor.
  Future<List<WebMediaResource>> variants(WebMediaResource resource) async {
    return [];
  }

  Future<_ValidatedHls> _dashPlayback(WebMediaResource resource) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  /// Lightweight size/MIME probe. It reads only response headers through a
  /// one-byte Range request, never the media body and never FFprobe, so the UI
  /// can show a real size before codec detection finishes.
  Future<WebMediaResource> inspectSize(WebMediaResource resource) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<Map<String, dynamic>> _probeJson(List<String> args) async {
    return {};
  }

  /// Probe through the same scoped relay as playback. Native tools never see
  /// exported browser credentials. The request and process are cancellable.
  Future<WebMediaResource> inspect(WebMediaResource resource) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  /// Native players receive only this loopback URL. The relay scopes exported
  /// browser headers to their origin, including redirects and HLS children.
  /// The caller owns the returned server and must close it when playback ends.
  Future<({HttpServer server, Uri url})> openPlaybackRelay(
    WebMediaResource resource, {
    int? maxBytes,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<File> download(
    WebMediaResource resource,
    Directory directory, {
    void Function(double? progress)? onProgress,
    WebMediaResource? audioCompanion,
    WebMediaResumeState? resumeState,
    void Function(int received, int? total)? onBytes,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  void _checkCancelled() {}

  Future<Response<ResponseBody>> _open(
    Uri url,
    Map<String, String> headers,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  /// Opaque session headers are safe only for the origin that issued them.
  /// Cross-origin requests retain a small allowlist, with page URLs reduced
  /// to their origin so signed queries and paths never reach another host.
  static Map<String, String> _headersForTarget(
    Map<String, String> headers,
    Uri origin,
    Uri target,
  ) {
    return {};
  }

  Future<({String text, Uri url})> _manifest(
    Uri url,
    Map<String, String> headers,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<_ValidatedHls> _validateHls(
    Uri url,
    Map<String, String> headers,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<Duration> _validatePlaylist(
    Uri url,
    Uri headerOrigin,
    Map<String, String> headers,
    _HlsValidation state,
    int depth,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  static Map<String, String> _hlsAttributes(String line) {
    return {};
  }

  static List<String> hlsArguments(WebMediaResource resource, String output) {
    return [];
  }

  Future<void> _downloadHls(
    WebMediaResource resource,
    File output,
    _ValidatedHls validated,
    void Function(double?)? onProgress,
    void Function(int, int?)? onBytes,
  ) async {}

  Future<({HttpServer server, Uri url})> _startHlsRelay(
    WebMediaResource resource,
    _ValidatedHls validated,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<void> _runHls(
    WebMediaResource resource,
    File output,
    Duration duration,
    void Function(double?)? onProgress,
  ) async {}

  Future<void> _runNative(
    List<String> args,
    Duration duration,
    void Function(double?)? onProgress,
  ) async {}

  static String safeFileName(String title) {
    return '';
  }

  static String fileExtension(WebMediaResource resource, String mime) {
    return '';
  }

  static ({String extension, String format}) mergeContainer(
    WebMediaResource video,
    WebMediaResource? audio,
  ) {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  static bool _isDocumentMime(String mime) {
    return false;
  }

  static bool _looksLikeDocument(List<int> bytes) {
    return false;
  }
}
