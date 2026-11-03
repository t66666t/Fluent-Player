import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue_screen.dart';
import 'package:video_player_app/features/web_media/web_media_download_service.dart';
import 'package:video_player_app/features/web_media/web_media_floating_controls.dart';
import 'package:video_player_app/features/web_media/web_media_resource.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';

import '../test/support/web_media_memory_store.dart';

/// Independent fixture server: response generation must not compete with the
/// downloader and Flutter frame work on the main isolate.
Future<void> _serve(SendPort ready) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ready.send(server.port);
  final chunk = Uint8List(65536)..fillRange(0, 65536, 0x47);
  server.listen((request) async {
    try {
      if (request.uri.path == '/page') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '''<!doctype html><style>html,body{margin:0;overflow:hidden;background:#111}canvas{width:100vw;height:100vh}</style>
<canvas width="1920" height="1080"></canvas><script>
const c=document.querySelector('canvas'),x=c.getContext('2d');
function frame(t){x.fillStyle='#151515';x.fillRect(0,0,c.width,c.height);
for(let i=0;i<120;i++){x.fillStyle=`hsl(\${i*3},55%,40%)`;x.fillRect((t/8+i*31)%1920,i*9,200,8)}
requestAnimationFrame(frame)}requestAnimationFrame(frame);
</script>''',
        );
      } else if (request.uri.path.endsWith('.m3u8')) {
        request.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        request.response.write('#EXTM3U\n#EXT-X-TARGETDURATION:10\n');
        for (var i = 0; i < 174; i++) {
          request.response.write('#EXTINF:9.5,\nsegment$i.ts\n');
        }
        request.response.write('#EXT-X-ENDLIST\n');
      } else {
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set('etag', '"fixture-v1"');
        request.response.contentLength = chunk.length * 16;
        for (var i = 0; i < 16; i++) {
          request.response.add(chunk);
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }
      await request.response.close();
    } catch (_) {
      /* Pausing a transfer closes its in-flight responses. */
    }
  });
}

