import 'dart:io';

import 'package:path/path.dart' as p;

/// Moves a received resource onto its permanent path.
///
/// Failures throw. The previous temporary path is never returned as success,
/// because a later cleanup of that directory would publish an empty card.
class FolderMediaCommitter {
  const FolderMediaCommitter();

  Future<String> commitFile({
    required String sourcePath,
    required Directory permanentDirectory,
    int? expectedLength,
    String? reservedFileName,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('原文件不存在', sourcePath);
    }
    final length = await source.length();
    if (expectedLength != null && length != expectedLength) {
      throw FileSystemException('原文件长度不符', sourcePath);
    }
    await permanentDirectory.create(recursive: true);
    final normalizedSource = p.normalize(source.path);
    if (p.isWithin(permanentDirectory.path, normalizedSource)) {
      await _requireReadable(source, length);
      return normalizedSource;
    }
    final destination = File(
      p.join(
        permanentDirectory.path,
        _safeFileName(reservedFileName ?? p.basename(source.path)),
      ),
    );
    if (await destination.exists()) {
      throw FileSystemException('永久路径已被占用', destination.path);
    }
    try {
      await source.rename(destination.path);
    } catch (_) {
      // Cross-volume rename fails. Stream onto a sibling .part so a crash
      // cannot leave a short file at the permanent name.
      final partial = File('${destination.path}.part');
      if (await partial.exists()) await partial.delete();
      final input = await source.open();
      final output = await partial.open(mode: FileMode.write);
      try {
        while (true) {
          final bytes = await input.read(1024 * 1024);
          if (bytes.isEmpty) break;
          await output.writeFrom(bytes);
        }
        await output.flush();
      } catch (_) {
        await output.close();
        if (await partial.exists()) await partial.delete();
        rethrow;
      } finally {
        await input.close();
        try {
          await output.close();
        } catch (_) {}
      }
      if (!await partial.exists() || await partial.length() != length) {
        if (await partial.exists()) await partial.delete();
        throw FileSystemException('原文件复制不完整', sourcePath);
      }
      await partial.rename(destination.path);
      if (await source.exists()) {
        try {
          await source.delete();
        } catch (_) {
          // The permanent copy is already verified. A leftover temp file is
          // owned by the task cleanup, not by the published card.
        }
      }
    }
    if (!await destination.exists() || await destination.length() != length) {
      throw FileSystemException('原文件未能保存到本机', destination.path);
    }
    if (!p.isWithin(permanentDirectory.path, destination.path)) {
      throw FileSystemException('原文件仍在可清理目录', destination.path);
    }
    await _requireReadable(destination, length);
    return destination.path;
  }

  Future<void> _requireReadable(File file, int length) async {
    final opened = await file.open();
    try {
      if (length > 0) await opened.read(1);
    } finally {
      await opened.close();
    }
  }

  String _safeFileName(String name) {
    var base = p.basename(name).trim().replaceAll(
      RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
      '_',
    );
    final extension = _safeExtension(base);
    var stem = p.basenameWithoutExtension(base);
    if (stem.isEmpty ||
        stem == '.' ||
        stem == '..' ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$',
          caseSensitive: false,
        ).hasMatch(stem)) {
      stem = 'media';
    }
    if (stem.length > 80) stem = stem.substring(0, 80);
    return '$stem$extension';
  }

  String _safeExtension(String name) {
    final ext = p.extension(name).toLowerCase();
    if (RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(ext)) return ext;
    return '';
  }
}
