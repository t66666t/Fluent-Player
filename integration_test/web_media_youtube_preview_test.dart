import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_browser_session.dart';
import 'package:video_player_app/services/network/browser_network_policy.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue_screen.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

class _DownloadService extends YtDlpDownloadService {
  final resolved = <String>[];
  @override
  Future<void> ensureReady({
    bool activatePage = false,
    bool requireRuntime = false,
  }) async {}
  @override
  Future<void> updateTaskSelectionModel(
    String id,
    DownloadSelection selection,
  ) async {
    final index = tasks.indexWhere((t) => t.taskId == id);
    tasks[index] = tasks[index].copyWith(selection: selection);
    notifyListeners();
  }

  @override
  void rememberImportFolder(String? folderId) {}
  @override
  Future<void> deactivatePage() async {}
  @override
  Future<VideoMeta> resolveAutomaticBrowserMedia(
    String url,
    DownloadSessionConfig config, {
    NetworkMode? networkMode,
  }) async {
    resolved.add(url);
    return VideoMeta(
      id: url,
      source: 'youtube',
      webpageUrl: url,
      title: 'Selected video',
      uploader: 'NBA',
    );
  }

  @override
  Future<VideoMeta?> resolveUrl(String url, {String? existingTaskId}) async {
    resolved.add(url);
    final id = Uri.parse(url).queryParameters['v']!;
    final meta = VideoMeta(
      id: id,
      source: 'youtube',
      webpageUrl: url,
      title: id == 'bMJ3oe_w3ho' ? 'First game' : 'Mavericks at Rockets',
      uploader: 'NBA',
      videoFormats: const [
        VideoFormat(
          formatId: '137',
          ext: 'mp4',
          height: 1080,
          videoCodec: 'avc1',
        ),
      ],
      audioFormats: const [
        AudioFormat(formatId: '140', ext: 'm4a', bitrate: 129),
      ],
    );
    tasks.add(
      YtDlpTaskRecord(
        taskId: existingTaskId!,
        sourceUrl: url,
        selection: const DownloadSelection(),
        meta: meta,
        createdAtIso: '',
      ),
    );
    return meta;
  }
}

