import 'dart:io';

import '../../models/bilibili_download_task.dart';
import '../../models/bilibili_models.dart';
import '../../models/video_item.dart';
import '../../services/app_storage_service.dart';
import '../../services/library_service.dart';
import '../../services/storage_audit_service.dart' show storagePathKey;
import 'legacy_bilibili_cache_import.dart';
import 'media_cache_models.dart';
import 'media_cache_service.dart';

/// Sealed download files enter the same registry as explicitly cached streams.
/// Save before publishing a logical card, including on retries.
Future<CacheVariant> registerBilibiliDownload(
  MediaCacheService cache,
  VideoItem item, {
  required String path,
  StreamItem? quality,
  CacheQuality? cacheQuality,
}) async {
  final source = CacheSource.fromItem(item);
  if (source == null || !source.isBilibili) {
    throw StateError('下载视频缺少明确的 B 站来源');
  }
  final stat = await File(path).stat();
  if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
    throw StateError('下载成品不存在或尚未完成');
  }
  final variant = CacheVariant(
    source: source,
    quality: cacheQuality ?? bilibiliDownloadedQuality(quality),
    path: path,
    bytes: stat.size,
    createdAt: item.lastUpdated,
    managed: false,
    assetId: bilibiliDownloadedAssetId(source, path),
  );
  await cache.registerLegacy(variant);
  // A preceding write may have failed after updating the in-memory registry.
  if (cache.persistenceError != null) await cache.flush();
  return cache.variants.firstWhere(
    (entry) =>
        entry.source.key == source.key &&
        entry.completeMedia &&
        !entry.pendingDelete &&
        AppStorageService.samePath(entry.path, path),
    orElse: () => throw StateError('下载成品尚未登记，请重试'),
  );
}

/// The two durable writes are intentionally ordered: an interruption can leave
/// an extra registry entry, never a converted card with an unregistered file.
Future<int> migrateBilibiliDownloadCards(
  LibraryService library,
  MediaCacheService cache,
  Iterable<BilibiliDownloadTask> tasks,
) async {
  final snapshot = library.storageVideos.toList();
  await cache.registerLegacyBatch(legacyBilibiliCacheVariants(snapshot, tasks));
  if (cache.persistenceError != null) await cache.flush();
  final completeFiles = <(String, String)>{
    for (final entry in cache.variants)
      if (entry.completeMedia && entry.available && !entry.pendingDelete)
        (entry.source.key, storagePathKey(entry.path)),
  };
  final ids = <String>[];
  for (final item in snapshot) {
    if (!item.isBilibiliExported ||
        item.type != MediaType.video ||
        item.path.contains('://')) {
      continue;
    }
    final source = CacheSource.fromItem(item);
    if (source == null || !source.isBilibili) continue;
    if (completeFiles.contains((source.key, storagePathKey(item.path)))) {
      ids.add(item.id);
    }
  }
  return library.promoteBilibiliDownloadCards(ids);
}
