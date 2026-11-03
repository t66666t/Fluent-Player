import '../utils/deferred_subtitle_edits.dart';
import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'landscape_sidebar_layout.dart';
import 'operation_status.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../models/subtitle_model.dart';
import '../services/settings_service.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

typedef SubtitleGroupPathCallback = Future<void> Function(String path);
typedef SubtitleGroupNameCallback = Future<void> Function(String name);
typedef SubtitleGroupRenameCallback =
    Future<void> Function(String oldName, String newName);
typedef SubtitleItemsPersistCallback =
    Future<void> Function(List<SubtitleItem> subtitles);

class LandscapeSubtitleEditorSidebar extends StatefulWidget {
  final Map<String, String> groups;
  final String? activeGroupPath;
  final String? documentId;
  final List<SubtitleItem> subtitles;
  final int currentSubtitleIndex;
  final Duration currentPlaybackPosition;
  final SubtitleGroupPathCallback onSelectGroupPath;
  final SubtitleGroupNameCallback onCreateGroup;
  final SubtitleGroupRenameCallback onRenameGroup;
  final SubtitleItemsPersistCallback onSubtitlesChanged;
  final ValueChanged<Duration> onSeekTo;
  final VoidCallback onClose;

  const LandscapeSubtitleEditorSidebar({
    super.key,
    required this.groups,
    required this.activeGroupPath,
    this.documentId,
    required this.subtitles,
    required this.currentSubtitleIndex,
    required this.currentPlaybackPosition,
    required this.onSelectGroupPath,
    required this.onCreateGroup,
    required this.onRenameGroup,
    required this.onSubtitlesChanged,
    required this.onSeekTo,
    required this.onClose,
  });

  @override
  State<LandscapeSubtitleEditorSidebar> createState() =>
      _LandscapeSubtitleEditorSidebarState();
}

