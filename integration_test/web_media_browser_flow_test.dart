import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_player_screen.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';

const _subtitle = 'Browser import test subtitle';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iframe download button selects its player, probes metadata and opens subtitled native playback',
    (tester) async {
      final fixture = await tester.runAsync(_createFixture);
      if (fixture == null) {
        markTestSkipped('FFmpeg is not available to create the local fixture.');
        return;
      }
      NativeVideoPlayerMediaKit.ensureInitialized();
      final downloader = YtDlpDownloadService();
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<YtDlpDownloadService>.value(
            value: downloader,
            child: const MaterialApp(home: WebMediaBrowserScreen()),
          ),
        );
        await _waitUntil(
          tester,
          () =>
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
        expect(find.text('打开网页，找到你想学习的视频'), findsOneWidget);
        await tester.enterText(find.byType(TextField), fixture.page.toString());
        await tester.tap(find.byTooltip('打开网页'));
        await _waitUntil(tester, () => _resourceButton.evaluate().isNotEmpty);
        await _waitUntil(tester, () => fixture.frameReady);
        // Send a real pointer gesture through the Windows platform view.
        // This keeps the production browser's user-gesture policy enabled.
        final browserRect = tester.getRect(find.byType(InAppWebView));
        await tester.tapAt(browserRect.topLeft + const Offset(158, 88));
        await _waitUntil(tester, () => fixture.frameIsPlaying);
        expect(fixture.framePage.origin, isNot(fixture.page.origin));
        await _waitUntil(
          tester,
          () => fixture.overlayX != null && fixture.overlayY != null,
        );
        // Click the actual injected button in the cross-origin native frame.
        await tester.tapAt(
          browserRect.topLeft +
              Offset(8 + fixture.overlayX!, 8 + fixture.overlayY!),
        );
        await _waitUntil(
          tester,
          () => find.text('这个播放器的媒体').evaluate().isNotEmpty,
        );
        expect(find.textContaining('你点击的视频'), findsOneWidget);
        expect(find.textContaining('未对应播放器'), findsNothing);
        await _waitUntil(
          tester,
          () => find.text('视频 + 音频').evaluate().isNotEmpty,
        );
        expect(find.textContaining('MP4 · 0:01 · '), findsOneWidget);
        expect(find.textContaining('160 × 90'), findsOneWidget);
        await _waitUntil(tester, () => find.text('在线播放').evaluate().isNotEmpty);
        // Let the real JS bridge merge its DOM track snapshot with the earlier
        // native request candidate while the live resource sheet is open.
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('在线播放').first);
        await _waitUntil(
          tester,
          () => find.byType(WebMediaPlayerScreen).evaluate().isNotEmpty,
        );
        final preview = tester.widget<WebMediaPlayerScreen>(
          find.byType(WebMediaPlayerScreen),
        );
        expect(preview.resource.url, fixture.media.toString());
        expect(preview.resource.subtitles, isNotEmpty);
        expect(
          preview.resource.subtitles.any(
            (track) => track.url == fixture.captions.toString(),
          ),
          isTrue,
        );
        await _waitUntil(
          tester,
          () => find.byType(VideoPlayer).evaluate().isNotEmpty,
        );
        final video = tester.widget<VideoPlayer>(find.byType(VideoPlayer));
        expect(video.controller.value.isInitialized, isTrue);
        expect(video.controller.value.duration, greaterThan(Duration.zero));
        await _waitUntil(
          tester,
          () => fixture.framePauseEvents > 0 && !fixture.frameIsPlaying,
        );
        await _waitUntil(
          tester,
          () => find.textContaining(_subtitle).evaluate().isNotEmpty,
        );
        expect(find.byTooltip('选择主字幕'), findsOneWidget);
        expect(find.byTooltip('选择副字幕'), findsOneWidget);
        await tester.tap(find.byTooltip('返回来源网页'));
        await _waitUntil(
          tester,
          () => find.byType(WebMediaPlayerScreen).evaluate().isEmpty,
        );
        expect(find.byType(WebMediaBrowserScreen), findsOneWidget);
        expect(fixture.mediaRequests, greaterThan(0));
        expect(fixture.subtitleRequests, greaterThan(0));
        // Let the return transition release its pointer hit region before
        // interacting with the browser toolbar again.
        await tester.pump(const Duration(milliseconds: 500));
        // A blob/MSE player consumes an HLS init file and MP4 fragments. Only
        // the owning manifest should remain as a downloadable resource.
        await tester.enterText(
          find.byType(TextField),
          fixture.page.resolve('/mse').toString(),
        );
        // Native WebView focus does not reliably register with TestTextInput
        // after route transitions; invoke the same address submission callback.
        tester.widget<TextField>(find.byType(TextField)).onSubmitted!(
          fixture.page.resolve('/mse').toString(),
        );
        await _waitUntil(
          tester,
          () => fixture.mseEvents.isNotEmpty,
          diagnostic: () =>
              'Address: ${tester.widget<TextField>(find.byType(TextField)).controller?.text}; ${fixture.pageRequests.join(', ')}',
        );
        await _waitUntil(
          tester,
          () => fixture.mseReady || fixture.mseError != null,
          diagnostic: () => fixture.mseEvents.join(', '),
        );
        expect(fixture.mseError, isNull);
        await tester.tap(_resourceButton.first);
        await _waitUntil(
          tester,
          () => find.text('视频 + 音频').evaluate().isNotEmpty,
        );
        expect(find.textContaining('HLS / M3U8'), findsOneWidget);
        expect(find.textContaining('/chunk0.mp4'), findsNothing);
        expect(find.textContaining('未对应播放器'), findsNothing);
        await tester.tap(find.text('在线播放').first);
        await _waitUntil(
          tester,
          () => find.byType(VideoPlayer).evaluate().isNotEmpty,
        );
        final hlsPreview = tester.widget<WebMediaPlayerScreen>(
          find.byType(WebMediaPlayerScreen),
        );
        expect(
          hlsPreview.resource.url,
          fixture.page.resolve('/hls/vod.m3u8').toString(),
        );
        expect(
          tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller
              .value
              .isInitialized,
          isTrue,
        );
      } finally {
        // Dispose the platform views and player before closing their source.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(fixture.close);
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Finder get _resourceButton => find.byWidgetPredicate(
  (widget) =>
      widget is Text && RegExp(r'^资源 [1-9]\d*$').hasMatch(widget.data ?? ''),
);

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 45),
  String Function()? diagnostic,
}) async {
  final watch = Stopwatch()..start();
  while (!predicate() && watch.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    predicate(),
    isTrue,
    reason:
        'The local browser/player flow did not become ready in time. ${diagnostic?.call() ?? ''}',
  );
}