class _TestBrowserSession extends WebMediaBrowserSession {
  _TestBrowserSession(this.profile);
  final Directory profile;
  String? error;
  @override
  Future<void> prepare() async {
    try {
      await BrowserNetworkPolicy.prepare(NetworkScope.other, owner: this);
      environment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: profile.path,
          additionalBrowserArguments:
              await BrowserNetworkPolicy.windowsArguments(NetworkScope.other),
        ),
      );
    } catch (e) {
      error = e.toString();
      rethrow;
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native preview buttons open exactly the selected YouTube video without navigating the browser',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final queue = WebMediaDownloadQueue.forLibrary(LibraryService());
      await tester.runAsync(queue.loadSettings);
      NativeVideoPlayerMediaKit.ensureInitialized();
      final profile = await tester.runAsync(
        () => Directory.systemTemp.createTemp('web_preview_profile_'),
      );
      final session = _TestBrowserSession(profile!);
      late HttpServer server;
      late StreamSubscription<HttpRequest> subscription;
      final service = _DownloadService();
      double? buttonX, buttonY;
      final states = <String>[];
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        subscription = server.listen((request) async {
          states.add(request.uri.path);
          if (request.uri.path == '/state') {
            buttonX = double.tryParse(request.uri.queryParameters['x'] ?? '');
            buttonY = double.tryParse(request.uri.queryParameters['y'] ?? '');
            request.response.statusCode = 204;
          } else {
            request.response.headers.contentType = ContentType.html;
            request.response.write(_html);
          }
          await request.response.close();
        });
      });
      final page = Uri.parse(
        'http://127.0.0.1:${server.port}/results?search_query=NBA',
      );
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<YtDlpDownloadService>.value(
            value: service,
            child: MaterialApp(home: WebMediaBrowserScreen(session: session)),
          ),
        );
        await _wait(
          tester,
          () =>
              tester
                  .widget<IconButton>(
                    find.byWidgetPredicate(
                      (w) => w is IconButton && w.tooltip == '打开网页',
                    ),
                  )
                  .onPressed !=
              null,
        );
        expect(session.error, isNull);
        await tester.enterText(find.byType(TextField), page.toString());
        tester.widget<TextField>(find.byType(TextField)).onSubmitted!(
          page.toString(),
        );
        await _wait(
          tester,
          () => buttonX != null && buttonY != null,
          diagnostic: () =>
              '${states.take(20).join(', ')}; ${tester.widget<TextField>(find.byType(TextField)).controller?.text}; '
              '${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | ')}',
        );
        for (final index in [0, 1]) {
          final rect = tester.getRect(find.byType(InAppWebView));
          // Real pointer input selects a card. Its preview stays in a detached
          // ytd-video-preview and reuses the same <video> and resource URL.
          await tester.tapAt(rect.topLeft + Offset(index == 0 ? 60 : 260, 40));
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tapAt(rect.topLeft + Offset(buttonX!, buttonY!));
          await _wait(tester, () => queue.nativeTasks.length == index + 1);
          final expected =
              'https://www.youtube.com/watch?v=${index == 0 ? 'bMJ3oe_w3ho' : 'b0dZkVV_heM'}';
          expect(
            queue.nativeTasks.first.target?.videoPage.toString(),
            expected,
          );
          expect(find.byType(WebMediaDownloadQueueScreen), findsNothing);
          expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            page.toString(),
          );
          await _wait(tester, () => service.resolved.length == index + 1);
          expect(service.resolved.last, expected);
        }
      } finally {
        await tester.runAsync(
          () => queue.removeTasks(queue.nativeTasks.map((t) => t.id).toList()),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(() async {
          await subscription.cancel();
          await server.close(force: true);
        });
        queue.dispose();
        service.dispose();
        // Native WebView2 can release profile files after route teardown;
        // leave the isolated system-temp profile for the OS to clean up.
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() condition, {
  String Function()? diagnostic,
}) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < const Duration(seconds: 30)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(condition(), isTrue, reason: diagnostic?.call());
}

// Mirrors the observed YouTube DOM: independent result cards plus a detached
// global preview with a wrapping watch link. No production capture API mocks.
const _html = '''<!doctype html><html><head><title>NBA search results</title>
<style>body{margin:0} ytd-video-renderer{display:inline-block;width:190px;height:85px}
button{width:180px;height:75px} ytd-video-preview{position:absolute;top:100px;left:10px;width:360px;height:200px}
video{width:360px;height:200px;background:#222}</style></head><body>
<ytd-video-renderer><a href="https://www.youtube.com/watch?v=bMJ3oe_w3ho">First game</a>
<button onclick="showPreview('bMJ3oe_w3ho','First game')">Preview first</button></ytd-video-renderer>
<ytd-video-renderer><a href="https://www.youtube.com/watch?v=b0dZkVV_heM">Mavericks at Rockets</a>
<button onclick="showPreview('b0dZkVV_heM','Mavericks at Rockets')">Preview second</button></ytd-video-renderer>
<ytd-video-preview><a id="preview-link" href="https://www.youtube.com/watch?v=bMJ3oe_w3ho" title="First game">
<div><video id="shared-preview"></video></div></a></ytd-video-preview>
<script>function showPreview(id,title){const a=document.getElementById('preview-link');
a.href='https://www.youtube.com/watch?v='+id;a.title=title;}
setInterval(()=>{const b=document.querySelector('[data-fluent-media-download]');if(!b||b.hidden)return;
const r=b.getBoundingClientRect();fetch('/state?x='+encodeURIComponent(r.x+r.width/2)+'&y='+encodeURIComponent(r.y+r.height/2)).catch(()=>{});},150);
</script></body></html>''';
