import 'dart:convert';
import 'dart:io';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/utils/ffmpeg_utils.dart';

class EmbeddedSubtitleTrack {
  final int index;
  final String title;
  final String language;
  final String codecName;

  EmbeddedSubtitleTrack({
    required this.index,
    required this.title,
    required this.language,
    required this.codecName,
  });
}

class _EmbeddedSubtitleCacheEntry {
  final int size;
  final DateTime modifiedAt;
  final List<EmbeddedSubtitleTrack> tracks;

  const _EmbeddedSubtitleCacheEntry({
    required this.size,
    required this.modifiedAt,
    required this.tracks,
  });
}

class EmbeddedSubtitleService extends ChangeNotifier {
  final Map<String, _EmbeddedSubtitleCacheEntry> _trackCache =
      <String, _EmbeddedSubtitleCacheEntry>{};
  final Map<String, Future<List<EmbeddedSubtitleTrack>>> _inFlightProbes =
      <String, Future<List<EmbeddedSubtitleTrack>>>{};

  String _languageLabel(String? language) {
    if (language == null) return "未知语言";
    final normalized = language.toLowerCase().replaceAll('_', '-').trim();
    if (normalized.isEmpty || normalized == 'und' || normalized == 'unknown') {
      return "未知语言";
    }
    if (normalized == 'chi' ||
        normalized == 'zho' ||
        normalized.startsWith('zh')) {
      return "中文";
    }
    if (normalized == 'en' || normalized == 'eng') return "English";
    if (normalized == 'ja' || normalized == 'jpn') return "日本語";
    if (normalized == 'ko' || normalized == 'kor') return "한국어";
    if (normalized == 'fr' || normalized == 'fra' || normalized == 'fre') {
      return "Français";
    }
    if (normalized == 'de' || normalized == 'deu' || normalized == 'ger') {
      return "Deutsch";
    }
    if (normalized == 'es' || normalized == 'spa') return "Español";
    if (normalized == 'ru' || normalized == 'rus') return "Русский";
    if (normalized == 'it' || normalized == 'ita') return "Italiano";
    if (normalized == 'pt' || normalized == 'por') return "Português";
    if (normalized == 'ar' || normalized == 'ara') return "العربية";
    return normalized.toUpperCase();
  }

  /// 获取视频文件中的内嵌字幕流信息
  Future<List<EmbeddedSubtitleTrack>> getEmbeddedSubtitles(
    String videoPath,
  ) async {
    final normalizedPath = p.normalize(videoPath);
    final cacheKey = Platform.isWindows
        ? normalizedPath.toLowerCase()
        : normalizedPath;
    late final FileStat stat;
    try {
      stat = await File(normalizedPath).stat();
      if (stat.type != FileSystemEntityType.file) {
        return const <EmbeddedSubtitleTrack>[];
      }
      final cached = _trackCache[cacheKey];
      if (cached != null &&
          cached.size == stat.size &&
          cached.modifiedAt == stat.modified) {
        return List<EmbeddedSubtitleTrack>.from(cached.tracks);
      }
    } on FileSystemException {
      return const <EmbeddedSubtitleTrack>[];
    }

    final existingProbe = _inFlightProbes[cacheKey];
    if (existingProbe != null) {
      return List<EmbeddedSubtitleTrack>.from(await existingProbe);
    }

    final probe = _probeEmbeddedSubtitles(normalizedPath);
    _inFlightProbes[cacheKey] = probe;
    try {
      final tracks = await probe;
      _trackCache[cacheKey] = _EmbeddedSubtitleCacheEntry(
        size: stat.size,
        modifiedAt: stat.modified,
        tracks: List<EmbeddedSubtitleTrack>.from(tracks),
      );
      return List<EmbeddedSubtitleTrack>.from(tracks);
    } finally {
      _inFlightProbes.remove(cacheKey);
    }
  }

