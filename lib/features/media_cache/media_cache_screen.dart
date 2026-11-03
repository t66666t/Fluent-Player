import 'dart:async';
import '../../widgets/transcription_queue_actions.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_tokens.dart';
import '../../widgets/download_queue_controls.dart';
import '../../widgets/cached_thumbnail_widget.dart';
import '../../widgets/media_library_safe_area.dart';
import '../../widgets/media_library_page_shortcuts.dart';
import '../../utils/page_shortcut_keys.dart';
import '../../widgets/add_to_playlist_button.dart';
import '../../widgets/playback_queue_add_actions.dart';
import '../../services/storage_audit_models.dart';
import 'media_cache_models.dart';
import 'media_cache_service.dart';
import 'media_cache_widgets.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class MediaCacheScreen extends StatefulWidget {
  const MediaCacheScreen({
    super.key,
    required this.service,
    this.focusMediaKey,
    this.onPlay,
    this.onLocate,
  });
  final MediaCacheService service;
  final String? focusMediaKey;
  final Future<void> Function(CacheSource source, String? qualityId)? onPlay;
  final void Function(CacheSource source)? onLocate;
  @override
  State<MediaCacheScreen> createState() => _MediaCacheScreenState();
}

class _MediaCacheScreenState extends State<MediaCacheScreen> {
  bool _completed = false;
  String _provider = 'all', _query = '';
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'cache search');
  final _scroll = ScrollController();
  Future<void>? _loading;
  final _selectedTaskIds = <String>{};
  final _selectedVariantIds = <String>{};
  @override
  void initState() {
    super.initState();
    _loading = widget.service.initialize();
    _loading!.catchError((Object _) {});
    if (widget.focusMediaKey != null) {
      _query = '';
      _completed = widget.service.taskFor(widget.focusMediaKey!) == null;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _matches(CacheSource source) =>
      (_provider == 'all' || source.provider == _provider) &&
      (_query.isEmpty ||
          source.title.toLowerCase().contains(_query.toLowerCase()));
  Future<void> _run(Future<void> Function() operation) =>
      cacheUiAction(operation);

  List<CacheTask> get _visibleTasks => widget.service.tasks
      .where((task) => task.unfinished && _matches(task.source))
      .toList();

  List<CacheTask> get _actionTasks {
    final visible = _visibleTasks;
    final selected = visible
        .where((t) => _selectedTaskIds.contains(t.id))
        .toList();
    return selected.isEmpty ? visible : selected;
  }

  List<CacheVariant> get _visibleVariants =>
      widget.service.variants.where((v) => _matches(v.source)).toList();

  void _changeFilter(VoidCallback change) => setState(() {
    change();
    _selectedTaskIds.clear();
    _selectedVariantIds.clear();
  });

  void _selectAll() {
    final ids = _completed
        ? _visibleVariants.map((v) => v.id).toSet()
        : _visibleTasks.map((t) => t.id).toSet();
    final selected = _completed ? _selectedVariantIds : _selectedTaskIds;
    setState(() {
      if (ids.isNotEmpty && ids.every(selected.contains)) {
        selected.removeAll(ids);
      } else {
        selected.addAll(ids);
      }
    });
  }

  bool get _hasActiveTasks => _actionTasks.any((task) => task.state.canPause);

  void _retryInitialization() {
    setState(() {
      _loading = widget.service.retryInitialization();
      _loading!.catchError((Object _) {});
    });
  }

  void _pauseVisibleTasks() {
    final tasks = _actionTasks.where((t) => t.state.canPause).toList();
    unawaited(
      _run(() async {
        for (final task in tasks) {
          await widget.service.pause(task.id);
        }
      }),
    );
  }

  void _resumeVisibleTasks() {
    final tasks = _actionTasks.where((t) => t.state.canResume).toList();
    unawaited(
      _run(() async {
        for (final task in tasks) {
          await widget.service.resume(task.id);
        }
      }),
    );
  }

  void _retryVisibleTasks() {
    if (_completed ||
        !widget.service.ready ||
        widget.service.loadError != null) {
      return;
    }
    final tasks = _actionTasks.where((t) => t.state.canRetry).toList();
    unawaited(
      _run(() async {
        for (final task in tasks) {
          await widget.service.resume(task.id);
        }
      }),
    );
  }

  void _toggleVisibleTasks() {
    if (_completed ||
        !widget.service.ready ||
        widget.service.loadError != null) {
      return;
    }
    if (_hasActiveTasks) {
      _pauseVisibleTasks();
    } else {
      _resumeVisibleTasks();
    }
  }

  @override
  Widget build(BuildContext context) => MediaLibraryPageShortcuts(
    onSelectAll: _selectAll,
    bindings: {
      LogicalKeyboardKey.keyS: () {
        if (widget.service.ready && widget.service.loadError == null) {
          _searchFocus.requestFocus();
        }
      },
      LogicalKeyboardKey.keyP: () =>
          unawaited(_run(() => showMediaCacheSettings(context))),
      LogicalKeyboardKey.space: _toggleVisibleTasks,
      LogicalKeyboardKey.keyT: _retryVisibleTasks,
      LogicalKeyboardKey.keyR: () {
        if (widget.service.loadError != null) _retryInitialization();
      },
    },
    child: Scaffold(
      backgroundColor: AppTokens.bgBase,
      appBar: AppBar(
        backgroundColor: AppTokens.bgBase,
        title: const Text('缓存管理'),
        actions: [
          DesktopButtonClickRegion(
            child: IconButton(
              tooltip: hoverAwareShortcutTooltip(
                '缓存设置',
                LogicalKeyboardKey.keyP,
                context: context,
              ),
              icon: const Icon(Icons.tune_rounded),
              onPressed: () =>
                  unawaited(_run(() => showMediaCacheSettings(context))),
            ),
          ),
        ],
      ),
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 600
          ? ListenableBuilder(
              listenable: widget.service,
              builder: (_, _) =>
                  widget.service.ready && widget.service.loadError == null
                  ? MediaLibrarySafeArea(child: _toolbar())
                  : const SizedBox.shrink(),
            )
          : null,
      body: _bodySafeArea(
        child: FutureBuilder<void>(
          future: _loading,
          builder: (context, snapshot) => ListenableBuilder(
            listenable: widget.service,
            builder: (context, _) {
              final service = widget.service;
              if (service.loadError != null || snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.folder_off_outlined,
                          size: 36,
                          color: AppTokens.text2,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          service.loadError ?? '缓存记录暂时无法读取',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Tooltip(
                          message: hoverAwareShortcutTooltip(
                            '重新读取',
                            LogicalKeyboardKey.keyR,
                            context: context,
                          ),
                          child: DesktopButtonClickRegion(
                            child: TextButton(
                              onPressed: _retryInitialization,
                              child: const Text('重新读取'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (!service.ready) {
                return const Center(child: CircularProgressIndicator());
              }
              final tasks = service.tasks
                  .where((t) => t.unfinished && _matches(t.source))
                  .toList();
              final groups = <String, List<CacheVariant>>{};
              for (final v in service.variants.where(
                (v) => _matches(v.source),
              )) {
                groups.putIfAbsent(v.source.key, () => []).add(v);
              }
              tasks.sort((a, b) {
                if (a.source.key == widget.focusMediaKey &&
                    b.source.key != widget.focusMediaKey) {
                  return -1;
                }
                if (b.source.key == widget.focusMediaKey &&
                    a.source.key != widget.focusMediaKey) {
                  return 1;
                }
                return a.createdAt.compareTo(b.createdAt);
              });
              final cached = groups.values.toList()
                ..sort((a, b) {
                  if (a.first.source.key == widget.focusMediaKey) return -1;
                  if (b.first.source.key == widget.focusMediaKey) return 1;
                  return b.first.createdAt.compareTo(a.first.createdAt);
                });
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: RefreshIndicator(
                    onRefresh: service.reconcile,
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 16,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      '${service.runningCount} 项进行中',
                                      style: const TextStyle(
                                        color: AppTokens.text2,
                                      ),
                                    ),
                                    if (service.bytesPerSecond > 0)
                                      Text(
                                        cacheSpeed(service.bytesPerSecond),
                                        style: const TextStyle(
                                          color: cacheQuietBlue,
                                        ),
                                      ),
                                    Text(
                                      '已缓存 ${formatStorageSize(service.cachedBytes)}',
                                      style: const TextStyle(
                                        color: AppTokens.text3,
                                      ),
                                    ),
                                  ],
                                ),
                                if (service.persistenceError != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      '任务记录保存失败：${service.persistenceError}',
                                      style: const TextStyle(
                                        color: AppTokens.text2,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 14),
                                TextField(
                                  controller: _search,
                                  focusNode: _searchFocus,
                                  onChanged: (v) =>
                                      _changeFilter(() => _query = v.trim()),
                                  decoration: InputDecoration(
                                    hintText: hoverAwareShortcutTooltip(
                                      '搜索缓存媒体',
                                      LogicalKeyboardKey.keyS,
                                      context: context,
                                    ),
                                    prefixIcon: const Icon(
                                      Icons.search,
                                      size: 20,
                                    ),
                                    isDense: true,
                                    filled: true,
                                    fillColor: AppTokens.bgRaised,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    ChoiceChip(
                                      label: Text(
                                        '任务 ${service.tasks.where((t) => t.unfinished).length}',
                                      ),
                                      selected: !_completed,
                                      onSelected: (_) => _changeFilter(
                                        () => _completed = false,
                                      ),
                                    ),
                                    ChoiceChip(
                                      label: Text(
                                        '已缓存 ${service.variants.length}',
                                      ),
                                      selected: _completed,
                                      onSelected: (_) => _changeFilter(
                                        () => _completed = true,
                                      ),
                                    ),
                                    DesktopButtonClickRegion(
                                      child: DropdownButton<String>(
                                        value: _provider,
                                        underline: const SizedBox.shrink(),
                                        items: [
                                          for (final e in const {
                                            'all': '全部来源',
                                            'bilibili': '哔哩哔哩',
                                            'baidu': '百度网盘',
                                            'quark': '夸克网盘',
                                            'uc': 'UC网盘',
                                            'aliyun': '阿里云盘',
                                            'podcast': '播客',
                                          }.entries)
                                            DropdownMenuItem(
                                              value: e.key,
                                              child: Text(
                                                e.value,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                        ],
                                        onChanged: (v) {
                                          if (v != null) {
                                            _changeFilter(() => _provider = v);
                                          }
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (MediaQuery.sizeOf(context).width >= 600)
                          SliverToBoxAdapter(child: _toolbar()),
                        const SliverToBoxAdapter(child: Divider(height: 1)),
                        if (_completed ? cached.isEmpty : tasks.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  _query.isNotEmpty || _provider != 'all'
                                      ? '没有匹配的媒体'
                                      : _completed
                                      ? '缓存完成后会保留在这里'
                                      : '暂无任务，可在媒体菜单或画质列表中开始缓存',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: AppTokens.text3,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                            sliver: SliverList.builder(
                              itemCount: _completed
                                  ? cached.length
                                  : tasks.length,
                              itemBuilder: (context, index) => _completed
                                  ? _cachedGroup(cached[index])
                                  : _task(tasks[index]),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  Widget _bodySafeArea({required Widget child}) =>
      MediaQuery.sizeOf(context).width < 600
      ? SafeArea(top: false, bottom: false, child: child)
      : MediaLibrarySafeArea(child: child);

  Widget _toolbar() {
    final visible = _completed
        ? _visibleVariants.map((v) => v.id).toSet()
        : _visibleTasks.map((t) => t.id).toSet();
    final selected = (_completed ? _selectedVariantIds : _selectedTaskIds)
        .intersection(visible);
    final tasks = _actionTasks;
    final scope = selected.isEmpty ? '当前列表' : '所选';
    final shortScope =
        MediaQuery.sizeOf(context).width < 600 && selected.isEmpty
        ? '列表'
        : scope;
    final resumeCount = tasks.where((t) => t.state.canResume).length;
    final pauseCount = tasks.where((t) => t.state.canPause).length;
    final retryCount = tasks.where((t) => t.state.canRetry).length;
    return DownloadQueueToolbar(
      key: const ValueKey('cache-queue-toolbar'),
      selectionLabel: selected.isEmpty ? '全选当前列表' : '已选 ${selected.length} 项',
      onSelectAll: visible.isEmpty ? null : _selectAll,
      allSelected: visible.isNotEmpty && visible.every(selected.contains),
      primary: _completed
          ? null
          : DownloadQueueAction(
              label: '继续$shortScope $resumeCount 项',
              icon: Icons.play_arrow_rounded,
              onPressed: resumeCount > 0 ? _resumeVisibleTasks : null,
            ),
      secondary: _completed
          ? null
          : DownloadQueueAction(
              label: '暂停$shortScope $pauseCount 项',
              icon: Icons.pause_rounded,
              onPressed: pauseCount > 0 ? _pauseVisibleTasks : null,
            ),
      more: _completed
          ? [
              DownloadQueueAction(
                label: '删除所选缓存 ${selected.length} 份',
                icon: Icons.delete_outline_rounded,
                destructive: true,
                onPressed: selected.isEmpty
                    ? null
                    : () => unawaited(_deleteVariants(selected)),
              ),
            ]
          : [
              DownloadQueueAction(
                label: '重试$scope失败任务 $retryCount 项',
                icon: Icons.refresh_rounded,
                onPressed: retryCount > 0 ? _retryVisibleTasks : null,
              ),
              DownloadQueueAction(
                label: '取消$scope任务 ${tasks.length} 项',
                icon: Icons.close_rounded,
                destructive: true,
                onPressed: tasks.isEmpty
                    ? null
                    : () => unawaited(_cancelTasks(tasks)),
              ),
            ],
    );
  }

  Future<void> _deleteVariants(Set<String> ids) async {
    final deleting = ids.toList();
    if (!await _confirm('删除所选 ${deleting.length} 份画质缓存？在线来源、字幕和观看记录会保留。')) {
      return;
    }
    await _run(() async {
      for (final id in deleting) {
        await widget.service.deleteVariant(id);
      }
    });
    if (mounted) setState(() => _selectedVariantIds.removeAll(deleting));
  }

  Widget _cover(CacheSource source) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      width: 72,
      height: 48,
      child: ColoredBox(
        color: AppTokens.bgCard,
        child: CachedThumbnailWidget(
          videoId: source.itemId,
          thumbnailPath: source.thumbnail,
          placeholder: Icon(
            source.kind.name == 'audio'
                ? Icons.audiotrack_outlined
                : Icons.movie_outlined,
            size: 22,
            color: AppTokens.text3,
          ),
        ),
      ),
    ),
  );

  Widget _task(CacheTask task) => Container(
    key: ValueKey('cache-task-${task.id}'),
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: AppTokens.bgRaised,
      borderRadius: BorderRadius.circular(14),
      border: task.source.key == widget.focusMediaKey
          ? Border.all(color: cacheQuietBlue.withValues(alpha: .4))
          : null,
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.source.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '${task.source.providerLabel} · ${task.quality?.label ?? (task.source.isBilibili ? '最高可用画质' : '原画（最高）')}',
              style: const TextStyle(color: AppTokens.text3, fontSize: 12),
            ),
          ],
        );
        final actions = DownloadTaskActions(
          primary: DownloadQueueAction(
            label: task.state.primaryActionLabel,
            icon: task.state.canPause
                ? Icons.pause_rounded
                : task.state.canRetry
                ? Icons.refresh_rounded
                : Icons.play_arrow_rounded,
            onPressed: () => unawaited(
              _run(
                () => task.state.canPause
                    ? widget.service.pause(task.id)
                    : widget.service.resume(task.id),
              ),
            ),
          ),
          more: DesktopButtonClickRegion(
            child: PopupMenuButton<String>(
              tooltip: '任务操作',
              onSelected: (_) => unawaited(_cancelTasks([task])),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'cancel',
                  child: Text('取消任务并删除未完成数据'),
                ),
              ],
            ),
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Checkbox(
                  key: ValueKey('cache-task-select-${task.id}'),
                  value: _selectedTaskIds.contains(task.id),
                  onChanged: (value) => setState(() {
                    if (value == true) {
                      _selectedTaskIds.add(task.id);
                    } else {
                      _selectedTaskIds.remove(task.id);
                    }
                  }),
                ),
                _cover(task.source),
                const SizedBox(width: 12),
                Expanded(child: info),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 4,
                value: task.progress ?? (task.state.running ? null : 0),
                color: AppTokens.accent,
                backgroundColor: AppTokens.lineSubtle,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  task.state.label,
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
                Text(
                  '${formatStorageSize(task.received)}${task.total == null ? '' : ' / ${formatStorageSize(task.total!)}'}',
                  style: const TextStyle(color: AppTokens.text3, fontSize: 12),
                ),
                if (task.progress != null)
                  Text(
                    '${(task.progress! * 100).floor()}%',
                    style: const TextStyle(
                      color: AppTokens.text3,
                      fontSize: 12,
                    ),
                  ),
                if (task.state == CacheTaskState.downloading &&
                    task.bytesPerSecond > 0) ...[
                  Text(
                    cacheSpeed(task.bytesPerSecond),
                    style: const TextStyle(color: cacheQuietBlue, fontSize: 12),
                  ),
                  if (task.remaining != null)
                    Text(
                      '约剩 ${cacheDuration(task.remaining!)}',
                      style: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 12,
                      ),
                    ),
                ],
              ],
            ),
            if (task.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  task.error!,
                  style: const TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        );
      },
    ),
  );

  Widget _cachedGroup(List<CacheVariant> variants) {
    final source = variants.first.source;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTokens.bgRaised,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ExpansionTile(
        key: PageStorageKey('cache-media-${source.key}'),
        initiallyExpanded:
            source.key == widget.focusMediaKey || variants.length == 1,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: _cover(source),
        title: Text(source.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${source.providerLabel} · ${variants.length} 份缓存 · '
          '${formatStorageSize(variants.fold<int>(0, (s, v) => s + v.bytes))}',
          style: const TextStyle(color: AppTokens.text3, fontSize: 12),
        ),
        children: [
          for (final v in variants)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Checkbox(
                    key: ValueKey('cache-variant-select-${v.id}'),
                    value: _selectedVariantIds.contains(v.id),
                    onChanged: (value) => setState(() {
                      if (value == true) {
                        _selectedVariantIds.add(v.id);
                      } else {
                        _selectedVariantIds.remove(v.id);
                      }
                    }),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(v.quality.label),
                        Text(
                          !v.available
                              ? '存储位置不可用'
                              : v.pendingDelete
                              ? '使用结束后删除'
                              : '${v.contentLabel} · ${formatStorageSize(v.bytes)}',
                          style: const TextStyle(
                            color: AppTokens.text3,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  DownloadTaskActions(
                    primary: DownloadQueueAction(
                      label: '播放',
                      icon: Icons.play_arrow_rounded,
                      onPressed:
                          !v.available ||
                              v.pendingDelete ||
                              !v.completeMedia ||
                              widget.onPlay == null
                          ? null
                          : () => unawaited(
                              _run(() => widget.onPlay!(source, v.quality.id)),
                            ),
                    ),
                    more: DesktopButtonClickRegion(
                      child: PopupMenuButton<String>(
                        tooltip: '缓存操作',
                        onSelected: (_) => unawaited(_deleteVariants({v.id})),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'delete',
                            enabled: !v.pendingDelete,
                            child: const Text('删除此画质缓存'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 4,
              children: [
                if (widget.onLocate != null)
                  DesktopButtonClickRegion(
                    child: TextButton.icon(
                      onPressed: () => widget.onLocate!(source),
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                      label: const Text('定位来源'),
                    ),
                  ),
                DesktopButtonClickRegion(
                  child: TextButton(
                    onPressed: () => unawaited(_deleteMedia(source)),
                    child: const Text('删除所有缓存'),
                  ),
                ),
                AddToPlaylistOverflowButton(
                  onTranscribe: () => openTranscriptionQueue(
                    context,
                    TranscriptionMediaSelection(items: [source.toItem()]),
                  ),
                  onAdd: () async {
                    await addCachedSourceToQueue(context, source);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Future<void> _cancelTasks(List<CacheTask> tasks) async {
    if (await _confirm('取消这 ${tasks.length} 个任务并删除未完成的数据？')) {
      await _run(() async {
        for (final t in tasks) {
          await widget.service.cancel(t.id);
        }
      });
      if (mounted) {
        setState(() => _selectedTaskIds.removeAll(tasks.map((t) => t.id)));
      }
    }
  }

  Future<void> _deleteMedia(CacheSource source) async {
    if (await _confirm('删除“${source.title}”的所有本地缓存？在线来源和观看记录会保留。')) {
      await _run(() => widget.service.deleteAll(source.key));
    }
  }

  Future<bool> _confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(text),
          actions: [
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('保留'),
              ),
            ),
            DesktopButtonClickRegion(
              child: TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('确认'),
              ),
            ),
          ],
        ),
      ) ??
      false;
}
