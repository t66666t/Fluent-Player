import 'dart:async';
import 'dart:io' hide Cookie;

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../services/browser/linux_chromium_browser.dart';
import '../../../services/network/browser_network_policy.dart';
import '../../../services/network/network_http.dart';
import '../../../services/storage_runtime_registry.dart';
import '../models/cloud_drive_models.dart';
import '../providers/cloud_drive_provider.dart';
import 'aliyun_web_session.dart';
import 'cloud_drive_login_session.dart';

/// Set before the first navigation, including redirects through login hosts.
const cloudDriveLoginDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

/// The login page only needs these operations. Tests substitute a fake.
abstract class CloudDriveLoginClient {
  Future<void> prepare();

  /// [webView] is the page the user actually logged in on. Windows must read
  /// that page; the profile-wide cookie API can miss its session.
  Future<List<CloudDriveCookie>> readCookies({InAppWebViewController? webView});
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies);
  Future<void> reload();
  Future<void> dispose();
  WebViewEnvironment? get environment;
}

/// One isolated official login page. Cookies are read from the browser cookie
/// API, which can see HttpOnly values that document.cookie cannot.
class CloudDriveLoginBrowser implements CloudDriveLoginClient {
  CloudDriveLoginBrowser(this.provider);

  final CloudDriveProvider provider;
  @override
  WebViewEnvironment? environment;
  Directory? _profile;
  LinuxChromiumBrowser? _linuxBrowser;
  var _disposed = false;
  Future<void>? _preparing;
  Map<String, String>? _tokenSecrets;

  CookieManager get _manager =>
      CookieManager.instance(webViewEnvironment: environment);

  @override
  Future<void> prepare() => _preparing ??= _prepare().catchError((
    Object error,
    StackTrace stack,
  ) async {
    await _cleanup();
    BrowserNetworkPolicy.release(this);
    _preparing = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _prepare() async {
    await BrowserNetworkPolicy.prepare(NetworkScope.cloudDrive, owner: this);
    if (_disposed) return;
    if (Platform.isLinux) {
      _profile = await Directory.systemTemp.createTemp(
        'fluent_cloud_drive_login_',
      );
      await _ownProfile(_profile!);
      _linuxBrowser = LinuxChromiumBrowser(
        _profile!,
        proxyEndpoint: () =>
            BrowserNetworkPolicy.endpoint(NetworkScope.cloudDrive),
      );
      await _linuxBrowser!.start();
      await _linuxBrowser!.command('Network.setUserAgentOverride', {
        'userAgent': cloudDriveLoginDesktopUserAgent,
        'platform': 'Win32',
      });
      await _linuxBrowser!.open(provider.loginUri, '');
      if (_disposed) await _cleanup();
      return;
    }
    if (Platform.isWindows) {
      if (await WebViewEnvironment.getAvailableVersion() == null) {
        throw StateError('WebView2 Runtime unavailable');
      }
      final arguments = await BrowserNetworkPolicy.windowsArguments(
        NetworkScope.cloudDrive,
      );
      if (_disposed) return;
      _profile = await Directory.systemTemp.createTemp(
        'fluent_cloud_drive_login_',
      );
      await _ownProfile(_profile!);
      environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: _profile!.path,
          additionalBrowserArguments: arguments,
        ),
      );
      if (_disposed) await _cleanup();
    } else {
      await resetSharedCloudDriveLoginSession(
        providerId: provider.id,
        cookieManager: _manager,
      );
    }
  }

  @override
  Future<void> reload() async {
    if (Platform.isLinux) {
      await _linuxBrowser?.open(provider.loginUri, '');
    }
  }

  List<String> get _cookieUrls => cloudDriveLoginCookieUrls(provider.id);

