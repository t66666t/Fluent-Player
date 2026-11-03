class BilibiliVideoInfo {
  final String title;
  final String desc;
  final String pic;
  final String bvid;
  final String aid; // Add aid
  final String ownerName;
  final String ownerMid;
  final int pubDate;
  final List<BilibiliPage> pages;

  // Optional Collection/Season Info (Level 1)
  final BilibiliCollectionInfo? collectionInfo;

  BilibiliVideoInfo({
    required this.title,
    required this.desc,
    required this.pic,
    required this.bvid,
    required this.aid,
    required this.ownerName,
    required this.ownerMid,
    required this.pubDate,
    required this.pages,
    this.collectionInfo,
  });

  factory BilibiliVideoInfo.fromJson(Map<String, dynamic> json) {
    // Check if this is a local storage map (has 'pages' as list directly, not inside data)
    if (json.containsKey('title') &&
        json.containsKey('pages') &&
        !json.containsKey('data')) {
      return BilibiliVideoInfo.fromMap(json);
    }

    final data = json['data'];

    // Check for UGC Season (Collection)
    BilibiliCollectionInfo? collectionInfo;
    final ugcSeason = data['ugc_season'];

    if (ugcSeason != null && ugcSeason['sections'] != null) {
      final sections = ugcSeason['sections'] as List;
      final List<BilibiliVideoInfo> videos = [];

      for (var section in sections) {
        final episodes = section['episodes'] as List?;
        if (episodes != null) {
          for (var ep in episodes) {
            // Each episode in a season is conceptually a VIDEO (Level 2)
            // It might have its own pages (Level 3), but usually season list gives just the main page.
            // We construct a 'VideoInfo' for each item.
            // Fix for multi-page parsing: Check if 'pages' exist in episode, otherwise use episode itself
            List<BilibiliPage> videoPages = [];
            if (ep['pages'] != null) {
              videoPages = (ep['pages'] as List)
                  .map(
                    (p) => BilibiliPage(
                      cid: p['cid'] ?? 0,
                      page: p['page'] ?? 1,
                      part: p['part'] ?? '',
                      duration: p['duration'] ?? 0,
                      bvid: ep['bvid'],
                      aid: ep['aid']?.toString(),
                    ),
                  )
                  .toList();
            } else {
              // Fallback to single page
              videoPages = [
                BilibiliPage(
                  cid: ep['cid'] ?? 0,
                  page: 1,
                  part: ep['title'] ?? '',
                  duration: ep['duration'] ?? 0,
                  bvid: ep['bvid'],
                  aid: ep['aid']?.toString(),
                ),
              ];
            }

            videos.add(
              BilibiliVideoInfo(
                title: ep['title'] ?? '',
                desc: '',
                pic:
                    ep['arc']?['pic'] ??
                    data['pic'] ??
                    '', // Use arc pic or season pic
                bvid: ep['bvid'] ?? '',
                aid: ep['aid']?.toString() ?? '',
                ownerName: data['owner']['name'] ?? '',
                ownerMid: data['owner']['mid'].toString(),
                pubDate: ep['arc']?['pubdate'] ?? 0,
                pages: videoPages,
              ),
            );
          }
        }
      }

      collectionInfo = BilibiliCollectionInfo(
        title: ugcSeason['title'] ?? data['title'],
        cover: ugcSeason['cover'] ?? data['pic'],
        videos: videos,
      );
    }

    // Standard Pages (for Single Video)
    List<BilibiliPage> standardPages = [];
    if (data['pages'] != null) {
      standardPages = (data['pages'] as List)
          .map((e) => BilibiliPage.fromJson(e))
          .toList();
    }

    return BilibiliVideoInfo(
      title: data['title'] ?? '',
      desc: data['desc'] ?? '',
      pic: data['pic'] ?? '',
      bvid: data['bvid'] ?? '',
      aid: data['aid']?.toString() ?? '',
      ownerName: data['owner']['name'] ?? '',
      ownerMid: data['owner']['mid'].toString(),
      pubDate: data['pubdate'] ?? 0,
      pages: standardPages,
      collectionInfo: collectionInfo,
    );
  }

  factory BilibiliVideoInfo.fromMap(Map<String, dynamic> map) {
    return BilibiliVideoInfo(
      title: map['title'] ?? '',
      desc: map['desc'] ?? '',
      pic: map['pic'] ?? '',
      bvid: map['bvid'] ?? '',
      aid: map['aid'] ?? '',
      ownerName: map['ownerName'] ?? '',
      ownerMid: map['ownerMid'] ?? '',
      pubDate: map['pubDate'] ?? 0,
      pages:
          (map['pages'] as List?)
              ?.map((e) => BilibiliPage.fromJson(e))
              .toList() ??
          [],
      collectionInfo: map['collectionInfo'] != null
          ? BilibiliCollectionInfo.fromMap(map['collectionInfo'])
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'desc': desc,
      'pic': pic,
      'bvid': bvid,
      'aid': aid,
      'ownerName': ownerName,
      'ownerMid': ownerMid,
      'pubDate': pubDate,
      'pages': pages.map((e) => e.toJson()).toList(),
      'collectionInfo': collectionInfo?.toJson(),
    };
  }
}

