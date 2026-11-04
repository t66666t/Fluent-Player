import '../../models/bilibili_browse_models.dart';
import '../../models/bilibili_favorites_models.dart';
import '../../models/bilibili_uploader_models.dart';
import 'bilibili_public_api_service.dart';

/// Account collection reads use the existing browser session and network scope.
class BilibiliFavoritesService {
  BilibiliFavoritesService({BilibiliPublicApiService? api})
    : _api = api ?? BilibiliPublicApiService();

  final BilibiliPublicApiService _api;

  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliFavoriteFolder>>>
  fetchFolders(int mid, {int page = 1}) async {
    if (mid <= 0) return _invalid('请先登录 B 站');
    final pn = page.clamp(1, kBilibiliUploaderMaxPages);
    final result = await _read(
      '/x/v3/fav/folder/created/list',
      mid: mid,
      query: {'up_mid': mid, 'pn': pn, 'ps': kBilibiliUploaderPageSize},
      what: '收藏夹',
    );
    if (!result.isSuccess) return result.cast();
    final data = result.data!;
    final raw = data['list'];
    if (!data.containsKey('count') ||
        (raw is! List && (raw != null || readBiliInt(data['count']) > 0))) {
      return _invalid('收藏夹数据不完整，请刷新重试');
    }
    final folders = <BilibiliFavoriteFolder>[];
    for (final json in readBiliMapList(raw)) {
      final owner = readBiliInt(json['mid']);
      if (owner != 0 && owner != mid) return _invalid('收藏夹账号不匹配，请刷新重试');
      final folder = BilibiliFavoriteFolder.tryParse(json);
      if (folder != null) folders.add(folder);
    }
    return BilibiliUploaderResult.success(
      BilibiliUploaderPage(
        items: folders,
        page: pn,
        total: readBiliInt(data['count']),
        hasMoreHint: _hasMore(data['has_more']),
      ),
    );
  }

  Future<BilibiliUploaderResult<BilibiliFavoriteVideoPage>> fetchVideos(
    int mid,
    int folderId, {
    int page = 1,
    bool limitToBrowsePages = true,
  }) async {
    if (mid <= 0 || folderId <= 0) return _invalid('收藏夹信息无效，请刷新重试');
    final pn = limitToBrowsePages
        ? page.clamp(1, kBilibiliUploaderMaxPages)
        : (page < 1 ? 1 : page);
    final result = await _read(
      '/x/v3/fav/resource/list',
      mid: mid,
      query: {
        'media_id': folderId,
        'pn': pn,
        'ps': kBilibiliUploaderPageSize,
        'order': 'mtime',
        'type': 0,
        'tid': 0,
        'platform': 'web',
      },
      what: '收藏视频',
    );
    if (!result.isSuccess) return result.cast();
    final data = result.data!;
    final info = readBiliMap(data['info']);
    final folder = BilibiliFavoriteFolder.tryParse(info);
    if (folder == null || folder.id != folderId) {
      return _invalid('收藏夹信息不完整，请刷新重试');
    }
    final owner = readBiliInt(readBiliMap(info['upper'])['mid'] ?? info['mid']);
    if (owner != 0 && owner != mid) return _invalid('收藏夹账号不匹配，请刷新重试');
    final raw = data['medias'];
    if (raw is! List && (raw != null || folder.mediaCount > 0)) {
      return _invalid('收藏视频数据不完整，请刷新重试');
    }
    return BilibiliUploaderResult.success(
      BilibiliFavoriteVideoPage(
        folder: folder,
        items: [
          for (final json in readBiliMapList(raw))
            ?BilibiliFavoriteVideo.tryParse(json),
        ],
        page: pn,
        total: folder.mediaCount,
        hasMoreHint: _hasMore(data['has_more']),
      ),
    );
  }

  static bool? _hasMore(Object? value) => switch (value) {
    bool more => more,
    0 => false,
    1 => true,
    _ => null,
  };

  /// Read the source completely before publishing a full-folder selection.
  Future<BilibiliFavoriteContents> fetchAllVideos(
    int mid,
    int folderId, {
    bool Function()? isCancelled,
    void Function(int loaded, int total)? onProgress,
  }) async {
    final entries = <String, BilibiliFavoriteVideo>{};
    BilibiliFavoriteFolder? folder;
    for (var page = 1; ; page++) {
      if (isCancelled?.call() == true) throw const BilibiliFavoritesCancelled();
      final result = await fetchVideos(
        mid,
        folderId,
        page: page,
        limitToBrowsePages: false,
      );
      if (isCancelled?.call() == true) throw const BilibiliFavoritesCancelled();
      if (!result.isSuccess) throw BilibiliFavoritesException(result.message);
      final data = result.data!;
      folder = data.folder;
      final before = entries.length;
      for (final video in data.items) {
        entries.putIfAbsent(video.key, () => video);
      }
      onProgress?.call(entries.length, data.total);
      final more =
          data.hasMoreHint ??
          (data.items.length >= data.pageSize &&
              (data.total == 0 || entries.length < data.total));
      if (!more) {
        if (data.total > entries.length) {
          throw const BilibiliFavoritesException('收藏夹列表未完整返回，请重试');
        }
        return BilibiliFavoriteContents(
          folder: folder,
          entries: entries.values.toList(),
        );
      }
      if (before == entries.length) {
        throw const BilibiliFavoritesException('收藏夹分页没有返回新的内容，请重试');
      }
    }
  }

  static BilibiliUploaderResult<T> _invalid<T>(String message) =>
      BilibiliUploaderResult.failure(BilibiliUploaderStatus.failed, message);

  Future<BilibiliUploaderResult<Map<String, dynamic>>> _read(
    String path, {
    required int mid,
    required Map<String, dynamic> query,
    required String what,
  }) async {
    try {
      for (var attempt = 1; attempt <= 2; attempt++) {
        final payload = await _api.getPublicJson(
          path,
          query: query,
          referer: 'https://space.bilibili.com/$mid/favlist',
          origin: 'https://space.bilibili.com',
          what: what,
          attempt: attempt,
        );
        final rawCode = payload['code'];
        final code = rawCode is int ? rawCode : null;
        if (BilibiliPublicApiService.isRiskControlPayload(payload)) {
          if (attempt == 1) {
            await _api.renewAfterRiskControl();
            continue;
          }
          return BilibiliUploaderResult.failure(
            BilibiliUploaderStatus.riskControlled,
            BilibiliPublicApiService.riskControlMessage(what, payload),
            code: code,
          );
        }
        if (code == -101) {
          return BilibiliUploaderResult.failure(
            BilibiliUploaderStatus.failed,
            'B 站登录已失效，请重新登录',
            code: code,
          );
        }
        if (code != 0) {
          final hidden =
              code == -403 ||
              code == -404 ||
              code == 11201 ||
              code == 11203 ||
              code == 7201006;
          return BilibiliUploaderResult.failure(
            hidden
                ? BilibiliUploaderStatus.notFound
                : BilibiliUploaderStatus.failed,
            hidden ? '$what不存在或不可访问' : '$what加载失败，请稍后重试',
            code: code,
          );
        }
        final data = payload['data'];
        if (data is! Map) return _invalid('$what不存在或暂时不可访问');
        return BilibiliUploaderResult.success(readBiliMap(data));
      }
    } on BilibiliPublicApiException catch (error) {
      return BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.networkError,
        error.message,
      );
    } catch (_) {
      return BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.networkError,
        '$what加载失败，请检查网络后重试',
      );
    }
    return _invalid('$what加载失败，请稍后重试');
  }
}
