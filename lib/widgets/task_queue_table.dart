import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/app_haptics.dart';
import '../models/batch_subtitle_task_view.dart';
import '../models/transcription_status.dart';
import '../models/transcription_progress.dart';
import '../models/local_asr_progress.dart';
import 'local_asr_progress_view.dart';
import 'subtitle_optimization_progress_view.dart';
import 'operation_status.dart';
import 'visibility_input_gate.dart';
import '../utils/transcription_failure_summary.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';
import 'task_reorder_listener.dart';
import 'task_range_selection_gesture.dart';
import '../utils/media_library_range_selection.dart';

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
  final Set<String> selectedKeys;
  final ValueChanged<Set<String>>? onSelectionChanged;

  /// On short windows, page controls scroll with the queue rather than
  /// consuming all the space left above the player and selection actions.
  final Widget? header;
  final bool scrollHeader;

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
    this.selectedKeys = const {},
    this.onSelectionChanged,
    this.header,
    this.scrollHeader = false,
  });

  @override
  State<TaskQueueTable> createState() => _TaskQueueTableState();
}

class _TaskQueueTableState extends State<TaskQueueTable>
    with WidgetsBindingObserver {
  bool _isDescending = false;
  int? _dragIndex;
  int? _hoverIndex;
  final _scrollController = ScrollController();
  final _viewportKey = GlobalKey();
  final _rowKeys = <String, GlobalKey>{};
  late final _rangeAutoScroller = MediaLibrarySelectionAutoScroller(
    scrollController: _scrollController,
    onScrolled: _scheduleRangeUpdate,
  );
  List<String>? _rangeOrder;
  Set<String> _rangeSnapshot = {};
  Set<String> _lastRangeSelection = {};
  int? _rangeAnchor;
  bool _rangeSelecting = true;
  Offset? _rangeStartPosition, _rangePosition;
  bool _rangeMoved = false;
  bool _rangeUpdateScheduled = false;
  TaskRangeSelectionGestureRecognizer? _rangeRecognizer;

  bool get _isSelecting =>
      widget.selectedKeys.isNotEmpty || _rangeAnchor != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _endRangeSelection();
  }

  @override
  void didUpdateWidget(TaskQueueTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    final order = _sortedTasks.map((task) => task.mediaKey).toList();
    final keys = order.toSet();
    _rowKeys.removeWhere((key, _) => !keys.contains(key));
    // A running task can finish and move between groups during a held drag.
    // End that gesture rather than interpreting its anchor in another order.
    if (_rangeOrder != null &&
        (!listEquals(_rangeOrder, order) ||
            widget.onSelectionChanged == null ||
            !setEquals(widget.selectedKeys, _lastRangeSelection) ||
            widget.autoDeletedKeys.containsKey(_rangeOrder![_rangeAnchor!]))) {
      _endRangeSelection(rebuild: false);
    }
    if (_rangeAnchor != null && _rangeMoved) _scheduleRangeUpdate();
  }

  Rect? _boxRect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  String? _checkboxAt(Offset position) {
    final viewport = _boxRect(_viewportKey);
    if (viewport == null || !viewport.contains(position)) return null;
    for (final entry in _rowKeys.entries) {
      if (widget.autoDeletedKeys.containsKey(entry.key)) continue;
      final row = _boxRect(entry.value);
      if (row == null || !row.contains(position)) continue;
      // A full-height, 40px-wide target around the unchanged 24px ordinal.
      // The rest of the row keeps its normal scrolling/reordering gestures.
      final rtl = Directionality.of(context) == TextDirection.rtl;
      if (rtl ? position.dx >= row.right - 40 : position.dx < row.left + 40) {
        return entry.key;
      }
    }
    return null;
  }

  void _startRangeSelection(Offset position) {
    final key = _checkboxAt(position);
    if (key == null) return;
    _rangeOrder = _sortedTasks.map((task) => task.mediaKey).toList();
    _rangeAnchor = _rangeOrder!.indexOf(key);
    _rangeSnapshot = Set.of(widget.selectedKeys);
    _lastRangeSelection = Set.of(widget.selectedKeys);
    _rangeSelecting = !_rangeSnapshot.contains(key);
    _rangeStartPosition = _rangePosition = position;
    _rangeMoved = false;
    Tooltip.dismissAllToolTips();
    AppHaptics.pulse();
    _applyRangeAt(_rangeAnchor!);
  }

  void _updateRangeSelection(Offset position) {
    if (_rangeAnchor == null) return;
    _rangePosition = position;
    _rangeMoved |= (position - _rangeStartPosition!).distance > 4;
    if (!_rangeMoved) return;
    _applyRangeAtPointer();
    final viewport = _boxRect(_viewportKey);
    if (viewport == null || viewport.isEmpty) return;
    _rangeAutoScroller.update(
      pointerY: position.dy,
      viewportTop: viewport.top,
      viewportBottom: viewport.bottom,
    );
  }

  void _scheduleRangeUpdate() {
    if (_rangeAnchor == null || _rangeUpdateScheduled) return;
    _rangeUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rangeUpdateScheduled = false;
      if (!mounted || _rangeAnchor == null) return;
      // Variable-height rows have their new positions only after scroll layout.
      final position = _rangePosition;
      if (position != null) _updateRangeSelection(position);
    });
  }

  void _applyRangeAtPointer() {
    final position = _rangePosition;
    final viewport = _boxRect(_viewportKey);
    final order = _rangeOrder;
    if (position == null ||
        viewport == null ||
        viewport.isEmpty ||
        order == null) {
      return;
    }
    final y = position.dy.clamp(viewport.top + .01, viewport.bottom - .01);
    int? nearest;
    var distance = double.infinity;
    for (final entry in _rowKeys.entries) {
      final row = _boxRect(entry.value);
      if (row == null ||
          row.bottom <= viewport.top ||
          row.top >= viewport.bottom) {
        continue;
      }
      final delta = y < row.top
          ? row.top - y
          : y > row.bottom
          ? y - row.bottom
          : 0.0;
      if (delta >= distance) continue;
      final index = order.indexOf(entry.key);
      if (index < 0) continue;
      nearest = index;
      distance = delta;
    }
    if (nearest != null) _applyRangeAt(nearest);
  }

  void _applyRangeAt(int index) {
    final anchor = _rangeAnchor;
    final order = _rangeOrder;
    if (anchor == null || order == null) return;
    final selection = Set<String>.of(_rangeSnapshot);
    final from = anchor < index ? anchor : index;
    final to = anchor > index ? anchor : index;
    for (var i = from; i <= to; i++) {
      final key = order[i];
      if (widget.autoDeletedKeys.containsKey(key)) continue;
      if (_rangeSelecting) {
        selection.add(key);
      } else {
        selection.remove(key);
      }
    }
    selection.removeAll(widget.autoDeletedKeys.keys);
    if (setEquals(selection, _lastRangeSelection)) return;
    _lastRangeSelection = selection;
    widget.onSelectionChanged?.call(selection);
  }

  void _endRangeSelection({bool rebuild = true}) {
    final wasActive = _rangeAnchor != null;
    _rangeRecognizer?.cancelTracking();
    _rangeAutoScroller.stop();
    _rangeAnchor = null;
    _rangeOrder = null;
    _rangePosition = _rangeStartPosition = null;
    _rangeSnapshot = {};
    _lastRangeSelection = {};
    _rangeMoved = false;
    if (wasActive && rebuild && mounted) setState(() {});
  }

  void _select(BatchSubtitleTaskView task, {bool toggle = false}) {
    final selected = Set<String>.of(widget.selectedKeys);
    if (toggle && selected.contains(task.mediaKey)) {
      selected.remove(task.mediaKey);
    } else {
      selected.add(task.mediaKey);
    }
    widget.onSelectionChanged?.call(selected);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rangeAutoScroller.dispose();
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
      final empty = LayoutBuilder(
        builder: (context, constraints) => Center(
          child: SingleChildScrollView(
            controller: _scrollController,
            primary: false,
            padding: widget.scrollHeader
                ? EdgeInsets.zero
                : const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.scrollHeader && widget.header != null)
                  widget.header!,
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
      return Column(
        children: [
          if (!widget.scrollHeader && widget.header != null) widget.header!,
          Expanded(child: empty),
        ],
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

        final header = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.header != null) widget.header!,
            if (isCompact || _isSelecting)
              Padding(
                key: const ValueKey('task-queue-order-row'),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    if (_isSelecting)
                      Expanded(
                        child: Text(
                          '已选 ${widget.selectedKeys.length} 项',
                          style: const TextStyle(fontSize: 13),
                        ),
                      )
                    else
                      const Spacer(),
                    if (_isSelecting) ...[
                      TextButton(
                        key: const ValueKey('task-queue-select-all'),
                        onPressed: () => widget.onSelectionChanged?.call({
                          for (final task in tasks)
                            if (!widget.autoDeletedKeys.containsKey(
                              task.mediaKey,
                            ))
                              task.mediaKey,
                        }),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        key: const ValueKey('task-queue-cancel-selection'),
                        onPressed: () => widget.onSelectionChanged?.call({}),
                        child: const Text('取消'),
                      ),
                    ],
                    if (!_isSelecting)
                      DesktopButtonClickRegion(
                        child: TextButton.icon(
                          key: const ValueKey('task-queue-display-order'),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.standard,
                            textStyle: Theme.of(
                              context,
                            ).textTheme.labelLarge?.copyWith(fontSize: 12),
                          ),
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
          ],
        );
        return Column(
          children: [
            if (!widget.scrollHeader) header,
            Expanded(
              child: RawGestureDetector(
                key: _viewportKey,
                behavior: HitTestBehavior.opaque,
                gestures: {
                  TaskRangeSelectionGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        TaskRangeSelectionGestureRecognizer
                      >(TaskRangeSelectionGestureRecognizer.new, (recognizer) {
                        _rangeRecognizer = recognizer;
                        recognizer.canStart = (position) =>
                            widget.onSelectionChanged != null &&
                            _checkboxAt(position) != null;
                        recognizer
                          ..onStart = _startRangeSelection
                          ..onUpdate = _updateRangeSelection
                          ..onEnd = _endRangeSelection;
                      }),
                },
                child: ReorderableListView.builder(
                  header: widget.scrollHeader ? header : null,
                  scrollController: _scrollController,
                  primary: false,
                  padding: isCompact
                      ? const EdgeInsets.only(bottom: 8)
                      : EdgeInsets.zero,
                  buildDefaultDragHandles: false,
                  itemCount: tasks.length,
                  onReorderStart: (index) {
                    Tooltip.dismissAllToolTips();
                    AppHaptics.pulse();
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
                        final t = Curves.easeOutCubic.transform(
                          animation.value,
                        );
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
                    final isSelected = widget.selectedKeys.contains(
                      task.mediaKey,
                    );
                    final canDrag =
                        isSelected && task.status == TranscriptionStatus.idle;

                    final row = _TaskRow(
                      key: _rowKeys.putIfAbsent(task.mediaKey, GlobalKey.new),
                      index: taskNumbers[task.mediaKey]!,
                      task: task,
                      isWide: isWide,
                      isCompact: isCompact,
                      isAutoDeleting: isAutoDeleting,
                      onConfigure: widget.onConfigure,
                      isDragging: _dragIndex == index,
                      isHoverTarget: _hoverIndex == index,
                      isSelecting: _isSelecting,
                      isSelected: isSelected,
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

                    final selectableRow = Semantics(
                      selected: _isSelecting ? isSelected : null,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPress:
                            canDrag || widget.onSelectionChanged == null
                            ? null
                            : () {
                                AppHaptics.pulse();
                                _select(task);
                              },
                        onTap: _isSelecting
                            ? () => _select(task, toggle: true)
                            : null,
                        child: IgnorePointer(
                          ignoring: _isSelecting,
                          child: row,
                        ),
                      ),
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
                              child: selectableRow,
                            )
                          : selectableRow,
                    );
                  },
                ),
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
            key: const ValueKey('task-queue-display-order'),
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
  final bool isSelecting;
  final bool isSelected;
  final double btnSize;
  final VoidCallback onStart;
  final VoidCallback? onPause;
  final VoidCallback onRetry;
  final VoidCallback? onRestart;
  final VoidCallback onDelete;
  final VoidCallback? onTapCompleted;

  const _TaskRow({
    super.key,
    required this.index,
    required this.task,
    required this.isWide,
    required this.isCompact,
    required this.isAutoDeleting,
    this.onConfigure,
    required this.isDragging,
    required this.isHoverTarget,
    required this.isSelecting,
    required this.isSelected,
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
        isSelecting: isSelecting,
        isSelected: isSelected,
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
                : isSelected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: .08)
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
                _TaskNumber(
                  key: ValueKey('task-select-${task.mediaKey}'),
                  index: index,
                  isSelecting: isSelecting,
                  isSelected: isSelected,
                  compact: false,
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
                        '${task.videoDuration.isEmpty ? '时长待获取' : task.videoDuration}${task.processingStages.isEmpty ? '' : ' · ${task.processingStages}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                          optimizationProgress: task.optimizationProgress,
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
  final bool isSelecting, isSelected;
  final double btnSize;
  final VoidCallback onStart, onRetry, onDelete;
  final VoidCallback? onPause, onRestart, onTapCompleted, onConfigure;

  const _CompactTaskTableRow({
    required this.index,
    required this.task,
    required this.isAutoDeleting,
    required this.isDragging,
    required this.isHoverTarget,
    required this.isSelecting,
    required this.isSelected,
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
    final statusStyle = DefaultTextStyle.of(
      context,
    ).style.merge(const TextStyle(fontSize: 13));
    // Reserve four characters with the actual font and system text scale.
    final labelMeasure = TextPainter(
      text: TextSpan(text: '识别语音', style: statusStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final statusWidth = (labelMeasure.width.ceilToDouble() + 8).clamp(
      60.0,
      120.0,
    );
    labelMeasure.dispose();
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
          color: isDragging
              ? theme.colorScheme.surfaceContainerHighest
              : isSelected
              ? theme.colorScheme.primary.withValues(alpha: .08)
              : null,
          border: Border(
            bottom: BorderSide(
              color: theme.colorScheme.onSurface.withValues(alpha: .10),
            ),
          ),
        ),
        child: Row(
          children: [
            _TaskNumber(
              key: ValueKey('task-select-${task.mediaKey}'),
              index: index,
              isSelecting: isSelecting,
              isSelected: isSelected,
              compact: true,
            ),
            const SizedBox(width: 5),
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
                        '${task.videoDuration.isEmpty ? "时长待获取" : task.videoDuration} · ${task.isExternal ? "外部媒体" : "媒体库"}${task.processingStages.isEmpty ? '' : ' · ${task.processingStages}'}',
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
                      if (isProcessing &&
                          task.optimizationProgress != null) ...[
                        const SizedBox(height: 4),
                        SubtitleOptimizationProgressView(
                          progress: task.optimizationProgress!,
                          foregroundColor: color,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: statusWidth,
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
                        task.translationProgress != null ? '翻译' : status,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: color),
                      ),
                      if (isProcessing) ...[
                        const SizedBox(height: 4),
                        LinearProgressIndicator(
                          value: (task.translationProgress ?? task.progress)
                              .clamp(0, 1),
                          minHeight: 2,
                          backgroundColor: theme.colorScheme.onSurface
                              .withValues(alpha: .1),
                        ),
                        Text(
                          '${((task.translationProgress ?? task.progress) * 100).round()}%',
                          style: TextStyle(fontSize: 13, color: color),
                        ),
                        if (task.translationProgress != null)
                          Text(
                            '总进度 ${(task.progress * 100).round()}%',
                            style: TextStyle(fontSize: 10, color: color),
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

/// The ordinal keeps its size and position when it becomes a selection box.
class _TaskNumber extends StatelessWidget {
  const _TaskNumber({
    super.key,
    required this.index,
    required this.isSelecting,
    required this.isSelected,
    required this.compact,
  });

  final int index;
  final bool isSelecting, isSelected, compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '任务 $index',
      checked: isSelecting ? isSelected : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOutCubic,
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelecting && isSelected
              ? scheme.primary
              : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: !isSelecting
                ? Colors.transparent
                : isSelected
                ? scheme.primary
                : scheme.outlineVariant,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '$index',
              style: TextStyle(
                fontSize: compact ? 11 : 13,
                fontWeight: FontWeight.w500,
                color: isSelecting && isSelected
                    ? scheme.onPrimary
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
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
  final SubtitleOptimizationProgress? optimizationProgress;
  final LocalAsrProgress? localAsrProgress;
  final TranscriptionAudioProgress? audioProgress;
  final String statusMessage;
  final String videoName;

  const _ProgressIndicator({
    required this.status,
    required this.progress,
    this.translationProgress,
    this.optimizationProgress,
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
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _LocalProcessingProgress(
            progress: progress,
            audio: audioProgress,
            local: localAsrProgress,
            fontSize: 13,
          ),
          if (optimizationProgress != null) ...[
            const SizedBox(height: 5),
            SubtitleOptimizationProgressView(progress: optimizationProgress!),
          ],
        ],
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
        if (optimizationProgress != null) ...[
          const SizedBox(height: 5),
          SubtitleOptimizationProgressView(progress: optimizationProgress!),
        ],
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
