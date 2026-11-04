import '../utils/bilibili_image_url.dart';
import '../utils/bilibili_text.dart';

/// Models for browsing Bilibili (search results and the player's Bilibili
/// panel).
///
/// Every parser tolerates missing or mistyped fields and falls back to safe
/// defaults, so a partial API response never crashes the UI.

int readBiliInt(Object? value) {
  if (value is int) return value < 0 ? 0 : value;
  if (value is num) return value.isFinite && value > 0 ? value.toInt() : 0;
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed < 0 ? 0 : parsed;
    final asDouble = double.tryParse(value.trim());
    return asDouble != null && asDouble.isFinite && asDouble > 0
        ? asDouble.toInt()
        : 0;
  }
  return 0;
}

String readBiliText(Object? value, [String fallback = '']) {
  final text = value is String
      ? value.trim()
      : (value is num ? value.toString() : '');
  return text.isEmpty ? fallback : text;
}

Map<String, dynamic> readBiliMap(Object? value) {
  if (value is Map) {
    return value.map((key, v) => MapEntry(key.toString(), v));
  }
  return const <String, dynamic>{};
}

List<Map<String, dynamic>> readBiliMapList(Object? value) {
  if (value is! List) return const <Map<String, dynamic>>[];
  return value.whereType<Map>().map(readBiliMap).toList(growable: false);
}

