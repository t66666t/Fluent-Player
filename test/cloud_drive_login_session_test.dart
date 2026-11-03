import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_session.dart';

class _CookieJar extends PlatformCookieManager {
  _CookieJar({this.withMetadata = true})
    : super.implementation(const PlatformCookieManagerCreationParams());

  final bool withMetadata;
  final cookies = <Cookie>[];
  final deletions = <({String host, String? domain, String path})>[];
  bool failDelete = false;

  @override
  Future<List<Cookie>> getCookies({
    required WebUri url,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async => cookies
      .where((cookie) {
        final domain = cookie.domain!.replaceFirst(RegExp(r'^\.'), '');
        return (url.host == domain || url.host.endsWith('.$domain')) &&
            url.path.startsWith(cookie.path!);
      })
      .map(
        (cookie) => Cookie(
          name: cookie.name,
          value: cookie.value,
          domain: withMetadata ? cookie.domain : null,
          path: withMetadata ? cookie.path : null,
          isHttpOnly: true,
        ),
      )
      .toList();

  @override
  Future<bool> deleteCookie({
    required WebUri url,
    required String name,
    String path = '/',
    String? domain,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    deletions.add((host: url.host, domain: domain, path: path));
    if (failDelete) return false;
    final target = (domain ?? url.host).replaceFirst(RegExp(r'^\.'), '');
    cookies.removeWhere(
      (cookie) =>
          cookie.name == name &&
          cookie.domain!.replaceFirst(RegExp(r'^\.'), '') == target &&
          cookie.path == path,
    );
    return true;
  }
}

class _Platform extends InAppWebViewPlatform {
  final views = <_Headless>[];
  bool clearSucceeds = true;
  final storage = <String, String>{};
  final records = <WebsiteDataRecord>[];
  final removedRecords = <WebsiteDataRecord>[];

  @override
  PlatformHeadlessInAppWebView createPlatformHeadlessInAppWebView(
    PlatformHeadlessInAppWebViewCreationParams params,
  ) {
    final view = _Headless(params, this);
    views.add(view);
    return view;
  }

  @override
  PlatformWebStorageManager createPlatformWebStorageManager(
    PlatformWebStorageManagerCreationParams params,
  ) => _WebStorage(params, this);
}

class _WebStorage extends PlatformWebStorageManager {
  _WebStorage(super.params, this.owner) : super.implementation();
  final _Platform owner;
  @override
  Future<List<WebsiteDataRecord>> fetchDataRecords({
    required Set<WebsiteDataType> dataTypes,
  }) async => owner.records;
  @override
  Future<void> removeDataFor({
    required Set<WebsiteDataType> dataTypes,
    required List<WebsiteDataRecord> dataRecords,
  }) async => owner.removedRecords.addAll(dataRecords);
}

class _Headless extends PlatformHeadlessInAppWebView {
  _Headless(super.params, this.owner) : super.implementation();
  final _Platform owner;
  bool disposed = false;
  @override
  Future<void> run() async {
    expect(params.initialUrlRequest, isNull);
    expect(params.initialSettings!.blockNetworkLoads, true);
    expect(params.initialSettings!.incognito, false);
    final controller = _Controller(this);
    params.onLoadStop!(
      InAppWebViewController.fromPlatform(platform: controller),
      params.initialData!.baseUrl,
    );
  }

  @override
  Future<void> dispose() async => disposed = true;
}

class _Controller extends PlatformInAppWebViewController {
  _Controller(this.view)
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'cleanup'),
      );
  final _Headless view;
  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    final origin = view.params.initialData!.baseUrl!.origin;
    if (!view.owner.clearSucceeds) return false;
    view.owner.storage.remove(origin);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final withMetadata in [true, false]) {
    for (final provider in ['baidu', 'quark', 'uc', 'aliyun']) {
      test(
        '$provider removes old sessions (cookie metadata=$withMetadata)',
        () async {
          final jar = _CookieJar(withMetadata: withMetadata);
          final urls = cloudDriveLoginCookieUrls(provider);
          final roots = cloudDriveLoginDomains(provider);
          for (final domain in roots) {
            jar.cookies.add(
              Cookie(name: 'sso', value: 'old', domain: '.$domain', path: '/'),
            );
          }
          for (final value in urls) {
            final url = WebUri(value);
            jar.cookies.add(
              Cookie(
                name: 'session',
                value: 'old',
                domain: url.host,
                path: url.path,
              ),
            );
          }
          jar.cookies.addAll([
            Cookie(
              name: 'SESSDATA',
              value: 'bilibili',
              domain: '.bilibili.com',
              path: '/',
            ),
            Cookie(
              name: 'other',
              value: 'other',
              domain: '.example.com',
              path: '/',
            ),
            Cookie(
              name: 'lookalike',
              value: 'other',
              domain: '.not${roots.first}',
              path: '/',
            ),
          ]);

          await clearCloudDriveLoginCookies(
            providerId: provider,
            cookieManager: CookieManager.fromPlatform(jar),
          );
          expect(
            jar.cookies.map((cookie) => cookie.value),
            everyElement(isNot('old')),
          );
          expect(
            jar.cookies.map((cookie) => cookie.name),
            containsAll(['SESSDATA', 'other', 'lookalike']),
          );
          expect(jar.deletions, isNotEmpty);
        },
      );
    }
  }

