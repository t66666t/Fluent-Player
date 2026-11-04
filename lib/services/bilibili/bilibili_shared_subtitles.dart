import 'dart:io';

import 'package:path/path.dart' as p;

import '../../models/video_item.dart';
import '../../utils/subtitle_file_matcher.dart';
import '../settings_service.dart';
import '../task_subtitle_storage_service.dart';
import '../subtitle_word_timing_store.dart';
import 'bilibili_stream_card.dart';

/// Subtitles that belong to one online Bilibili part, not to one card.
///
/// A library card and a one-time watch of the same `bvid` + `cid` read and
/// write this folder, so a subtitle made on either of them shows on the other.
/// Cards that only happen to use the same local file never get a folder here.
class BilibiliSharedSubtitles {
  const BilibiliSharedSubtitles({Directory? dataRootOverride})
    : _dataRootOverride = dataRootOverride;

  final Directory? _dataRootOverride;

  /// `BV..._cid`. Both pieces are already safe path tokens.
  static String? folderNameOf(VideoItem? item) {
    final key = item == null ? null : bilibiliOnlinePartKey(item);
    if (key == null) return null;
    final separator = key.indexOf('#');
    if (separator <= 0 || separator >= key.length - 1) return null;
    return '${key.substring(0, separator)}_${key.substring(separator + 1)}';
  }

  Future<Directory> dataRoot() async {
    return _dataRootOverride ?? SettingsService().resolveLargeDataRootDir();
  }

  Future<Directory> directoryFor(VideoItem item, {bool create = false}) async {
    final name = folderNameOf(item);
    if (name == null) {
      throw ArgumentError.value(item.id, 'item', '不是在线 B 站分P');
    }
    final root = await dataRoot();
    final directory = Directory(
      p.join(root.path, 'subtitles', 'bilibili', name),
    );
    if (create && !await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }

  /// True when [path] lives in the shared folder of [item]'s part.
  Future<bool> containsPath(String path, VideoItem item) async {
    if (folderNameOf(item) == null) return false;
    final directory = await directoryFor(item);
    return _samePath(path, directory.path) || p.isWithin(directory.path, path);
  }

  /// True for any file under `subtitles/bilibili/`, whatever the part.
  ///
  /// Card deletion must leave these files alone: the next open of the same
  /// part, from the library or from a one-time watch, still needs them.
  Future<bool> isSharedPath(String path) async {
    final root = Directory(
      p.join((await dataRoot()).path, 'subtitles', 'bilibili'),
    );
    return p.isWithin(root.path, path);
  }

  Future<List<File>> list(VideoItem item) async {
    if (folderNameOf(item) == null) return const <File>[];
    final directory = await directoryFor(item);
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

  Future<String> allocate(VideoItem item, String preferredFileName) async {
    final directory = await directoryFor(item, create: true);
    return TaskSubtitleStorageService(
      dataRootOverride: _dataRootOverride,
    ).allocateInside(directory, preferredFileName);
  }

  bool _samePath(String first, String second) {
    final left = p.normalize(p.absolute(first));
    final right = p.normalize(p.absolute(second));
    return Platform.isWindows
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
  }
}
