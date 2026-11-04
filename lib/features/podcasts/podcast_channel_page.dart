part of 'podcast_pages.dart';

class PodcastChannelPage extends StatefulWidget {
  const PodcastChannelPage({super.key, required this.channelId});
  final String channelId;
  @override
  State<PodcastChannelPage> createState() => _PodcastChannelPageState();
}

class _PodcastChannelPageState extends State<PodcastChannelPage> {
  String _filter = 'all', _query = '';
  String? _status;
  String? _queryKey;
  bool _expanded = false, _searching = false;
  final PodcastEpisodeSelection _selection = PodcastEpisodeSelection();
  List<String> _visibleIds = const [];
  Map<String, int> _visibleIndexes = const {};
  Set<String> _downloaded = const {};
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _searchDebounce = PodcastSearchDebounce();
  final _catalog = PodcastCatalogSnapshot();
  final _episodesScroll = PlaybackScrollController();
  final _identityScroll = PlaybackScrollController();
  final _entryWork = RouteTransitionWork();

  static const _filters = {
    'all': '全部',
    'unplayed': '未听',
    'inProgress': '进行中',
    'played': '已听',
    'favorite': '收藏',
    'downloaded': '已下载',
    'hidden': '已隐藏',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final runtime = PodcastRuntime.instance;
      if (mounted && runtime.ready) {
        // Preserve seen/badge semantics even when Back interrupts entry.
        runtime.controller.markSeen(widget.channelId);
      }
    });
    // Cached episodes and artwork are available immediately. Automatic feed
    // fetch/parse/merge and its notifications must not compete with entry.
    _entryWork.schedule('refresh', () {
      final runtime = PodcastRuntime.instance;
      if (mounted && runtime.ready) {
        unawaited(
          runtime.controller.refreshChannel(widget.channelId, manual: false),
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entryWork.bind(ModalRoute.of(context));
  }

  void _refreshChannel() {
    final runtime = PodcastRuntime.instance;
    if (!runtime.ready) return;
    // A user's refresh takes priority over the queued automatic one.
    _entryWork.cancel('refresh');
    unawaited(runtime.controller.refreshChannel(widget.channelId));
  }

  @override
  void dispose() {
    _entryWork.dispose();
    _searchDebounce.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _episodesScroll.dispose();
    _identityScroll.dispose();
    super.dispose();
  }

  void _beginSelection([String? episodeId]) {
    // Release search input so Escape belongs to selection, not text editing.
    FocusScope.of(context).unfocus();
    setState(() {
      if (episodeId == null) {
        _selection.active = true;
      } else {
        _selection.begin(episodeId);
      }
    });
  }

  void _endSelection() => setState(_selection.clear);
  void _showSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  bool get _selecting => _selection.active;

  void _batch(
    PodcastRuntime runtime,
    List<String> orderedIds, {
    required String action,
    Set<String> downloaded = const {},
  }) {
    final ids = _selection.ordered(orderedIds);
    var done = 0;
    var skipped = 0;
    for (final id in ids) {
      final episode = runtime.store.episode(id);
      final project = runtime.adapterFor(id) != null;
      switch (action) {
        case 'heard':
          runtime.controller.setPlayed(
            id,
            true,
            notify: false,
            project: project,
          );
          done++;
        case 'unheard':
          runtime.controller.setPlayed(
            id,
            false,
            notify: false,
            project: project,
          );
          done++;
        case 'download':
          if (episode == null || downloaded.contains(id)) {
            skipped++;
          } else {
            runtime.controller.enqueue(episode);
            done++;
          }
        case 'hide':
          runtime.store.setPresentation(id, hidden: true);
          done++;
        case 'unhide':
          runtime.store.setPresentation(id, hidden: false);
          done++;
        case 'favorite':
          runtime.controller.updateState(
            id,
            (state) => state.favorite = true,
            notify: false,
            project: project,
          );
          done++;
        case 'unfavorite':
          runtime.controller.updateState(
            id,
            (state) => state.favorite = false,
            notify: false,
            project: project,
          );
          done++;
      }
    }
    runtime.controller.publish();
    final sentence = switch (action) {
      'heard' => '已将 $done 集标为已听',
      'unheard' => '已将 $done 集标为未听',
      'download' => '已开始下载 $done 集',
      'hide' => '已隐藏 $done 集，可在「已隐藏」中恢复',
      'unhide' => '已恢复 $done 集',
      'favorite' => '已收藏 $done 集',
      'unfavorite' => '已取消收藏 $done 集',
      _ => '已处理 $done 项',
    };
    setState(() {
      _status = skipped == 0 ? sentence : '$sentence，$skipped 项不适用';
      _selection.clear();
    });
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_selecting,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _selecting) _endSelection();
    },
    child: PodcastPageShortcuts(
      bindings: {
        LogicalKeyboardKey.keyS: _showSearch,
        LogicalKeyboardKey.keyP: () => _openSettings(context, widget.channelId),
        LogicalKeyboardKey.keyB: _beginSelection,
        LogicalKeyboardKey.keyA: () => setState(() {
          if (_visibleIds.isNotEmpty &&
              _visibleIds.every(_selection.contains)) {
            _selection.deselectAll();
          } else {
            _selection.selectAll(_visibleIds);
          }
        }),
        LogicalKeyboardKey.space: _togglePodcastSession,
        LogicalKeyboardKey.keyR: _refreshChannel,
      },
      onSelectAll: () => setState(() => _selection.selectAll(_visibleIds)),
      onEscape: () {
        if (_selecting) {
          _endSelection();
          return true;
        }
        if (!_searching) return false;
        setState(() => _searching = false);
        return true;
      },
      child: Scaffold(
        backgroundColor: AppTokens.bgBase,
        body: PodcastGate(
          builder: (runtime) {
            final channel = runtime.store.channel(widget.channelId);
            if (channel == null) {
              return const PodcastEmpty(
                title: '频道尚未载入',
                message: '请检查订阅是否仍然存在，或重新导入频道。',
              );
            }
            final settings = runtime.store.effective(channel.id);
            final downloads = runtime.controller.downloads
                .where((t) => t.status == PodcastDownloadStatus.completed)
                .map((t) => t.episodeId)
                .toSet();
            final sort = settings.text('sort');
            _catalog.resolve(
              store: runtime.store,
              channelId: channel.id,
              filter: _filter,
              query: _query,
              sort: sort,
              hidePlayed: settings.flag('hidePlayed'),
              downloaded: downloads,
              countFilters: _filters.keys,
            );
            final counts = _catalog.counts;
            final queryKey =
                '$_filter|$_query|$sort|${settings.flag('hidePlayed')}|${settings.flag('groupSeasons')}';
            final ids = _catalog.ids;
            // Changing the query ends the selection. A plain refresh keeps ids
            // that are still in the list and does not select the new episodes.
            if (_queryKey != queryKey) {
              _selection.clear();
              _queryKey = queryKey;
            } else if (_selecting) {
              _selection.retain(ids);
            }
            if (!identical(_visibleIds, ids)) {
              _visibleIndexes = {
                for (var index = 0; index < ids.length; index++)
                  ids[index]: index,
              };
              _visibleIds = ids;
            }
            _downloaded = downloads;
            final episodes = _catalog.episodes;
            final continuing = _catalog.continuing;
            final start = continuing ?? episodes.firstOrNull;
            final refreshing = runtime.controller.refreshing.contains(
              channel.id,
            );
            return Stack(
              children: [
                PodcastBackdrop(
                  imageUrl: channel.imageUrl,
                  intensity: settings.number('tint'),
                  child: MediaLibrarySafeArea(
                    top: true,
                    child: LayoutBuilder(
                      builder: (context, bounds) {
                        final padding = bounds.maxWidth < 600 ? 8.0 : 24.0;
                        final split =
                            bounds.maxWidth >= 1100 &&
                            bounds.maxWidth / bounds.maxHeight >= 1.2;
                        final episodeWidth =
                            min(bounds.maxWidth, 1440.0) -
                            padding * 2 -
                            (split ? 240 : 0);
                        final wideRows = episodeWidth - 24 >= 680;
                        return Center(
                          child: SizedBox(
                            width: min(bounds.maxWidth, 1440.0),
                            child: Column(
                              children: [
                                SizedBox(
                                  height: 52,
                                  child: _navigation(
                                    runtime,
                                    channel,
                                    refreshing,
                                    bounds.maxWidth,
                                  ),
                                ),
                                Expanded(
                                  child: split
                                      ? Padding(
                                          padding: EdgeInsets.fromLTRB(
                                            padding,
                                            8,
                                            padding,
                                            0,
                                          ),
                                          child: Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              SizedBox(
                                                key: const ValueKey(
                                                  'podcast-channel-sidebar',
                                                ),
                                                width: 216,
                                                child: PodcastScrollbar(
                                                  controller: _identityScroll,
                                                  child: SingleChildScrollView(
                                                    controller: _identityScroll,
                                                    child: _identity(
                                                      runtime,
                                                      channel,
                                                      counts,
                                                      start,
                                                      episodes,
                                                      sidebar: true,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 24),
                                              Expanded(
                                                child: Column(
                                                  children: [
                                                    _toolbar(
                                                      runtime,
                                                      channel,
                                                      episodes,
                                                      counts,
                                                    ),
                                                    const SizedBox(height: 8),
                                                    Expanded(
                                                      child: _episodeScroll(
                                                        runtime,
                                                        channel,
                                                        episodes,
                                                        horizontalPadding: 0,
                                                        wideRows: wideRows,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        )
                                      : _episodeScroll(
                                          runtime,
                                          channel,
                                          episodes,
                                          horizontalPadding: padding,
                                          wideRows: wideRows,
                                          header: _identity(
                                            runtime,
                                            channel,
                                            counts,
                                            start,
                                            episodes,
                                          ),
                                          toolbar: _toolbar(
                                            runtime,
                                            channel,
                                            episodes,
                                            counts,
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: MediaLibrarySelectionBarTransition(
                    child: _selecting && _selection.ids.isNotEmpty
                        ? _selectionActions(runtime)
                        : null,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _selectionActions(PodcastRuntime runtime) =>
      MediaLibrarySelectionBottomBar.custom(
        onTranscribe: _selection.ids.isEmpty
            ? null
            : () {
                openTranscriptionQueue(
                  context,
                  TranscriptionMediaSelection(
                    podcastEpisodeIds: _selection.ordered(_visibleIds),
                  ),
                );
              },
        onAddToQueue: (progress) async {
          final result = await addPodcastEpisodesToQueue(
            context,
            _selection.ordered(_visibleIds),
            progress: progress,
          );
          if (mounted && result.completed) _endSelection();
          return result;
        },
        actions: [
          for (final action in [
            ('download', '下载', Icons.download_rounded),
            ('heard', '已听', Icons.done_all_rounded),
            ('unheard', '未听', Icons.unpublished_outlined),
            (
              _filter == 'hidden' ? 'unhide' : 'hide',
              _filter == 'hidden' ? '恢复' : '隐藏',
              _filter == 'hidden'
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
          ])
            MediaLibrarySelectionBarAction(
              label: action.$2,
              icon: action.$3,
              color: AppTokens.text1,
              onPressed: () => _batch(
                runtime,
                _visibleIds,
                action: action.$1,
                downloaded: _downloaded,
              ),
            ),
        ],
      );

  Widget _navigation(
    PodcastRuntime runtime,
    PodcastChannel channel,
    bool refreshing,
    double width,
  ) => _selecting
      ? Padding(
          padding: EdgeInsets.symmetric(
            horizontal: width < 600 ? 8 : 24,
            vertical: 2,
          ),
          child: Row(
            children: [
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: '退出多选',
                  onPressed: _endSelection,
                  icon: const Icon(Icons.close_rounded, size: 20),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已选 ${_selection.ids.length} 集',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip:
                      _visibleIds.isNotEmpty &&
                          _visibleIds.every(_selection.contains)
                      ? '取消全选'
                      : '全选当前列表',
                  onPressed: () => setState(() {
                    if (_visibleIds.isNotEmpty &&
                        _visibleIds.every(_selection.contains)) {
                      _selection.deselectAll();
                    } else {
                      _selection.selectAll(_visibleIds);
                    }
                  }),
                  icon: const Icon(Icons.select_all_rounded, size: 20),
                ),
              ),
            ],
          ),
        )
      : Padding(
          padding: EdgeInsets.symmetric(
            horizontal: width < 600 ? 8 : 24,
            vertical: 2,
          ),
          child: Row(
            children: [
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: '返回',
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded, size: 21),
                  style: IconButton.styleFrom(foregroundColor: AppTokens.text2),
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '播客频道',
                  style: TextStyle(color: AppTokens.text2, fontSize: 12),
                ),
              ),
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: refreshing ? '正在刷新频道' : '刷新频道',
                  onPressed: refreshing ? null : _refreshChannel,
                  icon: const Icon(Icons.refresh_rounded, size: 21),
                  style: IconButton.styleFrom(foregroundColor: AppTokens.text2),
                ),
              ),
              PodcastMenuButton(
                title: '频道操作',
                compact: true,
                subtitle: runtime.channelTitle(channel),
                tooltip: '更多频道操作',
                label: width >= 600 ? '更多' : null,
                actions: const [
                  PodcastMenuAction(
                    'transcribe',
                    transcriptionQueueLabel,
                    transcriptionQueueIcon,
                    section: '节目',
                  ),
                  PodcastMenuAction(
                    'rename',
                    '重命名',
                    Icons.edit_outlined,
                    description: '各页面同步显示应用内别名，保留 RSS 原始标题',
                    section: '频道',
                  ),
                  PodcastMenuAction(
                    'about',
                    '频道简介',
                    Icons.info_outline_rounded,
                    description: '查看完整介绍与频道名称',
                    section: '频道',
                  ),
                  PodcastMenuAction(
                    'links',
                    '频道链接',
                    Icons.link_rounded,
                    description: '查看、打开或复制频道主页与 RSS 订阅地址',
                    section: '频道',
                  ),
                  PodcastMenuAction(
                    'settings',
                    '频道独立设置',
                    Icons.tune_rounded,
                    description: '更新、播放与离线下载，按需单独设置',
                    section: '频道',
                  ),
                  PodcastMenuAction(
                    'select',
                    '批量管理节目',
                    Icons.checklist_rounded,
                    description: '选择多集下载，或统一标记收听状态',
                    section: '节目',
                  ),
                  PodcastMenuAction(
                    'unsub',
                    '取消订阅',
                    Icons.remove_circle_outline_rounded,
                    description: '频道移入回收站，保留已有下载',
                    destructive: true,
                  ),
                ],
                onSelected: (value) async {
                  if (value == 'transcribe') {
                    await openTranscriptionQueue(
                      context,
                      TranscriptionMediaSelection(
                        podcastChannelIds: [channel.id],
                      ),
                    );
                    return;
                  }
                  if (value == 'rename') {
                    await _renamePodcastChannel(context, runtime, channel);
                    return;
                  }
                  if (value == 'about') {
                    setState(() => _expanded = true);
                    _episodesScroll.animateTo(
                      0,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutCubic,
                    );
                    return;
                  }
                  if (value == 'links') {
                    await showPodcastLinks(
                      context,
                      title: '频道链接',
                      links: [
                        PodcastLink('频道主页', channel.link),
                        PodcastLink('RSS 订阅地址', channel.feedUrl),
                      ],
                    );
                    return;
                  }
                  if (value == 'settings') _openSettings(context, channel.id);
                  if (value == 'select') {
                    setState(() => _selection.active = true);
                  }
                  if (value == 'unsub') {
                    await runtime.unsubscribe(channel.id);
                    if (mounted) Navigator.maybePop(context);
                  }
                },
              ),
            ],
          ),
        );

  Widget _identity(
    PodcastRuntime runtime,
    PodcastChannel channel,
    Map<String, int> counts,
    PodcastEpisode? start,
    List<PodcastEpisode> episodes, {
    bool sidebar = false,
  }) {
    final title = runtime.channelTitle(channel);
    final continuing =
        start != null && runtime.controller.state(start.id).positionMs > 0;
    final description = podcastArticleText(channel.description);
    final small = MediaQuery.sizeOf(context).width < 600;
    final playLabel = continuing ? '继续收听' : '开始收听';
    void play() => openPodcastEpisode(context, start!, queue: episodes);
    return Padding(
      key: const ValueKey('podcast-channel-header'),
      padding: EdgeInsets.fromLTRB(
        small ? 0 : 12,
        sidebar ? 0 : 4,
        small ? 0 : 12,
        small ? 6 : 12,
      ),
      child: LayoutBuilder(
        builder: (context, bounds) {
          final wide = bounds.maxWidth >= 680;
          if (sidebar) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PodcastArtwork(url: channel.imageUrl, size: 112, radius: 16),
                const SizedBox(height: 16),
                _PodcastTitleHint(
                  title: title,
                  child: Text(
                    title,
                    maxLines: _expanded ? null : 3,
                    overflow: _expanded
                        ? TextOverflow.visible
                        : TextOverflow.ellipsis,
                    style: PodcastType.title.copyWith(
                      fontSize: 22,
                      height: 1.3,
                      letterSpacing: -.3,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  channel.author.isEmpty ? '独立播客' : channel.author,
                  style: PodcastType.meta.copyWith(
                    fontSize: 12,
                    height: 1.5,
                    color: AppTokens.text2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${counts['all']} 集节目 · ${counts['unplayed']} 集未听 · ${counts['inProgress']} 集进行中',
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: AppTokens.text3,
                  ),
                ),
                const SizedBox(height: 16),
                DesktopButtonClickRegion(
                  child: FilledButton.icon(
                    onPressed: start == null ? null : play,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD5DEEB),
                      foregroundColor: const Color(0xFF202833),
                      minimumSize: const Size(120, 44),
                      shape: const StadiumBorder(),
                      textStyle: Theme.of(context).textTheme.labelLarge
                          ?.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: Text(playLabel),
                  ),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  PodcastEpisodeSummary(
                    key: const ValueKey('podcast-channel-description'),
                    text: description,
                    expanded: _expanded,
                    onExpandedChanged: (value) =>
                        setState(() => _expanded = value),
                    semanticLabel: '频道简介',
                    style: const TextStyle(height: 1.6),
                  ),
                ],
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PodcastArtwork(
                    url: channel.imageUrl,
                    size: small ? 48 : 56,
                    radius: 12,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _PodcastTitleHint(
                          title: title,
                          child: Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: PodcastType.title.copyWith(
                              fontSize: wide ? 22 : (small ? 18 : 20),
                              height: 1.25,
                              letterSpacing: -.3,
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${channel.author.isEmpty ? '独立播客' : channel.author} · ${counts['all']} 集',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PodcastType.meta.copyWith(
                            fontSize: 12,
                            height: 1.4,
                            color: AppTokens.text2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (wide)
                    DesktopButtonClickRegion(
                      child: FilledButton.icon(
                        onPressed: start == null ? null : play,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFD5DEEB),
                          foregroundColor: const Color(0xFF202833),
                          minimumSize: const Size(120, 44),
                          shape: const StadiumBorder(),
                          textStyle: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: Text(playLabel),
                      ),
                    )
                  else
                    DesktopButtonClickRegion(
                      child: IconButton.filled(
                        tooltip: playLabel,
                        onPressed: start == null ? null : play,
                        style: IconButton.styleFrom(
                          backgroundColor: const Color(0xFFD5DEEB),
                          foregroundColor: const Color(0xFF202833),
                          fixedSize: const Size(40, 40),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 24),
                      ),
                    ),
                ],
              ),
              if (description.isNotEmpty) ...[
                SizedBox(height: small ? 4 : 10),
                PodcastEpisodeSummary(
                  key: const ValueKey('podcast-channel-description'),
                  text: description,
                  expanded: _expanded,
                  onExpandedChanged: (value) =>
                      setState(() => _expanded = value),
                  semanticLabel: '频道简介',
                  collapsedLines: small ? 1 : 3,
                  style: TextStyle(fontSize: small ? 12 : 13, height: 1.5),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _toolbar(
    PodcastRuntime runtime,
    PodcastChannel channel,
    List<PodcastEpisode> episodes,
    Map<String, int> counts,
  ) {
    final sort = runtime.store.effective(channel.id).text('sort');
    final largeText = MediaQuery.textScalerOf(context).scale(12) > 18;
    final small = MediaQuery.sizeOf(context).width < 600;
    final filters = PodcastFilterBar(
      compact: small,
      labels: _filters,
      counts: counts,
      selected: _filter,
      onSelected: (value) => setState(() => _filter = value),
    );
    final headingLabel = _query.isEmpty
        ? _filters[_filter]!
        : '${_filters[_filter]} · 搜索结果';
    final heading = Row(
      children: [
        Text(
          headingLabel,
          key: const ValueKey('podcast-channel-episodes-title'),
          style: PodcastType.title.copyWith(fontSize: 15, height: 1.4),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            '${episodes.length} 集',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: PodcastType.meta.copyWith(
              fontSize: 12,
              color: AppTokens.text3,
            ),
          ),
        ),
      ],
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DesktopButtonClickRegion(
          child: IconButton(
            tooltip: '搜索频道节目',
            onPressed: () => setState(() => _searching = !_searching),
            icon: Icon(
              Icons.search_rounded,
              size: 19,
              color: _searching || _query.isNotEmpty
                  ? AppTokens.text1
                  : AppTokens.text2,
            ),
            style: IconButton.styleFrom(
              minimumSize: const Size(40, 40),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
        PodcastMenuButton(
          title: '节目排序',
          dense: small,
          tooltip: '节目排序',
          icon: Icons.swap_vert_rounded,
          label: small && largeText
              ? null
              : sort == 'oldest'
              ? '最早优先'
              : '最新优先',
          actions: [
            PodcastMenuAction(
              'newest',
              '最新优先',
              Icons.south_rounded,
              selected: sort != 'oldest',
            ),
            PodcastMenuAction(
              'oldest',
              '最早优先',
              Icons.north_rounded,
              selected: sort == 'oldest',
            ),
          ],
          onSelected: (value) => runtime.setting(channel.id, 'sort', value),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        final inline = bounds.maxWidth >= 740 && !largeText;
        return SizedBox(
          key: const ValueKey('podcast-channel-toolbar'),
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (inline)
                Row(
                  children: [
                    const SizedBox(width: 12),
                    SizedBox(width: 136, child: heading),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: filters,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    controls,
                    const SizedBox(width: 12),
                  ],
                )
              else ...[
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: small ? 0 : 12),
                  child: Row(
                    children: [
                      Expanded(child: heading),
                      controls,
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                filters,
              ],
              if (_searching)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 8),
                  child: TextField(
                    controller: _search,
                    focusNode: _searchFocus,
                    onChanged: (value) =>
                        _searchDebounce.submit(value, (applied) {
                          if (mounted) setState(() => _query = applied);
                        }),
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '搜索节目标题或简介',
                      hintStyle: const TextStyle(
                        color: AppTokens.text3,
                        fontSize: 12,
                      ),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        size: 18,
                        color: AppTokens.text3,
                      ),
                      suffixIcon: _query.isEmpty
                          ? null
                          : DesktopButtonClickRegion(
                              child: IconButton(
                                tooltip: '清除频道搜索',
                                icon: const Icon(Icons.close_rounded, size: 16),
                                onPressed: () {
                                  _search.clear();
                                  _searchDebounce.submit('', (applied) {
                                    if (mounted) {
                                      setState(() => _query = applied);
                                    }
                                  });
                                },
                              ),
                            ),
                      filled: true,
                      fillColor: const Color(0x08FFFFFF),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 13,
                      ),
                      border: OutlineInputBorder(
                        borderSide: BorderSide.none,
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              if (channel.error.isNotEmpty || _status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _status ?? channel.error,
                    style: const TextStyle(
                      color: AppTokens.text2,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _episodeScroll(
    PodcastRuntime runtime,
    PodcastChannel channel,
    List<PodcastEpisode> episodes, {
    required double horizontalPadding,
    required bool wideRows,
    Widget? header,
    Widget? toolbar,
  }) {
    final settings = runtime.store.effective(channel.id);
    final refreshing = runtime.controller.refreshing.contains(channel.id);
    return PodcastScrollbar(
      key: const ValueKey('podcast-channel-episodes-scrollbar'),
      controller: _episodesScroll,
      child: CustomScrollView(
        key: PageStorageKey('podcast-channel-${channel.id}'),
        controller: _episodesScroll,
        physics: const SuperRangeMaintainingScrollPhysics(),
        slivers: [
          if (header != null)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverToBoxAdapter(child: header),
            ),
          if (toolbar != null)
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              sliver: SliverToBoxAdapter(child: toolbar),
            ),
          if (header != null || toolbar != null)
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
          if (episodes.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: PodcastEmpty(
                title: '没有符合条件的节目',
                message: '可以调整筛选条件，或稍后刷新频道。',
              ),
            )
          else
            // Skip directly to the destination during scrollbar drags. A
            // SliverList must build and measure every intervening variable-
            // height row, even though none of those rows will be visible.
            PlaybackSliverRegion(
              regionId: ('channel', channel.id),
              itemCount: episodes.length,
              itemKey: (index) => episodes[index].id,
              findIndex: (key) => _visibleIndexes[key],
              sliver: SuperSliverList.builder(
                itemCount: episodes.length,
                findChildIndexCallback: (key) =>
                    _visibleIndexes[(key as ValueKey<String>).value],
                itemBuilder: (context, index) {
                  final episode = episodes[index];
                  return Column(
                    key: ValueKey(episode.id),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (settings.flag('groupSeasons') &&
                          (index == 0 ||
                              episodes[index - 1].season != episode.season))
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            horizontalPadding + 12,
                            16,
                            horizontalPadding + 12,
                            6,
                          ),
                          child: Text(
                            episode.season == null
                                ? '其他节目'
                                : '第 ${episode.season} 季',
                            style: const TextStyle(
                              color: AppTokens.text3,
                              fontWeight: FontWeight.w500,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      PodcastEpisodeTile(
                        episode: episode,
                        preferences: settings,
                        channelStyle: true,
                        channelWide: wideRows,
                        horizontalPadding: horizontalPadding,
                        queue: episodes,
                        selecting: _selecting,
                        selected: _selection.contains(episode.id),
                        onLongPress: () => _beginSelection(episode.id),
                        onSelect: () =>
                            setState(() => _selection.toggle(episode.id)),
                        onRangeSelect: () => setState(() {
                          _selection.extendTo(
                            episodes
                                .map((item) => item.id)
                                .toList(growable: false),
                            episode.id,
                          );
                        }),
                        onError: (status) => setState(() => _status = status),
                      ),
                    ],
                  );
                },
              ),
            ),
          if (channel.nextPage != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: DesktopButtonClickRegion(
                  child: TextButton.icon(
                    onPressed: refreshing
                        ? null
                        : () => runtime.controller.refreshChannel(
                            channel.id,
                            history: true,
                          ),
                    icon: const Icon(Icons.expand_more_rounded, size: 18),
                    label: const Text('加载更早的节目'),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),
    );
  }
}
