import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_route.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_browser_session.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';

class _RetainedSession extends WebMediaBrowserSession {
  _RetainedSession(this.profile) : super(retainOnExit: true);
  final Directory profile;

  @override
  Future<void> prepare() async {
    environment ??= await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: profile.path),
    );
  }
}

Future<void> _until(
  WidgetTester tester,
  FutureOr<bool> Function() condition,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await tester.runAsync(() async => await condition()) == true) return;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  expect(await tester.runAsync(() async => await condition()), isTrue);
}

Finder _icon(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native page, scroll, form values and history survive leaving the browser',
    (tester) async {
      NativeVideoPlayerMediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final preferences = WebMediaBrowserPreferences();
      await preferences.setDesktopMode(true);
      final profile = await tester.runAsync(
        () => Directory.systemTemp.createTemp('fluent_retention_'),
      );
      final session = _RetainedSession(profile!);
      final downloader = YtDlpDownloadService();
      late HttpServer server;
      late StreamSubscription<HttpRequest> requests;
      var loads = 0;
      var responses = 0;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        requests = server.listen((request) async {
          if (request.uri.path == '/one' || request.uri.path == '/two') loads++;
          request.response.headers.contentType = ContentType.html;
          final html =
              '<!doctype html><title>Retention fixture</title>'
              '<input id="draft"><div style="height:6000px">${request.uri.path}</div>';
          request.response.contentLength = utf8.encode(html).length;
          request.response.write(html);
          await request.response.close();
          responses++;
        });
      });
      final origin = 'http://127.0.0.1:${server.port}';
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<YtDlpDownloadService>.value(
            value: downloader,
            child: MaterialApp(
              theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      WebMediaBrowserRoute(
                        session: session,
                        preferences: preferences,
                      ),
                    ),
                    child: const Text('Open browser'),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> enter() async {
          await tester.tap(find.text('Open browser'));
          await tester.pumpAndSettle();
          await _until(
            tester,
            () => tester.widget<IconButton>(_icon('打开网页')).onPressed != null,
          );
        }

        await enter();
        for (final path in ['/one', '/two']) {
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('web-browser-address')),
              )
              .onSubmitted!('$origin$path');
          try {
            await _until(
              tester,
              () async =>
                  await session.controller?.getUrl() ==
                      WebUri('$origin$path') &&
                  await session.controller?.evaluateJavascript(
                        source: 'document.title',
                      ) ==
                      'Retention fixture' &&
                  await session.controller?.evaluateJavascript(
                        source: 'document.readyState',
                      ) ==
                      'complete',
            );
          } catch (_) {
            debugPrint(
              'loads=$loads, responses=$responses, url=${await session.controller?.getUrl()}, '
              'title=${await session.controller?.getTitle()}, '
              'UI=${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList()}',
            );
            debugPrint(
              'document=${await session.controller?.evaluateJavascript(source: 'document.documentElement.outerHTML')}',
            );
            rethrow;
          }
        }
        final controller = session.controller!;
        // Missing/built-in handlers return a null method-channel reply. In
        // upstream Windows 0.6.0 this dereferences nullptr in the JS bridge.
        await controller.evaluateJavascript(
          source: '''
            window.__nullReplies = 0;
            Promise.all([
              window.flutter_inappwebview.callHandler('missingExitHandler'),
              window.flutter_inappwebview.callHandler('onWindowBlur')
            ]).then(() => window.__nullReplies = 2);
            window.__exitMessages = setInterval(() => {
              window.flutter_inappwebview.callHandler('fluentMedia', {});
            }, 25);
            void 0;
          ''',
        );
        await _until(
          tester,
          () async =>
              await controller.evaluateJavascript(
                source: 'window.__nullReplies',
              ) ==
              2,
        );
        await controller.evaluateJavascript(
          source:
              "document.querySelector('#draft').value = 'unfinished input'; window.scrollTo(0, 700); window.__retentionMarker = 'kept';",
        );
        await _until(
          tester,
          () async =>
              (await controller.evaluateJavascript(source: 'window.scrollY')
                  as num) >=
              650,
        );
        final initialLoads = loads;
        await tester.tap(_icon('退出浏览器页面'));
        await _until(
          tester,
          () => find.byType(WebMediaBrowserScreen).evaluate().isEmpty,
        );
        await enter();
        await _until(
          tester,
          () async =>
              await session.controller?.getUrl() == WebUri('$origin/two'),
        );
        final resumed = session.controller!;
        expect(
          await resumed.evaluateJavascript(source: 'window.__retentionMarker'),
          'kept',
        );
        expect(
          await resumed.evaluateJavascript(
            source: "document.querySelector('#draft').value",
          ),
          'unfinished input',
        );
        expect(
          await resumed.evaluateJavascript(source: 'window.scrollY'),
          greaterThanOrEqualTo(650),
        );
        expect(
          loads,
          initialLoads,
          reason: 'Re-entry must not reload the native page',
        );
        expect(await resumed.canGoBack(), isTrue);
        for (var cycle = 0; cycle < 5; cycle++) {
          await tester.tap(_icon('网站首页'));
          await tester.pumpAndSettle();
          await tester.tap(_icon('退出浏览器页面'));
          await tester.pumpAndSettle();
          // Keep processing native JS replies after the outgoing route has
          // removed its handlers, before attaching the retained view again.
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
          await tester.pump();
          expect(find.byType(WebMediaBrowserScreen), findsNothing);
          await enter();
          await _until(
            tester,
            () async =>
                await session.controller?.evaluateJavascript(
                  source: 'window.__retentionMarker',
                ) ==
                'kept',
          );
          expect(loads, initialLoads);
          expect(await session.controller!.canGoBack(), isTrue);
          await tester.tap(find.byTooltip('浏览器菜单'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('返回当前网页'));
          await tester.pumpAndSettle();
        }
        await session.controller!.evaluateJavascript(
          source: 'clearInterval(window.__exitMessages);',
        );
        await session.controller!.goBack();
        await _until(
          tester,
          () async =>
              await session.controller!.getUrl() == WebUri('$origin/one'),
        );
        await _until(
          tester,
          () =>
              preferences.history
                  .map((entry) => entry.url.path)
                  .toSet()
                  .containsAll(['/one', '/two']) &&
              preferences.history.every(
                (entry) => entry.title == 'Retention fixture',
              ),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 300));
        await session.dispose();
        preferences.dispose();
        downloader.dispose();
        await tester.runAsync(() async {
          await requests.cancel();
          await server.close(force: true);
        });
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
