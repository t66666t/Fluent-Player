import 'package:flutter/foundation.dart';

import '../../models/media_source_ref.dart';
import '../../models/video_item.dart';
import '../../services/library_service.dart';
import '../cloud_drive/models/cloud_drive_models.dart';
import '../cloud_drive/models/cloud_drive_view_options.dart';
import '../cloud_drive/services/cloud_drive_directory_session.dart';
import '../cloud_drive/services/cloud_drive_runtime.dart';
import 'media_cache_models.dart';

/// Checks library metadata only; remote folders are expanded by the cache
/// preview after the user chooses to cache them.
bool librarySelectionHasCacheableMedia(
  LibraryService library,
  Iterable<String> ids,
) {
  final pending = ids.toList();
  final visited = <String>{};
  while (pending.isNotEmpty) {
    final id = pending.removeLast();
    if (!visited.add(id)) continue;
    final item = library.getVideo(id);
    if (item != null) {
      final source = CacheSource.fromItem(item);
      if (source == null || source.isPodcast) continue;
      if (isCloudDriveMedia(source: item.sourceRef, path: item.path) ||
          item.path.startsWith('bilibili://stream/') ||
          (item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
              (item.path.startsWith('https://') ||
                  item.path.startsWith('http://')))) {
        return true;
      }
      continue;
    }
    final folder = library.getCollection(id);
    if (folder == null) continue;
    final cloud = folder.sourceRef?.cloudDrive;
    if (cloud != null &&
        const {'baidu', 'quark', 'uc', 'aliyun'}.contains(cloud.providerId)) {
      return true;
    }
    pending.addAll(library.getContents(id).map((child) => child.id as String));
  }
  return false;
}

CacheSource? cacheSourceForCloudEntry(CloudDriveEntry entry) {
  if (entry.kind != CloudDriveEntryKind.video &&
      entry.kind != CloudDriveEntryKind.audio) {
    return null;
  }
  final ref = cloudDriveEntrySource(entry);
  return CacheSource(
    ref: ref,
    itemId: ref.cloudDrive!.itemId,
    title: entry.name,
    kind: entry.kind == CloudDriveEntryKind.audio
        ? MediaType.audio
        : MediaType.video,
    durationMs: entry.durationMs ?? 0,
    remoteParentId: entry.parentFileId,
  );
}

/// Enumeration is metadata-only. It never imports cards or starts downloads.
/// Every directory is fully paged; cancelling closes the current reader.
class CacheSelectionCollector extends ChangeNotifier {
  final Map<String, CacheSource> sources = {};
  final Map<String, int> sizes = {};
  final Set<String> _folders = {};
  CloudDriveDirectorySession? _directory;
  bool cancelled = false, loading = false;
  String currentName = '';
  int skipped = 0;
  int get knownBytes => sizes.values.fold(0, (a, b) => a + b);
  void cancel() {
    cancelled = true;
    _directory?.pause();
  }

  Future<void> library(LibraryService library, Iterable<String> ids) async {
    loading = true;
    notifyListeners();
    try {
      Future<void> visit(String id) async {
        if (cancelled) return;
        final item = library.getVideo(id);
        if (item != null) {
          final source = CacheSource.fromItem(item);
          if (source != null) {
            sources[source.key] = source;
          } else {
            skipped++;
          }
          notifyListeners();
          return;
        }
        final folder = library.getCollection(id);
        if (folder == null || !_folders.add('library:$id')) return;
        currentName = folder.name;
        notifyListeners();
        if (folder.sourceRef?.cloudDrive != null) {
          await _remoteFolder(folder.sourceRef!, folder.name);
        } else {
          for (final child in library.getContents(id)) {
            if (cancelled) break;
            await visit(child.id as String);
          }
        }
      }

      for (final id in ids) {
        if (!cancelled) await visit(id);
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> cloud(Iterable<CloudDriveEntry> entries) async {
    loading = true;
    notifyListeners();
    try {
      for (final entry in entries) {
        if (!cancelled) await _entry(entry);
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _entry(CloudDriveEntry entry) async {
    if (cancelled) return;
    currentName = entry.name;
    if (entry.kind == CloudDriveEntryKind.folder) {
      await _remoteFolder(cloudDriveEntrySource(entry), entry.name);
    } else {
      final source = cacheSourceForCloudEntry(entry);
      if (source == null) {
        skipped++;
      } else {
        sources[source.key] = source;
        if (entry.size != null) sizes[source.key] = entry.size!;
      }
      notifyListeners();
    }
  }

  Future<void> _remoteFolder(MediaSourceRef source, String name) async {
    final ref = source.cloudDrive!;
    if (cancelled || !_folders.add('cloud:${ref.sourceKey}')) return;
    final runtime = await CloudDriveRuntime.ensureInstalled();
    final account = runtime.accounts.findRemote(
      ref.providerId,
      ref.remoteAccountId,
    );
    if (account == null) throw StateError('需要登录后读取网盘文件夹');
    final directory = CloudDriveDirectorySession(
      runtime: runtime,
      account: account,
      directoryId: ref.providerId == 'baidu'
          ? ref.pathHint ?? ref.fileId
          : ref.fileId,
    );
    _directory = directory;
    List<CloudDriveEntry> children;
    try {
      await directory.finish();
      if (!directory.complete && !cancelled) {
        throw StateError('“$name”未读取完整，请重试');
      }
      children = List.of(directory.entries);
    } finally {
      _directory = null;
      directory.release();
    }
    for (final child in children) {
      if (!cancelled) await _entry(child);
    }
  }
}
