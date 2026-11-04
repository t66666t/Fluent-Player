import 'dart:async';

import 'package:flutter/material.dart';
import '../../widgets/library_folder_picker.dart';

import 'folder_transfer_card.dart';
import 'folder_transfer_models.dart';
import 'progress_sync_components.dart';
import 'progress_sync_models.dart';
import 'progress_sync_service.dart';
import 'sync_folder_picker.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

export 'folder_transfer_card.dart';

/// The same task surface is used in sync settings and import/export history.
class FolderTransferSection extends StatefulWidget {
  const FolderTransferSection({
    super.key,
    required this.service,
    this.direction,
  });

  final ProgressSyncService service;
  final FolderTransferDirection? direction;

  @override
  State<FolderTransferSection> createState() => _FolderTransferSectionState();
}

class _FolderTransferSectionState extends State<FolderTransferSection> {
  final Set<String> _pending = {};

  Future<void> _chooseAcceptance(FolderTransferTask task) async {
    String? destinationParentId;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, update) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${task.peerName}想与你同步「${task.folderName}」',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text('选择一次即可开始双向同步。两端文件夹名称可以不同。'),
                  const SizedBox(height: 16),
                  DesktopButtonClickRegion(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext, 'existing'),
                      child: const Text('关联本地文件夹'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DesktopButtonClickRegion(
                    child: TextButton.icon(
                      onPressed: () async {
                        final picked = await showLibraryFolderPicker(
                          sheetContext,
                          library: widget.service.library,
                          initialFolderId: destinationParentId,
                          title: '新文件夹保存到',
                          confirmLabel: '保存到这里',
                          offerSetAsDefault: false,
                        );
                        if (sheetContext.mounted && picked != null) {
                          update(() => destinationParentId = picked.folderId);
                        }
                      },
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(
                        '保存到：${widget.service.library.getCollection(destinationParentId ?? '')?.name ?? '媒体库根目录'}',
                      ),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: FilledButton.tonal(
                      onPressed: () => Navigator.pop(sheetContext, 'new'),
                      child: const Text('接收新文件夹'),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () => Navigator.pop(sheetContext, 'ignore'),
                      child: const Text('忽略'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'ignore') {
      await _act(task.id, widget.service.rejectFolderTransfer);
      return;
    }
    if (choice == 'new') {
      await _act(
        task.id,
        (id) => widget.service.acceptFolderTransfer(
          id,
          destinationParentId: destinationParentId,
        ),
      );
      return;
    }
    final folderId = await _pickExistingFolder(task.folderName);
    if (!mounted || folderId == null) return;
    await _act(
      task.id,
      (id) => widget.service.acceptFolderSync(
        id,
        choice: FolderSyncAcceptChoice.linkExisting,
        existingCollectionId: folderId,
      ),
    );
  }

  Future<String?> _pickExistingFolder(String remoteName) =>
      showSyncFolderPicker(
        context,
        library: widget.service.library,
        title: '关联「$remoteName」',
        description: '包含子文件夹，两端文件夹名称可以不同。',
      );

  Future<void> _act(String id, Future<void> Function(String) action) async {
    if (!_pending.add(id)) return;
    setState(() {});
    try {
      await action(id);
    } catch (error) {
      if (!mounted) return;
      final detail = error is FormatException ? error.message.trim() : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            RegExp(r'^[\u3400-\u9FFF]').hasMatch(detail) && detail.length < 160
                ? detail
                : '未能完成，请检查设备连接后重试',
          ),
        ),
      );
    } finally {
      _pending.remove(id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (_, _) {
      final tasks = widget.service.folderTransfers
          .where(
            (task) =>
                widget.direction == null || task.direction == widget.direction,
          )
          .toList();
      if (tasks.isEmpty) return const SizedBox.shrink();
      return SyncSection(
        title: '设备传输',
        child: Column(
          children: [
            for (var index = 0; index < tasks.length; index++) ...[
              if (index > 0)
                const Divider(height: 1, indent: 16, endIndent: 16),
              FolderTransferCard(
                key: ValueKey('folder-transfer-${tasks[index].id}'),
                task: tasks[index],
                busy: _pending.contains(tasks[index].id),
                onAccept: () => unawaited(_chooseAcceptance(tasks[index])),
                onReject: () => unawaited(
                  _act(tasks[index].id, widget.service.rejectFolderTransfer),
                ),
                onCancel: () => unawaited(
                  _act(tasks[index].id, widget.service.cancelFolderTransfer),
                ),
                onRetry: () => unawaited(
                  _act(tasks[index].id, widget.service.retryFolderTransfer),
                ),
                onDismiss: () => unawaited(
                  _act(tasks[index].id, widget.service.dismissFolderTransfer),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}
