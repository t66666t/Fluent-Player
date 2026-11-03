import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/batch_subtitle_task_view.dart';
import '../models/transcription_status.dart';
import '../models/transcription_progress.dart';
import '../models/local_asr_progress.dart';
import 'local_asr_progress_view.dart';
import 'operation_status.dart';
import 'visibility_input_gate.dart';
import '../utils/transcription_failure_summary.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'task_reorder_listener.dart';

/// Converts Flutter's final displayed-list index into the task's final
/// position in the pending queue.
///
/// The table also contains active, failed, and completed rows, while the
/// manager's queue contains only idle rows. Scheduled and unstarted tasks
/// retain their own groups even when a row is dragged across the boundary.
@visibleForTesting
int calculateBatchSubtitleQueueIndex({
  required List<BatchSubtitleTaskView> displayedTasks,
  required int oldIndex,
  required int newIndex,
  required bool isDescending,
}) {
  if (oldIndex < 0 || oldIndex >= displayedTasks.length) return -1;

  final draggedTask = displayedTasks[oldIndex];
  if (draggedTask.status != TranscriptionStatus.idle) return -1;

  final reordered = List<BatchSubtitleTaskView>.from(displayedTasks);
  reordered.removeAt(oldIndex);

  // onReorderItem (unlike the deprecated onReorder callback) has already
  // adjusted newIndex for the removal at oldIndex.
  final insertionIndex = newIndex.clamp(0, reordered.length);
  reordered.insert(insertionIndex, draggedTask);

  final displayedQueue = reordered
      .where(
        (task) =>
            task.status == TranscriptionStatus.idle &&
            task.isStarted == draggedTask.isStarted,
      )
      .toList(growable: false);
  final displayedQueueIndex = displayedQueue.indexWhere(
    (task) => task.mediaKey == draggedTask.mediaKey,
  );
  if (displayedQueueIndex < 0) return -1;

  final groupIndex = isDescending
      ? displayedQueue.length - 1 - displayedQueueIndex
      : displayedQueueIndex;
  final offset = draggedTask.isStarted
      ? 0
      : displayedTasks
            .where(
              (task) =>
                  task.status == TranscriptionStatus.idle && task.isStarted,
            )
            .length;
  return offset + groupIndex;
}

double _taskStatusWidth(BuildContext context) =>
    (180 * MediaQuery.textScalerOf(context).scale(13) / 13)
        .clamp(180, 320)
        .toDouble();

class TaskQueueTable extends StatefulWidget {
  final List<BatchSubtitleTaskView> tasks;
  final Map<String, bool> autoDeletedKeys;
  final void Function(String mediaKey) onStart;
  final void Function(String mediaKey)? onPause;
  final void Function(String mediaKey) onRetry;
  final void Function(String mediaKey)? onRestart;
  final void Function(String mediaKey) onDelete;
  final void Function(String mediaKey, int newIndex) onReorder;
  final void Function(BatchSubtitleTaskView task)? onTapCompleted;
  final VoidCallback? onConfigure;

  const TaskQueueTable({
    super.key,
    required this.tasks,
    required this.autoDeletedKeys,
    required this.onStart,
    this.onPause,
    required this.onRetry,
    this.onRestart,
    required this.onDelete,
    required this.onReorder,
    this.onTapCompleted,
    this.onConfigure,
  });

  @override
  State<TaskQueueTable> createState() => _TaskQueueTableState();
}