  test('Android clears Alipan tokens and keeps other sites storage', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final platform = _Platform();
    InAppWebViewPlatform.instance = platform;
    for (final host in [
      'alipan.com',
      'www.alipan.com',
      'auth.alipan.com',
      'aliyundrive.com',
      'www.aliyundrive.com',
      'pan.quark.cn',
    ]) {
      platform.storage['https://$host'] = 'old-token';
    }
    final manager = CookieManager.fromPlatform(_CookieJar());
    await resetSharedCloudDriveLoginSession(
      providerId: 'aliyun',
      cookieManager: manager,
    );
    expect(platform.storage, {'https://pan.quark.cn': 'old-token'});
    expect(platform.views, hasLength(5));
    expect(platform.views.every((view) => view.disposed), true);

    // The completed cleanup must not keep deleting a newly signed-in session.
    platform.storage['https://www.alipan.com'] = 'new-token';
    await Future<void>.delayed(Duration.zero);
    expect(platform.storage['https://www.alipan.com'], 'new-token');
    await resetSharedCloudDriveLoginSession(
      providerId: 'aliyun',
      cookieManager: manager,
    );
    expect(platform.storage['https://www.alipan.com'], isNull);
  });

  test(
    'failed cleanup propagates and releases the temporary native view',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platform = _Platform()..clearSucceeds = false;
      InAppWebViewPlatform.instance = platform;
      await expectLater(
        resetSharedCloudDriveLoginSession(
          providerId: 'quark',
          cookieManager: CookieManager.fromPlatform(_CookieJar()),
        ),
        throwsStateError,
      );
      expect(platform.views.single.disposed, true);
    },
  );

  test(
    'cookie deletion failure cannot continue to the login website',
    () async {
      final jar = _CookieJar()..failDelete = true;
      jar.cookies.add(
        Cookie(name: 'session', value: 'old', domain: '.quark.cn', path: '/'),
      );
      await expectLater(
        clearCloudDriveLoginCookies(
          providerId: 'quark',
          cookieManager: CookieManager.fromPlatform(jar),
        ),
        throwsStateError,
      );
    },
  );

  test('WebKit removes only the selected provider data records', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final platform = _Platform();
    InAppWebViewPlatform.instance = platform;
    platform.records.addAll([
      for (final name in [
        'alipan.com',
        'aliyundrive.com',
        'pan.quark.cn',
        'bilibili.com',
        'notalipan.com',
        'alipan.com.example.com',
      ])
        WebsiteDataRecord(displayName: name),
    ]);
    await resetSharedCloudDriveLoginSession(
      providerId: 'aliyun',
      cookieManager: CookieManager.fromPlatform(_CookieJar()),
    );
    expect(platform.removedRecords.map((record) => record.displayName), [
      'alipan.com',
      'aliyundrive.com',
    ]);
    expect(platform.views, isEmpty);
  });
}
