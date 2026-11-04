import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;

import '../features/model_center/inference_resource_governor.dart';
import '../models/ocr_subtitle_models.dart';
import '../utils/ffmpeg_utils.dart';
import 'video_compose/video_compose_probe_service.dart';

class OcrRawFrame {
  const OcrRawFrame({
    required this.path,
    required this.offset,
    required this.width,
    required this.height,
    required this.atMs,
  });
  final String path;
  final int offset, width, height, atMs;
}

class OcrRawChunk {
  OcrRawChunk(
    this.directory,
    this.start,
    this.end,
    this.frames,
    this.extractionMs,
  );
  final Directory directory;
  final Duration start, end;
  final Map<int, List<OcrRawFrame>> frames;
  final int extractionMs;
  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

String buildOcrRawFilter(OcrSubtitleJob job) {
  String crop(OcrSubtitleTrack track, String input) {
    final r = track.region.normalized();
    return '$input${job.mirrorHorizontal ? 'hflip,' : ''}${job.mirrorVertical ? 'vflip,' : ''}'
        'crop=iw*${r.width}:ih*${r.height}:iw*${r.left}:ih*${r.top},'
        'scale=min(640\\,iw):-2:flags=area,fps=10:round=near,setpts=PTS-STARTPTS,'
        'mpdecimate=max=20:keep=1:hi=768:lo=320:frac=0.10,format=rgb24,'
        'showinfo@ocr_${track.number}[out_${track.number}]';
  }

  if (job.tracks.length == 1) return crop(job.tracks.first, '[0:v:0]');
  return '[0:v:0]split=${job.tracks.length}${job.tracks.map((t) => '[in_${t.number}]').join()};'
      '${job.tracks.map((t) => crop(t, '[in_${t.number}]')).join(';')}';
}

/// FFmpeg's per-branch index is paired with exact PTS and dimensions. Missing
/// or inconsistent metadata is an error, never guessed as index * 100 ms.
Map<int, List<OcrRawFrame>> parseOcrRawFrames(
  String logs,
  Directory directory,
  int startMs,
) {
  final pattern = RegExp(
    r'\[showinfo@ocr_(\d+)\s+@[^\]]*\][^\r\n]*?\bn:\s*(\d+)\s+pts:[^\r\n]*?pts_time:([-+\d.eE]+)[^\r\n]*?\bs:(\d+)x(\d+)',
  );
  final result = <int, List<OcrRawFrame>>{};
  final offsets = <int, int>{};
  for (final m in pattern.allMatches(logs)) {
    final track = int.parse(m[1]!), index = int.parse(m[2]!);
    final seconds = double.parse(m[3]!);
    final width = int.parse(m[4]!), height = int.parse(m[5]!);
    final frames = result.putIfAbsent(track, () => []);
    if (!seconds.isFinite ||
        width <= 0 ||
        height <= 0 ||
        index != frames.length) {
      throw const FormatException('OCR 帧索引或尺寸无效');
    }
    final offset = offsets[track] ?? 0;
    frames.add(
      OcrRawFrame(
        path: p.join(directory.path, 'track_$track.rgb'),
        offset: offset,
        width: width,
        height: height,
        atMs: startMs + (seconds * 1000).round(),
      ),
    );
    offsets[track] = offset + width * height * 3;
  }
  return result;
}

int ocrRawChunkMilliseconds({
  required int sourceWidth,
  required int sourceHeight,
  required List<OcrSubtitleTrack> tracks,
  required int bufferBytes,
}) {
  var bytesPerSample = 0;
  for (final track in tracks) {
    final r = track.region.normalized();
    final width = math.max(2, (sourceWidth * r.width).ceil());
    final height = math.max(2, (sourceHeight * r.height).ceil());
    final scaledWidth = math.min(640, width);
    final scaledHeight = (height * scaledWidth / width).ceil() + 2;
    bytesPerSample += scaledWidth * scaledHeight * 3;
  }
  if (bytesPerSample * 2 > bufferBytes) throw StateError('字幕区域过多或过大，请缩小区域后重试');
  // Ten samples/sec; half the byte budget belongs to the look-ahead chunk.
  final frames = bufferBytes ~/ (2 * bytesPerSample);
  return math.min(15000, math.max(100, (frames - 1) * 100));
}

class OcrRawExtractor {
  OcrRawExtractor({
    required this.resources,
    required this.cancelSignal,
    bool? preferSystemFfmpeg,
  }) : _preferSystemFfmpeg =
           preferSystemFfmpeg ?? FFmpegUtils.preferSystemFfmpeg;
  final InferenceResourceSession resources;
  final Future<void> cancelSignal;
  final bool _preferSystemFfmpeg;
  Process? _process;
  FFmpegSession? _session;
  bool _cancelled = false;
  Future<void> cancel() async {
    _cancelled = true;
    _process?.kill();
    await _session?.cancel();
  }

