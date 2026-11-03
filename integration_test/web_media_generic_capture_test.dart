import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_browser_session.dart';
import 'package:video_player_app/features/web_media/web_media_resource.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';

/// Exercises the production capture bridge and passive native network observer.
/// The two local origins serve real media; no page calls the app's JS bridge.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows captures generic early responses, native players and adaptive streams promptly',
    (tester) async {
      final fixture = await tester.runAsync(_GenericFixture.create);
      if (fixture == null) {
        markTestSkipped(
          'Local FFmpeg is required to generate tiny media fixtures.',
        );
        return;
      }
      SharedPreferences.setMockInitialValues({});
      final session = _FixtureSession(
        '${fixture.directory.path}/browser-profile',
      );
      final service = YtDlpDownloadService();
      final report = <Map<String, Object?>>[];
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<YtDlpDownloadService>.value(
            value: service,
            child: MaterialApp(home: WebMediaBrowserScreen(session: session)),
          ),
        );
        await _until(
          tester,
          () =>
              find.byType(TextField).evaluate().isNotEmpty &&
              find
                  .byWidgetPredicate(
                    (widget) =>
                        widget is IconButton &&
                        widget.tooltip == '打开网页' &&
                        widget.onPressed != null,
                  )
                  .evaluate()
                  .isNotEmpty,
          diagnostic: () => 'Browser home did not become ready',
        );
        // Prepare the WebView and its observer before timing an ordinary page
        // navigation. Cold browser startup is separate from discovery latency.
        await _openPage(tester, session, fixture.page('/warmup'));
        await _until(
          tester,
          () async =>
              await tester.runAsync(
                () => session.controller!.evaluateJavascript(
                  source: 'document.readyState',
                ),
              ) ==
              'complete',
        );

        final earlyPage = fixture.page('/early');
        final earlyUrl = fixture.media('/early-response');
        await _openPage(tester, session, earlyPage);
        final early = await _discovered(
          tester,
          session,
          fixture,
          earlyUrl,
          report,
          label: 'early-opaque-response',
        );
        expect(early.kind, WebMediaKind.video);
        expect(early.metadata.mimeType, startsWith('video/mp4'));
        expect(early.metadata.byteSize, fixture.mp4.length);
        expect(early.sourcePage, earlyPage);
        expect(early.playerIds, isEmpty);
        expect(session.capture.players, isEmpty);
        await _until(tester, () => fixture.events.contains('early-opaque'));

        final playerPage = fixture.page('/players');
        await _openPage(tester, session, playerPage);
        final urls = [
          fixture.page('/sample.mp4'),
          fixture.page('/dynamic.webm'),
          fixture.media('/frame-content'),
          fixture.page('/shadow.webm'),
        ];
        final ownerIds = <String>{};
        for (final url in urls) {
          final resource = await _discovered(
            tester,
            session,
            fixture,
            url,
            report,
            label: url.path.substring(1),
            associated: true,
          );
          expect(resource.kind, WebMediaKind.video);
          expect(resource.sourcePage, playerPage);
          expect(resource.playerIds, hasLength(1));
          expect(
            ownerIds.add(resource.playerIds.single),
            isTrue,
            reason: 'Different player sources must keep distinct owners',
          );
          final player = session.capture.players.singleWhere(
            (item) => item.id == resource.playerIds.single,
          );
          await _until(
            tester,
            () => session.capture.players.any(
              (item) =>
                  item.id == player.id && item.currentUrl == url.toString(),
            ),
            diagnostic: () => fixture.diagnostics(session),
          );
          expect(
            player.frameUrl?.origin,
            url.path == '/frame-content'
                ? fixture.mediaOrigin
                : fixture.pageOrigin,
          );
        }
        expect(
          session.capture.resources.any((r) => r.url == earlyUrl.toString()),
          isFalse,
          reason: 'Navigation must discard previous-page candidates',
        );
        expect(fixture.mediaOrigin, isNot(fixture.pageOrigin));

        for (final kind in ['hls', 'dash']) {
          final page = fixture.page('/mse/$kind');
          final manifest = fixture.media('/manifest?format=$kind');
          await _openPage(tester, session, page);
          final resource = await _discovered(
            tester,
            session,
            fixture,
            manifest,
            report,
            label: 'mse-$kind-manifest',
            associated: true,
          );
          await _until(
            tester,
            () =>
                fixture.events.contains('mse-$kind-ready') ||
                fixture.errors.containsKey('mse-$kind'),
            diagnostic: () => fixture.diagnostics(session),
          );
          expect(
            fixture.errors['mse-$kind'],
            isNull,
            reason: 'Fixture must append actual bytes to MediaSource',
          );
          expect(
            resource.kind,
            kind == 'hls' ? WebMediaKind.hls : WebMediaKind.dash,
          );
          expect(resource.sourcePage, page);
          expect(resource.playerIds, hasLength(1));
          expect(
            session.capture.resources.map((item) => item.url),
            isNot(contains(startsWith('${fixture.mediaOrigin}/segments/'))),
            reason:
                'Initialization files and fragments are not complete videos',
          );
          expect(
            session.capture.resources.any((r) => r.url.startsWith('blob:')),
            isFalse,
          );
          expect(
            session.capture.resources,
            hasLength(1),
            reason: 'An MSE player must expose its manifest once',
          );
          expect(fixture.requests['/segments/init.mp4'], isNotNull);
          expect(fixture.requests['/segments/chunk0.mp4'], isNotNull);
        }
        binding.reportData = {'genericCapture': report};
        debugPrint('GENERIC_MEDIA_CAPTURE ${jsonEncode(report)}');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(session.dispose);
        service.dispose();
        await tester.runAsync(fixture.close);
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _FixtureSession extends WebMediaBrowserSession {
  _FixtureSession(this.profile) : super(retainOnExit: true);
  final String profile;

  @override
  Future<void> prepare() async {
    try {
      nativeAgent = await InAppWebViewController.getDefaultUserAgent();
    } catch (_) {
      // Some Windows runtimes expose the identity only on a created WebView.
    }
    environment ??= await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(userDataFolder: profile),
    );
  }
}

