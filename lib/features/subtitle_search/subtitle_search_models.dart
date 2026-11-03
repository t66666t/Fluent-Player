import 'package:path/path.dart' as p;

import '../../models/subtitle_model.dart';
import 'subtitle_release_info.dart';

enum SubtitleSearchSource { subhd, jimaku, xunlei, opensubtitles, assrt, subdl }

/// How a catalog id was obtained. A search filter must not be stored as linked.
enum SubtitleCatalogEvidence { unspecified, linked, conflict, unknown }

enum SubtitleQualification { confirmed, incomplete }

extension SubtitleSearchSourceInfo on SubtitleSearchSource {
  bool get requiresKey =>
      this != SubtitleSearchSource.xunlei &&
      this != SubtitleSearchSource.subhd &&
      this != SubtitleSearchSource.jimaku;
  String get label => switch (this) {
    SubtitleSearchSource.subhd => 'SubHD',
    SubtitleSearchSource.xunlei => '迅雷字幕',
    SubtitleSearchSource.opensubtitles => 'OpenSubtitles',
    SubtitleSearchSource.jimaku => 'Jimaku',
    SubtitleSearchSource.assrt => 'ASSRT',
    SubtitleSearchSource.subdl => 'SubDL',
  };
  String get description => switch (this) {
    SubtitleSearchSource.subhd => '直接可用 · 按作品与季度查找中文、双语和整季字幕',
    SubtitleSearchSource.xunlei => '补充来源 · 建议使用片名与明确的季集编号',
    SubtitleSearchSource.opensubtitles => '电影、美剧与多语言字幕',
    SubtitleSearchSource.jimaku => '直接可用 · 日语动画与日本影视原文字幕',
    SubtitleSearchSource.assrt => '中文、双语字幕 · 由 assrt.net 提供',
    SubtitleSearchSource.subdl => '电影、剧集与整季字幕',
  };
  Uri get website => Uri.parse(switch (this) {
    SubtitleSearchSource.subhd => 'https://subhd.tv/',
    SubtitleSearchSource.xunlei => 'https://www.xunlei.com/',
    SubtitleSearchSource.opensubtitles => 'https://www.opensubtitles.com/',
    SubtitleSearchSource.jimaku => 'https://jimaku.cc/',
    SubtitleSearchSource.assrt => 'https://assrt.net/',
    SubtitleSearchSource.subdl => 'https://subdl.com/',
  });
  Uri get accountUrl => Uri.parse(switch (this) {
    SubtitleSearchSource.subhd => 'https://subhd.tv/',
    SubtitleSearchSource.xunlei => 'https://www.xunlei.com/',
    SubtitleSearchSource.opensubtitles =>
      'https://www.opensubtitles.com/consumers',
    SubtitleSearchSource.jimaku => 'https://jimaku.cc/account',
    SubtitleSearchSource.assrt => 'https://assrt.net/usercp.php',
    SubtitleSearchSource.subdl => 'https://subdl.com/panel/api',
  });
}

class SubtitleSearchCredentials {
  const SubtitleSearchCredentials({
    this.apiKey = '',
    this.username = '',
    this.password = '',
  });
  final String apiKey;
  final String username;
  final String password;
  bool get configured => apiKey.trim().isNotEmpty;
  Map<String, Object?> toJson() => {
    'key': apiKey,
    'username': username,
    'password': password,
  };
  factory SubtitleSearchCredentials.fromJson(Map<String, dynamic> json) =>
      SubtitleSearchCredentials(
        apiKey: json['key'] as String? ?? '',
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
      );
}

class SubtitleSearchQuery {
  const SubtitleSearchQuery({
    required this.text,
    this.language = '',
    this.season,
    this.episode,
    this.page = 1,
    this.work,
  });
  final String text;
  final String language;
  final int? season;
  final int? episode;
  final int page;
  final SubtitleSearchWork? work;
  String get cacheKey => '$text|$language|$season|$episode|$page|${work?.id}';
  SubtitleSearchQuery atPage(int value) => SubtitleSearchQuery(
    text: text,
    language: language,
    season: season,
    episode: episode,
    page: value,
    work: work,
  );

  static String cleanTitle(String title) =>
      SubtitleReleaseInfo.cleanTitle(title);

  static (int?, int?) episodeFrom(String title) {
    final info = SubtitleReleaseInfo.parse(title);
    return (info.season, info.episode);
  }
}

