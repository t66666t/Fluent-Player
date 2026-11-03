part of 'cloud_drive_screen.dart';

class _CloudDriveBrowserPane extends StatefulWidget {
  const _CloudDriveBrowserPane({
    super.key,
    required this.runtime,
    required this.account,
    required this.options,
    required this.onOptions,
    required this.isActive,
    required this.onSettings,
    this.targetFolderId,
    this.initialDirectoryId,
    this.initialQuery,
    this.popOnSearchBack = false,
    this.onSelectionChanged,
  });
  final CloudDriveRuntime runtime;
  final CloudDriveAccount account;
  final CloudDriveViewOptions options;
  final ValueChanged<CloudDriveViewOptions> onOptions;
  final bool isActive;
  final String? targetFolderId;
  final String? initialDirectoryId, initialQuery;
  final bool popOnSearchBack;
  final Future<void> Function() onSettings;
  final ValueChanged<bool>? onSelectionChanged;
  @override
  State<_CloudDriveBrowserPane> createState() => _CloudDriveBrowserPaneState();
}

class _CloudDriveBrowserPaneState extends State<_CloudDriveBrowserPane> {
  final _directories = <String, CloudDriveDirectorySession>{};
  final _scrolls = <String, ScrollController>{};
  final _revealedEntries = <String>{};
  String get _rootId => cloudDriveRootId(widget.account.providerId);
  late final List<({String id, String name})> _trail = [
    (id: _rootId, name: '全部文件'),
    if (widget.initialDirectoryId != null &&
        widget.initialDirectoryId != _rootId)
      (id: widget.initialDirectoryId!, name: '缓存来源文件夹'),
  ];
  late final _query = TextEditingController(text: widget.initialQuery);
  final _searchFocus = FocusNode();
  final _viewport = GlobalKey();
  final _selected = <String>{};
  bool _selecting = false;
  late bool _searching = widget.initialQuery?.isNotEmpty == true;
  int? _anchor;
  MediaLibraryGridGeometry? _geometry;
  MediaLibrarySelectionAutoScroller? _autoScroll;
  Offset? _dragPosition;
  Set<String> _dragSnapshot = {};
  CloudDriveReferenceImport? _import;
  bool _preparingImport = false;
  bool _pickingImportLocation = false;
  bool get _importBusy => _preparingImport || _import?.running == true;
  Map<String, VideoCollection>? _libraryFoldersBySource;
  List<CloudDriveEntry> _lastImportSelection = const [];
  String? _lastImportTarget;
  bool _opening = false;
  bool get _atInitialSearch =>
      widget.popOnSearchBack &&
      widget.initialQuery?.isNotEmpty == true &&
      _trail.length == 1;
  String get _directoryId => _trail.last.id;
  CloudDriveDirectorySession? get _session => _directories[_directoryId];
  ScrollController get _scroll =>
      _scrolls.putIfAbsent(_directoryId, () => PlaybackScrollController());
  List<CloudDriveEntry>? _projectionInput;
  List<CloudDriveEntry> _projection = const [];
  CloudDriveViewOptions? _projectionOptions;
  String _projectionQuery = '';
  bool _projectionComplete = false;
  List<CloudDriveEntry> get _entries {
    final session = _session;
    final raw = session?.entries ?? const <CloudDriveEntry>[];
    if (!identical(raw, _projectionInput) ||
        !identical(widget.options, _projectionOptions) ||
        _query.text != _projectionQuery ||
        (session?.complete ?? false) != _projectionComplete) {
      _projectionInput = raw;
      _projectionOptions = widget.options;
      _projectionQuery = _query.text;
      _projectionComplete = session?.complete ?? false;
      _projection = widget.options.project(
        raw,
        query: _query.text,
        sorted: _projectionComplete,
      );
    }
    return _projection;
  }

  @override
  void initState() {
    super.initState();
    widget.runtime.launch.library.addListener(_libraryChanged);
    if (widget.isActive) _ensureDirectory();
  }

