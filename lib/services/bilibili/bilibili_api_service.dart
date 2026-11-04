// Community edition: executable downloader implementation removed.
// Community edition: executable downloader implementation removed.
import 'package:dio/dio.dart';
import 'bilibili_startup.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, visibleForTesting;
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'dart:async';
import 'package:video_player_app/services/network/network_http.dart';
import 'dart:convert';
import '../../debug/developer_log.dart' as developer;
import 'dart:io' show ZLibDecoder, gzip;
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/media_chapter.dart';
import 'package:video_player_app/services/bilibili/bilibili_cookie_store.dart';
import 'package:video_player_app/services/bilibili/bilibili_device_identity.dart';
import 'package:video_player_app/services/bilibili/bilibili_offline_details.dart';
import 'package:video_player_app/services/bilibili/wbi_signer.dart';
import 'package:video_player_app/utils/subtitle_util.dart';

/// Login state of the Bilibili account.
///
/// * [loggedOut]: no SESSDATA is stored locally.
/// * [loggedIn]: nav confirmed `isLogin == true`.
/// * [expired]: a cookie exists but nav explicitly answered "not logged in"
///   (`code == -101` or `isLogin == false`).
/// * [networkError]: offline, timeout, HTTP error, unexpected business code or
///   secure storage failure. Never treated as a logout; cookies are kept.
enum BilibiliLoginStatus { loggedOut, loggedIn, expired, networkError }

class BilibiliAccountInfo {
  final int mid;
  final String name;
  final String avatarUrl;

  const BilibiliAccountInfo({
    required this.mid,
    required this.name,
    required this.avatarUrl,
  });
}

class BilibiliLoginState {
  final BilibiliLoginStatus status;
  final BilibiliAccountInfo? account;

  const BilibiliLoginState(this.status, {this.account});
}

/// Raised when a login attempt cannot be completed. [message] is user-facing
/// Chinese text and never contains cookie values.
class BilibiliAuthException implements Exception {
  final String message;
  final BilibiliLoginStatus? status;

  const BilibiliAuthException(this.message, {this.status});

  @override
  String toString() => message;
}

class BilibiliPlayerMetadata {
  final List<BilibiliSubtitle> subtitles;
  final List<MediaChapter> chapters;

  /// An empty successful answer is different from an unavailable request.
  /// Deferred card imports retain their retry marker when the request failed.
  final bool requestSucceeded;

  const BilibiliPlayerMetadata({
    this.subtitles = const <BilibiliSubtitle>[],
    this.chapters = const <MediaChapter>[],
    this.requestSucceeded = true,
  });
}

class BilibiliApiService {
  static final Object _startupRequestZone = Object();

