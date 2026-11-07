import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_browser.dart';
import 'package:video_player_app/features/cloud_drive/providers/baidu_cloud_drive_provider.dart';
import 'package:video_player_app/services/bilibili/bilibili_web_login_browser.dart';
import 'package:video_player_app/services/network/browser_network_policy.dart';
import 'package:video_player_app/services/network/network_models.dart';

void main() {
  test(
    'retired cloud browser never inspects credentials or calls a transport',
    () async {
      final browser = CloudDriveLoginBrowser(BaiduCloudDriveProvider());
      expect(browser.environment, isNull);
      await expectLater(browser.prepare(), throwsUnsupportedError);
      await expectLater(
        browser.readCookies(webView: Object()),
        throwsUnsupportedError,
      );
      expect(() => browser.credentialFrom(const []), throwsUnsupportedError);
      await expectLater(browser.reload(), throwsUnsupportedError);
      var transportCalls = 0;
      await expectLater(
        readCloudDrivePageCookies(
          cookieUrls: const ['https://example.test/'],
          callDevTools: (_, _) async {
            transportCalls++;
            return {};
          },
        ),
        throwsUnsupportedError,
      );
      expect(transportCalls, 0);
      expect(
        () => cookiesFromDevToolsPayload({'cookies': const []}),
        throwsUnsupportedError,
      );
      await browser.dispose();
    },
  );

  test(
    'retired Bili browser and browser proxy cannot initialize a session',
    () async {
      final browser = BilibiliWebLoginBrowser();
      expect(browser.environment, isNull);
      await expectLater(browser.prepare(), throwsUnsupportedError);
      await expectLater(browser.readCookies(), throwsUnsupportedError);
      await expectLater(browser.reopen(), throwsUnsupportedError);
      await browser.dispose();
      final owner = Object();
      await expectLater(
        BrowserNetworkPolicy.prepare(NetworkScope.other, owner: owner),
        throwsUnsupportedError,
      );
      await expectLater(
        BrowserNetworkPolicy.endpoint(NetworkScope.other),
        throwsUnsupportedError,
      );
      await expectLater(
        BrowserNetworkPolicy.windowsArguments(NetworkScope.other),
        throwsUnsupportedError,
      );
      BrowserNetworkPolicy.release(owner);
    },
  );

  test(
    'active dependency graph contains no embedded WebView backend',
    () async {
      for (final name in ['pubspec.yaml', 'pubspec.lock']) {
        final text = await File(name).readAsString();
        expect(text.contains('flutter_inappwebview'), isFalse, reason: name);
      }
      final retiredDirectory = Directory('lib/features/official_online');
      if (retiredDirectory.existsSync()) {
        expect(retiredDirectory.listSync().whereType<File>(), isEmpty);
      }
    },
  );
}