class _LandscapeSubtitleEditorSidebarState
    extends State<LandscapeSubtitleEditorSidebar>
    with WidgetsBindingObserver {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  final List<List<SubtitleItem>> _undoStack = <List<SubtitleItem>>[];
  final List<List<SubtitleItem>> _redoStack = <List<SubtitleItem>>[];
  final _edits = DeferredSubtitleEdits();
  List<SubtitleItem> _editingSubtitles = <SubtitleItem>[];
  String? _selectedGroupPath;
  bool _deleteMode = false;
  int _lastAutoFollowTargetIndex = -1;
  // Animated indexed-list transitions can mount the same line in two
  // viewports. Track mounted editors without sharing a GlobalKey between them.
  final Map<int, Set<_SubtitleEditRowState>> _rowsByStartMs = {};
  final Set<int> _focusedEditorRowStartMs = <int>{};
  DateTime? _lastKeyboardRepeatAt;
  int _keyboardRepeatStreak = 0;
  int _keyboardRepeatDirection = 0;
  DateTime _suppressAutoFollowUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _autoFollowResumeTimer;
  double _lastViewInsetBottom = 0;
  String? _saveError;
  bool _retryingSave = false;
  int _saveRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastViewInsetBottom = _currentViewInsetBottom();
    _syncFromWidget(resetHistory: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryAutoFollow(force: true);
    });
  }

  @override
  void didUpdateWidget(covariant LandscapeSubtitleEditorSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool groupChanged =
        (oldWidget.documentId ?? oldWidget.activeGroupPath) !=
        (widget.documentId ?? widget.activeGroupPath);
    final bool subtitlesChanged = oldWidget.subtitles != widget.subtitles;
    final bool indexChanged =
        oldWidget.currentSubtitleIndex != widget.currentSubtitleIndex;
    final bool positionChanged =
        oldWidget.currentPlaybackPosition != widget.currentPlaybackPosition;

    if (groupChanged) {
      _saveRevision++;
      _saveError = null;
      _edits.flushInBackground();
    }
    if (groupChanged || subtitlesChanged && !_edits.hasPending) {
      _syncFromWidget(resetHistory: groupChanged);
    }
    if (groupChanged || subtitlesChanged || positionChanged) {
      _lastAutoFollowTargetIndex = -1;
    }
    if (indexChanged) {
      setState(() {});
    }
    _tryAutoFollow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _edits.flushInBackground();
    _autoFollowResumeTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final double currentInsetBottom = _currentViewInsetBottom();
    final bool keyboardJustDismissed =
        _lastViewInsetBottom > 0.5 && currentInsetBottom <= 0.5;
    _lastViewInsetBottom = currentInsetBottom;
    if (keyboardJustDismissed && _focusedEditorRowStartMs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _unfocusAllEditors();
      });
    }
  }

  double _currentViewInsetBottom() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  int _resolveCurrentTargetIndex() {
    if (_editingSubtitles.isEmpty) return -1;
    if (widget.currentSubtitleIndex >= 0 &&
        widget.currentSubtitleIndex < _editingSubtitles.length) {
      return widget.currentSubtitleIndex;
    }
    final int positionMs = widget.currentPlaybackPosition.inMilliseconds;
    int bestIndex = 0;
    int bestDistance = 1 << 30;
    for (int i = 0; i < _editingSubtitles.length; i++) {
      final SubtitleItem item = _editingSubtitles[i];
      final int startMs = item.startTime.inMilliseconds;
      final int endMs = item.endTime.inMilliseconds;
      final int distance = positionMs < startMs
          ? (startMs - positionMs)
          : (positionMs > endMs ? (positionMs - endMs) : 0);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  void _scrollToIndexAtThirtyPercent(
    int targetIndex, {
    required bool isAuto,
    required int attempt,
  }) {
    if (!mounted) return;
    const int maxAttempts = 6;
    if (!_itemScrollController.isAttached) {
      if (attempt < maxAttempts) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToIndexAtThirtyPercent(
            targetIndex,
            isAuto: isAuto,
            attempt: attempt + 1,
          );
        });
      }
      return;
    }
    _itemScrollController.scrollTo(
      index: targetIndex,
      duration: isAuto
          ? const Duration(milliseconds: 180)
          : const Duration(milliseconds: 260),
      curve: Curves.easeInOut,
      alignment: 0.30,
    );
  }

  void _locateCurrentSubtitle({required bool isAuto}) {
    final int target = _resolveCurrentTargetIndex();
    if (target < 0 || target >= _editingSubtitles.length) return;
    _lastAutoFollowTargetIndex = target;
    _scrollToIndexAtThirtyPercent(target, isAuto: isAuto, attempt: 0);
  }

  void _tryAutoFollow({bool force = false}) {
    if (!mounted || !SettingsService().subtitleEditorAutoFollow) return;
    if (_focusedEditorRowStartMs.isNotEmpty) return;
    if (DateTime.now().isBefore(_suppressAutoFollowUntil)) return;
    final int target = _resolveCurrentTargetIndex();
    if (target < 0) return;
    if (!force && target == _lastAutoFollowTargetIndex) return;
    _locateCurrentSubtitle(isAuto: true);
  }

  void _deferAutoFollow([
    Duration duration = const Duration(milliseconds: 1200),
  ]) {
    _suppressAutoFollowUntil = DateTime.now().add(duration);
  }

  void _clearAutoFollowDeferral() {
    _suppressAutoFollowUntil = DateTime.fromMillisecondsSinceEpoch(0);
  }

  bool get _isAutoFollowPausedForEditing => _focusedEditorRowStartMs.isNotEmpty;

  void _cancelAutoFollowResume() {
    _autoFollowResumeTimer?.cancel();
    _autoFollowResumeTimer = null;
  }

  void _scheduleAutoFollowResume() {
    _cancelAutoFollowResume();
    _autoFollowResumeTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      if (!SettingsService().subtitleEditorAutoFollow) {
        setState(() {});
        return;
      }
      if (_focusedEditorRowStartMs.isNotEmpty) return;
      _clearAutoFollowDeferral();
      setState(() {});
      _tryAutoFollow(force: true);
    });
  }

  void _handleEditorFocusChanged(SubtitleItem item, bool hasFocus) {
    final int startMs = item.startTime.inMilliseconds;
    final bool changed = hasFocus
        ? _focusedEditorRowStartMs.add(startMs)
        : _focusedEditorRowStartMs.remove(startMs);
    if (!changed) return;
    if (hasFocus) {
      _cancelAutoFollowResume();
      _deferAutoFollow(const Duration(milliseconds: 240));
    } else if (_focusedEditorRowStartMs.isEmpty) {
      _scheduleAutoFollowResume();
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _unfocusAllEditors() {
    final List<int> focusedRows = _focusedEditorRowStartMs.toList();
    for (final int startMs in focusedRows) {
      for (final row
          in _rowsByStartMs[startMs]?.toList() ?? <_SubtitleEditRowState>[]) {
        row.clearEditorFocus();
      }
    }
  }

  Widget _buildToolbarButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget icon,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      preferBelow: false,
      verticalOffset: 18,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      textStyle: const TextStyle(color: Colors.white, fontSize: 11),
      decoration: BoxDecoration(
        color: const Color(0xEE141414),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white12),
      ),
      child: DesktopButtonClickRegion(
        child: IconButton(
          onPressed: onPressed,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          splashRadius: 18,
          icon: icon,
        ),
      ),
    );
  }

  void _syncFromWidget({required bool resetHistory}) {
    _selectedGroupPath = widget.activeGroupPath;
    _editingSubtitles = List<SubtitleItem>.from(widget.subtitles);
    if (resetHistory) {
      _undoStack.clear();
      _redoStack.clear();
      _deleteMode = false;
    }
    _rowsByStartMs.removeWhere(
      (startMs, _) => !_editingSubtitles.any(
        (item) => item.startTime.inMilliseconds == startMs,
      ),
    );
    if (mounted) setState(() {});
  }

  void _registerEditor(_SubtitleEditRowState row, bool mounted) {
    final startMs = row.widget.item.startTime.inMilliseconds;
    if (mounted) {
      (_rowsByStartMs[startMs] ??= {}).add(row);
    } else {
      final rows = _rowsByStartMs[startMs];
      rows?.remove(row);
      if (rows?.isEmpty ?? false) _rowsByStartMs.remove(startMs);
    }
  }

  void _scrollToIndexForKeyboardNavigation({
    required int targetIndex,
    required int direction,
    int attempt = 0,
  }) {
    if (!mounted) return;
    const int maxAttempts = 6;
    if (!_itemScrollController.isAttached) {
      if (attempt < maxAttempts) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToIndexForKeyboardNavigation(
            targetIndex: targetIndex,
            direction: direction,
            attempt: attempt + 1,
          );
        });
      }
      return;
    }
    final positions = _itemPositionsListener.itemPositions.value;
    bool isFullyVisible = false;
    for (final position in positions) {
      if (position.index != targetIndex) continue;
      if (position.itemLeadingEdge >= 0 && position.itemTrailingEdge <= 1) {
        isFullyVisible = true;
      }
      break;
    }
    if (isFullyVisible) return;
    _itemScrollController.scrollTo(
      index: targetIndex,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      alignment: direction > 0 ? 0.82 : 0.18,
    );
  }

  void _focusRowEditor(int index, {required int preferredOffset}) {
    if (index < 0 || index >= _editingSubtitles.length) return;
    final SubtitleItem targetItem = _editingSubtitles[index];
    final int startMs = targetItem.startTime.inMilliseconds;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rows = _rowsByStartMs[startMs];
      if (rows == null) return;
      for (final row in rows) {
        if (!row.mounted) continue;
        row.requestEditorFocus(preferredOffset: preferredOffset);
        break;
      }
    });
  }

  void _navigateByOffsetFromEditor({
    required int fromIndex,
    required int offset,
    int? preferredOffset,
    bool moveCaretToEnd = false,
    bool isKeyRepeat = false,
    bool preferGentleRepeat = false,
  }) {
    _deferAutoFollow(const Duration(milliseconds: 700));
    if (isKeyRepeat) {
      final DateTime now = DateTime.now();
      final bool sameDirection = _keyboardRepeatDirection == offset;
      if (!sameDirection) {
        _keyboardRepeatStreak = 0;
      }
      if (_lastKeyboardRepeatAt != null &&
          now.difference(_lastKeyboardRepeatAt!) >
              const Duration(milliseconds: 220)) {
        _keyboardRepeatStreak = 0;
      }
      _keyboardRepeatStreak += 1;
      _keyboardRepeatDirection = offset;
      final int maxGapMs = preferGentleRepeat ? 112 : 92;
      final int minGapFloor = preferGentleRepeat ? 64 : 52;
      final int accelStep = preferGentleRepeat ? 5 : 6;
      final int minGapMs = (maxGapMs - (_keyboardRepeatStreak * accelStep))
          .clamp(minGapFloor, maxGapMs);
      if (_lastKeyboardRepeatAt != null &&
          now.difference(_lastKeyboardRepeatAt!) <
              Duration(milliseconds: minGapMs)) {
        return;
      }
      _lastKeyboardRepeatAt = now;
    } else {
      _keyboardRepeatStreak = 0;
      _keyboardRepeatDirection = offset;
      _lastKeyboardRepeatAt = DateTime.now();
    }
    if (_editingSubtitles.isEmpty) return;
    final int safeFrom = fromIndex.clamp(0, _editingSubtitles.length - 1);
    final int target = (safeFrom + offset).clamp(
      0,
      _editingSubtitles.length - 1,
    );
    if (target == safeFrom) return;
    final SubtitleItem targetItem = _editingSubtitles[target];
    widget.onSeekTo(targetItem.startTime);
    _scrollToIndexForKeyboardNavigation(targetIndex: target, direction: offset);
    _focusRowEditor(
      target,
      preferredOffset: moveCaretToEnd
          ? _editingSubtitles[target].text.length
          : (preferredOffset ?? _editingSubtitles[target].text.length),
    );
  }

  void _pushUndoSnapshot() {
    _undoStack.add(List<SubtitleItem>.from(_editingSubtitles));
    if (_undoStack.length > 500) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  Future<void> _persistNow() {
    _persistDebounced();
    return _edits.flush();
  }

  void _persistDebounced() {
    final documentId = widget.documentId ?? widget.activeGroupPath;
    final persist = widget.onSubtitlesChanged;
    final revision = ++_saveRevision;
    bool isCurrent() =>
        mounted &&
        revision == _saveRevision &&
        documentId == (widget.documentId ?? widget.activeGroupPath);
    _edits.schedule(_editingSubtitles, (subtitles) async {
      try {
        await persist(subtitles);
        if (isCurrent() && _saveError != null) {
          setState(() => _saveError = null);
        }
      } catch (error) {
        if (isCurrent()) {
          setState(
            () => _saveError = operationErrorSummary(
              error,
              fallback: '字幕修改尚未保存，请重试。',
            ),
          );
        }
        rethrow;
      }
    }, documentId: documentId);
  }

  Future<void> _retrySave() async {
    if (_retryingSave) return;
    setState(() => _retryingSave = true);
    try {
      await _edits.flushForAction();
    } finally {
      if (mounted) setState(() => _retryingSave = false);
    }
  }

  Future<void> _saveAndClose() async {
    if (!await _edits.flushForAction() || !mounted) {
      return;
    }
    if (mounted) widget.onClose();
  }

  void _applyTextEdit(int index, String value) {
    if (index < 0 || index >= _editingSubtitles.length) return;
    _deferAutoFollow();
    final SubtitleItem current = _editingSubtitles[index];
    if (current.text == value) return;
    _pushUndoSnapshot();
    _editingSubtitles[index] = current.copyWith(text: value);
    // Note: Do not call setState to avoid rebuilding the entire list while typing
    // since we use initialValue in TextFormField, it maintains its own state.
    // However, if we need to sync, we might need a more granular approach.
    _persistDebounced();
  }

  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;
    _redoStack.add(List<SubtitleItem>.from(_editingSubtitles));
    _editingSubtitles = _undoStack.removeLast();
    setState(() {});
    await _persistNow();
  }

  Future<void> _redo() async {
    if (_redoStack.isEmpty) return;
    _undoStack.add(List<SubtitleItem>.from(_editingSubtitles));
    _editingSubtitles = _redoStack.removeLast();
    setState(() {});
    await _persistNow();
  }

  Future<void> _deleteAt(int index) async {
    if (index < 0 || index >= _editingSubtitles.length) return;
    _pushUndoSnapshot();
    _editingSubtitles.removeAt(index);
    setState(() {});
    await _persistNow();
  }

  Future<void> _promptCreateGroup() async {
    if (!await _edits.flushForAction() || !mounted) {
      return;
    }
    final controller = TextEditingController(text: '手动字幕');
    final String? name = await showDialog<String>(
      context: context,
      builder: (context) {
        return DialogKeyboardViewport(
          child: AlertDialog(
            title: const Text('新建分组'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '输入分组名称'),
            ),
            actions: [
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ),
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () =>
                      Navigator.pop(context, controller.text.trim()),
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (name == null || name.isEmpty) return;
    await widget.onCreateGroup(name);
  }

  Future<void> _promptRenameGroup() async {
    if (!await _edits.flushForAction() || !mounted) {
      return;
    }
    if (_selectedGroupPath == null) return;
    String? oldName;
    for (final entry in widget.groups.entries) {
      if (entry.value == _selectedGroupPath) {
        oldName = entry.key;
        break;
      }
    }
    if (oldName == null || oldName.isEmpty) return;
    final controller = TextEditingController(text: oldName);
    final String? nextName = await showDialog<String>(
      context: context,
      builder: (context) {
        return DialogKeyboardViewport(
          child: AlertDialog(
            title: const Text('重命名分组'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '输入新名称'),
            ),
            actions: [
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ),
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: () =>
                      Navigator.pop(context, controller.text.trim()),
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (nextName == null || nextName.isEmpty || nextName == oldName) return;
    await widget.onRenameGroup(oldName, nextName);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final sidebarSize =
        MediaQuery.orientationOf(context) == Orientation.landscape
        ? Size(
            LandscapeSidebarLayout.functionalWidthFor(screenSize),
            screenSize.height,
          )
        : screenSize;
    final layout = LandscapeSidebarLayout.fromSize(sidebarSize);
    final List<MapEntry<String, String>> groupEntries = widget.groups.entries
        .toList();

    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: SingleChildScrollView(
              key: const PageStorageKey('subtitle-editor-toolbar-scroll'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Container(
                    height: layout.headerHeight,
                    padding: EdgeInsets.symmetric(
                      horizontal: layout.horizontalPadding,
                    ),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Colors.white10)),
                    ),
                    child: Row(
                      children: [
                        Text(
                          '字幕编辑',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: layout.titleSize,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white70,
                            ),
                            onPressed: _saveAndClose,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Tools Row
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      layout.horizontalPadding,
                      layout.verticalPadding,
                      layout.horizontalPadding,
                      layout.verticalPadding / 2,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: CapsuleDropdownButtonFormField<String>(
                            initialValue: _selectedGroupPath,
                            dropdownColor: const Color(0xFF2A2A2A),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              border: OutlineInputBorder(),
                            ),
                            items: groupEntries
                                .map(
                                  (entry) => DropdownMenuItem<String>(
                                    value: entry.value,
                                    child: Text(
                                      entry.key,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: layout.bodySize,
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (path) async {
                              if (path == null || path.isEmpty) return;
                              if (!await _edits.flushForAction() || !mounted) {
                                return;
                              }
                              setState(() {
                                _selectedGroupPath = path;
                              });
                              await widget.onSelectGroupPath(path);
                            },
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: _promptCreateGroup,
                            icon: const Icon(
                              Icons.create_new_folder_outlined,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: _promptRenameGroup,
                            icon: const Icon(
                              Icons.drive_file_rename_outline,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: layout.horizontalPadding,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 2,
                        runSpacing: 2,
                        children: [
                          _buildToolbarButton(
                            tooltip: '撤回上一步',
                            onPressed: _undoStack.isEmpty ? null : _undo,
                            icon: Icon(
                              Icons.undo,
                              color: _undoStack.isEmpty
                                  ? Colors.white24
                                  : Colors.white70,
                              size: 20,
                            ),
                          ),
                          _buildToolbarButton(
                            tooltip: '恢复上一步',
                            onPressed: _redoStack.isEmpty ? null : _redo,
                            icon: Icon(
                              Icons.redo,
                              color: _redoStack.isEmpty
                                  ? Colors.white24
                                  : Colors.white70,
                              size: 20,
                            ),
                          ),
                          _buildToolbarButton(
                            tooltip: _deleteMode ? '关闭删除模式' : '开启删除模式',
                            onPressed: () {
                              setState(() {
                                _deleteMode = !_deleteMode;
                              });
                            },
                            icon: Icon(
                              Icons.delete_outline,
                              color: _deleteMode
                                  ? Colors.redAccent
                                  : Colors.white70,
                              size: 20,
                            ),
                          ),
                          _buildToolbarButton(
                            tooltip: '定位到当前字幕',
                            onPressed: () =>
                                _locateCurrentSubtitle(isAuto: false),
                            icon: const Icon(
                              Icons.my_location,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                          _buildToolbarButton(
                            tooltip: SettingsService().subtitleEditorAutoFollow
                                ? (_isAutoFollowPausedForEditing
                                      ? '自动跟随字幕（编辑中暂时暂停）'
                                      : '关闭自动跟随字幕')
                                : '开启自动跟随字幕',
                            onPressed: () {
                              final bool newValue =
                                  !SettingsService().subtitleEditorAutoFollow;
                              SettingsService()
                                  .updateSetting(
                                    'subtitleEditorAutoFollow',
                                    newValue,
                                  )
                                  .then((_) {
                                    if (!mounted) return;
                                    setState(() {});
                                    if (newValue) {
                                      _tryAutoFollow(force: true);
                                    }
                                  });
                            },
                            icon: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Icon(
                                  SettingsService().subtitleEditorAutoFollow
                                      ? Icons.gps_fixed
                                      : Icons.gps_not_fixed,
                                  color:
                                      SettingsService().subtitleEditorAutoFollow
                                      ? (_isAutoFollowPausedForEditing
                                            ? Colors.blueAccent.withValues(
                                                alpha: 0.6,
                                              )
                                            : Colors.blueAccent)
                                      : Colors.white70,
                                  size: 20,
                                ),
                                if (SettingsService().subtitleEditorAutoFollow)
                                  const Positioned(
                                    right: -1,
                                    bottom: -1,
                                    child: Text(
                                      'A',
                                      style: TextStyle(
                                        fontSize: 7,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blueAccent,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (_saveError != null)
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: layout.horizontalPadding,
                      ),
                      child: OperationStatus(
                        key: const ValueKey('subtitle-editor-save-error'),
                        title: _saveError!,
                        kind: OperationStatusKind.error,
                        actions: [
                          DesktopButtonClickRegion(
                            child: TextButton(
                              key: const ValueKey('subtitle-editor-retry-save'),
                              onPressed: _retryingSave ? null : _retrySave,
                              child: Text(_retryingSave ? '正在保存…' : '重试保存'),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Subtitles Document View
          Expanded(
            child: ScrollablePositionedList.builder(
              key: const PageStorageKey('subtitle-editor-lines'),
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
              itemCount: _editingSubtitles.length,
              itemBuilder: (context, index) {
                final item = _editingSubtitles[index];
                final isCurrent = index == widget.currentSubtitleIndex;
                final bool isEven = index % 2 == 0;

                return _SubtitleEditRow(
                  key: ValueKey(item.startTime.inMilliseconds),
                  onRegistrationChanged: _registerEditor,
                  item: item,
                  isCurrent: isCurrent,
                  isEven: isEven,
                  isDeleteMode: _deleteMode,
                  onChanged: (val) => _applyTextEdit(index, val),
                  onEditorInteraction: () => _deferAutoFollow(),
                  onEditorFocusChanged: (hasFocus) =>
                      _handleEditorFocusChanged(item, hasFocus),
                  onNavigateByOffset:
                      ({
                        required int offset,
                        int? preferredOffset,
                        bool moveCaretToEnd = false,
                        bool isKeyRepeat = false,
                        bool preferGentleRepeat = false,
                      }) {
                        _navigateByOffsetFromEditor(
                          fromIndex: index,
                          offset: offset,
                          preferredOffset: preferredOffset,
                          moveCaretToEnd: moveCaretToEnd,
                          isKeyRepeat: isKeyRepeat,
                          preferGentleRepeat: preferGentleRepeat,
                        );
                      },
                  onSeek: () => widget.onSeekTo(item.startTime),
                  onDelete: () => _deleteAt(index),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SubtitleEditRow extends StatefulWidget {
  final void Function(_SubtitleEditRowState row, bool mounted)
  onRegistrationChanged;
  final SubtitleItem item;
  final bool isCurrent;
  final bool isEven;
  final bool isDeleteMode;
  final ValueChanged<String> onChanged;
  final VoidCallback onEditorInteraction;
  final ValueChanged<bool> onEditorFocusChanged;
  final void Function({
    required int offset,
    int? preferredOffset,
    bool moveCaretToEnd,
    bool isKeyRepeat,
    bool preferGentleRepeat,
  })
  onNavigateByOffset;
  final VoidCallback onSeek;
  final VoidCallback onDelete;

  const _SubtitleEditRow({
    super.key,
    required this.onRegistrationChanged,
    required this.item,
    required this.isCurrent,
    required this.isEven,
    required this.isDeleteMode,
    required this.onChanged,
    required this.onEditorInteraction,
    required this.onEditorFocusChanged,
    required this.onNavigateByOffset,
    required this.onSeek,
    required this.onDelete,
  });

  @override
  State<_SubtitleEditRow> createState() => _SubtitleEditRowState();
}

class _SubtitleEditRowState extends State<_SubtitleEditRow> {
  late TextEditingController _controller;
  final FocusNode _textFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.item.text);
    _textFocusNode.addListener(_handleFocusChange);
    widget.onRegistrationChanged(this, true);
  }

  @override
  void didUpdateWidget(covariant _SubtitleEditRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.text != widget.item.text &&
        _controller.text != widget.item.text) {
      // This happens on Undo/Redo or external changes
      final selection = _controller.selection;
      _controller.text = widget.item.text;
      // Try to preserve selection if possible, otherwise move to end
      if (selection.isValid && selection.end <= widget.item.text.length) {
        _controller.selection = selection;
      } else {
        _controller.selection = TextSelection.collapsed(
          offset: widget.item.text.length,
        );
      }
    }
  }

  @override
  void dispose() {
    widget.onRegistrationChanged(this, false);
    if (_textFocusNode.hasFocus) {
      widget.onEditorFocusChanged(false);
    }
    _textFocusNode.removeListener(_handleFocusChange);
    _textFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  int _currentCaretOffset() {
    final selection = _controller.selection;
    if (!selection.isValid) return _controller.text.length;
    final int offset = selection.extentOffset;
    if (offset < 0) return _controller.text.length;
    if (offset > _controller.text.length) return _controller.text.length;
    return offset;
  }

  void _handleFocusChange() {
    widget.onEditorFocusChanged(_textFocusNode.hasFocus);
  }

  void clearEditorFocus() {
    if (_textFocusNode.hasFocus) {
      _textFocusNode.unfocus();
    }
  }

  void requestEditorFocus({int? preferredOffset}) {
    if (!mounted) return;
    _textFocusNode.requestFocus();
    final int targetOffset = preferredOffset ?? _controller.text.length;
    final int clampedOffset = targetOffset.clamp(0, _controller.text.length);
    _controller.selection = TextSelection.collapsed(offset: clampedOffset);
  }

  void _insertNewLineAtSelection() {
    final String text = _controller.text;
    final TextSelection selection = _controller.selection;
    final int start = selection.isValid
        ? selection.start.clamp(0, text.length)
        : text.length;
    final int end = selection.isValid
        ? selection.end.clamp(0, text.length)
        : text.length;
    final String nextText = text.replaceRange(start, end, '\n');
    final int nextOffset = start + 1;
    _controller.value = _controller.value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
      composing: TextRange.empty,
    );
    widget.onChanged(nextText);
  }

  KeyEventResult _handleEditorKeyEvent(FocusNode node, KeyEvent event) {
    final bool isArrowUp = event.logicalKey == LogicalKeyboardKey.arrowUp;
    final bool isArrowDown = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final bool isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    final bool isRepeat = event is KeyRepeatEvent;
    final bool isDown = event is KeyDownEvent;
    if ((isArrowUp || isArrowDown) && (isDown || isRepeat)) {
      widget.onNavigateByOffset(
        offset: isArrowUp ? -1 : 1,
        preferredOffset: _currentCaretOffset(),
        isKeyRepeat: isRepeat,
      );
      return KeyEventResult.handled;
    }
    if (isEnter && (isDown || isRepeat)) {
      if (HardwareKeyboard.instance.isControlPressed) {
        if (!isDown) return KeyEventResult.handled;
        _insertNewLineAtSelection();
      } else {
        widget.onNavigateByOffset(
          offset: 1,
          moveCaretToEnd: true,
          isKeyRepeat: isRepeat,
          preferGentleRepeat: true,
        );
      }
      return KeyEventResult.handled;
    }
    if (!isDown) return KeyEventResult.ignored;
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final sidebarSize =
        MediaQuery.orientationOf(context) == Orientation.landscape
        ? Size(
            LandscapeSidebarLayout.functionalWidthFor(screenSize),
            screenSize.height,
          )
        : screenSize;
    final layout = LandscapeSidebarLayout.fromSize(sidebarSize);
    final Color bgColor = widget.isCurrent
        ? Colors.white.withValues(alpha: 0.1)
        : (widget.isEven
              ? Colors.transparent
              : Colors.white.withValues(alpha: 0.03));

    return Container(
      color: widget.isDeleteMode
          ? (widget.isEven
                ? Colors.redAccent.withValues(alpha: 0.05)
                : Colors.redAccent.withValues(alpha: 0.1))
          : bgColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Editable Text Area
          Expanded(
            child: GestureDetector(
              onTap: widget.isDeleteMode ? widget.onDelete : null,
              child: AbsorbPointer(
                absorbing: widget.isDeleteMode,
                child: Focus(
                  onKeyEvent: _handleEditorKeyEvent,
                  child: TextField(
                    key: PageStorageKey((
                      'subtitle-editor-text-scroll',
                      widget.item.startTime.inMicroseconds,
                    )),
                    controller: _controller,
                    focusNode: _textFocusNode,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: layout.bodySize,
                      height: layout.isCompactHeight ? 1.3 : 1.4,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.fromLTRB(
                        layout.horizontalPadding,
                        layout.verticalPadding / 2,
                        layout.horizontalPadding / 2,
                        layout.verticalPadding / 2,
                      ),
                      border: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                    ),
                    onTap: widget.onEditorInteraction,
                    onTapOutside: (_) => _textFocusNode.unfocus(),
                    onChanged: (value) {
                      widget.onEditorInteraction();
                      widget.onChanged(value);
                    },
                  ),
                ),
              ),
            ),
          ),
          // Time Indicator (Clickable to Seek)
          InkWell(
            onTap: widget.onSeek,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: layout.horizontalPadding / 2,
                vertical: layout.verticalPadding,
              ),
              child: Text(
                _formatDuration(widget.item.startTime),
                style: TextStyle(
                  color: widget.isCurrent
                      ? theme.colorScheme.primary
                      : Colors.white38,
                  fontSize: layout.captionSize,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final int hours = d.inHours;
    final int minutes = d.inMinutes.remainder(60);
    final int seconds = d.inSeconds.remainder(60);
    return '${hours > 0 ? '$hours:' : ''}${two(minutes)}:${two(seconds)}';
  }
}
