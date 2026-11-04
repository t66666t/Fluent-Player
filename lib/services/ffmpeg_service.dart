import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;

import '../utils/ffmpeg_progress.dart';
import '../utils/ffmpeg_utils.dart';

class FFmpegService {
  static final FFmpegService _instance = FFmpegService._internal();
  factory FFmpegService() => _instance;
  FFmpegService._internal();

  final List<Future<void> Function()> _queue = [];
  int _activeTasks = 0;
  int _maxConcurrency = 2;

  void setConcurrency(int count) => _maxConcurrency = count;

  Future<void> mergeVideo({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    Duration duration = Duration.zero,
    required void Function(double) onProgress,
    required void Function(bool success, String? error) onComplete,
  }) async {
    _queue.add(
      () => _executeMerge(
        videoPath,
        audioPath,
        outputPath,
        duration,
        onProgress,
        onComplete,
      ),
    );
    _processQueue();
  }

  void _processQueue() {
    while (_activeTasks < _maxConcurrency && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _activeTasks++;
      unawaited(
        task().whenComplete(() {
          _activeTasks--;
          _processQueue();
        }),
      );
    }
  }

  Future<void> _executeMerge(
    String videoPath,
    String audioPath,
    String outputPath,
    Duration duration,
    void Function(double) onProgress,
    void Function(bool, String?) onComplete,
  ) async {
    final partial = File(
      p.join(
        p.dirname(outputPath),
        '${p.basenameWithoutExtension(outputPath)}.part${p.extension(outputPath)}',
      ),
    );
    final progress = FfmpegProgress(duration: duration, onProgress: onProgress);
    String? failure;
    try {
      await partial.parent.create(recursive: true);
      onProgress(0);
      final args = [
        '-nostdin',
        '-y',
        '-i',
        videoPath,
        '-i',
        audioPath,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c',
        'copy',
        partial.path,
      ];
      if (FFmpegUtils.useDesktopProcessFfmpeg) {
        await FFmpegUtils.ensureAvailable();
        final process = await Process.start(await FFmpegUtils.ffmpegPath, [
          '-progress',
          'pipe:1',
          '-nostats',
          ...args,
        ]);
        final stdoutDone = process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .forEach(progress.readLine);
        final stderr = process.stderr
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .map((line) {
              progress.readLine(line);
              return line;
            })
            .join('\n');
        final code = await process.exitCode;
        await stdoutDone;
        final logs = await stderr;
        if (code != 0) throw StateError(logs);
      } else {
        final completed = Completer<bool>();
        await FFmpegKit.executeWithArgumentsAsync(
          args,
          (session) async {
            completed.complete(
              ReturnCode.isSuccess(await session.getReturnCode()),
            );
          },
          (log) => progress.readLine(log.getMessage()),
          (statistics) =>
              progress.update(Duration(milliseconds: statistics.getTime())),
        );
        if (!await completed.future) throw StateError('FFmpeg 合并失败');
      }
      if (await partial.length() < 16) throw StateError('合并没有生成完整文件');
      await partial.rename(outputPath);
      onProgress(1);
    } catch (error) {
      failure = error.toString();
    } finally {
      if (await partial.exists()) await partial.delete();
    }
    onComplete(failure == null, failure);
  }
}
