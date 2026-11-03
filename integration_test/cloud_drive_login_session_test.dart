import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Cookie;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Also imported by the standalone Android verification app.
// ignore: avoid_relative_lib_imports
import '../lib/features/cloud_drive/auth/cloud_drive_login_session.dart';

/// Run with a separate test application ID. These tests intentionally reset
/// the WebView login store, and never use real account credentials or servers.
Future<dynamic> _atOrigin(String host, String script) async {
  final loaded = Completer<InAppWebViewController>();
  var active = true;
  final view = HeadlessInAppWebView(
    initialData: InAppWebViewInitialData(
      data: '<!doctype html><html><body></body></html>',
      baseUrl: WebUri('https://$host/'),
    ),
    initialSettings: InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      blockNetworkLoads: true,
    ),
    onLoadStop: (controller, _) {
      if (active && !loaded.isCompleted) loaded.complete(controller);
    },
  );
  try {
    await view.run();
    final controller = await loaded.future.timeout(const Duration(seconds: 10));
    return await controller.evaluateJavascript(source: script);
  } finally {
    active = false;
    await view.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Android fresh logins clear native cookies and Alipan tokens without clearing other sites',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.runAsync(() async {
        final manager = CookieManager.instance();
        final unrelatedUrl = WebUri('https://www.bilibili.com/');
        expect(
          await manager.setCookie(
            url: unrelatedUrl,
            name: 'cloud_login_unrelated',
            value: 'keep',
            domain: '.bilibili.com',
            isHttpOnly: true,
            isSecure: true,
          ),
          true,
        );
        await _atOrigin(
          'www.bilibili.com',
          "localStorage.setItem('cloud-login-test', 'keep'); true",
        );

        for (final providerId in ['baidu', 'quark', 'uc', 'aliyun']) {
          final urls = cloudDriveLoginCookieUrls(providerId);
          final root = cloudDriveLoginDomains(providerId).first;
          final loginUrl = WebUri(urls.first);
          for (final old in ['first-account', 'second-account']) {
            expect(
              await manager.setCookie(
                url: loginUrl,
                name: 'cloud_login_old_root',
                value: old,
                domain: '.$root',
                isHttpOnly: true,
                isSecure: true,
              ),
              true,
            );
            expect(
              await manager.setCookie(
                url: loginUrl,
                name: 'cloud_login_old_host',
                value: old,
                isHttpOnly: true,
                isSecure: true,
              ),
              true,
            );
            // Exercise API cookies with non-root paths too.
            final apiUrl = WebUri(urls.last);
            expect(
              await manager.setCookie(
                url: apiUrl,
                name: 'cloud_login_old_api',
                value: old,
                domain: apiUrl.host,
                path: apiUrl.path,
                isHttpOnly: true,
                isSecure: true,
              ),
              true,
            );
            expect(
              (await manager.getCookies(
                url: loginUrl,
              )).any((cookie) => cookie.value == old),
              true,
            );
            if (providerId == 'aliyun') {
              for (final host in ['www.alipan.com', 'www.aliyundrive.com']) {
                expect(
                  await _atOrigin(
                    host,
                    "localStorage.setItem('token', ${jsonEncode(old)}); localStorage.getItem('token')",
                  ),
                  old,
                );
              }
            }

            await resetSharedCloudDriveLoginSession(
              providerId: providerId,
              cookieManager: manager,
            );
            for (final value in urls) {
              expect(
                (await manager.getCookies(url: WebUri(value))).where(
                  (cookie) => cookie.name.startsWith('cloud_login_old_'),
                ),
                isEmpty,
                reason: '$providerId must not reuse $old at $value',
              );
            }
            if (providerId == 'aliyun') {
              for (final host in ['www.alipan.com', 'www.aliyundrive.com']) {
                expect(
                  await _atOrigin(host, "localStorage.getItem('token')"),
                  isNull,
                );
              }
            }
            expect(
              (await manager.getCookies(url: unrelatedUrl))
                  .singleWhere(
                    (cookie) => cookie.name == 'cloud_login_unrelated',
                  )
                  .value,
              'keep',
            );
            expect(
              await _atOrigin(
                'www.bilibili.com',
                "localStorage.getItem('cloud-login-test')",
              ),
              'keep',
            );
          }
        }
      });
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
