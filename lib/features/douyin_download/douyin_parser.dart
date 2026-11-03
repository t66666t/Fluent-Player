import 'dart:convert';

import 'douyin_models.dart';

enum DouyinLinkKind { video, note, profile, collection, shortLink }

class DouyinLinkParser {
  const DouyinLinkParser._();

  static const maxBatchLinks = 100;

  static const _pageHosts = {
    'douyin.com',
    'www.douyin.com',
    'm.douyin.com',
    'v.douyin.com',
    'iesdouyin.com',
    'www.iesdouyin.com',
  };
  static final _id = RegExp(r'^\d{15,22}$');
  static final _candidate = RegExp(
    r'''(?<![@\w./-])(?:https?://)?(?:(?:www|m|v)\.)?(?:douyin|iesdouyin)\.com(?:/[^\s<>"'`，。！？、；：【】《》「」『』（）()]*)?''',
    caseSensitive: false,
  );

  /// Accepts a copied share sentence, an official link, or an exact video ID.
  static Uri? parse(String input) {
    final trimmed = input.trim();
    if (_id.hasMatch(trimmed)) {
      return Uri.https('www.douyin.com', '/video/$trimmed');
    }
    for (final match in _candidate.allMatches(trimmed)) {
      var value = match.group(0)!;
      value = value.replaceFirst(RegExp(r'[.,;!?:\]\}]+$'), '');
      if (!value.toLowerCase().startsWith('http')) value = 'https://$value';
      final uri = Uri.tryParse(value);
      if (uri == null || !isTrustedPage(uri) || kindOf(uri) == null) continue;
      return uri.removeFragment().replace(scheme: 'https');
    }
    return null;
  }

  /// Read every share link, including links without a scheme and ID-only lines.
  /// Keep one extra result so the editor can report overflow instead of dropping it.
  static List<Uri> parseMany(String input, {int limit = maxBatchLinks + 1}) {
    final result = <String, Uri>{};
    for (final line in const LineSplitter().convert(input)) {
      final candidates = _id.hasMatch(line.trim())
          ? [line.trim()]
          : _candidate.allMatches(line).map((match) => match.group(0)!);
      for (final candidate in candidates) {
        final uri = parse(candidate);
        if (uri == null) continue;
        result[uri.toString()] = uri;
        if (result.length >= limit) return result.values.toList();
      }
    }
    return result.values.toList();
  }

  static bool isTrustedPage(Uri uri) =>
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      _pageHosts.contains(uri.host.toLowerCase()) &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 80 || uri.port == 443);

  static String? videoId(Uri uri) {
    if (!isTrustedPage(uri)) return null;
    for (final key in ['modal_id', 'aweme_id', 'item_id']) {
      final value = _query(uri, key);
      if (value != null && _id.hasMatch(value)) return value;
    }
    final match = RegExp(
      r'^/(?:video|note|share/video|share/note)/(\d{15,22})(?:/|$)',
    ).firstMatch(uri.path);
    return match?.group(1);
  }

  static DouyinLinkKind? kindOf(Uri uri) {
    if (!isTrustedPage(uri)) return null;
    if (uri.host == 'v.douyin.com' &&
        RegExp(r'^/[A-Za-z0-9_-]+/?$').hasMatch(uri.path)) {
      return DouyinLinkKind.shortLink;
    }
    if (videoId(uri) != null) {
      return uri.path.contains('/note/')
          ? DouyinLinkKind.note
          : DouyinLinkKind.video;
    }
    if (RegExp(r'^/(?:user|share/user)/[^/]+/?$').hasMatch(uri.path)) {
      return DouyinLinkKind.profile;
    }
    if (RegExp(
          r'^/(?:collection|mix|share/mix)/[A-Za-z0-9_-]+/?$',
        ).hasMatch(uri.path) ||
        _id.hasMatch(_query(uri, 'collection_id') ?? '') ||
        _id.hasMatch(_query(uri, 'mix_id') ?? '')) {
      return DouyinLinkKind.collection;
    }
    return null;
  }

  static String? _query(Uri uri, String key) {
    try {
      return uri.queryParameters[key];
    } on FormatException {
      return null;
    }
  }
}

/// Parses both web API responses and the camelCase page hydration model.
class DouyinParser {
  const DouyinParser._();

  static const _skipBranches = {
    'related',
    'recommend',
    'recommendations',
    'related_video',
    'relatedVideo',
    'ads',
    'ad',
    'advertisements',
    'comments',
    'author',
    'music',
  };

