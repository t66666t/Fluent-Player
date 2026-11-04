import '../utils/deferred_subtitle_edits.dart';
import 'package:video_player_app/widgets/dialog_keyboard_viewport.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'keyboard_inset_padding.dart';
import 'operation_status.dart';
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

class SubtitleEditorPanel extends StatefulWidget {
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
  final VoidCallback onBack;
  final bool isExpanded;
  final VoidCallback onToggleExpanded;

  const SubtitleEditorPanel({
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
    required this.onBack,
    required this.isExpanded,
    required this.onToggleExpanded,
  });

  @override
  State<SubtitleEditorPanel> createState() => _SubtitleEditorPanelState();
}

class _SubtitleEditorPanelState extends State<SubtitleEditorPanel>
    with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _textFocusNode = FocusNode();
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  final List<List<SubtitleItem>> _undoStack = <List<SubtitleItem>>[];
  final List<List<SubtitleItem>> _redoStack = <List<SubtitleItem>>[];
  final _edits = DeferredSubtitleEdits();
  List<SubtitleItem> _editingSubtitles = <SubtitleItem>[];
  String? _selectedGroupPath;
  int _selectedIndex = -1;
  bool _deleteMode = false;
  bool _isApplyingText = false;
  int _lastAutoFollowTargetIndex = -1;
  double _listViewportHeight = 0;
  bool _needsViewportRepair = false;
  bool _viewportRepairScheduled = false;
  double _lastKeyboardInset = 0;
  String? _saveError;
  bool _retryingSave = false;
  int _saveRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastKeyboardInset = _keyboardInset;
    _syncFromWidget(resetHistory: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tryAutoFollow(force: true);
    });
  }

  @override
  void didUpdateWidget(covariant SubtitleEditorPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool groupChanged =
        (oldWidget.documentId ?? oldWidget.activeGroupPath) !=
        (widget.documentId ?? widget.activeGroupPath);
    // Saving an edit sends a new list back through the player. It is an
    // acknowledgement, not a new document or a reason to move the caret.
    final bool subtitlesChanged =
        oldWidget.subtitles != widget.subtitles &&
        !listEquals(_editingSubtitles, widget.subtitles);
    final bool positionChanged =
        oldWidget.currentPlaybackPosition != widget.currentPlaybackPosition;
    if (groupChanged) {
      _saveRevision++;
      _saveError = null;
      _edits.flushInBackground();
    }
    if (groupChanged || subtitlesChanged && !_edits.hasPending) {
      _syncFromWidget(resetHistory: groupChanged);
    } else if (_selectedIndex == -1 &&
        widget.currentSubtitleIndex >= 0 &&
        widget.currentSubtitleIndex < _editingSubtitles.length) {
      _selectedIndex = widget.currentSubtitleIndex;
      _syncTextController();
    }
    if (groupChanged || subtitlesChanged || positionChanged) {
      _lastAutoFollowTargetIndex = -1;
    }
    _tryAutoFollow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _edits.flushInBackground();
    _textFocusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  double get _keyboardInset =>
      WidgetsBinding.instance.platformDispatcher.views.first.viewInsets.bottom;

  @override
  void didChangeMetrics() {
    final nextInset = _keyboardInset;
    if (_lastKeyboardInset > 0 && nextInset == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Native back can hide the IME without removing focus. Resume normal
        // playback following on its next update, after the viewport recovers.
        if (_keyboardInset == 0) _textFocusNode.unfocus();
      });
    }
    _lastKeyboardInset = nextInset;
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
    if (attempt == 0) {
      // The player can rebuild us before the keyboard's new constraints have
      // been laid out. Never start an indexed scroll using the previous size.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToIndexAtThirtyPercent(targetIndex, isAuto: isAuto, attempt: 1);
      });
      return;
    }
    if (targetIndex < 0 || targetIndex >= _editingSubtitles.length) return;
    if (isAuto && _textFocusNode.hasFocus) return;
    if (_listViewportHeight <= 4) {
      _needsViewportRepair = true;
      return;
    }
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

  Widget _buildListViewport(BuildContext context, BoxConstraints constraints) {
    _listViewportHeight = constraints.maxHeight;
    if (_listViewportHeight <= 4) {
      // The indexed list divides item positions by its viewport extent. Do
      // not lay it out at zero height and let NaN offsets survive IME dismissal.
      _needsViewportRepair = true;
      return const SizedBox.shrink();
    }
    if (_needsViewportRepair && !_viewportRepairScheduled) {
      _viewportRepairScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _viewportRepairScheduled = false;
        if (!mounted ||
            _listViewportHeight <= 4 ||
            !_itemScrollController.isAttached ||
            _editingSubtitles.isEmpty) {
          return;
        }
        _needsViewportRepair = false;
        _itemScrollController.jumpTo(
          index: _selectedIndex.clamp(0, _editingSubtitles.length - 1),
          alignment: .30,
        );
      });
    }
    return _buildSubtitleList();
  }

  void _locateCurrentSubtitle({required bool isAuto}) {
    final int target = _resolveCurrentTargetIndex();
    if (target < 0 || target >= _editingSubtitles.length) return;
    if (_selectedIndex != target) {
      setState(() {
        _selectedIndex = target;
      });
      _syncTextController();
    }
    _lastAutoFollowTargetIndex = target;
    _scrollToIndexAtThirtyPercent(target, isAuto: isAuto, attempt: 0);
  }

  void _tryAutoFollow({bool force = false}) {
    if (!mounted || !SettingsService().subtitleEditorAutoFollow) return;
    if (_textFocusNode.hasFocus) return;
    final int target = _resolveCurrentTargetIndex();
    if (target < 0) return;
    if (!force && target == _lastAutoFollowTargetIndex) return;
    _locateCurrentSubtitle(isAuto: true);
  }

  void _syncFromWidget({required bool resetHistory}) {
    _selectedGroupPath = widget.activeGroupPath;
    _editingSubtitles = List<SubtitleItem>.from(widget.subtitles);
    if (resetHistory) {
      _undoStack.clear();
      _redoStack.clear();
      _deleteMode = false;
    }
    if (_editingSubtitles.isEmpty) {
      _selectedIndex = -1;
    } else {
      final int candidate = widget.currentSubtitleIndex;
      if (resetHistory &&
          candidate >= 0 &&
          candidate < _editingSubtitles.length) {
        _selectedIndex = candidate;
      } else if (_selectedIndex >= _editingSubtitles.length ||
          _selectedIndex < 0) {
        _selectedIndex = 0;
      }
    }
    _syncTextController();
    if (mounted) setState(() {});
  }

  void _syncTextController() {
    _isApplyingText = true;
    final String nextText =
        (_selectedIndex >= 0 && _selectedIndex < _editingSubtitles.length)
        ? _editingSubtitles[_selectedIndex].text
        : '';
    final TextEditingValue currentValue = _textController.value;
    // Preserve the IME composing range when the selected text is unchanged.
    if (currentValue.text == nextText) {
      _isApplyingText = false;
      return;
    }
    _textController.value = currentValue.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
      composing: TextRange.empty,
    );
    _isApplyingText = false;
  }

  void _pushUndoSnapshot() {
    _undoStack.add(List<SubtitleItem>.from(_editingSubtitles));
    if (_undoStack.length > 80) {
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
    if (mounted) widget.onBack();
  }

  void _applyTextEdit(String value) {
    if (_isApplyingText) return;
    if (_selectedIndex < 0 || _selectedIndex >= _editingSubtitles.length) {
      return;
    }
    final SubtitleItem current = _editingSubtitles[_selectedIndex];
    if (current.text == value) return;
    _pushUndoSnapshot();
    _editingSubtitles[_selectedIndex] = current.copyWith(text: value);
    setState(() {});
    _persistDebounced();
  }

  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;
    _redoStack.add(List<SubtitleItem>.from(_editingSubtitles));
    _editingSubtitles = _undoStack.removeLast();
    if (_editingSubtitles.isEmpty) {
      _selectedIndex = -1;
    } else if (_selectedIndex >= _editingSubtitles.length ||
        _selectedIndex < 0) {
      _selectedIndex = 0;
    }
    _syncTextController();
    setState(() {});
    await _persistNow();
  }

  Future<void> _redo() async {
    if (_redoStack.isEmpty) return;
    _undoStack.add(List<SubtitleItem>.from(_editingSubtitles));
    _editingSubtitles = _redoStack.removeLast();
    if (_editingSubtitles.isEmpty) {
      _selectedIndex = -1;
    } else if (_selectedIndex >= _editingSubtitles.length ||
        _selectedIndex < 0) {
      _selectedIndex = 0;
    }
    _syncTextController();
    setState(() {});
    await _persistNow();
  }

  Future<void> _deleteAt(int index) async {
    if (index < 0 || index >= _editingSubtitles.length) return;
    _pushUndoSnapshot();
    _editingSubtitles.removeAt(index);
    if (_editingSubtitles.isEmpty) {
      _selectedIndex = -1;
    } else if (_selectedIndex >= _editingSubtitles.length) {
      _selectedIndex = _editingSubtitles.length - 1;
    }
    _syncTextController();
    setState(() {});
    await _persistNow();
  }

  Future<void> _seekByOffset(int offset) async {
    if (_editingSubtitles.isEmpty) return;
    int base = _selectedIndex;
    if (base < 0 || base >= _editingSubtitles.length) {
      base = widget.currentSubtitleIndex;
      if (base < 0 || base >= _editingSubtitles.length) {
        base = 0;
      }
    }
    final int target = (base + offset).clamp(0, _editingSubtitles.length - 1);
    setState(() {
      _selectedIndex = target;
    });
    _syncTextController();
    final SubtitleItem item = _editingSubtitles[target];
    widget.onSeekTo(item.startTime);
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
  Widget build(BuildContext context) =>
      KeyboardInsetPadding(child: LayoutBuilder(builder: _buildPanel));

  Widget _buildPanel(BuildContext context, BoxConstraints constraints) {
    final theme = Theme.of(context);
    final List<MapEntry<String, String>> groupEntries = widget.groups.entries
        .toList();
    final bool hasSelection =
        _selectedIndex >= 0 && _selectedIndex < _editingSubtitles.length;
    final size = MediaQuery.sizeOf(context);
    final double width = size.width;
    final double height = size.height;
    final double widthScale = (width / 390).clamp(0.72, 1.08);
    final double heightScale = (height / 844).clamp(0.78, 1.1);
    final double panelHorizontal = (width * 0.026).clamp(8.0, 16.0);
    final double panelTop = (height * 0.008).clamp(4.0, 10.0);
    final double panelBottom = (height * 0.008).clamp(4.0, 12.0);
    final double iconSize = (20 * widthScale).clamp(16.0, 22.0);
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * .42),
            child: SingleChildScrollView(
              key: const PageStorageKey('subtitle-editor-toolbar-scroll'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      panelHorizontal,
                      panelTop,
                      panelHorizontal,
                      (6 * heightScale).clamp(4.0, 8.0),
                    ),
                    child: Row(
                      children: [
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: _saveAndClose,
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.arrow_back,
                              color: Colors.white70,
                            ),
                          ),
                        ),
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
                            onPressed: _promptCreateGroup,
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.create_new_folder_outlined,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: _promptRenameGroup,
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.drive_file_rename_outline,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: widget.onToggleExpanded,
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              widget.isExpanded
                                  ? Icons.fullscreen_exit_rounded
                                  : Icons.fullscreen_rounded,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: panelHorizontal),
                    child: Row(
                      children: [
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: _undoStack.isEmpty ? null : _undo,
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.undo,
                              color: _undoStack.isEmpty
                                  ? Colors.white24
                                  : Colors.white70,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: _redoStack.isEmpty ? null : _redo,
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.redo,
                              color: _redoStack.isEmpty
                                  ? Colors.white24
                                  : Colors.white70,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: () {
                              setState(() {
                                _deleteMode = !_deleteMode;
                              });
                            },
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.delete_outline,
                              color: _deleteMode
                                  ? Colors.redAccent
                                  : Colors.white70,
                            ),
                          ),
                        ),
                        const Spacer(),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: () =>
                                _locateCurrentSubtitle(isAuto: false),
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.my_location,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
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
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Icon(
                                  SettingsService().subtitleEditorAutoFollow
                                      ? Icons.gps_fixed
                                      : Icons.gps_not_fixed,
                                  color:
                                      SettingsService().subtitleEditorAutoFollow
                                      ? Colors.blueAccent
                                      : Colors.white70,
                                ),
                                if (SettingsService().subtitleEditorAutoFollow)
                                  Positioned(
                                    right: -2,
                                    bottom: -2,
                                    child: Text(
                                      'A',
                                      style: TextStyle(
                                        fontSize: (7 * widthScale).clamp(
                                          6.0,
                                          8.0,
                                        ),
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blueAccent,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: () => _seekByOffset(-1),
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.skip_previous,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                        DesktopButtonClickRegion(
                          child: IconButton(
                            onPressed: () => _seekByOffset(1),
                            iconSize: iconSize,
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.skip_next,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_saveError != null)
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: panelHorizontal,
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
          Expanded(child: LayoutBuilder(builder: _buildListViewport)),
          Container(
            padding: EdgeInsets.fromLTRB(
              panelHorizontal,
              (8 * heightScale).clamp(6.0, 10.0),
              panelHorizontal,
              panelBottom,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF232323),
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            child: ConstrainedBox(
              // Leave room for the subtitle list even with a tall IME or a
              // long cue. The field scrolls internally past this height.
              constraints: BoxConstraints(
                maxHeight: (constraints.maxHeight * .32).clamp(0.0, 200.0),
              ),
              child: TextField(
                key: const PageStorageKey('subtitle-editor-text-scroll'),
                controller: _textController,
                focusNode: _textFocusNode,
                minLines: widget.isExpanded ? 4 : 2,
                maxLines: widget.isExpanded ? 10 : 4,
                enabled: hasSelection,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: (14 * widthScale).clamp(12.0, 15.0),
                  height: 1.25,
                ),
                decoration: InputDecoration(
                  hintText: hasSelection ? '编辑字幕文本（实时写入）' : '请选择字幕行',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF2A2A2A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white24),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: theme.colorScheme.primary),
                  ),
                ),
                onChanged: _applyTextEdit,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubtitleList() {
    final size = MediaQuery.sizeOf(context);
    final double widthScale = (size.width / 390).clamp(0.72, 1.08);
    final double heightScale = (size.height / 844).clamp(0.78, 1.1);
    final double panelHorizontal = (size.width * 0.026).clamp(8.0, 16.0);
    final double rowNumberWidth = (size.width * 0.1).clamp(30.0, 42.0);
    final double timeAreaWidth = (size.width * 0.23).clamp(78.0, 108.0);
    final double itemVertical = (6 * heightScale).clamp(3.0, 8.0);
    final double itemHorizontal = (10 * widthScale).clamp(7.0, 12.0);
    final double listTextSize = (13 * widthScale).clamp(11.0, 14.0);
    final double timeTextSize = (11 * widthScale).clamp(9.5, 12.0);
    return ScrollablePositionedList.builder(
      key: const PageStorageKey('subtitle-editor-positioned-list'),
      itemScrollController: _itemScrollController,
      itemPositionsListener: _itemPositionsListener,
      itemCount: _editingSubtitles.length,
      itemBuilder: (context, index) {
        final item = _editingSubtitles[index];
        final bool selected = index == _selectedIndex;
        final Color borderColor = selected
            ? Colors.blueAccent
            : (_deleteMode
                  ? Colors.redAccent.withValues(alpha: 0.35)
                  : Colors.white12);
        return InkWell(
          onTap: () async {
            if (_deleteMode) {
              await _deleteAt(index);
              return;
            }
            setState(() {
              _selectedIndex = index;
            });
            _syncTextController();
            final bool alreadyFocused = _textFocusNode.hasFocus;
            _textFocusNode.requestFocus();
            if (alreadyFocused) {
              // Android can hide the IME while keeping field focus.
              SystemChannels.textInput.invokeMethod<void>('TextInput.show');
            }
            widget.onSeekTo(item.startTime);
          },
          child: Container(
            margin: EdgeInsets.symmetric(
              horizontal: panelHorizontal,
              vertical: (4 * heightScale).clamp(2.0, 6.0),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: itemHorizontal,
              vertical: itemVertical,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? Colors.white10
                  : (index.isEven
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.white.withValues(alpha: 0.02)),
              borderRadius: BorderRadius.circular(
                (8 * widthScale).clamp(6.0, 10.0),
              ),
              border: Border.all(color: borderColor),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: rowNumberWidth,
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: (12 * widthScale).clamp(10.0, 13.0),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    item.text.isEmpty ? '（空文本）' : item.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : Colors.white70,
                      fontSize: listTextSize,
                      height: 1.2,
                    ),
                  ),
                ),
                SizedBox(width: (8 * widthScale).clamp(5.0, 9.0)),
                SizedBox(
                  width: timeAreaWidth,
                  child: Text(
                    _formatDuration(item.startTime),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: timeTextSize,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final int hours = d.inHours;
    final int minutes = d.inMinutes.remainder(60);
    final int seconds = d.inSeconds.remainder(60);
    final int millis = d.inMilliseconds.remainder(1000);
    return '${two(hours)}:${two(minutes)}:${two(seconds)}.${millis.toString().padLeft(3, '0')}';
  }
}
