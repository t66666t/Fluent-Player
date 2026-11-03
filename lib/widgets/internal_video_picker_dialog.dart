import 'dart:async';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../models/video_picker_tree_node.dart';
import '../services/internal_media_picker_source.dart';
import '../services/library_service.dart';
import '../services/transcription_manager.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class InternalVideoPickerDialog extends StatefulWidget {
  final LibraryService libraryService;
  final TranscriptionManager transcriptionManager;
  final String? defaultCollectionId;
  final FutureOr<void> Function(List<VideoPickerTreeNode> selectedNodes)
  onConfirm;

  const InternalVideoPickerDialog({
    super.key,
    required this.libraryService,
    required this.transcriptionManager,
    this.defaultCollectionId,
    required this.onConfirm,
  });

  @override
  State<InternalVideoPickerDialog> createState() =>
      _InternalVideoPickerDialogState();
}

class _InternalVideoPickerDialogState extends State<InternalVideoPickerDialog> {
  late final InternalMediaPickerSource _source;
  late final VideoPickerTree _tree;
  final _expandedFolders = <String>{};
  final _folderLoads = <String, Future<bool>>{};
  final _folderErrors = <String, String>{};
  final _durationRequested = <String>{};
  final _durationLoading = <String>{};
  final _durationMissing = <String>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _source = InternalMediaPickerSource(
      library: widget.libraryService,
      manager: widget.transcriptionManager,
    );
    _tree = _source.buildTree();
    widget.transcriptionManager.addListener(_refreshQueueState);
    final defaultId = widget.defaultCollectionId;
    if (defaultId != null) {
      // Expand ancestors too, so a nested entry point is visible.
      var folder = widget.libraryService.getCollection(defaultId);
      while (folder != null && _expandedFolders.add(folder.id)) {
        folder = folder.parentId == null
            ? null
            : widget.libraryService.getCollection(folder.parentId!);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final row in _visibleRows()) {
          if (_expandedFolders.contains(row.node.nodeId)) {
            unawaited(_loadFolder(row.node));
          }
        }
      });
    }
  }

  @override
  void dispose() {
    widget.transcriptionManager.removeListener(_refreshQueueState);
    super.dispose();
  }

  void _refreshQueueState() {
    void refresh(VideoPickerTreeNode node) {
      if (!node.isFolder) {
        node.isAlreadyInQueue = _source.isQueued(node.videoPath!, node.videoId);
      }
      for (final child in node.children) {
        refresh(child);
      }
    }

    if (!mounted) return;
    setState(() {
      for (final root in _tree.roots) {
        refresh(root);
      }
      _tree.recalculateCounts();
    });
  }

  List<({VideoPickerTreeNode node, int depth})> _visibleRows() {
    final rows = <({VideoPickerTreeNode node, int depth})>[];
    void visit(VideoPickerTreeNode node, int depth) {
      rows.add((node: node, depth: depth));
      if (node.isFolder && _expandedFolders.contains(node.nodeId)) {
        for (final child in node.children) {
          visit(child, depth + 1);
        }
      }
    }

    for (final root in _tree.roots) {
      visit(root, 0);
    }
    return rows;
  }

  Future<bool> _loadFolder(VideoPickerTreeNode node, {bool earlier = false}) {
    if (node.childrenLoaded && !earlier) return Future.value(true);
    return _folderLoads.putIfAbsent(node.nodeId, () async {
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return false;
      setState(() => _folderErrors.remove(node.nodeId));
      try {
        if (earlier) {
          await _source.loadEarlierEpisodes(node);
        } else {
          await _source.loadChildren(node);
        }
        if (!mounted) return false;
        _refreshQueueState();
        return true;
      } catch (_) {
        if (mounted) {
          setState(
            () => _folderErrors[node.nodeId] = earlier
                ? '更早节目加载失败，请重试'
                : '单集加载失败，请重试',
          );
        }
        return false;
      } finally {
        _folderLoads.remove(node.nodeId);
        if (mounted) setState(() {});
      }
    });
  }

  Future<bool> _loadSubtree(VideoPickerTreeNode node) async {
    if (!mounted) return false;
    if (node.isFolder && !await _loadFolder(node)) return false;
    for (final child in node.children) {
      if (!await _loadSubtree(child)) return false;
    }
    return mounted;
  }

  Future<void> _select(VideoPickerTreeNode? node, bool selected) async {
    if (_busy || node?.isAlreadyInQueue == true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (selected) {
        for (final root in node == null ? _tree.roots : [node]) {
          if (!await _loadSubtree(root)) {
            if (mounted) {
              setState(() => _error = '文件夹未能读取完整，请重试后选择');
            }
            return;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        if (node == null) {
          _tree.selectAll(selected);
        } else {
          _tree.updateSelection(node, selected);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleFolder(VideoPickerTreeNode node) {
    setState(() {
      if (!_expandedFolders.remove(node.nodeId)) {
        _expandedFolders.add(node.nodeId);
        unawaited(_loadFolder(node));
      }
    });
  }

  void _ensureDuration(VideoPickerTreeNode node, {bool retry = false}) {
    if (node.mediaItem?.sourceRef?.cloudDrive == null ||
        (node.videoDuration?.isNotEmpty ?? false) ||
        !_durationRequested.add(node.nodeId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() => _durationLoading.add(node.nodeId));
      var found = false;
      try {
        found = await _source.refreshDuration(node, force: retry);
      } catch (_) {
        // Missing metadata does not prevent selection or transcription.
      }
      if (!mounted) return;
      setState(() {
        _durationLoading.remove(node.nodeId);
        if (!found) _durationMissing.add(node.nodeId);
      });
    });
  }

  Future<void> _confirm() async {
    if (_busy) return;
    _refreshQueueState();
    final selected = _tree.getSelectedLeaves();
    if (selected.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _source.prepareSelection(selected);
      if (!mounted) return;
      await widget.onConfirm(selected);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _error = '添加媒体失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visibleRows();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final actionStyle = TextButton.styleFrom(
      minimumSize: const Size(44, 40),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: size.width < 600 ? 12 : 40,
        vertical: 20,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 860,
        height: (size.height * .84).clamp(0.0, 720.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '选择内部媒体',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          tooltip: '关闭',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close_rounded, size: 20),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '支持音视频，勾选文件夹可批量选择',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '已选择 ${_tree.selectedCount} 项',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.primary,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: '选择全部媒体，包括未展开的文件夹',
                        child: DesktopButtonClickRegion(
                          child: TextButton(
                            style: actionStyle,
                            onPressed: _busy || rows.isEmpty
                                ? null
                                : () => _select(null, true),
                            child: const Text('全选'),
                          ),
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: TextButton(
                          style: actionStyle,
                          onPressed: _busy || _tree.selectedCount == 0
                              ? null
                              : () => _select(null, false),
                          child: const Text('清空'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(_error!, style: TextStyle(color: colors.error)),
              ),
            const Divider(height: 1),
            Expanded(
              child: _tree.roots.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          '暂无媒体，请先导入视频、音频或订阅播客',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        _ensureDuration(row.node);
                        return _buildNodeRow(row.node, row.depth);
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Row(
                    children: [
                      Expanded(
                        child: DesktopButtonClickRegion(
                          child: TextButton(
                            style: actionStyle,
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('取消'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: DesktopButtonClickRegion(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 44),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              textStyle: theme.textTheme.labelLarge?.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onPressed: !_busy && _tree.selectedCount > 0
                                ? _confirm
                                : null,
                            child: Text('确认 (${_tree.selectedCount})'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _metadataLabel(VideoPickerTreeNode node) {
    if (node.isFolder) {
      if (_folderLoads.containsKey(node.nodeId)) return '正在读取单集…';
      final error = _folderErrors[node.nodeId];
      if (error != null) return error;
      if (_source.isPodcastFolder(node)) {
        return node.childrenLoaded
            ? '播客 · ${node.children.length} 个媒体${_source.hasEarlierEpisodes(node) ? ' · 还有更早节目' : ''}'
            : '播客 · 展开查看全部单集';
      }
      return '';
    }
    final item = node.mediaItem;
    final origin = item?.sourceRef?.podcast != null
        ? '播客'
        : item?.sourceRef?.cloudDrive != null
        ? '网盘'
        : '内部';
    final type = item?.type == MediaType.audio ? '音频' : '视频';
    final duration = node.videoDuration;
    final label = duration != null && duration.isNotEmpty
        ? duration
        : _durationLoading.contains(node.nodeId)
        ? '正在获取时长…'
        : _durationMissing.contains(node.nodeId)
        ? '暂未获取时长'
        : '时长待获取';
    return '$origin$type · $label';
  }

  Widget _buildNodeRow(VideoPickerTreeNode node, int depth) {
    final theme = Theme.of(context);
    final loading = _folderLoads.containsKey(node.nodeId);
    final disabled = _busy || node.isAlreadyInQueue;
    final expanded = _expandedFolders.contains(node.nodeId);
    final metadata = _metadataLabel(node);
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxIndent = (constraints.maxWidth - 260).clamp(0.0, 48.0);
        return Padding(
          padding: EdgeInsets.only(
            left: (depth * 12.0).clamp(0.0, maxIndent),
            top: 2,
            bottom: 2,
          ),
          child: Material(
            color: node.isSelected || node.isIndeterminate
                ? theme.colorScheme.primary.withValues(alpha: .08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              key: ValueKey('internal-media-${node.nodeId}'),
              borderRadius: BorderRadius.circular(10),
              onTap: node.isFolder
                  ? () => _toggleFolder(node)
                  : disabled
                  ? null
                  : () => _select(node, !node.isSelected),
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 10, right: 8),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 44,
                      child: Checkbox(
                        value: node.isIndeterminate ? null : node.isSelected,
                        tristate: true,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: disabled
                            ? null
                            : (_) => _select(node, !node.isSelected),
                      ),
                    ),
                    Icon(
                      node.isFolder
                          ? _source.isPodcastFolder(node)
                                ? Icons.podcasts
                                : Icons.folder
                          : node.mediaItem?.type == MediaType.audio
                          ? Icons.audiotrack
                          : Icons.play_circle_outline,
                      size: 18,
                      color: node.isFolder
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            node.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              fontWeight: FontWeight.w600,
                              color: node.isAlreadyInQueue
                                  ? theme.disabledColor
                                  : null,
                            ),
                          ),
                          if (node.isAlreadyInQueue)
                            Text(
                              '已在队列',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          else if (metadata.isNotEmpty)
                            Text(
                              metadata,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                fontWeight: FontWeight.w500,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else if (_folderErrors.containsKey(node.nodeId))
                      DesktopButtonClickRegion(
                        child: IconButton(
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 40,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '重试加载单集',
                          icon: const Icon(Icons.refresh, size: 18),
                          onPressed: _busy
                              ? null
                              : () => _loadFolder(
                                  node,
                                  earlier:
                                      node.childrenLoaded &&
                                      _source.hasEarlierEpisodes(node),
                                ),
                        ),
                      )
                    else if (expanded &&
                        node.childrenLoaded &&
                        _source.hasEarlierEpisodes(node))
                      DesktopButtonClickRegion(
                        child: IconButton(
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 40,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '加载更早的节目，加载后可选择',
                          icon: const Icon(Icons.history, size: 18),
                          onPressed: _busy
                              ? null
                              : () => _loadFolder(node, earlier: true),
                        ),
                      )
                    else if (_durationMissing.contains(node.nodeId))
                      DesktopButtonClickRegion(
                        child: IconButton(
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 40,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '重试获取时长',
                          icon: const Icon(Icons.refresh, size: 18),
                          onPressed: () {
                            _durationRequested.remove(node.nodeId);
                            _durationMissing.remove(node.nodeId);
                            _ensureDuration(node, retry: true);
                          },
                        ),
                      ),
                    if (node.isFolder)
                      Tooltip(
                        message: expanded ? '收起' : '展开',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(
                            expanded ? Icons.expand_more : Icons.chevron_right,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