  @override
  void didUpdateWidget(covariant _CloudDriveBrowserPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _ensureDirectory();
    if (!widget.isActive && oldWidget.isActive) {
      _selecting = false;
      _selected.clear();
      _endDrag();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSelectionChanged?.call(false);
      });
    }
  }

  @override
  void dispose() {
    _endDrag();
    widget.runtime.launch.library.removeListener(_libraryChanged);
    _query.dispose();
    _searchFocus.dispose();
    if (_import?.running == true) {
      _import?.cancel();
    } else {
      _import?.dispose();
    }
    for (final session in _directories.values) {
      session.removeListener(_changed);
      session.release();
    }
    for (final scroll in _scrolls.values) {
      scroll.dispose();
    }
    super.dispose();
  }

  void _changed() {
    if (mounted && widget.isActive) setState(() {});
  }

  void _libraryChanged() {
    _libraryFoldersBySource = null;
    _changed();
  }

  ({String? folderId})? _libraryLocation(CloudDriveEntry entry) {
    final library = widget.runtime.launch.library;
    final sourceKey = cloudDriveEntryKey(entry);
    if (entry.kind == CloudDriveEntryKind.folder) {
      final folders = _libraryFoldersBySource ??= {
        for (final folder in library.storageCollections)
          if (folder.sourceRef?.cloudDrive case final source?)
            if (library.activityProjection.isVisibleCollection(folder.id))
              source.sourceKey: folder,
      };
      final folder = folders[sourceKey];
      return folder == null ? null : (folderId: folder.id);
    }
    final item = library.cloudDriveCardForSource(sourceKey);
    return item != null && library.activityProjection.isVisibleMedia(item.id)
        ? (folderId: item.parentId)
        : null;
  }

  void _ensureDirectory({bool refresh = false}) {
    if (refresh) {
      final previous = _directories.remove(_directoryId);
      previous?.removeListener(_changed);
      previous?.release();
    }
    final directory = _directories.putIfAbsent(_directoryId, () {
      final session = CloudDriveDirectorySession(
        runtime: widget.runtime,
        account: widget.account,
        directoryId: _directoryId,
      );
      session.addListener(_changed);
      return session;
    });
    unawaited(directory.finish().catchError((Object _) {}));
  }

  void _selection(bool enabled) {
    setState(() {
      _selecting = enabled;
      if (!enabled) _selected.clear();
    });
    widget.onSelectionChanged?.call(enabled);
  }

  static bool _selectable(CloudDriveEntry entry) =>
      entry.kind == CloudDriveEntryKind.folder ||
      entry.kind == CloudDriveEntryKind.video ||
      entry.kind == CloudDriveEntryKind.audio;

  void _toggle(int index, {bool enter = false}) {
    final entries = _entries;
    if (index >= entries.length || !_selectable(entries[index])) return;
    if (enter && !_selecting) _selection(true);
    setState(() {
      if (HardwareKeyboard.instance.isShiftPressed && _anchor != null) {
        _selected.addAll(
          MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
            snapshot: _selected,
            startIndex: _anchor!,
            currentIndex: index,
            itemCount: entries.length,
            idAt: (i) =>
                _selectable(entries[i]) ? cloudDriveEntryKey(entries[i]) : null,
          ),
        );
      } else {
        final key = cloudDriveEntryKey(entries[index]);
        if (!_selected.add(key)) _selected.remove(key);
        _anchor = index;
      }
    });
  }

  Future<void> _all() async {
    _selection(true);
    final directory = _session;
    final query = _query.text;
    try {
      await directory?.finish();
    } catch (_) {
      return;
    }
    if (!mounted ||
        !widget.isActive ||
        !_selecting ||
        !identical(directory, _session) ||
        query != _query.text ||
        directory?.complete != true) {
      return;
    }
    final eligible = _entries
        .where(_selectable)
        .map(cloudDriveEntryKey)
        .toSet();
    setState(() {
      if (_selected.containsAll(eligible)) {
        _selected.clear();
      } else {
        _selected.addAll(eligible);
      }
    });
  }

  void _dragStart(int index, Offset global) {
    _anchor = index;
    _dragSnapshot = Set.of(_selected);
    _autoScroll?.dispose();
    _autoScroll = MediaLibrarySelectionAutoScroller(
      scrollController: _scroll,
      onScrolled: () {
        if (_dragPosition != null) _dragUpdate(_dragPosition!);
      },
    );
    _dragUpdate(global);
  }

  void _dragUpdate(Offset global) {
    final box = _viewport.currentContext?.findRenderObject() as RenderBox?;
    final geometry = _geometry;
    if (box == null ||
        geometry == null ||
        _anchor == null ||
        !_scroll.hasClients) {
      return;
    }
    _dragPosition = global;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    _autoScroll?.update(
      pointerY: global.dy,
      viewportTop: top,
      viewportBottom: bottom,
    );
    final clamped = MediaLibraryRangeSelection.clampPointerToVerticalViewport(
      global: global,
      viewportTop: top,
      viewportBottom: bottom - 1,
    );
    final local = box.globalToLocal(clamped) + Offset(0, _scroll.offset);
    final entries = _entries;
    final index = geometry.indexAt(local, entries.length);
    if (index == null) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(
          MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
            snapshot: _dragSnapshot,
            startIndex: _anchor!,
            currentIndex: index,
            itemCount: entries.length,
            idAt: (i) =>
                _selectable(entries[i]) ? cloudDriveEntryKey(entries[i]) : null,
          ),
        );
    });
  }

  void _endDrag() {
    _autoScroll?.dispose();
    _autoScroll = null;
    _dragPosition = null;
  }

  void _popTo(int index) {
    _endDrag();
    _selection(false);
    setState(() {
      _trail.removeRange(index + 1, _trail.length);
      _query.clear();
      _searching = false;
    });
    _ensureDirectory();
  }

  bool _escape() {
    // A search submitted from home is a page in its own right. Back returns
    // home directly; folder navigation and selection retain their local Back.
    if (_atInitialSearch) {
      if (_selecting) {
        _selection(false);
        return true;
      }
      return false;
    }
    if (_searching) {
      setState(() {
        _query.clear();
        _searching = false;
      });
      return true;
    }
    if (_selecting) {
      _selection(false);
      return true;
    }
    if (_trail.length > 1) {
      _popTo(_trail.length - 2);
      return true;
    }
    return false;
  }

  Future<void> _open(int index) async {
    if (_selecting) {
      _toggle(index);
      return;
    }
    final entry = _entries[index];
    if (entry.kind == CloudDriveEntryKind.folder) {
      setState(() {
        _trail.add((
          id: entry.providerId == 'baidu'
              ? entry.pathHint ?? entry.fileId
              : entry.fileId,
          name: entry.name,
        ));
        _query.clear();
        _searching = false;
      });
      _ensureDirectory();
    } else if (entry.kind == CloudDriveEntryKind.video ||
        entry.kind == CloudDriveEntryKind.audio) {
      if (_opening) return;
      _opening = true;
      try {
        await widget.runtime.launch.openEntry(
          context: context,
          entry: entry,
          visibleEntries: widget.options.project(_session!.entries),
          directory: _session,
          options: widget.options,
          openedFromFolderId: widget.targetFolderId,
        );
      } catch (_) {
        AppToast.show('暂时无法打开该媒体，请重试', type: AppToastType.error);
      } finally {
        _opening = false;
      }
    } else {
      AppToast.show(
        entry.kind == CloudDriveEntryKind.subtitle
            ? '字幕文件可在播放器的字幕管理中选择'
            : '该文件类型暂不支持播放',
      );
    }
  }

  Future<void> _importSelected({bool chooseLocation = false}) async {
    final selection = _entries
        .where((e) => _selected.contains(cloudDriveEntryKey(e)))
        .toList();
    await _importEntries(selection, chooseLocation: chooseLocation);
  }

  Future<void> _importEntries(
    List<CloudDriveEntry> selection, {
    bool chooseLocation = false,
  }) async {
    if (selection.isEmpty || _importBusy) return;
    setState(() => _preparingImport = true);
    try {
      // Snapshot once for the whole operation, including a recursive import.
      final request = SettingsService().captureImportPlacement(
        ImportCardFeature.cloudDrive,
        openedFromFolderId: widget.targetFolderId,
      );
      String? target;
      if (chooseLocation ||
          request.placement == ImportCardPlacement.askEveryTime) {
        setState(() => _pickingImportLocation = true);
        // Previewing or cancelling must not create the default source folder.
        final initial = request.placement == ImportCardPlacement.askEveryTime
            ? widget.targetFolderId
            : request.folderId;
        final pick = await showLibraryFolderPicker(
          context,
          library: widget.runtime.launch.library,
          initialFolderId: initial,
          title: '加入媒体库 · 选择位置',
          confirmLabel: '加入到这里',
          offerSetAsDefault: false,
          header: (_) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '已选 ${selection.length} 项 · 保存在线播放引用，文件夹保留层级。'
              '本次选择不会更改默认设置。',
            ),
          ),
        );
        if (pick == null || !mounted || !widget.isActive) return;
        setState(() => _pickingImportLocation = false);
        target = pick.folderId;
      } else {
        target = await widget.runtime.launch.library.resolveImportCardParentId(
          feature: ImportCardFeature.cloudDrive,
          openedFromFolderId: widget.targetFolderId,
          request: request,
        );
      }
      if (!mounted || !widget.isActive) return;
      await _runImport(selection, target);
    } on ImportPlacementException catch (error) {
      if (mounted) AppToast.show(error.message, type: AppToastType.error);
    } catch (_) {
      if (mounted) {
        AppToast.show('暂时无法加入媒体库，请重试', type: AppToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          _preparingImport = false;
          _pickingImportLocation = false;
        });
      }
    }
  }

  String _libraryPath(String? folderId) {
    final parts = <String>[];
    final seen = <String>{};
    while (folderId != null && seen.add(folderId)) {
      final folder = widget.runtime.launch.library.getCollection(folderId);
      if (folder == null) break;
      parts.insert(0, folder.name);
      folderId = folder.parentId;
    }
    return ['媒体库', ...parts].join(' / ');
  }

  Future<void> _runImport(
    List<CloudDriveEntry> selection,
    String? target,
  ) async {
    if (_import?.running == true) return;
    _lastImportSelection = List.of(selection);
    _lastImportTarget = target;
    _import?.dispose();
    final job = CloudDriveReferenceImport(
      runtime: widget.runtime,
      account: widget.account,
      targetFolderId: target,
    );
    _import = job;
    job.addListener(_changed);
    setState(() {});
    try {
      await job.run(selection);
    } catch (_) {
      AppToast.show('保存导入结果失败，请重试', type: AppToastType.error);
    } finally {
      job.removeListener(_changed);
    }
    if (!mounted) {
      job.dispose();
      return;
    }
    _selection(false);
    setState(() {});
    AppToast.show(
      '${!job.persisted
          ? '尚未保存，请重试'
          : job.cancelled
          ? '已取消'
          : '入库完成'} · 新增 ${job.created} · 已有 ${job.reused} · 失败 ${job.failed}'
      '${job.persisted ? '\n${_libraryPath(target)}' : ''}',
      duration: const Duration(seconds: 5),
      action: job.persisted
          ? AppToastAction(
              label: '查看媒体库',
              onPressed: () {
                if (!mounted) return;
                CloudDriveNavigation.viewFolder(target);
              },
            )
          : null,
    );
  }

  void _search() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _style() {
    unawaited(
      MediaLibraryStyleSheet.show(
        context: context,
        scope: MediaLibraryCardStyleScope.collection,
      ),
    );
  }

  void _view() {
    unawaited(
      SettingsService().updateSetting(
        'mediaLibraryViewMode',
        SettingsService().mediaLibraryViewMode == 1 ? 0 : 1,
      ),
    );
  }

  void _playbackKey(LogicalKeyboardKey key) {
    final playback = widget.runtime.launch.playback;
    if (playback.currentItem == null) return;
    if (key == LogicalKeyboardKey.space) {
      if (playback.desiredPlaying) {
        unawaited(playback.pause());
      } else {
        unawaited(playback.resume());
      }
    } else {
      final settings = SettingsService();
      playback.handleExternalDoubleTapSeek(
        isLeft: key == LogicalKeyboardKey.arrowLeft,
        doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
        enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
        subtitleOffset: settings.subtitleOffset,
      );
    }
  }

  @override
  Widget build(BuildContext context) => MediaLibraryPageShortcuts(
    enabled: widget.isActive,
    onEscape: _escape,
    onSelectAll: () => unawaited(_all()),
    bindings: {
      LogicalKeyboardKey.keyS: _search,
      LogicalKeyboardKey.keyB: () => _selection(!_selecting),
      LogicalKeyboardKey.keyV: _view,
      LogicalKeyboardKey.keyT: _style,
      LogicalKeyboardKey.keyP: widget.onSettings,
      LogicalKeyboardKey.keyR: () {
        setState(() => _ensureDirectory(refresh: true));
      },
      LogicalKeyboardKey.keyI: () => unawaited(_importSelected()),
      LogicalKeyboardKey.keyU: () {
        if (_trail.length > 1) _popTo(_trail.length - 2);
      },
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
      ])
        key: () => _playbackKey(key),
    },
    child: PopScope(
      canPop:
          !widget.isActive ||
          (!_selecting &&
              _trail.length == 1 &&
              (!_searching || _atInitialSearch)),
      onPopInvokedWithResult: (popped, _) {
        if (!popped && widget.isActive) _escape();
      },
      child: Stack(
        children: [
          MediaLibrarySafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                children: [
                  if (constraints.maxHeight >= 40) _toolbar(),
                  Expanded(
                    child: MediaLibraryScrollViewport.library(
                      settings: context.watch<SettingsService>(),
                      screenSize: MediaQuery.sizeOf(context),
                      controller: _scroll,
                      isActive: widget.isActive,
                      child: _contents(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.isActive && (_selecting || _importBusy))
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MediaLibraryBottomBarObstruction(
                child: ColoredBox(
                  color: AppTokens.bgRaised,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: _selectionBarContents(),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  void _selectionExit() => _selection(false);

  List<CloudDriveEntry> get _selectedEntries => _entries
      .where((entry) => _selected.contains(cloudDriveEntryKey(entry)))
      .toList();

  Future<QueueAddResult> _addSelectionToQueue([QueueAddProgress? progress]) async {
    final entries = _selectedEntries;
    final result = await addCloudSelectionToQueue(
      context,
      entries,
      progress: progress,
    );
    if (mounted && !result.cancelled && !result.queueChanged) {
      setState(() {
        for (final entry in entries) {
          if (!result.failed.contains(cloudDriveEntryKey(entry))) {
            _selected.remove(cloudDriveEntryKey(entry));
          }
        }
        if (_selected.isEmpty) _selecting = false;
      });
      widget.onSelectionChanged?.call(_selecting);
    }
    return result;
  }

  Widget _selectionBarContents() => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
      final compact = constraints.maxWidth < 620 * scale;
      final overflowSecondary = constraints.maxWidth < 440 * scale;
      final importing = _import?.running == true;
      return SizedBox(
        key: const ValueKey('cloud-selection-single-row'),
        height: 44,
        child: Row(
          children: [
            Expanded(
              child: Text(
                importing
                    ? '正在入库 ${_import!.created + _import!.reused} 项'
                    : _preparingImport
                    ? '正在准备入库…'
                    : '已选 ${_selected.length} 项',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            if (importing)
              DesktopButtonClickRegion(
                child: TextButton(
                  onPressed: _import!.cancel,
                  child: const Text('取消'),
                ),
              )
            else ...[
              if (!overflowSecondary)
                SizedBox(
                  width: compact ? 44 : 132,
                  child: AddToPlaylistButton(
                    onAdd: _selected.isEmpty || _importBusy
                        ? null
                        : _addSelectionToQueue,
                    key: const ValueKey('cloud-selection-add-to-playlist'),
                    label: '插播',
                    tooltip: AddToPlaylistButton.defaultLabel,
                    stacked: compact,
                    fitLabel: true,
                    height: 44,
                  ),
                ),
              Flexible(
                fit: FlexFit.tight,
                child: TranscriptionQueueButton(
                  key: const ValueKey('cloud-selection-transcribe'),
                  compact: compact,
                  height: 44,
                  onPressed: _selected.isEmpty || _importBusy
                      ? null
                      : () {
                          openTranscriptionQueue(
                            context,
                            TranscriptionMediaSelection(
                              cloudEntries: _selectedEntries,
                            ),
                            cloudRuntime: widget.runtime,
                          );
                        },
                ),
              ),
              if (!overflowSecondary && MediaCacheService.instance != null)
                _selectionCacheAction(compact),
              SizedBox(
                width: 36,
                child: MediaLibraryTooltip(
                  message: '更多操作',
                  child: TooltipVisibility(
                    visible: false,
                    child: CapsulePopupMenuButton<String>(
                      key: const ValueKey('cloud-selection-more'),
                      useRootNavigator: true,
                      tooltip: '更多操作',
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_horiz, size: 20),
                      enabled: !_importBusy,
                      onSelected: (action) {
                        switch (action) {
                          case 'location':
                            unawaited(_importSelected(chooseLocation: true));
                          case 'playlist':
                            unawaited(_addSelectionToQueue());
                          case 'cache':
                            unawaited(
                              cacheUiAction(
                                () => cacheCloudSelection(
                                  context,
                                  _selectedEntries,
                                ),
                              ),
                            );
                          case 'cacheSettings':
                            unawaited(
                              cacheUiAction(
                                () => showMediaCacheSettings(context),
                              ),
                            );
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'location',
                          enabled: _selected.isNotEmpty,
                          child: const Text('选择入库位置…'),
                        ),
                        if (overflowSecondary)
                          PopupMenuItem(
                            value: 'playlist',
                            enabled: _selected.isNotEmpty,
                            child: const Text('加入播放列表'),
                          ),
                        if (overflowSecondary &&
                            MediaCacheService.instance != null)
                          PopupMenuItem(
                            value: 'cache',
                            enabled: _selected.isNotEmpty,
                            child: const Text('缓存 / 管理缓存'),
                          ),
                        if (MediaCacheService.instance != null)
                          const PopupMenuItem(
                            value: 'cacheSettings',
                            child: Text('缓存画质设置'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 36,
                child: DesktopButtonClickRegion(
                  child: MediaLibraryTooltip(
                    message: '退出多选',
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      onPressed: _preparingImport ? null : _selectionExit,
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ),
                ),
              ),
              DesktopButtonClickRegion(
                child: SizedBox(
                  width: compact ? 76 : 116,
                  child: FilledButton.tonal(
                    key: const ValueKey('cloud-selection-add-to-library'),
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 10 : 16,
                      ),
                      textStyle: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(fontSize: 13),
                    ),
                    onPressed: _selected.isEmpty || _importBusy
                        ? null
                        : () => _importSelected(),
                    child: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('加入媒体库', maxLines: 1, softWrap: false),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _selectionCacheAction(bool compact) => ListenableBuilder(
    listenable: MediaCacheService.instance!,
    builder: (context, _) {
      final entries = _entries
          .where((entry) => _selected.contains(cloudDriveEntryKey(entry)))
          .toList();
      final sources = entries
          .map(cacheSourceForCloudEntry)
          .whereType<CacheSource>()
          .toList();
      final allCached =
          entries.isNotEmpty &&
          sources.length == entries.length &&
          sources.every(
            (source) => MediaCacheService.instance!.hasCache(source.key),
          );
      final icon = allCached
          ? Icons.delete_sweep_outlined
          : Icons.download_outlined;
      final label = allCached ? '删除所有缓存' : '缓存';
      final VoidCallback? action = _selected.isEmpty
          ? null
          : () => unawaited(
              cacheUiAction(() => cacheCloudSelection(context, entries)),
            );
      if (compact) {
        return SizedBox(
          width: 36,
          child: DesktopButtonClickRegion(child: MediaLibraryTooltip(
            message: label,
            child: IconButton(
            padding: EdgeInsets.zero,
            icon: Icon(icon, size: 18),
            onPressed: action,
          ))),
        );
      }
      return DesktopButtonClickRegion(child: TextButton.icon(
        icon: Icon(icon, size: 18),
        label: Text(label),
        onPressed: action,
      ));
    },
  );

  Widget _toolbar() {
    final directory = _session;
    final loading = directory?.loading == true;
    final incomplete = directory != null && !directory.complete;
    final status = _import?.running == true
        ? '正在入库：${_import!.currentName}'
        : _preparingImport
        ? '正在准备入库…'
        : directory?.error?.message ??
              (incomplete
                  ? '已读取 ${directory.entries.length} 项 · 目录尚未完整'
                  : '${directory?.entries.length ?? 0} 项');
    return SizedBox(
      height: math.max(40, MediaQuery.textScalerOf(context).scale(14) + 16),
      child: Stack(
        children: [
          Row(
            children: [
              DesktopButtonClickRegion(child: IconButton(
                tooltip: shortcutHintLabel(
                  context,
                  _selecting ? '退出多选' : '上一级',
                  _selecting ? 'Esc' : 'U',
                ),
                onPressed: _selecting
                    ? _selectionExit
                    : _trail.length > 1
                    ? () => _popTo(_trail.length - 2)
                    : null,
                icon: Icon(
                  _selecting ? Icons.close : Icons.arrow_back,
                  size: 19,
                ),
              )),
              Expanded(
                child: _searching
                    ? TextField(
                        controller: _query,
                        focusNode: _searchFocus,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索当前目录',
                        ),
                      )
                    : Tooltip(
                        message: status,
                        child: MediaLibraryFolderBreadcrumb(
                          compact: true,
                          hitPadding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                          textStyle: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                height: 1,
                              ),
                          crumbs: [
                            for (final crumb in _trail)
                              MediaLibraryBreadcrumbCrumb(
                                folderId: crumb.id,
                                label: crumb.name,
                              ),
                          ],
                          onSelected: (id) => _popTo(
                            _trail.indexWhere((crumb) => crumb.id == id),
                          ),
                        ),
                      ),
              ),
              if (directory?.error != null || (incomplete && !loading))
                DesktopButtonClickRegion(child: IconButton(
                  tooltip: '$status · 点击继续读取',
                  onPressed: () => _ensureDirectory(),
                  icon: const Icon(Icons.refresh, size: 18),
                )),
              if (loading)
                DesktopButtonClickRegion(child: IconButton(
                  tooltip: '$status · 暂停读取',
                  onPressed: directory!.pause,
                  icon: const Icon(Icons.pause_circle_outline, size: 18),
                )),
              CapsulePopupMenuButton<CloudDriveViewSort>(
                useRootNavigator: true,
                tooltip: '排序：${widget.options.sort.label}',
                icon: Icon(
                  widget.options.descending ? Icons.sort : Icons.sort_by_alpha,
                  size: 19,
                ),
                onSelected: (sort) =>
                    widget.onOptions(widget.options.copyWith(sort: sort)),
                itemBuilder: (_) => [
                  for (final sort in CloudDriveViewSort.values)
                    CheckedPopupMenuItem(
                      value: sort,
                      checked: widget.options.sort == sort,
                      child: Text(sort.label),
                    ),
                ],
              ),
              CapsulePopupMenuButton<String>(
                useRootNavigator: true,
                tooltip: '目录操作',
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: (action) {
                  switch (action) {
                    case 'direction':
                      widget.onOptions(
                        widget.options.copyWith(
                          descending: !widget.options.descending,
                        ),
                      );
                    case 'folders':
                      widget.onOptions(
                        widget.options.copyWith(
                          foldersFirst: !widget.options.foldersFirst,
                        ),
                      );
                    case 'refresh':
                      setState(() => _ensureDirectory(refresh: true));
                    case 'search':
                      _search();
                    case 'view':
                      _view();
                    case 'style':
                      _style();
                    case 'select':
                      _selection(!_selecting);
                    case 'all':
                      unawaited(_all());
                    case 'retryImport':
                      unawaited(
                        _runImport(_lastImportSelection, _lastImportTarget),
                      );
                    case 'settings':
                      unawaited(widget.onSettings());
                    default:
                      final filter = CloudDriveViewFilter.values
                          .where((f) => f.name == action)
                          .firstOrNull;
                      if (filter != null) {
                        widget.onOptions(
                          widget.options.copyWith(filter: filter),
                        );
                      }
                  }
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(
                    value: 'direction',
                    checked: widget.options.descending,
                    child: const Text('降序排列'),
                  ),
                  CheckedPopupMenuItem(
                    value: 'folders',
                    checked: widget.options.foldersFirst,
                    child: const Text('文件夹优先'),
                  ),
                  const PopupMenuDivider(),
                  for (final filter in CloudDriveViewFilter.values)
                    CheckedPopupMenuItem(
                      value: filter.name,
                      checked: widget.options.filter == filter,
                      child: Text(filter.label),
                    ),
                  const PopupMenuDivider(),
                  if (_import != null &&
                      !_import!.running &&
                      (_import!.failed > 0 ||
                          _import!.cancelled ||
                          !_import!.persisted))
                    const PopupMenuItem(
                      value: 'retryImport',
                      child: Text('继续上次导入'),
                    ),
                  PopupMenuItem(
                    value: 'search',
                    child: Text(shortcutHintLabel(context, '搜索当前目录', 'S')),
                  ),
                  PopupMenuItem(
                    value: 'refresh',
                    child: Text(shortcutHintLabel(context, '刷新', 'R')),
                  ),
                  PopupMenuItem(
                    value: 'view',
                    child: Text(shortcutHintLabel(context, '切换卡片／列表', 'V')),
                  ),
                  PopupMenuItem(
                    value: 'style',
                    child: Text(shortcutHintLabel(context, '调整卡片样式', 'T')),
                  ),
                  PopupMenuItem(
                    value: 'select',
                    child: Text(
                      shortcutHintLabel(
                        context,
                        _selecting ? '退出多选' : '批量选择',
                        'B',
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'all',
                    child: Text(shortcutHintLabel(context, '全选', 'Ctrl+A')),
                  ),
                  PopupMenuItem(
                    value: 'settings',
                    child: Text(shortcutHintLabel(context, '网盘设置', 'P')),
                  ),
                ],
              ),
            ],
          ),
          if (loading || (_importBusy && !_pickingImportLocation))
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(minHeight: 1.5),
            ),
        ],
      ),
    );
  }

  Widget _contents() {
    final settings = context.watch<SettingsService>();
    final entries = _entries;
    if (entries.isEmpty) {
      final directory = _session;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                directory?.error == null
                    ? Icons.folder_open_outlined
                    : Icons.cloud_off_outlined,
                size: 40,
                color: AppTokens.text4,
              ),
              const SizedBox(height: 12),
              Text(
                directory?.error?.message ??
                    (directory?.loading == true
                        ? '正在读取目录'
                        : _query.text.isNotEmpty
                        ? '没有匹配的文件'
                        : '此目录暂无符合条件的文件'),
                textAlign: TextAlign.center,
              ),
              if (directory?.error != null)
                DesktopButtonClickRegion(child: TextButton(
                  onPressed: () => _ensureDirectory(),
                  child: const Text('重试'),
                )),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = MediaQuery.sizeOf(context);
        final list = settings.mediaLibraryViewMode == 1;
        final listStyle = settings.listStyleFor(screen);
        final grid = MediaLibraryLayoutDefaults.cardGrid(
          textScaler: MediaQuery.textScalerOf(context),
          textStyle: DefaultTextStyle.of(context).style,
          screenSize: Size(constraints.maxWidth, screen.height),
          style: settings.collectionCardStyleFor(screen),
        );
        final rows = MediaListLayoutMetrics.forGrid(
          screenShortestSide: screen.shortestSide,
          availableWidth: constraints.maxWidth,
          crossAxisCount: listStyle.crossAxisCount,
          heightSetting: listStyle.heightScale,
          titleSetting: listStyle.titleScale,
          mainSpacingSetting: listStyle.mainSpacingScale,
          crossSpacingSetting: listStyle.crossSpacingScale,
        );
        final columns = list ? listStyle.crossAxisCount : grid.crossAxisCount;
        final extent = list ? rows.rowHeight : grid.cellHeight;
        final cross = list ? rows.crossSpacing : grid.crossSpacing;
        final main = list ? rows.mainSpacing : grid.mainSpacing;
        final outer = list ? rows.outerPadding : grid.outerPadding;
        _geometry = MediaLibraryGridGeometry(
          crossAxisCount: columns,
          itemWidth: list ? rows.cellWidth : grid.cellWidth,
          itemHeight: extent,
          horizontalSpacing: cross,
          verticalSpacing: main,
          horizontalPadding: outer,
          topPadding: main,
        );
        return PlaybackGridView.builder(
          regionId: _directoryId,
          itemKey: (index) => cloudDriveEntryKey(entries[index]),
          key: _viewport,
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(outer, main, outer, main),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: extent,
            crossAxisSpacing: cross,
            mainAxisSpacing: main,
          ),
          itemCount: entries.length,
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = entries.indexWhere(
              (e) => '$_directoryId:${cloudDriveEntryKey(e)}' == key.value,
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (_, index) {
            final entry = entries[index];
            final identity = '$_directoryId:${cloudDriveEntryKey(entry)}';
            final location = _libraryLocation(entry);
            return CloudDriveEntryReveal(
              key: ValueKey(identity),
              index: index,
              columns: columns,
              revealed: _revealedEntries.contains(identity),
              onRevealed: () => _revealedEntries.add(identity),
              child: MediaCoverRevealStamp(
                index: index,
                crossAxisCount: columns,
                child: _CloudDriveRemoteCard(
                  key: ValueKey(
                    'cloud-drive-entry-${cloudDriveEntryKey(entry)}',
                  ),
                  runtime: widget.runtime,
                  entry: entries[index],
                  index: index,
                  list: list,
                  titleScale: list ? listStyle.titleScale : grid.titleScale,
                  showIndex: listStyle.showIndex,
                  showThumbnail: listStyle.showThumbnail,
                  selecting: _selecting && _selectable(entries[index]),
                  selected: _selected.contains(
                    cloudDriveEntryKey(entries[index]),
                  ),
                  onTap: () => _open(index),
                  onSelect: () => _toggle(index, enter: true),
                  onDragStart: (position) => _dragStart(index, position),
                  onDragUpdate: _dragUpdate,
                  onDragEnd: _endDrag,
                  onAddToLibrary: _importBusy
                      ? null
                      : () => _importEntries([entry]),
                  onChooseLibraryLocation: _importBusy
                      ? null
                      : () => _importEntries([entry], chooseLocation: true),
                  onViewInLibrary: location == null
                      ? null
                      : () => CloudDriveNavigation.viewFolder(location.folderId),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _CloudDriveRemoteCard extends StatefulWidget {
  const _CloudDriveRemoteCard({
    super.key,
    required this.runtime,
    required this.entry,
    required this.index,
    required this.list,
    required this.titleScale,
    required this.showIndex,
    required this.showThumbnail,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onSelect,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    this.onAddToLibrary,
    this.onChooseLibraryLocation,
    this.onViewInLibrary,
  });
  final CloudDriveRuntime runtime;
  final CloudDriveEntry entry;
  final int index;
  final bool list, showIndex, showThumbnail, selecting, selected;
  final double titleScale;
  final VoidCallback onTap, onSelect, onDragEnd;
  final ValueChanged<Offset> onDragStart, onDragUpdate;
  final Future<void> Function()? onAddToLibrary, onChooseLibraryLocation;
  final VoidCallback? onViewInLibrary;
  @override
  State<_CloudDriveRemoteCard> createState() => _CloudDriveRemoteCardState();
}

class _CloudDriveRemoteCardState extends State<_CloudDriveRemoteCard> {
  Future<String?>? _thumbnail;
  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _CloudDriveRemoteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.revision != widget.entry.revision ||
        oldWidget.entry.thumbnailRef != widget.entry.thumbnailRef) {
      _thumbnail = null;
      _loadThumbnail();
    }
  }

  void _loadThumbnail() {
    final source = cloudDriveEntrySource(widget.entry).cloudDrive!;
    final thumbnails = widget.runtime.thumbnails;
    if (thumbnails != null &&
        (widget.entry.kind == CloudDriveEntryKind.video ||
            widget.entry.kind == CloudDriveEntryKind.audio)) {
      thumbnails.rememberEntry(source, widget.entry);
      _thumbnail = thumbnails.ensure(source);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _thumbnail,
    builder: (_, snapshot) {
      final e = widget.entry;
      final source = cloudDriveEntrySource(e);
      final existing = widget.runtime.launch.library.cloudDriveCardForSource(
        source.cloudDrive!.sourceKey,
      );
      final folder = VideoCollection(
        id: source.cloudDrive!.itemId,
        name: e.name,
        createTime: 0,
      );
      final item = VideoItem(
        id: existing?.id ?? source.cloudDrive!.itemId,
        path: source.cloudDrive!.logicalUri,
        title: e.name,
        sourceRef: source,
        durationMs: e.durationMs ?? existing?.durationMs ?? 0,
        lastUpdated: 0,
        lastPositionMs: existing?.lastPositionMs ?? 0,
        thumbnailPath: snapshot.data ?? existing?.thumbnailPath,
        type: e.kind == CloudDriveEntryKind.audio
            ? MediaType.audio
            : MediaType.video,
      );
      final supported =
          e.kind == CloudDriveEntryKind.folder ||
          e.kind == CloudDriveEntryKind.video ||
          e.kind == CloudDriveEntryKind.audio;
      final moreActions = supported
          ? CloudEntryCacheMenu(
              entry: e,
              cloudRuntime: widget.runtime,
              onAddToLibrary: widget.onAddToLibrary,
              onChooseLibraryLocation: widget.onChooseLibraryLocation,
              onViewInLibrary: widget.onViewInLibrary,
            )
          : null;
      final metadata = e.kind == CloudDriveEntryKind.folder
          ? '网盘文件夹'
          : _metadata(e);
      final libraryMetadata = widget.onViewInLibrary == null
          ? metadata
          : '已加入媒体库 · $metadata';
      if (widget.list) {
        if (e.kind == CloudDriveEntryKind.folder) {
          return MediaLibraryListTile.collection(
            moreActions: moreActions,
            collection: folder,
            index: widget.index,
            showIndex: widget.showIndex,
            showThumbnail: widget.showThumbnail,
            isSelected: widget.selected,
            isSelectionMode: widget.selecting,
            titleScale: widget.titleScale,
            relativePath: libraryMetadata,
            onTap: widget.onTap,
            onLongPress: widget.onSelect,
            onSecondaryTap: widget.onSelect,
            onSelectionTap: widget.onSelect,
            onSelectionPanStart: (d) => widget.onDragStart(d.globalPosition),
            onSelectionPanUpdate: (d) => widget.onDragUpdate(d.globalPosition),
            onSelectionPanEnd: (_) => widget.onDragEnd(),
          );
        }
        return MediaLibraryListTile.video(
          moreActions: moreActions,
          item: item,
          index: widget.index,
          showIndex: widget.showIndex,
          showThumbnail: widget.showThumbnail,
          isSelected: widget.selected,
          isSelectionMode: widget.selecting,
          titleScale: widget.titleScale,
          relativePath: libraryMetadata,
          onTap: widget.onTap,
          onLongPress: widget.onSelect,
          onSecondaryTap: widget.onSelect,
          onSelectionTap: widget.onSelect,
          onSelectionPanStart: (d) => widget.onDragStart(d.globalPosition),
          onSelectionPanUpdate: (d) => widget.onDragUpdate(d.globalPosition),
          onSelectionPanEnd: (_) => widget.onDragEnd(),
        );
      }
      if (e.kind == CloudDriveEntryKind.folder) {
        return MediaLibraryFolderGridCard(
          moreActions: moreActions,
          collection: folder,
          metadataLabel: libraryMetadata,
          titleScale: widget.titleScale,
          onTap: widget.onTap,
          showActivityMenu: false,
          isSelected: widget.selected,
          isSelectionMode: widget.selecting,
          onLongPress: widget.onSelect,
          onSecondaryTap: widget.onSelect,
          onSelectionTap: widget.onSelect,
          onSelectionPanStart: (d) => widget.onDragStart(d.globalPosition),
          onSelectionPanUpdate: (d) => widget.onDragUpdate(d.globalPosition),
          onSelectionPanEnd: (_) => widget.onDragEnd(),
          onSelectionLongPressStart: (d) =>
              widget.onDragStart(d.globalPosition),
          onSelectionLongPressMoveUpdate: (d) =>
              widget.onDragUpdate(d.globalPosition),
          onSelectionLongPressEnd: (_) => widget.onDragEnd(),
        );
      }
      return MediaLibraryMediaGridCard(
        moreActions: moreActions,
        item: item,
        titleScale: widget.titleScale,
        onTap: widget.onTap,
        onLocate: () {},
        showLocate: false,
        showActivityMenu: false,
        relativePath: libraryMetadata,
        coverOverride: item.thumbnailPath == null
            ? ColoredBox(
                color: Colors.black26,
                child: Center(
                  child: Icon(switch (e.kind) {
                    CloudDriveEntryKind.subtitle => Icons.subtitles_outlined,
                    CloudDriveEntryKind.unsupported =>
                      Icons.insert_drive_file_outlined,
                    CloudDriveEntryKind.audio => Icons.music_note,
                    _ => Icons.movie_outlined,
                  }, color: AppTokens.text3),
                ),
              )
            : null,
        isSelected: widget.selected,
        isSelectionMode: widget.selecting,
        onLongPress: widget.onSelect,
        onSecondaryTap: widget.onSelect,
        onSelectionTap: widget.onSelect,
        onSelectionPanStart: (d) => widget.onDragStart(d.globalPosition),
        onSelectionPanUpdate: (d) => widget.onDragUpdate(d.globalPosition),
        onSelectionPanEnd: (_) => widget.onDragEnd(),
        onSelectionLongPressStart: (d) => widget.onDragStart(d.globalPosition),
        onSelectionLongPressMoveUpdate: (d) =>
            widget.onDragUpdate(d.globalPosition),
        onSelectionLongPressEnd: (_) => widget.onDragEnd(),
      );
    },
  );

  String _metadata(CloudDriveEntry entry) {
    if (entry.kind == CloudDriveEntryKind.subtitle) return '字幕文件';
    if (entry.kind == CloudDriveEntryKind.unsupported) return '暂不支持播放';
    final size = entry.size;
    if (size == null) {
      return entry.kind == CloudDriveEntryKind.audio ? '网盘音频' : '网盘视频';
    }
    if (size >= 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (size >= 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024).toStringAsFixed(1)} KB';
  }
}