class SubtitleSearchWork {
  const SubtitleSearchWork({
    required this.id,
    required this.title,
    this.originalTitle = '',
    this.year = '',
    this.type = '',
    this.poster = '',
  });
  final String id, title, originalTitle, year, type, poster;
  int? get season => SubtitleReleaseInfo.parse(title).season;
  bool get isMovie => type == 'Movie';
  List<String> get aliases => [
    title,
    if (originalTitle.isNotEmpty) originalTitle,
  ];
  Map<String, String> toJson() => {
    'id': id,
    'title': title,
    'originalTitle': originalTitle,
    'year': year,
    'type': type,
    'poster': poster,
  };
  factory SubtitleSearchWork.fromJson(Map<String, dynamic> value) =>
      SubtitleSearchWork(
        id: '${value['id'] ?? ''}',
        title: '${value['title'] ?? ''}',
        originalTitle: '${value['originalTitle'] ?? value['title2'] ?? ''}',
        year: '${value['year'] ?? ''}',
        type: '${value['type'] ?? ''}',
        poster: '${value['poster'] ?? ''}',
      );
}

class SubtitleSearchFile {
  const SubtitleSearchFile({
    required this.id,
    required this.name,
    this.url,
    this.size = 0,
    this.language = '',
    this.archiveEntries = const [],
    this.declaredOnly = false,
    this.containerLabel = '',
  });
  final String id;
  final String name;
  final String? url;
  final int size;
  final String language;

  /// Names published by the website. They are not a verified container listing.
  final List<String> archiveEntries;
  final bool declaredOnly;
  final String containerLabel;

  String get availabilityLabel {
    if (containerLabel.isNotEmpty) return containerLabel;
    if (archiveEntries.isNotEmpty) {
      return '网站列出 ${archiveEntries.length} 份，尚未验证';
    }
    return '字幕资源包，格式待检查';
  }
}

class SubtitleSearchHit {
  const SubtitleSearchHit({
    required this.source,
    required this.id,
    required this.title,
    this.release = '',
    this.language = '',
    this.format = '',
    this.downloads = 0,
    this.hearingImpaired = false,
    this.files = const [],
    this.websiteUrl,
    this.season,
    this.episode,
    this.episodeEnd,
    this.fullSeason = false,
    this.catalogId,
    this.mediaType = '',
    this.workTitle = '',
    this.queryCatalogId,
    this.catalogEvidence = SubtitleCatalogEvidence.unspecified,
    this.qualification = SubtitleQualification.confirmed,
  });
  final SubtitleSearchSource source;
  final String id;
  final String title;
  final String release;
  final String language;
  final String format;
  final int downloads;
  final bool hearingImpaired;
  final List<SubtitleSearchFile> files;
  final String? websiteUrl;
  final int? season, episode, episodeEnd;
  final bool fullSeason;
  final String? catalogId;
  final String mediaType;
  final String workTitle;
  final String? queryCatalogId;
  final SubtitleCatalogEvidence catalogEvidence;
  final SubtitleQualification qualification;

  /// A catalog id copied from the search box is not a verified relationship.
  bool get catalogVerified =>
      catalogId != null &&
      catalogId!.isNotEmpty &&
      catalogEvidence != SubtitleCatalogEvidence.conflict &&
      catalogEvidence != SubtitleCatalogEvidence.unknown;
  SubtitleReleaseInfo get releaseInfo {
    final file = SubtitleReleaseInfo.parse(release);
    final name = SubtitleReleaseInfo.parse(title);
    return SubtitleReleaseInfo(
      season: season ?? file.season ?? name.season,
      seasonEnd: file.seasonEnd ?? name.seasonEnd,
      episode: episode ?? file.episode ?? name.episode,
      episodeEnd: episodeEnd ?? file.episodeEnd ?? name.episodeEnd,
      pack: fullSeason || file.pack || name.pack,
      special: file.special || name.special,
      series: file.series,
      videoSource: file.videoSource,
    );
  }

  Uri? get detailUri {
    final uri = Uri.tryParse(websiteUrl ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty) {
      return null;
    }
    final host = source.website.host.replaceFirst('www.', '');
    return (uri.host == host || uri.host.endsWith('.$host')) &&
            uri.path != '/' &&
            uri.path.isNotEmpty
        ? uri
        : null;
  }

  String get key => '${source.name}:$id';
}

class SubtitleSearchPage {
  const SubtitleSearchPage(this.hits, {this.hasMore = false});
  final List<SubtitleSearchHit> hits;
  final bool hasMore;
}