class _Fixture {
  _Fixture(this.directory, this.video, this.server, this.frameServer);

  final Directory directory;
  final File video;
  final HttpServer server;
  final HttpServer frameServer;
  int mediaRequests = 0;
  int subtitleRequests = 0;
  bool frameIsPlaying = false;
  bool frameReady = false;
  bool frameEverPlayed = false;
  int framePauseEvents = 0;
  double? overlayX;
  double? overlayY;
  bool mseReady = false;
  String? mseError;
  final List<String> mseEvents = [];
  final List<String> pageRequests = [];
  Uri get page => Uri.parse('http://127.0.0.1:${server.port}/lesson');
  Uri get media => page.resolve('/sample.mp4');
  Uri get captions => page.resolve('/captions.vtt');
  Uri get framePage => Uri.parse('http://127.0.0.1:${frameServer.port}/frame');

  Future<void> close() async {
    await server.close(force: true);
    await frameServer.close(force: true);
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

Future<_Fixture?> _createFixture() async {
  try {
    final version = await Process.run('ffmpeg', ['-version']);
    if (version.exitCode != 0) return null;
  } on ProcessException {
    return null;
  }
  final directory = await Directory.systemTemp.createTemp(
    'fluent_browser_flow_',
  );
  final video = File('${directory.path}${Platform.pathSeparator}sample.mp4');
  HttpServer? server;
  HttpServer? frameServer;
  try {
    final encode = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'color=c=black:s=160x90:r=10',
      '-f',
      'lavfi',
      '-i',
      'anullsrc=r=44100:cl=stereo',
      '-t',
      '1.5',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      '-movflags',
      '+faststart',
      '-shortest',
      video.path,
    ]);
    if (encode.exitCode != 0) {
      throw StateError(
        'Could not generate the browser fixture: ${encode.stderr}',
      );
    }
    final hlsDirectory = Directory('${directory.path}/hls');
    await hlsDirectory.create();
    final hls = await Process.run('ffmpeg', [
      '-v',
      'error',
      '-y',
      '-i',
      video.path,
      '-c',
      'copy',
      '-f',
      'hls',
      '-hls_segment_type',
      'fmp4',
      '-hls_time',
      '0.5',
      '-hls_list_size',
      '0',
      '-hls_segment_filename',
      '${hlsDirectory.path}/chunk%d.mp4',
      '${hlsDirectory.path}/vod.m3u8',
    ]);
    if (hls.exitCode != 0) {
      throw StateError('Could not create HLS fixture: ${hls.stderr}');
    }
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    frameServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Dart's default SAMEORIGIN header would block this intentional cross-port
    // iframe fixture before its document and playback script could execute.
    frameServer.defaultResponseHeaders.removeAll('X-Frame-Options');
    final fixture = _Fixture(directory, video, server, frameServer);
    server.listen((request) => unawaited(_serve(request, fixture)));
    frameServer.listen((request) => unawaited(_serve(request, fixture)));
    return fixture;
  } catch (_) {
    await server?.close(force: true);
    await frameServer?.close(force: true);
    if (await directory.exists()) await directory.delete(recursive: true);
    rethrow;
  }
}