class _Transfer extends WebMediaDownloadService {
  _Transfer() : super(dio: Dio());
  @override
  Future<File> download(
    WebMediaResource resource,
    Directory directory, {
    void Function(double?)? onProgress,
    WebMediaResource? audioCompanion,
    WebMediaResumeState? resumeState,
    void Function(int, int?)? onBytes,
  }) {
    final notify = onStage;
    onStage = (stage) {
      // The deterministic payload exercises the real transfer and checkpoints.
      // It is intentionally stopped before invoking a native media muxer.
      if (stage == WebMediaTransferStage.merging) unawaited(cancel());
      notify?.call(stage);
    };
    return super.download(
      resource,
      directory,
      onProgress: onProgress,
      audioCompanion: audioCompanion,
      resumeState: resumeState,
      onBytes: onBytes,
    );
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'native floating queue responds while 32 HLS connections transfer',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = null;
      final directory = await Directory.systemTemp.createTemp(
        'web_expansion_native_',
      );
      final browserDirectory = await Directory.systemTemp.createTemp(
        'web_expansion_browser_',
      );
      final port = ReceivePort();
      final fixture = await Isolate.spawn(_serve, port.sendPort);
      final serverPort = await port.first as int;
      port.close();
      final transfer = _Transfer();
      final queue = WebMediaDownloadQueue(
        Object(),
        directoryProvider: () async => directory,
        storeFactory: WebMediaMemoryStore.new,
        transferFactory: () => transfer,
      );
      final focus = FocusScopeNode();
      final environment = Platform.isWindows
          ? await WebViewEnvironment.create(
              settings: WebViewEnvironmentSettings(
                userDataFolder: browserDirectory.path,
              ),
            )
          : null;
      var pageReady = false;
      final frames = <ui.FrameTiming>[];
      void collect(List<ui.FrameTiming> next) => frames.addAll(next);
      final clock = Stopwatch()..start();
      var lastTick = 0, maxEventGap = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
        final now = clock.elapsedMicroseconds;
        final gap = now - lastTick;
        if (lastTick > 0 && gap > maxEventGap) maxEventGap = gap;
        lastTick = now;
      });
      final clicks = <Map<String, Object>>[];
      try {
        await queue.loadSettings();
        var media = WebMediaResource(
          url: 'http://127.0.0.1:$serverPort/main.m3u8',
          sourcePage: Uri.parse('https://course.example/watch'),
          title: '腾讯体育样式回放 · 展开操作与高速下载测试',
          kind: WebMediaKind.hls,
        );
        const sourceQueue = String.fromEnvironment('WEB_MEDIA_EXPANSION_QUEUE');
        if (sourceQueue.isNotEmpty) {
          final index =
              jsonDecode(await File(sourceQueue).readAsString()) as Map;
          final record = (index['tasks'] as List).cast<Map>().firstWhere(
            (task) => task['status'] == 'paused',
          );
          media = WebMediaResource.fromPersistedJson(
            Map<String, dynamic>.from(record['resource'] as Map),
          );
          media = media.copyWith(
            headers: {
              'Referer': media.sourcePage.toString(),
              'User-Agent': 'Mozilla/5.0',
            },
          );
        }
        final task = WebMediaNativeQueueTask(
          id: 'native-active',
          resource: media,
        );
        queue.nativeTasks.add(task);
        for (var i = 0; i < 50; i++) {
          queue.nativeTasks.add(
            WebMediaNativeQueueTask(
              id: 'history-$i',
              resource: WebMediaResource(
                url: 'https://cdn.example/$i.mp4',
                sourcePage: Uri.parse('https://course.example/watch'),
                title: '已完成的历史任务 $i',
                kind: WebMediaKind.video,
              ),
            )..status = WebMediaTaskStatus.exported,
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: appInteractionTheme(
              ThemeData(
                brightness: Brightness.dark,
                useMaterial3: true,
                fontFamily: 'Microsoft YaHei',
              ),
            ),
            home: WebMediaWindowHost(
              visible: true,
              onClose: () {},
              focusNode: focus,
              title: '下载队列',
              windowBuilder: (_) =>
                  WebMediaDownloadQueueScreen(queue: queue, embedded: true),
              child: Scaffold(
                body: InAppWebView(
                  webViewEnvironment: environment,
                  initialUrlRequest: URLRequest(
                    url: WebUri('http://127.0.0.1:$serverPort/page'),
                  ),
                  onLoadStop: (_, _) async {
                    pageReady = true;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        for (var attempt = 0; attempt < 200 && !pageReady; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        expect(pageReady, isTrue);
        binding.addTimingsCallback(collect);
        maxEventGap = 0;
        queue.startNative(task);
        await tester.pump();
        for (var round = 0; round < 8; round++) {
          for (final opening in [true, false]) {
            final button = find.byTooltip(opening ? '下载详情' : '收起详情').first;
            final watch = Stopwatch()..start();
            await tester.tap(button, kind: PointerDeviceKind.mouse);
            await tester.pump();
            watch.stop();
            final responded = find
                .byTooltip(opening ? '收起详情' : '下载详情')
                .evaluate()
                .isNotEmpty;
            clicks.add({
              'round': round,
              'opening': opening,
              'responseUs': watch.elapsedMicroseconds,
              'respondedOnFirstClick': responded,
              'received': task.downloadedBytes,
              'activeConnections': task.snapshot?.activeConnections ?? 0,
            });
            expect(responded, isTrue);
            expect(tester.takeException(), isNull);
            await Future<void>.delayed(
              Duration(milliseconds: opening ? 600 : 220),
            );
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final report = <String, Object>{
          'clicks': clicks,
          'buildUs': frames
              .map((frame) => frame.buildDuration.inMicroseconds)
              .toList(),
          'rasterUs': frames
              .map((frame) => frame.rasterDuration.inMicroseconds)
              .toList(),
          'maxEventGapUs': maxEventGap,
          'received': task.downloadedBytes,
          'completedSegments':
              task.snapshot?.blocks.where((block) => block.complete).length ??
              0,
          'frameCount': frames.length,
          'nativeBrowser': true,
          'externalMedia': sourceQueue.isNotEmpty,
          'totalSegments': task.snapshot?.blocks.length ?? 0,
        };
        binding.reportData = report;
        final output = File(
          const String.fromEnvironment(
            'WEB_MEDIA_EXPANSION_REPORT',
            defaultValue: '.artifacts/web-media-expansion-native.json',
          ),
        );
        await output.parent.create(recursive: true);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
        );
        debugPrint(
          'WEB_MEDIA_EXPANSION_PROFILE ${jsonEncode({'clicks': clicks, 'maxEventGapUs': maxEventGap, 'frames': frames.length, 'received': task.downloadedBytes})}',
        );
        expect(frames, isNotEmpty);
        expect(task.snapshot?.blocks, isNotEmpty);
        expect(task.downloadedBytes, greaterThan(1024 * 1024));
        expect(
          clicks.every((click) => click['respondedOnFirstClick'] == true),
          isTrue,
        );
        expect(
          clicks
              .map((click) => click['responseUs'] as int)
              .reduce((a, b) => a > b ? a : b),
          lessThan(200000),
          reason: 'a click must not wait for a second click or a long UI stall',
        );
        expect(
          maxEventGap,
          lessThan(250000),
          reason: 'transfer work must keep the UI event loop responsive',
        );
      } finally {
        heartbeat.cancel();
        binding.removeTimingsCallback(collect);
        await queue.pauseAll();
        await tester.pumpWidget(const SizedBox.shrink());
        await queue.shutdown();
        focus.dispose();
        await environment?.dispose();
        fixture.kill(priority: Isolate.immediate);
        HttpOverrides.global = previousHttp;
        await directory.delete(recursive: true);
        try {
          await browserDirectory.delete(recursive: true);
        } on FileSystemException {
          // WebView2 can briefly retain its isolated cache after disposal.
          // The system temporary directory owns it; no app profile is touched.
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: !Platform.isWindows,
  );
}
