import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/bilibili/bilibili_watch_playlist.dart';
import 'cached_thumbnail_widget.dart';

/// Cover for a row in the mini-player list or the episode list.
///
/// The card's own file wins. When that card was only a lightweight Bilibili
/// entry, or its file was removed with the card, the shared cover cache is
/// used instead. The lookup happens when the item or its path changes, not
/// on every playback tick.
class BilibiliQueueThumbnail extends StatefulWidget {
  const BilibiliQueueThumbnail({
    super.key,
    required this.item,
    required this.placeholder,
    this.cacheWidth,
    this.cacheHeight,
  });

  final VideoItem item;
  final Widget placeholder;
  final int? cacheWidth;
  final int? cacheHeight;

  @override
  State<BilibiliQueueThumbnail> createState() => _BilibiliQueueThumbnailState();
}

class _BilibiliQueueThumbnailState extends State<BilibiliQueueThumbnail> {
  String? _path;

  /// Copied string, not the live field. The card mutates [VideoItem.thumbnailPath]
  /// in place, so comparing the old and new widget would see the same value.
  String? _seenThumbnailPath;

  @override
  void initState() {
    super.initState();
    _seenThumbnailPath = widget.item.thumbnailPath;
    _path = BilibiliWatchPlaylistSession.thumbnailFileFor(widget.item);
    BilibiliWatchPlaylistSession.coverUpdates.addListener(_onCovers);
  }

  @override
  void didUpdateWidget(BilibiliQueueThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final thumbnailPath = widget.item.thumbnailPath;
    if (oldWidget.item.id != widget.item.id ||
        thumbnailPath != _seenThumbnailPath) {
      _seenThumbnailPath = thumbnailPath;
      _path = BilibiliWatchPlaylistSession.thumbnailFileFor(widget.item);
    }
  }

  @override
  void dispose() {
    BilibiliWatchPlaylistSession.coverUpdates.removeListener(_onCovers);
    super.dispose();
  }

  /// A cover download finished. Re-read this row; playback ticks do not.
  void _onCovers() {
    if (!mounted) return;
    final thumbnailPath = widget.item.thumbnailPath;
    final next = BilibiliWatchPlaylistSession.thumbnailFileFor(widget.item);
    if (next == _path && thumbnailPath == _seenThumbnailPath) return;
    setState(() {
      _seenThumbnailPath = thumbnailPath;
      _path = next;
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = _path;
    if (path == null || path.isEmpty) return widget.placeholder;
    return CachedThumbnailWidget(
      videoId: widget.item.id,
      thumbnailPath: path,
      fit: BoxFit.cover,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      placeholder: widget.placeholder,
      errorWidget: widget.placeholder,
    );
  }
}