Future<void> _openPage(
  WidgetTester tester,
  WebMediaBrowserSession session,
  Uri page,
) async {
  final address = tester.widget<TextField>(find.byType(TextField).first);
  address.onSubmitted!(page.toString());
  await _until(
    tester,
    () => session.controller != null && session.capture.pageUrl == page,
    diagnostic: () => 'Expected $page, got ${session.capture.pageUrl}',
  );
}

Future<void> _until(
  WidgetTester tester,
  FutureOr<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 15),
  String Function()? diagnostic,
}) async {
  final watch = Stopwatch()..start();
  while (!await predicate()) {
    if (watch.elapsed >= timeout) {
      fail('Generic capture timed out: ${diagnostic?.call() ?? ''}');
    }
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  }
}

Future<WebMediaResource> _discovered(
  WidgetTester tester,
  WebMediaBrowserSession session,
  _GenericFixture fixture,
  Uri url,
  List<Map<String, Object?>> report, {
  required String label,
  bool associated = false,
}) async {
  await _until(
    tester,
    () => session.capture.resources.any((item) => item.url == url.toString()),
    diagnostic: () => 'Missing $url; ${fixture.diagnostics(session)}',
  );
  WebMediaResource current() => session.capture.resources.singleWhere(
    (item) => item.url == url.toString(),
  );
  final responseAt =
      fixture.requests[url.hasQuery ? '${url.path}?${url.query}' : url.path];
  expect(
    responseAt,
    isNotNull,
    reason: 'Capture must correspond to an actual requested media URL',
  );
  final responseStarted = responseAt!;
  final elapsed = DateTime.now().difference(responseStarted);
  if (associated) {
    await _until(
      tester,
      () => current().playerIds.isNotEmpty,
      diagnostic: () => 'Unassociated $url; ${fixture.diagnostics(session)}',
    );
  }
  final resource = current();
  final associatedElapsed = DateTime.now().difference(responseStarted);
  report.add({
    'case': label,
    'responseToDiscoveryMs': elapsed.inMilliseconds,
    if (associated) 'responseToPlayerMs': associatedElapsed.inMilliseconds,
    'kind': resource.kind.name,
    'playerCount': resource.playerIds.length,
    'mimeType': resource.metadata.mimeType,
  });
  expect(
    elapsed,
    lessThan(const Duration(seconds: 2)),
    reason: '$label discovery should not wait for polling or metadata probes',
  );
  if (associated) {
    expect(
      associatedElapsed,
      lessThan(const Duration(seconds: 2)),
      reason:
          '$label must associate with its player without an extraction pass',
    );
  }
  return resource;
}

class _GenericFixture {
  _GenericFixture(
    this.directory,
    this.server,
    this.mediaServer,
    this.mp4,
    this.webm,
    this.hlsManifest,
    this.fragments,
  );
  final Directory directory;
  final HttpServer server;
  final HttpServer mediaServer;
  final List<int> mp4;
  final List<int> webm;
  final String hlsManifest;
  final Map<String, List<int>> fragments;
  final Map<String, DateTime> requests = {};
  final Set<String> events = {};
  final Map<String, String> errors = {};

  String get pageOrigin => 'http://127.0.0.1:${server.port}';
  String get mediaOrigin => 'http://127.0.0.1:${mediaServer.port}';
  Uri page(String path) => Uri.parse('$pageOrigin$path');
  Uri media(String path) => Uri.parse('$mediaOrigin$path');

