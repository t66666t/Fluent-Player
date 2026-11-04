import 'package:video_player_app/services/network/network_http.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../debug/developer_log.dart' as developer;
import 'bilibili_request_log.dart';

/// The anonymous browser device id Bilibili's web pages carry in every
/// request: `buvid3`, `buvid4`, `b_nut` and `_uuid`.
///
/// These identify an installation, not an account. Requests without them
/// (or with only `buvid3`) are the ones Bilibili's risk control rejects
/// first: search answers HTTP 412, uploader pages -352 / -799, and account
/// writes "账号异常" or "非法访问". Values never reach a log.
class BilibiliDeviceIdentity {
  const BilibiliDeviceIdentity({
    required this.buvid3,
    this.buvid4 = '',
    required this.bNut,
    required this.uuid,
    this.serverIssued = false,
  });

  final String buvid3;
  final String buvid4;

  /// Seconds since the epoch when the id was first issued.
  final String bNut;
  final String uuid;
  final bool serverIssued;

  bool get isComplete =>
      buvid3.isNotEmpty && bNut.isNotEmpty && uuid.isNotEmpty;

  /// Cookie name to value, in the order a browser sends them.
  Map<String, String> get cookies => <String, String>{
    'buvid3': buvid3,
    if (buvid4.isNotEmpty) 'buvid4': buvid4,
    'b_nut': bNut,
    '_uuid': uuid,
  };

  Map<String, Object> toJson() => <String, Object>{
    'buvid3': buvid3,
    'buvid4': buvid4,
    'b_nut': bNut,
    '_uuid': uuid,
    'server_issued': serverIssued,
  };

  static BilibiliDeviceIdentity? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String read(String key) => (raw[key] ?? '').toString().trim();
    final identity = BilibiliDeviceIdentity(
      buvid3: read('buvid3'),
      buvid4: read('buvid4'),
      bNut: read('b_nut'),
      uuid: read('_uuid'),
      serverIssued: raw['server_issued'] == true,
    );
    return identity.isComplete ? identity : null;
  }

  /// A new id: [buvid3] / [buvid4] as issued by Bilibili's fingerprint
  /// endpoint when given, otherwise generated in the same shape the web
  /// page uses (an upper-case UUID, five digits and `infoc`).
  static BilibiliDeviceIdentity issue({
    String buvid3 = '',
    String buvid4 = '',
    required DateTime now,
    Random? random,
  }) {
    final rng = random ?? Random.secure();
    final b3 = buvid3.trim().isNotEmpty ? buvid3.trim() : _infocId(rng, now);
    return BilibiliDeviceIdentity(
      buvid3: b3,
      buvid4: buvid4.trim(),
      bNut: '${now.millisecondsSinceEpoch ~/ 1000}',
      uuid: _infocId(rng, now),
      serverIssued: buvid3.trim().isNotEmpty,
    );
  }

  static String _infocId(Random rng, DateTime now) {
    String hex(int count) => [
      for (var i = 0; i < count; i++)
        rng.nextInt(16).toRadixString(16).toUpperCase(),
    ].join();
    final suffix = (now.millisecondsSinceEpoch % 100000).toString().padLeft(
      5,
      '0',
    );
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}${suffix}infoc';
  }
}

/// Where the device id is kept between runs.
abstract class BilibiliDeviceIdentityStore {
  Future<BilibiliDeviceIdentity?> load();
  Future<void> save(BilibiliDeviceIdentity identity);
}

/// Kept in shared preferences (it is not a login secret). Storage failures
/// are ignored: the id is then simply issued again next run.
class PreferencesBilibiliDeviceIdentityStore
    implements BilibiliDeviceIdentityStore {
  const PreferencesBilibiliDeviceIdentityStore();

  static const String storageKey = 'bilibili_device_identity_v1';

  @override
  Future<BilibiliDeviceIdentity?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      return BilibiliDeviceIdentity.fromJson(jsonDecode(raw));
    } catch (e) {
      developer.log('Bilibili device id unreadable', error: e.runtimeType);
      return null;
    }
  }

  @override
  Future<void> save(BilibiliDeviceIdentity identity) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(identity.toJson()));
    } catch (e) {
      developer.log('Bilibili device id not saved', error: e.runtimeType);
    }
  }
}

class MemoryBilibiliDeviceIdentityStore implements BilibiliDeviceIdentityStore {
  MemoryBilibiliDeviceIdentityStore([this.value]);

  BilibiliDeviceIdentity? value;

  @override
  Future<BilibiliDeviceIdentity?> load() async => value;

  @override
  Future<void> save(BilibiliDeviceIdentity identity) async => value = identity;
}

