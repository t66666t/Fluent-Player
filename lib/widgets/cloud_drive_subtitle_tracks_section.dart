import 'package:flutter/material.dart';

import '../features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import '../models/video_item.dart';

/// Historical source metadata never activates remote subtitle discovery.
CloudDriveSubtitleTracks? cloudDriveSubtitleTracksFor(
  BuildContext context,
  VideoItem? item,
) => null;

/// Retained constructor for old callers; online track UI is retired.
class CloudDriveSubtitleTracksSection extends StatelessWidget {
  const CloudDriveSubtitleTracksSection({
    super.key,
    required this.itemId,
    required this.tracks,
    required this.onPick,
    required this.savedRow,
    this.openLogin,
  });
  final String itemId;
  final CloudDriveSubtitleTracks tracks;
  final ValueChanged<String> onPick;
  final Widget Function(CloudDriveListedSubtitle track) savedRow;
  final Future<void> Function(BuildContext context)? openLogin;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