  String diagnostics(WebMediaBrowserSession session) =>
      'Events: $events; errors: $errors; requests: ${requests.keys}; '
      'generation: ${session.capture.generation}; '
      'players: ${session.capture.players.map((p) => '${p.id}:${p.currentUrl}')}; '
      'resources: ${session.capture.resources.map((r) => '${r.url}:${r.playerIds}')}';

  static Future<_GenericFixture?> create() async {
    try {
      if ((await Process.run('ffmpeg', ['-version'])).exitCode != 0) {
        return null;
      }
    } on ProcessException {
      return null;
    }
    final directory = await Directory.systemTemp.createTemp('generic_capture_');
    HttpServer? server;
    HttpServer? mediaServer;
    try {
      final mp4 = File('${directory.path}/sample.mp4');
      final webm = File('${directory.path}/sample.webm');
      final hls = await Directory('${directory.path}/hls').create();
      await _encode([
        '-f',
        'lavfi',
        '-i',
        'color=c=navy:s=160x90:r=10',
        '-t',
        '1.5',
        '-an',
        '-c:v',
        'libx264',
        '-profile:v',
        'baseline',
        '-level:v',
        '1.0',
        '-pix_fmt',
        'yuv420p',
        '-g',
        '5',
        '-movflags',
        '+faststart',
        mp4.path,
      ]);
      await _encode([
        '-i',
        mp4.path,
        '-an',
        '-c:v',
        'libvpx',
        '-deadline',
        'realtime',
        '-cpu-used',
        '8',
        webm.path,
      ]);
      await _encode([
        '-i',
        mp4.path,
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
        '${hls.path}/chunk%d.mp4',
        '${hls.path}/vod.m3u8',
      ]);
      final fragments = <String, List<int>>{};
      await for (final file in hls.list()) {
        if (file is File && file.path.endsWith('.mp4')) {
          fragments[file.uri.pathSegments.last] = await file.readAsBytes();
        }
      }
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // The fixture intentionally embeds a document from a different port.
      mediaServer.defaultResponseHeaders.removeAll('X-Frame-Options');
      final fixture = _GenericFixture(
        directory,
        server,
        mediaServer,
        await mp4.readAsBytes(),
        await webm.readAsBytes(),
        await File('${hls.path}/vod.m3u8').readAsString(),
        fragments,
      );
      server.listen((request) => unawaited(fixture.serve(request)));
      mediaServer.listen((request) => unawaited(fixture.serve(request)));
      return fixture;
    } catch (_) {
      await server?.close(force: true);
      await mediaServer?.close(force: true);
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  static Future<void> _encode(List<String> args) async {
    final result = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      ...args,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'Could not generate generic media fixture: ${result.stderr}',
      );
    }
  }

  Future<void> serve(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    requests.putIfAbsent(request.uri.toString(), DateTime.now);
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    // /early-response remains opaque to page JavaScript, forcing native
    // response capture to classify its extensionless URL from its actual MIME.
    if (path != '/early-response') {
      response.headers.set(HttpHeaders.accessControlAllowOriginHeader, '*');
    }
    try {
      if (path == '/event') {
        final name = request.uri.queryParameters['name'] ?? '';
        final error = request.uri.queryParameters['error'];
        events.add(name);
        if (error != null) errors[name] = error;
        response.statusCode = HttpStatus.noContent;
      } else if (path == '/early-response' ||
          path == '/frame-content' ||
          path == '/sample.mp4') {
        _serveBytes(request, mp4, 'video/mp4');
      } else if (path == '/dynamic.webm' || path == '/shadow.webm') {
        _serveBytes(request, webm, 'video/webm');
      } else if (path.startsWith('/segments/')) {
        final bytes = fragments[request.uri.pathSegments.last];
        if (bytes == null) {
          response.statusCode = HttpStatus.notFound;
        } else {
          _serveBytes(request, bytes, 'video/mp4');
        }
      } else if (path == '/manifest') {
        final isHls = request.uri.queryParameters['format'] == 'hls';
        response.headers.set(
          HttpHeaders.contentTypeHeader,
          isHls ? 'application/vnd.apple.mpegurl' : 'application/dash+xml',
        );
        response.write(isHls ? _servedHlsManifest : _dashManifest);
      } else {
        response.headers.contentType = ContentType.html;
        response.write(_document(path));
      }
      await response.close();
    } catch (_) {
      // Navigations cancel speculative media loads and range requests.
      try {
        await response.close();
      } catch (_) {}
    }
  }