/// Answer of Bilibili's public fingerprint endpoint (`b_3`, `b_4`), or null
/// when it could not be asked.
typedef BilibiliFingerprintFetch = Future<({String b3, String b4})?> Function();

/// Hands out the one device id of this installation: loaded from [store],
/// otherwise issued from the fingerprint endpoint (or generated when that
/// fails) and saved. Concurrent callers share one issue.
class BilibiliDeviceIdentitySource {
  BilibiliDeviceIdentitySource({
    required BilibiliFingerprintFetch fetchFingerprint,
    BilibiliDeviceIdentityStore? store,
    DateTime Function()? clock,
    Random? random,
  }) : _fetchFingerprint = fetchFingerprint,
       _store = store ?? const PreferencesBilibiliDeviceIdentityStore(),
       _clock = clock ?? DateTime.now,
       _random = random;

  /// The one source of the app: saved in shared preferences, issued from
  /// the fingerprint endpoint without any cookie. Services built with a
  /// test client use their own source instead.
  static final BilibiliDeviceIdentitySource shared =
      BilibiliDeviceIdentitySource(fetchFingerprint: _fetchSharedFingerprint);

  static Future<({String b3, String b4})?> _fetchSharedFingerprint() async {
    final dio = NetworkHttp.instance.createDio(
      scope: NetworkScope.bilibili,
      options: BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.json,
        validateStatus: (_) => true,
        headers: const {
          'User-Agent': bilibiliBrowserUserAgent,
          'Referer': 'https://www.bilibili.com/',
          'Accept': 'application/json, text/plain, */*',
        },
      ),
    );
    try {
      final response = await dio.get<dynamic>(
        'https://api.bilibili.com/x/frontend/finger/spi',
      );
      Object? payload = response.data;
      if (payload is String) payload = jsonDecode(payload);
      final (code, message) = BilibiliRequestLog.readCodeAndMessage(payload);
      BilibiliRequestLog.instance.record(
        BilibiliRequestRecord(
          method: 'GET',
          path: '/x/frontend/finger/spi',
          httpStatus: response.statusCode,
          code: code,
          message: message,
        ),
      );
      if (response.statusCode != 200 || code != 0) return null;
      final data = payload is Map ? payload['data'] : null;
      if (data is! Map) return null;
      final b3 = (data['b_3'] ?? '').toString().trim();
      if (b3.isEmpty) return null;
      return (b3: b3, b4: (data['b_4'] ?? '').toString().trim());
    } finally {
      dio.close(force: true);
    }
  }

  final BilibiliFingerprintFetch _fetchFingerprint;
  final BilibiliDeviceIdentityStore _store;
  final DateTime Function() _clock;
  final Random? _random;
  BilibiliDeviceIdentity? _current;
  Future<BilibiliDeviceIdentity>? _loading;

  /// The id last handed out, if any (no request).
  BilibiliDeviceIdentity? get current => _current;

  Future<BilibiliDeviceIdentity> ensure() {
    final known = _current;
    if (known != null) return Future<BilibiliDeviceIdentity>.value(known);
    return _run(() async => await _store.load() ?? await _issue());
  }

  /// Drops the current id and issues a new one (after risk control).
  Future<BilibiliDeviceIdentity> renew() {
    _current = null;
    return _run(_issue);
  }

  Future<BilibiliDeviceIdentity> _run(
    Future<BilibiliDeviceIdentity> Function() body,
  ) {
    final running = _loading;
    if (running != null) return running;
    final loading = body().then((identity) => _current = identity);
    _loading = loading;
    return loading.whenComplete(() {
      if (identical(_loading, loading)) _loading = null;
    });
  }

  Future<BilibiliDeviceIdentity> _issue() async {
    ({String b3, String b4})? fingerprint;
    try {
      fingerprint = await _fetchFingerprint();
    } catch (e) {
      developer.log('Bilibili fingerprint unavailable', error: e.runtimeType);
    }
    final identity = BilibiliDeviceIdentity.issue(
      buvid3: fingerprint?.b3 ?? '',
      buvid4: fingerprint?.b4 ?? '',
      now: _clock(),
      random: _random,
    );
    await _store.save(identity);
    return identity;
  }
}

/// Desktop browser User-Agent sent with the device id.
const String bilibiliBrowserUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// `name=value; ...` from [parts], later maps overriding earlier names.
String buildBilibiliRequestCookieHeader(Iterable<Map<String, String>> parts) {
  final merged = <String, String>{};
  for (final part in parts) {
    part.forEach((name, value) {
      if (name.isNotEmpty && value.isNotEmpty) merged[name] = value;
    });
  }
  return [for (final e in merged.entries) '${e.key}=${e.value}'].join('; ');
}
