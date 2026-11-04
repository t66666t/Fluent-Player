// Community edition: executable downloader implementation removed.
import 'bilibili_api_service.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/services/bilibili/download_integrity.dart';
import 'package:video_player_app/services/bilibili/download_route_policy.dart';
import 'package:video_player_app/services/bilibili/media_connection_pool.dart';
// Import video_player for validation

class DownloadUrlExpiredException implements Exception {
  final String url;
  final int? statusCode;

  DownloadUrlExpiredException(this.url, {this.statusCode});

  @override
  String toString() {
    return '';
  }
}

class DownloadProgressStalledException implements Exception {
  final String url;
  final Duration idleDuration;

  DownloadProgressStalledException(this.url, {required this.idleDuration});

  @override
  String toString() {
    return '';
  }
}

class _RangeDownloadUnsupportedException implements Exception {
  const _RangeDownloadUnsupportedException(this.message);

  final String message;

  @override
  String toString() {
    return '';
  }
}

class _RestartSequentialDownloadException implements Exception {
  const _RestartSequentialDownloadException();
}

class _ProcessTimeoutSignal {
  const _ProcessTimeoutSignal();
}

class _ProcessCancelledSignal {
  const _ProcessCancelledSignal();
}

class _MediaProbeResult {
  const _MediaProbeResult({required this.duration, required this.videoCodec});

  final Duration duration;
  final String? videoCodec;
}

typedef BilibiliTrackDownloader =
    Future<DownloadPartResumeState> Function({
      required StreamItem stream,
      required String filePath,
      required DownloadPartResumeState? initialState,
      required CancelToken? cancelToken,
      required void Function(DownloadPartResumeState state, String? speedText)
      onProgress,
    });

class BilibiliDownloadManager {
  final BilibiliApiService _apiService;

  final int _rangeMinBytesPerConnection;
  final BilibiliDownloadRoutePolicy _routePolicy;
  final BilibiliDownloadDiagnostic? _onDiagnostic;

  BilibiliDownloadManager(
    this._apiService, {
    int rangeMinBytesPerConnection =
        BilibiliDownloadIntegrity.defaultMinBytesPerConnection,
    BilibiliDownloadRoutePolicy routePolicy =
        const BilibiliDownloadRoutePolicy(),
    BilibiliDownloadDiagnostic? onDiagnostic,
  }) : assert(rangeMinBytesPerConnection > 0),
       _rangeMinBytesPerConnection = rangeMinBytesPerConnection,
       _routePolicy = routePolicy,
       _onDiagnostic = onDiagnostic;

  @visibleForTesting
  Future<DownloadPartResumeState> downloadVideoStreamForTesting({
    required StreamItem stream,
    required String filePath,
    required int maxConnections,
    DownloadPartResumeState? initialState,
    CancelToken? cancelToken,
    void Function(DownloadPartResumeState state, String? speedText)? onProgress,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  static final BilibiliMediaConnectionPool _mediaConnectionPool =
      BilibiliMediaConnectionPool.shared;
  static BilibiliMediaConnectionPool get mediaConnectionPool =>
      _mediaConnectionPool;

  Future<String> downloadAndMerge({
    required StreamItem videoStream,
    required StreamItem audioStream,
    required String fileName,
    required String tempArtifactKey,
    required Function(double) onProgress,
    Function(String)? onSpeedUpdate,
    Function(String)? onSizeUpdate,
    Function(DownloadStatus)?
    onStatusUpdate, // Callback for checking/repairing status
    VoidCallback?
    onDownloadPhaseFinished, // New callback for releasing download slot
    Function(DownloadPartResumeState?, DownloadPartResumeState?)?
    onResumeStateChanged,
    BilibiliSubtitle? subtitle,
    List<MediaChapter> chapters = const <MediaChapter>[],
    DownloadPartResumeState? videoResumeState,
    DownloadPartResumeState? audioResumeState,
    CancelToken? cancelToken,
    int maxVideoConnections = 2,
    Directory? workDirectory,
    BilibiliTrackDownloader? trackDownloader,
    VoidCallback? beforeMerge,
    bool retainTracks = false,
    bool verifyAfterDownload = true,
  }) async {
    throw UnsupportedError('开源版不提供媒体下载或网站提取');
  }

  // Verify if video can be played by ExoPlayer

  // Repair the picture to H.264, keeping special audio packets intact. The
  // repaired output is validated before replacing the original merged file.

  // Helper for executing FFmpeg based on platform

  // Helper for serial execution
}
