import '../../models/bilibili_download_task.dart';
import '../../models/bilibili_favorites_models.dart';
import '../../models/bilibili_models.dart';
import '../../models/import_card_placement.dart';
import '../../models/media_source_ref.dart';
import '../library_service.dart';
import 'bilibili_collection_import.dart';
import 'bilibili_download_service.dart';
import 'bilibili_favorites_service.dart';
import 'bilibili_quick_import.dart';

class BilibiliFavoritesImportRequest {
  const BilibiliFavoritesImportRequest({
    required this.mid,
    required this.folder,
    required this.placement,
    this.selectedVideos,
  });
  final int mid;
  final BilibiliFavoriteFolder folder;
  final ImportPlacementRequest placement;

  /// Null means the entire remote folder, not just the currently loaded rows.
  final List<BilibiliFavoriteVideo>? selectedVideos;
  bool get wholeFolder => selectedVideos == null;
}

class BilibiliFavoritesImportResult {
  const BilibiliFavoritesImportResult({
    this.imported = const {},
    this.failed = const {},
    this.parts = 0,
    this.skipped = 0,
    this.cancelled = false,
  });
  final Set<String> imported;
  final Map<String, String> failed;
  final int parts;
  final int skipped;
  final bool cancelled;
  String get message => [
    '已导入 ${imported.length} 个视频（$parts 个分P）',
    if (skipped > 0) '跳过 $skipped 个失效或非视频内容',
    if (failed.isNotEmpty) '${failed.length} 个视频未完整导入，可重试',
    if (cancelled) '其余操作已取消',
  ].join('，');
}

void _checkCancelled(bool Function()? isCancelled) {
  if (isCancelled?.call() == true) throw const BilibiliFavoritesCancelled();
}

void _validateInfo(BilibiliVideoInfo info, String bvid) {
  if (info.bvid != bvid ||
      info.pages.isEmpty ||
      info.pages.any((part) => part.cid <= 0 || part.page <= 0)) {
    throw BilibiliFavoritesException('“${info.title}”的分P信息不完整，请重试');
  }
}

Future<BilibiliDownloadTask> prepareBilibiliFavoritesFolderImport({
  required BilibiliDownloadService service,
  required BilibiliFavoriteContents contents,
  required ImportPlacementRequest placement,
  required int mid,
  bool Function()? isCancelled,
  void Function(String message)? onProgress,
}) async {
  final entries = contents.playable;
  if (entries.isEmpty) throw const BilibiliFavoritesException('这个收藏夹没有可导入的视频');
  final infos = <BilibiliVideoInfo>[];
  for (final entry in entries) {
    _checkCancelled(isCancelled);
    onProgress?.call('正在读取视频 ${infos.length + 1}/${entries.length}');
    final info = await loadBilibiliImportVideoInfo(service, entry.bvid);
    _checkCancelled(isCancelled);
    _validateInfo(info, entry.bvid);
    infos.add(info);
  }
  final url = Uri.https('space.bilibili.com', '/$mid/favlist', {
    'fid': '${contents.folder.id}',
  }).toString();
  return BilibiliDownloadTask(
    collectionInfo: BilibiliCollectionInfo(
      title: contents.folder.title,
      cover: contents.folder.coverUrl ?? infos.first.pic,
      videos: infos,
    ),
    sourceRef: MediaSourceRef(kind: MediaSourceKind.url, value: url),
    streamingPlacement: placement,
    isStreamingImport: true,
    isSelected: true,
    isExpanded: true,
    videos: [
      for (final info in infos)
        BilibiliVideoItem(
          videoInfo: info,
          sourceRef: MediaSourceRef(
            kind: MediaSourceKind.bilibiliBv,
            value: info.bvid,
            bvid: info.bvid,
            originalValue: url,
          ),
          isSelected: true,
          episodes: [
            for (final part in info.pages)
              BilibiliDownloadEpisode(
                page: part,
                bvid: info.bvid,
                isSelected: true,
              ),
          ],
        ),
    ],
  );
}