  Future<BilibiliStreamInfo> fetchStartupPlayUrl(
    String bvid,
    int cid,
    BilibiliStartupContext startup, {
    int? courseEpisodeId,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  late Dio _dio;

  /// Separate client without the cookie interceptor. Used for QR polling and
  /// nav verification so unverified cookies never reach the live jar.
  late Dio _authDio;

  /// In-memory jar for the live client. The persistent copy of the login
  /// lives in [BilibiliCookieStore] (platform secure storage).
  final CookieJar _cookieJar = CookieJar();
  final BilibiliCookieStore _cookieStore;
  Future<void>? _initFuture;
  String? _imgKey;
  String? _subKey;
  DateTime? _wbiKeysAt;
  Future<void>? _wbiKeysLoading;
  final DateTime Function() _clock;
  final ValueNotifier<int> _loginChanges = ValueNotifier<int>(0);

  /// Last login read, so the account page can paint it before the next nav
  /// check instead of flashing a spinner.
  BilibiliLoginState? cachedLoginState;

  /// Counts up whenever the stored login is replaced or removed (cookie or
  /// QR login, logout), so readers that depend on it can ask again.
  ValueListenable<int> get loginChanges => _loginChanges;

  /// How long the WBI signing keys are reused before `nav` is asked again.
  /// Bilibili rotates them about once a day; a rejected signature refreshes
  /// them at once.
  static const Duration wbiKeyLifetime = Duration(hours: 6);

  static const String _navUrl = "https://api.bilibili.com/x/web-interface/nav";
  static final Uri _cookieUri = Uri.parse("https://api.bilibili.com");

  static const String _userAgent = bilibiliBrowserUserAgent;
  static const String _referer = "https://www.bilibili.com/";

  BilibiliApiService({
    BilibiliCookieStore? cookieStore,
    HttpClientAdapter? httpClientAdapter,
    @visibleForTesting DateTime Function()? clock,
  }) : _cookieStore = cookieStore ?? BilibiliCookieStore(),
       _clock = clock ?? DateTime.now {
    BaseOptions options() => BaseOptions(
      headers: {"User-Agent": _userAgent, "Referer": _referer},
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    );
    _dio = NetworkHttp.instance.createDio(
      options: options(),
      scope: NetworkScope.bilibili,
    );
    _authDio = NetworkHttp.instance.createDio(
      options: options(),
      scope: NetworkScope.bilibili,
    );
    if (httpClientAdapter != null) {
      _dio.httpClientAdapter = httpClientAdapter;
      _authDio.httpClientAdapter = httpClientAdapter;
    }
  }

  Future<void> init() {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  Future<void> _initInternal() async {
    _dio.interceptors.add(CookieManager(_cookieJar));
    var cookies = <String, String>{};
    try {
      final migration = await _cookieStore.migrateLegacyIfPresent();
      if (migration.outcome == BilibiliLegacyCookieMigration.failedKeptLegacy) {
        // Keep using the old login for this run; migration retries next start.
        cookies = migration.legacyCookies;
      }
    } catch (e) {
      developer.log('Bilibili cookie migration failed', error: e.runtimeType);
    }
    if (cookies.isEmpty) {
      try {
        cookies = await _cookieStore.readCookies();
      } catch (e) {
        developer.log(
          'Bilibili secure cookie storage unavailable',
          error: e.runtimeType,
        );
      }
    }
    await _applyCookiesToJar(cookies);
  }

  Future<void> _applyCookiesToJar(Map<String, String> cookies) async {
    await _cookieJar.deleteAll();
    if (cookies.isEmpty) return;
    final list = <Cookie>[
      for (final entry in cookies.entries)
        Cookie(entry.key, entry.value)
          ..domain = ".bilibili.com"
          ..path = "/"
          ..httpOnly = entry.key == 'SESSDATA',
    ];
    await _cookieJar.saveFromResponse(_cookieUri, list);
  }

  Future<bool> hasCookie() async {
    await init();
    final cookies = await _cookieJar.loadForRequest(_cookieUri);
    return cookies.any((c) => c.name == "SESSDATA" && c.value.isNotEmpty);
  }

  /// Cookies of the verified login for authenticated video, subtitle and
  /// browsing reads. Callers must never log the values.
  Future<Map<String, String>> readLoginCookies() async {
    await init();
    final cookies = await _cookieJar.loadForRequest(_cookieUri);
    return <String, String>{
      for (final cookie in cookies)
        if (cookie.value.isNotEmpty) cookie.name: cookie.value,
    };
  }

  /// Interprets a nav response. Only an explicit "not logged in" from
  /// Bilibili is [BilibiliLoginStatus.expired]; anything unexpected is a
  /// [BilibiliLoginStatus.networkError] so the stored login is kept.
  static BilibiliLoginStatus classifyLoginResponse({
    required int? statusCode,
    required dynamic responseData,
  }) => parseNavResponse(
    statusCode: statusCode,
    responseData: responseData,
  ).status;

  static BilibiliLoginState parseNavResponse({
    required int? statusCode,
    required dynamic responseData,
  }) {
    if (statusCode != 200) {
      return const BilibiliLoginState(BilibiliLoginStatus.networkError);
    }
    dynamic payload = responseData;
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } on FormatException {
        return const BilibiliLoginState(BilibiliLoginStatus.networkError);
      }
    }
    if (payload is! Map) {
      return const BilibiliLoginState(BilibiliLoginStatus.networkError);
    }
    final code = payload['code'];
    final data = payload['data'];
    if (code == -101) {
      return const BilibiliLoginState(BilibiliLoginStatus.expired);
    }
    if (code != 0 || data is! Map || data['isLogin'] is! bool) {
      return const BilibiliLoginState(BilibiliLoginStatus.networkError);
    }
    if (data['isLogin'] != true) {
      return const BilibiliLoginState(BilibiliLoginStatus.expired);
    }
    final rawFace = data['face'] is String
        ? (data['face'] as String).trim()
        : '';
    final face = rawFace.startsWith('//')
        ? 'https:$rawFace'
        : rawFace.replaceFirst(RegExp(r'^http://'), 'https://');
    final rawName = data['uname'] is String
        ? (data['uname'] as String).trim()
        : '';
    return BilibiliLoginState(
      BilibiliLoginStatus.loggedIn,
      account: BilibiliAccountInfo(
        mid: (data['mid'] as num?)?.toInt() ?? 0,
        name: rawName.isEmpty ? '已登录用户' : rawName,
        avatarUrl: face.startsWith('https://') ? face : '',
      ),
    );
  }

  /// Checks the stored login against nav. Without a stored SESSDATA this
  /// returns [BilibiliLoginStatus.loggedOut] without touching the network.
  /// Network failures never clear cookies.
  Future<BilibiliLoginState> fetchLoginState() async {
    if (!await hasCookie()) {
      return _rememberLogin(
        const BilibiliLoginState(BilibiliLoginStatus.loggedOut),
      );
    }
    try {
      final response = await _dio.get(
        _navUrl,
        options: Options(validateStatus: (_) => true),
      );
      return _rememberLogin(
        parseNavResponse(
          statusCode: response.statusCode,
          responseData: response.data,
        ),
      );
    } catch (e) {
      developer.log('Error checking login status', error: e.runtimeType);
      return _rememberLogin(
        const BilibiliLoginState(BilibiliLoginStatus.networkError),
      );
    }
  }

  BilibiliLoginState _rememberLogin(BilibiliLoginState state) {
    cachedLoginState = state;
    return state;
  }

  Future<BilibiliLoginStatus> checkLoginStatusDetailed() async =>
      (await fetchLoginState()).status;

  /// Compatibility helper for callers that only need a boolean result.
  Future<bool> checkLoginStatus() async =>
      await checkLoginStatusDetailed() == BilibiliLoginStatus.loggedIn;

  /// Verifies [cookies] against nav with an explicit Cookie header (the live
  /// jar is not touched), then persists them in secure storage and activates
  /// them. Throws [BilibiliAuthException] on any failure; previously stored
  /// cookies stay untouched in that case.
  Future<BilibiliAccountInfo> verifyAndSaveCookies(
    Map<String, String> cookies,
  ) async {
    await init();
    final session = BilibiliCookieStore.filterSessionCookies(cookies);
    if ((session['SESSDATA'] ?? '').isEmpty) {
      throw const BilibiliAuthException(
        '没有找到有效的 SESSDATA，无法登录',
        status: BilibiliLoginStatus.loggedOut,
      );
    }
    BilibiliLoginState state = const BilibiliLoginState(
      BilibiliLoginStatus.networkError,
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      state = await _requestNavWith(session);
      if (state.status != BilibiliLoginStatus.networkError) break;
    }
    switch (state.status) {
      case BilibiliLoginStatus.loggedIn:
        break;
      case BilibiliLoginStatus.networkError:
        throw const BilibiliAuthException(
          '暂时无法连接 B 站验证登录，请检查网络后重试',
          status: BilibiliLoginStatus.networkError,
        );
      case BilibiliLoginStatus.expired:
      case BilibiliLoginStatus.loggedOut:
        throw const BilibiliAuthException(
          'B 站未确认登录，Cookie 无效或已过期',
          status: BilibiliLoginStatus.expired,
        );
    }
    try {
      await _cookieStore.replaceCookies(session);
    } catch (e) {
      developer.log(
        'Saving verified Bilibili cookies failed',
        error: e.runtimeType,
      );
      throw const BilibiliAuthException(
        '登录已验证，但无法安全保存到本机，请重试',
        status: BilibiliLoginStatus.networkError,
      );
    }
    await _applyCookiesToJar(session);
    _rememberLogin(state);
    _loginChanges.value++;
    return state.account!;
  }

  /// Manual login: accepts a bare SESSDATA or a full cookie header.
  Future<BilibiliAccountInfo> loginWithCookieInput(String rawInput) =>
      verifyAndSaveCookies(parseBilibiliCookieInput(rawInput));

  /// Removes the stored login (secure storage and live jar).
  Future<void> logout() async {
    await _cookieStore.clear();
    await _cookieJar.deleteAll();
    _rememberLogin(const BilibiliLoginState(BilibiliLoginStatus.loggedOut));
    _loginChanges.value++;
  }

  Future<BilibiliLoginState> _requestNavWith(
    Map<String, String> cookies,
  ) async {
    try {
      final response = await _authDio.get(
        _navUrl,
        options: Options(
          headers: {"Cookie": buildBilibiliCookieHeader(cookies)},
          validateStatus: (_) => true,
        ),
      );
      return parseNavResponse(
        statusCode: response.statusCode,
        responseData: response.data,
      );
    } catch (e) {
      developer.log('Error verifying login cookies', error: e.runtimeType);
      return const BilibiliLoginState(BilibiliLoginStatus.networkError);
    }
  }

  /// Collects cookies from a QR poll success response: Set-Cookie headers
  /// first, then the cross-domain URL query as fallback.
  static Map<String, String> extractQrLoginCookies({
    required List<String>? setCookieHeaders,
    required dynamic redirectUrl,
  }) {
    final cookies = <String, String>{};
    for (final header in setCookieHeaders ?? const <String>[]) {
      try {
        final cookie = Cookie.fromSetCookieValue(header);
        if (cookie.value.isNotEmpty) cookies[cookie.name] = cookie.value;
      } catch (_) {
        // Ignore malformed Set-Cookie lines.
      }
    }
    // Headers may contain SESSDATA while the redirect supplies bili_jct.
    // Merge each missing field, rather than skipping the entire fallback.
    if (redirectUrl is String) {
      final uri = Uri.tryParse(redirectUrl);
      if (uri != null &&
          uri.scheme == 'https' &&
          (uri.host == 'bilibili.com' || uri.host.endsWith('.bilibili.com'))) {
        for (final name in BilibiliCookieStore.sessionCookieNames) {
          final value = uri.queryParameters[name];
          if (value != null && value.isNotEmpty) {
            cookies.putIfAbsent(name, () => value);
          }
        }
      }
    }
    return BilibiliCookieStore.filterSessionCookies(cookies);
  }

  // --- QR Code Login ---

  Future<Map<String, String>> generateQrCode() async {
    try {
      final response = await _authDio.get(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/generate",
      );
      final payload = response.data;
      final data = payload is Map && payload['code'] == 0
          ? payload['data']
          : null;
      final url = data is Map ? data['url'] : null;
      final key = data is Map ? data['qrcode_key'] : null;
      final uri = url is String ? Uri.tryParse(url) : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          !(uri.host == 'bilibili.com' || uri.host.endsWith('.bilibili.com')) ||
          key is! String ||
          key.trim().isEmpty) {
        throw const BilibiliAuthException('无法获取有效二维码，请重试');
      }
      return {'url': url as String, 'qrcode_key': key};
    } catch (e) {
      developer.log('Error generating QR code', error: e.runtimeType);
      rethrow;
    }
  }

