import '../utils/bilibili_image_url.dart';
import '../utils/bilibili_text.dart';
import 'bilibili_browse_models.dart';
import 'bilibili_uploader_models.dart';

class BilibiliFavoriteFolder {
  const BilibiliFavoriteFolder({
    required this.id,
    required this.title,
    this.coverUrl,
    this.mediaCount = 0,
    this.isPublic = true,
  });

  final int id;
  final String title;
  final String? coverUrl;
  final int mediaCount;
  final bool isPublic;

  static BilibiliFavoriteFolder? tryParse(Map<String, dynamic> json) {
    final id = readBiliInt(json['id']);
    if (id <= 0) return null;
    return BilibiliFavoriteFolder(
      id: id,
      title: stripBilibiliHighlight(readBiliText(json['title'], '未命名收藏夹')),
      coverUrl: bilibiliCoverThumbnailUrl(readBiliText(json['cover'])),
      mediaCount: readBiliInt(json['media_count']),
      isPublic: readBiliInt(json['attr']) & 1 == 0,
    );
  }
}

class BilibiliFavoritesCancelled implements Exception {
  const BilibiliFavoritesCancelled();
}

class BilibiliFavoritesException implements Exception {
  const BilibiliFavoritesException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BilibiliFavoriteContents {
  BilibiliFavoriteContents({
    required this.folder,
    required List<BilibiliFavoriteVideo> entries,
  }) : entries = List.unmodifiable(entries);

  final BilibiliFavoriteFolder folder;
  final List<BilibiliFavoriteVideo> entries;
  List<BilibiliFavoriteVideo> get playable =>
      entries.where((video) => video.canPlay).toList(growable: false);
  int get skipped => entries.where((video) => !video.canPlay).length;
}

class BilibiliFavoriteVideo {
  const BilibiliFavoriteVideo({
    required this.id,
    required this.type,
    required this.bvid,
    required this.title,
    this.coverUrl,
    this.ownerName = '',
    this.durationSeconds = 0,
    this.unavailable = false,
    this.favoredAt,
  });

  final int id;
  final int type;
  final String bvid;
  final String title;
  final String? coverUrl;
  final String ownerName;
  final int durationSeconds;
  final bool unavailable;
  final DateTime? favoredAt;

  String get key => '$type:$id';
  bool get canPlay => type == 2 && !unavailable && isValidBvid(bvid);
  String get unavailableLabel => type == 2 ? '视频已失效或不可访问' : '暂不支持此收藏类型';

  static BilibiliFavoriteVideo? tryParse(Map<String, dynamic> json) {
    final id = readBiliInt(json['id']);
    if (id <= 0) return null;
    final upper = readBiliMap(json['upper']);
    return BilibiliFavoriteVideo(
      id: id,
      type: readBiliInt(json['type']),
      bvid: readBiliText(json['bvid'], readBiliText(json['bv_id'])),
      title: stripBilibiliHighlight(readBiliText(json['title'], '未命名视频')),
      coverUrl: bilibiliCoverThumbnailUrl(readBiliText(json['cover'])),
      ownerName: readBiliText(upper['name']),
      durationSeconds: readBiliInt(json['duration']),
      unavailable: readBiliInt(json['attr']) & 1 != 0,
      favoredAt: readBiliUnixTime(json['fav_time']),
    );
  }
}

class BilibiliFavoriteVideoPage
    extends BilibiliUploaderPage<BilibiliFavoriteVideo> {
  const BilibiliFavoriteVideoPage({
    required this.folder,
    required super.items,
    required super.page,
    required super.total,
    required super.hasMoreHint,
  });

  final BilibiliFavoriteFolder folder;
}
