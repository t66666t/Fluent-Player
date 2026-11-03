import '../utils/bilibili_image_url.dart';
import '../utils/bilibili_text.dart';
import 'bilibili_browse_models.dart';

// Models for an uploader's (UP 主) public data: profile card, uploaded
// videos, articles and collections. Parsers tolerate missing or mistyped
// fields like the browse models do.

/// Videos per page of an uploader's list.
const int kBilibiliUploaderPageSize = 20;

/// Pages an uploader list may go to.
const int kBilibiliUploaderMaxPages = 50;

enum BilibiliUploaderStatus {
  success,

  /// Blocked by risk control (-352, -412, -799 or HTTP 412).
  riskControlled,

  /// The uploader or list does not exist.
  notFound,

  /// Bilibili answered with another error.
  failed,

  /// No usable answer (network, HTTP error, unreadable data).
  networkError,
}

/// Outcome of an uploader read. Never thrown; [message] is user-facing
/// Chinese text and [data] is only set on success.
class BilibiliUploaderResult<T> {
  final BilibiliUploaderStatus status;
  final T? data;
  final String message;

  /// Bilibili business code, when a JSON answer came back.
  final int? code;

  const BilibiliUploaderResult._(
    this.status, {
    this.data,
    this.message = '',
    this.code,
  });

  const BilibiliUploaderResult.success(T value)
    : this._(BilibiliUploaderStatus.success, data: value);

  const BilibiliUploaderResult.failure(
    BilibiliUploaderStatus status,
    String message, {
    int? code,
  }) : this._(status, message: message, code: code);

  static const String riskMessage = '请求被 B 站风控，稍后再试';

  bool get isSuccess => status == BilibiliUploaderStatus.success;

  /// Same failure, retyped for another payload.
  BilibiliUploaderResult<R> cast<R>() =>
      BilibiliUploaderResult<R>._(status, message: message, code: code);
}

class BilibiliUploaderProfile {
  final int mid;
  final String name;
  final String? avatarUrl;
  final String sign;
  final int level;

  /// Official verification text, empty when none.
  final String officialTitle;

  /// Null when unknown (the supplement request failed).
  final int? following;
  final int? follower;
  final int? archiveCount;
  final int? likeCount;

  const BilibiliUploaderProfile({
    required this.mid,
    required this.name,
    this.avatarUrl,
    this.sign = '',
    this.level = 0,
    this.officialTitle = '',
    this.following,
    this.follower,
    this.archiveCount,
    this.likeCount,
  });

  BilibiliUploaderProfile withRelation({int? following, int? follower}) =>
      BilibiliUploaderProfile(
        mid: mid,
        name: name,
        avatarUrl: avatarUrl,
        sign: sign,
        level: level,
        officialTitle: officialTitle,
        following: following ?? this.following,
        follower: follower ?? this.follower,
        archiveCount: archiveCount,
        likeCount: likeCount,
      );

  /// `data` of `/x/web-interface/card`.
  static BilibiliUploaderProfile? tryParseCard(Map<String, dynamic> data) {
    final card = readBiliMap(data['card']);
    final mid = readBiliInt(card['mid']);
    if (mid <= 0) return null;
    final official = readBiliMap(card['Official']).isNotEmpty
        ? readBiliMap(card['Official'])
        : readBiliMap(card['official_verify']);
    return BilibiliUploaderProfile(
      mid: mid,
      name: readBiliText(card['name'], '未知 UP 主'),
      avatarUrl: bilibiliAvatarUrl(readBiliText(card['face'])),
      sign: readBiliText(card['sign']),
      level: readBiliInt(readBiliMap(card['level_info'])['current_level']),
      officialTitle: readBiliText(
        official['title'],
        readBiliText(official['desc']),
      ),
      following: _optionalInt(card['attention']),
      follower: _optionalInt(data['follower'] ?? card['fans']),
      archiveCount: _optionalInt(data['archive_count']),
      likeCount: _optionalInt(data['like_num']),
    );
  }

  /// `data` of `/x/space/wbi/acc/info`; it carries no counts.
  static BilibiliUploaderProfile? tryParseAccount(Map<String, dynamic> data) {
    final mid = readBiliInt(data['mid']);
    if (mid <= 0) return null;
    return BilibiliUploaderProfile(
      mid: mid,
      name: readBiliText(data['name'], '未知 UP 主'),
      avatarUrl: bilibiliAvatarUrl(readBiliText(data['face'])),
      sign: readBiliText(data['sign']),
      level: readBiliInt(data['level']),
      officialTitle: readBiliText(readBiliMap(data['official'])['title']),
    );
  }

  static int? _optionalInt(Object? value) =>
      value == null ? null : readBiliInt(value);
}

/// Sort order of an uploader's video list.
enum BilibiliUploaderVideoOrder {
  latest('pubdate', '最新发布'),
  mostPlayed('click', '最多播放'),
  mostFavorited('stow', '最多收藏');

