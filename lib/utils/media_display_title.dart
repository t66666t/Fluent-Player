import '../models/media_source_ref.dart';
import '../models/video_item.dart';
import 'supported_media_extensions.dart';

/// Formats a local file's title without changing its stored name or path.
/// Metadata titles may contain path separators, so never use basename here.
String localMediaDisplayTitle(String title, {bool showExtension = false}) {
  if (showExtension) return title;
  final end = title.trimRight().length;
  final dot = title.lastIndexOf('.', end == 0 ? 0 : end - 1);
  if (dot <= 0) return title;
  final extension = title.substring(dot, end).toLowerCase();
  if (!kSupportedVideoExtensions.contains(extension) &&
      !kSupportedAudioExtensions.contains(extension)) {
    return title;
  }
  if (title.substring(0, dot).trim().isEmpty) return title;
  return title.substring(0, dot) + title.substring(end);
}

/// Online cards retain their publisher title, even when a cache is available.
String mediaItemDisplayTitle(
  VideoItem item, {
  bool showLocalMediaExtensions = false,
}) {
  if (showLocalMediaExtensions ||
      itemNeedsOnlineMaterialization(source: item.sourceRef, path: item.path)) {
    return item.title;
  }
  final scheme = Uri.tryParse(item.path)?.scheme.toLowerCase() ?? '';
  // A single-letter scheme is a Windows drive. SAF and file URLs are local.
  if (scheme.isNotEmpty &&
      scheme.length != 1 &&
      scheme != 'file' &&
      scheme != 'content') {
    return item.title;
  }
  return localMediaDisplayTitle(item.title);
}
