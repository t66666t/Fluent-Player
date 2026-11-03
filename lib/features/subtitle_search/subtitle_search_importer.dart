import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/managed_subtitle_asset.dart';
import '../../services/library_service.dart';
import '../../services/task_subtitle_storage_service.dart';
import 'subtitle_search_models.dart';

class SubtitleSearchImporter {
  const SubtitleSearchImporter();

  Future<String> save({
    required LibraryService library,
    required String videoId,
    required SubtitleSearchImportRequest request,
    String? existingPath,
  }) async {
    if (library.getVideo(videoId) == null) throw StateError('当前视频已从媒体库移除');
    final identity = request.document.contentHash;
    if (identity.isNotEmpty) {
      final previous = library
          .getVideo(videoId)
          ?.managedSubtitleAssets
          .where(
            (asset) =>
                asset.contentHash == identity &&
                asset.offsetMs == request.offsetMs &&
                asset.entryId == request.document.entryId,
          )
          .firstOrNull;
      if (previous != null && await File(previous.path).exists()) {
        return previous.path;
      }
    }
    if (existingPath != null &&
        library.managedSubtitleAssetForPath(videoId, existingPath) != null &&
        await File(existingPath).exists()) {
      return existingPath;
    }
    if (!{'.srt', '.vtt', '.ass', '.ssa'}.contains(request.extension) ||
        request.document.cues.isEmpty) {
      throw const FormatException('这个文件没有可导入的文本字幕');
    }
    final languages = request.document.languages;
    final language = languages.isNotEmpty
        ? languages.join('+')
        : _specificSourceLanguage(request.hit.language);
    final label =
        '${p.basenameWithoutExtension(request.document.name)} · ${request.hit.source.label}';
    final path = await library.allocateSubtitleFile(
      videoId,
      TaskSubtitleStorageService.readableSubtitleFileName(
        label: label,
        extension: request.extension,
      ),
    );
    final partial = File('$path.partial');
    try {
      await partial.writeAsString(request.content, flush: true);
      if (await File(path).exists()) await File(path).delete();
      await partial.rename(path);
      final asset = await library.registerManagedSubtitleAsset(
        videoId,
        path: path,
        kind: ManagedSubtitleAssetKind.downloaded,
        displayName: label,
        language: language,
        contentHash: identity.isEmpty ? null : identity,
        sourceLabel: request.hit.source.label,
        entryId: request.document.entryId.isEmpty
            ? null
            : request.document.entryId,
        offsetMs: request.offsetMs,
      );
      if (asset == null) throw StateError('当前视频已从媒体库移除');
      return path;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      if (library.managedSubtitleAssetForPath(videoId, path) == null &&
          await File(path).exists()) {
        await File(path).delete();
      }
      rethrow;
    }
  }

  /// Roles are explicit; replacing the primary keeps a different secondary.
  static List<String> selectedPaths(
    List<String> current,
    String path,
    SubtitleSearchImportRole role,
  ) {
    switch (role) {
      case SubtitleSearchImportRole.saveOnly:
        return List.of(current);
      case SubtitleSearchImportRole.primary:
        final secondary = current.length > 1 ? current[1] : null;
        return [path, if (secondary != null && secondary != path) secondary];
      case SubtitleSearchImportRole.secondary:
        if (current.isEmpty) throw StateError('请先选择一条主字幕，再添加副字幕');
        if (current.first == path) throw StateError('这条字幕已是主字幕，请选择另一条作为副字幕');
        return [current.first, path];
    }
  }
}

/// Package-wide labels such as "双语" are not a language for one file.
String? _specificSourceLanguage(String value) {
  final text = value.trim();
  if (text.isEmpty || text.contains('/') || text.contains('双语')) return null;
  return text;
}