  /// Polls the QR login. On scan confirmation the returned cookies are
  /// checked for SESSDATA, verified with nav, and only then saved.
  ///
  /// Result keys: `success` (bool), `code` (Bilibili poll code; -1 network,
  /// -2 verification/saving failed), `message`, optional `account`.
  Future<Map<String, dynamic>> pollQrCode(String qrcodeKey) async {
    final Response<dynamic> response;
    try {
      // Auth client: Set-Cookie from this response must not reach the live
      // jar before nav has confirmed the login.
      response = await _authDio.get(
        "https://passport.bilibili.com/x/passport-login/web/qrcode/poll",
        queryParameters: {'qrcode_key': qrcodeKey},
      );
    } catch (e) {
      developer.log('Error polling QR code', error: e.runtimeType);
      return {'success': false, 'code': -1, 'message': '网络异常，正在重试'};
    }
    final payload = response.data;
    final data = payload is Map && payload['code'] == 0
        ? payload['data']
        : null;
    if (data is! Map) {
      return {'success': false, 'code': -1, 'message': '扫码状态暂时不可用'};
    }

    // data['code']: 0=Success, 86101=Unscanned, 86090=Scanned but not confirmed, 86038=Expired
    final code = data['code'];
    if (code != 0) {
      return {'success': false, 'code': code, 'message': data['message']};
    }

    final cookies = extractQrLoginCookies(
      setCookieHeaders: response.headers['set-cookie'],
      redirectUrl: data['url'],
    );
    if ((cookies['SESSDATA'] ?? '').isEmpty) {
      return {
        'success': false,
        'code': -2,
        'message': '扫码已确认，但没有拿到登录凭据，请刷新二维码重试',
      };
    }
    try {
      final account = await verifyAndSaveCookies(cookies);
      return {'success': true, 'message': '登录成功', 'account': account};
    } on BilibiliAuthException catch (e) {
      return {'success': false, 'code': -2, 'message': e.message};
    }
  }

