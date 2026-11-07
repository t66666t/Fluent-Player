import 'dart:io';

import '../models/video_item.dart';
import 'community_media_input.dart';

typedef PlaybackSourceExists = bool Function(String path);

/// The single source of truth for whether a library item may participate in
/// previous/next navigation and an operating-system media queue.
///
/// Opening an item is a separate concern: a missing local item may still open
/// its detail/player page so the user can restore its source. It must never be
/// inserted into a playback queue. Existing local files and validated podcast identities are queue sources;
/// unrelated historical online references remain excluded.
///
/// Library queues always exclude recycled items. Recycle-bin preview is the
/// exception: pass [allowRecycled] so videos shown in one recycle-bin
/// directory can be previous/next targets and appear in the playlist card.
class PlaybackQueuePolicy {
  PlaybackQueuePolicy({PlaybackSourceExists? sourceExists})
    : _sourceExists = sourceExists ?? _defaultSourceExists;

  final PlaybackSourceExists _sourceExists;

  bool isEligible(VideoItem item, {bool allowRecycled = false}) {
    if (item.isRecycled && !allowRecycled) return false;

    if (communityMediaIsPodcast(item.path, source: item.sourceRef)) return true;
    if (!communityMediaIsLocal(item.path)) return false;
    try {
      return _sourceExists(communityLocalMediaPath(item.path));
    } catch (_) {
      return false;
    }
  }

  List<VideoItem> filter(
    Iterable<VideoItem> items, {
    bool allowRecycled = false,
  }) {
    return List<VideoItem>.unmodifiable(
      items.where((item) => isEligible(item, allowRecycled: allowRecycled)),
    );
  }

  static bool _defaultSourceExists(String path) => File(path).existsSync();
}

/// Immutable, revisioned projection consumed by every playback-queue client.
class PlaybackQueueSnapshot {
  PlaybackQueueSnapshot({
    required this.revision,
    required Iterable<VideoItem> entries,
    required this.currentItemId,
    required this.folderId,
  }) : entries = List<VideoItem>.unmodifiable(entries) {
    final mapping = <String, int>{};
    for (var index = 0; index < this.entries.length; index++) {
      mapping[this.entries[index].id] = index;
    }
    indexByItemId = Map<String, int>.unmodifiable(mapping);
    currentIndex = currentItemId == null ? -1 : (mapping[currentItemId] ?? -1);
  }

  final int revision;
  final List<VideoItem> entries;
  final String? currentItemId;
  final String? folderId;
  late final Map<String, int> indexByItemId;
  late final int currentIndex;

  VideoItem? get currentItem =>
      currentIndex >= 0 ? entries[currentIndex] : null;
  bool get hasPrevious => currentIndex > 0;
  bool get hasNext => currentIndex >= 0 && currentIndex < entries.length - 1;

  int indexOf(String itemId) => indexByItemId[itemId] ?? -1;
}
