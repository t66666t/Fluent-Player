import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path/path.dart' as p;

import '../../utils/ffmpeg_utils.dart';
import 'lyric_search_models.dart';

class LyricMediaMetadata {
  const LyricMediaMetadata({
    this.title = '',
    this.artist = '',
    this.album = '',
  });
  final String title;
  final String artist;
  final String album;

  static LyricMediaMetadata fromProbeJson(Object? raw) {
    if (raw is! Map) return const LyricMediaMetadata();
    final format = raw['format'];
    final groups = <Map>[
      if (format is Map && format['tags'] is Map) format['tags'] as Map,
      if (raw['streams'] is List)
        for (final stream in (raw['streams'] as List).whereType<Map>())
          if (stream['codec_type'] == 'audio' && stream['tags'] is Map)
            stream['tags'] as Map,
    ];
    final tags = <String, String>{};
    for (final group in groups) {
      for (final entry in group.entries) {
        final value = entry.value;
        if (value is String && value.trim().isNotEmpty) {
          tags.putIfAbsent(
            entry.key.toString().toLowerCase(),
            () => value.trim(),
          );
        }
      }
    }
    String first(List<String> names) => names
        .map((name) => tags[name] ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    return LyricMediaMetadata(
      title: first(['title']),
      artist: first([
        'artist',
        'album_artist',
        'albumartist',
        'author',
        'performer',
        'composer',
      ]),
      album: first(['album']),
    );
  }

  static String filename(String path, String fallback) {
    if (path.isEmpty || path.contains('://') || path.startsWith('content:')) {
      return LyricSearchQuery.fileStem(fallback);
    }
    return LyricSearchQuery.fileStem(p.basename(path));
  }
}

class LyricMediaMetadataProbe {
  static const _timeout = Duration(seconds: 6);

  static Future<LyricMediaMetadata> probe(String path) async {
    // Probe local files only: metadata discovery never downloads media.
    if (path.isEmpty ||
        path.contains('://') ||
        path.startsWith('content:') ||
        !await File(path).exists()) {
      return const LyricMediaMetadata();
    }
    try {
      return FFmpegUtils.useDesktopProcessFfmpeg
          ? await _desktop(path)
          : await _mobile(path);
    } catch (_) {
      // Missing tags/tools must leave the filename search fully usable.
      return const LyricMediaMetadata();
    }
  }

  static Future<LyricMediaMetadata> _desktop(String path) async {
    final executable = await FFmpegUtils.ffprobePath.timeout(_timeout);
    final process = await Process.start(executable, [
      '-v',
      'error',
      '-show_entries',
      'format_tags:stream=codec_type:stream_tags',
      '-of',
      'json',
      path,
    ]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    try {
      final code = await process.exitCode.timeout(_timeout);
      final text = await output;
      await errors;
      return code == 0
          ? LyricMediaMetadata.fromProbeJson(jsonDecode(text))
          : const LyricMediaMetadata();
    } on TimeoutException {
      process.kill();
      // Drain pipes before returning so a timed out probe cannot block playback.
      await Future.wait([
        output,
        errors,
      ]).timeout(const Duration(seconds: 1), onTimeout: () => []);
      return const LyricMediaMetadata();
    }
  }

  static Future<LyricMediaMetadata> _mobile(String path) async {
    final done = Completer<dynamic>();
    var timedOut = false;
    final session = await FFprobeKit.getMediaInformationAsync(path, (result) {
      if (!timedOut && !done.isCompleted) done.complete(result);
    });
    try {
      final result = await done.future.timeout(_timeout);
      if (!ReturnCode.isSuccess(await result.getReturnCode())) {
        return const LyricMediaMetadata();
      }
      final info = result.getMediaInformation();
      return LyricMediaMetadata.fromProbeJson({
        'format': {'tags': info?.getTags()},
        'streams': [
          for (final stream in info?.getStreams() ?? [])
            {'codec_type': stream.getType(), 'tags': stream.getTags()},
        ],
      });
    } on TimeoutException {
      timedOut = true;
      await session.cancel();
      return const LyricMediaMetadata();
    }
  }
}
