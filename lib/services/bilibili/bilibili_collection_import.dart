import '../../models/bilibili_browse_models.dart';
import '../../models/bilibili_download_task.dart';
import '../../models/bilibili_models.dart';
import '../../models/bilibili_uploader_models.dart';
import '../../models/import_card_placement.dart';
import '../../models/media_source_ref.dart';
import '../../utils/bilibili_image_url.dart';
import '../library_service.dart';
import '../settings_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_uploader_service.dart';
import 'bilibili_watch_launch.dart';

/// Identifies a whole collection, independently of how many rows the page
/// has loaded. Detail pages without a space identity can use their full
/// season episode list instead.
class BilibiliCollectionImportSource {
  const BilibiliCollectionImportSource({
    required this.mid,
    required this.collection,
    this.fallbackBvids = const <String>[],
  });

  factory BilibiliCollectionImportSource.fromDetail(
    BilibiliVideoDetail detail,
  ) {
    final season = detail.season!;
    return BilibiliCollectionImportSource(
      mid: detail.owner.mid,
      collection: BilibiliUploaderCollection(
        id: season.id,
        isSeason: true,
        title: season.title,
        coverUrl: season.coverUrl ?? detail.coverUrl,
        videoCount: season.episodes.length,
      ),
      fallbackBvids: [for (final episode in season.episodes) episode.bvid],
    );
  }

  final int mid;
  final BilibiliUploaderCollection collection;
  final List<String> fallbackBvids;

  String get key =>
      '${collection.isSeason ? 'season' : 'series'}:$mid:'
      '${collection.id}:${collection.id > 0 ? '' : fallbackBvids.join(',')}';

  String get url => Uri.https(
    'space.bilibili.com',
    '/$mid/lists/${collection.id}',
    {'type': collection.isSeason ? 'season' : 'series'},
  ).toString();
}

class BilibiliCollectionImportException implements Exception {
  const BilibiliCollectionImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Enumerates every page before publishing any cards. Failed or truncated
/// pagination is an error, never a successful import of only the first page.
Future<List<String>> loadBilibiliCollectionBvids({
  required BilibiliCollectionImportSource source,
  required BilibiliUploaderService uploader,
  bool Function()? isCancelled,
}) async {
  final ids = <String>{};
  if (source.mid <= 0 || source.collection.id <= 0) {
    ids.addAll(source.fallbackBvids.where(isValidBvid));
  } else {
    for (var page = 1; ; page++) {
      if (isCancelled?.call() == true) throw StateError('已取消');
      final result = await uploader.fetchCollectionVideos(
        source.mid,
        source.collection,
        page: page,
        limitToBrowsePages: false,
      );
      if (!result.isSuccess) {
        throw BilibiliCollectionImportException(result.message);
      }
      final data = result.data!;
      if (isCancelled?.call() == true) throw StateError('已取消');
      final before = ids.length;
      ids.addAll(data.items.map((item) => item.bvid).where(isValidBvid));
      if (data.total > 0 && ids.length >= data.total) break;
      if (data.items.length < data.pageSize) {
        if (data.total > ids.length) {
          throw const BilibiliCollectionImportException('合集列表未完整返回，请稍后重试');
        }
        break;
      }
      if (ids.length == before) {
        throw const BilibiliCollectionImportException('合集列表未完整加载，请稍后重试');
      }
    }
  }
  if (ids.isEmpty) {
    throw const BilibiliCollectionImportException('这个合集暂时没有可导入的视频');
  }
  return ids.toList(growable: false);
}

/// Builds the same collection/video/part task tree as the online parser.
/// Fetching each video's full info also includes all parts of multipart
/// collection entries (space lists only carry the first cid).
Future<BilibiliDownloadTask> prepareBilibiliCollectionImport({
  required BilibiliDownloadService service,
  required BilibiliUploaderService uploader,
  required BilibiliCollectionImportSource source,
  SettingsService? settings,
  ImportPlacementRequest? placement,
}) async {
  final config = settings ?? SettingsService();
  final destination =
      placement ??
      config.captureImportPlacement(ImportCardFeature.bilibiliPage);
  final ids = await loadBilibiliCollectionBvids(
    source: source,
    uploader: uploader,
  );
  final infos = <BilibiliVideoInfo>[];
  // Small batches keep large collections from flooding the API, while
  // preserving their original order in the resulting folder.
  for (var start = 0; start < ids.length; start += 3) {
    infos.addAll(
      await Future.wait([
        for (final bvid in ids.skip(start).take(3))
          loadBilibiliImportVideoInfo(service, bvid),
      ]),
    );
  }
  final videos = <BilibiliVideoItem>[];
  for (var index = 0; index < infos.length; index++) {
    final info = infos[index];
    if (info.bvid != ids[index] ||
        info.pages.isEmpty ||
        info.pages.any((part) => part.cid <= 0 || part.page <= 0)) {
      throw BilibiliCollectionImportException('“${info.title}”的分P信息不完整，请稍后重试');
    }
    videos.add(
      BilibiliVideoItem(
        videoInfo: info,
        sourceRef: MediaSourceRef(
          kind: MediaSourceKind.bilibiliBv,
          value: info.bvid,
          bvid: info.bvid,
          originalValue: source.url,
        ),
        episodes: [
          for (final part in info.pages)
            BilibiliDownloadEpisode(
              page: part,
              bvid: info.bvid,
              isSelected: true,
            ),
        ],
        isSelected: true,
      ),
    );
  }
  return BilibiliDownloadTask(
    collectionInfo: BilibiliCollectionInfo(
      title: source.collection.title,
      cover:
          normalizeBilibiliImageUrl(source.collection.coverUrl) ??
          infos
              .map((info) => normalizeBilibiliImageUrl(info.pic))
              .whereType<String>()
              .firstOrNull ??
          '',
      videos: infos,
    ),
    videos: videos,
    sourceRef: MediaSourceRef(kind: MediaSourceKind.url, value: source.url),
    streamingPlacement: destination,
    isStreamingImport: true,
    isSelected: true,
    isExpanded: true,
  );
}

Future<BilibiliVideoInfo> loadBilibiliImportVideoInfo(
  BilibiliDownloadService service,
  String bvid,
) async {
  try {
    return await service.apiService.fetchVideoInfo(bvid);
  } catch (error, stack) {
    // The anonymous view endpoint can be rejected while the signed public
    // detail reader still works. Match the regular watch loader's fallback.
    try {
      final detail = await service.publicApi.fetchVideoDetail(bvid: bvid);
      if (detail.parts.isEmpty) throw StateError('detail without parts');
      return bilibiliWatchInfoFromDetail(detail);
    } catch (_) {
      Error.throwWithStackTrace(error, stack);
    }
  }
}

Future<int> importBilibiliCollection({
  required BilibiliDownloadService service,
  required LibraryService library,
  required BilibiliUploaderService uploader,
  required BilibiliCollectionImportSource source,
  ImportPlacementRequest? placement,
}) async {
  await service.init();
  final task = await prepareBilibiliCollectionImport(
    service: service,
    uploader: uploader,
    source: source,
    placement: placement,
  );
  final expected = task.videos.fold<int>(
    0,
    (sum, v) => sum + v.episodes.length,
  );
  final count = await service.importParsedStreamingTaskToLibrary(library, task);
  if (count != expected) {
    throw BilibiliCollectionImportException(
      '已导入 $count/$expected 个分P，可在哔哩哔哩在线解析页重试未完成的条目',
    );
  }
  return count;
}
