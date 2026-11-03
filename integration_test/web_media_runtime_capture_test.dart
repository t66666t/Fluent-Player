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
import 'package:video_player_app/services/network/browser_network_policy.dart';
import 'package:video_player_app/services/network/network_http.dart';

/// Opt-in smoke check. The address is supplied at runtime and is never logged.
/// No page text, images, media bodies or signed resource URLs are exported.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
  const input = String.fromEnvironment('WEB_MEDIA_VALIDATION_URL');
  testWidgets(
    'runtime page exposes generic media capture promptly',
    (tester) async {
      final uri = Uri.parse(input);
      final directory = await Directory.systemTemp.createTemp(
        'generic_capture_',
      );
      final session = _RuntimeSession(directory.path)
        ..page = uri
        ..showHome = false;
      session.capture.beginPage(uri);
      final service = YtDlpDownloadService();
      SharedPreferences.setMockInitialValues({});
      final timer = Stopwatch()..start();
      var firstResourceMs = 0;
      var firstAssociatedMs = 0;
      var firstManifestMs = 0;
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<YtDlpDownloadService>.value(
            value: service,
            child: MaterialApp(home: WebMediaBrowserScreen(session: session)),
          ),
        );
        while (timer.elapsed < const Duration(seconds: 45)) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            final controller = session.controller;
            if (controller != null) {
              await controller.evaluateJavascript(
                source: '''(() => {
              const videos = Array.from(document.querySelectorAll('video'));
              videos.sort((a,b) => b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight);
              const video = videos[0];
              if (video && video.paused) {
                video.muted = true;
                const started = video.play();
                if (started && started.catch) started.catch(() => {});
              }
              return videos.length;
            })();''',
              );
            }
          });
          final resources = session.capture.resources;
          if (resources.isNotEmpty && firstResourceMs == 0) {
            firstResourceMs = timer.elapsedMilliseconds;
          }
          if (resources.any((r) => r.playerIds.isNotEmpty) &&
              firstAssociatedMs == 0) {
            firstAssociatedMs = timer.elapsedMilliseconds;
          }
          if (resources.any(
                (r) =>
                    r.kind == WebMediaKind.hls || r.kind == WebMediaKind.dash,
              ) &&
              firstManifestMs == 0) {
            firstManifestMs = timer.elapsedMilliseconds;
          }
          if (firstManifestMs > 0 && firstAssociatedMs > 0) break;
        }
        final resources = session.capture.resources;
        final structure = await tester.runAsync(() async {
          return session.controller?.evaluateJavascript(
            source: r'''(() => ({
              scripts: document.scripts.length,
              inlineScripts: Array.from(document.scripts).filter(s => !s.src).length,
              manifestScripts: Array.from(document.scripts).filter(s => /\.m3u8|\.mpd/i.test(s.textContent || '')).length,
              boundGeneration: window.__fluentMediaCapture && window.__fluentMediaCapture.generation,
              readyState: document.readyState,
              playingVideos: Array.from(document.querySelectorAll('video')).filter(v => !v.paused).length,
              failedVideos: Array.from(document.querySelectorAll('video')).filter(v => !!v.error).length
            }))();''',
          );
        });
        final report = <String, Object?>{
          'firstResourceMs': firstResourceMs,
          'firstAssociatedMs': firstAssociatedMs,
          'firstManifestMs': firstManifestMs,
          'players': session.capture.players.length,
          'resources': resources.length,
          'associated': resources.where((r) => r.playerIds.isNotEmpty).length,
          'hls': resources.where((r) => r.kind == WebMediaKind.hls).length,
          'dash': resources.where((r) => r.kind == WebMediaKind.dash).length,
          'authenticated': resources
              .where((r) => r.headers.containsKey('cookie'))
              .length,
          'pageStructure': structure,
        };
        binding.reportData = {'runtimeCapture': report};
        debugPrint('RUNTIME_MEDIA_CAPTURE ${jsonEncode(report)}');
        expect(
          resources,
          isNotEmpty,
          reason: 'No media discovered within the validation window',
        );
        expect(
          firstManifestMs,
          greaterThan(0),
          reason: 'No adaptive stream discovered',
        );
        expect(
          firstAssociatedMs,
          greaterThan(0),
          reason: 'No media associated with a player',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(session.dispose);
        service.dispose();
      }
    },
    skip: !Platform.isWindows || input.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _RuntimeSession extends WebMediaBrowserSession {
  _RuntimeSession(this.profile) : super(retainOnExit: true);
  final String profile;
  @override
  Future<void> prepare() async {
    environment ??= await WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: profile,
        additionalBrowserArguments: await BrowserNetworkPolicy.windowsArguments(
          NetworkScope.other,
        ),
      ),
    );
  }
}
