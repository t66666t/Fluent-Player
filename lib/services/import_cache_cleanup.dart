import 'dart:io';

import 'package:path/path.dart' as p;

/// Releases only the exact picker copy after the library snapshot is durable.
/// Never invokes file_picker's directory-wide cache clearing.
Future<bool> releaseVerifiedImportCacheCopy({
  required String sourcePath,
  required String persistedPath,
  required List<Directory> cacheRoots,
  required bool scopedRoots,
  required bool Function(String path) isReferenced,
}) async {
  String key(String path) => Platform.isWindows
      ? p.normalize(p.absolute(path)).toLowerCase()
      : p.normalize(p.absolute(path));
  if (key(sourcePath) == key(persistedPath) || isReferenced(sourcePath)) {
    return false;
  }
  final roots = cacheRoots
      .where((dir) => p.isWithin(key(dir.path), key(sourcePath)))
      .toList();
  if (roots.isEmpty) return false;
  if (scopedRoots &&
      !roots.any(
        (dir) => {
          'file_picker',
          'image_picker',
          'incoming_media',
        }.contains(p.split(p.relative(sourcePath, from: dir.path)).first),
      )) {
    return false;
  }
  try {
    final source = File(sourcePath);
    final persisted = File(persistedPath);
    if (await FileSystemEntity.type(sourcePath, followLinks: false) !=
            FileSystemEntityType.file ||
        await FileSystemEntity.type(persistedPath, followLinks: false) !=
            FileSystemEntityType.file) {
      return false;
    }
    final realSource = await source.resolveSymbolicLinks();
    final realPersisted = await persisted.resolveSymbolicLinks();
    if (key(realSource) == key(realPersisted)) return false;
    var safeRoot = false;
    for (final root in roots) {
      final realRoot = await root.resolveSymbolicLinks();
      final expectedSource = p.join(
        realRoot,
        p.relative(sourcePath, from: root.path),
      );
      if (key(expectedSource) == key(realSource) &&
          p.isWithin(key(realRoot), key(realSource))) {
        safeRoot = true;
      }
    }
    if (!safeRoot) return false;
    final initial = await source.stat();
    if (initial.size != await persisted.length()) return false;
    final beforeDelete = await source.stat();
    if (initial.size != beforeDelete.size ||
        initial.modified != beforeDelete.modified ||
        initial.changed != beforeDelete.changed ||
        isReferenced(sourcePath)) {
      return false;
    }
    await source.delete();
    return !await source.exists();
  } on FileSystemException {
    return false;
  }
}
