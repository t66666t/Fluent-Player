import '../../../utils/subtitle_file_matcher.dart';
import '../../../utils/supported_media_extensions.dart';
import 'cloud_drive_models.dart';

/// Classifies a cloud file before any playback request.
///
/// Vendor category wins for video and audio. Extensions only fill the gap,
/// and a subtitle extension is recognised even when the vendor calls the file
/// "other", so sidecar scans are not blocked by the video filter.
CloudDriveEntryKind classifyCloudDriveFile({
  required String name,
  int? category,
}) {
  final extension = _extensionOf(name);
  if (kSupportedTextSubtitleExtensions.contains(extension) ||
      SubtitleFileMatcher.supportedExtensions.contains(extension)) {
    return CloudDriveEntryKind.subtitle;
  }
  if (category == 1) return CloudDriveEntryKind.video;
  if (category == 2) return CloudDriveEntryKind.audio;
  if (kSupportedAudioExtensions.contains(extension)) {
    return CloudDriveEntryKind.audio;
  }
  if (kSupportedVideoExtensions.contains(extension)) {
    return CloudDriveEntryKind.video;
  }
  return CloudDriveEntryKind.unsupported;
}

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot).toLowerCase();
}