class _TaskQueueTableState extends State<TaskQueueTable> {
  bool _isDescending = false;
  int? _dragIndex;
  int? _hoverIndex;
  final _scrollController = ScrollController();
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<BatchSubtitleTaskView> get _sortedTasks {
    return orderBatchSubtitleTasks(widget.tasks, descending: _isDescending);
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _sortedTasks;
    final taskNumbers = {
      for (final (index, task) in orderBatchSubtitleTasks(widget.tasks).indexed)
        task.mediaKey: index + 1,
    };

    if (tasks.isEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) => Center(
          child: SingleChildScrollView(
            controller: _scrollController,
            primary: false,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.65),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.subtitles_outlined,
                    size: 27,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '还没有字幕任务',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Text(
                  constraints.maxWidth < 600
                      ? '点击上方“添加媒体”开始'
                      : '选择内部媒体或外部文件添加到队列',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final mediaSize = MediaQuery.sizeOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final isCompact =
            mediaSize.shortestSide < 600 ||
            constraints.maxWidth < 720 * textScale;
        final isWide = !isCompact && constraints.maxWidth >= 840;
        final btnSize = isCompact
            ? (mediaSize.shortestSide * 0.09).clamp(31.0, 36.0)
            : (mediaSize.shortestSide * 0.04).clamp(30.0, 38.0);

        return Column(
          children: [
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: isCompact ? 0 : 8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _isDescending ? '进行中置顶 · 等待任务从下到上' : '进行中置顶 · 等待任务从上到下',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  DesktopButtonClickRegion(
                    child: TextButton.icon(
                      key: const ValueKey('task-queue-display-order'),
                      onPressed: () =>
                          setState(() => _isDescending = !_isDescending),
                      icon: Icon(
                        _isDescending
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: 18,
                      ),
                      label: Text(_isDescending ? '正序显示' : '倒序显示'),
                    ),
                  ),
                ],
              ),
            ),
            if (!isCompact) _buildHeader(isWide, false, btnSize, tasks.length),
            const Divider(height: 1),
            Expanded(
              child: ReorderableListView.builder(
                scrollController: _scrollController,
                primary: false,
                padding: isCompact
                    ? const EdgeInsets.only(bottom: 8)
                    : EdgeInsets.zero,
                buildDefaultDragHandles: false,
                itemCount: tasks.length,
                onReorderStart: (index) {
                  Tooltip.dismissAllToolTips();
                  HapticFeedback.selectionClick();
                  setState(() => _dragIndex = index);
                },
                onReorderEnd: (_) {
                  setState(() {
                    _dragIndex = null;
                    _hoverIndex = null;
                  });
                },
                onReorderItem: (oldIndex, newIndex) {
                  final task = tasks[oldIndex];
                  if (task.status != TranscriptionStatus.idle) return;
                  final queueIndex = calculateBatchSubtitleQueueIndex(
                    displayedTasks: tasks,
                    oldIndex: oldIndex,
                    newIndex: newIndex,
                    isDescending: _isDescending,
                  );
                  if (queueIndex < 0) return;
                  widget.onReorder(task.mediaKey, queueIndex);
                },
                proxyDecorator: (child, index, animation) {
                  return AnimatedBuilder(
                    animation: animation,
                    builder: (context, _) {
                      final t = Curves.easeOutCubic.transform(animation.value);
                      return Transform.scale(
                        scale: 1.0 + t * 0.018,
                        child: Material(
                          color: Theme.of(context).colorScheme.surface,
                          elevation: 6 * t,
                          child: TooltipVisibility(
                            visible: false,
                            child: child,
                          ),
                        ),
                      );
                    },
                  );
                },
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  final isAutoDeleting = widget.autoDeletedKeys.containsKey(
                    task.mediaKey,
                  );
                  final canDrag = task.status == TranscriptionStatus.idle;

                  final row = _TaskRow(
                    index: taskNumbers[task.mediaKey]!,
                    task: task,
                    isWide: isWide,
                    isCompact: isCompact,
                    isAutoDeleting: isAutoDeleting,
                    onConfigure: widget.onConfigure,
                    isDragging: _dragIndex == index,
                    isHoverTarget: _hoverIndex == index,
                    btnSize: btnSize,
                    onStart: () => widget.onStart(task.mediaKey),
                    onPause: widget.onPause == null
                        ? null
                        : () => widget.onPause!(task.mediaKey),
                    onRetry: () => widget.onRetry(task.mediaKey),
                    onRestart: widget.onRestart == null
                        ? null
                        : () => widget.onRestart!(task.mediaKey),
                    onDelete: () => widget.onDelete(task.mediaKey),
                    onTapCompleted: widget.onTapCompleted != null
                        ? () => widget.onTapCompleted!(task)
                        : null,
                  );

                  return VisibilityInputGate(
                    key: ValueKey(task.mediaKey),
                    enabled: !isAutoDeleting,
                    child: canDrag
                        ? TaskReorderListener(
                            key: ValueKey('task-drag-${task.mediaKey}'),
                            index: index,
                            onCancel: () {
                              if (_dragIndex == null) return;
                              setState(() => _dragIndex = null);
                            },
                            child: row,
                          )
                        : row,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(
    bool isWide,
    bool isCompact,
    double btnSize,
    int taskCount,
  ) {
    if (isCompact) {
      final theme = Theme.of(context);
      final actionWidth = btnSize * (widget.onRestart == null ? 2 : 3);
      final headerStyle = TextStyle(
        fontSize: MediaQuery.sizeOf(context).width < 360 ? 9.5 : 10.5,
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurfaceVariant,
      );
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        child: Row(
          children: [
            Tooltip(
              triggerMode: TooltipTriggerMode.manual,
              waitDuration: const Duration(milliseconds: 600),
              message: _isDescending ? '切换为最早优先' : '切换为最新优先',
              child: InkWell(
                onTap: () => setState(() => _isDescending = !_isDescending),
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('#', style: headerStyle),
                      Icon(
                        _isDescending
                            ? Icons.arrow_downward_rounded
                            : Icons.arrow_upward_rounded,
                        size: 11,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                '名称（$taskCount）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: headerStyle,
              ),
            ),
            SizedBox(
              width: 120,
              child: Text(
                '状态',
                textAlign: TextAlign.center,
                style: headerStyle,
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: Text(
                '操作',
                textAlign: TextAlign.center,
                style: headerStyle,
              ),
            ),
          ],
        ),
      );
    }

    final actionWidth = btnSize * (widget.onRestart == null ? 2 : 3) + 4;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          GestureDetector(
            onTap: () => setState(() => _isDescending = !_isDescending),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('#', style: const TextStyle(fontWeight: FontWeight.bold)),
                Icon(
                  _isDescending ? Icons.arrow_downward : Icons.arrow_upward,
                  size: 14,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            flex: 3,
            child: Text('名称', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (isWide)
            const SizedBox(
              width: 60,
              child: Text('类型', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          SizedBox(
            width: _taskStatusWidth(context),
            child: const Text(
              '进度',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          SizedBox(
            width: actionWidth,
            child: const Text(
              '操作',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  final int index;
  final BatchSubtitleTaskView task;
  final bool isWide;
  final bool isCompact;
  final bool isAutoDeleting;
  final VoidCallback? onConfigure;
  final bool isDragging;
  final bool isHoverTarget;
  final double btnSize;
  final VoidCallback onStart;
  final VoidCallback? onPause;
  final VoidCallback onRetry;
  final VoidCallback? onRestart;
  final VoidCallback onDelete;
  final VoidCallback? onTapCompleted;

  const _TaskRow({
    required this.index,
    required this.task,
    required this.isWide,
    required this.isCompact,
    required this.isAutoDeleting,
    this.onConfigure,
    required this.isDragging,
    required this.isHoverTarget,
    required this.btnSize,
    required this.onStart,
    this.onPause,
    required this.onRetry,
    this.onRestart,
    required this.onDelete,
    this.onTapCompleted,
  });

  @override
  Widget build(BuildContext context) {
    if (isCompact) {
      return _CompactTaskTableRow(
        index: index,
        task: task,
        isAutoDeleting: isAutoDeleting,
        isDragging: isDragging,
        isHoverTarget: isHoverTarget,
        onConfigure: onConfigure,
        btnSize: btnSize,
        onStart: onStart,
        onPause: onPause,
        onRetry: onRetry,
        onRestart: onRestart,
        onDelete: onDelete,
        onTapCompleted: onTapCompleted,
      );
    }

    final isProcessing =
        task.status != TranscriptionStatus.idle &&
        task.status != TranscriptionStatus.completed &&
        task.status != TranscriptionStatus.error;
    final isCompleted = task.status == TranscriptionStatus.completed;
    final isError = task.status == TranscriptionStatus.error;
    final isIdle = task.status == TranscriptionStatus.idle;

    final iconSize = btnSize * 0.5;

    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        opacity: isAutoDeleting ? 0.0 : 1.0,
        child: Container(
          margin: EdgeInsets.symmetric(
            horizontal: isDragging ? 4 : 0,
            vertical: 1,
          ),
          decoration: BoxDecoration(
            color: isDragging
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : isHoverTarget
                ? Theme.of(context).hoverColor
                : null,
            borderRadius: BorderRadius.circular(isDragging ? 8 : 0),
            boxShadow: isDragging
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Text(
                  '$index',
                  style: TextStyle(
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).hintColor,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: isCompleted && onTapCompleted != null
                                ? GestureDetector(
                                    onTap: onTapCompleted,
                                    child: Text(
                                      task.videoName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        decoration: TextDecoration.underline,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurface,
                                      ),
                                    ),
                                  )
                                : Text(
                                    task.videoName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                          ),
                          if (!isWide)
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: _TypeBadge(
                                isExternal: task.isExternal,
                                compact: true,
                              ),
                            ),
                        ],
                      ),
                      Text(
                        task.videoDuration.isEmpty
                            ? '时长待获取'
                            : task.videoDuration,
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isWide)
                  SizedBox(
                    width: 60,
                    child: _TypeBadge(
                      isExternal: task.isExternal,
                      compact: false,
                    ),
                  ),
                SizedBox(
                  width: _taskStatusWidth(context),
                  child: InkWell(
                    onTap: isError
                        ? () => _showTaskDetails(
                            context,
                            task,
                            onRetry: onRetry,
                            onRestart: onRestart,
                            onDelete: onDelete,
                            onConfigure: onConfigure,
                          )
                        : null,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ProgressIndicator(
                          status: task.status,
                          progress: task.progress,
                          translationProgress: task.translationProgress,
                          localAsrProgress: task.localAsrProgress,
                          audioProgress: task.audioProgress,
                          statusMessage: task.statusMessage,
                          videoName: task.videoName,
                        ),
                        if (isError)
                          Text(
                            '查看详情',
                            style: TextStyle(
                              fontSize: 13,
                              decoration: TextDecoration.underline,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: btnSize * (onRestart == null ? 2 : 3) + 6,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isIdle && !task.isStarted)
                        _CompactIconButton(
                          icon: Icons.play_arrow,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Theme.of(context).colorScheme.primary,
                          tooltip: '开始',
                          onPressed: onStart,
                        ),
                      if ((isIdle && task.isStarted) || isProcessing)
                        _CompactIconButton(
                          icon: Icons.pause_rounded,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Theme.of(context).colorScheme.primary,
                          tooltip: '暂停',
                          onPressed: onPause,
                        ),
                      if (isCompleted)
                        _CompactIconButton(
                          icon: Icons.check_circle,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Colors.green,
                          tooltip: '已完成',
                          onPressed: null,
                        ),
                      if (isError)
                        _CompactIconButton(
                          icon: Icons.refresh,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Colors.orange,
                          tooltip: '重试',
                          onPressed: onRetry,
                        ),
                      if (onRestart != null)
                        _CompactIconButton(
                          icon: Icons.restart_alt,
                          size: btnSize,
                          iconSize: iconSize,
                          color: Theme.of(context).colorScheme.primary,
                          tooltip: '从头开始',
                          onPressed:
                              !isProcessing && (!isIdle || !task.isStarted)
                              ? onRestart
                              : null,
                        ),
                      const SizedBox(width: 2),
                      _CompactIconButton(
                        icon: Icons.close,
                        size: btnSize,
                        iconSize: iconSize,
                        color: Theme.of(context).colorScheme.error,
                        tooltip: isProcessing ? '取消并删除' : '删除',
                        onPressed: onDelete,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactTaskTableRow extends StatelessWidget {
  final int index;
  final BatchSubtitleTaskView task;
  final bool isAutoDeleting, isDragging, isHoverTarget;
  final double btnSize;
  final VoidCallback onStart, onRetry, onDelete;
  final VoidCallback? onPause, onRestart, onTapCompleted, onConfigure;

  const _CompactTaskTableRow({
    required this.index,
    required this.task,
    required this.isAutoDeleting,
    required this.isDragging,
    required this.isHoverTarget,
    required this.btnSize,
    required this.onStart,
    required this.onRetry,
    required this.onDelete,
    this.onPause,
    this.onRestart,
    this.onTapCompleted,
    this.onConfigure,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isIdle = task.status == TranscriptionStatus.idle;
    final isCompleted = task.status == TranscriptionStatus.completed;
    final isError = task.status == TranscriptionStatus.error;
    final isProcessing = !isIdle && !isCompleted && !isError;
    final status = isCompleted
        ? '已完成'
        : isError
        ? '失败'
        : isIdle
        ? (task.isStarted ? '排队中' : '待开始')
        : TranscriptionProgress.stage(task.status, task.statusMessage);
    void details() => _showTaskDetails(
      context,
      task,
      onRetry: onRetry,
      onRestart: onRestart,
      onDelete: onDelete,
      onConfigure: onConfigure,
    );
    final color = isError
        ? theme.colorScheme.error
        : isProcessing
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: isAutoDeleting ? 0 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isDragging ? theme.colorScheme.surfaceContainerHighest : null,
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.onSurface.withValues(alpha: .10),
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: Text(
                '$index',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: .45),
                ),
              ),
            ),
            Expanded(
              child: Tooltip(
                triggerMode: TooltipTriggerMode.manual,
                waitDuration: const Duration(milliseconds: 600),
                message: task.videoName,
                child: InkWell(
                  onTap: isCompleted
                      ? onTapCompleted
                      : isError
                      ? details
                      : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        task.videoName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          decoration: isCompleted && onTapCompleted != null
                              ? TextDecoration.underline
                              : null,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      if (isError)
                        Text(
                          transcriptionFailureSummary(task.statusMessage),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      Text(
                        '${task.videoDuration.isEmpty ? "时长待获取" : task.videoDuration} · ${task.isExternal ? "外部媒体" : "媒体库"}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.6,
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: .5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 52,
              child: InkWell(
                onTap: isError ? details : null,
                child: Tooltip(
                  triggerMode: TooltipTriggerMode.manual,
                  waitDuration: const Duration(milliseconds: 600),
                  message: isError
                      ? transcriptionFailureSummary(task.statusMessage)
                      : task.statusMessage.isEmpty
                      ? status
                      : task.statusMessage,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        status,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: color),
                      ),
                      if (isProcessing) ...[
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: task.progress.clamp(0, 1),
                          minHeight: 2,
                          backgroundColor: theme.colorScheme.onSurface
                              .withValues(alpha: .1),
                        ),
                        Text(
                          '${(task.progress * 100).round()}%',
                          style: TextStyle(fontSize: 13, color: color),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            _CompactIconButton(
              icon: isCompleted
                  ? Icons.check_rounded
                  : isError
                  ? Icons.refresh
                  : isProcessing || task.isStarted
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              size: btnSize,
              iconSize: 18,
              color: theme.colorScheme.primary,
              tooltip: isCompleted
                  ? '已完成'
                  : isError
                  ? '重试'
                  : isProcessing || task.isStarted
                  ? '暂停'
                  : '开始',
              onPressed: isCompleted
                  ? onTapCompleted
                  : isError
                  ? onRetry
                  : isProcessing || task.isStarted
                  ? onPause
                  : onStart,
            ),
            if (onRestart != null)
              _CompactIconButton(
                icon: Icons.restart_alt,
                size: btnSize,
                iconSize: 18,
                color: theme.colorScheme.primary,
                tooltip: '从头开始',
                onPressed: !isProcessing && (!isIdle || !task.isStarted)
                    ? onRestart
                    : null,
              ),
            _CompactIconButton(
              icon: Icons.close,
              size: btnSize,
              iconSize: 18,
              color: theme.colorScheme.error,
              tooltip: isProcessing ? '取消并删除' : '删除',
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showTaskDetails(
  BuildContext context,
  BatchSubtitleTaskView task, {
  required VoidCallback onRetry,
  required VoidCallback onDelete,
  VoidCallback? onRestart,
  VoidCallback? onConfigure,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    title: const Text('转录任务详情', style: TextStyle(fontSize: 16)),
    scrollable: true,
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task.videoName, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          Text(transcriptionFailureSummary(task.statusMessage)),
          const SizedBox(height: 8),
          const Text('重试沿用上次配置；调整设置后请从头开始。', style: TextStyle(fontSize: 13)),
          if (task.statusMessage.isNotEmpty)
            ExpansionTile(
              key: const PageStorageKey('task-failure-diagnostic'),
              tilePadding: EdgeInsets.zero,
              title: const Text('诊断详情', style: TextStyle(fontSize: 13)),
              children: [
                PageStorage(
                  bucket: PageStorageBucket(),
                  child: SelectableText(
                    safeOperationDiagnostic(task.statusMessage),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
        ],
      ),
    ),
    actions: [
      if (onConfigure != null)
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              onConfigure();
            },
            child: const Text('调整设置'),
          ),
        ),
      if (onRestart != null)
        DesktopButtonClickRegion(
          child: TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              onRestart();
            },
            child: const Text('从头开始'),
          ),
        ),
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            onDelete();
          },
          child: const Text('删除任务'),
        ),
      ),
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            onRetry();
          },
          child: const Text('重试'),
        ),
      ),
      DesktopButtonClickRegion(
        child: TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ),
    ],
  ),
);

class _CompactIconButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;
  final Color color;
  final String tooltip;
  final VoidCallback? onPressed;

  const _CompactIconButton({
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      triggerMode: TooltipTriggerMode.manual,
      waitDuration: const Duration(milliseconds: 600),
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(size * 0.25),
            child: Center(
              child: Icon(
                icon,
                size: iconSize,
                color: onPressed == null
                    ? Theme.of(context).disabledColor
                    : color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final bool isExternal;
  final bool compact;

  const _TypeBadge({required this.isExternal, required this.compact});

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: isExternal
              ? Colors.orange.withValues(alpha: 0.15)
              : Colors.blue.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          isExternal ? '外部' : '内部',
          style: TextStyle(
            fontSize: 10,
            color: isExternal ? Colors.orange.shade800 : Colors.blue.shade800,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: isExternal
            ? Colors.orange.withValues(alpha: 0.15)
            : Colors.blue.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        isExternal ? '外部媒体' : '内部媒体',
        style: TextStyle(
          fontSize: 11,
          color: isExternal ? Colors.orange.shade800 : Colors.blue.shade800,
        ),
      ),
    );
  }
}

class _LocalProcessingProgress extends StatelessWidget {
  const _LocalProcessingProgress({
    required this.progress,
    required this.audio,
    required this.local,
    required this.fontSize,
  });

  final double progress, fontSize;
  final TranscriptionAudioProgress? audio;
  final LocalAsrProgress? local;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        (audio ??
                TranscriptionAudioProgress(
                  completed: Duration.zero,
                  total: local!.total,
                ))
            .label,
        style: TextStyle(
          fontSize: fontSize,
          height: 1.4,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      const SizedBox(height: 4),
      if (local != null)
        LocalAsrProgressView(
          progress: local!,
          compact: true,
          compactFontSize: fontSize,
        )
      else
        LinearProgressIndicator(value: progress.clamp(0.0, 1.0), minHeight: 3),
    ],
  );
}

class _ProgressIndicator extends StatelessWidget {
  final TranscriptionStatus status;
  final double progress;
  final double? translationProgress;
  final LocalAsrProgress? localAsrProgress;
  final TranscriptionAudioProgress? audioProgress;
  final String statusMessage;
  final String videoName;

  const _ProgressIndicator({
    required this.status,
    required this.progress,
    this.translationProgress,
    this.localAsrProgress,
    this.audioProgress,
    this.statusMessage = '',
    this.videoName = '',
  });

  @override
  Widget build(BuildContext context) {
    if (status == TranscriptionStatus.completed) {
      final msg = statusMessage.isNotEmpty ? statusMessage : '转录完成，可直接使用生成字幕';
      return Tooltip(
        triggerMode: TooltipTriggerMode.manual,
        waitDuration: const Duration(milliseconds: 600),
        message: '$videoName - $msg',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle,
                  size: 16,
                  color: Colors.green.shade600,
                ),
                const SizedBox(width: 4),
                Text(
                  '已完成',
                  style: TextStyle(fontSize: 13, color: Colors.green.shade600),
                ),
              ],
            ),
            if (statusMessage.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                msg,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: Colors.green.shade300),
              ),
            ],
          ],
        ),
      );
    }

    if (status == TranscriptionStatus.error) {
      final msg = transcriptionFailureSummary(statusMessage);
      return Tooltip(
        triggerMode: TooltipTriggerMode.manual,
        waitDuration: const Duration(milliseconds: 600),
        message: '$videoName - $msg',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error, size: 16, color: Colors.red.shade400),
                const SizedBox(width: 4),
                const Text(
                  '失败',
                  style: TextStyle(fontSize: 13, color: Colors.red),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              msg,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: Colors.red.shade300),
            ),
          ],
        ),
      );
    }

    if (status == TranscriptionStatus.idle) {
      if (statusMessage.isNotEmpty) {
        // Show queue position for started tasks
        return Tooltip(
          triggerMode: TooltipTriggerMode.manual,
          waitDuration: const Duration(milliseconds: 600),
          message: statusMessage,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.hourglass_bottom,
                size: 14,
                color: Colors.amber.shade700,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  statusMessage,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Colors.amber.shade700),
                ),
              ),
            ],
          ),
        );
      }
      return const Text(
        '排队中',
        style: TextStyle(fontSize: 13, color: Colors.grey),
      );
    }

    // Processing states: extracting / uploading / transcribing
    if (audioProgress != null || localAsrProgress != null) {
      return _LocalProcessingProgress(
        progress: progress,
        audio: audioProgress,
        local: localAsrProgress,
        fontSize: 13,
      );
    }
    final statusText = TranscriptionProgress.stage(status, statusMessage);
    final waiting = TranscriptionProgress.isWaiting(status, statusMessage);

    final bool hasDetailMessage = statusMessage.isNotEmpty;

    final widget = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 4,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              translationProgress == null ? statusText : '翻译',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(width: 4),
            Text(
              waiting
                  ? '等待结果'
                  : translationProgress == null
                  ? '${(progress * 100).floor()}%'
                  : '${(translationProgress! * 100).floor()}%',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
        ),
        if (translationProgress != null)
          Text(
            '总进度 ${(progress * 100).floor()}%',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        const SizedBox(height: 2),
        SizedBox(
          width: 100,
          child: LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
        ),
        if (hasDetailMessage) ...[
          const SizedBox(height: 3),
          Text(
            statusMessage,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ],
    );
    return hasDetailMessage
        ? Tooltip(message: '$videoName - $statusMessage', child: widget)
        : widget;
  }
}
