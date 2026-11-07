import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/library_service.dart';
import 'confirmation_dialog_shortcuts.dart';
import 'operation_status.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Keeps irreversible deletion, progress and partial failure in one surface.
class RecycleBinDeletionDialog extends StatefulWidget {
  const RecycleBinDeletionDialog({
    super.key,
    required this.library,
    required this.ids,
  });
  final LibraryService library;
  final List<String> ids;
  @override
  State<RecycleBinDeletionDialog> createState() =>
      _RecycleBinDeletionDialogState();
}

class _RecycleBinDeletionDialogState extends State<RecycleBinDeletionDialog> {
  bool _busy = false;
  int _processed = 0;
  RecycleBinDeleteResult? _result;
  String? _error;
  final Set<String> _deleted = {};
  final Map<String, String> _restoredFailures = {};
  late final Map<String, String> _titles = {
    for (final id in widget.ids.toSet())
      id:
          widget.library.getVideo(id)?.title ??
          widget.library.getCollection(id)?.name ??
          '媒体项',
  };

  void _closeIfComplete() {
    final result = _result;
    if (mounted &&
        result != null &&
        result.failedIds.isEmpty &&
        result.saved &&
        !widget.library.hasPersistenceFailure &&
        Navigator.canPop(context)) {
      Navigator.pop(context, result);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final pending = _result == null
        ? widget.ids.toSet().toList()
        : [
            for (final entry in _result!.failedIds.entries)
              if (!_result!.restoredIds.contains(entry.key)) entry.key,
          ];
    setState(() {
      _busy = true;
      _processed = 0;
      _error = null;
    });
    try {
      final result = await widget.library.deleteFromRecycleBin(
        pending,
        onProgress: (done, total) {
          if (mounted) setState(() => _processed = done);
        },
      );
      _deleted.addAll(result.deletedIds);
      _restoredFailures.addAll({
        for (final id in result.restoredIds) id: result.failedIds[id]!,
      });
      if (mounted) {
        setState(
          () => _result = RecycleBinDeleteResult(
            deletedIds: _deleted.toList(),
            failedIds: {..._restoredFailures, ...result.failedIds},
            saved: result.saved,
            restoredIds: _restoredFailures.keys.toSet(),
          ),
        );
        _closeIfComplete();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法完成删除，请检查存储位置后重试。未完成的项目会保留。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retrySave() async {
    setState(() => _busy = true);
    try {
      await widget.library.retryLibraryPersistence();
      if (mounted) {
        setState(() {
          final result = _result!;
          _result = RecycleBinDeleteResult(
            deletedIds: result.deletedIds,
            failedIds: result.failedIds,
            saved: !widget.library.hasPersistenceFailure,
            restoredIds: result.restoredIds,
          );
        });
        _closeIfComplete();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '删除记录未能保存，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final count = widget.ids.toSet().length;
    final failed = result?.failedIds.length ?? 0;
    final retryable =
        result != null &&
        result.failedIds.keys.any((id) => !result.restoredIds.contains(id));
    return PopScope(
      canPop: !_busy,
      child: ConfirmationDialogShortcuts(
        onCancel: _busy ? null : () => Navigator.pop(context, _result),
        confirmKey: LogicalKeyboardKey.keyD,
        onConfirm: _busy || result != null || _error != null ? null : _delete,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          title: Text('永久删除 $count 项', style: const TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_busy && result == null && _error == null)
                    const Text('删除所选项及文件夹内的内容，删除后无法恢复。'),
                  if (_busy)
                    OperationStatus(
                      title: '正在处理',
                      message: '已处理 $_processed 项，请等待完成。',
                      kind: OperationStatusKind.progress,
                    ),
                  if (_error != null)
                    OperationStatus(
                      title: '删除未完成',
                      message: _error,
                      kind: OperationStatusKind.error,
                    ),
                  if (!_busy && result != null) ...[
                    if (failed > 0)
                      OperationStatus(
                        title: '有 $failed 项未能删除，记录已保留。',
                        kind: OperationStatusKind.error,
                        details: result.failedIds.keys
                            .map(
                              (id) =>
                                  '${_titles[id] ?? '媒体项'}：${result.failedIds[id]}',
                            )
                            .join('\n'),
                      ),
                    if (!result.saved ||
                        widget.library.hasPersistenceFailure) ...[
                      const SizedBox(height: 12),
                      OperationStatus(
                        title: '删除结果尚未保存',
                        message: '请保持存储位置可用后重试保存。',
                        kind: OperationStatusKind.error,
                        actions: [
                          DesktopButtonClickRegion(
                            child: TextButton(
                              onPressed: _retrySave,
                              child: const Text('重试保存'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context, _result),
                child: ConfirmationShortcutLabel(
                  result == null ? '取消' : '关闭',
                  'Esc',
                ),
              ),
            ),
            if (result == null || retryable)
              DesktopButtonClickRegion(
                child: FilledButton(
                  onPressed: _busy ? null : _delete,
                  child: result == null && _error == null
                      ? const ConfirmationShortcutLabel('永久删除', 'Enter / D')
                      : const Text('重试未完成项'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
