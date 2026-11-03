import 'dart:async';
import 'package:video_player_app/services/network/network_http.dart';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../debug/developer_log.dart' as developer;
import '../../models/bilibili_browse_models.dart';
import '../../utils/bilibili_url_parser.dart';
import 'bilibili_device_identity.dart';
import 'bilibili_offline_details.dart';
import 'bilibili_request_log.dart';
import 'wbi_signer.dart';

/// User-facing error from a public Bilibili request. [message] is Chinese.
class BilibiliPublicApiException implements Exception {
  final String message;

  /// True when no answer came back at all (offline, connection failed or
  /// timed out), as opposed to Bilibili refusing the request.
  final bool isNetworkError;

  const BilibiliPublicApiException(this.message, {this.isNetworkError = false});

  @override
  String toString() => message;
}

/// Login cookies (name to value) of the current account, or an empty map.
typedef BilibiliLoginCookieSource = Future<Map<String, String>> Function();

/// Read-only Bilibili requests: video detail, tags, search, keyword
/// suggestions and uploader data.
///
/// Every request carries what a browser on bilibili.com carries: the device
/// id (`buvid3`, `buvid4`, `b_nut`, `_uuid`) and, when an account is logged
/// in, its login cookies. Requests are signed where the web page signs them.
/// On risk control (-352, -412, -799, HTTP 412 or a `v_voucher` challenge)
/// the WBI keys and the device id are renewed and the request is retried
/// once; a second refusal becomes a Chinese message naming the reason.
///
/// Each api.bilibili.com answer is recorded in [BilibiliRequestLog] (path,
/// code, message, whether device id / login / signature were present; never
/// the values).
class BilibiliPublicApiService {
  BilibiliPublicApiService({
    HttpClientAdapter? httpClientAdapter,
    Dio? dio,
    BilibiliLoginCookieSource? loginCookies,
    BilibiliDeviceIdentitySource? identitySource,
    @visibleForTesting DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _loginCookies = loginCookies,
       _dio =
           dio ??
           NetworkHttp.instance.createDio(
             scope: NetworkScope.bilibili,
             options: BaseOptions(
               connectTimeout: const Duration(seconds: 10),
               receiveTimeout: const Duration(seconds: 20),
               headers: const {'User-Agent': userAgent},
               // Status codes are interpreted by this service.
               validateStatus: (_) => true,
             ),
           ) {
    if (httpClientAdapter != null) _dio.httpClientAdapter = httpClientAdapter;
    // The app shares one device id; a service on a test client keeps its
    // own in memory, issued through that client.
    _identity =
        identitySource ??
        (httpClientAdapter == null && dio == null
            ? BilibiliDeviceIdentitySource.shared
            : BilibiliDeviceIdentitySource(
                fetchFingerprint: _fetchFingerprint,
                store: MemoryBilibiliDeviceIdentityStore(),
                clock: _clock,
              ));
  }

  /// Login source used by services created without [loginCookies]; the
  /// app's Bilibili service registers the live login here at start-up.
  static BilibiliLoginCookieSource? defaultLoginCookies;

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const String _api = 'https://api.bilibili.com';
  static const String _rootReferer = 'https://www.bilibili.com/';
  static const String _searchOrigin = 'https://search.bilibili.com';
  static const int maxSuggestions = 10;

  final Dio _dio;
  final DateTime Function() _clock;
  final BilibiliLoginCookieSource? _loginCookies;
  late final BilibiliDeviceIdentitySource _identity;
  String? _imgKey;
  String? _subKey;
  DateTime? _wbiKeysAt;
  Future<void>? _wbiKeysLoading;

  /// How long the WBI signing keys are reused before `nav` is asked again
  /// (Bilibili rotates them about once a day).
  static const Duration wbiKeyLifetime = Duration(hours: 6);

  static String videoReferer(String bvid) =>
      'https://www.bilibili.com/video/$bvid/';

  // ---------------------------------------------------------------- detail

  /// Loads the video detail. Tags are fetched separately and a tag failure
  /// leaves [BilibiliVideoDetail.tags] empty instead of failing the page.
  Future<BilibiliVideoDetail> fetchVideoDetail({String? bvid, int? aid}) async {
    final hasBvid = bvid != null && isValidBvid(bvid);
    if (!hasBvid && (aid == null || aid <= 0)) {
      throw const BilibiliPublicApiException('无效的视频编号');
    }
    final query = <String, dynamic>{if (hasBvid) 'bvid': bvid else 'aid': aid};
    final referer = hasBvid
        ? videoReferer(bvid)
        : 'https://www.bilibili.com/video/av$aid/';
    var payload = await _getJson(
      '$_api/x/web-interface/view',
      query: query,
      referer: referer,
      what: '视频详情',
      allowRiskStatus: true,
    );
    if (isRiskControlPayload(payload)) {
      developer.log('Bilibili detail hit risk control, retrying once signed');
      await renewAfterRiskControl();
      payload = await _getJson(
        '$_api/x/web-interface/wbi/view',
        query: await _signedQuery(query),
        referer: referer,
        what: '视频详情',
        attempt: 2,
        allowRiskStatus: true,
      );
    }
    if (isRiskControlPayload(payload)) {
      throw BilibiliPublicApiException(riskControlMessage('视频详情', payload));
    }
    if (payload['code'] != 0) {
      throw BilibiliPublicApiException(_detailError(payload['code']));
    }
    final detail = BilibiliVideoDetail.tryParse(readBiliMap(payload['data']));
    if (detail == null) {
      throw const BilibiliPublicApiException('视频详情数据不完整');
    }
    final tags = await fetchVideoTags(detail.bvid);
    final complete = tags.isEmpty ? detail : detail.withTags(tags);
    // Kept for the panel of a downloaded video when offline.
    unawaited(BilibiliOfflineDetails.instance.rememberDetail(complete));
    return complete;
  }

  /// Never throws; returns an empty list on any failure.
  Future<List<String>> fetchVideoTags(String bvid) async {
    if (!isValidBvid(bvid)) return const <String>[];
    try {
      final payload = await _getJson(
        '$_api/x/tag/archive/tags',
        query: {'bvid': bvid},
        referer: videoReferer(bvid),
        what: '视频标签',
      );
      if (payload['code'] != 0) return const <String>[];
      return parseBilibiliTags(payload['data']);
    } catch (e) {
      developer.log('Bilibili tags unavailable', error: e.runtimeType);
      return const <String>[];
    }
  }

  String _detailError(Object? raw) {
    return switch (raw) {
      -404 || 62002 => '视频不存在或已被删除',
      62004 => '视频正在审核中',
      62012 => '该视频仅 UP 主自己可见',
      -403 => '没有权限查看该视频',
      _ => 'B 站返回错误（$raw），请稍后重试',
    };
  }

  // ---------------------------------------------------------------- search

  Future<BilibiliSearchPage<BilibiliSearchVideo>> searchVideos(
    String keyword, {
    int page = 1,
    BilibiliVideoSearchFilter filter = const BilibiliVideoSearchFilter(),
    DateTime? now,
  }) async {
    final query = <String, dynamic>{
      'search_type': 'video',
      'keyword': _requireKeyword(keyword),
      'page': _safePage(page),
      'order': filter.order.apiValue,
      'duration': filter.durationRange?.apiValue ?? filter.duration.apiValue,
    };
    final window = filter.published.window;
    if (window != null) {
      final end =
          (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
      query['pubtime_begin_s'] = end - window.inSeconds;
      query['pubtime_end_s'] = end;
    }
    final data = await _search(query);
    final items = <BilibiliSearchVideo>[];
    final seen = <String>{};
    for (final raw in readBiliMapList(data['result'])) {
      final item = BilibiliSearchVideo.tryParse(raw);
      if (item != null && seen.add(item.bvid)) items.add(item);
    }
    return BilibiliSearchPage<BilibiliSearchVideo>(
      items: List<BilibiliSearchVideo>.unmodifiable(items),
      page: query['page'] as int,
      numPages: readBiliInt(data['numPages']),
    );
  }

  Future<BilibiliSearchPage<BilibiliSearchUser>> searchUsers(
    String keyword, {
    int page = 1,
  }) async {
    final query = <String, dynamic>{
      'search_type': 'bili_user',
      'keyword': _requireKeyword(keyword),
      'page': _safePage(page),
    };
    final data = await _search(query);
    final items = <BilibiliSearchUser>[];
    final seen = <int>{};
    for (final raw in readBiliMapList(data['result'])) {
      final item = BilibiliSearchUser.tryParse(raw);
      if (item != null && seen.add(item.mid)) items.add(item);
    }
    return BilibiliSearchPage<BilibiliSearchUser>(
      items: List<BilibiliSearchUser>.unmodifiable(items),
      page: query['page'] as int,
      numPages: readBiliInt(data['numPages']),
    );
  }

  /// Keyword suggestions, at most [maxSuggestions]. Never throws.
  Future<List<String>> suggestKeywords(String input) async {
    final term = input.trim();
    if (term.isEmpty) return const <String>[];
    try {
      final payload = await _getJson(
        'https://s.search.bilibili.com/main/suggest',
        query: {'term': term, 'main_ver': 'v1'},
        referer: _rootReferer,
        what: '搜索建议',
      );
      return parseBilibiliSuggestions(payload);
    } catch (e) {
      developer.log('Bilibili suggestions unavailable', error: e.runtimeType);
      return const <String>[];
    }
  }

  static List<String> parseBilibiliSuggestions(Map<String, dynamic> payload) {
    final result = payload['result'];
    final Object? tags = result is Map ? result['tag'] : result;
    final out = <String>[];
    final seen = <String>{};
    for (final item in readBiliMapList(tags)) {
      final value = readBiliText(item['value'], readBiliText(item['term']));
      if (value.isEmpty || !seen.add(value)) continue;
      out.add(value);
      if (out.length >= maxSuggestions) break;
    }
    return List<String>.unmodifiable(out);
  }

  Future<Map<String, dynamic>> _search(Map<String, dynamic> query) async {
    final keyword = query['keyword'] as String;
    final referer =
        'https://search.bilibili.com/all?keyword=${Uri.encodeQueryComponent(keyword)}';
    // Signed from the first attempt, like the search page itself.
    var payload = await _getJson(
      '$_api/x/web-interface/wbi/search/type',
      query: await _signedQuery(query),
      referer: referer,
      origin: _searchOrigin,
      what: '搜索',
      allowRiskStatus: true,
    );
    if (isRiskControlPayload(payload)) {
      developer.log('Bilibili search hit risk control, renewing and retrying');
      await renewAfterRiskControl();
      payload = await _getJson(
        '$_api/x/web-interface/wbi/search/type',
        query: await _signedQuery(query),
        referer: referer,
        origin: _searchOrigin,
        what: '搜索',
        attempt: 2,
        allowRiskStatus: true,
      );
    }
    if (isRiskControlPayload(payload)) {
      throw BilibiliPublicApiException(riskControlMessage('搜索', payload));
    }
    if (payload['code'] != 0) {
      throw BilibiliPublicApiException('搜索失败（${payload['code']}），请稍后重试');
    }
    return readBiliMap(payload['data']);
  }

  /// Chinese message for a request still refused after the automatic retry
  /// (which renewed the signing keys and the device id).
  static String riskControlMessage(String what, Map<String, dynamic> payload) {
    final code = payload['code'];
    final reason = payload['__http'] == 412
        ? 'HTTP 412'
        : payload['code'] == 0
        ? '需要人机验证'
        : '错误码 $code';
    return '$what被 B 站风控拦截（$reason），已自动重试一次，请稍后再试';
  }

  Future<Map<String, dynamic>> _signedQuery(Map<String, dynamic> query) async {
    try {
      await _ensureWbiKeys();
      final img = _imgKey;
      final sub = _subKey;
      if (img == null || sub == null) return query;
      return WbiSigner.sign(query, img, sub);
    } catch (e) {
      developer.log('Bilibili WBI keys unavailable', error: e.runtimeType);
      return query;
    }
  }

  /// Risk control hits within this time of a renewal share it instead of
  /// renewing again (several lists of one page often fail together).
  static const Duration riskRenewalCooldown = Duration(minutes: 1);

  DateTime? _renewedAt;
  Future<void>? _renewing;

  /// Renews the WBI keys and the device id before the one retry after
  /// risk control; at most once per [riskRenewalCooldown], concurrent
  /// callers sharing it. Failures are left to the retried request.
  Future<void> renewAfterRiskControl() {
    final running = _renewing;
    if (running != null) return running;
    final at = _renewedAt;
    if (at != null && _clock().difference(at) < riskRenewalCooldown) {
      return Future<void>.value();
    }
    final renewing = _renew();
    _renewing = renewing;
    return renewing.whenComplete(() {
      _renewedAt = _clock();
      if (identical(_renewing, renewing)) _renewing = null;
    });
  }

  Future<void> _renew() async {
    try {
      await _ensureWbiKeys(refresh: true);
    } catch (e) {
      developer.log('Bilibili WBI keys not renewed', error: e.runtimeType);
    }
    try {
      await _identity.renew();
    } catch (e) {
      developer.log('Bilibili device id not renewed', error: e.runtimeType);
    }
  }

  /// The WBI keys, reused for [wbiKeyLifetime]; concurrent callers share one
  /// `nav` request. [refresh] asks again even when the keys are young.
  Future<void> _ensureWbiKeys({bool refresh = false}) {
    final at = _wbiKeysAt;
    if (!refresh &&
        _imgKey != null &&
        _subKey != null &&
        at != null &&
        _clock().difference(at) < wbiKeyLifetime) {
      return Future<void>.value();
    }
    final running = _wbiKeysLoading;
    if (running != null) return running;
    final loading = _fetchWbiKeys();
    _wbiKeysLoading = loading;
    return loading.whenComplete(() {
      if (identical(_wbiKeysLoading, loading)) _wbiKeysLoading = null;
    });
  }

  Future<void> _fetchWbiKeys() async {
    // nav answers -101 when signed out but still returns the WBI keys.
    final nav = await _getJson(
      '$_api/x/web-interface/nav',
      referer: _rootReferer,
      what: '签名密钥',
      session: true,
    );
    final wbi = readBiliMap(readBiliMap(nav['data'])['wbi_img']);
    String keyOf(Object? url) =>
        readBiliText(url).split('/').last.split('.').first;
    final img = keyOf(wbi['img_url']);
    final sub = keyOf(wbi['sub_url']);
    if (img.length + sub.length < 64) return;
    _imgKey = img;
    _subKey = sub;
    _wbiKeysAt = _clock();
  }

  /// Bilibili's public fingerprint endpoint: the `buvid3` / `buvid4` the web
  /// page gets for a new browser. Asked without any cookie.
  Future<({String b3, String b4})?> _fetchFingerprint() async {
    final spi = await _getJson(
      '$_api/x/frontend/finger/spi',
      referer: _rootReferer,
      what: '设备标识',
      session: false,
    );
    final data = readBiliMap(spi['data']);
    final b3 = readBiliText(data['b_3']);
    if (b3.isEmpty) return null;
    return (b3: b3, b4: readBiliText(data['b_4']));
  }

  /// Device id plus login cookies, as a browser on bilibili.com sends them.
  Future<({String header, bool device, bool login})> _sessionCookies() async {
    Map<String, String> device = const <String, String>{};
    try {
      device = (await _identity.ensure()).cookies;
    } catch (e) {
      developer.log('Bilibili device id unavailable', error: e.runtimeType);
    }
    Map<String, String> login = const <String, String>{};
    final source = _loginCookies ?? defaultLoginCookies;
    if (source != null) {
      try {
        login = await source();
      } catch (e) {
        developer.log('Bilibili login unavailable', error: e.runtimeType);
      }
    }
    return (
      header: buildBilibiliRequestCookieHeader([device, login]),
      device: device.isNotEmpty,
      login: (login['SESSDATA'] ?? '').isNotEmpty,
    );
  }

  // ------------------------------------------------------- other readers

  /// GET for other public readers (e.g. uploader data) on
  /// `api.bilibili.com`, with the device id and login like every request
  /// here. [path] starts with `/x/`.
  ///
  /// [signed] adds WBI signing with the shared [WbiSigner] (falls back to
  /// the plain query when the keys are unavailable). [origin] is sent as the
  /// Origin header; [attempt] 2 marks the retry after risk control in the
  /// diagnostics log.
  ///
  /// HTTP 412 comes back as `{'code': -412}` so callers can treat it as risk
  /// control; see [isRiskControlPayload]. Network, other HTTP and parse
  /// failures throw [BilibiliPublicApiException].
  Future<Map<String, dynamic>> getPublicJson(
    String path, {
    Map<String, dynamic> query = const <String, dynamic>{},
    required String referer,
    required String what,
    String? origin,
    bool signed = false,
    int attempt = 1,
  }) async {
    if (!path.startsWith('/x/')) {
      throw BilibiliPublicApiException('$what请求地址无效');
    }
    return _getJson(
      '$_api$path',
      query: signed ? await _signedQuery(query) : query,
      referer: referer,
      origin: origin,
      what: what,
      attempt: attempt,
      allowRiskStatus: true,
    );
  }

  /// Risk control / rate limiting: -352, -412, -799, HTTP 412, or a code-0
  /// answer that only carries a `v_voucher` challenge instead of data.
  static bool isRiskControlPayload(Map<String, dynamic> payload) {
    final code = payload['code'];
    if (code == -352 || code == -412 || code == -799) return true;
    if (payload['__http'] == 412) return true;
    final data = payload['data'];
    return code == 0 && data is Map && data.containsKey('v_voucher');
  }

  // ------------------------------------------------------------ short link

  /// Resolves a b23.tv short link without the login cookie: https only, at
  /// most [kBilibiliShortLinkMaxRedirects] redirects within [timeout], and
  /// never leaving Bilibili. Never throws; see [BilibiliShortLinkResult].
  Future<BilibiliShortLinkResult> resolveShortLink(
    Uri link, {
    Duration timeout = kBilibiliShortLinkTimeout,
  }) async {
    final cancel = CancelToken();
    try {
      return await resolveBilibiliShortLink(
        link,
        timeout: timeout,
        fetchRedirect: (url) async {
          final response = await _dio.getUri<dynamic>(
            url,
            cancelToken: cancel,
            options: Options(
              followRedirects: false,
              responseType: ResponseType.plain,
              headers: const {'Referer': _rootReferer},
            ),
          );
          final status = response.statusCode ?? 0;
          final location = response.headers.value('location');
          if (status < 300 || status >= 400 || location == null) return null;
          return Uri.tryParse(location.trim());
        },
      );
    } finally {
      // Drops a request still in flight after a timeout.
      cancel.cancel();
    }
  }

  // ---------------------------------------------------------------- shared

  String _requireKeyword(String keyword) {
    final text = keyword.trim();
    if (text.isEmpty) {
      throw const BilibiliPublicApiException('请输入搜索关键词');
    }
    return text;
  }

  int _safePage(int page) => page.clamp(1, kBilibiliSearchMaxPages).toInt();

  /// GET with the device id and login cookies ([session]), recorded in the
  /// diagnostics log when it goes to api.bilibili.com.
  Future<Map<String, dynamic>> _getJson(
    String url, {
    Map<String, dynamic>? query,
    required String referer,
    required String what,
    String? origin,
    bool session = true,
    int attempt = 1,
    bool allowRiskStatus = false,
  }) async {
    final cookies = session
        ? await _sessionCookies()
        : (header: '', device: false, login: false);
    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        url,
        queryParameters: query,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Referer': referer,
            'Origin': ?origin,
            if (cookies.header.isNotEmpty) 'Cookie': cookies.header,
          },
        ),
      );
    } on DioException catch (e) {
      developer.log('Bilibili public request failed: $what', error: e.type);
      throw BilibiliPublicApiException(
        '$what加载失败，请检查网络后重试',
        isNetworkError:
            e.type != DioExceptionType.badResponse &&
            e.type != DioExceptionType.cancel &&
            e.type != DioExceptionType.badCertificate,
      );
    }
    final result = _decodeAnswer(response, what, allowRiskStatus);
    final uri = Uri.tryParse(url);
    if (uri != null && uri.host == 'api.bilibili.com') {
      final (code, message) = BilibiliRequestLog.readCodeAndMessage(result.$2);
      BilibiliRequestLog.instance.record(
        BilibiliRequestRecord(
          method: 'GET',
          path: uri.path,
          httpStatus: response.statusCode,
          code: code,
          message: message,
          hasDeviceId: cookies.device,
          hasLogin: cookies.login,
          signed: query?.containsKey('w_rid') ?? false,
          attempt: attempt,
        ),
      );
    }
    final error = result.$1;
    if (error != null) throw error;
    return result.$2!;
  }

  /// The decoded answer, or the error to throw (after logging).
  (BilibiliPublicApiException?, Map<String, dynamic>?) _decodeAnswer(
    Response<dynamic> response,
    String what,
    bool allowRiskStatus,
  ) {
    final status = response.statusCode ?? 0;
    if (status == 412 && allowRiskStatus) {
      return (null, const <String, dynamic>{'code': -412, '__http': 412});
    }
    if (status != 200) {
      return (BilibiliPublicApiException('$what暂时不可用（HTTP $status）'), null);
    }
    final body = response.data;
    Object? decoded = body;
    if (body is String) {
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        return (BilibiliPublicApiException('$what返回的数据无法解析'), null);
      }
    }
    if (decoded is! Map) {
      return (BilibiliPublicApiException('$what返回的数据无法解析'), null);
    }
    return (null, readBiliMap(decoded));
  }
}
