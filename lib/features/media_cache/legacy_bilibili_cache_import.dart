import 'dart:io';

import '../../models/bilibili_download_task.dart';
import '../../models/bilibili_models.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import 'media_cache_models.dart';
import '../../services/storage_audit_service.dart' show storagePathKey;

CacheQuality bilibiliDownloadedQuality(StreamItem? quality) => CacheQuality(
  id: quality == null ? 'legacy' : '${quality.id}',
  label:
      quality?.qualityName ??
      (quality == null
          ? '已有离线版本'
          : quality.height > 0
          ? '${quality.height}P'
          : '已缓存画质 ${quality.id}'),
  codec: quality?.codecs ?? '',
  height: quality == null || quality.height <= 0 ? null : quality.height,
  width: quality == null || quality.width <= 0 ? null : quality.width,
  revision: 'cid',
);

String bilibiliDownloadedAssetId(CacheSource source, String path) =>
    cacheDigest('${source.key}:${storagePathKey(path)}');

/// A startup snapshot, indexed once. First matches and iteration order are the
/// same as the old nested searches; no downloads or library cards are mutated.
Stream<CacheVariant> legacyBilibiliCacheVariants(
  Iterable<VideoItem> libraryItems,
  Iterable<BilibiliDownloadTask> tasks,
) async* {
  final items = libraryItems.toList(growable: false);
  final episodes = [
    for (final task in tasks)
      for (final video in task.videos)
        for (final episode in video.episodes) (video, episode),
  ];
  final episodeByItem = <String, BilibiliDownloadEpisode>{};
  for (final (_, episode) in episodes) {
    for (final id in episode.importedVideoIds) {
      episodeByItem.putIfAbsent(id, () => episode);
    }
  }
  final itemBySource = <(String?, int?), VideoItem>{};
  for (final item in items) {
    itemBySource.putIfAbsent((
      item.sourceRef?.bvid,
      item.sourceRef?.cid,
    ), () => item);
  }

  for (final item in items) {
    final source = CacheSource.fromItem(item);
    if (source == null || !source.isBilibili || item.path.contains('://')) {
      continue;
    }
    final file = File(item.path);
    if (!await file.exists()) continue;
    yield CacheVariant(
      source: source,
      quality: bilibiliDownloadedQuality(
        episodeByItem[item.id]?.downloadedVideoQuality ??
            episodeByItem[item.id]?.selectedVideoQuality,
      ),
      path: file.path,
      bytes: await file.length(),
      managed: false,
      createdAt: item.lastUpdated,
      assetId: bilibiliDownloadedAssetId(source, file.path),
    );
  }

  for (final (video, episode) in episodes) {
    final path = episode.publishedMediaPath ?? episode.outputPath;
    if (episode.status != DownloadStatus.completed || path == null) continue;
    final file = File(path);
    if (!await file.exists()) continue;
    final existing = itemBySource[(episode.bvid, episode.page.cid)];
    final source = existing == null
        ? CacheSource(
            ref: MediaSourceRef(
              value: episode.bvid,
              kind: MediaSourceKind.bilibiliStream,
              bvid: episode.bvid,
              cid: episode.page.cid,
            ),
            itemId: 'bilibili_cache_${episode.bvid}_${episode.page.cid}',
            title: episode.page.part,
            thumbnail: video.videoInfo.pic,
            kind: MediaType.video,
            durationMs: episode.page.duration * 1000,
            legacyPath: path,
          )
        : CacheSource.fromItem(existing);
    if (source == null) continue;
    yield CacheVariant(
      source: source,
      quality: bilibiliDownloadedQuality(
        episode.downloadedVideoQuality ?? episode.selectedVideoQuality,
      ),
      path: file.path,
      bytes: await file.length(),
      managed: false,
      createdAt: (await file.lastModified()).millisecondsSinceEpoch,
      assetId: bilibiliDownloadedAssetId(source, file.path),
    );
  }
}
