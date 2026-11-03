import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../models/bilibili_video_shot.dart';
import '../settings_service.dart';
import 'bilibili_api_service.dart';

class BilibiliVideoShotService {
  BilibiliVideoShotService._();

  static final BilibiliVideoShotService instance = BilibiliVideoShotService._();

  static const String directoryName = 'bilibili_videoshots';
  static const int _maxSpriteBytes = 20 * 1024 * 1024;
  static const int _maxSpriteCount = 64;

  Future<BilibiliVideoShot?> downloadForCard({
    required BilibiliApiService apiService,
    required String videoId,
    required String bvid,
    required int cid,
    Directory? dataRootOverride,
  }) async {
    if (videoId.trim().isEmpty || bvid.trim().isEmpty || cid <= 0) return null;
    final data = await apiService.fetchVideoShot(bvid.trim(), cid);
    if (data == null) return null;

    final columns = (data['img_x_len'] as num?)?.toInt() ?? 0;
    final rows = (data['img_y_len'] as num?)?.toInt() ?? 0;
    final cellWidth = (data['img_x_size'] as num?)?.toInt() ?? 0;
    final cellHeight = (data['img_y_size'] as num?)?.toInt() ?? 0;
    if (columns <= 0 || rows <= 0 || cellWidth <= 0 || cellHeight <= 0) {
      return null;
    }

    final urls = (data['image'] as List? ?? const <dynamic>[])
        .map((value) => _normalizeSpriteUri(value.toString()))
        .whereType<Uri>()
        .take(_maxSpriteCount)
        .toList(growable: false);
    if (urls.isEmpty) return null;

    final rawIndex = (data['index'] as List? ?? const <dynamic>[])
        .map(
          (value) =>
              value is num ? value.toInt() : int.tryParse(value.toString()),
        )
        .whereType<int>()
        .where((value) => value >= 0)
        .toList(growable: false);
    // Bilibili's first zero is a sentinel; the second zero is the timestamp of
    // the first actual frame. Removing exactly one element aligns cell N with
    // timestamp N, matching the web player's sprite-selection logic.
    final timestamps = rawIndex.isEmpty
        ? const <int>[]
        : rawIndex.skip(1).toList(growable: false);
    final maxFrames = urls.length * columns * rows;
    final usableTimestamps = timestamps.take(maxFrames).toList(growable: false);
    if (usableTimestamps.isEmpty) return null;

    final directory = await _videoDirectory(
      videoId,
      dataRootOverride: dataRootOverride,
      create: true,
      replaceExisting: true,
    );
    final savedPaths = <String>[];
    try {
      for (var index = 0; index < urls.length; index++) {
        final response = await apiService.dio.get<List<int>>(
          urls[index].toString(),
          options: Options(responseType: ResponseType.bytes),
        );
        final bytes = response.data;
        if (bytes == null || bytes.isEmpty || bytes.length > _maxSpriteBytes) {
          throw const FileSystemException('Invalid Bilibili video-shot sprite');
        }
        final extension = _safeImageExtension(urls[index].path);
        final destination = File(
          p.join(
            directory.path,
            'sprite_${index.toString().padLeft(3, '0')}$extension',
          ),
        );
        final temporary = File('${destination.path}.download');
        await temporary.writeAsBytes(bytes, flush: true);
        await _commitSpriteFile(temporary, destination);
        savedPaths.add(destination.path);
      }
    } catch (_) {
      if (await directory.exists()) await directory.delete(recursive: true);
      return null;
    }

    return BilibiliVideoShot(
      spritePaths: List<String>.unmodifiable(savedPaths),
      timestampsSeconds: List<int>.unmodifiable(usableTimestamps),
      columns: columns,
      rows: rows,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
    );
  }

  Future<void> deleteForVideo(
    String videoId, {
    Directory? dataRootOverride,
  }) async {
    final directory = await _videoDirectory(
      videoId,
      dataRootOverride: dataRootOverride,
    );
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<int> directorySize(
    String videoId, {
    Directory? dataRootOverride,
  }) async {
    final directory = await _videoDirectory(
      videoId,
      dataRootOverride: dataRootOverride,
    );
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      try {
        total += await entity.length();
      } on FileSystemException {
        // 单个截图文件不可读时跳过，不影响总量统计。
      }
    }
    return total;
  }

  Future<Directory> _videoDirectory(
    String videoId, {
    Directory? dataRootOverride,
    bool create = false,
    bool replaceExisting = false,
  }) async {
    final root =
        dataRootOverride ?? await SettingsService().resolveLargeDataRootDir();
    final parent = Directory(p.join(root.path, directoryName));
    final safeVideoId = _safeVideoId(videoId);
    final directory = Directory(p.join(parent.path, safeVideoId));
    if (!p.isWithin(parent.path, directory.path)) {
      throw StateError('Bilibili video-shot path escapes its storage root');
    }
    if (replaceExisting && await directory.exists()) {
      await directory.delete(recursive: true);
    }
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<void> _commitSpriteFile(File temporary, File destination) async {
    try {
      if (await destination.exists()) await destination.delete();
      await temporary.rename(destination.path);
    } catch (_) {
      // Windows rename fails when the destination is locked or the move crosses
      // a volume. Copy still publishes the sprite.
      await temporary.copy(destination.path);
      try {
        await temporary.delete();
      } catch (_) {}
    }
  }

  Uri? _normalizeSpriteUri(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parsed = Uri.tryParse(
      trimmed.startsWith('//') ? 'https:$trimmed' : trimmed,
    );
    if (parsed == null || parsed.host.isEmpty) return null;
    final uri = parsed.isScheme('http')
        ? parsed.replace(scheme: 'https')
        : parsed;
    if (!uri.isScheme('https')) return null;
    final host = uri.host.toLowerCase();
    if (host != 'hdslb.com' &&
        !host.endsWith('.hdslb.com') &&
        host != 'bilivideo.com' &&
        !host.endsWith('.bilivideo.com')) {
      return null;
    }
    return uri;
  }

  String _safeImageExtension(String path) {
    final extension = p.extension(path).toLowerCase();
    return const <String>{'.jpg', '.jpeg', '.png', '.webp'}.contains(extension)
        ? extension
        : '.jpg';
  }

  String _safeVideoId(String value) {
    final safe = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.isEmpty || safe == '.' || safe == '..') {
      throw ArgumentError.value(value, 'videoId', 'Invalid media id');
    }
    return safe;
  }
}
