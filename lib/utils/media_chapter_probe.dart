import 'dart:async';
import 'dart:convert';
import '../debug/developer_log.dart' as developer;
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import '../models/media_chapter.dart';
import 'ffmpeg_utils.dart';

class MediaChapterProbe {
  static const Duration _timeout = Duration(seconds: 15);

  static Future<List<MediaChapter>> probe(
    String mediaPath, {
    int durationMs = 0,
  }) async {
    final file = File(mediaPath);
    if (!await file.exists()) return const <MediaChapter>[];

    try {
      final chapters = _supportsCli
          ? await _probeWithCli(mediaPath)
          : await _probeWithKit(mediaPath);
      return MediaChapter.normalize(chapters, durationMs: durationMs);
    } catch (error, stackTrace) {
      developer.log(
        'Probe media chapters failed: $mediaPath',
        error: error,
        stackTrace: stackTrace,
        name: 'media.chapter_probe',
      );
      return const <MediaChapter>[];
    }
  }

  static bool get _supportsCli =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  static Future<List<MediaChapter>> _probeWithCli(String mediaPath) async {
    final ffprobePath = await FFmpegUtils.ffprobePath;
    final process = await Process.start(ffprobePath, <String>[
      '-v',
      'error',
      '-show_chapters',
      '-of',
      'json',
      mediaPath,
    ]);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(_timeout);
    } on TimeoutException {
      process.kill();
      await stdoutFuture.timeout(
        const Duration(seconds: 1),
        onTimeout: () => '',
      );
      await stderrFuture.timeout(
        const Duration(seconds: 1),
        onTimeout: () => '',
      );
      return const <MediaChapter>[];
    }
    final stdoutText = await stdoutFuture;
    await stderrFuture;
    if (exitCode != 0 || stdoutText.trim().isEmpty) {
      return const <MediaChapter>[];
    }
    final decoded = jsonDecode(stdoutText);
    if (decoded is! Map) return const <MediaChapter>[];
    return _parseRawChapters(decoded['chapters']);
  }

  static Future<List<MediaChapter>> _probeWithKit(String mediaPath) async {
    var timedOut = false;
    final completer = Completer<dynamic>();
    final runningSession = await FFprobeKit.getMediaInformationAsync(
      mediaPath,
      (session) {
        if (!timedOut && !completer.isCompleted) completer.complete(session);
      },
    );
    dynamic session;
    try {
      session = await completer.future.timeout(_timeout);
    } on TimeoutException {
      timedOut = true;
      await runningSession.cancel();
      return const <MediaChapter>[];
    }
    final returnCode = await session.getReturnCode();
    final information = session.getMediaInformation();
    if (!ReturnCode.isSuccess(returnCode) || information == null) {
      return const <MediaChapter>[];
    }
    return information.getChapters().map<MediaChapter>((chapter) {
      final tags = chapter.getTags();
      return MediaChapter(
        title: (tags?['title'] ?? tags?['TITLE'] ?? '').toString().trim(),
        startMs: _secondsToMilliseconds(chapter.getStartTime()),
        endMs: _secondsToMilliseconds(chapter.getEndTime()),
      );
    }).toList();
  }

  static List<MediaChapter> _parseRawChapters(Object? value) {
    return (value as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map>()
        .map((raw) => Map<String, dynamic>.from(raw))
        .map((raw) {
          final tags = raw['tags'] is Map
              ? Map<String, dynamic>.from(raw['tags'] as Map)
              : const <String, dynamic>{};
          return MediaChapter(
            title: (tags['title'] ?? tags['TITLE'] ?? '').toString().trim(),
            startMs: _secondsToMilliseconds(raw['start_time']),
            endMs: _secondsToMilliseconds(raw['end_time']),
          );
        })
        .toList();
  }

  static int _secondsToMilliseconds(Object? value) {
    final seconds = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return seconds == null ? 0 : (seconds * 1000).round();
  }
}
