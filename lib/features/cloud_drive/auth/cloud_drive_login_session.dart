import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

List<String> cloudDriveLoginDomains(String providerId) => switch (providerId) {
  'quark' => const ['quark.cn'],
  'uc' => const ['uc.cn'],
  'aliyun' => const ['alipan.com', 'aliyundrive.com'],
  _ => const ['baidu.com'],
};

List<String> cloudDriveLoginCookieUrls(String providerId) =>
    switch (providerId) {
      'quark' => const [
        'https://pan.quark.cn/',
        'https://pan.quark.cn/account/info',
        'https://drive-pc.quark.cn/1/clouddrive/',
        'https://drive.quark.cn/1/clouddrive/',
      ],
      'uc' => const [
        'https://drive.uc.cn/',
        'https://drive.uc.cn/account/info',
        'https://pc-api.uc.cn/1/clouddrive/',
      ],
      'aliyun' => const [
        'https://www.alipan.com/',
        'https://api.alipan.com/',
        'https://auth.alipan.com/',
        'https://www.aliyundrive.com/',
      ],
      _ => const [
        'https://pan.baidu.com/',
        'https://passport.baidu.com/',
        'https://www.baidu.com/',
        'https://pcs.baidu.com/',
      ],
    };

bool _belongsTo(String domain, List<String> roots) {
  final host = domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
  return roots.any((root) => host == root || host.endsWith('.$root'));
}

/// Android and WebKit share their default store across login views. Reset only
/// this provider before displaying its website or polling for a session. Saved
/// app credentials live separately and must not be signed out by this reset.
Future<void> resetSharedCloudDriveLoginSession({
  required String providerId,
  required CookieManager cookieManager,
}) async {
  await clearCloudDriveLoginCookies(
    providerId: providerId,
    cookieManager: cookieManager,
  );
  final roots = cloudDriveLoginDomains(providerId);
  if (defaultTargetPlatform == TargetPlatform.android) {
    final hosts = switch (providerId) {
      'quark' => const ['pan.quark.cn'],
      'uc' => const ['drive.uc.cn'],
      'aliyun' => const [
        'alipan.com',
        'www.alipan.com',
        'auth.alipan.com',
        'aliyundrive.com',
        'www.aliyundrive.com',
      ],
      _ => const ['pan.baidu.com', 'passport.baidu.com'],
    };
    for (final host in hosts) {
      await _clearAndroidLoginStorage(WebUri('https://$host/'));
    }
  } else if (defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS) {
    final storage = WebStorageManager.instance();
    final records = await storage
        .fetchDataRecords(dataTypes: WebsiteDataType.ALL)
        .timeout(const Duration(seconds: 5));
    final relevant = records
        .where((record) => _belongsTo(record.displayName ?? '', roots))
        .toList();
    if (relevant.isNotEmpty) {
      await storage
          .removeDataFor(dataTypes: WebsiteDataType.ALL, dataRecords: relevant)
          .timeout(const Duration(seconds: 5));
    }
  }
}

@visibleForTesting
Future<void> clearCloudDriveLoginCookies({
  required String providerId,
  required CookieManager cookieManager,
}) async {
  final roots = cloudDriveLoginDomains(providerId);
  final urls = {
    ...cloudDriveLoginCookieUrls(providerId),
    for (final root in roots) 'https://$root/',
    if (providerId == 'quark') 'https://uop.quark.cn/',
    if (providerId == 'uc') 'https://passport.uc.cn/',
    if (providerId == 'baidu') 'https://pan.baidu.com/disk/main',
    if (providerId == 'aliyun') 'https://www.alipan.com/drive/file/all',
  };
  final deleted = <String>{};
  for (final value in urls) {
    final url = WebUri(value);
    final cookies = await cookieManager
        .getCookies(url: url)
        .timeout(const Duration(seconds: 5));
    for (final cookie in cookies) {
      if (cookie.domain != null && !_belongsTo(cookie.domain!, roots)) continue;
      // Older Android WebViews return only name/value. Deleting a host-only
      // cookie then leaves .quark.cn/.baidu.com sessions intact. Try each legal
      // parent domain and path when native metadata is unavailable.
      final domains = <String?>{cookie.domain};
      if (cookie.domain == null) {
        var host = url.host;
        while (_belongsTo(host, roots)) {
          domains.add(host);
          host = host.substring(host.indexOf('.') + 1);
        }
      }
      final paths = <String>{cookie.path ?? '/'};
      if (cookie.path == null) {
        var path = '';
        for (final segment in url.pathSegments.where(
          (part) => part.isNotEmpty,
        )) {
          path += '/$segment';
          paths.addAll([path, '$path/']);
        }
      }
      for (final domain in domains) {
        for (final path in paths) {
          if (!deleted.add('${url.host}|${cookie.name}|$domain|$path')) {
            continue;
          }
          final removed = await cookieManager
              .deleteCookie(
                url: url,
                name: cookie.name,
                domain: domain,
                path: path,
              )
              .timeout(const Duration(seconds: 5));
          if (!removed) throw StateError('无法清理网盘网页登录状态');
        }
      }
    }
  }
}

/// WebStorage.deleteOrigin on Android covers WebSQL/app cache, not localStorage
/// (where Alipan keeps its token). Load our own empty document at that origin
/// and clear storage before any official page script or request can run. This
/// also works without DOCUMENT_START_SCRIPT support on older WebViews.
Future<void> _clearAndroidLoginStorage(WebUri origin) async {
  final loaded = Completer<InAppWebViewController>();
  var active = true;
  final view = HeadlessInAppWebView(
    initialData: InAppWebViewInitialData(
      data: '<!doctype html><html><head></head><body></body></html>',
      baseUrl: origin,
    ),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      incognito: false,
      sharedCookiesEnabled: false,
      blockNetworkLoads: true,
    ),
    onLoadStop: (controller, _) {
      if (active && !loaded.isCompleted) loaded.complete(controller);
    },
  );
  try {
    await view.run().timeout(const Duration(seconds: 5));
    final controller = await loaded.future.timeout(const Duration(seconds: 5));
    final cleared = await controller
        .evaluateJavascript(
          source:
              '''(() => {
            if (location.origin !== ${jsonEncode(origin.origin)}) return false;
            localStorage.clear();
            sessionStorage.clear();
            return localStorage.length === 0 && sessionStorage.length === 0;
          })()''',
        )
        .timeout(const Duration(seconds: 5));
    if (cleared != true) throw StateError('无法清理网盘网页存储');
  } finally {
    active = false;
    await view.dispose();
  }
}
