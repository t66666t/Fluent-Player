import 'dart:async';
import 'dart:convert';
import '../debug/developer_log.dart' as developer;
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/media_information_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';

import 'ffmpeg_utils.dart';

class MediaDurationProbe {
  static Future<void> _reportDebugEvent(
    String hypothesisId,
    String location,
    String msg, {
    Map<String, Object?>? data,
  }) async {
    if (!kDebugMode) return;
    try {
      final client = HttpClient();
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:7777/event'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'sessionId': 'bilibili-export-crash',
          'runId': 'pre-fix',
          'hypothesisId': hypothesisId,
          'location': location,
          'msg': '[DEBUG] $msg',
          'data': data ?? <String, Object?>{},
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await request.close();
      client.close(force: true);
    } catch (_) {}
  }

  static Future<int> probeDurationMs(
    String mediaPath, {
    bool allowVideoPlayerFallback = true,
  }) async {
    try {
      final file = File(mediaPath);
      if (!await file.exists()) {
        return 0;
      }

      int durationMs = 0;

      if (_shouldUseCliProbeFirst) {
        durationMs = await _probeWithFfprobeCli(mediaPath);
      } else {
        durationMs = await _probeWithFfprobeKit(mediaPath);
      }
      // #region debug-point D:probe-cli-result
      unawaited(
        _reportDebugEvent(
          'D',
          'media_duration_probe.dart:probeDurationMs',
          'Primary duration probe completed',
          data: <String, Object?>{
            'mediaPath': mediaPath,
            'durationMs': durationMs,
            'usedCliFirst': _shouldUseCliProbeFirst,
          },
        ),
      );
      // #endregion
      if (durationMs > 0) {
        return durationMs;
      }

      if (_supportsCliProbe && !_shouldUseCliProbeFirst) {
        durationMs = await _probeWithFfprobeCli(mediaPath);
        if (durationMs > 0) {
          return durationMs;
        }
      }

      if (!allowVideoPlayerFallback) {
        return 0;
      }

      // #region debug-point D:probe-fallback-videoplayer
      unawaited(
        _reportDebugEvent(
          'D',
          'media_duration_probe.dart:probeDurationMs',
          'Falling back to VideoPlayer duration probe',
          data: <String, Object?>{
            'mediaPath': mediaPath,
            'platform': Platform.operatingSystem,
          },
        ),
      );
      // #endregion
      return await _probeWithVideoPlayer(file);
    } catch (e) {
      developer.log('Probe media duration failed: $mediaPath', error: e);
      return 0;
    }
  }

  static bool get _shouldUseCliProbeFirst =>
      Platform.isWindows || Platform.isLinux;

  static bool get _supportsCliProbe =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<int> _probeWithFfprobeKit(String mediaPath) async {
    MediaInformationSession? runningSession;
    var timedOut = false;
    try {
      final completer = Completer<MediaInformationSession>();
      runningSession = await FFprobeKit.getMediaInformationAsync(mediaPath, (
        session,
      ) {
        if (!timedOut && !completer.isCompleted) {
          completer.complete(session);
        }
      });
      late MediaInformationSession session;
      try {
        session = await completer.future.timeout(const Duration(seconds: 12));
      } on TimeoutException {
        timedOut = true;
        await runningSession.cancel();
        developer.log('FFprobeKit duration probe timed out: $mediaPath');
        return 0;
      }
      final info = session.getMediaInformation();
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode) || info == null) {
        return 0;
      }

      final durationStr = info.getDuration();
      final durationSec = double.tryParse(durationStr ?? '');
      if (durationSec == null || durationSec <= 0) {
        return 0;
      }
      return (durationSec * 1000).round();
    } catch (e) {
      developer.log('FFprobeKit duration probe failed: $mediaPath', error: e);
      return 0;
    }
  }

  static Future<int> _probeWithFfprobeCli(String mediaPath) async {
    try {
      final ffprobePath = await FFmpegUtils.ffprobePath;
      final process = await Process.start(ffprobePath, [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        mediaPath,
      ]);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      late int exitCode;
      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: 12));
      } on TimeoutException {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {}
        await stdoutFuture.timeout(
          const Duration(seconds: 1),
          onTimeout: () => '',
        );
        await stderrFuture.timeout(
          const Duration(seconds: 1),
          onTimeout: () => '',
        );
        developer.log('CLI ffprobe duration probe timed out: $mediaPath');
        return 0;
      }
      final stdoutText = await stdoutFuture;
      await stderrFuture;
      if (exitCode != 0) {
        return 0;
      }
      final durationSec = double.tryParse(stdoutText.trim());
      if (durationSec == null || durationSec <= 0) {
        return 0;
      }
      return (durationSec * 1000).round();
    } catch (e) {
      developer.log('CLI ffprobe duration probe failed: $mediaPath', error: e);
      return 0;
    }
  }

  static Future<int> _probeWithVideoPlayer(File file) async {
    VideoPlayerController? controller;
    try {
      // #region debug-point D:videoplayer-probe-start
      unawaited(
        _reportDebugEvent(
          'D',
          'media_duration_probe.dart:_probeWithVideoPlayer',
          'VideoPlayer duration probe starting',
          data: <String, Object?>{'mediaPath': file.path},
        ),
      );
      // #endregion
      controller = AppVideoPlayerController.file(file);
      await controller.initialize().timeout(const Duration(seconds: 15));
      final duration = controller.value.duration;
      // #region debug-point D:videoplayer-probe-end
      unawaited(
        _reportDebugEvent(
          'D',
          'media_duration_probe.dart:_probeWithVideoPlayer',
          'VideoPlayer duration probe finished',
          data: <String, Object?>{
            'mediaPath': file.path,
            'durationMs': duration.inMilliseconds,
          },
        ),
      );
      // #endregion
      if (duration <= Duration.zero) {
        return 0;
      }
      return duration.inMilliseconds;
    } catch (e) {
      developer.log(
        'VideoPlayer duration probe failed: ${file.path}',
        error: e,
      );
      return 0;
    } finally {
      if (controller != null) {
        try {
          await controller.dispose().timeout(const Duration(seconds: 5));
        } catch (_) {
          // Best effort cleanup.
        }
      }
    }
  }
}