  Stream<OcrRawChunk> chunks(OcrSubtitleJob job, Directory root, {Duration? resumeFrom}) async* {
    // FFmpeg arguments and frame offsets use milliseconds. Use that same
    // precision for termination so a sub-millisecond tail cannot repeat forever.
    var start = Duration(milliseconds: resumeFrom?.inMilliseconds ?? job.start.inMilliseconds);
    final rangeEnd = Duration(milliseconds: job.end.inMilliseconds);
    if (start >= rangeEnd) return;
    late final int width, height;
    if (_preferSystemFfmpeg) {
      final result = await Process.run(await FFmpegUtils.ffprobePath, [
        '-v',
        'error',
        '-select_streams',
        'v:0',
        '-show_entries',
        'stream=width,height:stream_tags=rotate:stream_side_data=rotation',
        '-of',
        'json',
        job.videoPath,
      ]).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) {
        throw StateError('无法读取 OCR 视频尺寸：${result.stderr}');
      }
      final streams =
          (jsonDecode(result.stdout.toString()) as Map)['streams'] as List;
      if (streams.isEmpty) throw StateError('视频没有可识别的视频轨');
      final stream = streams.first as Map;
      final w = (stream['width'] as num).toInt(),
          h = (stream['height'] as num).toInt();
      final side = stream['side_data_list'] as List? ?? const [];
      final rotation =
          side
              .whereType<Map>()
              .where((m) => m['rotation'] != null)
              .firstOrNull?['rotation'] ??
          (stream['tags'] as Map?)?['rotate'] ??
          0;
      final rotated =
          ((num.tryParse(rotation.toString()) ?? 0).round().abs() % 180) == 90;
      width = rotated ? h : w;
      height = rotated ? w : h;
    } else {
      final probe = await const VideoComposeProbeService(
        preferSystemFfmpeg: false,
      ).probeVideoInfo(
        job.videoPath,
      );
      width = math.max(probe.width, probe.displayWidth);
      height = math.max(probe.height, probe.displayHeight);
    }
    final mobile = Platform.isAndroid || Platform.isIOS;
    final budget = (mobile ? 64 : 128) * 1024 * 1024;
    final chunkMs = ocrRawChunkMilliseconds(
      sourceWidth: width,
      sourceHeight: height,
      tracks: job.tracks,
      bufferBytes: budget,
    );
    OcrRawChunk? current;
    Future<({OcrRawChunk? chunk, Object? error, StackTrace? stack})>? next;
    Future<({OcrRawChunk? chunk, Object? error, StackTrace? stack})> fetch(
      Duration at, {
      bool first = false,
    }) {
      final end = Duration(
        milliseconds: math.min(
          rangeEnd.inMilliseconds,
          at.inMilliseconds + (first ? math.min(5000, chunkMs) : chunkMs),
        ),
      );
      return _extract(job, at, end, root).then(
        (chunk) => (chunk: chunk, error: null, stack: null),
        onError: (Object e, StackTrace s) => (chunk: null, error: e, stack: s),
      );
    }

    unawaited(cancelSignal.then((_) => cancel()));
    try {
      final firstLength = math.min(5000, chunkMs);
      final resumed = start.inMilliseconds - job.start.inMilliseconds;
      if (resumed < 0 || (resumed != 0 && start < rangeEnd &&
          (resumed < firstLength || (resumed - firstLength) % chunkMs != 0))) {
        throw StateError('OCR 恢复位置不在原抽帧段边界');
      }
      next = fetch(start, first: resumed == 0);
      while (start < rangeEnd) {
        final outcome = await next!;
        next = null;
        if (outcome.error != null) {
          Error.throwWithStackTrace(outcome.error!, outcome.stack!);
        }
        current = outcome.chunk!;
        start = current.end;
        if (start < rangeEnd && resources.decision.allowAudioPrefetch) {
          next = fetch(start);
        }
        yield current;
        await current.dispose();
        current = null;
        if (start < rangeEnd) next ??= fetch(start);
      }
    } finally {
      await cancel();
      await current?.dispose();
      if (next != null) await (await next).chunk?.dispose();
    }
  }

