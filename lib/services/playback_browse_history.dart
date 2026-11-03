import '../models/video_item.dart';
import 'bilibili/bilibili_player_video.dart';

/// A visit made through a link, independent of the previous/next play queue.
class PlaybackBrowseEntry {
  PlaybackBrowseEntry({
    required this.item,
    required this.position,
    required this.wasPlaying,
    required List<VideoItem> queue,
    this.queueOwner,
  }) : queue = List.unmodifiable(queue);

  final VideoItem item;
  final Duration position;
  final bool wasPlaying;
  final List<VideoItem> queue;
  final Object? queueOwner;
}

/// Keeps lightweight resume points rather than stacking live player routes.
class PlaybackBrowseHistory {
  PlaybackBrowseHistory({this.capacity = 20}) : assert(capacity > 0);

  final int capacity;
  final List<PlaybackBrowseEntry> _entries = [];
  VideoItem? _target;

  Set<String> get itemIds => {for (final entry in _entries) entry.item.id};

  bool _matches(VideoItem item) {
    if (_target?.id == item.id) return true;
    final targetVideo = bilibiliPlayerVideoOf(_target);
    final video = bilibiliPlayerVideoOf(item);
    // Changing a part stays within this visit and adds no browser history.
    return targetVideo != null && video?.bvid == targetVideo.bvid;
  }

  PlaybackBrowseEntry? previousFor(VideoItem item) =>
      _entries.isNotEmpty && _matches(item) ? _entries.last : null;

  void record({
    required PlaybackBrowseEntry origin,
    required VideoItem target,
  }) {
    if (origin.item.id == target.id) return;
    if (!_matches(origin.item)) clear();
    _entries.add(origin);
    if (_entries.length > capacity) _entries.removeAt(0);
    _target = target;
  }

  void returned(PlaybackBrowseEntry entry) {
    if (_entries.isEmpty || !identical(_entries.last, entry)) return;
    _entries.removeLast();
    _target = _entries.isEmpty ? null : entry.item;
  }

  void clear() {
    _entries.clear();
    _target = null;
  }
}
