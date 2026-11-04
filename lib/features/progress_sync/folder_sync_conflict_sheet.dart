import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import 'folder_sync_models.dart';
import 'folder_transfer_card.dart' show formatFolderTransferBytes;
import 'progress_sync_components.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

typedef FolderSyncResolution = ({String eventId, bool keepBoth});

Future<FolderSyncResolution?> showFolderSyncConflict(
  BuildContext context,
  FolderSyncIssue issue,
) => showSyncSheet<FolderSyncResolution>(
  context: context,
  title: issue.reason == 'deleteHasLiveDescendants'
      ? '保留新增内容'
      : switch (issue.kind) {
          FolderSyncIssueKind.deleteConflict => '删除与修改需要确认',
          FolderSyncIssueKind.renameConflict => '选择名称',
          FolderSyncIssueKind.moveConflict => '选择位置',
          _ => '选择文件版本',
        },
  child: Builder(
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          issue.title,
          style: const TextStyle(fontSize: 14, color: AppTokens.text1),
        ),
        const SizedBox(height: 6),
        Text(
          issue.reason == 'deleteHasLiveDescendants'
              ? '另一端新增的内容已保留。保留文件夹后，可继续同步。'
              : issue.message,
          style: const TextStyle(
            fontSize: 12,
            color: AppTokens.text2,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        if (issue.reason == 'deleteHasLiveDescendants' &&
            issue.choices.isNotEmpty)
          DesktopButtonClickRegion(
            child: FilledButton.icon(
              onPressed: () => Navigator.pop(sheetContext, (
                eventId: issue.choices.first.eventId,
                keepBoth: true,
              )),
              icon: const Icon(Icons.folder_outlined, size: 18),
              label: const Text('保留文件夹'),
            ),
          )
        else
          for (final choice in issue.choices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                choice.deleted
                    ? Icons.delete_outline
                    : choice.node.kind == FolderSyncNodeKind.folder
                    ? Icons.folder_outlined
                    : Icons.description_outlined,
                color: choice.deleted ? AppTokens.danger : AppTokens.text2,
              ),
              title: Text(
                choice.deleted
                    ? '采用删除 · ${choice.deviceName}'
                    : switch (issue.kind) {
                        FolderSyncIssueKind.renameConflict =>
                          '采用 ${choice.deviceName} 的名称',
                        FolderSyncIssueKind.moveConflict =>
                          '采用 ${choice.deviceName} 的位置',
                        _ => '保留 ${choice.deviceName} 的版本',
                      },
              ),
              subtitle: Text(
                choice.deleted
                    ? '对应项目会移到各设备回收站。'
                    : choice.node.kind == FolderSyncNodeKind.folder
                    ? choice.fileName
                    : '${choice.fileName} · ${formatFolderTransferBytes(choice.bytes)}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTokens.text2,
                  height: 1.5,
                ),
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => Navigator.pop(sheetContext, (
                eventId: choice.eventId,
                keepBoth: false,
              )),
            ),
        if (issue.reason != 'deleteHasLiveDescendants' &&
            issue.choices.where((choice) => !choice.deleted).length >= 2 &&
            issue.choices
                .where((choice) => !choice.deleted)
                .every(
                  (choice) => choice.node.kind == FolderSyncNodeKind.media,
                )) ...[
          const SizedBox(height: 12),
          DesktopButtonClickRegion(
            child: OutlinedButton.icon(
              onPressed: () => Navigator.pop(sheetContext, (
                eventId: issue.choices
                    .firstWhere((choice) => !choice.deleted)
                    .eventId,
                keepBoth: true,
              )),
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('保留双方'),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '各保留一个文件，内容不会合并。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: AppTokens.text3),
          ),
        ],
        const SizedBox(height: 12),
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () => Navigator.pop(sheetContext),
            child: const Text('稍后处理'),
          ),
        ),
      ],
    ),
  ),
);
