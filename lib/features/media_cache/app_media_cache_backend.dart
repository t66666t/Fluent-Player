// Community edition: executable downloader implementation removed.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../services/bilibili/bilibili_download_service.dart';
import 'media_cache_backend.dart';
import 'media_cache_models.dart';

class AppMediaCacheBackend implements MediaCacheBackend {
  AppMediaCacheBackend(this.bilibili);
  final BilibiliDownloadService bilibili;

  static int? qualityHeight(String id, String label) {
    return null;
  }

  @override
  Future<List<CacheQuality>> qualities(CacheSource source) async {
    return [];
  }

  @override
  Future<CacheDownloadPlan> resolve(CacheTask task, CancelToken cancel) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  @override
  Future<Directory> outputDirectory(CacheSource source) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  @override
  Future<Directory> taskDirectory(CacheTask task) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  @override
  Future<File> download(
    CacheTask task,
    CacheDownloadPlan plan,
    MediaCachePreferences preferences,
    CancelToken cancel,
    void Function(CacheTransferProgress) onProgress,
  ) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }
}