  @override
  Future<List<CloudDriveCookie>> readCookies({
    InAppWebViewController? webView,
  }) async {
    if (provider.id == 'aliyun') {
      _tokenSecrets = null;
      Object? payload;
      try {
        if (Platform.isLinux) {
          payload = await _linuxBrowser?.evaluate(aliyunSessionCaptureScript);
        } else if (webView != null) {
          payload = await webView
              .evaluateJavascript(source: aliyunSessionCaptureScript)
              .timeout(const Duration(seconds: 5));
        }
        _tokenSecrets = aliyunSecretsFromBrowser(payload);
      } catch (_) {
        // A page in the middle of navigation is retried by the login poll.
      }
      return const [];
    }
    final cookies = <CloudDriveCookie>[];
    if (webView != null && Platform.isWindows) {
      cookies.addAll(await _readWindowsPageCookies(webView));
    }
    if (Platform.isLinux) {
      final browser = _linuxBrowser;
      if (browser == null || !browser.isOpen) {
        throw StateError('登录浏览器已关闭');
      }
      for (final host in _cookieUrls) {
        for (final raw in await browser.cookiesFor(Uri.parse(host))) {
          final cookie = _fromMap(raw);
          if (cookie != null) cookies.add(cookie);
        }
      }
    } else if (!Platform.isWindows ||
        _uniqueRelevant(cookies).isEmpty ||
        (const {'quark', 'uc'}.contains(provider.id) &&
            !cookies.any(
              (cookie) => cookie.name == '__pus' || cookie.name == '__puus',
            ))) {
      for (final host in _cookieUrls) {
        final uri = Uri.parse(host);
        List<Cookie> values;
        try {
          values = await _manager
              .getCookies(url: WebUri(host), webViewController: webView)
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          // A cookie API unavailable on one host must not discard the
          // session already read from the visible login page or other hosts.
          continue;
        }
        for (final cookie in values) {
          if (cookie.name.isEmpty || cookie.value.isEmpty) continue;
          cookies.add(
            CloudDriveCookie(
              name: cookie.name,
              value: cookie.value,
              domain: (cookie.domain ?? uri.host).toString(),
              path: cookie.path ?? '/',
              secure: cookie.isSecure ?? true,
            ),
          );
        }
      }
    }
    return _uniqueRelevant(cookies);
  }

  /// The visible WebView owns the login. Asking the hidden environment
  /// WebView misses Baidu's partitioned session cookies.
  Future<List<CloudDriveCookie>> _readWindowsPageCookies(
    InAppWebViewController webView,
  ) => readCloudDrivePageCookies(
    cookieUrls: _cookieUrls,
    callDevTools: (method, parameters) => webView.callDevToolsProtocolMethod(
      methodName: method,
      parameters: parameters,
    ),
  );

  @override
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies) {
    final relevant = _uniqueRelevant(cookies);
    if (provider.id == 'aliyun') {
      final secrets = _tokenSecrets;
      return secrets == null
          ? null
          : CloudDriveCredential(
              cookies: relevant,
              secrets: secrets,
              capturedAt: DateTime.now().toUtc(),
            );
    }
    if (relevant.isEmpty) return null;
    final normalized = provider.id == 'baidu'
        ? _withBaiduSessionAliases(relevant)
        : relevant;
    if (provider.id == 'baidu' &&
        !normalized.any(
          (cookie) => cookie.name == 'BDUSS' && cookie.value.isNotEmpty,
        )) {
      return null;
    }
    return CloudDriveCredential(
      cookies: normalized,
      capturedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _cleanup();
    BrowserNetworkPolicy.release(this);
  }

  Future<void> _cleanup() async {
    final browser = _linuxBrowser;
    _linuxBrowser = null;
    await browser?.dispose();
    final profile = _profile;
    _profile = null;
    final previousEnvironment = environment;
    environment = null;
    try {
      await previousEnvironment?.dispose();
    } catch (_) {
      // The native view may already have released the environment on exit.
    }
    if (profile != null) {
      StorageRuntimeRegistry.deactivate(profile.path);
      if (await profile.exists()) {
        try {
          await profile.delete(recursive: true);
          await StorageRuntimeRegistry.forget(profile.path);
        } catch (_) {
          // The profile belongs only to this login attempt. A locked file
          // must not clear any other browser. The marker lets a later audit
          // remove the residue after the lease expires.
        }
      } else {
        await StorageRuntimeRegistry.forget(profile.path);
      }
    }
  }

  Future<void> _ownProfile(Directory profile) async {
    await markOwnedTemporaryDirectory(profile, marker: 'cloud-drive-login/1');
    StorageRuntimeRegistry.activate(profile.path);
    await StorageRuntimeRegistry.remember(
      kind: 'cloudLogin',
      path: profile.path,
    );
  }

  List<CloudDriveCookie> _uniqueRelevant(List<CloudDriveCookie> cookies) {
    final seen = <String>{};
    final kept = <CloudDriveCookie>[];
    for (final cookie in cookies) {
      if (cookie.name.isEmpty || cookie.value.isEmpty) continue;
      final domain = cookie.domain.toLowerCase().replaceFirst(
        RegExp(r'^\.'),
        '',
      );
      final roots = cloudDriveLoginDomains(provider.id);
      if (!roots.any((root) => domain == root || domain.endsWith('.$root'))) {
        continue;
      }
      if (seen.add('$domain|${cookie.name}|${cookie.path}')) kept.add(cookie);
    }
    return kept;
  }
}

