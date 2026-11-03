import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../network/browser_network_policy.dart';
import '../network/network_http.dart';
import 'bilibili_cookie_store.dart';
import '../browser/linux_chromium_browser.dart';

/// Owns the login browser's network policy and isolated Windows profile.
class BilibiliWebLoginBrowser {
  WebViewEnvironment? environment;
  Directory? _temporaryProfile;
  LinuxChromiumBrowser? _linuxBrowser;
  bool _disposed = false;
  Future<void>? _preparing;

  CookieManager get _manager =>
      CookieManager.instance(webViewEnvironment: environment);

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
    await BrowserNetworkPolicy.prepare(NetworkScope.bilibili, owner: this);
    if (_disposed) return;
    if (Platform.isLinux) {
      _temporaryProfile = await Directory.systemTemp.createTemp(
        'fluent_bilibili_login_',
      );
      _linuxBrowser = LinuxChromiumBrowser(
        _temporaryProfile!,
        proxyEndpoint: () =>
            BrowserNetworkPolicy.endpoint(NetworkScope.bilibili),
      );
      await reopen();
      if (_disposed) await _cleanup();
    } else if (Platform.isWindows) {
      if (await WebViewEnvironment.getAvailableVersion() == null) {
        throw StateError('WebView2 Runtime unavailable');
      }
      final arguments = await BrowserNetworkPolicy.windowsArguments(
        NetworkScope.bilibili,
      );
      if (_disposed) return;
      _temporaryProfile = await Directory.systemTemp.createTemp(
        'fluent_bilibili_login_',
      );
      environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: _temporaryProfile!.path,
          additionalBrowserArguments: arguments,
        ),
      );
      if (_disposed) await _cleanup();
    } else {
      // A fresh flow must not silently re-import the account after logout.
      await _clearAccountCookies();
    }
  }

  Future<void> reopen() async {
    await _linuxBrowser?.open(Uri.https('passport.bilibili.com', '/login'), '');
  }

  Future<Map<String, String>> readCookies() async {
    final cookies = <String, String>{};
    for (final host in ['www', 'passport', 'api']) {
      if (Platform.isLinux) {
        final browser = _linuxBrowser;
        if (browser == null || !browser.isOpen) {
          throw StateError('Login browser closed');
        }
        for (final cookie in await browser.cookiesFor(
          Uri.https('$host.bilibili.com', '/'),
        )) {
          final name = cookie['name'];
          final value = cookie['value'];
          if (name is String &&
              value is String &&
              value.isNotEmpty &&
              BilibiliCookieStore.sessionCookieNames.contains(name)) {
            cookies.putIfAbsent(name, () => value);
          }
        }
        continue;
      }
      final values = await _manager
          .getCookies(url: WebUri('https://$host.bilibili.com/'))
          .timeout(const Duration(seconds: 5));
      for (final cookie in values) {
        if (BilibiliCookieStore.sessionCookieNames.contains(cookie.name) &&
            cookie.value.isNotEmpty) {
          cookies.putIfAbsent(cookie.name, () => cookie.value);
        }
      }
    }
    return cookies;
  }

  Future<void> _clearAccountCookies() async {
    for (final host in ['www', 'passport', 'api']) {
      final url = WebUri('https://$host.bilibili.com/');
      final cookies = await _manager
          .getCookies(url: url)
          .timeout(const Duration(seconds: 5));
      for (final cookie in cookies) {
        if (const {
          'SESSDATA',
          'bili_jct',
          'DedeUserID',
          'DedeUserID__ckMd5',
          'sid',
        }.contains(cookie.name)) {
          await _manager.deleteCookie(
            url: url,
            name: cookie.name,
            domain: cookie.domain,
            path: cookie.path ?? '/',
          );
        }
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    BrowserNetworkPolicy.release(this);
    try {
      await _preparing;
    } catch (_) {}
    await _cleanup();
  }

  Future<void> _cleanup() async {
    try {
      if (Platform.isWindows || Platform.isLinux) {
        await _linuxBrowser?.dispose();
        _linuxBrowser = null;
        await environment?.dispose();
        environment = null;
        final profile = _temporaryProfile;
        // The exact unique path returned by createTemp, never a shared folder.
        if (profile != null && await profile.exists()) {
          await profile.delete(recursive: true);
        }
      } else {
        await _clearAccountCookies();
      }
    } catch (_) {
      // Native teardown may briefly hold a profile/cookie-store handle.
    }
  }
}