  /// The WBI keys, fetched once and reused for [wbiKeyLifetime]; callers
  /// asking at the same time share one `nav` request. [refresh] asks again
  /// even when the keys are still young (a rejected signature).
  Future<void> _ensureWbiKeys({bool refresh = false}) {
    final at = _wbiKeysAt;
    final fresh =
        _imgKey != null &&
        _subKey != null &&
        at != null &&
        _clock().difference(at) < wbiKeyLifetime;
    if (fresh && !refresh) return Future<void>.value();
    final running = _wbiKeysLoading;
    if (running != null) return running;
    final loading = _fetchWbiKeys();
    _wbiKeysLoading = loading;
    return loading.whenComplete(() {
      if (identical(_wbiKeysLoading, loading)) _wbiKeysLoading = null;
    });
  }

  /// Fetches the WBI keys ahead of a signed request (a tapped video asks for
  /// its play address right after its info). Failures are left to that
  /// request.
  Future<void> warmUpSigning() async {
    try {
      await _ensureWbiKeys();
    } catch (_) {
      // The signed request asks again and reports the reason.
    }
  }

  Future<void> _fetchWbiKeys() async {
    try {
      final response = await _dio.get(
        "https://api.bilibili.com/x/web-interface/nav",
      );
      final data = response.data['data'];
      final wbiImg = data['wbi_img'];
      final imgUrl = wbiImg['img_url'] as String;
      final subUrl = wbiImg['sub_url'] as String;

      _imgKey = imgUrl.split('/').last.split('.').first;
      _subKey = subUrl.split('/').last.split('.').first;
      _wbiKeysAt = _clock();
    } catch (e) {
      developer.log('Error fetching WBI keys', error: e);
      rethrow;
    }
  }

