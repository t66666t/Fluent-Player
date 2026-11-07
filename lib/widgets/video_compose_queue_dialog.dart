import '../theme/app_settings_theme.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/video_compose_models.dart';
import '../services/settings_service.dart';
import '../services/video_compose_manager.dart';
import '../utils/app_toast.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Null cancels; false confirms record-only deletion; true also deletes output.
Future<bool?> showComposeDeleteConfirmation(
  BuildContext context, {
  required int count,
  required bool deleteOutput,
  required bool includesActiveTasks,
  bool clearAll = false,
  ValueChanged<bool>? onDeleteOutputChanged,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      var choice = deleteOutput;
      var confirmed = false;
      return StatefulBuilder(
        builder: (context, update) {
          void confirm() {
            if (confirmed) return;
            confirmed = true;
            Navigator.of(dialogContext).pop(choice);
          }

          return CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.enter,
                includeRepeats: false,
              ): confirm,
              const SingleActivator(
                LogicalKeyboardKey.numpadEnter,
                includeRepeats: false,
              ): confirm,
            },
            child: Focus(
              autofocus: true,
              child: AlertDialog(
                backgroundColor: const Color(0xFF2C2C2C),
                scrollable: true,
                title: Text(
                  clearAll ? '确认清空' : '确认删除',
                  style: const TextStyle(color: Colors.white),
                ),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clearAll
                          ? '确定要清空这 $count 条合成记录吗？'
                          : count == 1
                          ? '确定要删除该合成记录吗？'
                          : '确定要删除选中的 $count 条合成记录吗？',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    if (includesActiveTasks)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '其中正在运行和排队的任务也会取消。',
                          style: TextStyle(color: Colors.orangeAccent),
                        ),
                      ),
                    const SizedBox(height: 8),
                    CheckboxListTile(
                      value: choice,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        '同时删除已合成的视频文件',
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        '仅删除这些任务对应的输出文件',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      onChanged: (value) {
                        if (confirmed) return;
                        update(() => choice = value ?? true);
                        onDeleteOutputChanged?.call(choice);
                      },
                    ),
                  ],
                ),
                actions: [
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: confirm,
                      child: Text(
                        clearAll ? '清空' : '删除',
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class VideoComposeQueueDialog extends StatefulWidget {
  const VideoComposeQueueDialog({
    super.key,
    required this.onPreview,
    required this.onOpenOutput,
    required this.openOutputLabel,
    this.onSaveOutput,
    this.requestDeleteOutputPermission,
  });

  final Future<void> Function(VideoComposeTaskState task) onPreview;
  final Future<void> Function(String path) onOpenOutput;
  final Future<void> Function(String path)? onSaveOutput;
  final String openOutputLabel;
  final Future<bool> Function(List<VideoComposeTaskState> tasks)?
  requestDeleteOutputPermission;

  @override
  State<VideoComposeQueueDialog> createState() =>
      _VideoComposeQueueDialogState();
}

class _VideoComposeQueueDialogState extends State<VideoComposeQueueDialog> {
  final _selected = <String>{};
  bool _selecting = false;
  bool _deleting = false;
  String? _previewing;
  String? _saving;
  bool get _busy => _deleting || _saving != null;
  late bool _deleteOutput;

  @override
  void initState() {
    super.initState();
    _deleteOutput = context
        .read<SettingsService>()
        .videoComposeDeleteOutputOnTaskDelete;
  }

  void _rememberDeleteOutput(bool value) {
    if (!mounted) return;
    setState(() => _deleteOutput = value);
    unawaited(
      context
          .read<SettingsService>()
          .updateSetting('videoComposeDeleteOutputOnTaskDelete', value)
          .catchError((Object error) => debugPrint('保存合成删除偏好失败：$error')),
    );
  }

  Future<void> _delete(
    List<VideoComposeTaskState> tasks, {
    bool clearAll = false,
  }) async {
    if (_busy || tasks.isEmpty) return;
    final manager = context.read<VideoComposeManager>();
    final ids = tasks.map((task) => task.taskId).toSet();
    final choice = await showComposeDeleteConfirmation(
      context,
      count: tasks.length,
      deleteOutput: _deleteOutput,
      includesActiveTasks: tasks.any(
        (task) =>
            task.stage != VideoComposeStage.completed &&
            task.stage != VideoComposeStage.failed,
      ),
      clearAll: clearAll,
      onDeleteOutputChanged: _rememberDeleteOutput,
    );
    if (!mounted || choice == null || _busy) return;
    setState(() => _deleting = true);
    try {
      if (choice &&
          !(await widget.requestDeleteOutputPermission?.call(tasks) ?? true)) {
        if (mounted) {
          AppToast.show('没有存储权限，任务和视频均未删除', type: AppToastType.error);
        }
        return;
      }
      final result = await manager.deleteTasksAndFiles(
        ids,
        deleteOutput: choice,
      );
      if (!mounted) return;
      setState(() {
        _selected.removeAll(result.deletedTaskIds);
        if (result.failedTaskIds.isEmpty) _selecting = false;
      });
      if (result.failedTaskIds.isNotEmpty) {
        AppToast.show(
          '${result.failedTaskIds.length} 个任务删除失败，记录已保留；请关闭文件占用或授权后重试',
          type: AppToastType.error,
        );
      }
    } catch (error) {
      if (mounted) {
        AppToast.show('删除失败，未删除的记录已保留：$error', type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _preview(VideoComposeTaskState task) async {
    if (_previewing != null || _busy) return;
    setState(() => _previewing = task.taskId);
    try {
      await widget.onPreview(task);
    } catch (error) {
      if (mounted) {
        AppToast.show('无法打开预览：$error', type: AppToastType.error);
      }
    } finally {
      if (mounted) setState(() => _previewing = null);
    }
  }

  Future<void> _save(VideoComposeTaskState task) async {
    if (_busy || widget.onSaveOutput == null) return;
    setState(() => _saving = task.taskId);
    try {
      await widget.onSaveOutput!(task.request.outputPath);
    } catch (error) {
      if (mounted) AppToast.show('保存失败，合成视频仍保留', type: AppToastType.error);
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) =>
      AppSettingsTheme(child: Builder(builder: _buildThemedSurface));

  Widget _buildThemedSurface(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        width: (size.width * .9).clamp(280, 760),
        height: (size.height * .78).clamp(180, 780),
        child: Consumer<VideoComposeManager>(
          builder: (context, manager, _) {
            final tasks = manager.allTasks;
            final selectedTasks = tasks
                .where((t) => _selected.contains(t.taskId))
                .toList();
            final allSelected =
                tasks.isNotEmpty && selectedTasks.length == tasks.length;
            return CustomScrollView(
              key: const PageStorageKey('compose-tasks'),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '视频合成队列',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            DesktopButtonClickRegion(
                              child: IconButton(
                                tooltip: '关闭合成队列',
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '运行${manager.runningTask == null ? 0 : 1} · 排队${manager.queuedTasks.length} · 共${tasks.length}项',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (_selecting) ...[
                              DesktopButtonClickRegion(
                                child: TextButton(
                                  onPressed: _busy || tasks.isEmpty
                                      ? null
                                      : () => setState(() {
                                          _selected.clear();
                                          if (!allSelected) {
                                            _selected.addAll(
                                              tasks.map((t) => t.taskId),
                                            );
                                          }
                                        }),
                                  child: Text(allSelected ? '取消全选' : '全选'),
                                ),
                              ),
                              DesktopButtonClickRegion(
                                child: TextButton.icon(
                                  onPressed: _busy || selectedTasks.isEmpty
                                      ? null
                                      : () => _delete(selectedTasks),
                                  icon: const Icon(Icons.delete_outline),
                                  label: Text('删除已选（${selectedTasks.length}）'),
                                ),
                              ),
                              DesktopButtonClickRegion(
                                child: TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => setState(() {
                                          _selecting = false;
                                          _selected.clear();
                                        }),
                                  child: const Text('退出选择'),
                                ),
                              ),
                            ] else
                              DesktopButtonClickRegion(
                                child: TextButton.icon(
                                  onPressed: _busy || tasks.isEmpty
                                      ? null
                                      : () => setState(() => _selecting = true),
                                  icon: const Icon(Icons.checklist),
                                  label: const Text('批量选择'),
                                ),
                              ),
                            DesktopButtonClickRegion(
                              child: TextButton.icon(
                                onPressed: _busy || tasks.isEmpty
                                    ? null
                                    : () => _delete(tasks, clearAll: true),
                                icon: const Icon(Icons.clear_all),
                                label: const Text('清空队列'),
                              ),
                            ),
                          ],
                        ),
                        if (_deleting)
                          const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LinearProgressIndicator(),
                              SizedBox(height: 6),
                              Text(
                                '正在删除，请稍候…',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        if (tasks.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Center(
                              child: Text(
                                '当前没有合成任务',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  sliver: SliverList.builder(
                    itemCount: tasks.length,
                    itemBuilder: (context, index) =>
                        _taskCard(manager, tasks[index]),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _taskCard(VideoComposeManager manager, VideoComposeTaskState task) {
    final running = manager.runningTask?.taskId == task.taskId;
    final completed = task.stage == VideoComposeStage.completed;
    final progress = completed ? 1.0 : task.progress.clamp(0.0, 1.0);
    final color = task.stage == VideoComposeStage.failed
        ? Colors.redAccent
        : running
        ? Colors.blueAccent
        : completed
        ? Colors.greenAccent
        : Colors.orangeAccent;
    final hasOutput = completed && File(task.request.outputPath).existsSync();
    return Container(
      key: ValueKey('compose-task-${task.taskId}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _selected.contains(task.taskId) && _selecting
              ? Colors.blueAccent
              : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_selecting)
                Checkbox(
                  key: ValueKey('compose-select-${task.taskId}'),
                  value: _selected.contains(task.taskId),
                  semanticLabel: '选择 ${task.request.title}',
                  onChanged: _busy
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            _selected.add(task.taskId);
                          } else {
                            _selected.remove(task.taskId);
                          }
                        }),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.request.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      task.message,
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (!_selecting)
                DesktopButtonClickRegion(
                  child: IconButton(
                    key: ValueKey('compose-delete-${task.taskId}'),
                    tooltip: '删除合成记录',
                    onPressed: _busy ? null : () => _delete([task]),
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                    ),
                  ),
                ),
            ],
          ),
          Text(
            task.request.softSubtitleOnly
                ? '仅软字幕'
                : task.request.renderMode == VideoComposeRenderMode.precise
                ? '精确渲染 · 非幽灵字幕'
                : '粗略渲染 · ASS',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: LinearProgressIndicator(
                  value: progress,
                  backgroundColor: Colors.white10,
                  color: color,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          if (task.error?.trim().isNotEmpty == true &&
              task.stage == VideoComposeStage.failed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                task.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
          if (task.completedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '完成时间: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(task.completedAt!)}',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          if (completed || task.stage == VideoComposeStage.failed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(
                '输出位置：${task.request.outputPath}',
                maxLines: 2,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          if (hasOutput) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                DesktopButtonClickRegion(
                  child: OutlinedButton.icon(
                    onPressed: _busy || _previewing != null
                        ? null
                        : () => _preview(task),
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: const Text('预览'),
                  ),
                ),
                DesktopButtonClickRegion(
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => widget.onOpenOutput(task.request.outputPath),
                    icon: const Icon(Icons.open_in_new_outlined, size: 18),
                    label: Text(widget.openOutputLabel),
                  ),
                ),
                if (widget.onSaveOutput != null)
                  DesktopButtonClickRegion(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _save(task),
                      icon: const Icon(Icons.save_alt, size: 18),
                      label: Text(_saving == task.taskId ? '正在保存…' : '保存到设备'),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
