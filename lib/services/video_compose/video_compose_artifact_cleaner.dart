import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

class VideoComposeArtifactCleaner {
  final Map<String, Set<String>> _taskArtifactPaths = <String, Set<String>>{};

  Set<String> taskArtifactPaths(String taskId) =>
      Set.unmodifiable(_taskArtifactPaths[taskId] ?? const <String>{});

  void trackTaskArtifact(String taskId, String filePath) {
    if (filePath.trim().isEmpty) return;
    _taskArtifactPaths.putIfAbsent(taskId, () => <String>{}).add(filePath);
  }

  Future<bool> cleanupTaskArtifacts(
    String taskId, {
    bool deleteOutput = false,
    String? outputPath,
  }) async {
    final String? normalizedOutputPath = outputPath?.trim();
    final Set<String> paths = <String>{};
    final Set<String>? tracked = _taskArtifactPaths.remove(taskId);
    if (tracked != null) {
      for (final String path in tracked) {
        final String trimmed = path.trim();
        if (trimmed.isEmpty) continue;
        if (normalizedOutputPath != null &&
            normalizedOutputPath.isNotEmpty &&
            p.equals(trimmed, normalizedOutputPath)) {
          continue;
        }
        paths.add(trimmed);
      }
    }
    for (final String path in paths) {
      await deleteFileWithRetry(path);
    }
    if (deleteOutput &&
        normalizedOutputPath != null &&
        normalizedOutputPath.isNotEmpty) {
      return deleteOutputFileByPlatform(normalizedOutputPath);
    }
    return true;
  }

  Future<bool> deleteOutputFileByPlatform(String outputPath) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return deleteMobileComposeOutputs(outputPath);
    }
    return _deleteOutputFileWithRetry(outputPath);
  }

  Future<bool> deleteMobileComposeOutputs(String outputPath) async {
    final String normalizedOutputPath = _normalizeOutputPath(outputPath);
    if (normalizedOutputPath.isEmpty) return true;
    final outputType = await FileSystemEntity.type(
      normalizedOutputPath,
      followLinks: false,
    );
    if (outputType != FileSystemEntityType.file &&
        outputType != FileSystemEntityType.notFound) {
      return false;
    }
    final Set<String> candidates = <String>{normalizedOutputPath};
    final RegExp? pattern = buildComposeOutputPattern(normalizedOutputPath);
    final Directory parent = Directory(p.dirname(normalizedOutputPath));
    if (pattern != null && await parent.exists()) {
      await for (final FileSystemEntity entity in parent.list(
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final String name = p.basename(entity.path);
        if (!pattern.hasMatch(name)) continue;
        final String normalizedPath = _normalizeOutputPath(entity.path);
        if (normalizedPath.isEmpty) continue;
        candidates.add(normalizedPath);
      }
    }
    bool allDeleted = true;
    for (final String candidate in candidates) {
      final bool deleted = await _deleteOutputFileWithRetry(candidate);
      if (!deleted) {
        allDeleted = false;
      }
    }
    for (final String candidate in candidates) {
      if (await FileSystemEntity.type(candidate, followLinks: false) !=
          FileSystemEntityType.notFound) {
        allDeleted = false;
      }
    }
    return allDeleted;
  }

  String _normalizeOutputPath(String path) {
    if (path.trim().isEmpty) return '';
    // Resolve lexical segments, never a link to somebody else's file/directory.
    return p.absolute(p.normalize(path.trim()));
  }

  Future<bool> _deleteOutputFileWithRetry(String outputPath) async {
    final path = _normalizeOutputPath(outputPath);
    if (path.isEmpty) return true;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        final type = await FileSystemEntity.type(path, followLinks: false);
        if (type == FileSystemEntityType.notFound) return true;
        if (type != FileSystemEntityType.file) return false;
        // File.delete cannot recursively remove a directory if another actor
        // replaces the checked path before deletion. Tracked staging keeps
        // its separate, explicitly owned directory cleanup below.
        await File(path).delete();
        if (await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          return true;
        }
      } on FileSystemException {
        // Preserve the task and allow retry when a reader keeps the file open.
      }
      if (attempt < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 320));
      }
    }
    return await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.notFound;
  }

  RegExp? buildComposeOutputPattern(String outputPath) {
    final String fileName = p.basename(outputPath);
    final Match? match = RegExp(
      r'^(.*)_compose_(\d+)(\.[^.]*)?$',
    ).firstMatch(fileName);
    if (match == null) return null;
    final String titlePart = RegExp.escape(match.group(1) ?? '');
    final String composeId = RegExp.escape(match.group(2) ?? '');
    if (titlePart.isEmpty || composeId.isEmpty) return null;
    return RegExp('^${titlePart}_compose_$composeId(\\.[^.]+)?\$');
  }

  Future<String> normalizeDeletePath(String filePath) async {
    final String trimmed = filePath.trim();
    if (trimmed.isEmpty) return '';
    String normalized = p.normalize(trimmed);
    if (!p.isAbsolute(normalized)) {
      normalized = p.absolute(normalized);
    }
    final File file = File(normalized);
    if (await file.exists()) {
      try {
        normalized = await file.resolveSymbolicLinks();
      } catch (_) {}
    }
    return normalized;
  }

  Future<bool> deleteFileWithRetry(String filePath) async {
    final String normalizedPath = await normalizeDeletePath(filePath);
    if (normalizedPath.isEmpty) return true;
    final Directory directory = Directory(normalizedPath);
    if (await directory.exists()) {
      try {
        await directory.delete(recursive: true);
        return !await directory.exists();
      } catch (_) {
        return false;
      }
    }
    String currentPath = normalizedPath;
    for (int i = 0; i < 5; i++) {
      final File file = File(currentPath);
      try {
        if (!await file.exists()) return true;
        await file.delete();
        if (!await file.exists()) return true;
      } catch (_) {
        try {
          final String renamedPath =
              '$currentPath.__del_${DateTime.now().microsecondsSinceEpoch}';
          final File renamedFile = await file.rename(renamedPath);
          currentPath = renamedPath;
          await renamedFile.delete();
          final bool renamedExists = await File(currentPath).exists();
          final bool originExists = await File(normalizedPath).exists();
          if (!renamedExists && !originExists) return true;
        } catch (_) {}
      }
      final bool originExists = await File(normalizedPath).exists();
      final bool currentExists = await File(currentPath).exists();
      if (!originExists && !currentExists) return true;
      if (i < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 320));
      }
    }
    final bool originExists = await File(normalizedPath).exists();
    final bool currentExists = await File(currentPath).exists();
    return !originExists && !currentExists;
  }
}