DateTime? readBiliUnixTime(Object? value) {
  final seconds = readBiliInt(value);
  if (seconds <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

final RegExp _bvidExact = RegExp(r'^BV[0-9A-Za-z]{10}$');

bool isValidBvid(String value) => _bvidExact.hasMatch(value);

enum BilibiliVideoSearchOrder { totalrank, click, pubdate, dm, stow }

extension BilibiliVideoSearchOrderX on BilibiliVideoSearchOrder {
  String get apiValue => name;

  String get label => switch (this) {
    BilibiliVideoSearchOrder.totalrank => '综合排序',
    BilibiliVideoSearchOrder.click => '最多播放',
    BilibiliVideoSearchOrder.pubdate => '最新发布',
    BilibiliVideoSearchOrder.dm => '最多弹幕',
    BilibiliVideoSearchOrder.stow => '最多收藏',
  };
}

enum BilibiliVideoDurationFilter {
  any,
  under10,
  from10To30,
  from30To60,
  over60,
}

extension BilibiliVideoDurationFilterX on BilibiliVideoDurationFilter {
  int get apiValue => index;

  String get label => switch (this) {
    BilibiliVideoDurationFilter.any => '全部时长',
    BilibiliVideoDurationFilter.under10 => '10 分钟以下',
    BilibiliVideoDurationFilter.from10To30 => '10-30 分钟',
    BilibiliVideoDurationFilter.from30To60 => '30-60 分钟',
    BilibiliVideoDurationFilter.over60 => '60 分钟以上',
  };
}

enum BilibiliPublishedFilter { any, lastDay, lastWeek, lastHalfYear }

extension BilibiliPublishedFilterX on BilibiliPublishedFilter {
  String get label => switch (this) {
    BilibiliPublishedFilter.any => '全部时间',
    BilibiliPublishedFilter.lastDay => '最近一天',
    BilibiliPublishedFilter.lastWeek => '最近一周',
    BilibiliPublishedFilter.lastHalfYear => '最近半年',
  };

  Duration? get window => switch (this) {
    BilibiliPublishedFilter.any => null,
    BilibiliPublishedFilter.lastDay => const Duration(days: 1),
    BilibiliPublishedFilter.lastWeek => const Duration(days: 7),
    BilibiliPublishedFilter.lastHalfYear => const Duration(days: 183),
  };
}

/// Inclusive bounds in seconds; a null upper bound leaves long videos unrestricted.
class BilibiliVideoDurationRange {
  final int minimumSeconds;
  final int? maximumSeconds;

  const BilibiliVideoDurationRange({
    this.minimumSeconds = 0,
    this.maximumSeconds,
  }) : assert(minimumSeconds >= 0),
       assert(maximumSeconds == null || maximumSeconds >= minimumSeconds);

  bool get isRestricted => minimumSeconds > 0 || maximumSeconds != null;

  bool includes(int seconds) =>
      (seconds > 0 || !isRestricted) &&
      seconds >= minimumSeconds &&
      (maximumSeconds == null || seconds <= maximumSeconds!);

  // Use a server bucket only when neither endpoint touches an ambiguous boundary.
  int get apiValue {
    final upper = maximumSeconds;
    if (minimumSeconds > 3600) return 4;
    if (upper == null) return 0;
    if (upper < 600) return 1;
    if (minimumSeconds > 600 && upper < 1800) return 2;
    if (minimumSeconds > 1800 && upper < 3600) return 3;
    return 0;
  }

  static String formatSeconds(int seconds) {
    if (seconds == 0) return '0 分钟';
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    if (minutes == 0) return '$remainder 秒';
    return remainder == 0 ? '$minutes 分钟' : '$minutes 分 $remainder 秒';
  }

  String get label {
    if (!isRestricted) return '全部时长';
    if (maximumSeconds == null) return '${formatSeconds(minimumSeconds)}以上';
    if (minimumSeconds == 0) return '${formatSeconds(maximumSeconds!)}以内';
    return '${formatSeconds(minimumSeconds)} ～ ${formatSeconds(maximumSeconds!)}';
  }

  factory BilibiliVideoDurationRange.fromPreset(
    BilibiliVideoDurationFilter preset,
  ) => switch (preset) {
    BilibiliVideoDurationFilter.any => const BilibiliVideoDurationRange(),
    BilibiliVideoDurationFilter.under10 => const BilibiliVideoDurationRange(
      maximumSeconds: 600,
    ),
    BilibiliVideoDurationFilter.from10To30 => const BilibiliVideoDurationRange(
      minimumSeconds: 600,
      maximumSeconds: 1800,
    ),
    BilibiliVideoDurationFilter.from30To60 => const BilibiliVideoDurationRange(
      minimumSeconds: 1800,
      maximumSeconds: 3600,
    ),
    BilibiliVideoDurationFilter.over60 => const BilibiliVideoDurationRange(
      minimumSeconds: 3600,
    ),
  };

  @override
  bool operator ==(Object other) =>
      other is BilibiliVideoDurationRange &&
      minimumSeconds == other.minimumSeconds &&
      maximumSeconds == other.maximumSeconds;

  @override
  int get hashCode => Object.hash(minimumSeconds, maximumSeconds);
}

class BilibiliVideoSearchFilter {
  final BilibiliVideoSearchOrder order;
  final BilibiliVideoDurationFilter duration;
  final BilibiliPublishedFilter published;
  final BilibiliVideoDurationRange? durationRange;

  const BilibiliVideoSearchFilter({
    this.order = BilibiliVideoSearchOrder.totalrank,
    this.duration = BilibiliVideoDurationFilter.any,
    this.published = BilibiliPublishedFilter.any,
    this.durationRange,
  });

  BilibiliVideoSearchFilter copyWith({
    BilibiliVideoSearchOrder? order,
    BilibiliVideoDurationFilter? duration,
    BilibiliPublishedFilter? published,
    BilibiliVideoDurationRange? durationRange,
    bool clearDurationRange = false,
  }) => BilibiliVideoSearchFilter(
    order: order ?? this.order,
    duration: duration ?? this.duration,
    published: published ?? this.published,
    durationRange: clearDurationRange
        ? null
        : durationRange ?? this.durationRange,
  );

  @override
  bool operator ==(Object other) =>
      other is BilibiliVideoSearchFilter &&
      other.order == order &&
      other.duration == duration &&
      other.published == published &&
      other.durationRange == durationRange;

  @override
  int get hashCode => Object.hash(order, duration, published, durationRange);
}

/// Search pages are capped at 50 by Bilibili.
const int kBilibiliSearchMaxPages = 50;

class BilibiliSearchPage<T> {
  final List<T> items;
  final int page;
  final int numPages;

  const BilibiliSearchPage({
    required this.items,
    required this.page,
    required this.numPages,
  });

  bool get hasMore =>
      page < numPages && page < kBilibiliSearchMaxPages && items.isNotEmpty;
}

class BilibiliSearchVideo {
  final String bvid;
  final int aid;
  final String title;
  final String author;
  final int mid;
  final String? coverUrl;
  final int durationSeconds;
  final int playCount;
  final int danmakuCount;
  final DateTime? publishedAt;

  const BilibiliSearchVideo({
    required this.bvid,
    this.aid = 0,
    required this.title,
    this.author = '',
    this.mid = 0,
    this.coverUrl,
    this.durationSeconds = 0,
    this.playCount = 0,
    this.danmakuCount = 0,
    this.publishedAt,
  });

  /// Returns null when the item has no usable BV id (ads, live rooms...).
  static BilibiliSearchVideo? tryParse(Map<String, dynamic> json) {
    final bvid = readBiliText(json['bvid']);
    if (!isValidBvid(bvid)) return null;
    return BilibiliSearchVideo(
      bvid: bvid,
      aid: readBiliInt(json['aid'] ?? json['id']),
      title: stripBilibiliHighlight(readBiliText(json['title'], '未命名视频')),
      author: stripBilibiliHighlight(readBiliText(json['author'], '未知 UP 主')),
      mid: readBiliInt(json['mid']),
      coverUrl: bilibiliCoverThumbnailUrl(readBiliText(json['pic'])),
      durationSeconds: json['duration'] is num
          ? readBiliInt(json['duration'])
          : parseBilibiliDurationText(readBiliText(json['duration'])),
      playCount: readBiliInt(json['play']),
      danmakuCount: readBiliInt(json['danmaku'] ?? json['video_review']),
      publishedAt: readBiliUnixTime(json['pubdate']),
    );
  }
}

class BilibiliSearchUser {
  final int mid;
  final String name;
  final String? avatarUrl;
  final String sign;
  final int fans;
  final int videos;
  final int level;
  final String officialDesc;

  const BilibiliSearchUser({
    required this.mid,
    required this.name,
    this.avatarUrl,
    this.sign = '',
    this.fans = 0,
    this.videos = 0,
    this.level = 0,
    this.officialDesc = '',
  });

  static BilibiliSearchUser? tryParse(Map<String, dynamic> json) {
    final mid = readBiliInt(json['mid']);
    if (mid <= 0) return null;
    final official = readBiliMap(json['official_verify']);
    return BilibiliSearchUser(
      mid: mid,
      name: stripBilibiliHighlight(readBiliText(json['uname'], '未知用户')),
      avatarUrl: bilibiliAvatarUrl(readBiliText(json['upic'])),
      sign: stripBilibiliHighlight(readBiliText(json['usign'])),
      fans: readBiliInt(json['fans']),
      videos: readBiliInt(json['videos']),
      level: readBiliInt(json['level']),
      officialDesc: stripBilibiliHighlight(readBiliText(official['desc'])),
    );
  }
}

class BilibiliVideoOwner {
  final int mid;
  final String name;
  final String? avatarUrl;
  final String role;

  const BilibiliVideoOwner({
    this.mid = 0,
    this.name = '未知 UP 主',
    this.avatarUrl,
    this.role = '',
  });

  static BilibiliVideoOwner parse(
    Map<String, dynamic> json, {
    String role = '',
  }) {
    return BilibiliVideoOwner(
      mid: readBiliInt(json['mid']),
      name: readBiliText(json['name'], '未知 UP 主'),
      avatarUrl: bilibiliAvatarUrl(readBiliText(json['face'])),
      role: readBiliText(json['title'], role),
    );
  }
}

class BilibiliVideoStat {
  final int view;
  final int danmaku;
  final int reply;
  final int favorite;
  final int coin;
  final int share;
  final int like;

  const BilibiliVideoStat({
    this.view = 0,
    this.danmaku = 0,
    this.reply = 0,
    this.favorite = 0,
    this.coin = 0,
    this.share = 0,
    this.like = 0,
  });

  static BilibiliVideoStat parse(Map<String, dynamic> json) =>
      BilibiliVideoStat(
        view: readBiliInt(json['view']),
        danmaku: readBiliInt(json['danmaku']),
        reply: readBiliInt(json['reply']),
        favorite: readBiliInt(json['favorite']),
        coin: readBiliInt(json['coin']),
        share: readBiliInt(json['share']),
        like: readBiliInt(json['like']),
      );
}

class BilibiliVideoPart {
  final int cid;
  final int page;
  final String title;
  final int durationSeconds;

  const BilibiliVideoPart({
    required this.cid,
    required this.page,
    required this.title,
    this.durationSeconds = 0,
  });
}

class BilibiliSeasonEpisode {
  final String bvid;
  final String title;
  final String? coverUrl;
  final int durationSeconds;

  const BilibiliSeasonEpisode({
    required this.bvid,
    required this.title,
    this.coverUrl,
    this.durationSeconds = 0,
  });
}

class BilibiliVideoSeason {
  final int id;
  final String title;
  final String? coverUrl;
  final List<BilibiliSeasonEpisode> episodes;

  const BilibiliVideoSeason({
    required this.id,
    required this.title,
    this.coverUrl,
    this.episodes = const <BilibiliSeasonEpisode>[],
  });

  static BilibiliVideoSeason? tryParse(Object? raw) {
    final json = readBiliMap(raw);
    if (json.isEmpty) return null;
    final episodes = <BilibiliSeasonEpisode>[];
    final seen = <String>{};
    for (final section in readBiliMapList(json['sections'])) {
      for (final ep in readBiliMapList(section['episodes'])) {
        final arc = readBiliMap(ep['arc']);
        final bvid = readBiliText(ep['bvid'], readBiliText(arc['bvid']));
        if (!isValidBvid(bvid) || !seen.add(bvid)) continue;
        episodes.add(
          BilibiliSeasonEpisode(
            bvid: bvid,
            title: readBiliText(ep['title'], readBiliText(arc['title'], bvid)),
            coverUrl: bilibiliCoverThumbnailUrl(readBiliText(arc['pic'])),
            durationSeconds: readBiliInt(
              arc['duration'] ?? readBiliMap(ep['page'])['duration'],
            ),
          ),
        );
      }
    }
    final id = readBiliInt(json['id']);
    if (id <= 0 && episodes.isEmpty) return null;
    return BilibiliVideoSeason(
      id: id,
      title: readBiliText(json['title'], '合集'),
      coverUrl: normalizeBilibiliImageUrl(readBiliText(json['cover'])),
      episodes: List<BilibiliSeasonEpisode>.unmodifiable(episodes),
    );
  }
}

class BilibiliVideoDetail {
  final String bvid;
  final int aid;
  final String title;
  final String? coverUrl;
  final String description;
  final BilibiliVideoOwner owner;
  final List<BilibiliVideoOwner> staff;
  final BilibiliVideoStat stat;
  final DateTime? publishedAt;
  final int durationSeconds;
  final List<BilibiliVideoPart> parts;
  final BilibiliVideoSeason? season;
  final List<String> tags;

  /// `copyright` of the view answer: 1 original, 2 reprint, 0 unknown.
  final int copyright;

  const BilibiliVideoDetail({
    required this.bvid,
    this.aid = 0,
    required this.title,
    this.coverUrl,
    this.description = '',
    this.owner = const BilibiliVideoOwner(),
    this.staff = const <BilibiliVideoOwner>[],
    this.stat = const BilibiliVideoStat(),
    this.publishedAt,
    this.durationSeconds = 0,
    this.parts = const <BilibiliVideoPart>[],
    this.season,
    this.tags = const <String>[],
    this.copyright = 0,
  });

  bool get isReprint => copyright == 2;

  BilibiliVideoDetail withTags(List<String> value) => BilibiliVideoDetail(
    bvid: bvid,
    aid: aid,
    title: title,
    coverUrl: coverUrl,
    description: description,
    owner: owner,
    staff: staff,
    stat: stat,
    publishedAt: publishedAt,
    durationSeconds: durationSeconds,
    parts: parts,
    season: season,
    tags: List<String>.unmodifiable(value),
    copyright: copyright,
  );

  /// Parses the `data` object of `/x/web-interface/view`.
  /// Returns null only when there is no usable BV id.
  static BilibiliVideoDetail? tryParse(Map<String, dynamic> data) {
    final bvid = readBiliText(data['bvid']);
    if (!isValidBvid(bvid)) return null;
    final duration = readBiliInt(data['duration']);
    final parts = <BilibiliVideoPart>[];
    for (final page in readBiliMapList(data['pages'])) {
      final cid = readBiliInt(page['cid']);
      if (cid <= 0) continue;
      final index = readBiliInt(page['page']);
      parts.add(
        BilibiliVideoPart(
          cid: cid,
          page: index > 0 ? index : parts.length + 1,
          title: readBiliText(page['part'], 'P${parts.length + 1}'),
          durationSeconds: readBiliInt(page['duration']),
        ),
      );
    }
    if (parts.isEmpty) {
      final cid = readBiliInt(data['cid']);
      if (cid > 0) {
        parts.add(
          BilibiliVideoPart(
            cid: cid,
            page: 1,
            title: 'P1',
            durationSeconds: duration,
          ),
        );
      }
    }
    final rawDesc = readBiliText(data['desc']);
    return BilibiliVideoDetail(
      bvid: bvid,
      aid: readBiliInt(data['aid']),
      title: readBiliText(data['title'], '未命名视频'),
      coverUrl: bilibiliCoverThumbnailUrl(readBiliText(data['pic'])),
      description: rawDesc == '-' ? '' : rawDesc,
      owner: BilibiliVideoOwner.parse(readBiliMap(data['owner'])),
      staff: readBiliMapList(
        data['staff'],
      ).map((s) => BilibiliVideoOwner.parse(s)).toList(growable: false),
      stat: BilibiliVideoStat.parse(readBiliMap(data['stat'])),
      publishedAt: readBiliUnixTime(data['pubdate']),
      durationSeconds: duration,
      parts: List<BilibiliVideoPart>.unmodifiable(parts),
      season: BilibiliVideoSeason.tryParse(data['ugc_season']),
      copyright: readBiliInt(data['copyright']),
    );
  }
}

/// Parses `/x/tag/archive/tags` data: at most 16 unique, non-empty names.
List<String> parseBilibiliTags(Object? data) {
  final out = <String>[];
  final seen = <String>{};
  for (final tag in readBiliMapList(data)) {
    final name = readBiliText(tag['tag_name']);
    if (name.isEmpty || name.length > 30 || !seen.add(name)) continue;
    out.add(name);
    if (out.length >= 16) break;
  }
  return List<String>.unmodifiable(out);
}
