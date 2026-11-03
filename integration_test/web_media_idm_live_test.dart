import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_browser_screen.dart';
import 'package:video_player_app/features/web_media/web_media_browser_session.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue_screen.dart';
import 'package:video_player_app/features/web_media/web_media_download_target.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationCachePath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getDownloadsPath() async => path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows downloads real playback resources and imports native files',
    (tester) async {
      final root = await tester.runAsync(
        () => Directory.systemTemp.createTemp('web_media_sniff_live_'),
      );
      PathProviderPlatform.instance = _Paths(root!.path);
      SharedPreferences.setMockInitialValues({'largeDataRootPath': root.path});
      final library = LibraryService();
      await tester.runAsync(() async {
        await SettingsService().init();
        SettingsService().largeDataRootPath = root.path;
        await library.init();
      });
      final session = WebMediaBrowserSession(retainOnExit: true);
      final queue = WebMediaDownloadQueue.forLibrary(library);
      final reports = <Map<String, Object?>>[];
      final previousErrors = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception is SocketException ||
            details.exception is HttpException) {
          return;
        }
        previousErrors?.call(details);
      };
      try {
        await tester.pumpWidget(
          MaterialApp(home: WebMediaBrowserScreen(session: session)),
        );
        await _until(
          tester,
          () => find.byTooltip('打开网页').evaluate().isNotEmpty,
        );
        for (final page in [
          'https://www.bilibili.com/video/BV1GJ411x7h7/',
          'https://www.youtube.com/watch?v=jNQXAC9IVRw',
        ]) {
          tester.widget<TextField>(find.byType(TextField).first).onSubmitted!(
            page,
          );
          await _until(tester, () async {
            final controller = session.controller;
            if (controller == null) return false;
            final state = await tester.runAsync(
              () => controller.evaluateJavascript(
                source:
                    '({url:location.href,generation:window.__fluentMediaCapture?.generation,players:document.querySelectorAll("video").length})',
              ),
            );
            return state is Map &&
                webMediaVideoPage(
                      Uri.tryParse(state['url'] as String? ?? ''),
                    ) ==
                    Uri.parse(page) &&
                state['generation'] == session.capture.generation &&
                state['players'] > 0;
          }, seconds: 60);
          await tester.runAsync(
            () => session.controller!.evaluateJavascript(
              source: r'''(() => {
const video=Array.from(document.querySelectorAll('video')).sort((a,b)=>b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight)[0];
if(video){video.muted=true;video.play().catch(()=>{});}})();''',
            ),
          );
          await _until(
            tester,
            () => session.capture.players.any(
              (p) => webMediaVideoPage(p.videoPageUrl) == Uri.parse(page),
            ),
            seconds: 30,
          );
          final player = session.capture.players.firstWhere(
            (p) => webMediaVideoPage(p.videoPageUrl) == Uri.parse(page),
          );
          var clicked = false;
          for (var i = 0; i < 20 && !clicked; i++) {
            clicked =
                await tester.runAsync(
                  () => session.controller!.evaluateJavascript(
                    source: r'''(() => {
const video=Array.from(document.querySelectorAll('video')).sort((a,b)=>b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight)[0];
if(!video)return false;const rect=video.getBoundingClientRect();
const button=Array.from(document.querySelectorAll('[data-fluent-media-download]')).find(b=>Math.abs(parseFloat(b.style.top)-Math.max(4,rect.top+5))<2);
if(!button)return false;button.click();return true;})();''',
                  ),
                ) ==
                true;
            await _tick(tester);
          }
          expect(clicked, isTrue);
          await _until(
            tester,
            () =>
                find.byType(WebMediaDownloadQueueScreen).evaluate().isNotEmpty,
          );
          final screen = tester.widget<WebMediaDownloadQueueScreen>(
            find.byType(WebMediaDownloadQueueScreen),
          );
          final id = screen.focusTaskId!;
          await _until(
            tester,
            () =>
                queue.nativeTasks.any((t) => t.id == id && !t.inspecting) ||
                queue.discoveries.any(
                  (t) => t.id == id && t.message.startsWith('网页暂未'),
                ),
            seconds: 60,
          );
          final task = queue.nativeTasks.where((t) => t.id == id).firstOrNull;
          final report = <String, Object?>{
            'page': page,
            'captured': session.capture.resources.length,
            'owned': session.capture.resources
                .where((r) => r.playerIds.contains(player.id))
                .length,
            'variants': task?.variants.length ?? 0,
            'downloaded': false,
          };
          reports.add(report);
          if (task != null) {
            expect(task.identity, page);
            expect(task.status, WebMediaTaskStatus.pending);
            expect(task.output, isNull);
            if (task.canDownload) {
              await tester.tap(find.text('开始下载').first);
              await _until(
                tester,
                () =>
                    task.status == WebMediaTaskStatus.exported ||
                    task.status == WebMediaTaskStatus.failed,
                seconds: 150,
              );
              report['status'] = task.status.name;
              report['reason'] = task.message;
              if (task.status == WebMediaTaskStatus.exported) {
                final result = await tester.runAsync(
                  () => Process.run('ffprobe', [
                    '-v',
                    'error',
                    '-show_entries',
                    'stream=codec_type:format=duration',
                    '-of',
                    'json',
                    task.output!.path,
                  ]),
                );
                expect(result!.exitCode, 0);
                final info = jsonDecode(result.stdout as String) as Map;
                final streams = (info['streams'] as List)
                    .map((s) => s['codec_type'])
                    .toList();
                expect(streams, containsAll(['video', 'audio']));
                report['downloaded'] = true;
                report['streams'] = streams;
                report['duration'] = info['format']['duration'];
                expect(task.libraryId, isNotNull);
              }
            } else {
              report['reason'] = task.message;
            }
          } else {
            report['reason'] = queue.discoveries
                .firstWhere((t) => t.id == id)
                .message;
          }
          Navigator.of(
            tester.element(find.byType(WebMediaDownloadQueueScreen)),
          ).pop();
          await _tick(tester);
        }
        for (final listPage in [
          'https://www.bilibili.com/',
          'https://search.bilibili.com/all?keyword=Never%20Gonna%20Give%20You%20Up',
        ]) {
          tester.widget<TextField>(find.byType(TextField).first).onSubmitted!(
            listPage,
          );
          Map? selected;
          await _until(tester, () async {
            final result = await tester.runAsync(
              () => session.controller!.evaluateJavascript(
                source: r'''(() => {
if(location.href.indexOf('/video/')>=0 || !window.__fluentMediaCapture) return null;
const card=Array.from(document.querySelectorAll('.bili-video-card,.video-list-item,.video-item')).find(c=>Array.from(c.querySelectorAll('a[href]')).some(a=>/\/video\/(BV|av)/.test(a.href)));
if(!card)return null;const links=Array.from(card.querySelectorAll('a[href]')).filter(a=>/\/video\/(BV|av)/.test(a.href));
const ids=new Set(links.map(a=>(a.href.match(/\/video\/(BV[0-9A-Za-z]{10}|av\d+)/)||[])[1]));if(ids.size!==1)return null;
window.__nativeCoverTestCard=card;card.dispatchEvent(new PointerEvent('pointerover',{bubbles:true}));
return {url:links[0].href,title:links.find(a=>a.title)?.title||'',generation:window.__fluentMediaCapture.generation};})();''',
              ),
            );
            if (result is Map &&
                result['generation'] == session.capture.generation) {
              selected = result;
              return true;
            }
            return false;
          }, seconds: 45);
          final expected = webMediaVideoPage(
            Uri.parse(selected!['url'] as String),
          )!;
          final clicked = await tester.runAsync(
            () => session.controller!.evaluateJavascript(
              source: r'''(() => {
const card=window.__nativeCoverTestCard;if(!card)return false;const rect=card.getBoundingClientRect();
const button=Array.from(document.querySelectorAll('[data-fluent-media-download]')).find(b=>Math.abs(parseFloat(b.style.top)-Math.max(4,rect.top+5))<2);
if(!button)return false;button.click();return true;})();''',
            ),
          );
          expect(clicked, true);
          await _until(
            tester,
            () =>
                find.byType(WebMediaDownloadQueueScreen).evaluate().isNotEmpty,
          );
          final screen = tester.widget<WebMediaDownloadQueueScreen>(
            find.byType(WebMediaDownloadQueueScreen),
          );
          final waiting = queue.discoveries
              .where((t) => t.id == screen.focusTaskId)
              .firstOrNull;
          final native = queue.nativeTasks
              .where((t) => t.id == screen.focusTaskId)
              .firstOrNull;
          expect(
            waiting?.target.identity ?? native?.identity,
            expected.toString(),
          );
          reports.add({
            'page': listPage,
            'selectedCover': expected.toString(),
            'matched': true,
            'autoStarted': native?.operation != null,
          });
          expect(native?.operation, isNull);
          Navigator.of(
            tester.element(find.byType(WebMediaDownloadQueueScreen)),
          ).pop();
          await _tick(tester);
        }
      } finally {
        await tester.runAsync(() async {
          final artifacts = Directory('.artifacts/web-media-sniff');
          await artifacts.create(recursive: true);
          await File(
            '${artifacts.path}/live-downloads.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await _tick(tester);
        FlutterError.onError = previousErrors;
      }
      expect(
        reports.any((r) => r['downloaded'] == true),
        isTrue,
        reason: 'No actual website completed a native resource download.',
      );
    },
    skip: !Platform.isWindows || !const bool.fromEnvironment('WEB_MEDIA_LIVE'),
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _tick(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
}

Future<void> _until(
  WidgetTester tester,
  FutureOr<bool> Function() condition, {
  int seconds = 40,
}) async {
  final timer = Stopwatch()..start();
  while (timer.elapsed < Duration(seconds: seconds)) {
    if (await condition()) return;
    await _tick(tester);
  }
  expect(
    await condition(),
    isTrue,
    reason: 'Browser condition timed out after $seconds seconds',
  );
}