  Future<List<EmbeddedSubtitleTrack>> _probeEmbeddedSubtitles(
    String videoPath,
  ) async {
    if (FFmpegUtils.preferSystemFfmpeg) {
      return _getEmbeddedSubtitlesWindows(videoPath);
    }

    List<EmbeddedSubtitleTrack> tracks = [];

    try {
      // 优化：使用 executeAsync 配合 Completer，或者直接使用 Future.wait 来避免主线程阻塞
      // FFprobeKit.getMediaInformation 本身是异步的，应该不会阻塞 UI。
      // 但解析大文件元数据可能耗时。

      final session = await FFprobeKit.getMediaInformation(videoPath);
      final info = session.getMediaInformation();

      if (info == null) {
        debugPrint("FFprobe failed to get media info for $videoPath");
        return [];
      }

      final streams = info.getStreams();
      for (var stream in streams) {
        if (stream.getType() == "subtitle") {
          final props = stream.getAllProperties();
          final index = stream.getIndex();

          if (index == null) continue; // Skip if index is missing

          // 尝试获取元数据
          String title = "未知标题";
          String language = "未知语言";
          String codec = stream.getCodec() ?? "unknown";

          if (props != null) {
            if (props['tags'] != null) {
              final tags = props['tags'];
              if (tags is Map) {
                final titleValue =
                    tags['title'] ?? tags['handler_name'] ?? tags['name'];
                if (titleValue != null &&
                    titleValue.toString().trim().isNotEmpty) {
                  title = titleValue.toString();
                }
                final languageValue = tags['language'];
                if (languageValue != null &&
                    languageValue.toString().trim().isNotEmpty) {
                  language = languageValue.toString();
                }
              }
            }
          }

          final displayLanguage = _languageLabel(language);
          final displayTitle =
              (title.trim().isEmpty || title == "未知标题") &&
                  displayLanguage != "未知语言"
              ? displayLanguage
              : title;
          tracks.add(
            EmbeddedSubtitleTrack(
              index: index,
              title: displayTitle,
              language: displayLanguage,
              codecName: codec,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint("Error probing subtitles: $e");
    }

    return tracks;
  }

  Future<List<EmbeddedSubtitleTrack>> _getEmbeddedSubtitlesWindows(
    String videoPath,
  ) async {
    try {
      final mediaKitTracks = await _getEmbeddedSubtitlesWindowsViaMediaKit(
        videoPath,
      );
      if (mediaKitTracks.isNotEmpty) {
        return mediaKitTracks;
      }

      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      final result = await Process.run(
        ffmpegPath,
        ['-hide_banner', '-nostdin', '-i', videoPath],
        stdoutEncoding: null,
        stderrEncoding: null,
      ).timeout(const Duration(seconds: 15));
      final output =
          '${_decodeProcessOutput(result.stdout)}\n${_decodeProcessOutput(result.stderr)}';
      return _parseWindowsSubtitleTracksFromFfmpeg(output);
    } catch (e) {
      debugPrint("Error probing subtitles: $e");
      return [];
    }
  }

  Future<List<EmbeddedSubtitleTrack>> _getEmbeddedSubtitlesWindowsViaMediaKit(
    String videoPath,
  ) async {
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(osc: false, libass: false),
    );

    try {
      await player.open(Media(videoPath), play: false);

      final tracks = await _waitForWindowsSubtitleTracks(player);
      final subtitleTracks = tracks.subtitle.where((track) {
        return track.id != 'auto' &&
            track.id != 'no' &&
            !track.uri &&
            !track.data;
      }).toList();

      if (subtitleTracks.isEmpty) {
        return [];
      }

      final List<EmbeddedSubtitleTrack> result = [];
      for (int i = 0; i < subtitleTracks.length; i++) {
        final track = subtitleTracks[i];
        final language = _languageLabel(track.language);
        final rawTitle = (track.title ?? '').trim();
        final displayTitle = rawTitle.isEmpty && language != '未知语言'
            ? language
            : (rawTitle.isEmpty ? '未知标题' : rawTitle);
        result.add(
          EmbeddedSubtitleTrack(
            index: i,
            title: displayTitle,
            language: language,
            codecName: (track.codec ?? 'unknown').trim(),
          ),
        );
      }
      return result;
    } catch (e) {
      debugPrint('MediaKit subtitle probe failed: $e');
      return [];
    } finally {
      await player.dispose();
    }
  }

  Future<Tracks> _waitForWindowsSubtitleTracks(Player player) async {
    final currentTracks = player.state.tracks;
    if (currentTracks.subtitle.length > 2) {
      return currentTracks;
    }

    try {
      return await player.stream.tracks
          .firstWhere((tracks) => tracks.subtitle.length > 2)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => player.state.tracks,
          );
    } catch (_) {
      return player.state.tracks;
    }
  }

  /// 提取指定索引的字幕流
  /// 返回提取后的文件路径
  Future<String?> extractSubtitle(
    String videoPath,
    int streamIndex,
    String outputDir, {
    String? codecName,
    String? videoId,
  }) async {
    try {
      // 构造输出文件名
      final videoName = p.basenameWithoutExtension(videoPath);

      String extension = ".srt";
      String codec = codecName ?? "unknown";

      // 如果未提供 codec，则尝试探测
      if (codec == "unknown") {
        if (FFmpegUtils.preferSystemFfmpeg) {
          codec =
              await _probeSubtitleCodecWindows(videoPath, streamIndex) ??
              "unknown";
        } else {
          final probeSession = await FFprobeKit.getMediaInformation(videoPath);
          final info = probeSession.getMediaInformation();
          if (info != null) {
            final streams = info.getStreams();
            for (var stream in streams) {
              if (stream.getIndex() == streamIndex) {
                codec = stream.getCodec() ?? "unknown";
                break;
              }
            }
          }
        }
      }

      if (codec == "hdmv_pgs_subtitle") {
        extension = ".sup";
      } else if (codec == "dvd_subtitle") {
        // 将 DVD Subtitle 转码为 PGS (.sup) 以便统一解析
        extension = ".sup";
      } else if (codec == "ass" || codec == "ssa") {
        extension = ".ass";
      }

      final filePrefix = videoId != null && videoId.isNotEmpty
          ? videoId
          : videoName;
      final fileName = "$filePrefix.stream_$streamIndex$extension";
      final outputPath = p.join(outputDir, fileName);
      final outputFile = File(outputPath);

      // 如果文件已存在，直接返回（简单的缓存策略）
      if (await outputFile.exists()) {
        debugPrint("Subtitle already extracted: $outputPath");
        return outputPath;
      }

      // 构造提取命令
      String command;
      if (extension == ".sup") {
        if (codec == "dvd_subtitle") {
          // VobSub -> PGS 转码
          command =
              "-i \"$videoPath\" -map 0:$streamIndex -c:s hdmv_pgs_subtitle \"$outputPath\"";
        } else {
          // PGS: 直接拷贝流
          command =
              "-i \"$videoPath\" -map 0:$streamIndex -c:s copy \"$outputPath\"";
        }
      } else if (extension == ".ass") {
        command = "-i \"$videoPath\" -map 0:$streamIndex \"$outputPath\"";
      } else {
        // 默认尝试转 SRT (text)
        command = "-i \"$videoPath\" -map 0:$streamIndex \"$outputPath\"";
      }

      debugPrint("Executing FFmpeg: $command");

      // Use execute() synchronously to ensure completion before returning.
      // executeAsync caused race conditions if the user clicked multiple times or if UI updated too fast.
      if (FFmpegUtils.preferSystemFfmpeg) {
        await FFmpegUtils.ensureAvailable();
        final ffmpegPath = await FFmpegUtils.ffmpegPath;
        final List<String> args = [];
        args.addAll(['-i', videoPath, '-map', '0:s:$streamIndex']);
        if (extension == ".sup") {
          if (codec == "dvd_subtitle") {
            args.addAll(['-c:s', 'hdmv_pgs_subtitle']);
          } else {
            args.addAll(['-c:s', 'copy']);
          }
        }
        args.add(outputPath);
        final result = await Process.run(
          ffmpegPath,
          args,
          stdoutEncoding: null,
          stderrEncoding: null,
        ).timeout(const Duration(seconds: 60));
        if (result.exitCode == 0) {
          return outputPath;
        }
        final stderrText = _decodeProcessOutput(result.stderr);
        debugPrint("Extraction failed logs: $stderrText");
        return null;
      } else {
        final syncSession = await FFmpegKit.execute(command);
        final returnCode = await syncSession.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          return outputPath;
        } else {
          final logs = await syncSession.getAllLogsAsString();
          debugPrint("Extraction failed logs: $logs");
          return null;
        }
      }
    } catch (e) {
      debugPrint("Error extracting subtitle: $e");
      return null;
    }
  }

  Future<String?> _probeSubtitleCodecWindows(
    String videoPath,
    int streamIndex,
  ) async {
    try {
      final tracks = await _getEmbeddedSubtitlesWindows(videoPath);
      for (final track in tracks) {
        if (track.index == streamIndex) {
          return track.codecName;
        }
      }
    } catch (e) {
      debugPrint("Error probing subtitle codec: $e");
    }
    return null;
  }

  List<EmbeddedSubtitleTrack> _parseWindowsSubtitleTracksFromFfmpeg(
    String output,
  ) {
    if (output.trim().isEmpty) return [];

    final streamPattern = RegExp(
      r'^\s*Stream #\d+:(\d+)(?:\(([^)]+)\))?.*?: Subtitle:\s*([^,\s]+)',
      caseSensitive: false,
    );
    final metadataPattern = RegExp(r'^([A-Za-z0-9_\- ]+)\s*:\s*(.+)$');
    final lines = LineSplitter.split(output).toList();
    final List<_WindowsSubtitleTrackBuffer> buffers = [];
    _WindowsSubtitleTrackBuffer? current;
    bool inMetadataBlock = false;

    for (final line in lines) {
      final streamMatch = streamPattern.firstMatch(line);
      if (streamMatch != null) {
        final index = int.tryParse(streamMatch.group(1) ?? '');
        if (index == null) {
          current = null;
          inMetadataBlock = false;
          continue;
        }
        current = _WindowsSubtitleTrackBuffer(
          index: index,
          codecName: (streamMatch.group(3) ?? 'unknown').trim(),
          title: '',
          language: (streamMatch.group(2) ?? '').trim(),
        );
        buffers.add(current);
        inMetadataBlock = false;
        continue;
      }

      if (current == null) continue;

      final trimmed = line.trim();
      if (trimmed == 'Metadata:') {
        inMetadataBlock = true;
        continue;
      }

      if (!inMetadataBlock) {
        continue;
      }

      final metadataMatch = metadataPattern.firstMatch(trimmed);
      if (metadataMatch == null) {
        if (trimmed.isNotEmpty) {
          inMetadataBlock = false;
        }
        continue;
      }

      final key = metadataMatch.group(1)?.trim().toLowerCase();
      final value = metadataMatch.group(2)?.trim();
      if (key == null || value == null || value.isEmpty) continue;
      if ((key == 'title' || key == 'handler_name' || key == 'name') &&
          current.title.isEmpty) {
        current.title = value;
      } else if (key == 'language' && current.language.isEmpty) {
        current.language = value;
      }
    }

    return buffers.map((buffer) {
      final rawLanguage = buffer.language.isEmpty ? '未知语言' : buffer.language;
      final displayLanguage = _languageLabel(rawLanguage);
      final rawTitle = buffer.title.isEmpty ? '未知标题' : buffer.title;
      final displayTitle =
          (rawTitle == '未知标题' || rawTitle.trim().isEmpty) &&
              displayLanguage != '未知语言'
          ? displayLanguage
          : rawTitle;
      return EmbeddedSubtitleTrack(
        index: buffer.index,
        title: displayTitle,
        language: displayLanguage,
        codecName: buffer.codecName,
      );
    }).toList();
  }

  String _decodeProcessOutput(dynamic output) {
    if (output == null) return '';
    if (output is String) return output;
    if (output is List<int>) {
      try {
        return utf8.decode(output);
      } catch (_) {
        try {
          return gbk.decode(output);
        } catch (_) {
          return '';
        }
      }
    }
    return output.toString();
  }
}

class _WindowsSubtitleTrackBuffer {
  final int index;
  final String codecName;
  String title;
  String language;

  _WindowsSubtitleTrackBuffer({
    required this.index,
    required this.codecName,
    this.title = '',
    this.language = '',
  });
}
