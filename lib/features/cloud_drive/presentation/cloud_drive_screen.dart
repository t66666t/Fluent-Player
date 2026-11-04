import 'package:flutter/material.dart';

import '../../../theme/app_page_transitions.dart';
import '../models/cloud_drive_models.dart';
import '../providers/cloud_drive_provider.dart';
import '../services/cloud_drive_account_repository.dart';
import '../services/cloud_drive_runtime.dart';

part 'cloud_drive_browser_pane.dart';

class CloudDriveRoute extends MaterialPageRoute<void> {
  CloudDriveRoute({String? targetFolderId})
    : super(
        settings: const RouteSettings(name: '/retired/cloud-drive'),
        builder: (_) => CloudDriveScreen(targetFolderId: targetFolderId),
      );
}

class CloudDriveLoginRoute extends AppMaterialPageRoute<CloudDriveAccount> {
  CloudDriveLoginRoute({
    required CloudDriveProvider provider,
    required CloudDriveAccountRepository accounts,
  }) : super(
         builder: (_) => const CloudDriveScreen(),
         settings: const RouteSettings(name: '/retired/cloud-drive'),
       );
}

class CloudDriveScreen extends StatelessWidget {
  const CloudDriveScreen({
    super.key,
    this.targetFolderId,
    this.initialAccount,
    this.initialProviderId,
    this.popOnSearchBack = false,
    this.initialDirectoryId,
    this.initialQuery,
    this.runtime,
    this.embedded = false,
    this.isActive = true,
    this.onSelectionChanged,
  });
  final String? targetFolderId,
      initialProviderId,
      initialDirectoryId,
      initialQuery;
  final CloudDriveAccount? initialAccount;
  final CloudDriveRuntime? runtime;
  final bool popOnSearchBack, embedded, isActive;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    const message = Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('社区版专注本地媒体，请导入本地视频、音频或字幕。'),
      ),
    );
    return embedded
        ? message
        : Scaffold(
            appBar: AppBar(title: const Text('本地媒体')),
            body: message,
          );
  }
}
