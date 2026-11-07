import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/local_filesystem_path.dart';
import '../utils/supported_media_extensions.dart';
import 'community_media_input.dart';

const batchImportSubtitleExtensions = {
  '.srt',
  '.vtt',
  '.lrc',
  '.ass',
  '.ssa',
  '.sup',
  '.sub',
  '.idx',
  '.scc',
};

const batchImportMediaExtensions = {
  ...kSupportedVideoExtensions,
  ...kSupportedAudioExtensions,
};

class BatchImportFiles {
  final media = <String>[];
  final subtitles = <String>[];
  final archives = <String>[];
  int ignored = 0;
  int duplicates = 0;
  int failedArchives = 0;
}

String _identity(String path) => Platform.isWindows ? path.toLowerCase() : path;

/// Both pickers and desktop drops use this local-only classifier. Each column
/// retains input order; ZIP entries occupy their position in the subtitle list.
/// Directories and unknown extensions are ignored rather than traversed.
Future<BatchImportFiles> collectBatchImportFiles(
  Iterable<String> paths, {
  Iterable<String> existingMedia = const [],
  Iterable<String> existingSubtitles = const [],
  Iterable<String> existingArchives = const [],
  required Future<List<String>> Function(String) extractSubtitleArchive,
}) async {
  final result = BatchImportFiles();
  final seen = {
    for (final path in [
      ...existingMedia,
      ...existingSubtitles,
      ...existingArchives,
    ])
      _identity(p.normalize(path)),
  };

  Future<void> add(String rawPath, {bool fromArchive = false}) async {
    if (!communityMediaIsLocal(rawPath)) {
      result.ignored++;
      return;
    }
    final path = normalizeLocalFilesystemPath(rawPath);
    if (path == null) {
      result.ignored++;
      return;
    }
    final extension = p.extension(path).toLowerCase();
    final isSubtitle = batchImportSubtitleExtensions.contains(extension);
    final isMedia =
        !fromArchive && batchImportMediaExtensions.contains(extension);
    final isArchive = !fromArchive && extension == '.zip';
    if (!isSubtitle && !isMedia && !isArchive) {
      result.ignored++;
      return;
    }
    final identity = _identity(path);
    if (seen.contains(identity)) {
      result.duplicates++;
      return;
    }
    try {
      if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
        result.ignored++;
        return;
      }
    } on FileSystemException {
      result.ignored++;
      return;
    }
    seen.add(identity);
    if (isArchive) {
      try {
        final extracted = await extractSubtitleArchive(path);
        for (final subtitle in extracted) {
          await add(subtitle, fromArchive: true);
        }
        result.archives.add(path);
      } catch (_) {
        result.failedArchives++;
      }
    } else if (isSubtitle) {
      result.subtitles.add(path);
    } else {
      result.media.add(path);
    }
  }

  for (final path in paths) {
    await add(path);
  }
  return result;
}
