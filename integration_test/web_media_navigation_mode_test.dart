import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_browser_session.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

class _Session extends WebMediaBrowserSession {
  _Session(this.profile);
  final Directory profile;
  @override
  Future<void> prepare() async {
    environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: profile.path),
    );
  }
}

Future<void> _until(
  WidgetTester tester,
  FutureOr<bool> Function() condition,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  expect(await condition(), true, reason: 'Browser operation did not complete');
}

Finder _icon(String tooltip) =>
    find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native WebView back and desktop/mobile switching preserve history and cookies',
    (tester) async {
      NativeVideoPlayerMediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final preferences = WebMediaBrowserPreferences();
      await preferences.setDesktopMode(true);
      final profile = await tester.runAsync(
        () => Directory.systemTemp.createTemp('fluent_navigation_mode_'),
      );
      final session = _Session(profile!);
      final service = YtDlpDownloadService();
      late HttpServer server;
      late StreamSubscription<HttpRequest> requests;
      final agents = <String, String>{};
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        requests = server.listen((request) async {
          final agent = request.headers.value('user-agent') ?? '';
          agents[request.uri.path] = agent;
          request.response.headers.contentType = ContentType.html;
          request.response.headers.set(
            'set-cookie',
            'fluent_mode=retained; Path=/; SameSite=Lax',
          );
          request.response.write(
            '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>${agent.contains('Mobile') ? 'Phone fixture' : 'Desktop fixture'}</title><h1>${request.uri.path}</h1>',
          );
          await request.response.close();
        });
      });
      final origin = 'http://127.0.0.1:${server.port}';
      Future<String> title() async =>
          '${await session.controller?.evaluateJavascript(source: 'document.title')}';
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<YtDlpDownloadService>.value(
            value: service,
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => WebMediaBrowserScreen(
                            session: session,
                            preferences: preferences,
                          ),
                        ),
                      ),
                      child: const Text('Open browser'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open browser'));
        await tester.pumpAndSettle();
        await _until(
          tester,
          () => tester.widget<IconButton>(_icon('打开网页')).onPressed != null,
        );
        Future<void> open(String path) async {
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
                  await title() == 'Desktop fixture',
            );
          } catch (_) {
            debugPrint(
              'fixture: requests=${agents.keys.toList()}, url=${await session.controller?.getUrl()}, title=${await session.controller?.getTitle()}, '
              'UI=${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList()}',
            );
            rethrow;
          }
        }

        await open('/one');
        await open('/two');
        final controller = session.controller!;
        Future<void> toggle() async {
          await tester.tap(_icon('浏览器菜单'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(CheckedPopupMenuItem<String>));
          await tester.pump(const Duration(milliseconds: 300));
        }

        await toggle();
        await _until(tester, () async => await title() == 'Phone fixture');
        expect(agents['/two'], contains('Mobile'));
        expect(await controller.canGoBack(), true);
        expect(await controller.getUrl(), WebUri('$origin/two'));
        expect(
          '${await controller.evaluateJavascript(source: 'document.cookie')}',
          contains('fluent_mode=retained'),
        );
        expect(
          tester.getSize(find.byType(InAppWebView)).width,
          lessThanOrEqualTo(480),
        );
        await toggle();
        await _until(tester, () async => await title() == 'Desktop fixture');
        expect(agents['/two'], isNot(contains('Mobile')));
        expect(identical(session.controller, controller), true);
        await controller.evaluateJavascript(
          source:
              "window.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));",
        );
        await _until(
          tester,
          () async => await controller.getUrl() == WebUri('$origin/one'),
        );
        expect(find.byType(WebMediaBrowserScreen), findsOneWidget);
        expect(await controller.canGoBack(), false);
        await tester.binding.handlePopRoute();
        await _until(
          tester,
          () => find.byType(WebMediaBrowserScreen).evaluate().isEmpty,
        );
        expect(find.text('Open browser'), findsOneWidget);
        expect(find.byType(WebMediaBrowserScreen), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() async {
          await requests.cancel();
          await server.close(force: true);
        });
        await session.dispose();
        preferences.dispose();
        service.dispose();
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
