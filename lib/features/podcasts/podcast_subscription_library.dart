part of 'podcast_pages.dart';

class _PodcastSubscriptionLibrary extends StatefulWidget {
  const _PodcastSubscriptionLibrary({
    super.key,
    required this.runtime,
    required this.controller,
    required this.bottomPadding,
    required this.isActive,
    required this.onFolderChanged,
    required this.onDiscover,
    required this.overviewController,
    required this.selectionManagedByHost,
    this.initialFolderId,
  });

  final PodcastRuntime runtime;
  final PlaybackScrollController controller;
  final double bottomPadding;
  final bool isActive;
  final String? initialFolderId;
  final ValueChanged<String?> onFolderChanged;
  final VoidCallback onDiscover;
  final PodcastOverviewController overviewController;
  final bool selectionManagedByHost;

  @override
  State<_PodcastSubscriptionLibrary> createState() =>
      _PodcastSubscriptionLibraryState();
}

class _PodcastSubscriptionLibraryState
    extends State<_PodcastSubscriptionLibrary> {
  final _selection = PodcastEpisodeSelection();
  final _viewportKey = GlobalKey();
  final _itemKeys = <String, GlobalKey>{};
  final _folderOffsets = <String, double>{};
  final _reorderDrag = MediaLibraryReorderDragSession();
  final _pointers = MediaLibrarySelectionPointerSession();
  late final MediaLibrarySelectionAutoScroller _autoScroll;
  late String? _folderId = widget.initialFolderId;
  List<String> _visibleIds = const [];
  List<String>? _dragOrder;
  List<String> _dragIds = const [];
  String? _draggedId;
  Offset? _dragGlobalPosition;
  bool _dragLayoutRefreshScheduled = false;
  String? _rangeAnchorId;
  Set<String> _rangeSnapshot = {};
  Offset? _rangePosition;
  String? _notice;
  bool _busy = false;

  PodcastSubscriptionLayout get _layout =>
      PodcastSubscriptionLayout(widget.runtime.store);

  @override
  void initState() {
    super.initState();
    _autoScroll = MediaLibrarySelectionAutoScroller(
      scrollController: widget.controller,
      onScrolled: () {
        if (_rangePosition case final position?) _applyRange(position);
        _reorderDrag.scheduleHitRefresh();
      },
    );
  }

  @override
  void didUpdateWidget(_PodcastSubscriptionLibrary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive) _endGestures();
  }

  @override
  void dispose() {
    _autoScroll.dispose();
    _reorderDrag.end();
    _dragGlobalPosition = null;
    super.dispose();
  }

  void _endGestures() {
    _autoScroll.stop();
    _reorderDrag.end();
    _dragGlobalPosition = null;
    _rangeAnchorId = null;
    _rangePosition = null;
    _rangeSnapshot = {};
    _pointers.clear();
    // A drop is delivered before onDragEnd. Keep its identity through release;
    // a later gesture always replaces this snapshot before accepting a drop.
  }

  void beginSelection() => setState(() => _selection.active = true);

  void selectAll({bool toggle = false}) {
    setState(() {
      if (toggle &&
          _visibleIds.isNotEmpty &&
          _visibleIds.every(_selection.contains)) {
        _selection.deselectAll();
      } else {
        _selection.selectAll(_visibleIds);
      }
    });
  }

  bool handleBack() {
    if (_selection.active) {
      _endGestures();
      setState(_selection.clear);
      return true;
    }
    if (_folderId != null) {
      _openFolder(_layout.folder(_folderId!)?.parentId);
      return true;
    }
    return false;
  }

  void _openFolder(String? id) {
    _endGestures();
    if (widget.controller.hasClients) {
      _folderOffsets[_folderId ?? ''] = widget.controller.offset;
    }
    setState(() {
      _folderId = id;
      _selection.clear();
      _notice = null;
      _itemKeys.clear();
    });
    widget.onFolderChanged(id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.controller.hasClients) return;
      widget.controller.jumpTo(
        (_folderOffsets[id ?? ''] ?? 0).clamp(
          0.0,
          widget.controller.position.maxScrollExtent,
        ),
      );
    });
  }

  void _toggle(String id, {bool force = false}) {
    if (_busy) return;
    setState(() {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _selection.extendTo(_visibleIds, id);
      } else if (force ||
          _selection.active ||
          HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed) {
        _selection.toggle(id);
      }
    });
    unawaited(AppHaptics.selectionClick(SettingsService()));
  }

  void _activate(String id) {
    if (_busy) return;
    if (_selection.active ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      _toggle(id, force: true);
    } else if (_layout.folder(id) != null) {
      _openFolder(id);
    } else {
      Navigator.push(
        context,
        AppMaterialPageRoute<void>(
          builder: (_) => PodcastChannelPage(channelId: id),
        ),
      );
    }
  }

  void _beginDrag(String id) {
    if (_busy) return;
    _endGestures();
    _dragOrder = List.of(_visibleIds);
    _draggedId = id;
    _dragIds = _selection.contains(id) ? _selection.ordered(_visibleIds) : [id];
    if (!_selection.active) setState(() => _selection.begin(id));
    // Mobile feedback is already issued by the shared adaptive draggable.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      unawaited(AppHaptics.selectionClick(SettingsService()));
    }
  }

  List<String> _idsForDrop(int index) {
    final order = _dragOrder;
    if (order == null ||
        index < 0 ||
        index >= order.length ||
        order[index] != _draggedId) {
      return const [];
    }
    // Refreshes may insert / remove cards during a drag. Resolve from logical
    // IDs captured at the start, never from the new indexes on screen.
    final visible = _layout.entries(
      _folderId,
      widget.runtime.controller.channels,
    );
    return _dragIds.where(visible.contains).toList();
  }

  void _move(List<String> ids, String? target) {
    if (_busy || ids.isEmpty) return;
    final layout = _layout;
    if (!layout.move(ids, target)) return;
    _endGestures();
    setState(() {
      _selection.retain(
        layout.entries(_folderId, widget.runtime.controller.channels),
      );
      _notice = '已移动 ${ids.length} 项';
    });
    unawaited(AppHaptics.reorderDragCompleted(SettingsService()));
  }

  void _reorder(int oldIndex, String targetId) {
    final ids = _idsForDrop(oldIndex);
    final draggedId = _draggedId;
    if (_busy || draggedId == null || ids.isEmpty) {
      return;
    }
    if (_layout.reorder(
      _folderId,
      ids,
      draggedId: draggedId,
      targetId: targetId,
    )) {
      setState(() {});
      unawaited(AppHaptics.reorderDragCompleted(SettingsService()));
    }
  }

  void _autoScrollAt(Offset position) {
    final bounds = _selectionBounds();
    if (bounds == null) return;
    _autoScroll.update(
      pointerY: position.dy,
      viewportTop: bounds.top,
      viewportBottom: bounds.bottom,
    );
  }

  Rect? _selectionBounds() {
    final box = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(
      origin.dx,
      origin.dy,
      box.size.width,
      max(0, box.size.height - widget.bottomPadding),
    );
  }

  void _dragPosition(
    Offset position,
    int pointer,
    int viewId,
    PointerDeviceKind kind,
  ) {
    if (!mounted || !widget.isActive) return;
    _dragGlobalPosition = position;
    _reorderDrag.update(
      globalPosition: position,
      pointer: pointer,
      viewId: viewId,
      kind: kind,
    );
    _autoScrollAt(position);
  }

  void _beginRange(int index, Offset position) {
    _rangeAnchorId = _visibleIds[index];
    _rangeSnapshot = {..._selection.ids, _visibleIds[index]};
    _applyRange(position);
  }

  void _refreshDragAfterLayout() {
    if (_dragLayoutRefreshScheduled || _dragGlobalPosition == null) return;
    _dragLayoutRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dragLayoutRefreshScheduled = false;
      final position = _dragGlobalPosition;
      if (!mounted || position == null || !_reorderDrag.isActive) return;
      _autoScrollAt(position);
      _reorderDrag.scheduleHitRefresh();
    });
  }

  void _applyRange(Offset position) {
    final anchorId = _rangeAnchorId;
    if (!mounted || anchorId == null) return;
    final start = _visibleIds.indexOf(anchorId);
    if (start < 0) {
      _endGestures();
      return;
    }
    _rangePosition = position;
    final bounds = _selectionBounds();
    if (bounds == null || bounds.isEmpty) return;
    final hit = MediaLibraryRangeSelection.clampPointerToVerticalViewport(
      global: position,
      viewportTop: bounds.top,
      viewportBottom: bounds.bottom - 1,
    );
    int? target;
    var nearest = double.infinity;
    for (var i = 0; i < _visibleIds.length; i++) {
      final box = _itemKeys[_visibleIds[i]]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (!rect.overlaps(bounds)) continue;
      final dx = hit.dx - hit.dx.clamp(rect.left, rect.right);
      final dy = hit.dy - hit.dy.clamp(rect.top, rect.bottom);
      final distance = dx * dx + dy * dy;
      if (distance < nearest) {
        target = i;
        nearest = distance;
      }
    }
    if (target != null) {
      final before = _selection.ids.toSet();
      setState(
        () => _selection.extendFromSnapshot(
          _visibleIds,
          _rangeSnapshot.intersection(_visibleIds.toSet()),
          start,
          target!,
        ),
      );
      if (_selection.ids.difference(before).isNotEmpty) {
        unawaited(AppHaptics.selectionClick(SettingsService()));
      }
    }
    _autoScrollAt(position);
  }

  Future<void> _createFolder() async {
    if (_busy) return;
    final parent = _folderId;
    final ids = _selection.ordered(_visibleIds);
    await showLibraryCreateCollectionDialog(
      context: context,
      onCreate: (name) async {
        final layout = _layout;
        final id = layout.createFolder(name, parentId: parent);
        if (ids.isNotEmpty) layout.move(ids, id);
        if (mounted) {
          setState(() {
            _selection.clear();
            _notice = null;
          });
        }
      },
    );
  }

  Future<void> _rename(String id) async {
    final folder = _layout.folder(id);
    if (folder != null) {
      await showLibraryRenameDialog(
        context: context,
        itemId: id,
        currentName: folder.name,
        onRename: (name) async {
          _layout.renameFolder(id, name);
          if (mounted) setState(() {});
        },
      );
    } else {
      final channel = widget.runtime.store.channel(id);
      if (channel != null) {
        await _renamePodcastChannel(context, widget.runtime, channel);
      }
      if (mounted) setState(() {});
    }
  }

  List<String> _idsForAction(int? draggedIndex) => draggedIndex == null
      ? _selection.ordered(_visibleIds)
      : _idsForDrop(draggedIndex);

  void _moveSelectionToParent([int? draggedIndex]) {
    if (_folderId == null) return;
    _move(_idsForAction(draggedIndex), _layout.folder(_folderId!)?.parentId);
  }

  String _removeLabel(List<String> ids) {
    final layout = _layout;
    final folders = ids.where((id) => layout.folder(id) != null).length;
    return folders == 0
        ? '取消订阅'
        : folders == ids.length
        ? '解散合集'
        : '移除所选项';
  }

  Future<void> _removeSelection([int? draggedIndex]) async {
    if (_busy) return;
    final ids = _idsForAction(draggedIndex);
    if (ids.isEmpty) return;
    final layout = _layout;
    final channels = ids.where((id) => layout.folder(id) == null).toList();
    final folders = ids.where((id) => layout.folder(id) != null).toList();
    final label = _removeLabel(ids);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: Text(
          [
            if (channels.isNotEmpty) '取消订阅 ${channels.length} 个频道并将频道卡片移入回收站。',
            if (folders.isNotEmpty) '解散 ${folders.length} 个合集，内容移回各自的上一级。',
            '已有下载和收听进度都会保留。',
          ].join('\n'),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTokens.danger),
              onPressed: () => Navigator.pop(context, true),
              child: Text(label),
            ),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      for (final id in channels) {
        await widget.runtime.unsubscribe(id);
      }
      _layout.dissolveFolders(folders);
      if (mounted) {
        setState(() {
          _selection.clear();
          _notice = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _notice = '部分项目未能移除：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _selectionDropTargets() => MediaLibrarySelectionDropTargets(
    hasSelectedItems: _selection.ids.isNotEmpty,
    showMoveToParent: _folderId != null,
    onMoveToParent: _moveSelectionToParent,
    onMoveToRecycleBin: (index) => unawaited(_removeSelection(index)),
    removeLabel: _removeLabel(_selection.ordered(_visibleIds)),
    removeIcon: Icons.delete_outline,
  );

  Widget _toolbar(PodcastSubscriptionLayout layout) {
    final compact = useCompactMediaLibraryTopBar(context);
    if (_selection.active) {
      if (widget.selectionManagedByHost) return const SizedBox.shrink();
      return SizedBox(
        height: compact ? 44 : 48,
        child: Row(
          children: [
            MediaLibraryCompactIconButton(
              icon: Icons.close,
              tooltip: '退出选择',
              onPressed: handleBack,
            ),
            Expanded(child: _selectionDropTargets()),
            MediaLibraryCompactIconButton(
              icon: Icons.select_all,
              tooltip: '全选',
              onPressed: () => selectAll(toggle: true),
            ),
          ],
        ),
      );
    }
    if (widget.selectionManagedByHost && _folderId == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          if (_folderId != null)
            DesktopButtonClickRegion(
              child: IconButton(
                tooltip: '返回上一级',
                onPressed: handleBack,
                icon: const Icon(Icons.arrow_back),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _folderId == null
                          ? null
                          : () => _openFolder(null),
                      child: const Text('全部订阅'),
                    ),
                  ),
                  for (final folder in layout.ancestors(_folderId)) ...[
                    const Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: AppTokens.text3,
                    ),
                    DesktopButtonClickRegion(
                      child: TextButton(
                        onPressed: folder.id == _folderId
                            ? null
                            : () => _openFolder(folder.id),
                        child: Text(folder.name),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!widget.selectionManagedByHost)
            MediaLibraryCompactIconButton(
              tooltip: '批量管理',
              onPressed: beginSelection,
              icon: Icons.checklist,
            ),
        ],
      ),
    );
  }

  List<String> _channelsForSelection(List<String> ids) {
    final layout = _layout;
    final channels = widget.runtime.controller.channels;
    final active = channels.map((channel) => channel.id).toSet();
    final visited = <String>{};
    final result = <String>[];
    void visit(String id) {
      if (!visited.add(id)) return;
      if (layout.folder(id) != null) {
        for (final child in layout.entries(id, channels)) {
          visit(child);
        }
      } else if (active.contains(id)) {
        result.add(id);
      }
    }

    for (final id in ids) {
      visit(id);
    }
    return result;
  }

  void _exportSelection() {
    final ids = _channelsForSelection(_selection.ordered(_visibleIds))
        .map((id) => widget.runtime.collectionFor(id)?.id)
        .whereType<String>()
        .toList();
    if (_busy || ids.isEmpty) return;
    _endGestures();
    setState(_selection.clear);
    unawaited(PortableTransferNavigation.openExportSettings(context, ids));
  }

  Widget _selectionActions(PodcastSubscriptionLayout layout) {
    final ids = _selection.ordered(_visibleIds);
    final channels = _channelsForSelection(ids);
    return IgnorePointer(
      ignoring: _busy,
      child: MediaLibrarySelectionBottomBar.custom(
        onTranscribe: channels.isEmpty
            ? null
            : () {
                openTranscriptionQueue(
                  context,
                  TranscriptionMediaSelection(podcastChannelIds: channels),
                );
              },
        onAddToQueue: (progress) async {
          final result = await addPodcastChannelsToQueue(
            context,
            channels,
            progress: progress,
          );
          if (mounted && result.completed) setState(_selection.clear);
          return result;
        },
        actions: [
          MediaLibrarySelectionBarAction(
            label: _removeLabel(ids),
            icon: Icons.delete,
            color: AppTokens.danger,
            onPressed: () => unawaited(_removeSelection()),
          ),
          MediaLibrarySelectionBarAction(
            label: '导出',
            icon: Icons.unarchive_outlined,
            color: AppTokens.text1,
            tooltip: '导出为 Fluent Pack 或 Zip',
            onPressed: channels.isEmpty ? null : _exportSelection,
          ),
          if (ids.length == 1)
            MediaLibrarySelectionBarAction(
              label: '重命名',
              icon: Icons.edit,
              color: AppTokens.text1,
              onPressed: () => unawaited(_rename(ids.single)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = _layout;
    if (_folderId != null && layout.folder(_folderId!) == null) {
      _folderId = null;
    }
    final channels = widget.runtime.controller.channels;
    _visibleIds = layout.entries(_folderId, channels);
    _selection.retain(_visibleIds);
    _itemKeys.removeWhere((id, _) => !_visibleIds.contains(id));
    final byId = {for (final channel in channels) channel.id: channel};
    widget.overviewController._publishSelection();
    _refreshDragAfterLayout();
    return PopScope(
      canPop: !widget.isActive || (!_selection.active && _folderId == null),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handleBack();
      },
      child: Column(
        children: [
          _toolbar(layout),
          if (_notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Text(
                _notice!,
                style: PodcastType.meta.copyWith(color: AppTokens.text2),
              ),
            ),
          Expanded(
            child: MediaLibraryScrollViewport(
              controller: widget.controller,
              contentInsetFraction:
                  MediaLibraryScrollViewport.libraryInsetFraction(
                    SettingsService(),
                    MediaQuery.sizeOf(context),
                    useList: false,
                  ),
              isActive: widget.isActive,
              bottomObstruction: widget.bottomPadding,
              child: NotificationListener<SizeChangedLayoutNotification>(
                onNotification: (_) {
                  _refreshDragAfterLayout();
                  return false;
                },
                child: SizeChangedLayoutNotifier(
                  child: Listener(
                    key: _viewportKey,
                    onPointerDown: (event) => _pointers.down(event.pointer),
                    onPointerMove: (event) {
                      if (_rangeAnchorId != null &&
                          _pointers.move(event.pointer)) {
                        _applyRange(event.position);
                      }
                    },
                    onPointerUp: (event) {
                      if (_pointers.up(event.pointer) ||
                          _reorderDrag.pointer == event.pointer) {
                        _endGestures();
                      }
                    },
                    onPointerCancel: (event) {
                      if (_pointers.up(event.pointer) ||
                          _reorderDrag.pointer == event.pointer) {
                        _endGestures();
                      }
                    },
                    child: _visibleIds.isEmpty
                        ? PodcastEmpty(
                            title: _folderId == null ? '把喜欢的频道带进来' : '文件夹还是空的',
                            message: _folderId == null
                                ? '搜索播客、粘贴订阅链接，或导入已有的 OPML 列表。'
                                : '可以从上一级拖入订阅，也可以用多选菜单移动频道。',
                            action: QuietEmptyAction(
                              onPressed: widget.onDiscover,
                              label: '搜索与导入',
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final screen = MediaQuery.sizeOf(context);
                              final metrics =
                                  MediaLibraryLayoutDefaults.cardGrid(
                                    textScaler: MediaQuery.textScalerOf(
                                      context,
                                    ),
                                    textStyle: DefaultTextStyle.of(
                                      context,
                                    ).style,
                                    screenSize: Size(
                                      constraints.maxWidth,
                                      screen.height,
                                    ),
                                    style: SettingsService()
                                        .collectionCardStyleFor(screen),
                                  );
                              return PlaybackGridView.builder(
                                key: PageStorageKey((
                                  'podcast-subscriptions',
                                  _folderId,
                                )),
                                controller: widget.controller,
                                itemKey: (index) => _visibleIds[index],
                                padding: EdgeInsets.fromLTRB(
                                  metrics.outerPadding,
                                  metrics.topPadding,
                                  metrics.outerPadding,
                                  widget.bottomPadding,
                                ),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: metrics.crossAxisCount,
                                      mainAxisExtent: metrics
                                          .cellHeightForCoverAspect(1),
                                      crossAxisSpacing: metrics.crossSpacing,
                                      mainAxisSpacing: metrics.mainSpacing,
                                    ),
                                itemCount: _visibleIds.length,
                                itemBuilder: (context, index) {
                                  final id = _visibleIds[index];
                                  final folder = layout.folder(id);
                                  final selected = _selection.contains(id);
                                  final card = folder == null
                                      ? _ChannelCard(
                                          channel: byId[id]!,
                                          titleScale: metrics.titleScale,
                                          isSelected: selected,
                                          isSelectionMode: _selection.active,
                                          onTap: () => _activate(id),
                                          onSecondaryTap: () =>
                                              _toggle(id, force: true),
                                        )
                                      : _PodcastSubscriptionFolderCard(
                                          folder: folder,
                                          onTranscribe: _selection.active
                                              ? null
                                              : () {
                                                  openTranscriptionQueue(
                                                    context,
                                                    TranscriptionMediaSelection(
                                                      podcastChannelIds:
                                                          _channelsForSelection(
                                                            [folder.id],
                                                          ),
                                                    ),
                                                  );
                                                },
                                          titleScale: metrics.titleScale,
                                          count: layout
                                              .entries(id, channels)
                                              .length,
                                          isSelected: selected,
                                          onTap: () => _activate(id),
                                          onSecondaryTap: () =>
                                              _toggle(id, force: true),
                                        );
                                  return KeyedSubtree(
                                    key: _itemKeys.putIfAbsent(
                                      id,
                                      GlobalKey.new,
                                    ),
                                    child: IgnorePointer(
                                      ignoring: _busy,
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          MediaLibraryItemInteractionWrapper(
                                            index: index,
                                            dragDelay:
                                                mediaLibraryLongPressDelay,
                                            isSelected: selected,
                                            selectedCount:
                                                _selection.ids.length,
                                            folderId: folder?.id,
                                            onMoveToFolder: (from, target) =>
                                                _move(
                                                  _idsForDrop(from),
                                                  target,
                                                ),
                                            onReorder: (from, _) =>
                                                _reorder(from, id),
                                            onTap: () => _activate(id),
                                            onDragStarted: () => _beginDrag(id),
                                            onDragPosition: _dragPosition,
                                            onDragEnd: _endGestures,
                                            child: card,
                                          ),
                                          if (_selection.active)
                                            Positioned(
                                              top: 0,
                                              right: 0,
                                              child: GestureDetector(
                                                onTap: () =>
                                                    _toggle(id, force: true),
                                                onHorizontalDragStart:
                                                    (details) => _beginRange(
                                                      index,
                                                      details.globalPosition,
                                                    ),
                                                onHorizontalDragUpdate:
                                                    (details) => _applyRange(
                                                      details.globalPosition,
                                                    ),
                                                onHorizontalDragEnd: (_) =>
                                                    _endGestures(),
                                                onVerticalDragStart:
                                                    (details) => _beginRange(
                                                      index,
                                                      details.globalPosition,
                                                    ),
                                                onVerticalDragUpdate:
                                                    (details) => _applyRange(
                                                      details.globalPosition,
                                                    ),
                                                onVerticalDragEnd: (_) =>
                                                    _endGestures(),
                                                onLongPressStart: (details) =>
                                                    _beginRange(
                                                      index,
                                                      details.globalPosition,
                                                    ),
                                                onLongPressMoveUpdate:
                                                    (details) => _applyRange(
                                                      details.globalPosition,
                                                    ),
                                                onLongPressEnd: (_) =>
                                                    _endGestures(),
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                child: Padding(
                                                  key: ValueKey(
                                                    'podcast-select-$id',
                                                  ),
                                                  padding: EdgeInsets.all(
                                                    MediaListLayoutMetrics.gridSelectionHitPadding(
                                                      metrics.cellWidth,
                                                    ),
                                                  ),
                                                  child: Icon(
                                                    selected
                                                        ? Icons.check_circle
                                                        : Icons.circle_outlined,
                                                    color: selected
                                                        ? Colors.blueAccent
                                                        : Colors.white70,
                                                    size:
                                                        MediaListLayoutMetrics.gridSelectionIconSize(
                                                          metrics.cellWidth,
                                                        ),
                                                  ),
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
                          ),
                  ),
                ),
              ),
            ),
          ),
          if (!widget.selectionManagedByHost)
            MediaLibrarySelectionBarTransition(
              child: _selection.active && _selection.ids.isNotEmpty
                  ? _selectionActions(layout)
                  : null,
            ),
        ],
      ),
    );
  }
}

class _PodcastSubscriptionFolderCard extends StatelessWidget {
  const _PodcastSubscriptionFolderCard({
    required this.folder,
    this.onTranscribe,
    required this.titleScale,
    required this.count,
    required this.isSelected,
    required this.onTap,
    required this.onSecondaryTap,
  });
  final PodcastSubscriptionFolder folder;
  final VoidCallback? onTranscribe;
  final double titleScale;
  final int count;
  final bool isSelected;
  final VoidCallback onTap, onSecondaryTap;

  @override
  Widget build(BuildContext context) => MediaLibraryCardScale(
    builder: (context) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final titleSize = MediaLibraryLayoutDefaults.titleFontSize(
          width,
          titleScale,
        );
        return MediaLibraryGridCard(
          key: ValueKey('podcast-folder-${folder.id}'),
          radius: MediaLibraryLayoutDefaults.cardCornerRadius(width),
          isSelected: isSelected,
          onTap: onTap,
          onSecondaryTap: onSecondaryTap,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: FolderPlaceholderCover(
                      folderId: folder.id,
                      folderName: folder.name,
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: MediaListLayoutMetrics.cardGridContentPadding(
                        width,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              folder.name,
                              maxLines: SettingsService().cardTitleMaxLinesFor(
                                MediaQuery.sizeOf(context),
                              ),
                              overflow: TextOverflow.ellipsis,
                              style: PodcastType.title.copyWith(
                                fontSize: titleSize,
                              ),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Padding(
                            padding: EdgeInsets.only(
                              right: onTranscribe == null ? 0 : width * .19,
                            ),
                            child: Text(
                              '$count 个项目',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PodcastType.meta.copyWith(
                                fontSize:
                                    MediaLibraryLayoutDefaults.metaFontSize(
                                      titleSize,
                                    ),
                                color: Colors.white54,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (onTranscribe != null)
                MediaLibraryActionDock(
                  chipSize: MediaLibraryActionDockMetrics.gridChipSize(width),
                  more: PodcastMenuButton(
                    title: '文件夹操作',
                    subtitle: folder.name,
                    compact: true,
                    fillSlot: true,
                    actions: const [
                      PodcastMenuAction(
                        'transcribe',
                        transcriptionQueueLabel,
                        transcriptionQueueIcon,
                      ),
                    ],
                    onSelected: (_) => onTranscribe?.call(),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