  static List<DouyinVideo> parse(Object? data) {
    if (data is String) {
      if (data.length > 8 * 1024 * 1024) return const [];
      try {
        data = jsonDecode(data);
      } on FormatException {
        return const [];
      }
    }
    final items = <String, DouyinVideo>{};
    var visited = 0;
    void visit(Object? value, int depth) {
      if (depth > 12 || ++visited > 12000 || items.length >= 100) return;
      if (value is List) {
        for (final child in value.take(300)) {
          visit(child, depth + 1);
        }
      } else if (value is Map) {
        if (_isAd(value)) return;
        final id = _text(value['aweme_id'] ?? value['awemeId']);
        if (id != null && RegExp(r'^\d{15,22}$').hasMatch(id)) {
          final parsed = _video(value, id);
          if (parsed != null) {
            final previous = items[id];
            items[id] = previous?.merge(parsed) ?? parsed;
          }
          // An aweme may contain unrelated recommendations. Do not descend.
          return;
        }
        for (final entry in value.entries) {
          if (!_skipBranches.contains(entry.key)) visit(entry.value, depth + 1);
        }
      }
    }

    visit(data, 0);
    return List.unmodifiable(items.values);
  }

  static bool _isAd(Map value) =>
      value['is_ads'] == true ||
      value['is_ads'] == 1 ||
      value['isAds'] == true ||
      value['is_ad'] == true ||
      value['aweme_type'] == 101 ||
      value['awemeType'] == 101;

  static DouyinVideo? _video(Map item, String id) {
    // Photo posts can have a synthetic video field; these are not downloadable
    // video renditions and must not be presented as a successful video parse.
    if (_number(item['aweme_type'] ?? item['awemeType']) == 68 ||
        (item['images'] is List && (item['images'] as List).isNotEmpty) ||
        (item['image_post_info'] is Map)) {
      return null;
    }
    final video = item['video'];
    if (video is! Map) return null;
    final variants = <DouyinVideoVariant>[];
    final seen = <String>{};
    final rates =
        video['bit_rate'] ??
        video['bitRate'] ??
        video['bitRateList'] ??
        video['bitrateInfo'];
    final audio =
        video['bit_rate_audio'] ?? video['bitRateAudio'] ?? video['audio'];
    final audioEntries = audio is List
        ? audio
        : audio == null
        ? const []
        : [audio];
    final ownAudioUrls = audioEntries
        .expand(
          (entry) => _urls(
            entry is Map
                ? entry['play_addr'] ??
                      entry['playAddr'] ??
                      entry['PlayAddr'] ??
                      entry['audio_addr'] ??
                      entry['audioAddr'] ??
                      entry
                : entry,
            playback: true,
          ),
        )
        .toSet()
        .toList(growable: false);

    void addVariant(Object? address, Map source, String variantId) {
      final urls = _urls(address, playback: true);
      if (urls.isEmpty || !seen.add(urls.first)) return;
      if (urls.every(isAudioOnlyUrl)) return;
      final fields = address is Map ? address : const {};
      final width = _positive(
        fields['width'] ?? fields['Width'] ?? source['width'],
      );
      final height = _positive(
        fields['height'] ?? fields['Height'] ?? source['height'],
      );
      final bitrate = _positive(
        source['bit_rate'] ?? source['bitRate'] ?? source['bitrate'],
      );
      final size = _positive(
        fields['data_size'] ??
            fields['dataSize'] ??
            fields['DataSize'] ??
            source['data_size'] ??
            source['dataSize'],
      );
      var codec = _text(
        source['codec_type'] ??
            source['codecType'] ??
            source['videoFormat'] ??
            source['codec'],
      );
      if (const {'mp4', 'dash', 'hls', 'm4v'}.contains(codec?.toLowerCase())) {
        codec = null;
      }
      if (codec == null &&
          (source['is_h265'] == 1 ||
              source['isH265'] == 1 ||
              source['isH265'] == true)) {
        codec = 'H.265';
      }
      final fps = _number(source['FPS'] ?? source['fps'])?.toDouble();
      final shortEdge = width != null && height != null
          ? (width < height ? width : height)
          : null;
      final separate =
          urls.any(isSeparateVideoUrl) ||
          _text(source['format'])?.toLowerCase() == 'dash';
      final pairedAudio = _urls(
        source['audio_addr'] ?? source['audioAddr'],
        playback: true,
      );
      final explicitAudio = source['has_audio'] ?? source['hasAudio'];
      variants.add(
        DouyinVideoVariant(
          id: '$id-$variantId',
          url: urls.first,
          backupUrls: List.unmodifiable(urls.skip(1)),
          width: width,
          height: height,
          bitrate: bitrate,
          fps: fps != null && fps > 0 && fps < 1000 ? fps : null,
          codec: codec,
          sizeBytes: size,
          qualityLabel: shortEdge == null ? '网页播放源' : '${shortEdge}p',
          isSeparateVideo: separate,
          hasAudio: separate
              ? false
              : explicitAudio is bool
              ? explicitAudio
              : null,
          audioUrls: List.unmodifiable(
            pairedAudio.isNotEmpty ? pairedAudio : ownAudioUrls,
          ),
        ),
      );
    }

    if (rates is List) {
      for (var i = 0; i < rates.length && i < 30; i++) {
        final rate = rates[i];
        if (rate is! Map) continue;
        final address =
            rate['play_addr'] ??
            rate['playAddr'] ??
            rate['PlayAddr'] ??
            rate['playApi'];
        if (address != null) addVariant(address, rate, 'rate-$i');
      }
    }
    for (final key in [
      'play_addr',
      'playAddr',
      'playApi',
      'play_addr_h264',
      'playAddrH264',
      'play_addr_265',
      'playAddr265',
      'play_addr_256',
      'play_addr_bytevc1',
    ]) {
      final address = video[key];
      if (address != null) addVariant(address, video, key);
    }
    if (variants.isEmpty) return null;
    variants.sort(DouyinVideoVariant.compare);
    final author = item['author'];
    final statistics = item['statistics'] ?? item['stats'];
    var cover = '';
    for (final key in [
      'origin_cover',
      'originCover',
      'cover_original_scale',
      'coverOriginalScale',
      'cover',
      'dynamic_cover',
      'dynamicCover',
    ]) {
      final urls = _urls(video[key], playback: false);
      if (urls.isNotEmpty) {
        cover = urls.first;
        break;
      }
    }
    final durationMs = _positive(video['duration'] ?? item['duration']);
    var title = [
      'desc',
      'description',
      'caption',
      'title',
    ].map((key) => _text(item[key])).whereType<String>().firstOrNull;
    if (title != null &&
        RegExp(r'^抖音\s*[-_—|·]?\s*(记录美好生活|美好生活)?\s*$').hasMatch(title)) {
      title = null;
    }
    return DouyinVideo(
      id: id,
      title: title ?? '抖音视频 $id',
      titleQuality: title == null
          ? 0
          : item['capture_source'] == 'dom'
          ? 1
          : 2,
      author: author is Map
          ? (_text(author['nickname'] ?? author['nickName']) ?? '')
          : '',
      coverUrl: cover,
      duration: Duration(milliseconds: durationMs ?? 0),
      variants: List.unmodifiable(variants),
      createTime: _positive(item['create_time'] ?? item['createTime']),
      likes: statistics is Map
          ? _nonnegative(statistics['digg_count'] ?? statistics['diggCount'])
          : null,
    );
  }