Future<void> _serve(HttpRequest request, _Fixture fixture) async {
  final response = request.response;
  try {
    if (request.uri.path == '/lesson' || request.uri.path == '/mse') {
      fixture.pageRequests.add(request.uri.path);
    }
    response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    switch (request.uri.path) {
      case '/mse':
        fixture.mseEvents.add('served-document');
        response.headers.contentType = ContentType(
          'text',
          'html',
          charset: 'utf-8',
        );
        response.write(
          '''<!doctype html><html><head><title>MSE lesson</title></head><body>
          <video id="mse" controls muted preload="auto" width="320"></video>
          <script>addEventListener('error', error => fetch('/mse-ready?error=' + encodeURIComponent(error.message)));</script>
          <script>
          const media = document.getElementById('mse');
          const event = stage => fetch('/mse-event?stage=' + encodeURIComponent(stage)).catch(() => {});
          event('document');
          const source = new MediaSource(); media.src = URL.createObjectURL(source);
          media.load();
          source.addEventListener('sourceopen', async () => {
            try {
              event('source-open');
              const playlist = await (await fetch('/hls/vod.m3u8')).text();
              event('manifest');
              const buffer = source.addSourceBuffer('video/mp4; codecs="avc1.64001e,mp4a.40.2"');
              const append = async url => {
                const data = await (await fetch(url)).arrayBuffer();
                await new Promise(resolve => { buffer.addEventListener('updateend', resolve, {once:true}); buffer.appendBuffer(data); });
              };
              await append('/hls/init.mp4');
              event('init');
              for (const line of playlist.split(/\\r?\\n/)) {
                if (line.trim() && !line.startsWith('#')) await append('/hls/' + line.trim());
              }
              source.endOfStream(); fetch('/mse-ready');
            } catch (error) { fetch('/mse-ready?error=' + encodeURIComponent(String(error))); }
          }, {once:true});
          </script></body></html>''',
        );
      case '/mse-ready':
        fixture.mseError = request.uri.queryParameters['error'];
        fixture.mseReady = !request.uri.queryParameters.containsKey('error');
        response.statusCode = HttpStatus.noContent;
      case '/lesson':
        response.headers.contentType = ContentType(
          'text',
          'html',
          charset: 'utf-8',
        );
        response.write(
          '''<!doctype html><html><head><title>Local browser lesson</title></head>
          <body><video id="sample" controls muted playsinline preload="auto" width="320"
            src="/sample.mp4"><track src="/captions.vtt" kind="subtitles"
            srclang="en" label="English" default></video>
          <iframe src="${fixture.framePage}" title="Cross origin playback"
            style="position:fixed;left:8px;top:8px;width:300px;height:160px;border:0"></iframe>
          </body></html>''',
        );
      case '/frame':
        response.headers.contentType = ContentType(
          'text',
          'html',
          charset: 'utf-8',
        );
        response.write('''<!doctype html><html><body>
          <video id="frameVideo" controls muted loop playsinline src="${fixture.media}"></video>
          <button id="playEmbedded" style="position:fixed;inset:0;width:100%;height:100%">点击播放嵌入视频</button>
          <script>
            const media = document.getElementById('frameVideo');
            media.muted = true;
            const report = event => {
              const button = document.querySelector('button[data-fluent-media-download]');
              const rect = button && !button.hidden ? button.getBoundingClientRect() : null;
              fetch('/frame-status' + '?playing=' + (!media.paused && !media.ended) + '&event=' + event +
                (rect ? '&overlayX=' + (rect.x + rect.width / 2) + '&overlayY=' + (rect.y + rect.height / 2) : ''),
                {cache:'no-store'}).catch(() => {});
            };
            media.addEventListener('playing', () => report('playing'));
            media.addEventListener('pause', () => report('pause'));
            setInterval(() => report('state'), 200);
            document.getElementById('playEmbedded').addEventListener('click', () => {
              media.play().then(() => document.getElementById('playEmbedded').hidden = true)
                .catch(() => report('play-error'));
            });
            report('ready');
          </script></body></html>''');
      case '/mse-event':
        fixture.mseEvents.add(request.uri.queryParameters['stage'] ?? '');
        response.statusCode = HttpStatus.noContent;
      case '/frame-status':
        if (request.uri.queryParameters['event'] == 'ready') {
          fixture.frameReady = true;
        }
        if (request.uri.queryParameters.containsKey('playing')) {
          fixture.frameIsPlaying =
              request.uri.queryParameters['playing'] == 'true';
        }
        fixture.frameEverPlayed |= fixture.frameIsPlaying;
        fixture.overlayX = double.tryParse(
          request.uri.queryParameters['overlayX'] ?? '',
        );
        fixture.overlayY = double.tryParse(
          request.uri.queryParameters['overlayY'] ?? '',
        );
        if (fixture.frameEverPlayed &&
            request.uri.queryParameters['event'] == 'pause') {
          fixture.framePauseEvents++;
        }
        response.statusCode = HttpStatus.noContent;
      case '/captions.vtt':
        fixture.subtitleRequests++;
        response.headers.contentType = ContentType(
          'text',
          'vtt',
          charset: 'utf-8',
        );
        response.write('WEBVTT\n\n00:00:00.000 --> 00:00:01.500\n$_subtitle\n');
      case '/sample.mp4':
        fixture.mediaRequests++;
        final length = await fixture.video.length();
        var start = 0;
        var end = length - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        if (range != null) {
          final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
          if (match == null) {
            response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            break;
          }
          if (match[1]!.isEmpty) {
            final suffix = int.tryParse(match[2]!) ?? 0;
            start = (length - suffix).clamp(0, length).toInt();
          } else {
            start = int.parse(match[1]!);
            if (match[2]!.isNotEmpty) {
              end = int.parse(match[2]!).clamp(0, end).toInt();
            }
          }
          if (start > end || start >= length) {
            response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */$length',
            );
            break;
          }
          response.statusCode = HttpStatus.partialContent;
          response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/$length',
          );
        }
        response.headers.contentType = ContentType('video', 'mp4');
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        response.headers.contentLength = end - start + 1;
        if (request.method != 'HEAD') {
          await response.addStream(fixture.video.openRead(start, end + 1));
        }
      default:
        final name = request.uri.pathSegments.lastOrNull ?? '';
        if (request.uri.path.startsWith('/hls/') &&
            RegExp(r'^(vod\.m3u8|init\.mp4|chunk\d+\.mp4)$').hasMatch(name)) {
          final file = File('${fixture.directory.path}/hls/$name');
          response.headers.contentType = name.endsWith('.m3u8')
              ? ContentType('application', 'vnd.apple.mpegurl')
              : ContentType('video', 'mp4');
          response.contentLength = await file.length();
          await response.addStream(file.openRead());
        } else {
          response.statusCode = HttpStatus.notFound;
        }
    }
    await response.close();
  } catch (_) {
    // The browser may cancel preload/range requests when the preview takes over.
    try {
      await response.close();
    } catch (_) {}
  }
}
