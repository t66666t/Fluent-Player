import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../utils/subtitle_file_matcher.dart';
import 'settings_service.dart';
import 'subtitle_word_timing_store.dart';

/// One subtitle after its on-screen name has been separated from its file name.
///
/// [displayName] is what the app shows and may repeat ("中文", "中文").
/// [storageKey] is only a map key, so a second copy does not overwrite the first.
class BoundSubtitleLabel {
  final String storageKey;
  final String displayName;
  final String path;

  const BoundSubtitleLabel({
    required this.storageKey,
    required this.displayName,
    required this.path,
  });
}

/// Keeps every file even when several share one display name.
List<BoundSubtitleLabel> bindSubtitleLabels(
  Iterable<({String label, String path})> entries,
) {
  final usedKeys = <String>{};
  final bound = <BoundSubtitleLabel>[];
  for (final entry in entries) {
    final displayName = subtitleDisplayLabel(entry.label);
    var key = displayName;
    if (usedKeys.contains(key)) {
      final baseName = p.basename(entry.path);
      key = baseName;
      var serial = 2;
      while (usedKeys.contains(key)) {
        final extension = p.extension(baseName);
        final stem = p.basenameWithoutExtension(baseName);
        key = '$stem ($serial)$extension';
        serial++;
      }
    }
    usedKeys.add(key);
    bound.add(
      BoundSubtitleLabel(
        storageKey: key,
        displayName: displayName,
        path: entry.path,
      ),
    );
  }
  return bound;
}

/// The name shown in subtitle management. It is not a file name.
String subtitleDisplayLabel(String label) {
  final trimmed = label.trim();
  return trimmed.isEmpty ? '字幕' : trimmed;
}

class TaskSubtitleStorageService {
  final Directory? _dataRootOverride;

  const TaskSubtitleStorageService({Directory? dataRootOverride})
    : _dataRootOverride = dataRootOverride;

  Future<Directory> dataRoot() async {
    return _dataRootOverride ?? SettingsService().resolveLargeDataRootDir();
  }

  Future<Directory> tasksRoot({bool create = false}) async {
    final root = await dataRoot();
    final directory = Directory(p.join(root.path, 'subtitles', 'tasks'));
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<Directory> taskDirectory(String videoId, {bool create = false}) async {
    _validateVideoId(videoId);
    final root = await tasksRoot(create: create);
    final directory = Directory(p.join(root.path, videoId));
    _ensureWithin(root.path, directory.path);
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  Future<bool> isTaskOwnedPath(String path, String videoId) async {
    final directory = await taskDirectory(videoId);
    return _samePath(path, directory.path) || p.isWithin(directory.path, path);
  }

  Future<List<File>> listTaskSubtitles(String videoId) async {
    final directory = await taskDirectory(videoId);
    if (!await directory.exists()) return const <File>[];
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || SubtitleWordTimingStore.isCompanion(entity.path)) continue;
      final extension = p.extension(entity.path).toLowerCase();
      if (SubtitleFileMatcher.supportedExtensions.contains(extension)) {
        files.add(entity);
      }
    }
    return files;
  }

  /// File name inside a card's subtitle folder.
  ///
  /// The folder is already `subtitles/tasks/{videoId}`, so the video title is
  /// not repeated here. The readable label stays in the name for browsing,
  /// and the short id only stops two "中文.srt" files from overwriting each other.
  static String readableSubtitleFileName({
    required String label,
    required String extension,
    String? uniqueId,
  }) {
    var suffix = extension.trim().toLowerCase();
    if (suffix.isEmpty) suffix = '.srt';
    if (!suffix.startsWith('.')) suffix = '.$suffix';
    final safeLabel = _readableStorageLabel(label);
    final id = _shortStorageId(uniqueId);
    return '$safeLabel.$id$suffix';
  }

  static String _readableStorageLabel(String label) {
    var cleaned = label
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (cleaned.length > 80) {
      cleaned = cleaned.substring(0, 80).replaceAll(RegExp(r'[. ]+$'), '');
    }
    return cleaned.isEmpty ? '字幕' : cleaned;
  }

  static String _shortStorageId(String? uniqueId) {
    final raw = (uniqueId ?? const Uuid().v4()).replaceAll('-', '');
    final hex = raw.replaceAll(RegExp(r'[^a-fA-F0-9]'), '');
    if (hex.length >= 8) return hex.substring(0, 8).toLowerCase();
    return '${hex}00000000'.substring(0, 8).toLowerCase();
  }

  Future<String> allocatePath(String videoId, String preferredFileName) async {
    final directory = await taskDirectory(videoId, create: true);
    return allocateInside(directory, preferredFileName);
  }

  /// Next free file name inside [directory]. The caller owns that directory.
  Future<String> allocateInside(
    Directory directory,
    String preferredFileName,
  ) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final safeName = _safeFileName(preferredFileName);
    final extension = p.extension(safeName);
    final stem = p.basenameWithoutExtension(safeName);
    var candidate = p.join(directory.path, safeName);
    var serial = 2;
    while (await File(candidate).exists()) {
      candidate = p.join(directory.path, '$stem.$serial$extension');
      serial++;
    }
    _ensureWithin(directory.path, candidate);
    return candidate;
  }

  Future<String> copyIntoTask(
    String videoId,
    String sourcePath, {
    String? preferredFileName,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('字幕源文件不存在', sourcePath);
    }
    final outputPath = await allocatePath(
      videoId,
      preferredFileName ?? p.basename(sourcePath),
    );
    await source.copy(outputPath);
    final companion = File(SubtitleWordTimingStore.pathFor(sourcePath));
    if (await companion.exists()) {
      await companion.copy(SubtitleWordTimingStore.pathFor(outputPath));
    }
    return outputPath;
  }

  Future<void> deleteTaskDirectory(String videoId) async {
    final root = await tasksRoot();
    final directory = await taskDirectory(videoId);
    _ensureWithin(root.path, directory.path);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<int> taskDirectorySize(String videoId) async {
    final directory = await taskDirectory(videoId);
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } on FileSystemException {
          // A file may disappear while size calculation is in progress.
        }
      }
    }
    return total;
  }

  void _validateVideoId(String videoId) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(videoId)) {
      throw ArgumentError.value(videoId, 'videoId', '非法媒体任务 ID');
    }
  }

  String _safeFileName(String value) {
    final baseName = p.basename(value.trim());
    final sanitized = baseName.replaceAll(
      RegExp(r'[<>:"/\\|?*\x00-\x1F]'),
      '_',
    );
    if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
      throw ArgumentError.value(value, 'preferredFileName', '非法字幕文件名');
    }
    final extension = p.extension(sanitized).toLowerCase();
    if (!SubtitleFileMatcher.supportedExtensions.contains(extension)) {
      throw ArgumentError.value(value, 'preferredFileName', '不支持的字幕格式');
    }
    return sanitized;
  }

  void _ensureWithin(String root, String candidate) {
    if (!_samePath(root, candidate) && !p.isWithin(root, candidate)) {
      throw StateError('字幕路径越过任务目录边界');
    }
  }

  bool _samePath(String first, String second) {
    final left = p.normalize(p.absolute(first));
    final right = p.normalize(p.absolute(second));
    return Platform.isWindows
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
  }
}
