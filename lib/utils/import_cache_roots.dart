import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Includes both iOS temporary locations: path_provider returns Library/Caches,
/// while older incoming shares and file_picker use the container's tmp folder.
/// Resolve the latter from Documents, never from the movable metadata root.
Future<List<Directory>> resolveImportCacheRoots({
  TargetPlatform? platform,
}) async {
  final target = platform ?? defaultTargetPlatform;
  final roots = <Directory>[];
  try {
    roots.add(await getTemporaryDirectory());
  } catch (_) {}
  if (target == TargetPlatform.android) {
    try {
      roots.addAll(await getExternalCacheDirectories() ?? []);
    } catch (_) {}
  }
  if (target == TargetPlatform.iOS) {
    try {
      final documents = await getApplicationDocumentsDirectory();
      roots.add(Directory(p.join(documents.parent.path, 'tmp')));
    } catch (_) {}
  }
  final unique = <String, Directory>{};
  for (final root in roots) {
    unique[p.normalize(root.path)] = root;
  }
  return unique.values.toList(growable: false);
}

Future<bool> isDisposableImportCachePath(
  String path, {
  TargetPlatform? platform,
}) async {
  final target = platform ?? defaultTargetPlatform;
  final mobile =
      target == TargetPlatform.android || target == TargetPlatform.iOS;
  for (final root in await resolveImportCacheRoots(platform: target)) {
    if (!p.isWithin(root.path, path)) continue;
    if (mobile) return true;
    // Desktop system temp also holds user originals and other apps' files.
    if ({
      'file_picker',
      'image_picker',
      'incoming_media',
      'fluent_transfer',
    }.contains(p.split(p.relative(path, from: root.path)).first)) {
      return true;
    }
  }
  return false;
}