  Future<String> resolveShortLink(String url) async {
    try {
      final response = await _dio.head(
        url,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final statusCode = response.statusCode ?? 0;
      if (statusCode >= 300 && statusCode < 400) {
        final location = response.headers.value('location');
        if (location != null && location.isNotEmpty) {
          return Uri.parse(url).resolve(location).toString();
        }
      }
    } catch (e) {
      developer.log('Error resolving short link', error: e);
    }

    // Some short-link services reject HEAD or return an HTML response for it.
    // A following GET still exposes the final redirect URI without depending
    // on a particular 3xx status code.
    try {
      final response = await _dio.get(url);
      return response.realUri.toString();
    } catch (e) {
      developer.log('Error resolving short link with GET fallback', error: e);
      return url;
    }
  }

  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    try {
      final params = <String, dynamic>{};
      if (bvid.isNotEmpty) params['bvid'] = bvid;
      if (aid != null) params['aid'] = aid;

      final response = await _dio.get(
        "https://api.bilibili.com/x/web-interface/view",
        queryParameters: params,
      );
      final info = BilibiliVideoInfo.fromJson(response.data);
      // Kept for the panel of a downloaded video when offline.
      unawaited(BilibiliOfflineDetails.instance.rememberInfo(info));
      return info;
    } catch (e) {
      developer.log('Error fetching video info', error: e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> fetchBangumiInfo({
    String? epId,
    String? seasonId,
  }) async {
    try {
      final params = <String, dynamic>{};
      if (epId != null) params['ep_id'] = epId;
      if (seasonId != null) params['season_id'] = seasonId;

      final response = await _dio.get(
        "https://api.bilibili.com/pgc/view/web/season",
        queryParameters: params,
      );
      return response.data['result'];
    } catch (e) {
      developer.log('Error fetching bangumi info', error: e);
      rethrow;
    }
  }

  /// Preserves the classroom namespace through task persistence and playback.
  /// Normal videos retain fetchPlayUrl, including its existing overrides.
  Future<BilibiliStreamInfo> fetchMediaPlayUrl(
    String bvid,
    int cid, {
    int? courseEpisodeId,
  }) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Future<Map<String, dynamic>> fetchCourseInfo({
    String? epId,
    String? seasonId,
  }) async {
    await init();
    final response = await _dio.get<dynamic>(
      'https://api.bilibili.com/pugv/view/web/season',
      queryParameters: {'ep_id': ?epId, 'season_id': ?seasonId},
      options: Options(
        headers: {'Referer': 'https://www.bilibili.com/cheese/'},
      ),
    );
    final data = _readCourseData(response.data, '课程信息');
    final episodes = <Map<String, dynamic>>[
      for (final raw in data['episodes'] as List? ?? const [])
        if (raw is Map) Map<String, dynamic>.from(raw),
    ];
    final expected =
        int.tryParse('${data['ep_count'] ?? ''}') ?? episodes.length;
    final page = data['episode_page'];
    if (episodes.length < expected || page is Map && page['next'] == true) {
      // Fetch from page one to handle EP links whose initial window is centred
      // on the selected lesson rather than on the start of the course.
      final seen = <String>{};
      final all = <Map<String, dynamic>>[];
      for (var pn = 1; ; pn++) {
        final response = await _dio.get<dynamic>(
          'https://api.bilibili.com/pugv/view/web/ep/list',
          queryParameters: {
            'season_id': data['season_id'],
            'pn': pn,
            'ps': 100,
          },
          options: Options(
            headers: {'Referer': 'https://www.bilibili.com/cheese/'},
          ),
        );
        final listing = _readCourseData(response.data, '课程目录');
        final before = all.length;
        for (final raw in listing['items'] as List? ?? const []) {
          if (raw is Map && seen.add('${raw['id']}')) {
            all.add(Map<String, dynamic>.from(raw));
          }
        }
        final page = listing['page'];
        final next = page is Map && page['next'] == true;
        if (!next) {
          if (all.length < expected) throw StateError('课程目录不完整，请重试');
          break;
        }
        if (all.length == before) throw StateError('课程目录分页没有返回新课时，请重试');
      }
      episodes
        ..clear()
        ..addAll(all);
    }
    return {...data, 'episodes': episodes};
  }

  Future<BilibiliStreamInfo> fetchCoursePlayUrl(int episodeId) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  Map<String, dynamic> _readCourseData(dynamic payload, String what) {
    final code = payload is Map ? payload['code'] : null;
    if (code == -101) throw StateError('请先登录购买该课程的哔哩哔哩账号');
    if (code == -403) {
      throw StateError('当前登录账号没有该课时的观看权限，请确认已登录购买课程的账号且课程未过期');
    }
    if (payload is! Map || code != 0 || payload['data'] is! Map) {
      throw StateError('$what获取失败（${code ?? '响应无效'}）');
    }
    final data = Map<String, dynamic>.from(payload['data'] as Map);
    final nestedCode = data['code'];
    if (nestedCode != null && nestedCode != 0) {
      throw StateError('$what获取失败（$nestedCode）');
    }
    return data;
  }

  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    return throw UnsupportedError('此开源版本不包含网站媒体提取或下载');
  }

  /// Keep upstream denials actionable without printing signed addresses or
  /// arbitrary server messages. UGC and PGC adapters are both tried first.
  @visibleForTesting
  static String? playbackRestriction(Object? payload) {
    if (payload is! Map || payload['code'] == 0) return null;
    final message = '${payload['message'] ?? payload['msg'] ?? ''}'
        .toLowerCase();
    if (RegExp('地区|区域|地域|region|area').hasMatch(message)) {
      return '当前视频受地区限制，无法播放';
    }
    if (RegExp('付费|购买|大会员|会员专享|vip|payment').hasMatch(message)) {
      return '当前视频需要大会员或购买后播放';
    }
    if (payload['code'] == -101 || RegExp('登录|login').hasMatch(message)) {
      return '当前账号需要登录后播放';
    }
    if (RegExp('权限|permission').hasMatch(message)) {
      return '当前账号没有该视频的播放权限';
    }
    return null;
  }

  /// Returns Bilibili's pre-generated seek-preview sprite metadata.
  /// A null result means that the video has no published preview sprites.
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async {
    try {
      final response = await _dio.get(
        'https://api.bilibili.com/x/player/videoshot',
        queryParameters: <String, dynamic>{
          'bvid': bvid,
          'cid': cid,
          'index': 1,
        },
      );
      final payload = response.data;
      if (payload is! Map || payload['code'] != 0 || payload['data'] is! Map) {
        return null;
      }
      return Map<String, dynamic>.from(payload['data'] as Map);
    } catch (error) {
      developer.log(
        'Error fetching Bilibili video-shot metadata',
        error: error,
      );
      return null;
    }
  }

  Future<List<BilibiliSubtitle>> fetchSubtitles(
    String bvid,
    int cid, {
    String? aid,
    bool skipAi = false,
  }) async {
    final metadata = await fetchPlayerMetadata(
      bvid,
      cid,
      aid: aid,
      skipAiSubtitles: skipAi,
    );
    return metadata.subtitles;
  }

  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async {
    try {
      final List<BilibiliSubtitle> subtitles = [];
      final Set<String> seenUrls = {};
      final List<MediaChapter> chapters = [];
      var requestSucceeded = false;

      developer.log(
        'Fetching player metadata for bvid=$bvid, cid=$cid, aid=$aid',
      );

      // Step 1: Request x/player/wbi/v2 (Signed, most reliable)
      try {
        await _ensureWbiKeys();

        final Map<String, dynamic> params = {'cid': cid};
        if (bvid.isNotEmpty) {
          params['bvid'] = bvid;
        } else if (aid != null && aid.isNotEmpty) {
          params['aid'] = aid;
        }

        final signedParams = WbiSigner.sign(params, _imgKey!, _subKey!);

        final wbiV2Response = await _dio.get(
          "https://api.bilibili.com/x/player/wbi/v2",
          queryParameters: signedParams,
        );

        final payload = wbiV2Response.data;
        if (payload is! Map ||
            payload['code'] != 0 ||
            payload['data'] is! Map) {
          throw const FormatException('Bilibili player metadata unavailable');
        }

        final subtitlesList =
            wbiV2Response.data['data']?['subtitle']?['subtitles'];
        if (subtitlesList is List && subtitlesList.isNotEmpty) {
          for (var item in subtitlesList) {
            _addSubtitleToList(item, subtitles, seenUrls);
          }
          if (subtitles.isNotEmpty) {
            developer.log('Fetched subtitles from player/wbi/v2');
          }
        }
        final viewPoints = wbiV2Response.data['data']?['view_points'];
        if (viewPoints is List) {
          chapters.addAll(
            viewPoints.whereType<Map>().map(
              (item) => MediaChapter.fromJson(Map<String, dynamic>.from(item)),
            ),
          );
        }
        requestSucceeded = true;
      } catch (e) {
        developer.log(
          'Warning: Failed to fetch player metadata from player/wbi/v2',
          error: e,
        );
      }

      // Fallback methods removed as requested by user to avoid incorrect matches.
      return BilibiliPlayerMetadata(
        requestSucceeded: requestSucceeded,
        subtitles: skipAiSubtitles
            ? subtitles.where((subtitle) => !subtitle.isAi).toList()
            : subtitles,
        chapters: MediaChapter.normalize(
          chapters,
          durationMs: durationSeconds * 1000,
        ),
      );
    } catch (e) {
      developer.log('Error fetching player metadata', error: e);
      return const BilibiliPlayerMetadata(requestSucceeded: false);
    }
  }

  /// The signed player answer (`x/player/wbi/v2`) of one part, asked with
  /// the live login and returned whole (`code`, `data`). Unlike
  /// [fetchPlayerMetadata] nothing is swallowed: a request that fails
  /// throws, so the subtitle area can tell "could not ask" from "no
  /// subtitles". A rejected signature refreshes the keys once. Logs carry
  /// only bvid and cid.
  Future<Map<String, dynamic>> fetchPlayerAnswer(String bvid, int cid) async {
    await init();
    await _ensureWbiKeys();
    for (var attempt = 0; ; attempt++) {
      final Response<dynamic> response;
      try {
        response = await _dio.get<dynamic>(
          "https://api.bilibili.com/x/player/wbi/v2",
          queryParameters: WbiSigner.sign(
            <String, dynamic>{'bvid': bvid, 'cid': cid},
            _imgKey!,
            _subKey!,
          ),
        );
      } catch (e) {
        developer.log(
          'Player answer for bvid=$bvid, cid=$cid failed',
          error: e.runtimeType,
        );
        rethrow;
      }
      Object? payload = response.data;
      if (payload is String) payload = jsonDecode(payload);
      if (payload is! Map) {
        throw const FormatException('播放器信息无法解析');
      }
      if (attempt == 0 && payload['code'] == -403) {
        await _ensureWbiKeys(refresh: true);
        continue;
      }
      return Map<String, dynamic>.from(payload);
    }
  }

  void _addSubtitleToList(
    dynamic item,
    List<BilibiliSubtitle> list,
    Set<String> seenUrls,
  ) {
    final url = (item['subtitle_url'] ?? '').toString();
    if (url.isEmpty || seenUrls.contains(url)) return;

    String finalUrl = url;
    if (finalUrl.startsWith("//")) finalUrl = "https:$finalUrl";

    final lan = item['lan'] ?? '';
    final lanDoc = item['lan_doc'] ?? SubtitleUtil.getLanguageName(lan);

    // AI detection
    final isLock = item['is_lock'];
    final bool isLocked = isLock == true || isLock == 1;
    final bool isAi =
        isLocked ||
        lan.toString().startsWith("ai-") ||
        lanDoc.toString().toUpperCase().contains("AI") ||
        lanDoc.toString().contains("自动") ||
        lanDoc.toString().contains("机器");

    list.add(
      BilibiliSubtitle(
        id: item['id']?.toString() ?? '',
        lan: lan,
        lanDoc: lanDoc,
        url: finalUrl,
        isAi: isAi,
      ),
    );
    seenUrls.add(url);
  }

  Future<dynamic> fetchSubtitleContent(String url) async {
    try {
      final response = await _dio.get(
        url,
        options: Options(
          headers: {"User-Agent": _userAgent, "Referer": _referer},
        ),
      );
      return response.data; // Return raw data (Map or String)
    } catch (e) {
      developer.log('Error downloading subtitle content', error: e);
      return null;
    }
  }

  Future<String> fetchDanmakuXml(int cid) async {
    final response = await _dio.get<List<int>>(
      'https://comment.bilibili.com/$cid.xml',
      options: Options(
        responseType: ResponseType.bytes,
        headers: const {'Accept': 'application/xml,text/xml,*/*'},
      ),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) {
      throw StateError('Bilibili returned an empty danmaku file.');
    }
    final content = decodeBilibiliDanmakuPayload(
      bytes,
      contentEncoding: response.headers.value('content-encoding'),
    );
    if (content.trim().isEmpty) {
      throw StateError('Bilibili returned an empty danmaku file.');
    }
    if (!RegExp(r'<i(?:\s|>)', caseSensitive: false).hasMatch(content) ||
        !RegExp(r'</i\s*>', caseSensitive: false).hasMatch(content)) {
      throw const FormatException('Bilibili returned invalid danmaku XML.');
    }
    return content;
  }

  // Helper to get Dio instance for downloading
  Dio get dio => _dio;
}

String decodeBilibiliDanmakuPayload(
  List<int> bytes, {
  String? contentEncoding,
}) {
  final encoding = contentEncoding?.toLowerCase() ?? '';
  try {
    final plain = utf8.decode(bytes, allowMalformed: false);
    if (RegExp(r'^\s*<', multiLine: true).hasMatch(plain)) {
      return plain;
    }
  } on FormatException {
    // Compressed data is expected to fail direct UTF-8 decoding.
  }

  List<int> decoded = bytes;
  final hasGzipHeader =
      bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  final hasZlibHeader = bytes.length > 1 && bytes[0] == 0x78;
  if (encoding.contains('gzip') || hasGzipHeader) {
    decoded = gzip.decode(bytes);
  } else if (encoding.contains('deflate') || hasZlibHeader) {
    try {
      decoded = ZLibDecoder().convert(bytes);
    } on FormatException {
      decoded = ZLibDecoder(raw: true).convert(bytes);
    }
  }
  return utf8.decode(decoded, allowMalformed: false);
}
