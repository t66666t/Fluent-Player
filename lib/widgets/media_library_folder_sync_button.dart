import 'dart:async';

import 'package:flutter/material.dart';
import 'media_library_tooltip.dart';
import 'package:provider/provider.dart';

import '../features/progress_sync/folder_sync_settings_sheet.dart';
import '../features/progress_sync/progress_sync_service.dart';
import '../theme/app_tokens.dart';

/// Select only membership: byte updates do not rebuild every library card.
bool mediaLibraryFolderIsSynced(BuildContext context, String collectionId) {
  try {
    return context.select<ProgressSyncService, bool>(
      (service) => service.bindings.any(
        (binding) => binding.collectionId == collectionId,
      ),
    );
  } on ProviderNotFoundException {
    return false;
  }
}

class MediaLibraryFolderSyncButton extends StatelessWidget {
  const MediaLibraryFolderSyncButton({
    super.key,
    required this.collectionId,
    this.fillSlot = false,
  });

  final String collectionId;
  final bool fillSlot;

  @override
  Widget build(BuildContext context) => MediaLibraryTooltip(
    message: '文件夹同步',
    child: Semantics(
      button: true,
      label: '文件夹同步',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('folder-sync-button-$collectionId'),
          onTap: () {
            final service = context.read<ProgressSyncService>();
            final name = service.bindings
                .where((binding) => binding.collectionId == collectionId)
                .firstOrNull
                ?.name;
            unawaited(
              showFolderSyncActions(context, service, collectionId, name: name),
            );
          },
          child: fillSlot
              ? const SizedBox.expand()
              : const SizedBox(
                  width: 36,
                  height: 36,
                  child: Icon(
                    Icons.sync_outlined,
                    size: 18,
                    color: AppTokens.text2,
                  ),
                ),
        ),
      ),
    ),
  );
}
