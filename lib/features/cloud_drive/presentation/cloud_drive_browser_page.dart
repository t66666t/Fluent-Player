import 'package:flutter/material.dart';
import '../../../models/video_item.dart';
import '../../../services/library_service.dart';
import '../models/cloud_drive_models.dart';
import '../services/cloud_drive_runtime.dart';
import 'cloud_drive_screen.dart';

/// Compatibility entry: every cloud browser now uses the same page design.
class CloudDriveBrowserPage extends StatelessWidget {
  const CloudDriveBrowserPage({
    super.key,
    required this.runtime,
    required this.account,
    this.targetFolderId,
  });
  final CloudDriveRuntime runtime;
  final CloudDriveAccount account;
  final String? targetFolderId;
  @override
  Widget build(BuildContext context) => CloudDriveScreen(
    runtime: runtime,
    initialAccount: account,
    targetFolderId: targetFolderId,
  );
}

List<VideoItem> cloudDriveRecentCards(LibraryService library) => library
    .storageVideos
    .where((item) => item.sourceRef?.cloudDrive != null && !item.isRecycled)
    .toList();
