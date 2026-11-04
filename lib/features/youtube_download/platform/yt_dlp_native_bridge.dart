// Community edition: executable downloader implementation removed.
import 'dart:async';
import 'package:video_player_app/services/network/network_http.dart';

import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';

class YtDlpBinaryStatus {
  final bool ytDlpReady;

  /// Whether FFmpeg functionality is available through either a CLI binary or
  /// an embedded backend such as FFmpegKit.
  final bool ffmpegReady;

  /// Whether yt-dlp can invoke a standalone ffmpeg executable directly.
  final bool ffmpegCliReady;
  final String? ffmpegBackend;
  final String? ytDlpVersion;
  final String? ffmpegVersion;
  final String? ytDlpPath;
  final String? ffmpegPath;
  final String? diagnosticMessage;
  final String? runtimeKind;
  final String? pythonVersion;
  final String? jsRuntime;
  final String? ejsVersion;

  const YtDlpBinaryStatus({
    this.ytDlpReady = false,
    this.ffmpegReady = false,
    this.ffmpegCliReady = false,
    this.ffmpegBackend,
    this.ytDlpVersion,
    this.ffmpegVersion,
    this.ytDlpPath,
    this.ffmpegPath,
    this.diagnosticMessage,
    this.runtimeKind,
    this.pythonVersion,
    this.jsRuntime,
    this.ejsVersion,
  });

  factory YtDlpBinaryStatus.fromJson(Map<String, dynamic> json) {
    final ffmpegReady = json['ffmpegReady'] == true;
    return YtDlpBinaryStatus(
      ytDlpReady: json['ytDlpReady'] == true,
      ffmpegReady: ffmpegReady,
      ffmpegCliReady: json.containsKey('ffmpegCliReady')
          ? json['ffmpegCliReady'] == true
          : ffmpegReady,
      ffmpegBackend: json['ffmpegBackend']?.toString(),
      ytDlpVersion: json['ytDlpVersion']?.toString(),
      ffmpegVersion: json['ffmpegVersion']?.toString(),
      ytDlpPath: json['ytDlpPath']?.toString(),
      ffmpegPath: json['ffmpegPath']?.toString(),
      diagnosticMessage: json['diagnosticMessage']?.toString(),
      runtimeKind: json['runtimeKind']?.toString(),
      pythonVersion: json['pythonVersion']?.toString(),
      jsRuntime: json['jsRuntime']?.toString(),
      ejsVersion: json['ejsVersion']?.toString(),
    );
  }

  String get ffmpegAvailabilityLabel {
    if (!ffmpegReady) return '不可用';
    final backend = ffmpegBackend?.trim();
    return backend == null || backend.isEmpty ? '可用' : '可用（$backend）';
  }
}

class YtDlpPauseResult {
  final bool accepted;
  final bool stopped;
  final String? reason;

  const YtDlpPauseResult({
    required this.accepted,
    required this.stopped,
    this.reason,
  });

  const YtDlpPauseResult.rejected([this.reason])
    : accepted = false,
      stopped = false;

  factory YtDlpPauseResult.fromPlatform(dynamic value) {
    if (value is bool) {
      return YtDlpPauseResult(accepted: value, stopped: value);
    }
    if (value is Map) {
      return YtDlpPauseResult(
        accepted: value['accepted'] == true,
        stopped: value['stopped'] == true,
        reason: value['reason']?.toString(),
      );
    }
    return const YtDlpPauseResult.rejected('平台未返回暂停结果');
  }
}

class YtDlpNativeBridge {
  static const String resolveYoutubeMetaMethod = 'resolveYoutubeMeta';
  static const String startYoutubeDownloadMethod = 'startYoutubeDownload';
  static const String pauseYoutubeDownloadMethod = 'pauseYoutubeDownload';
  static const String cancelYoutubeDownloadMethod = 'cancelYoutubeDownload';
  static const String removeYoutubeTaskMethod = 'removeYoutubeTask';
  static const String getYoutubeTaskStatusMethod = 'getYoutubeTaskStatus';
  static const String importYoutubeCookiesMethod = 'importYoutubeCookies';
  static const String saveYoutubeSessionConfigMethod =
      'saveYoutubeSessionConfig';
  static const String loadYoutubeSessionConfigMethod =
      'loadYoutubeSessionConfig';
  static const String getBinaryStatusMethod = 'getYtDlpBinaryStatus';
  static const String configureBinaryPathsMethod = 'configureYtDlpBinaryPaths';
  static const String reloadAndroidRuntimeMethod = 'reloadYtDlpRuntime';

  Future<bool> configureBinaryPaths({
    required String? ytDlpPath,
    required String? ffmpegPath,
  }) async {
    return false;
  }

  Future<String?> reloadAndroidRuntime(String archivePath) async {
    return null;
  }

  Stream<DownloadTaskEvent> taskEvents() {
    return const Stream.empty();
  }

  Future<Map<String, dynamic>?> resolveYoutubeMeta(
    String url,
    DownloadSessionConfig sessionConfig, {
    NetworkMode? networkMode,
    NetworkScope? networkScope,
  }) async {
    return null;
  }

  Future<bool> startYoutubeDownload(
    NativeDownloadRequest request, {
    required int generation,
  }) async {
    return false;
  }

  Future<YtDlpPauseResult> pauseYoutubeDownload(String taskId) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<bool> cancelYoutubeDownload(String taskId) async {
    return false;
  }

  Future<bool> removeYoutubeTask(String taskId) async {
    return false;
  }

  Future<Map<String, dynamic>?> getYoutubeTaskStatus(String taskId) async {
    return null;
  }

  Future<String?> importYoutubeCookies(String filePath) async {
    return null;
  }

  Future<bool> saveYoutubeSessionConfig(DownloadSessionConfig config) async {
    return false;
  }

  Future<DownloadSessionConfig?> loadYoutubeSessionConfig() async {
    return null;
  }

  Future<YtDlpBinaryStatus> getBinaryStatus() async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }
}
