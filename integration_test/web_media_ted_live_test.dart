// Opt-in real-site test: flutter test integration_test/web_media_ted_live_test.dart
// -d windows --dart-define=TED_LIVE_TEST=true
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_browser_session.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/network/browser_network_policy.dart';
import 'package:video_player_app/services/network/network_http.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/support';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root/documents';
  @override
  Future<String?> getTemporaryPath() async => '$root/temp';
}

class _Session extends WebMediaBrowserSession {
  _Session(this.profile);
  final String profile;
  @override
  Future<void> prepare() async {
    await BrowserNetworkPolicy.prepare(NetworkScope.other, owner: this);
    environment = await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: profile,
        additionalBrowserArguments: await BrowserNetworkPolicy.windowsArguments(
          NetworkScope.other,
        ),
      ),
    );
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String step, {
  int seconds = 90,
}) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed.inSeconds < seconds) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
  }
  expect(condition(), isTrue, reason: step);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'TED native browser playback, sniffing, download and media import',
    (tester) async {
      final root = Directory(
        '.artifacts/ted-live/${DateTime.now().millisecondsSinceEpoch}',
      ).absolute;
      await root.create(recursive: true);
      for (final name in [
        'support',
        'documents',
        'temp',
        'data',
        'downloads',
      ]) {
        await Directory('${root.path}/$name').create(recursive: true);
      }
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      SharedPreferences.setMockInitialValues({
        'largeDataRootPath': '${root.path}/data',
      });
      AppStorageService.instance = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.windows,
          support: Directory('${root.path}/support'),
          documents: Directory('${root.path}/documents'),
          cache: Directory('${root.path}/temp'),
          defaultData: Directory('${root.path}/data'),
          executable: Directory('${root.path}/program'),
        ),
      );
      SettingsService().resetForTest();
      SettingsService().largeDataRootPath = '${root.path}/data';
      final library = LibraryService()..resetLibraryForTesting();
      await library.init();
      final queue = WebMediaDownloadQueue(
        library,
        directoryProvider: () async => Directory('${root.path}/downloads'),
      );
      WebMediaDownloadQueue.installForLibraryForTesting(library, queue);
      final session = _Session('${root.path}/profile');
      final downloader = YtDlpDownloadService();
      NativeVideoPlayerMediaKit.ensureInitialized();
      final report = <String, Object?>{
        'page':
            'https://www.ted.com/talks/matt_cutts_try_something_new_for_30_days',
        'root': root.path,
      };
      void log(String message) {
        // ignore: avoid_print
        print('TED_LIVE $message');
      }

      Future<dynamic> script(String source) async => tester.runAsync(
        () => session.controller!.evaluateJavascript(source: source),
      );
      Future<void> screenshot(String name) async {
        await tester.pump();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('ted-live')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${root.path}/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('ted-live'),
            child: ChangeNotifierProvider<YtDlpDownloadService>.value(
              value: downloader,
              child: MaterialApp(
                theme: ThemeData.dark(useMaterial3: true),
                home: WebMediaBrowserScreen(session: session),
              ),
            ),
          ),
        );
        await _until(
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
          'Browser ready',
        );
        expect(find.text('YouTube'), findsNothing);
        expect(find.text('哔哩哔哩'), findsNothing);
        expect(find.text('添加网站'), findsOneWidget);
        await screenshot('empty-home');
        await tester.enterText(
          find.byKey(const ValueKey('web-browser-address')),
          report['page']! as String,
        );
        await tester.tap(find.byTooltip('打开网页'));
        await _until(
          tester,
          () => session.controller != null,
          'Native WebView created',
        );
        dynamic playback;
        final watch = Stopwatch()..start();
        while (watch.elapsed.inSeconds < 90) {
          playback = await script(
            '''JSON.stringify({title:document.title, text:document.body.innerText.slice(0,2500), buttons:Array.from(document.querySelectorAll('button,[role="button"]')).slice(0,80).map(e=>({label:e.getAttribute('aria-label'),title:e.getAttribute('title'),text:e.textContent.slice(0,80)})),videos:Array.from(document.querySelectorAll('video')).map(v=>({src:v.currentSrc,paused:v.paused,duration:v.duration}))})''',
          );
          if (playback is String && playback.contains('Try something new')) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 200));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 1)),
          );
        }
        report['pageState'] = playback;
        log('PAGE $playback');
        // Read native DOM geometry, then deliver a real pointer gesture. Do not
        // call video.play(), inject source URLs or manufacture captured resources.
        final deadline = Stopwatch()..start();
        while (deadline.elapsed.inSeconds < 60) {
          final buttonJson = await script(
            '''JSON.stringify(Array.from(document.querySelectorAll('button,[role="button"]')).filter(e=>/^(play|play video|play talk|播放)/i.test((e.getAttribute('aria-label')||e.getAttribute('title')||e.textContent||'').trim())).map(e=>{const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,w:r.width,h:r.height}}).find(r=>r.w>0&&r.h>0))''',
          );
          if (buttonJson is String && buttonJson.startsWith('{')) {
            final button = jsonDecode(buttonJson) as Map;
            final rect = tester.getRect(find.byType(InAppWebView));
            await tester.tapAt(
              rect.topLeft +
                  Offset(
                    (button['x'] as num).toDouble(),
                    (button['y'] as num).toDouble(),
                  ),
            );
            log('Clicked native play button $buttonJson');
            break;
          }
          await tester.pump(const Duration(milliseconds: 200));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 1)),
          );
        }
        await _until(
          tester,
          () => session.capture.resources.isNotEmpty,
          'TED resources captured after native play',
        );
        await _until(
          tester,
          () => session.capture.players.any(
            (player) =>
                player.isActive &&
                player.duration != null &&
                player.duration!.inSeconds >= 180 &&
                player.duration!.inSeconds <= 240,
          ),
          'The TED talk is playing after any pre-roll advertisement',
          seconds: 120,
        );
        final talkPlayer = session.capture.players.firstWhere(
          (player) =>
              player.isActive &&
              player.duration != null &&
              player.duration!.inSeconds >= 180 &&
              player.duration!.inSeconds <= 240,
        );
        report['players'] = session.capture.players
            .map(
              (player) => {
                'active': player.isActive,
                'durationSeconds': player.duration?.inMilliseconds == null
                    ? null
                    : player.duration!.inMilliseconds / 1000,
              },
            )
            .toList();
        report['resources'] = session.capture.resources
            .map((r) => {'url': r.url, 'kind': r.kind.name, 'title': r.title})
            .toList();
        log(
          'RESOURCES ${jsonEncode((report['resources'] as List).take(5).toList())}',
        );
        await screenshot('ted-playing');
        await tester.tap(
          find
              .byWidgetPredicate(
                (w) =>
                    w is Text &&
                    RegExp(r'^资源 [1-9]\d*$').hasMatch(w.data ?? ''),
              )
              .first,
        );
        await _until(
          tester,
          () => find.byType(ExpansionTile).evaluate().isNotEmpty,
          'Resource groups are visible',
        );
        final talkGroup = find
            .widgetWithText(ExpansionTile, talkPlayer.title)
            .first;
        final addTalk = find.descendant(
          of: talkGroup,
          matching: find.text('添加到下载队列'),
        );
        if (addTalk.evaluate().isEmpty) {
          // Several candidates produce collapsed groups. Expand the current
          // player's group just as a user would before choosing its action.
          await tester.tap(
            find
                .descendant(
                  of: talkGroup,
                  matching: find.text(talkPlayer.title),
                )
                .first,
          );
          await tester.pump(const Duration(milliseconds: 300));
        }
        await _until(
          tester,
          () => addTalk.evaluate().isNotEmpty,
          'Resource sheet can add captured TED media',
        );
        await screenshot('resources');
        await tester.tap(addTalk.first);
        await _until(
          tester,
          () => queue.nativeTasks.isNotEmpty,
          'TED task appears in queue',
        );
        final task = queue.nativeTasks.first;
        // Adding the resource opens the production queue automatically.
        await _until(
          tester,
          () => find.text('下载队列').evaluate().isNotEmpty,
          'Queue is visible',
        );
        await _until(
          tester,
          () =>
              find.text('开始').evaluate().isNotEmpty ||
              task.runAllowed ||
              task.status == WebMediaTaskStatus.exported ||
              task.status == WebMediaTaskStatus.failed,
          'Queue ready',
        );
        if (find.text('开始').evaluate().isNotEmpty) {
          await tester.tap(find.text('开始').first);
        }
        log('Download started ${task.status.name}');
        await _until(
          tester,
          () =>
              task.status == WebMediaTaskStatus.exported ||
              task.status == WebMediaTaskStatus.failed,
          'Download and import complete',
          seconds: 240,
        );
        report['download'] = {
          'status': task.status.name,
          'message': task.message,
          'bytes': task.downloadedBytes,
          'output': task.output?.path,
          'libraryId': task.libraryId,
        };
        log('DOWNLOAD ${jsonEncode(report['download'])}');
        await screenshot('download-result');
        expect(task.status, WebMediaTaskStatus.exported, reason: task.message);
        expect(task.libraryId, isNotNull);
        expect(task.output, isNotNull);
        final probe = await tester.runAsync(
          () async => Process.run(await FFmpegUtils.ffprobePath, [
            '-v',
            'error',
            '-show_entries',
            'format=duration,size:stream=codec_type,codec_name,width,height',
            '-of',
            'json',
            task.output!.path,
          ]),
        );
        report['ffprobe'] = jsonDecode(probe!.stdout as String);
        expect(probe.exitCode, 0, reason: '${probe.stderr}');
        final streams = (report['ffprobe'] as Map)['streams'] as List;
        expect(streams.any((s) => s['codec_type'] == 'video'), isTrue);
        expect(streams.any((s) => s['codec_type'] == 'audio'), isTrue);
        final duration = double.parse(
          (report['ffprobe'] as Map)['format']['duration'] as String,
        );
        expect(
          duration,
          inInclusiveRange(180, 240),
          reason:
              'The complete TED talk must be downloaded, not an ad or preview',
        );
        log('PASS ${jsonEncode(report['ffprobe'])}');
      } finally {
        await tester.runAsync(
          () => File(
            '${root.path}/report.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(report)),
        );
        log('Report ${root.path}/report.json');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 500));
        await tester.runAsync(session.dispose);
        queue.dispose();
        downloader.dispose();
        PathProviderPlatform.instance = previousPaths;
      }
    },
    skip: !Platform.isWindows || !const bool.fromEnvironment('TED_LIVE_TEST'),
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
