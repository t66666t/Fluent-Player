// Build with: flutter build windows --release --no-pub
// -t scripts/windows_exit_validation.dart
// Reuses the existing isolated paths/preferences/clipboard startup fixture and
// its regular windowManager.close() path. Never launch lib/main.dart to test
// against private production data.
import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:window_manager/window_manager.dart';
import 'package:video_player_app/utils/deferred_subtitle_edits.dart';

import 'isolated_app_startup_profile.dart' as startup;

HeadlessInAppWebView? _webView;

Future<void> main() async {
  await startup.main();
  if (Platform.environment['FLUENT_EXIT_SUBTITLE_MARKER'] == 'true') {
    Timer(const Duration(seconds: 1), () async {
      final root = Platform.environment['FLUENT_PERF_ROOT']!;
      final edits = DeferredSubtitleEdits();
      edits.schedule(const [], (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await File(
          '$root/subtitle-exit-flushed.txt',
        ).writeAsString('saved before normal window close', flush: true);
        stdout.writeln('EXIT AUDIT subtitle marker saved');
      });
      stdout.writeln('EXIT AUDIT subtitle draft pending; requesting close');
      await windowManager.close();
    });
  }
  if (Platform.environment['FLUENT_EXIT_HEADLESS_WEBVIEW'] == 'true') {
    final delayMs =
        int.tryParse(
          Platform.environment['FLUENT_EXIT_WEBVIEW_DELAY_MS'] ?? '',
        ) ??
        1000;
    Timer(Duration(milliseconds: delayMs), () async {
      stdout.writeln('EXIT AUDIT WebView create-start');
      _webView = HeadlessInAppWebView(
        initialData: InAppWebViewInitialData(
          data: '<html><body>Exit validation</body></html>',
        ),
        onWebViewCreated: (_) =>
            stdout.writeln('EXIT AUDIT WebView native-created'),
        onLoadStop: (_, _) => stdout.writeln('EXIT AUDIT WebView loaded'),
      );
      final creation = _webView!.run();
      final closeDelayMs = int.tryParse(
        Platform.environment['FLUENT_EXIT_CLOSE_AFTER_CREATE_MS'] ?? '',
      );
      if (closeDelayMs != null) {
        Timer(Duration(milliseconds: closeDelayMs), () async {
          stdout.writeln('EXIT AUDIT close-request during creation');
          await windowManager.close();
        });
      }
      await creation;
    });
  }
  final mode = Platform.environment['FLUENT_EXIT_FFMPEG_MODE'] ?? 'none';
  if (mode != 'none') {
    Timer(const Duration(seconds: 1), () async {
      await FFmpegKit.executeAsync(
        '-f lavfi -i sine=frequency=1000:sample_rate=16000 -t 0.2 -f null -',
        (session) async {
          stdout.writeln(
            'EXIT AUDIT short completed rc=${await session.getReturnCode()}',
          );
          if (mode == 'active') {
            final longSession = await FFmpegKit.executeAsync(
              '-re -f lavfi -i sine=frequency=200:sample_rate=16000 -t 120 -f null -',
            );
            stdout.writeln(
              'EXIT AUDIT long launched id=${longSession.getSessionId()}',
            );
          }
        },
      );
    });
  }
}
