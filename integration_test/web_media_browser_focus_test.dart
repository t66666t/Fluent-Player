import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_browser_session.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/library_service.dart';

import '../test/support/web_media_memory_store.dart';

class _Session extends WebMediaBrowserSession {
  _Session(this.profile);
  final Directory profile;

  @override
  Future<void> prepare() async {
    environment ??= await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: profile.path),
    );
  }
}

Future<void> _until(WidgetTester tester, Future<bool> Function() check) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    final ready = await tester.runAsync(check);
    final error = tester.takeException();
    if (error != null) Error.throwWithStackTrace(error, StackTrace.current);
    if (ready == true) return;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  expect(await tester.runAsync(check), isTrue);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Windows pixels and document survive blank clicks and address focus transfers',
    (tester) async {
      NativeVideoPlayerMediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final preferences = WebMediaBrowserPreferences();
      await preferences.setDesktopMode(true);
      final profile = await tester.runAsync(
        () => Directory.systemTemp.createTemp('fluent_focus_'),
      );
      final session = _Session(profile!);
      final downloader = YtDlpDownloadService();
      final library = LibraryService();
      WebMediaDownloadQueue.installForLibraryForTesting(
        library,
        WebMediaDownloadQueue(
          library,
          directoryProvider: () async => profile,
          storeFactory: WebMediaMemoryStore.new,
        ),
      );
      late HttpServer server;
      late StreamSubscription<HttpRequest> requests;
      var loads = 0;
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        requests = server.listen((request) async {
          if (request.uri.path == '/') loads++;
          request.response.headers.contentType = ContentType.html;
          final html = '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Browser focus fixture</title><style>
html,body { margin:0; height:100%; background:#2067ad; }
input { position:absolute; left:40px; top:36px; width:240px; height:50px; }
</style></head><body><input id="draft" placeholder="Native page input">
<script>window.stateToken = Math.random().toString();</script></body></html>''';
          request.response.contentLength = utf8.encode(html).length;
          request.response.write(html);
          await request.response.close();
        });
      });
      final page = 'http://127.0.0.1:${server.port}/';
      final boundaryKey = GlobalKey();
      List<int>? lastNativePixel;
      List<int>? referencePixel;

      Future<bool> visibleNativePixels({bool save = false}) async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final rect = tester.getRect(find.byType(InAppWebView));
        final point = boundary.globalToLocal(
          rect.topLeft + Offset(rect.width * .55, rect.height * .78),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final offset =
              (point.dy.floor() * image.width + point.dx.floor()) * 4;
          lastNativePixel = List.generate(
            4,
            (index) => bytes!.getUint8(offset + index),
          );
          if (save) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '.artifacts/browser-focus-native-frame.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          }
          final pixel = lastNativePixel!;
          final reference = referencePixel;
          if (reference != null) {
            return List.generate(
              4,
              (index) => index,
            ).every((index) => (pixel[index] - reference[index]).abs() < 8);
          }
          // GPU capture/color management may transform the CSS RGB values.
          // Establish a visible blue-page baseline, then compare real pixels.
          return pixel[3] == 255 &&
              pixel[0] < 100 &&
              pixel[1] > pixel[0] + 25 &&
              pixel[2] > pixel[1] + 30;
        } finally {
          image.dispose();
        }
      }

      try {
        debugPrint('Native queue regression: mounting browser');
        await tester.pumpWidget(
          ChangeNotifierProvider<YtDlpDownloadService>.value(
            value: downloader,
            child: MaterialApp(
              home: RepaintBoundary(
                key: boundaryKey,
                child: WebMediaBrowserScreen(
                  preferences: preferences,
                  session: session,
                ),
              ),
            ),
          ),
        );
        await _until(
          tester,
          () async =>
              tester
                  .widget<IconButton>(
                    find.byWidgetPredicate(
                      (widget) =>
                          widget is IconButton && widget.tooltip == '打开网页',
                    ),
                  )
                  .onPressed !=
              null,
        );
        final field = find.byKey(const ValueKey('web-browser-address'));
        tester.widget<TextField>(field).onSubmitted!(page);
        debugPrint('Native queue regression: loading fixture');
        try {
          await _until(
            tester,
            () async =>
                await session.controller?.evaluateJavascript(
                      source: 'document.readyState',
                    ) ==
                    'complete' &&
                // Windows 0.6.0's getTitle channel returns the URL; use the
                // same document-title workaround as the production screen.
                await session.controller?.evaluateJavascript(
                      source: 'document.title',
                    ) ==
                    'Browser focus fixture',
          );
        } catch (_) {
          debugPrint(
            'Fixture loads=$loads, controller=${session.controller != null}, '
            'url=${await session.controller?.getUrl()}, '
            'title=${await session.controller?.getTitle()}, '
            'ready=${await session.controller?.evaluateJavascript(source: 'document.readyState')}, '
            'lifecycle=${tester.binding.lifecycleState}, '
            'UI=${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).toList()}',
          );
          rethrow;
        }
        await tester.pumpAndSettle();
        try {
          await _until(tester, visibleNativePixels);
        } catch (_) {
          await tester.runAsync(() => visibleNativePixels(save: true));
          debugPrint(
            'Native pixel=$lastNativePixel, '
            'rect=${tester.getRect(find.byType(InAppWebView))}, '
            'DOM=${await session.controller?.evaluateJavascript(source: 'document.documentElement.outerHTML')}',
          );
          rethrow;
        }
        referencePixel = List.of(lastNativePixel!);
        debugPrint('Native queue regression: native texture ready');
        final controller = session.controller!;
        final token = await tester.runAsync(
          () => controller.evaluateJavascript(source: 'window.stateToken'),
        );
        final originalLoads = loads;
        final rect = tester.getRect(find.byType(InAppWebView));
        final blank =
            rect.topLeft + Offset(rect.width * .55, rect.height * .78);
        for (var click = 0; click < 10; click++) {
          await tester.tapAt(blank, kind: PointerDeviceKind.mouse);
          await tester.pump(const Duration(milliseconds: 80));
          expect(
            await tester.runAsync(visibleNativePixels),
            isTrue,
            reason: 'Native texture disappeared after blank click $click',
          );
        }

        for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
          await tester.tap(field, kind: kind);
          await tester.pump();
          final input = tester.widget<TextField>(field);
          input.controller!.text = 'https://unfinished.example/draft';
          await tester.tapAt(blank, kind: kind);
          await tester.pump(const Duration(milliseconds: 100));
          expect(input.focusNode!.hasFocus, isFalse);
          expect(input.controller!.text, page);
          expect(await tester.runAsync(visibleNativePixels), isTrue);
        }

        await tester.tap(find.byTooltip('浏览器菜单'));
        await tester.pumpAndSettle();
        expect(await tester.runAsync(visibleNativePixels), isTrue);
        await tester.tapAt(const Offset(12, 200));
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(await tester.runAsync(visibleNativePixels), isTrue);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();

        // The queue remains open while real native document input is delivered
        // through the uncovered part of the browser texture.
        debugPrint('Native queue regression: opening queue');
        await tester.runAsync(
          () => controller.evaluateJavascript(
            source: '''
          window.queueOutsideClicks = 0;
          document.addEventListener('click', () => window.queueOutsideClicks++);
          document.body.style.minHeight = '2400px';
        ''',
          ),
        );
        final queueButton = find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.tooltip?.startsWith('下载队列（') == true,
        );
        await tester.tap(queueButton);
        await tester.pumpAndSettle();
        final queueSurface = find.byKey(
          const ValueKey('web-media-window-surface'),
        );
        await tester.drag(
          find.byKey(const ValueKey('web-media-window-resize-handle')),
          const Offset(-400, -300),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        await tester.drag(
          find.text('下载队列'),
          const Offset(3000, 0),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        final nativeRect = tester.getRect(find.byType(InAppWebView));
        final outsideQueue = nativeRect.topLeft + const Offset(80, 200);
        expect(tester.getRect(queueSurface).contains(outsideQueue), isFalse);
        for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
          final previousClicks = await tester.runAsync(
            () => controller.evaluateJavascript(
              source: 'window.queueOutsideClicks',
            ),
          );
          await tester.tapAt(outsideQueue, kind: kind);
          await tester.pump();
          await _until(
            tester,
            () async =>
                (await controller.evaluateJavascript(
                      source: 'window.queueOutsideClicks',
                    )
                    as num) >
                (previousClicks as num),
          );
          expect(queueSurface, findsOneWidget);
        }
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: outsideQueue,
            scrollDelta: const Offset(0, 240),
          ),
        );
        await _until(
          tester,
          () async =>
              (await controller.evaluateJavascript(source: 'window.scrollY')
                  as num) >
              0,
        );
        expect(queueSurface, findsOneWidget);
        await tester.tap(field);
        await tester.pump();
        expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
        await tester.tap(find.byTooltip('关闭窗口'));
        await tester.pumpAndSettle();
        expect(queueSurface, findsNothing);
        await tester.runAsync(
          () => controller.evaluateJavascript(
            source: '''
          document.body.style.minHeight = '100%';
          window.scrollTo(0, 0);
        ''',
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          await tester.runAsync(
            () => controller.evaluateJavascript(source: 'window.stateToken'),
          ),
          token,
        );
        expect(loads, originalLoads);
        expect(
          await tester.runAsync(() => visibleNativePixels(save: true)),
          isTrue,
        );
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
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
