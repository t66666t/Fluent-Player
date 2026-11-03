import '../features/podcasts/podcast_runtime.dart';
import '../models/video_item.dart';
import 'bilibili/bilibili_watch_playlist.dart';
import 'playlist_manager.dart';

/// Update the source's queue record as well as the visible playback queue.
bool removePlaybackQueueItem(PlaylistManager queue, VideoItem item) {
  final bilibili = BilibiliWatchPlaylistSession.instance;
  if (bilibili != null &&
      identical(bilibili.queue, queue) &&
      bilibili.isActive) {
    return bilibili.removeFromQueue(item.id);
  }
  final podcasts = PodcastRuntime.instance;
  if (podcasts.ready && identical(podcasts.playlist, queue)) {
    return podcasts.removeQueueItem(item.id);
  }
  return queue.removeFromQueue(item.id);
}

bool reorderPlaybackQueue(PlaylistManager queue, List<String> itemIds) {
  final bilibili = BilibiliWatchPlaylistSession.instance;
  if (bilibili != null &&
      identical(bilibili.queue, queue) &&
      bilibili.isActive) {
    return bilibili.reorderQueue(itemIds);
  }
  final podcasts = PodcastRuntime.instance;
  if (podcasts.ready && identical(podcasts.playlist, queue)) {
    return podcasts.reorderQueueItems(itemIds);
  }
  return queue.reorderQueue(itemIds);
}

bool reversePlaybackQueue(PlaylistManager queue) => reorderPlaybackQueue(
  queue,
  queue.playbackQueue.reversed.map((item) => item.id).toList(),
);

bool resetPlaybackQueueOrder(PlaylistManager queue) {
  final bilibili = BilibiliWatchPlaylistSession.instance;
  if (bilibili != null &&
      identical(bilibili.queue, queue) &&
      bilibili.isActive) {
    return bilibili.resetQueueOrder();
  }
  final podcasts = PodcastRuntime.instance;
  if (podcasts.ready && identical(podcasts.playlist, queue)) {
    return podcasts.resetQueueOrder();
  }
  return queue.resetQueueOrder();
}

/// Indices use Flutter's post-removal target index. Submitting the complete
/// snapshot lets the manager reject a drop if queue membership changed meanwhile.
List<String> reorderedQueueItemIds(
  List<VideoItem> items,
  int oldIndex,
  int newIndex,
) {
  final ids = items.map((item) => item.id).toList();
  if (oldIndex < 0 ||
      oldIndex >= ids.length ||
      newIndex < 0 ||
      newIndex >= ids.length) {
    return ids;
  }
  final moved = ids.removeAt(oldIndex);
  ids.insert(newIndex, moved);
  return ids;
}
