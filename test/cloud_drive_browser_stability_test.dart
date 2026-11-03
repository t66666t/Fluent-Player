import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/cloud_drive/auth/cloud_drive_login_browser.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/presentation/cloud_drive_login_screen.dart';
import 'support/cloud_drive_fixture.dart';
import 'support/embedded_browser_platform.dart';

class _Login extends CloudDriveLoginClient {
  _Login({this.preparation});
  final Future<void>? preparation;
  bool disposed = false;
  int cookieReads = 0;
  @override
  WebViewEnvironment? get environment => null;
  @override
  Future<void> prepare() async => preparation;
  @override
  Future<void> reload() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<List<CloudDriveCookie>> readCookies({
    InAppWebViewController? webView,
  }) async {
    cookieReads++;
    return [];
  }

  @override
  CloudDriveCredential? credentialFrom(List<CloudDriveCookie> cookies) => null;
}

void main() {
  testWidgets(
    'preparation and missing native view block old-session detection',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final platform = BrowserTestPlatform();
      InAppWebViewPlatform.instance = platform;
      final provider = FixtureCloudProvider('quark', {});
      final runtime = await cloudRuntime([provider]);
      addTearDown(runtime.shutdown);
      final prepared = Completer<void>();
      final login = _Login(preparation: prepared.future);
      await tester.pumpWidget(
        MaterialApp(
          home: CloudDriveLoginScreen(
            provider: provider,
            accounts: runtime.accounts,
            browser: login,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('检测登录状态'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(login.cookieReads, 0);
      expect(platform.controllers, isEmpty);

      prepared.complete();
      await tester.pumpAndSettle();
      // The immediate check after prepare must also wait for the native page.
      expect(login.cookieReads, 0);
      await tester.tap(find.text('检测登录状态'));
      await tester.pump();
      expect(login.cookieReads, 1);

      final controller = platform.controllers.single;
      controller.callbacks.onRenderProcessGone!(
        controller.api,
        RenderProcessGoneDetail(didCrash: true),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(login.cookieReads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  for (final providerId in ['quark', 'baidu']) {
    testWidgets(
      '$providerId login uses pinch zoom and recreates an exited native renderer',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final platform = BrowserTestPlatform();
        InAppWebViewPlatform.instance = platform;
        final provider = FixtureCloudProvider(providerId, {});
        final runtime = await cloudRuntime([provider]);
        addTearDown(runtime.shutdown);
        final login = _Login();
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: CloudDriveLoginScreen(
              provider: provider,
              accounts: runtime.accounts,
              browser: login,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final old = platform.controllers.single;
        expect(platform.params.initialSettings!.supportZoom, true);
        expect(platform.params.initialSettings!.builtInZoomControls, true);
        expect(platform.params.initialSettings!.useWideViewPort, true);
        expect(platform.params.initialSettings!.incognito, false);
        expect(
          platform.params.initialUserScripts!.any(
            (script) => script.groupName == 'fluent-browser-zoom',
          ),
          true,
        );
        expect(find.byTooltip('检测登录状态').hitTestable(), findsOneWidget);
        old.callbacks.onRenderProcessGone!(
          old.api,
          RenderProcessGoneDetail(didCrash: true),
        );
        await tester.pumpAndSettle();
        expect(find.byType(InAppWebView), findsNothing);
        await tester.tap(find.text('重新打开网页'));
        await tester.pumpAndSettle();
        expect(platform.controllers, hasLength(2));
        expect(login.disposed, false);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(login.disposed, true);
      },
    );
  }
}
