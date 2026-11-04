import 'dart:io';

import 'package:dio/dio.dart';

import 'media_cache_models.dart';

class CacheDownloadPlan {
  const CacheDownloadPlan({
    required this.quality,
    this.estimatedBytes,
    this.extension = '.mp4',
    this.payload,
    this.retainInPlace = false,
  });
  final CacheQuality quality;
  final int? estimatedBytes;
  final String extension;

  /// Process-only resolved source. Never serialized with a task.
  final Object? payload;
  final bool retainInPlace;
}

class CacheTransferProgress {
  const CacheTransferProgress({
    required this.received,
    this.total,
    this.fraction,
    this.state = CacheTaskState.downloading,
  });
  final int received;
  final int? total;
  final double? fraction;
  final CacheTaskState state;
}

abstract class MediaCacheBackend {
  Future<List<CacheQuality>> qualities(CacheSource source);
  Future<CacheDownloadPlan> resolve(CacheTask task, CancelToken cancel);
  Future<File> download(
    CacheTask task,
    CacheDownloadPlan plan,
    MediaCachePreferences preferences,
    CancelToken cancel,
    void Function(CacheTransferProgress) onProgress,
  );
  Future<Directory> outputDirectory(CacheSource source);
  Future<Directory> taskDirectory(CacheTask task);
}

class CacheLoginRequired implements Exception {
  const CacheLoginRequired();
  @override
  String toString() => '需要重新登录后继续缓存';
}

extension CacheCancelCheck on CancelToken {
  void throwIfCancellationRequested() {
    if (isCancelled) throw cancelError!;
  }
}