  Future<OcrRawChunk> _extract(
    OcrSubtitleJob job,
    Duration start,
    Duration end,
    Directory root,
  ) => resources.run(InferenceLane.videoDecode, (permit) async {
    if (_cancelled) throw StateError('OCR 抽帧已取消');
    if ((end - start).inMilliseconds <= 0) {
      throw StateError('OCR 抽帧时间范围无效');
    }
    // Each extraction owns its directory, including concurrent prefetches.
    final directory = await root.createTemp('raw_${start.inMilliseconds}_');
    final watch = Stopwatch()..start();
    final args = [
      '-hide_banner',
      '-loglevel',
      'info',
      '-nostats',
      '-y',
      '-ss',
      (start.inMilliseconds / 1000).toStringAsFixed(3),
      '-t',
      ((end - start).inMilliseconds / 1000).toStringAsFixed(3),
      '-threads',
      '1',
      '-i',
      job.videoPath,
      '-filter_complex_threads',
      '1',
      '-filter_complex',
      buildOcrRawFilter(job),
      for (final track in job.tracks) ...[
        '-map',
        '[out_${track.number}]',
        '-an',
        '-fps_mode',
        'vfr',
        '-threads',
        '1',
        '-pix_fmt',
        'rgb24',
        '-f',
        'rawvideo',
        p.join(directory.path, 'track_${track.number}.rgb'),
      ],
    ];
    String logs;
    try {
      if (_preferSystemFfmpeg) {
        await FFmpegUtils.ensureAvailable();
        if (_cancelled) throw StateError('OCR 抽帧已取消');
        final process = await Process.start(await FFmpegUtils.ffmpegPath, args);
        _process = process;
        final releasePid = InferenceProcessRegistry.instance.retain(
          process.pid,
        );
        try {
          final stdout = process.stdout.drain<void>();
          final stderr = process.stderr.transform(utf8.decoder).join();
          final exit = await process.exitCode;
          await stdout;
          logs = await stderr;
          if (exit != 0 || _cancelled) {
            throw StateError(
              _cancelled
                  ? 'OCR 抽帧已取消'
                  : 'OCR 抽帧失败：${logs.length > 1500 ? logs.substring(logs.length - 1500) : logs}',
            );
          }
        } finally {
          _process = null;
          releasePid();
        }
      } else {
        final done = Completer<FFmpegSession>();
        _session = await FFmpegKit.executeWithArgumentsAsync(
          args,
          done.complete,
        );
        if (_cancelled) await _session?.cancel();
        final session = await done.future;
        final code = await session.getReturnCode();
        logs = await session.getAllLogsAsString() ?? '';
        _session = null;
        if (!ReturnCode.isSuccess(code) || _cancelled) {
          throw StateError(_cancelled ? 'OCR 抽帧已取消' : 'OCR 抽帧失败：$logs');
        }
      }
      final frames = parseOcrRawFrames(logs, directory, start.inMilliseconds);
      var totalBytes = 0;
      for (final track in job.tracks) {
        final values = frames.putIfAbsent(track.number, () => []);
        final file = File(p.join(directory.path, 'track_${track.number}.rgb'));
        final expected = values.isEmpty
            ? 0
            : values.last.offset + values.last.width * values.last.height * 3;
        if ((await file.exists() ? await file.length() : 0) != expected) {
          throw StateError('OCR 原始帧与时间戳数量不一致');
        }
        totalBytes += expected;
      }
      final halfBudget =
          (Platform.isAndroid || Platform.isIOS ? 32 : 64) * 1024 * 1024;
      if (totalBytes > halfBudget) throw StateError('OCR 原始帧超出暂存预算，请缩小区域后重试');
      return OcrRawChunk(
        directory,
        start,
        end,
        frames,
        watch.elapsedMilliseconds,
      );
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }, cancelSignal: cancelSignal);
}
