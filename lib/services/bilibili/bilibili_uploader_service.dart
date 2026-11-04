import 'dart:convert';

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_browse_models.dart';
import '../../models/bilibili_uploader_models.dart';
import 'bilibili_public_api_service.dart';

/// Reads an uploader's (UP 主) public data: profile, videos, articles and
/// collections.
///
/// Everything goes through [BilibiliPublicApiService], so each request
/// carries the device id and, when logged in, the login cookies, like the
/// uploader's space page in a browser. Space requests send that page as
/// Referer and Origin, and the signed ones the page's own extra parameters
/// (`web_location` and the `dm_*` rendering hints). On risk control the
/// signing keys and device id are renewed and the same request is retried
/// once. Nothing here throws: every call returns a [BilibiliUploaderResult].
class BilibiliUploaderService {
  BilibiliUploaderService({BilibiliPublicApiService? api})
    : _api = api ?? BilibiliPublicApiService();

  final BilibiliPublicApiService _api;

  static String spaceReferer(int mid) => 'https://space.bilibili.com/$mid';

  static const String spaceOrigin = 'https://space.bilibili.com';

  /// Browser rendering hints the space page adds to its signed requests (an
  /// empty pointer trace, WebGL names and an empty interaction summary).
  /// Fixed text, not user data.
  static final Map<String, String> renderHints = <String, String>{
    'dm_img_list': '[]',
    'dm_img_str': _b64('WebGL 1.0 (OpenGL ES 2.0 Chromium)'),
    'dm_cover_img_str': _b64(
      'ANGLE (Intel, Intel(R) UHD Graphics Direct3D11 vs_5_0 ps_5_0, D3D11)'
      'Google Inc. (Intel)',
    ),
    'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
  };

  static String _b64(String text) =>
      base64Encode(utf8.encode(text)).replaceAll('=', '');

  static int clampPage(int page) =>
      page.clamp(1, kBilibiliUploaderMaxPages).toInt();

  // ---------------------------------------------------------------- profile

  /// Profile card first (no signing needed); if that fails, the WBI-signed
  /// account info. Then follow / follower counts from the relation stat; a
  /// failed supplement keeps what was already read. [onProfile] publishes
  /// the usable card before waiting for the supplementary counts.
  Future<BilibiliUploaderResult<BilibiliUploaderProfile>> fetchProfile(
    int mid, {
    void Function(BilibiliUploaderProfile profile)? onProfile,
  }) async {
    if (mid <= 0) {
      return const BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.failed,
        '无效的 UP 主编号',
      );
    }
    final referer = spaceReferer(mid);
    BilibiliUploaderProfile? profile;

    final card = await _read(
      '/x/web-interface/card',
      query: {'mid': mid, 'photo': 'false'},
      referer: referer,
      what: 'UP 主资料',
      // The signed account info below is the fallback.
      retryOnRisk: false,
    );
    if (card.isSuccess) {
      profile = BilibiliUploaderProfile.tryParseCard(card.data!);
    }

    var failure = card;
    if (profile == null) {
      developer.log('Bilibili uploader card unavailable, trying account info');
      final account = await _read(
        '/x/space/wbi/acc/info',
        query: {
          'mid': mid,
          'token': '',
          'platform': 'web',
          'web_location': '1550101',
          ...renderHints,
        },
        referer: referer,
        what: 'UP 主资料',
        signed: true,
      );
      if (account.isSuccess) {
        profile = BilibiliUploaderProfile.tryParseAccount(account.data!);
      }
      failure = account;
    }
    if (profile == null) {
      return failure.isSuccess
          ? const BilibiliUploaderResult.failure(
              BilibiliUploaderStatus.networkError,
              'UP 主资料数据不完整',
            )
          : failure.cast<BilibiliUploaderProfile>();
    }

