import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'video_action_buttons.dart';

/// Keeps the empty page's actions in the existing app-bar menus.
List<PopupMenuEntry<VoidCallback>> mediaLibraryActionMenuItems(
  BuildContext context, {
  String? collectionId,
}) {
  PopupMenuItem<VoidCallback> item(
    String label,
    IconData icon,
    VoidCallback onSelected,
  ) => PopupMenuItem<VoidCallback>(
    value: onSelected,
    height: 44,
    child: Row(
      children: [
        Icon(icon, size: 18, color: AppTokens.text2),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: AppTokens.text1,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );

  return [
    item('导入视频或音频', Icons.add_rounded, () {
      unawaited(VideoActionButtons.showImportMenu(context, collectionId));
    }),
    item('新建合集', Icons.create_new_folder_outlined, () {
      VideoActionButtons.openCreateCollectionDialog(context, collectionId);
    }),
    item('浏览器导入', Icons.language_outlined, () {
      VideoActionButtons.openWebMediaPage(context, collectionId: collectionId);
    }),
    item('B站下载', Icons.live_tv_outlined, () {
      VideoActionButtons.openBilibiliDownloadPage(
        context,
        collectionId: collectionId,
      );
    }),
    item('YT-DLP下载', Icons.ondemand_video_outlined, () {
      VideoActionButtons.openYtDlpDownloadPage(
        context,
        collectionId: collectionId,
      );
    }),
    item('抖音下载', Icons.music_note_outlined, () {
      VideoActionButtons.openDouyinDownloadPage(
        context,
        collectionId: collectionId,
      );
    }),
    item('缓存管理', Icons.download_outlined, () {
      VideoActionButtons.openCacheManagementPage(context);
    }),
    item('语音转录', Icons.closed_caption_outlined, () {
      VideoActionButtons.openBatchSubtitlePage(
        context,
        collectionId: collectionId,
      );
    }),
    const PopupMenuDivider(),
  ];
}

/// The wide toolbar reuses its existing import/export icon as the menu anchor.
Future<void> showMediaLibraryActionsMenu(
  BuildContext context, {
  String? collectionId,
  required VoidCallback onTransfer,
}) async {
  final screenSize = MediaQuery.sizeOf(context);
  final padding = MediaQuery.paddingOf(context);
  final top = MediaQuery.viewPaddingOf(context).top + 48;
  final action = await showMenu<VoidCallback>(
    context: context,
    useRootNavigator: true,
    color: AppTokens.bgOverlay,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    position: RelativeRect.fromLTRB(
      screenSize.width - padding.right - 16,
      top,
      padding.right + 16,
      screenSize.height - top,
    ),
    items: [
      ...mediaLibraryActionMenuItems(context, collectionId: collectionId),
      PopupMenuItem<VoidCallback>(
        value: onTransfer,
        child: const Text('导入与导出'),
      ),
    ],
  );
  if (context.mounted) action?.call();
}