  void _serveBytes(HttpRequest request, List<int> bytes, String mime) {
    final response = request.response;
    response.headers.set(HttpHeaders.contentTypeHeader, mime);
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    var start = 0;
    var end = bytes.length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
      if (match == null || int.parse(match[1]!) >= bytes.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
        return;
      }
      start = int.parse(match[1]!);
      if (match[2]!.isNotEmpty) {
        end = int.parse(match[2]!).clamp(start, end).toInt();
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
      );
    }
    response.contentLength = end - start + 1;
    if (request.method != 'HEAD') response.add(bytes.sublist(start, end + 1));
  }

  String get _servedHlsManifest => hlsManifest
      .split('\n')
      .map(
        (line) => line.startsWith('#')
            ? line.replaceAll('URI="init.mp4"', 'URI="/segments/init.mp4"')
            : line.trim().isEmpty
            ? line
            : '/segments/${line.trim()}',
      )
      .join('\n');

  String get _dashManifest =>
      '''<?xml version="1.0"?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1.5S" minBufferTime="PT0.5S">
 <Period><AdaptationSet mimeType="video/mp4" codecs="avc1.42c00a">
  <Representation id="video" bandwidth="10000" width="160" height="90">
   <SegmentList timescale="1000" duration="500"><Initialization sourceURL="/segments/init.mp4"/>
    ${fragments.keys.where((name) => name != 'init.mp4').map((name) => '<SegmentURL media="/segments/$name"/>').join('\n')}
   </SegmentList>
  </Representation>
 </AdaptationSet></Period>
</MPD>''';

  String _document(String path) {
    if (path == '/early') {
      return '''<!doctype html><html><head><script>
fetch('$mediaOrigin/early-response', {mode:'no-cors',cache:'no-store'})
 .then(response => fetch('/event?name=early-' + response.type));
</script><title>Early response fixture</title></head><body>No player element.</body></html>''';
    }
    if (path == '/players') {
      return '''<!doctype html><html><head><title>Generic players</title></head><body>
<video id="direct" controls muted preload="auto" width="240" height="135" src="/sample.mp4"></video>
<div id="dynamic"></div><div id="shadow"></div>
<iframe src="$mediaOrigin/frame" width="260" height="160" style="border:0"></iframe>
<script>
setTimeout(() => {
 const media = document.createElement('video');
 Object.assign(media,{controls:true,muted:true,preload:'auto',width:240,height:135});
 const source = document.createElement('source'); source.src='/dynamic.webm'; source.type='video/webm';
 media.appendChild(source); document.getElementById('dynamic').appendChild(media); media.load();
}, 40);
const root = document.getElementById('shadow').attachShadow({mode:'open'});
root.innerHTML='<video controls muted preload="auto" width="240" height="135" src="/shadow.webm"></video>';
</script></body></html>''';
    }
    if (path == '/frame') {
      return '''<!doctype html><title>Embedded player</title>
<video controls muted preload="auto" width="240" height="135" src="/frame-content"></video>''';
    }
    if (path.startsWith('/mse/')) {
      final kind = path.split('/').last;
      return '''<!doctype html><html><head><title>Adaptive fixture</title></head><body>
<video id="adaptive" controls muted preload="auto" width="320" height="180"></video>
<script>
const media = document.getElementById('adaptive');
const source = new MediaSource(); media.src = URL.createObjectURL(source); media.load();
source.addEventListener('sourceopen', async () => {
 try {
  const text = await (await fetch('$mediaOrigin/manifest?format=$kind')).text();
  const buffer = source.addSourceBuffer('video/mp4; codecs="avc1.42c00a"');
  const append = async name => {
   const bytes = await (await fetch(new URL(name,'$mediaOrigin/manifest').href)).arrayBuffer();
   await new Promise((resolve,reject) => {
    buffer.addEventListener('updateend',resolve,{once:true});
    buffer.addEventListener('error',reject,{once:true}); buffer.appendBuffer(bytes);
   });
  };
  await append('/segments/init.mp4');
  const names = '$kind' === 'hls'
   ? text.split(/\\r?\\n/).filter(line => line.trim() && !line.startsWith('#'))
   : Array.from(new DOMParser().parseFromString(text,'application/xml').querySelectorAll('SegmentURL')).map(node => node.getAttribute('media'));
  for (const name of names) await append(name.trim());
  source.endOfStream(); fetch('/event?name=mse-$kind-ready');
 } catch (error) { fetch('/event?name=mse-$kind&error=' + encodeURIComponent(String(error))); }
}, {once:true});
</script></body></html>''';
    }
    return '<!doctype html><title>Warm browser</title><p>Local capture fixture</p>';
  }

  Future<void> close() async {
    await server.close(force: true);
    await mediaServer.close(force: true);
    // WebView2 may keep its temporary profile locked briefly after disposal.
    // Leave only that OS-owned profile if it cannot yet be removed.
    for (final entity in directory.listSync()) {
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        if (!entity.path.endsWith('browser-profile')) rethrow;
      }
    }
    if (directory.listSync().isEmpty) await directory.delete();
  }
}