  const BilibiliUploaderVideoOrder(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

/// One page of an uploader list.
class BilibiliUploaderPage<T> {
  final List<T> items;
  final int page;
  final int pageSize;

  /// Total items Bilibili reports for the whole list.
  final int total;

  /// Some lists report continuation separately from their item count.
  final bool? hasMoreHint;

  const BilibiliUploaderPage({
    required this.items,
    required this.page,
    this.pageSize = kBilibiliUploaderPageSize,
    this.total = 0,
    this.hasMoreHint,
  });

  int get pageCount {
    final pages = (total + pageSize - 1) ~/ pageSize;
    return pages > kBilibiliUploaderMaxPages
        ? kBilibiliUploaderMaxPages
        : pages;
  }

  bool get hasMore => hasMoreHint ?? (items.isNotEmpty && page < pageCount);
}

class BilibiliUploaderVideo {
  final String bvid;
  final int aid;
  final String title;
  final String? coverUrl;
  final String description;
  final int durationSeconds;
  final int playCount;
  final int commentCount;
  final DateTime? publishedAt;

  const BilibiliUploaderVideo({
    required this.bvid,
    this.aid = 0,
    required this.title,
    this.coverUrl,
    this.description = '',
    this.durationSeconds = 0,
    this.playCount = 0,
    this.commentCount = 0,
    this.publishedAt,
  });

  /// An item of `data.list.vlist` of the space video search, or of
  /// `data.archives` of a collection's video list.
  static BilibiliUploaderVideo? tryParse(Map<String, dynamic> json) {
    final bvid = readBiliText(json['bvid']);
    if (!isValidBvid(bvid)) return null;
    final length = json['length'] ?? json['duration'];
    return BilibiliUploaderVideo(
      bvid: bvid,
      aid: readBiliInt(json['aid']),
      title: stripBilibiliHighlight(readBiliText(json['title'], '未命名视频')),
      coverUrl: bilibiliCoverThumbnailUrl(readBiliText(json['pic'])),
      description: readBiliText(json['description']),
      durationSeconds: length is num
          ? readBiliInt(length)
          : parseBilibiliDurationText(readBiliText(length)),
      playCount: readBiliInt(json['play'] ?? readBiliMap(json['stat'])['view']),
      commentCount: readBiliInt(
        json['comment'] ?? readBiliMap(json['stat'])['reply'],
      ),
      publishedAt: readBiliUnixTime(json['created'] ?? json['pubdate']),
    );
  }
}

class BilibiliUploaderArticle {
  final int id;
  final String title;
  final String summary;
  final String? coverUrl;
  final int viewCount;
  final int likeCount;
  final DateTime? publishedAt;

  const BilibiliUploaderArticle({
    required this.id,
    required this.title,
    this.summary = '',
    this.coverUrl,
    this.viewCount = 0,
    this.likeCount = 0,
    this.publishedAt,
  });

  /// An item of `data.articles` of the space article list.
  static BilibiliUploaderArticle? tryParse(Map<String, dynamic> json) {
    final id = readBiliInt(json['id']);
    if (id <= 0) return null;
    final images = json['image_urls'];
    final banner = readBiliText(json['banner_url']);
    final cover = banner.isNotEmpty
        ? banner
        : (images is List && images.isNotEmpty
              ? readBiliText(images.first)
              : '');
    final stats = readBiliMap(json['stats']);
    return BilibiliUploaderArticle(
      id: id,
      title: readBiliText(json['title'], '未命名专栏'),
      summary: readBiliText(json['summary']),
      coverUrl: bilibiliCoverThumbnailUrl(cover),
      viewCount: readBiliInt(stats['view']),
      likeCount: readBiliInt(stats['like']),
      publishedAt: readBiliUnixTime(json['publish_time']),
    );
  }
}

/// A collection on the uploader's space: a season (合集) or an older series
/// (系列).
class BilibiliUploaderCollection {
  final int id;
  final bool isSeason;
  final String title;
  final String? coverUrl;
  final String description;
  final int videoCount;

  const BilibiliUploaderCollection({
    required this.id,
    required this.isSeason,
    required this.title,
    this.coverUrl,
    this.description = '',
    this.videoCount = 0,
  });

  /// An item of `seasons_list` or `series_list`.
  static BilibiliUploaderCollection? tryParse(
    Map<String, dynamic> json, {
    required bool isSeason,
  }) {
    final meta = readBiliMap(json['meta']);
    final id = readBiliInt(isSeason ? meta['season_id'] : meta['series_id']);
    if (id <= 0) return null;
    return BilibiliUploaderCollection(
      id: id,
      isSeason: isSeason,
      title: readBiliText(meta['name'], isSeason ? '未命名合集' : '未命名系列'),
      coverUrl: bilibiliCoverThumbnailUrl(readBiliText(meta['cover'])),
      description: readBiliText(meta['description']),
      videoCount: readBiliInt(meta['total']),
    );
  }
}