  static List<String> _urls(Object? address, {required bool playback}) {
    final raw = address is String
        ? [address]
        : address is List
        ? address
        : address is Map
        ? address['url_list'] ??
              address['urlList'] ??
              address['UrlList'] ??
              [address['src'] ?? address['url']]
        : null;
    if (raw is! List) return const [];
    final result = <String>{};
    for (final value in raw.take(12)) {
      final text = value is String
          ? value
          : value is Map
          ? _text(value['src'] ?? value['url'])
          : null;
      if (text == null || text.length > 16384) continue;
      final normalized = text.startsWith('//') ? 'https:$text' : text;
      final uri = Uri.tryParse(normalized);
      if (uri == null || !isSafeMediaUrl(normalized)) continue;
      if (playback &&
          (uri.path.contains('/playwm') ||
              DouyinLinkParser._query(uri, 'watermark') == '1')) {
        continue;
      }
      result.add(normalized);
    }
    return result.toList(growable: false);
  }

  static bool isAudioOnlyUrl(String value) => RegExp(
    r'/media-audio-[^/]+/|audio-und-mp4a|[?&]mime_type=audio(?:_|%2f|\b)',
    caseSensitive: false,
  ).hasMatch(value);
  static bool isSeparateVideoUrl(String value) =>
      RegExp(r'/media-video-[^/]+/', caseSensitive: false).hasMatch(value);

  /// Shared by the downloader before following a CDN redirect. Credentials and
  /// arbitrary network destinations never come from imported capture data.
  static bool isSafeMediaUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    if (uri.hasPort && uri.port != 80 && uri.port != 443) return false;
    final host = uri.host.toLowerCase();
    const roots = [
      'douyinvod.com',
      'douyinvod.com.cn',
      'bytecdn.cn',
      'bytecdn.com',
      'byteimg.com',
      'douyinpic.com',
      'ixigua.com',
      'snssdk.com',
      'amemv.com',
      'iesdouyin.com',
      'douyin.com',
      'bytedance.com',
      'zjcdn.com',
      'volcvideo.com',
      'vcloud-dy.com',
      'toutiao.com',
    ];
    return roots.any((root) => host == root || host.endsWith('.$root'));
  }

  static String? _text(Object? value) {
    if (value is! String && value is! num) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static num? _number(Object? value) {
    final result = value is num
        ? value
        : value is String
        ? num.tryParse(value)
        : null;
    return result != null && result.isFinite ? result : null;
  }

  static int? _positive(Object? value) {
    final number = _nonnegative(value);
    return number != null && number > 0 ? number : null;
  }

  static int? _nonnegative(Object? value) {
    final number = _number(value);
    return number != null && number >= 0 && number <= 9007199254740991
        ? number.toInt()
        : null;
  }
}
