import '../models/video_collection.dart';
import '../models/video_item.dart';

/// Depth-first media listing that never mutates folder childrenIds.
class MediaLibraryFolderWalk {
  static List<VideoItem> collectMedia({
    required String rootId,
    required VideoCollection? Function(String id) folderOf,
    required VideoItem? Function(String id) videoOf,
  }) {
    final result = <VideoItem>[];
    final seenMedia = <String>{};
    final visitingFolders = <String>{};

    void visit(String folderId) {
      if (!visitingFolders.add(folderId)) return;
      final folder = folderOf(folderId);
      if (folder == null || folder.isRecycled) return;
      for (final childId in folder.childrenIds) {
        final nested = folderOf(childId);
        if (nested != null) {
          if (!nested.isRecycled) visit(childId);
          continue;
        }
        final video = videoOf(childId);
        if (video == null || video.isRecycled) continue;
        if (!seenMedia.add(video.id)) continue;
        result.add(video);
      }
    }

    visit(rootId);
    return result;
  }

  /// Path from [rootId] exclusive to the item's parent, using folder names.
  static String relativePath({
    required String rootId,
    required String? parentId,
    required VideoCollection? Function(String id) folderOf,
  }) {
    if (parentId == null || parentId == rootId) return '';
    final names = <String>[];
    final visited = <String>{};
    String? currentId = parentId;
    while (currentId != null &&
        currentId != rootId &&
        visited.add(currentId)) {
      final folder = folderOf(currentId);
      if (folder == null) break;
      names.add(folder.name);
      currentId = folder.parentId;
    }
    return names.reversed.join(' / ');
  }
}

/// Session memory for "include subfolders". Only the last folder is persisted.
class MediaLibraryFolderBrowseMemory {
  static final Map<String, bool> _session = <String, bool>{};

  static bool includeFor({
    required String folderId,
    required String lastFolderId,
    required bool persistedLast,
  }) {
    if (_session.containsKey(folderId)) return _session[folderId]!;
    if (folderId == lastFolderId) return persistedLast;
    return false;
  }

  static void remember(String folderId, bool include) {
    _session[folderId] = include;
  }

  static void resetForTest() {
    _session.clear();
  }
}
