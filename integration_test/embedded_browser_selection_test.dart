import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_player_app/features/web_media/web_media_browser_controls.dart';
import 'package:video_player_app/widgets/embedded_browser_view.dart';

Future<void> _nativeWait(WidgetTester tester, [int milliseconds = 80]) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(Duration(milliseconds: milliseconds)),
  );
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native mouse and touch selection retain the page and its gestures',
    (tester) async {
      final profile = await Directory.systemTemp.createTemp(
        'browser_selection_',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write('''<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body { margin: 30px; font: 24px/1.8 sans-serif; }
p { width: 600px; max-width: 85vw; } input { font: inherit; }</style>
</head><body><p id="text">Alpha beta gamma delta epsilon zeta eta theta.
Touch selection and mouse selection share this document.</p>
<input id="editor" value="Editable text"><a id="nearby" href="#clicked">Nearby link</a>
<script>
window.pointerKinds = []; window.clicks = 0;
document.addEventListener('pointerdown', e => pointerKinds.push(e.pointerType));
document.getElementById('nearby').addEventListener('click', () => clicks++);
window.textBox = (start, end) => {
  const range = document.createRange();
  const text = document.getElementById('text').firstChild;
  range.setStart(text, start); range.setEnd(text, end);
  const r = range.getBoundingClientRect();
  return JSON.stringify({x:r.x, y:r.y, width:r.width, height:r.height});
};
</script></body></html>''');
        await request.response.close();
      });
      WebViewEnvironment? environment;
      InAppWebViewController? controller;
      var loaded = false, backs = 0;
      final pager = PageController();
      try {
        if (Platform.isWindows) {
          environment = await WebViewEnvironment.create(
            settings: WebViewEnvironmentSettings(userDataFolder: profile.path),
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PageView(
                controller: pager,
                children: [
                  EmbeddedBrowserView(
                    browserId: 'selection-integration',
                    initialUrlRequest: URLRequest(
                      url: WebUri('http://127.0.0.1:${server.port}/'),
                    ),
                    initialSettings: InAppWebViewSettings(),
                    webViewEnvironment: environment,
                    initialUserScripts: UnmodifiableListView([
                      UserScript(
                        source: fluentBrowserBackScript,
                        injectionTime:
                            UserScriptInjectionTime.AT_DOCUMENT_START,
                      ),
                    ]),
                    onWebViewCreated: (value) {
                      controller = value;
                      value.addJavaScriptHandler(
                        handlerName: 'fluentBrowserBack',
                        callback: (_) {
                          backs++;
                          return null;
                        },
                      );
                    },
                    onLoadStop: (_, _) => loaded = true,
                  ),
                  const Center(child: Text('Other page')),
                ],
              ),
            ),
          ),
        );
        for (var i = 0; i < 150 && !loaded; i++) {
          await _nativeWait(tester);
        }
        expect(loaded, isTrue);
        final browser = controller!;
        Future<dynamic> js(String source) async =>
            tester.runAsync(() => browser.evaluateJavascript(source: source));
        Future<Rect> textBox(int start, int end) async {
          final value =
              jsonDecode(await js('textBox($start, $end)') as String) as Map;
          return Rect.fromLTWH(
            (value['x'] as num).toDouble(),
            (value['y'] as num).toDouble(),
            (value['width'] as num).toDouble(),
            (value['height'] as num).toDouble(),
          ).shift(tester.getTopLeft(find.byType(InAppWebView)));
        }

        final firstWord = await textBox(0, 5);
        final lastWord = await textBox(17, 22);
        final mouse = await tester.startGesture(
          Offset(firstWord.left + 1, firstWord.center.dy),
          kind: PointerDeviceKind.mouse,
        );
        for (var i = 1; i <= 12; i++) {
          await mouse.moveTo(
            Offset.lerp(
              Offset(firstWord.left + 1, firstWord.center.dy),
              Offset(lastWord.right - 1, lastWord.center.dy),
              i / 12,
            )!,
          );
          await _nativeWait(tester, 20);
        }
        await mouse.up();
        await _nativeWait(tester);
        expect(
          await js('window.getSelection().toString()'),
          contains('beta gamma'),
        );
        expect(pager.page, 0);
        expect(await js('clicks'), 0);
        await js(
          "window.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape'}))",
        );
        await _nativeWait(tester);
        expect(await js('window.getSelection().toString()'), isEmpty);
        expect(backs, 0);

        // Exercise a touch sequence after mouse use on the same desktop/device.
        final touch = await tester.startGesture(firstWord.center);
        await _nativeWait(tester, 900);
        await touch.up();
        await _nativeWait(tester, 150);
        expect(await js('window.getSelection().toString()'), isNotEmpty);
        expect(await js('JSON.stringify(pointerKinds)'), contains('touch'));
        expect(pager.page, 0);
        expect(await js('clicks'), 0);
        expect(backs, 0);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await _nativeWait(tester);
        pager.dispose();
        await environment?.dispose();
        await requests.cancel();
        await server.close(force: true);
        // WebView2 can retain its isolated profile briefly after view disposal.
        try {
          if (profile.absolute.parent.path ==
              Directory.systemTemp.absolute.path) {
            await profile.delete(recursive: true);
          }
        } on FileSystemException {
          /* OS cleanup later. */
        }
      }
    },
    skip: Platform.isLinux, // Linux uses the dedicated Chromium transport test.
  );
}
