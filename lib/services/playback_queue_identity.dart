import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/video_item.dart';

/// Identity of the resource, independent of which page produced its card.
String playbackQueueIdentity(VideoItem item) {
  final source = item.sourceRef;
  if (source?.cloudDrive case final cloud?) return 'cloud:${cloud.sourceKey}';
  if (source?.podcast case final podcast?) {
    return 'podcast:${podcast.feedUrl}:${podcast.episodeId}';
  }
  if (source?.bvid case final bvid?) {
    if (bvid.isNotEmpty && (source?.cid ?? 0) > 0) {
      return 'bilibili:$bvid:${source!.cid}';
    }
  }
  final path = item.path.trim();
  if (path.isNotEmpty && !path.contains('://')) {
    final normalized = p.normalize(p.absolute(path));
    return 'file:${Platform.isWindows ? normalized.toLowerCase() : normalized}';
  }
  return 'item:${item.id}';
}