class SubtitleSearchDocument {
  const SubtitleSearchDocument({
    required this.name,
    required this.content,
    required this.cues,
    this.entryId = '',
    this.encoding = '',
    this.format = '',
    this.languages = const [],
    this.languageEvidence = '',
    this.contentHash = '',
    this.warnings = const [],
  });
  final String name;
  final String content;
  final List<SubtitleItem> cues;
  final String entryId;
  final String encoding;
  final String format;
  final List<String> languages;
  final String languageEvidence;
  final String contentHash;
  final List<String> warnings;
  String get languageLabel => languages.isEmpty ? '' : languages.join('+');
  Duration get duration => cues.fold(
    Duration.zero,
    (end, cue) => cue.endTime > end ? cue.endTime : end,
  );
}

enum SubtitleSearchImportRole { primary, secondary, saveOnly }

class SubtitleSearchImportRequest {
  const SubtitleSearchImportRequest({
    required this.hit,
    required this.document,
    required this.role,
    this.offsetMs = 0,
  });
  final SubtitleSearchHit hit;
  final SubtitleSearchDocument document;
  final SubtitleSearchImportRole role;
  final int offsetMs;

  String get content => offsetMs == 0
      ? document.content
      : _shifted(document, offsetMs);
  String get extension {
    final original = p.extension(document.name).toLowerCase();
    if (offsetMs == 0) return original.isEmpty ? '.srt' : original;
    if (original == '.ass' || original == '.ssa') return original;
    return '.srt';
  }

  static String _shifted(SubtitleSearchDocument document, int offsetMs) {
    final format = document.format.isNotEmpty
        ? document.format
        : p.extension(document.name).toLowerCase().replaceFirst('.', '');
    if (format == 'ass' || format == 'ssa') return _shiftAss(document.content, offsetMs);
    return [
      for (final (index, cue) in document.cues.indexed)
        if (cue.endTime.inMilliseconds + offsetMs > 0)
          '${index + 1}\n${timestamp(cue.startTime + Duration(milliseconds: offsetMs))} --> '
              '${timestamp(cue.endTime + Duration(milliseconds: offsetMs))}\n${cue.text}\n',
    ].join('\n');
  }

  /// Moves ASS/SSA event timestamps and keeps the original script, styles and
  /// event text. A timing change is not silently rewritten as SRT.
  static String _shiftAss(String content, int offsetMs) {
    final line = RegExp(
      r'^((?:Dialogue|Comment):\s*[^,]*,)(\d+:\d\d:\d\d\.\d\d)(,)(\d+:\d\d:\d\d\.\d\d)',
      multiLine: true,
    );
    return content.replaceAllMapped(line, (match) {
      return '${match[1]}${_assTime(match[2]!, offsetMs)},${_assTime(match[4]!, offsetMs)}';
    });
  }

  static String _assTime(String value, int offsetMs) {
    final parts = value.split(RegExp(r'[:.]'));
    if (parts.length != 4) return value;
    final raw =
        (((int.tryParse(parts[0]) ?? 0) * 3600 +
                    (int.tryParse(parts[1]) ?? 0) * 60 +
                    (int.tryParse(parts[2]) ?? 0)) *
                1000) +
            (int.tryParse(parts[3]) ?? 0) * 10 +
            offsetMs;
    final ms = raw < 0 ? 0 : raw;
    String pad(int n, int width) => n.toString().padLeft(width, '0');
    final centis = (ms ~/ 10) % 100;
    return '${ms ~/ 3600000}:${pad(ms ~/ 60000 % 60, 2)}:${pad(ms ~/ 1000 % 60, 2)}.${pad(centis, 2)}';
  }

  static String timestamp(Duration time) {
    final ms = time.inMilliseconds.clamp(0, 359999999);
    String pad(int n, int w) => n.toString().padLeft(w, '0');
    return '${pad(ms ~/ 3600000, 2)}:${pad(ms ~/ 60000 % 60, 2)}:${pad(ms ~/ 1000 % 60, 2)},${pad(ms % 1000, 3)}';
  }
}

String subtitleVisibleLabel(String value) {
  final text = value.trim();
  if (RegExp(
    r'^(podcast|video|media|task|library):',
    caseSensitive: false,
  ).hasMatch(text)) {
    return '';
  }
  return text;
}

String subtitleLanguageLabel(String value) => switch (value.toLowerCase()) {
  '' => '语言未标注',
  'zh' ||
  'chi' ||
  'zho' ||
  'zh-cn' ||
  'zh-hans' ||
  'chinese' ||
  'chinese-bg-code' => '简体中文',
  'zh-tw' || 'zh-hant' || 'chinese-traditional' || 'ze' => '繁体中文',
  'en' || 'eng' || 'english' => '英语',
  'ja' || 'jp' || 'jpn' || 'japanese' => '日语',
  'ko' || 'kor' || 'korean' => '韩语',
  'fr' || 'french' => '法语',
  'es' || 'spanish' => '西班牙语',
  _ => value,
};