class BilibiliCollectionInfo {
  final String title;
  final String cover;
  final List<BilibiliVideoInfo> videos;

  BilibiliCollectionInfo({
    required this.title,
    required this.cover,
    required this.videos,
  });

  factory BilibiliCollectionInfo.fromMap(Map<String, dynamic> map) {
    return BilibiliCollectionInfo(
      title: map['title'] ?? '',
      cover: map['cover'] ?? '',
      videos:
          (map['videos'] as List?)
              ?.map((e) => BilibiliVideoInfo.fromMap(e))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'cover': cover,
      'videos': videos.map((e) => e.toJson()).toList(),
    };
  }
}

class BilibiliPage {
  final int cid;
  final int page;
  final String part;
  final int duration;
  final String? bvid; // Optional specific bvid (for collection/season)
  final String? aid; // Optional specific aid
  final int? courseEpisodeId;

  BilibiliPage({
    required this.cid,
    required this.page,
    required this.part,
    required this.duration,
    this.bvid,
    this.aid,
    this.courseEpisodeId,
  });

  factory BilibiliPage.fromJson(Map<String, dynamic> json) {
    return BilibiliPage(
      cid: json['cid'] ?? 0,
      page: json['page'] ?? 1,
      part: json['part'] ?? '',
      duration: json['duration'] ?? 0,
      bvid: json['bvid'],
      aid: json['aid']?.toString(),
      courseEpisodeId: int.tryParse('${json['courseEpisodeId'] ?? ''}'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'cid': cid,
      'page': page,
      'part': part,
      'duration': duration,
      'bvid': bvid,
      'aid': aid,
      if (courseEpisodeId != null) 'courseEpisodeId': courseEpisodeId,
    };
  }
}

class BilibiliStreamInfo {
  final bool isPreview;
  final List<StreamItem> videoStreams;
  final List<StreamItem> audioStreams;
  final Map<int, String> qualityMap;
  final int durationMs;

  BilibiliStreamInfo({
    required this.videoStreams,
    required this.audioStreams,
    required this.qualityMap,
    this.durationMs = 0,
    this.isPreview = false,
  });

  factory BilibiliStreamInfo.fromJson(Map<String, dynamic> json) {
    final data = json['data'];
    if (data == null) {
      return BilibiliStreamInfo(
        videoStreams: [],
        audioStreams: [],
        qualityMap: {},
      );
    }

    final dash = data['dash'];
    if (dash == null) {
      return BilibiliStreamInfo(
        videoStreams: [],
        audioStreams: [],
        qualityMap: {},
      );
    }

    // Fallback quality labels when the response omits descriptions.
    final Map<int, String> qMap = {
      127: "8K 超高清",
      126: "杜比视界",
      125: "HDR 真彩",
      120: "4K 超清",
      116: "1080P 60帧",
      112: "1080P 高码率",
      80: "1080P 高清",
      74: "720P 60帧",
      64: "720P 高清",
      32: "480P 清晰",
      16: "360P 流畅",
    };

    // Override with dynamic values from API if available
    final acceptQuality = data['accept_quality'] as List?;
    final acceptDesc = data['accept_description'] as List?;

    if (acceptQuality != null &&
        acceptDesc != null &&
        acceptQuality.length == acceptDesc.length) {
      for (int i = 0; i < acceptQuality.length; i++) {
        final q = acceptQuality[i];
        final d = acceptDesc[i];
        if (q is int && d is String) {
          qMap[q] = d;
        }
      }
    }

    final videos =
        (dash['video'] as List?)
            ?.map((e) => StreamItem.fromJson(e, qMap[e['id'] as int]))
            .toList() ??
        [];
    final audios = <StreamItem>[
      ...?((dash['audio'] as List?)?.whereType<Map>().map(
        (e) => StreamItem.fromJson(Map<String, dynamic>.from(e)),
      )),
      ...?(((dash['dolby'] as Map?)?['audio'] as List?)?.whereType<Map>().map(
        (e) => StreamItem.fromJson(Map<String, dynamic>.from(e), '杜比全景声'),
      )),
      if ((dash['flac'] as Map?)?['audio'] case final Map flacAudio)
        StreamItem.fromJson(Map<String, dynamic>.from(flacAudio), 'Hi-Res无损'),
    ];

    // Keep display order aligned with resolution preference selection.
    videos.sort(StreamItem.compareVideoQuality);
    audios.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));

