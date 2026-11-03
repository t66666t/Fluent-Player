import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_browser_session.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

class _IsolatedSession extends WebMediaBrowserSession {
  _IsolatedSession(this.directory);
  final Directory directory;
  @override
  Future<void> prepare() async {
    environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: directory.path),
    );
  }
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  expect(condition(), isTrue);
}

Finder _icon(String tooltip) => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == tooltip,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real WebView preserves history on home, manages native cookies and exits its route',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      NativeVideoPlayerMediaKit.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp(
        'fluent_browser_home_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final page = Uri.parse('http://127.0.0.1:${server.port}/one');
      final session = _IsolatedSession(Directory('${directory.path}/profile'));
      final downloader = YtDlpDownloadService();
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.headers.add(
          'set-cookie',
          'fluent_home_fixture=root-secret; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400',
        );
        request.response.headers.add(
          'set-cookie',
          'fluent_private_fixture=private-secret; Path=/private; HttpOnly; Max-Age=86400',
        );
        request.response.write(
          '<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1"><title>本地浏览器测试</title><h1>${request.uri.path}</h1><a href="/two">第二页</a>',
        );
        await request.response.close();
      });
      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('native-home-preview'),
            child: ChangeNotifierProvider<YtDlpDownloadService>.value(
              value: downloader,
              child: MaterialApp(
                theme: ThemeData.dark(useMaterial3: true).copyWith(
                  colorScheme: const ColorScheme.dark(
                    primary: Color(0xFF6EA8FF),
                  ),
                ),
                home: Builder(
                  builder: (context) => Scaffold(
                    body: Center(
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) =>
                                WebMediaBrowserScreen(session: session),
                          ),
                        ),
                        child: const Text('媒体库'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('媒体库'));
        await tester.pumpAndSettle();
        await _until(
          tester,
          () => tester.widget<IconButton>(_icon('打开网页')).onPressed != null,
        );
        expect(find.text('添加网站'), findsOneWidget);
        expect(find.text('YouTube'), findsNothing);
        expect(find.text('哔哩哔哩'), findsNothing);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('native-home-preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final screenshots = Directory('temp_web_browser_ui');
          await screenshots.create(recursive: true);
          await File(
            '${screenshots.path}/native-home-desktop.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        Future<void> open(Uri uri) async {
          await tester.enterText(
            find.byKey(const ValueKey('web-browser-address')),
            uri.toString(),
          );
          // The Windows native view can hold TestTextInput focus after the
          // first navigation. Submit using the real address field callback.
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('web-browser-address')),
              )
              .onSubmitted!(uri.toString());
          await _until(
            tester,
            () =>
                find.byType(InAppWebView).evaluate().isNotEmpty &&
                session.controller != null,
          );
          var loaded = false;
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (!loaded && DateTime.now().isBefore(deadline)) {
            loaded =
                await tester.runAsync(
                  () async =>
                      await session.controller!.getUrl() ==
                          WebUri(uri.toString()) &&
                      await session.controller!.evaluateJavascript(
                            source: 'document.readyState',
                          ) ==
                          'complete',
                ) ??
                false;
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
          }
          expect(
            loaded,
            isTrue,
            reason:
                'Local page must finish its first navigation before opening the next page',
          );
        }

        await open(page);
        await open(page.resolve('/two'));
        await _until(
          tester,
          () => tester.widget<IconButton>(_icon('上一页')).onPressed != null,
        );
        final controller = session.controller;
        await tester.tap(find.byTooltip('网站首页'));
        await tester.pumpAndSettle();
        expect(find.text('添加网站'), findsOneWidget);
        expect(find.text('YouTube'), findsNothing);
        expect(find.byType(InAppWebView), findsNothing);
        await tester.tap(find.byTooltip('浏览器菜单'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('返回当前网页'));
        await tester.pumpAndSettle();
        expect(identical(session.controller, controller), isTrue);
        expect(
          await session.controller!.getUrl(),
          WebUri(page.resolve('/two').toString()),
        );
        await tester.tap(find.byTooltip('Cookie 管理'));
        await _until(
          tester,
          () => find.text('fluent_home_fixture').evaluate().isNotEmpty,
        );
        expect(find.text('root-secret'), findsNothing);
        final all = await session.cookies.all();
        expect(
          all!.map((cookie) => cookie.name),
          contains('fluent_private_fixture'),
        );
        expect(
          all
              .singleWhere((cookie) => cookie.name == 'fluent_home_fixture')
              .expiresDate,
          greaterThan(DateTime.now().millisecondsSinceEpoch),
        );
        await tester.tap(find.text('清除网站 Cookie'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清除'));
        await _until(
          tester,
          () => find.text('已清除网站 Cookie').evaluate().isNotEmpty,
        );
        expect(await session.cookies.all(), isEmpty);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(tester.widget<IconButton>(_icon('上一页')).onPressed, isNotNull);
        await tester.tap(find.byTooltip('退出浏览器页面'));
        await tester.pumpAndSettle();
        expect(find.byType(WebMediaBrowserScreen), findsNothing);
        expect(find.text('媒体库'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await server.close(force: true);
        await session.dispose();
        downloader.dispose();
        // WebView2 may finish flushing the owned temporary profile asynchronously.
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          /* Temporary test profile only. */
        }
      }
    },
    skip: !Platform.isWindows,
  );
}