    onProfile?.call(profile);
    final stat = await _read(
      '/x/relation/stat',
      query: {'vmid': mid},
      referer: referer,
      what: '关注数',
      retryOnRisk: false,
    );
    if (stat.isSuccess) {
      final data = stat.data!;
      profile = profile.withRelation(
        following: data.containsKey('following')
            ? readBiliInt(data['following'])
            : null,
        follower: data.containsKey('follower')
            ? readBiliInt(data['follower'])
            : null,
      );
    }
    return BilibiliUploaderResult.success(profile);
  }

  // ----------------------------------------------------------------- videos

  /// One page ([kBilibiliUploaderPageSize] items, page 1..
  /// [kBilibiliUploaderMaxPages]) of the uploader's videos, sorted by
  /// [order] and optionally filtered by [keyword].
  ///
  /// Uses the WBI-signed space search with the page's own parameters; on
  /// risk control it renews keys and device id and retries once, and if that
  /// is blocked too returns [BilibiliUploaderStatus.riskControlled]. (The
  /// older unsigned endpoint answers -799 / 412 and is no longer asked.)
  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderVideo>>>
  fetchVideos(
    int mid, {
    int page = 1,
    BilibiliUploaderVideoOrder order = BilibiliUploaderVideoOrder.latest,
    String keyword = '',
  }) async {
    if (mid <= 0) {
      return const BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.failed,
        '无效的 UP 主编号',
      );
    }
    final pn = clampPage(page);
    final term = keyword.trim();
    final query = <String, dynamic>{
      'mid': mid,
      'ps': kBilibiliUploaderPageSize,
      'tid': 0,
      'special_type': '',
      'pn': pn,
      'keyword': term,
      'order': order.apiValue,
      'platform': 'web',
      'web_location': '333.1387',
      'order_avoided': 'true',
      ...renderHints,
    };
    final result = await _read(
      '/x/space/wbi/arc/search',
      query: query,
      referer: '${spaceReferer(mid)}/video',
      what: '投稿列表',
      signed: true,
    );
    if (!result.isSuccess) {
      return result.cast<BilibiliUploaderPage<BilibiliUploaderVideo>>();
    }
    final data = result.data!;
    final items = <BilibiliUploaderVideo>[];
    final seen = <String>{};
    for (final raw in readBiliMapList(readBiliMap(data['list'])['vlist'])) {
      final item = BilibiliUploaderVideo.tryParse(raw);
      if (item != null && seen.add(item.bvid)) items.add(item);
    }
    return BilibiliUploaderResult.success(
      BilibiliUploaderPage<BilibiliUploaderVideo>(
        items: List<BilibiliUploaderVideo>.unmodifiable(items),
        page: pn,
        total: readBiliInt(readBiliMap(data['page'])['count']),
      ),
    );
  }

  // --------------------------------------------------------------- articles

  /// One page of the uploader's articles (专栏), newest first.
  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderArticle>>>
  fetchArticles(int mid, {int page = 1}) async {
    if (mid <= 0) {
      return const BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.failed,
        '无效的 UP 主编号',
      );
    }
    final pn = clampPage(page);
    final result = await _read(
      '/x/space/wbi/article',
      query: {
        'mid': mid,
        'pn': pn,
        'ps': kBilibiliUploaderPageSize,
        'sort': 'publish_time',
      },
      referer: spaceReferer(mid),
      what: '专栏列表',
      signed: true,
    );
    if (!result.isSuccess) {
      return result.cast<BilibiliUploaderPage<BilibiliUploaderArticle>>();
    }
    final data = result.data!;
    final items = <BilibiliUploaderArticle>[
      for (final raw in readBiliMapList(data['articles']))
        ?BilibiliUploaderArticle.tryParse(raw),
    ];
    return BilibiliUploaderResult.success(
      BilibiliUploaderPage<BilibiliUploaderArticle>(
        items: List<BilibiliUploaderArticle>.unmodifiable(items),
        page: pn,
        total: readBiliInt(data['count']),
      ),
    );
  }

  // ------------------------------------------------------------ collections

  /// One page of the uploader's collections: seasons (合集) first, then the
  /// older series (系列).
  Future<
    BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderCollection>>
  >
  fetchCollections(int mid, {int page = 1}) async {
    if (mid <= 0) {
      return const BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.failed,
        '无效的 UP 主编号',
      );
    }
    final pn = clampPage(page);
    final result = await _read(
      '/x/polymer/web-space/seasons_series_list',
      query: {
        'mid': mid,
        'page_num': pn,
        'page_size': kBilibiliUploaderPageSize,
      },
      referer: spaceReferer(mid),
      what: '合集列表',
    );
    if (!result.isSuccess) {
      return result.cast<BilibiliUploaderPage<BilibiliUploaderCollection>>();
    }
    final lists = readBiliMap(result.data!['items_lists']);
    final items = <BilibiliUploaderCollection>[
      for (final raw in readBiliMapList(lists['seasons_list']))
        ?BilibiliUploaderCollection.tryParse(raw, isSeason: true),
      for (final raw in readBiliMapList(lists['series_list']))
        ?BilibiliUploaderCollection.tryParse(raw, isSeason: false),
    ];
    return BilibiliUploaderResult.success(
      BilibiliUploaderPage<BilibiliUploaderCollection>(
        items: List<BilibiliUploaderCollection>.unmodifiable(items),
        page: pn,
        total: readBiliInt(readBiliMap(lists['page'])['total']),
      ),
    );
  }

  /// One page of the videos in [collection]: a season (合集) or a series
  /// (系列), [kBilibiliUploaderPageSize] per page, at most
  /// [kBilibiliUploaderMaxPages] pages while browsing. Whole-collection
  /// imports disable [limitToBrowsePages] to read every page. Never throws.
  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderVideo>>>
  fetchCollectionVideos(
    int mid,
    BilibiliUploaderCollection collection, {
    int page = 1,
    bool limitToBrowsePages = true,
  }) async {
    if (mid <= 0 || collection.id <= 0) {
      return const BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.failed,
        '无效的合集',
      );
    }
    final pn = limitToBrowsePages ? clampPage(page) : (page < 1 ? 1 : page);
    final result = collection.isSeason
        ? await _read(
            '/x/polymer/web-space/seasons_archives_list',
            query: {
              'mid': mid,
              'season_id': collection.id,
              'page_num': pn,
              'page_size': kBilibiliUploaderPageSize,
              'sort_reverse': 'false',
            },
            referer: spaceReferer(mid),
            what: '合集视频',
          )
        : await _read(
            '/x/series/archives',
            query: {
              'mid': mid,
              'series_id': collection.id,
              'pn': pn,
              'ps': kBilibiliUploaderPageSize,
              'only_normal': 'true',
              'sort': 'desc',
            },
            referer: spaceReferer(mid),
            what: '系列视频',
          );
    if (!result.isSuccess) {
      return result.cast<BilibiliUploaderPage<BilibiliUploaderVideo>>();
    }
    final data = result.data!;
    final items = <BilibiliUploaderVideo>[];
    final seen = <String>{};
    for (final raw in readBiliMapList(data['archives'])) {
      final item = BilibiliUploaderVideo.tryParse(raw);
      if (item != null && seen.add(item.bvid)) items.add(item);
    }
    final pageInfo = readBiliMap(data['page']);
    return BilibiliUploaderResult.success(
      BilibiliUploaderPage<BilibiliUploaderVideo>(
        items: List<BilibiliUploaderVideo>.unmodifiable(items),
        page: pn,
        total: readBiliInt(pageInfo['total']),
      ),
    );
  }

  // ----------------------------------------------------------------- shared

  /// One request turned into a result carrying `data` on code 0. Risk
  /// control renews keys and device id and retries the same request once.
  Future<BilibiliUploaderResult<Map<String, dynamic>>> _read(
    String path, {
    required Map<String, dynamic> query,
    required String referer,
    required String what,
    bool signed = false,
    bool retryOnRisk = true,
  }) async {
    var answer = await _readOnce(path, query, referer, what, signed, 1);
    if (retryOnRisk &&
        answer.$2 != null &&
        BilibiliPublicApiService.isRiskControlPayload(answer.$2!)) {
      developer.log('Bilibili uploader read $path hit risk control, retrying');
      await _api.renewAfterRiskControl();
      answer = await _readOnce(path, query, referer, what, signed, 2);
    }
    final failure = answer.$1;
    if (failure != null) return failure;
    final payload = answer.$2!;
    final code = payload['code'];
    developer.log('Bilibili uploader read $path -> code=$code');
    if (BilibiliPublicApiService.isRiskControlPayload(payload)) {
      return BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.riskControlled,
        BilibiliPublicApiService.riskControlMessage(what, payload),
        code: code is int ? code : null,
      );
    }
    if (code != 0) {
      final notFound = code == -404 || code == -626 || code == 53013;
      return BilibiliUploaderResult.failure(
        notFound
            ? BilibiliUploaderStatus.notFound
            : BilibiliUploaderStatus.failed,
        notFound ? '$what不存在或不可见' : '$what加载失败（$code），请稍后重试',
        code: code is int ? code : null,
      );
    }
    return BilibiliUploaderResult.success(readBiliMap(payload['data']));
  }

  Future<(BilibiliUploaderResult<Map<String, dynamic>>?, Map<String, dynamic>?)>
  _readOnce(
    String path,
    Map<String, dynamic> query,
    String referer,
    String what,
    bool signed,
    int attempt,
  ) async {
    try {
      final payload = await _api.getPublicJson(
        path,
        query: query,
        referer: referer,
        origin: spaceOrigin,
        what: what,
        signed: signed,
        attempt: attempt,
      );
      return (null, payload);
    } on BilibiliPublicApiException catch (e) {
      return (
        BilibiliUploaderResult<Map<String, dynamic>>.failure(
          BilibiliUploaderStatus.networkError,
          e.message,
        ),
        null,
      );
    } catch (e) {
      developer.log(
        'Bilibili uploader read failed: $path',
        error: e.runtimeType,
      );
      return (
        BilibiliUploaderResult<Map<String, dynamic>>.failure(
          BilibiliUploaderStatus.networkError,
          '$what加载失败，请稍后重试',
        ),
        null,
      );
    }
  }
}
