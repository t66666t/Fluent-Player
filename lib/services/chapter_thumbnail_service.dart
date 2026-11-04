import 'package:video_player_app/services/network/network_http.dart';
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/media_chapter.dart';
import '../utils/serial_task_queue.dart';
import 'settings_service.dart';
import 'video_preview_service.dart';

class ChapterThumbnailService {
  ChapterThumbnailService._();

  static final ChapterThumbnailService instance = ChapterThumbnailService._();
  static final SerialTaskQueue _generationQueue = SerialTaskQueue();

  final Map<String, Future<String?>> _inFlight = <String, Future<String?>>{};
  final Set<String> _deletedVideoIds = <String>{};

  Future<String?> getOrCreate({
    required String videoId,
    required String videoPath,
    required int chapterIndex,
    required MediaChapter chapter,
  }) async {
    final safeVideoId = _safeVideoId(videoId);
    if (_deletedVideoIds.contains(safeVideoId)) return null;
    final directory = await _videoDirectory(safeVideoId, create: true);
    final output = File(
      p.join(
        directory.path,
        '${chapterIndex.toString().padLeft(4, '0')}_${chapter.startMs}.image',
      ),
    );
    if (await _isUsable(output)) return output.path;

    final key = output.path;
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final operation = _generationQueue.enqueue<String?>(() async {
      if (_deletedVideoIds.contains(safeVideoId)) return null;
      if (await _isUsable(output)) return output.path;

      var bytes = await _downloadSourceThumbnail(chapter.sourceThumbnailUrl);
      bytes ??= await VideoPreviewService().requestPrecisePreview(
        videoPath,
        _thumbnailTimeMs(chapter),
      );
      if (bytes == null ||
          bytes.isEmpty ||
          _deletedVideoIds.contains(safeVideoId)) {
        return null;
      }
      await output.writeAsBytes(bytes, flush: true);
      if (_deletedVideoIds.contains(safeVideoId)) {
        if (await output.exists()) await output.delete();
        return null;
      }
      return output.path;
    });
    _inFlight[key] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_inFlight[key], operation)) _inFlight.remove(key);
    }
  }

  Future<void> deleteForVideo(String videoId) async {
    final safeVideoId = _safeVideoId(videoId);
    _deletedVideoIds.add(safeVideoId);
    final directory = await _videoDirectory(safeVideoId);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<int> directorySize(String videoId) async {
    final directory = await _videoDirectory(_safeVideoId(videoId));
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // A lazily generated file may disappear during permanent deletion.
        }
      }
    }
    return total;
  }

  Future<Directory> _videoDirectory(
    String safeVideoId, {
    bool create = false,
  }) async {
    final root = await SettingsService().resolveLargeDataRootDir();
    final thumbnailsRoot = Directory(p.join(root.path, 'chapter_thumbnails'));
    final directory = Directory(p.join(thumbnailsRoot.path, safeVideoId));
    if (!p.isWithin(thumbnailsRoot.path, directory.path)) {
      throw StateError('章节缩略图路径越界');
    }
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<List<int>?> _downloadSourceThumbnail(String? sourceUrl) async {
    final rawUrl = sourceUrl?.trim();
    if (rawUrl == null || rawUrl.isEmpty) return null;
    final normalizedUrl = rawUrl.startsWith('//') ? 'https:$rawUrl' : rawUrl;
    final parsedUri = Uri.tryParse(normalizedUrl);
    final uri =
        parsedUri != null &&
            parsedUri.isScheme('http') &&
            parsedUri.host.toLowerCase().endsWith('hdslb.com')
        ? parsedUri.replace(scheme: 'https')
        : parsedUri;
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }

    HttpClient? client;
    try {
      client = NetworkHttp.instance.createClient(scope: NetworkScope.bilibili)
        ..connectionTimeout = const Duration(seconds: 5);
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 6));
      request.headers.set('Referer', 'https://www.bilibili.com/');
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final bytes = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            if (buffer.length + chunk.length > 6 * 1024 * 1024) {
              throw const FileSystemException('章节缩略图过大');
            }
            buffer.addAll(chunk);
            return buffer;
          })
          .timeout(const Duration(seconds: 10));
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  int _thumbnailTimeMs(MediaChapter chapter) {
    final offset = (chapter.duration.inMilliseconds * 0.08).round();
    final safeOffset = offset.clamp(180, 1200);
    return (chapter.startMs + safeOffset).clamp(
      chapter.startMs,
      chapter.endMs - 1,
    );
  }

  Future<bool> _isUsable(File file) async {
    try {
      return await file.exists() && await file.length() > 0;
    } on FileSystemException {
      return false;
    }
  }

  String _safeVideoId(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw ArgumentError.value(value, 'videoId', '非法媒体 ID');
    }
    return safe;
  }
}
