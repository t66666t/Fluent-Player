import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../../utils/ffmpeg_utils.dart';
import 'media_cache_backend.dart';

abstract final class MediaCacheMediaTools {
  static Future<File> mux(
    File video,
    File audio,
    File output,
    CancelToken cancel,
  ) async {
    cancel.throwIfCancellationRequested();
    final args = [
      '-nostdin',
      '-y',
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
      output.path,
    ];
    return _execute(args, output, cancel);
  }

  static Future<File> joinSegments(
    List<File> segments,
    List<int> durationsMs,
    File output,
    CancelToken cancel,
  ) async {
    cancel.throwIfCancellationRequested();
    if (segments.isEmpty || segments.length != durationsMs.length) {
      throw const FormatException('缺少可合并的媒体分片');
    }
    final manifest = File(p.join(output.parent.path, 'segments.ffconcat'));
    final text = StringBuffer('ffconcat version 1.0\n');
    for (var i = 0; i < segments.length; i++) {
      final path = segments[i].absolute.path.replaceAll('\\', '/');
      if (path.contains('\n') || path.contains('\r')) {
        throw const FormatException('媒体分片路径无法识别');
      }
      text.writeln("file '${path.replaceAll("'", "'\\''")}'");
      if (durationsMs[i] > 0) {
        text.writeln('duration ${(durationsMs[i] / 1000).toStringAsFixed(3)}');
      }
    }
    await manifest.writeAsString(text.toString(), flush: true);
    return _execute(
      [
        '-nostdin',
        '-y',
        '-f',
        'concat',
        '-safe',
        '0',
        '-i',
        manifest.path,
        '-map',
        '0:v:0?',
        '-map',
        '0:a:0?',
        '-c',
        'copy',
        '-movflags',
        '+faststart',
        output.path,
      ],
      output,
      cancel,
    );
  }

  static Future<File> _execute(
    List<String> args,
    File output,
    CancelToken cancel,
  ) async {
    cancel.throwIfCancellationRequested();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final process = await Process.start(await FFmpegUtils.ffmpegPath, args);
      final drain = process.stdout.drain<void>();
      final errors = process.stderr.drain<void>();
      cancel.whenCancel.then((_) => process.kill());
      final code = await process.exitCode.timeout(
        const Duration(minutes: 6),
        onTimeout: () {
          process.kill();
          throw TimeoutException('缓存合并超时，断点已保留');
        },
      );
      await Future.wait([drain, errors]);
      cancel.throwIfCancellationRequested();
      if (code != 0) throw const FormatException('音视频合并失败，已保留完整分片');
    } else {
      final done = Completer<void>();
      final session = await FFmpegKit.executeWithArgumentsAsync(args, (
        finished,
      ) async {
        final code = await finished.getReturnCode();
        if (done.isCompleted) return;
        if (ReturnCode.isSuccess(code)) {
          done.complete();
        } else {
          done.completeError(const FormatException('音视频合并失败，分片已保留'));
        }
      });
      cancel.whenCancel.then((_) => FFmpegKit.cancel(session.getSessionId()));
      await done.future.timeout(
        const Duration(minutes: 6),
        onTimeout: () async {
          await FFmpegKit.cancel(session.getSessionId());
          throw TimeoutException('缓存合并超时，断点已保留');
        },
      );
      cancel.throwIfCancellationRequested();
    }
    return output;
  }

  static Future<void> verify(
    File file, {
    required bool audioOnly,
    int? expectedDurationMs,
    required CancelToken cancel,
  }) async {
    cancel.throwIfCancellationRequested();
    Map<String, dynamic> info;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final process = await Process.start(await FFmpegUtils.ffprobePath, [
        '-v',
        'error',
        '-show_streams',
        '-show_format',
        '-of',
        'json',
        file.path,
      ]);
      final text = utf8.decoder.bind(process.stdout).join();
      final errors = process.stderr.drain<void>();
      cancel.whenCancel.then((_) => process.kill());
      final code = await process.exitCode.timeout(
        const Duration(seconds: 25),
        onTimeout: () {
          process.kill();
          throw TimeoutException('缓存文件校验超时');
        },
      );
      await errors;
      cancel.throwIfCancellationRequested();
      if (code != 0) throw const FormatException('缓存文件无法解码，已保留下载数据');
      info = Map<String, dynamic>.from(jsonDecode(await text) as Map);
    } else {
      final session = await FFprobeKit.getMediaInformation(
        file.path,
      ).timeout(const Duration(seconds: 25));
      final media = session.getMediaInformation();
      if (media == null) throw const FormatException('缓存文件无法识别');
      info = Map<String, dynamic>.from(media.getAllProperties() ?? {});
    }
    final streams = (info['streams'] as List? ?? []).whereType<Map>().toList();
    if (audioOnly
        ? !streams.any((s) => s['codec_type'] == 'audio')
        : !streams.any((s) => s['codec_type'] == 'video')) {
      throw const FormatException('缓存文件缺少所需的媒体轨道');
    }
    final duration = double.tryParse(
      '${(info['format'] as Map?)?['duration'] ?? ''}',
    );
    if (expectedDurationMs != null &&
        expectedDurationMs > 15000 &&
        duration != null &&
        duration * 1000 < expectedDurationMs * .8) {
      throw const FormatException('下载内容明显短于原媒体，未将其标记为完整缓存');
    }
    cancel.throwIfCancellationRequested();
  }
}