/// Both APIs must be queried on the page the user logged in on. A non-empty
/// Storage response can contain only tracking cookies, or an older session;
/// it is not evidence that Network.getCookies has nothing more to contribute.
Future<List<CloudDriveCookie>> readCloudDrivePageCookies({
  required List<String> cookieUrls,
  required Future<dynamic> Function(
    String method,
    Map<String, dynamic> parameters,
  )
  callDevTools,
}) async {
  Future<List<CloudDriveCookie>> read(
    String method,
    Map<String, dynamic> parameters,
  ) async {
    try {
      return cookiesFromDevToolsPayload(
        await callDevTools(
          method,
          parameters,
        ).timeout(const Duration(seconds: 5)),
      );
    } catch (_) {
      return const [];
    }
  }

  final results = await Future.wait([
    read('Storage.getCookies', const {}),
    read('Network.getCookies', {'urls': cookieUrls}),
  ]);
  // Prefer cookies applicable to the actual endpoints if the APIs disagree.
  return [...results[1], ...results[0]];
}

/// Parses a DevTools `Storage.getCookies` or `Network.getCookies` result.
List<CloudDriveCookie> cookiesFromDevToolsPayload(Object? data) {
  if (data is! Map) return const [];
  final raw = data['cookies'];
  if (raw is! List) return const [];
  final cookies = <CloudDriveCookie>[];
  for (final item in raw.whereType<Map>()) {
    final name = item['name']?.toString() ?? '';
    final value = item['value']?.toString() ?? '';
    if (name.isEmpty || value.isEmpty) continue;
    final path = item['path']?.toString();
    cookies.add(
      CloudDriveCookie(
        name: name,
        value: value,
        domain: item['domain']?.toString() ?? '',
        path: path == null || path.isEmpty ? '/' : path,
        secure: item['secure'] != false && item['isSecure'] != false,
      ),
    );
  }
  return cookies;
}

/// Current Baidu pages often set only `BDUSS_BFESS`. The file APIs still
/// look for the cookie name `BDUSS`, so the saved jar carries both.
List<CloudDriveCookie> _withBaiduSessionAliases(
  List<CloudDriveCookie> cookies,
) {
  final names = cookies.map((cookie) => cookie.name).toSet();
  final aliases = <CloudDriveCookie>[];
  void mirror(String from, String to) {
    if (names.contains(to)) return;
    for (final cookie in cookies) {
      if (cookie.name != from || cookie.value.isEmpty) continue;
      aliases.add(
        CloudDriveCookie(
          name: to,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path,
          secure: cookie.secure,
        ),
      );
      names.add(to);
      break;
    }
  }

  mirror('BDUSS_BFESS', 'BDUSS');
  mirror('STOKEN_BFESS', 'STOKEN');
  return [...cookies, ...aliases];
}

CloudDriveCookie? _fromMap(Map<String, dynamic> raw) {
  final name = raw['name'];
  final value = raw['value'];
  if (name is! String || value is! String || name.isEmpty || value.isEmpty) {
    return null;
  }
  final domain = raw['domain'];
  return CloudDriveCookie(
    name: name,
    value: value,
    domain: domain is String && domain.isNotEmpty ? domain : '',
    path: raw['path'] is String ? raw['path'] as String : '/',
    secure: raw['secure'] != false,
  );
}

String cloudDriveLoginFailureMessage() {
  if (kIsWeb) return '当前平台不能打开网盘登录页';
  if (Platform.isLinux) {
    return 'Linux 网页登录需要安装 Chromium 或 Google Chrome，安装后点刷新网页';
  }
  if (Platform.isWindows) {
    return '无法启动 WebView2，请安装 Microsoft Edge WebView2 Runtime 后重试';
  }
  return '无法启动系统网页组件，请重试';
}