Future<BilibiliFavoritesImportResult> importBilibiliFavorites({
  required BilibiliFavoritesImportRequest request,
  required BilibiliDownloadService service,
  required LibraryService library,
  required BilibiliFavoritesService favorites,
  bool Function()? isCancelled,
  void Function(String message)? onProgress,
}) async {
  _checkCancelled(isCancelled);
  await service.init();
  _checkCancelled(isCancelled);
  if (request.wholeFolder) {
    final contents = await favorites.fetchAllVideos(
      request.mid,
      request.folder.id,
      isCancelled: isCancelled,
      onProgress: (loaded, total) => onProgress?.call('正在读取收藏夹 $loaded/$total'),
    );
    if (contents.playable.isEmpty) {
      return BilibiliFavoritesImportResult(skipped: contents.skipped);
    }
    final task = await prepareBilibiliFavoritesFolderImport(
      service: service,
      contents: contents,
      placement: request.placement,
      mid: request.mid,
      isCancelled: isCancelled,
      onProgress: onProgress,
    );
    _checkCancelled(isCancelled);
    final episodes = [
      for (final video in task.videos)
        List<BilibiliDownloadEpisode>.of(video.episodes),
    ];
    final expected = episodes.fold<int>(0, (sum, parts) => sum + parts.length);
    onProgress?.call('正在导入整个收藏夹…');
    final count = await service.importParsedStreamingTaskToLibrary(
      library,
      task,
      shouldContinue: () => isCancelled?.call() != true,
    );
    final cancelled = isCancelled?.call() == true;
    final imported = <String>{};
    final failed = <String, String>{};
    final entries = contents.playable;
    for (var i = 0; i < entries.length; i++) {
      if (count == expected || episodes[i].every((part) => part.isExported)) {
        imported.add(entries[i].key);
      } else if (!cancelled) {
        failed[entries[i].key] = '有分P未导入，可在哔哩哔哩在线解析页重试';
      }
    }
    return BilibiliFavoritesImportResult(
      imported: imported,
      failed: failed,
      parts: count,
      skipped: contents.skipped,
      cancelled: cancelled,
    );
  }

  final entries = {
    for (final video in request.selectedVideos!) video.key: video,
  }.values.toList();
  final imported = <String>{};
  final failed = <String, String>{};
  var parts = 0, skipped = 0;
  String? targetFolder;
  var resolved = false;
  for (var i = 0; i < entries.length; i++) {
    if (isCancelled?.call() == true) break;
    final entry = entries[i];
    if (!entry.canPlay) {
      skipped++;
      continue;
    }
    onProgress?.call('正在导入视频 ${i + 1}/${entries.length}');
    try {
      final info = await loadBilibiliImportVideoInfo(service, entry.bvid);
      _checkCancelled(isCancelled);
      _validateInfo(info, entry.bvid);
      if (!resolved) {
        targetFolder = await library.resolveImportCardParentId(
          feature: ImportCardFeature.bilibiliPage,
          openedFromFolderId: request.placement.folderId,
          request: request.placement,
        );
        resolved = true;
      }
      _checkCancelled(isCancelled);
      final result = await runBilibiliQuickImport(
        service: service,
        library: library,
        bvid: entry.bvid,
        videoInfo: info,
        target: BilibiliImportTarget.picked(targetFolder),
        allParts: true,
        selectedPages: info.pages.map((part) => part.page).toList(),
        again: true,
      );
      parts += result.batch?.cards.length ?? 0;
      if (result.batch?.failedPages.isNotEmpty == true) {
        failed[entry.key] = '部分分P未导入，请重试';
      } else {
        imported.add(entry.key);
      }
    } on BilibiliFavoritesCancelled {
      break;
    } catch (_) {
      failed[entry.key] = '“${entry.title}”导入失败，请重试';
    }
  }
  return BilibiliFavoritesImportResult(
    imported: imported,
    failed: failed,
    parts: parts,
    skipped: skipped,
    cancelled: isCancelled?.call() == true,
  );
}