    return BilibiliStreamInfo(
      videoStreams: videos,
      audioStreams: audios,
      qualityMap: qMap,
      isPreview: [data['is_preview'], data['is_trial'], data['isPreview']]
        .any((value) => value == true || value == 1 || value == '1'),
      durationMs:
          ((data['timelength'] as num?)?.toDouble() ??
                  ((dash['duration'] as num?)?.toDouble() ?? 0) * 1000)
              .round(),
    );
  }
}

class StreamItem {
  final int id;
  final String baseUrl;
  final List<String> backupUrls;
  final int bandwidth;
  final String codecs;
  final int codecid;
  final String? mimeType;
  final String? qualityName;
  final int width;
  final int height;
  final String frameRate;
  final String initializationRange;
  final String indexRange;

  StreamItem({
    required this.id,
    required this.baseUrl,
    this.backupUrls = const [],
    required this.bandwidth,
    required this.codecs,
    required this.codecid,
    this.mimeType,
    this.qualityName,
    this.width = 0,
    this.height = 0,
    this.frameRate = '',
    this.initializationRange = '',
    this.indexRange = '',
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'base_url': baseUrl,
      'backup_url': backupUrls,
      'bandwidth': bandwidth,
      'codecs': codecs,
      'codecid': codecid,
      'mime_type': mimeType,
      'qualityName': qualityName,
      'width': width,
      'height': height,
      'frame_rate': frameRate,
      'segment_base': {
        'initialization': initializationRange,
        'index_range': indexRange,
      },
    };
  }

  factory StreamItem.fromJson(
    Map<String, dynamic> json, [
    String? qualityName,
  ]) {
    final backupUrls =
        ((json['backup_url'] ?? json['backupUrl']) as List?)
            ?.map((e) => _normalizeBilibiliMediaUrl(e?.toString() ?? ''))
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];
    final segmentBase = (json['segment_base'] ?? json['SegmentBase']);
    final segment = segmentBase is Map
        ? segmentBase
        : const <String, dynamic>{};
    return StreamItem(
      id: json['id'] ?? 0,
      baseUrl: _normalizeBilibiliMediaUrl(
        (json['base_url'] ?? json['baseUrl'] ?? '').toString(),
      ),
      backupUrls: backupUrls,
      bandwidth: json['bandwidth'] ?? 0,
      codecs: json['codecs'] ?? '',
      codecid: json['codecid'] ?? 0,
      mimeType: (json['mime_type'] ?? json['mimeType'])?.toString(),
      qualityName: qualityName ?? json['qualityName'],
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      frameRate: (json['frame_rate'] ?? json['frameRate'] ?? '').toString(),
      initializationRange:
          (segment['initialization'] ?? segment['Initialization'] ?? '')
              .toString(),
      indexRange: (segment['index_range'] ?? segment['indexRange'] ?? '')
          .toString(),
    );
  }

  static int compareVideoQuality(StreamItem a, StreamItem b) {
    final resolutionCompare = b.qualitySortScore.compareTo(a.qualitySortScore);
    if (resolutionCompare != 0) {
      return resolutionCompare;
    }

    final idCompare = b.id.compareTo(a.id);
    if (idCompare != 0) {
      return idCompare;
    }

    final bandwidthCompare = b.bandwidth.compareTo(a.bandwidth);
    if (bandwidthCompare != 0) {
      return bandwidthCompare;
    }

    return a.codecs.compareTo(b.codecs);
  }

  int get qualitySortScore {
    const knownScores = <int, int>{
      127: 8000,
      126: 4001,
      125: 4000,
      120: 2160,
      116: 1082,
      112: 1081,
      80: 1080,
      74: 721,
      64: 720,
      32: 480,
      16: 360,
    };
    final knownScore = knownScores[id];
    if (knownScore != null) {
      return knownScore;
    }

    final normalizedLabel = (qualityName ?? '').toUpperCase();
    if (normalizedLabel.contains('8K')) {
      return 8000;
    }
    if (normalizedLabel.contains('4K')) {
      return 2160;
    }
    if (normalizedLabel.contains('杜比')) {
      return 4001;
    }
    if (normalizedLabel.contains('HDR')) {
      return 4000;
    }

    final match = RegExp(r'(\d+)\s*P').firstMatch(normalizedLabel);
    if (match != null) {
      return int.tryParse(match.group(1) ?? '') ?? id;
    }

    return id;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamItem &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          codecid == other.codecid &&
          codecs == other.codecs;

  @override
  int get hashCode => id.hashCode ^ codecid.hashCode ^ codecs.hashCode;
}

String _normalizeBilibiliMediaUrl(String value) {
  final trimmed = value.trim();
  return trimmed.startsWith('//') ? 'https:$trimmed' : trimmed;
}
