import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../../utils/ffmpeg_utils.dart';
import '../../utils/ffmpeg_progress.dart';

/// Merge only already-downloaded local files. No account headers or remote URLs
/// are passed to FFmpeg, and audio is selected explicitly from the matching work.
class DouyinAudioMuxer {
  DouyinAudioMuxer({this.ffmpegExecutable});
  final String? ffmpegExecutable;
  Duration duration = Duration.zero;
  void Function(double)? onProgress;
  Process? _process;
  int? _sessionId;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _process?.kill();
    final id = _sessionId;
    if (id != null) unawaited(FFmpegKit.cancel(id));
  }

  Future<void> merge(File video, File audio, File output) async {
    if (_cancelled) throw StateError('已取消');
    final progress = FfmpegProgress(
      duration: duration,
      onProgress: (value) => onProgress?.call(value),
    );
    onProgress?.call(0);
    final args = [
      '-nostdin',
      '-y',
      '-v',
      'error',
      '-i',
      video.path,
      '-i',
      audio.path,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0',
      '-c',
      'copy',
      '-movflags',
      '+faststart',
      '-f',
      'mp4',
      output.path,
    ];
    if (FFmpegUtils.useDesktopProcessFfmpeg) {
      final process = await Process.start(
        ffmpegExecutable ?? await FFmpegUtils.ffmpegPath,
        ['-progress', 'pipe:1', '-nostats', ...args],
      );
      _process = process;
      if (_cancelled) process.kill();
      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(progress.readLine);
      final stderrDone = process.stderr.drain<void>();
      try {
        final code = await process.exitCode.timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
        if (_cancelled || code != 0) throw StateError('合并音轨失败');
        await stdoutDone;
        await stderrDone;
      } finally {
        _process = null;
      }
    } else {
      final completed = Completer<bool>();
      final session = await FFmpegKit.executeWithArgumentsAsync(
        args,
        (session) async {
          if (!completed.isCompleted) {
            completed.complete(
              ReturnCode.isSuccess(await session.getReturnCode()),
            );
          }
        },
        (_) {},
        (statistics) =>
            progress.update(Duration(milliseconds: statistics.getTime())),
      );
      _sessionId = session.getSessionId();
      if (_cancelled) await FFmpegKit.cancel(_sessionId);
      try {
        final ok = await completed.future.timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            cancel();
            return false;
          },
        );
        if (_cancelled || !ok) throw StateError('合并音轨失败');
      } finally {
        _sessionId = null;
      }
    }
    onProgress?.call(1);
  }
}
