import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/video_item.dart';
import 'subtitle_optimization.dart';

/// Installed by the podcast runtime. Resolves this item's stored episode,
/// never the currently playing item, and performs no network request.
class SubtitleOptimizationBackground {
  static Map<String, String>? Function(VideoItem)? podcastMetadata;

  static Future<String> capture(VideoItem? item, String fallbackTitle) async {
    var title = item?.title ?? fallbackTitle;
    var description = '', creator = '';
    var tags = <String>[];
    final ref = item?.sourceRef;
    if (item != null && ref?.podcast != null) {
      final data = podcastMetadata?.call(item);
      title = data?['title'] ?? title;
      description = data?['description'] ?? '';
      creator = data?['creator'] ?? '';
    } else if (ref?.bvid?.isNotEmpty == true) {
      // This is the existing offline detail cache, not a metadata fetch.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('bilibiliOfflineDetails');
      try {
        final cached = raw == null ? null : jsonDecode(raw);
        final detail = cached is Map ? cached[ref!.bvid] : null;
        if (detail is Map) {
          final originalTitle = detail['t'] as String? ?? '';
          if (originalTitle.isNotEmpty && originalTitle != title) {
            title = '$title · $originalTitle';
          }
          description = detail['d'] as String? ?? '';
          creator = detail['o'] as String? ?? '';
          if (detail['tags'] is List) {
            tags = (detail['tags'] as List).whereType<String>().toList();
          }
        }
      } on FormatException {
        /* Missing background never blocks transcription. */
      }
    }
    return subtitleOptimizationBackground(
      title: title,
      description: description,
      tags: tags,
      creator: creator,
    );
  }
}
