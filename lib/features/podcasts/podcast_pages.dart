import '../../widgets/media_library_tooltip.dart';
import '../../widgets/quiet_empty_state_visuals.dart';
import '../../widgets/media_library_card_scale.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show ImageFilter;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../../widgets/keyboard_inset_padding.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/platform/app_video_player_controller.dart';
import '../../models/video_item.dart';
import '../../screens/video_player_screen.dart';
import '../../screens/music_player_screen.dart';
import '../../services/media_playback_service.dart';
import '../../services/playlist_manager.dart';
import '../../services/settings_service.dart';
import '../../services/app_haptics.dart';
import '../../models/import_card_placement.dart';
import '../../widgets/media_library_grid_card.dart';
import '../../widgets/media_library_keyboard_navigation.dart';
import '../../widgets/media_library_item_interaction_wrapper.dart';
import '../../widgets/media_library_gestures.dart';
import '../../widgets/folder_placeholder_cover.dart';
import '../../utils/media_library_range_selection.dart';
import '../../widgets/media_library_action_dock.dart';
import '../../widgets/media_library_layout_profile.dart';
import '../../widgets/media_library_scroll_viewport.dart';
import '../../widgets/media_library_selection_bottom_bar.dart';
import '../../widgets/media_list_layout_metrics.dart';
import '../../services/playback_navigation_service.dart';
import '../../theme/app_tokens.dart';
import '../../theme/app_page_transitions.dart';
import '../../utils/route_transition_work.dart';
import '../../utils/app_toast.dart';
import '../../widgets/library_folder_picker.dart';
import '../../widgets/library_rename_dialog.dart';
import '../../widgets/library_create_collection_dialog.dart';
import '../../widgets/media_library_selection_drop_targets.dart';
import '../../widgets/media_library_compact_app_bar.dart';
import '../../widgets/playback_queue_add_actions.dart';
import '../../widgets/transcription_queue_actions.dart';
import '../../features/portable_transfer/portable_transfer_navigation.dart';
import '../../widgets/media_library_shell.dart';
import '../../widgets/playback_source_viewport.dart';
import '../../widgets/playback_queue_remove_button.dart';
import '../../widgets/playback_queue_sort_controls.dart';
import '../../widgets/media_library_safe_area.dart';
import '../../models/transcription_status.dart';
import '../../services/transcription_manager.dart';
import '../../widgets/music_subtitle_management_dialog.dart';
import 'podcast_article.dart';
import 'podcast_client.dart';
import 'podcast_preview_loader.dart';
import 'podcast_episode_press.dart';
import 'podcast_episode_selection.dart';
import 'podcast_episode_summary.dart';
import 'podcast_feed_parser.dart';
import 'podcast_models.dart';
import 'podcast_playback_hooks.dart';
import 'podcast_playback_policy.dart';
import 'podcast_runtime.dart';
import 'podcast_transfer.dart';
import 'podcast_store.dart';
import 'podcast_subscription_layout.dart';
import 'podcast_settings_page.dart';
import 'podcast_widgets.dart';
import 'podcast_menu.dart';
import 'podcast_links.dart';
import 'podcast_typography.dart';
import 'podcast_page_shortcuts.dart';
import 'podcast_scrollbar.dart';
import 'podcast_settings.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

part 'podcast_channel_page.dart';
part 'podcast_discover_search.dart';
part 'podcast_library_search.dart';
part 'podcast_subscription_library.dart';
part 'podcast_player_page.dart';

T? _maybeProvider<T extends Object>(BuildContext context) {
  try {
    return Provider.of<T>(context);
  } catch (_) {
    return null;
  }
}

void installPodcastNavigation() {
  PodcastPlaybackHooks.musicRoute = (item) => buildMusicPlayerRoute<void>(
    builder: (_) => PodcastPlayerPage(
      episodeId: item.sourceRef!.podcast!.episodeId,
      presentation: PodcastPlayerPresentation.music,
      restoreSystemUiOnExit: false,
    ),
  );
  PodcastPlaybackHooks.route = (item) =>
      PlaybackNavigationService.buildPlaybackPageRoute<void>(
        settings: RouteSettings(name: '/playback/podcast', arguments: item.id),
        delayPushOneFrame: item.type == MediaType.audio,
        builder: (_) =>
            PodcastPlayerPage(episodeId: item.sourceRef!.podcast!.episodeId),
      );
  final runtime = PodcastRuntime.instance;
  void openPending() {
    final id = runtime.pendingChannel.value,
        navigator = AppToast.navigatorKey.currentState;
    if (id == null || navigator == null) return;
    runtime.pendingChannel.value = null;
    navigator.push(
      AppMaterialPageRoute<void>(
        builder: (_) => PodcastChannelPage(channelId: id),
      ),
    );
  }

  runtime.pendingChannel.addListener(openPending);
  WidgetsBinding.instance.addPostFrameCallback((_) => openPending());
}

Future<void> openPodcastEpisode(
  BuildContext context,
  PodcastEpisode episode, {
  List<PodcastEpisode>? queue,
}) async {
  final runtime = PodcastRuntime.instance;
  // Cover the old card before publishing a different episode. The outgoing
  // library must keep its presentation throughout the playback-page zoom.
  final closed = pushAboveMediaLibrary(
    context,
    PlaybackNavigationService.buildPlaybackPageRoute<void>(
      delayPushOneFrame: !episode.media.any((media) => media.isVideo),
      settings: RouteSettings(
        name: '/playback/podcast',
        arguments: runtime.adapterFor(episode.id)?.id ?? episode.id,
      ),
      builder: (_) => PodcastPlayerPage(episodeId: episode.id),
    ),
  );
  if (runtime.playback?.currentItem?.sourceRef?.podcast?.episodeId !=
          episode.id ||
      runtime.playback?.controller == null) {
    unawaited(runtime.play(episode, queue: queue).catchError((Object _) {}));
  }
  await closed;
}

void _openSettings(BuildContext context, [String? id]) => pushAboveMediaLibrary(
  context,
  AppMaterialPageRoute<void>(
    builder: (_) => PodcastSettingsPage(channelId: id),
  ),
);

Future<void> _renamePodcastEpisode(
  BuildContext context,
  PodcastRuntime runtime,
  PodcastEpisode episode,
) => showLibraryRenameDialog(
  context: context,
  itemId: episode.id,
  currentName: runtime.episodeTitle(episode),
  onRename: (name) => runtime.renameEpisode(episode.id, name),
  scopeDescription: '修改应用内的单集别名，媒体库、播客列表和播放器同步显示；RSS 原始标题不变。',
);

Future<void> _renamePodcastChannel(
  BuildContext context,
  PodcastRuntime runtime,
  PodcastChannel channel,
) async {
  final card = runtime.collectionFor(channel.id);
  if (card == null) return;
  await showLibraryRenameDialog(
    context: context,
    itemId: card.id,
    currentName: runtime.channelTitle(channel),
  );
}

void _togglePodcastSession() {
  final playback = PodcastRuntime.instance.playback;
  if (playback == null ||
      playback.currentItem == null ||
      (playback.state != PlaybackState.playing &&
          playback.state != PlaybackState.paused)) {
    return;
  }
  if (playback.desiredPlaying) {
    unawaited(playback.pause());
  } else {
    unawaited(playback.resume());
  }
}

/// Connects the root library's existing controls to the visible podcast folder.
class PodcastOverviewController extends ChangeNotifier {
  _PodcastOverviewPageState? _page;
  String _published = '';
  bool _publishScheduled = false;

  _PodcastSubscriptionLibraryState? get _library =>
      _page?._tab == 0 ? _page?._subscriptionLibraryKey.currentState : null;
  bool get isSelecting => _library?._selection.active ?? false;
  Set<String> get selectedIds =>
      Set.unmodifiable(_library?._selection.ids ?? <String>{});

  List<String> get visibleKeyboardIds =>
      List.unmodifiable(_library?._visibleIds ?? const <String>[]);

  void setKeyboardSelection(Set<String> ids) {
    final library = _library;
    if (library == null || !library.mounted) return;
    library.setKeyboardSelection(ids);
  }

  void _publishSelection() {
    if (_publishScheduled) return;
    _publishScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _publishScheduled = false;
      if (_page == null) return;
      final ids = selectedIds.toList()..sort();
      final signature = '$isSelecting|${_library?._folderId}|${ids.join(',')}';
      if (signature == _published) return;
      _published = signature;
      notifyListeners();
    });
  }

  Future<void> createCollection() async {
    final page = _page;
    if (page == null || !page.mounted) return;
    if (page._tab != 0) {
      page._selectTab(0);
      await WidgetsBinding.instance.endOfFrame;
    }
    await _library?._createFolder();
  }

  void enterSelection() => _library?.beginSelection();
  void exitSelection() {
    if (isSelecting) _library?.handleBack();
  }

  void toggleSelectAll() => _library?.selectAll(toggle: true);
  Widget buildSelectionDropTargets() =>
      _library?._selectionDropTargets() ?? const SizedBox.shrink();
  Widget? buildSelectionBottomBar() {
    final library = _library;
    return library != null && isSelecting && selectedIds.isNotEmpty
        ? library._selectionActions(library._layout)
        : null;
  }

  @override
  void dispose() {
    _page = null;
    super.dispose();
  }
}

class PodcastOverviewPage extends StatefulWidget {
  const PodcastOverviewPage({
    super.key,
    this.embedded = true,
    this.bottomPadding = 100,
    this.isActive = true,
    this.controller,
  });
  final bool embedded;
  final double bottomPadding;
  final bool isActive;
  final PodcastOverviewController? controller;
  @override
  State<PodcastOverviewPage> createState() => _PodcastOverviewPageState();
}

class _PodcastOverviewPageState extends State<PodcastOverviewPage> {
  late PodcastOverviewController _overviewController;
  final _subscriptionLibraryKey = GlobalKey<_PodcastSubscriptionLibraryState>();
  String? _subscriptionFolderId;
  List<PodcastEpisode>? _dragEpisodes;
  final ScrollController _tabsScroll = ScrollController();
  final Object _headerFocusGroup = Object();
  final _listScrolls = <int, PlaybackScrollController>{};

  PlaybackScrollController _scrollForTab(int tab) =>
      _listScrolls.putIfAbsent(tab, PlaybackScrollController.new);

  @override
  void initState() {
    super.initState();
    _bindController();
  }

  void _bindController() {
    _overviewController = widget.controller ?? PodcastOverviewController();
    _overviewController._page = this;
    _overviewController.addListener(_selectionChanged);
  }

  void _selectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(PodcastOverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _overviewController.removeListener(_selectionChanged);
    _overviewController._page = null;
    if (oldWidget.controller == null) _overviewController.dispose();
    _bindController();
  }

  @override
  void dispose() {
    _overviewController.removeListener(_selectionChanged);
    _overviewController._page = null;
    if (widget.controller == null) _overviewController.dispose();
    _tabsScroll.dispose();
    for (final controller in _listScrolls.values) {
      controller.dispose();
    }
    super.dispose();
  }

  int _tab = 0;
  void _selectTab(int tab) {
    setState(() => _tab = tab);
    _overviewController._publishSelection();
    if (tab != 5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabsScroll.hasClients) return;
      _tabsScroll.animateTo(
        _tabsScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  String? _status;
  static const _tabs = ['订阅', '最新更新', '继续收听', '收藏', '下载', '队列'];

  Future<void> _openDiscover() async {
    final runtime = PodcastRuntime.instance;
    final folderId = _tab == 0 ? _subscriptionFolderId : null;
    final before = runtime.ready
        ? runtime.controller.channels.map((channel) => channel.id).toSet()
        : <String>{};
    await pushAboveMediaLibrary(
      context,
      AppMaterialPageRoute<void>(builder: (_) => const PodcastDiscoverPage()),
    );
    if (!mounted || !runtime.ready || folderId == null) return;
    final layout = PodcastSubscriptionLayout(runtime.store);
    if (layout.folder(folderId) == null) return;
    final added = runtime.controller.channels
        .map((channel) => channel.id)
        .where((id) => !before.contains(id))
        .toList();
    if (layout.move(added, folderId)) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final body = PodcastGate(
      bottomPadding: widget.bottomPadding,
      builder: (runtime) {
        final episodes = switch (_tab) {
          1 => runtime.store.view('new'),
          2 =>
            runtime.store.view('continue')..sort(
              (a, b) => runtime.controller
                  .state(b.id)
                  .lastPlayedMs
                  .compareTo(runtime.controller.state(a.id).lastPlayedMs),
            ),
          3 => runtime.store.view('favorites'),
          4 =>
            runtime.controller.downloads
                .map((t) => runtime.store.episode(t.episodeId))
                .whereType<PodcastEpisode>()
                .toList(),
          5 => runtime.queueEpisodes(),
          _ => <PodcastEpisode>[],
        };
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        return Column(
          children: [
            if (!_overviewController.isSelecting)
              _PodcastOverviewHeader(
                // Landscape is short. Share one row when the controls fit so the
                // episode list keeps the height a second toolbar row would take.
                allowSingleRow: landscape,
                title: Text(
                  '播客',
                  style: PodcastType.title.copyWith(fontSize: 25),
                ),
                tabs: MediaLibrarySpatialNavigationGroup(
                  group: _headerFocusGroup,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: SingleChildScrollView(
                          controller: _tabsScroll,
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: MediaLibrarySpatialNavigationGroup(
                            group: _headerFocusGroup,
                            child: Row(
                              children: [
                                for (var i = 0; i < _tabs.length; i++)
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      DesktopButtonClickRegion(
                                        child: TextButton(
                                          onPressed: () {
                                            _selectTab(i);
                                            final keyboard =
                                                HardwareKeyboard.instance;
                                            if (keyboard.isLogicalKeyPressed(
                                                  LogicalKeyboardKey.enter,
                                                ) ||
                                                keyboard.isLogicalKeyPressed(
                                                  LogicalKeyboardKey
                                                      .numpadEnter,
                                                ) ||
                                                keyboard.isLogicalKeyPressed(
                                                  LogicalKeyboardKey.space,
                                                )) {
                                              MediaLibrarySpatialNavigation.focusInitial(
                                                context,
                                              );
                                            }
                                          },
                                          style: TextButton.styleFrom(
                                            foregroundColor: _tab == i
                                                ? AppTokens.text1
                                                : AppTokens.text3,
                                          ),
                                          child: Text(
                                            _tabs[i],
                                            style: PodcastType.label,
                                          ),
                                        ),
                                      ),
                                      IgnorePointer(
                                        child: Container(
                                          key: ValueKey(
                                            'podcast-tab-indicator-$i',
                                          ),
                                          height: 2,
                                          width: 18,
                                          color: _tab == i
                                              ? AppTokens.text1
                                              : Colors.transparent,
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (_tab == 5) ...[
                        if (runtime.playlist?.canUndoQueueAddition ?? false)
                          PlaybackQueueUndoAdditionButton(
                            queue: runtime.playlist!,
                          ),
                        const SizedBox(width: 4),
                        PlaybackQueueSortControls(
                          canReverse: episodes.length > 1,
                          canReset: runtime.playlist?.hasCustomOrder ?? false,
                          compact:
                              MediaQuery.sizeOf(context).width < 600 ||
                              MediaQuery.textScalerOf(context).scale(14) > 18.2,
                          color: AppTokens.text2,
                          onReverse: () => runtime.reorderPodcastQueue(
                            episodes.reversed
                                .map((episode) => episode.id)
                                .toList(),
                          ),
                          onReset: runtime.resetQueueOrder,
                        ),
                        const SizedBox(width: 14),
                      ],
                    ],
                  ),
                ),
                actions: MediaLibrarySpatialNavigationGroup(
                  group: _headerFocusGroup,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DesktopButtonClickRegion(
                        child: IconButton(
                          tooltip: runtime.controller.refreshing.isEmpty
                              ? '检查更新'
                              : '正在检查更新',
                          onPressed: runtime.controller.refreshing.isEmpty
                              ? () => runtime.refresh(manual: true)
                              : null,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          tooltip: '搜索与导入',
                          onPressed: _openDiscover,
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          tooltip: '播客设置',
                          onPressed: () => _openSettings(context),
                          icon: const Icon(Icons.tune_rounded),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  _status!,
                  style: const TextStyle(color: AppTokens.text2),
                ),
              ),
            Expanded(
              child: _tab == 0
                  ? _PodcastSubscriptionLibrary(
                      key: _subscriptionLibraryKey,
                      runtime: runtime,
                      controller: _scrollForTab(0),
                      bottomPadding: widget.bottomPadding,
                      isActive: widget.isActive,
                      initialFolderId: _subscriptionFolderId,
                      onFolderChanged: (id) => _subscriptionFolderId = id,
                      onDiscover: _openDiscover,
                      overviewController: _overviewController,
                      selectionManagedByHost: widget.controller != null,
                    )
                  : MediaLibraryKeyboardRegion(
                      surface: () => 'podcast-overview-$_tab',
                      orderedIds: () => episodes.map((e) => e.id).toList(),
                      selectionMode: () => false,
                      selectedIds: () => <String>{},
                      onSelectionChanged: (_) {},
                      child: MediaLibraryScrollViewport(
                        controller: _scrollForTab(_tab),
                        isActive: widget.isActive,
                        bottomObstruction: widget.bottomPadding,
                        child: episodes.isEmpty
                            ? PodcastEmpty(
                                bottomPadding: widget.bottomPadding,
                                title: switch (_tab) {
                                  1 => '暂时没有新节目',
                                  2 => '还没有未听完的节目',
                                  3 => '还没有收藏',
                                  4 => '还没有下载',
                                  _ => '队列是空的',
                                },
                                message: _tab == 4
                                    ? '在节目菜单中下载完整音频或视频，也可以为频道开启自动下载。'
                                    : '可以从已订阅频道中选择节目。',
                              )
                            : _tab == 5
                            ? PlaybackQueueListView(
                                controller: _scrollForTab(5),
                                padding: EdgeInsets.only(
                                  bottom: widget.bottomPadding,
                                ),
                                itemCount: episodes.length,
                                onReorderStart: (_) =>
                                    _dragEpisodes = List.of(episodes),
                                onReorder: (oldIndex, newIndex) {
                                  final reordered = [
                                    ...(_dragEpisodes ?? episodes),
                                  ];
                                  if (oldIndex < 0 ||
                                      oldIndex >= reordered.length ||
                                      newIndex < 0 ||
                                      newIndex >= reordered.length) {
                                    return;
                                  }
                                  final moved = reordered.removeAt(oldIndex);
                                  reordered.insert(newIndex, moved);
                                  // Keep local files and other sources sitting in the same queue.
                                  // Only the podcast members move, and the queue becomes custom
                                  // so a later channel sort does not put them back.
                                  runtime.reorderPodcastQueue(
                                    reordered
                                        .map((episode) => episode.id)
                                        .toList(),
                                  );
                                  _dragEpisodes = null;
                                  setState(() {});
                                },
                                itemBuilder: (_, i) => Row(
                                  key: ValueKey(episodes[i].id),
                                  children: [
                                    PlaybackQueueDragHandle(
                                      key: ValueKey(
                                        'podcast-queue-drag-${episodes[i].id}',
                                      ),
                                      index: i,
                                      isCurrent:
                                          runtime
                                              .playback
                                              ?.currentItem
                                              ?.sourceRef
                                              ?.podcast
                                              ?.episodeId ==
                                          episodes[i].id,
                                      title: runtime.episodeTitle(episodes[i]),
                                      color: AppTokens.text3,
                                      numberColor: AppTokens.text2,
                                      enabled: episodes.length > 1,
                                      onMoveUp: i > 0
                                          ? () {
                                              final reordered = [...episodes];
                                              final moved = reordered.removeAt(
                                                i,
                                              );
                                              reordered.insert(i - 1, moved);
                                              runtime.reorderPodcastQueue(
                                                reordered
                                                    .map(
                                                      (episode) => episode.id,
                                                    )
                                                    .toList(),
                                              );
                                            }
                                          : null,
                                      onMoveDown: i < episodes.length - 1
                                          ? () {
                                              final reordered = [...episodes];
                                              final moved = reordered.removeAt(
                                                i,
                                              );
                                              reordered.insert(i + 1, moved);
                                              runtime.reorderPodcastQueue(
                                                reordered
                                                    .map(
                                                      (episode) => episode.id,
                                                    )
                                                    .toList(),
                                              );
                                            }
                                          : null,
                                    ),
                                    Expanded(
                                      child: PodcastEpisodeTile(
                                        episode: episodes[i],
                                        queue: episodes,
                                        onRemoveFromQueue: () => runtime
                                            .removeFromQueue(episodes[i].id),
                                        onError: (s) =>
                                            setState(() => _status = s),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : PodcastEpisodeList(
                                key: ValueKey(_tab),
                                controller: _scrollForTab(_tab),
                                storageKey: ('podcast-overview', _tab),
                                episodes: episodes,
                                bottomPadding: widget.bottomPadding,
                                onError: (s) => setState(() => _status = s),
                              ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
    final shortcuts = PodcastPageShortcuts(
      enabled: widget.isActive,
      onEscape: () =>
          _subscriptionLibraryKey.currentState?.handleBack() ?? false,
      onSelectAll: () => _subscriptionLibraryKey.currentState?.selectAll(),
      bindings: {
        LogicalKeyboardKey.keyB: () =>
            _subscriptionLibraryKey.currentState?.beginSelection(),
        LogicalKeyboardKey.keyA: () =>
            _subscriptionLibraryKey.currentState?.selectAll(toggle: true),
        LogicalKeyboardKey.keyS: _openDiscover,
        LogicalKeyboardKey.keyI: _openDiscover,
        LogicalKeyboardKey.keyN: () {
          final library = _subscriptionLibraryKey.currentState;
          if (_overviewController.isSelecting) {
            if (library?._selection.ids.length == 1) {
              unawaited(library!._rename(library._selection.ids.single));
            }
          } else {
            unawaited(_overviewController.createCollection());
          }
        },
        LogicalKeyboardKey.keyU: () =>
            _subscriptionLibraryKey.currentState?._moveSelectionToParent(),
        LogicalKeyboardKey.keyE: () =>
            _subscriptionLibraryKey.currentState?._exportSelection(),
        LogicalKeyboardKey.keyP: () => _openSettings(context),
        LogicalKeyboardKey.keyR: () {
          if (_overviewController.isSelecting) {
            unawaited(_subscriptionLibraryKey.currentState!._removeSelection());
            return;
          }
          final runtime = PodcastRuntime.instance;
          if (runtime.ready) unawaited(runtime.refresh(manual: true));
        },
        LogicalKeyboardKey.space: _togglePodcastSession,
      },
      child: PodcastTypography(
        child: widget.embedded
            ? ColoredBox(color: AppTokens.bgBase, child: body)
            : Scaffold(
                backgroundColor: AppTokens.bgBase,
                appBar: AppBar(title: const Text('播客')),
                body: SafeArea(top: false, child: body),
              ),
      ),
    );
    return widget.embedded
        ? shortcuts
        : MediaLibrarySpatialNavigation(child: shortcuts);
  }
}

/// Title, section filters, and toolbar for the podcast library.
///
/// Landscape windows are short, so the big title, the filter labels, and the
/// refresh / import / settings actions share one row when that row does not
/// overflow. Portrait, and any landscape width that cannot hold
/// the controls, keeps the title and actions above a separate filter row.
class _PodcastOverviewHeader extends MultiChildRenderObjectWidget {
  _PodcastOverviewHeader({
    required bool allowSingleRow,
    required Widget title,
    required Widget tabs,
    required Widget actions,
  }) : _allowSingleRow = allowSingleRow,
       super(
         key: const ValueKey('podcast-overview-header'),
         children: [title, tabs, actions],
       );

  final bool _allowSingleRow;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderPodcastOverviewHeader(allowSingleRow: _allowSingleRow);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPodcastOverviewHeader renderObject,
  ) {
    renderObject.allowSingleRow = _allowSingleRow;
  }
}

class _PodcastHeaderParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPodcastOverviewHeader extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PodcastHeaderParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PodcastHeaderParentData> {
  _RenderPodcastOverviewHeader({required bool allowSingleRow})
    : _allowSingleRow = allowSingleRow;

  bool _allowSingleRow;
  bool get allowSingleRow => _allowSingleRow;
  set allowSingleRow(bool value) {
    if (_allowSingleRow == value) return;
    _allowSingleRow = value;
    markNeedsLayout();
  }

  static const _left = 22.0;
  static const _right = 14.0;
  static const _top = 16.0;
  static const _bottom = 8.0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PodcastHeaderParentData) {
      child.parentData = _PodcastHeaderParentData();
    }
  }

  @override
  void performLayout() {
    final width = constraints.maxWidth;
    final title = firstChild!;
    final tabs = childAfter(title)!;
    final actions = childAfter(tabs)!;
    if (!width.isFinite) {
      // A horizontal scroller cannot be measured with an infinite width.
      final zero = BoxConstraints.tightFor(width: 0);
      title.layout(zero, parentUsesSize: true);
      tabs.layout(zero, parentUsesSize: true);
      actions.layout(zero, parentUsesSize: true);
      size = Size.zero;
      _place(title, Offset.zero);
      _place(tabs, Offset.zero);
      _place(actions, Offset.zero);
      return;
    }

    final contentWidth = max(0.0, width - _left - _right);
    final loose = BoxConstraints(maxWidth: contentWidth);
    title.layout(loose, parentUsesSize: true);
    tabs.layout(loose, parentUsesSize: true);
    actions.layout(loose, parentUsesSize: true);

    final filtersWidth =
        title.size.width + tabs.size.width + actions.size.width;
    final filtersFit = _allowSingleRow && filtersWidth <= contentWidth + 0.5;

    if (filtersFit) {
      final rowHeight = max(
        title.size.height,
        max(tabs.size.height, actions.size.height),
      );
      _place(title, Offset(_left, _center(_top, rowHeight, title.size.height)));
      _place(
        tabs,
        Offset(
          _left + title.size.width,
          _center(_top, rowHeight, tabs.size.height),
        ),
      );
      _place(
        actions,
        Offset(
          width - _right - actions.size.width,
          _center(_top, rowHeight, actions.size.height),
        ),
      );
      size = Size(width, _top + rowHeight + _bottom);
      return;
    }

    // Title and actions stay on their own row. Filters scroll beneath them.
    tabs.layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    final rowHeight = max(title.size.height, actions.size.height);
    _place(title, Offset(_left, _center(_top, rowHeight, title.size.height)));
    _place(
      actions,
      Offset(
        width - _right - actions.size.width,
        _top + (rowHeight - actions.size.height) / 2,
      ),
    );
    final tabsY = _top + rowHeight + _bottom;
    _place(tabs, Offset(0, tabsY));
    size = Size(width, tabsY + tabs.size.height);
  }

  double _center(double top, double rowHeight, double childHeight) =>
      top + (rowHeight - childHeight) / 2;

  void _place(RenderBox child, Offset offset) {
    (child.parentData! as _PodcastHeaderParentData).offset = offset;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}

class _ChannelCard extends StatelessWidget {
  const _ChannelCard({
    required this.channel,
    required this.titleScale,
    this.onTap,
    this.onSecondaryTap,
    this.isSelected = false,
    this.isSelectionMode = false,
  });
  final PodcastChannel channel;
  final double titleScale;
  final VoidCallback? onTap, onSecondaryTap;
  final bool isSelected, isSelectionMode;
  @override
  Widget build(BuildContext context) {
    final runtime = PodcastRuntime.instance;
    final author = channel.author.trim();
    final subtitle = author.isEmpty ? '播客频道' : author;
    return MediaLibraryCardScale(
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth = constraints.maxWidth;
          final chipSize = MediaLibraryActionDockMetrics.gridChipSize(
            cardWidth,
          );
          final textInset = MediaLibraryActionDockMetrics.textInset(
            chipSize: chipSize,
            showMore: !isSelectionMode,
            showLocate: false,
            existingPadding: MediaListLayoutMetrics.cardGridContentPadding(
              cardWidth,
            ).right,
          );
          final radius = MediaLibraryLayoutDefaults.cardCornerRadius(cardWidth);
          final titleFontSize = MediaLibraryLayoutDefaults.titleFontSize(
            cardWidth,
            titleScale,
          );
          final metaFontSize = MediaLibraryLayoutDefaults.metaFontSize(
            titleFontSize,
          );
          return MediaLibraryGridCard(
            keyboardItemId: channel.id,
            radius: radius,
            isSelected: isSelected,
            isSelectionMode: isSelectionMode,
            onSecondaryTap: onSecondaryTap,
            onTap:
                onTap ??
                () => Navigator.push(
                  context,
                  AppMaterialPageRoute<void>(
                    builder: (_) => PodcastChannelPage(channelId: channel.id),
                  ),
                ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      key: ValueKey('podcast-channel-cover-${channel.id}'),
                      aspectRatio: 1,
                      child: ColoredBox(
                        color: Colors.black26,
                        child: PodcastArtwork(
                          url: channel.imageUrl,
                          ownerKind: 'channel',
                          ownerId: channel.id,
                          size: cardWidth,
                          radius: 0,
                          expand: true,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: MediaListLayoutMetrics.cardGridContentPadding(
                          cardWidth,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _PodcastTitleHint(
                                title: runtime.channelTitle(channel),
                                child: Text(
                                  runtime.channelTitle(channel),
                                  key: ValueKey(
                                    'podcast-channel-title-${channel.id}',
                                  ),
                                  maxLines: SettingsService()
                                      .cardTitleMaxLinesFor(
                                        MediaQuery.sizeOf(context),
                                      ),
                                  overflow: TextOverflow.ellipsis,
                                  style: PodcastType.title.copyWith(
                                    fontSize: titleFontSize,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 2),
                            Padding(
                              padding: EdgeInsets.only(right: textInset),
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: PodcastType.meta.copyWith(
                                  fontSize: metaFontSize,
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
                if (!isSelectionMode)
                  MediaLibraryActionDock(
                    chipSize: chipSize,
                    more: PodcastMenuButton(
                      key: ValueKey('podcast-channel-menu-${channel.id}'),
                      compact: true,
                      title: '频道操作',
                      subtitle: runtime.channelTitle(channel),
                      tooltip: '更多频道操作',
                      fillSlot: true,
                      actionsBuilder: () => [
                        const PodcastMenuAction(
                          'transcribe',
                          transcriptionQueueLabel,
                          transcriptionQueueIcon,
                        ),
                        const PodcastMenuAction(
                          'refresh',
                          '更新',
                          Icons.refresh_rounded,
                        ),
                        if (runtime
                                .collectionFor(channel.id)
                                ?.isHiddenFromFolders ==
                            true)
                          const PodcastMenuAction(
                            'show_in_folders',
                            '添加到文件夹页面',
                            Icons.create_new_folder_outlined,
                          ),
                        const PodcastMenuAction(
                          'delete',
                          '删除',
                          Icons.delete_outline_rounded,
                          description: '取消订阅并移入回收站，保留已有下载',
                          destructive: true,
                        ),
                      ],
                      onSelected: (value) async {
                        switch (value) {
                          case 'transcribe':
                            await openTranscriptionQueue(
                              context,
                              TranscriptionMediaSelection(
                                podcastChannelIds: [channel.id],
                              ),
                            );
                          case 'refresh':
                            await runtime.controller.refreshChannel(channel.id);
                          case 'show_in_folders':
                            await runtime.showChannelInFolders(channel.id);
                          case 'delete':
                            await runtime.unsubscribe(channel.id);
                        }
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class PodcastEpisodeList extends StatelessWidget {
  const PodcastEpisodeList({
    super.key,
    required this.episodes,
    this.bottomPadding = 100,
    this.onError,
    this.controller,
    this.storageKey = 'podcast-episodes',
  });
  final List<PodcastEpisode> episodes;
  final double bottomPadding;
  final ValueChanged<String>? onError;
  final ScrollController? controller;
  final Object storageKey;
  @override
  Widget build(BuildContext context) => PlaybackListView.builder(
    key: PageStorageKey(storageKey),
    controller: controller,
    itemKey: (index) => episodes[index].id,
    padding: EdgeInsets.only(top: 8, bottom: bottomPadding),
    itemCount: episodes.length,
    itemBuilder: (_, i) => PodcastEpisodeTile(
      episode: episodes[i],
      queue: episodes,
      onError: onError,
    ),
  );
}

class PodcastEpisodeTile extends StatelessWidget {
  const PodcastEpisodeTile({
    super.key,
    required this.episode,
    this.queue,
    this.onError,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
    this.onRangeSelect,
    this.onLongPress,
    this.channelStyle = false,
    this.horizontalPadding,
    this.preferences,
    this.channelWide = false,
    this.onRemoveFromQueue,
  });
  final PodcastEpisode episode;
  final List<PodcastEpisode>? queue;
  final ValueChanged<String>? onError;
  final bool selecting, selected;
  final VoidCallback? onSelect;
  final VoidCallback? onRangeSelect;
  final VoidCallback? onLongPress;
  final bool channelStyle;
  final double? horizontalPadding;
  final PodcastPreferences? preferences;
  final bool channelWide;
  final VoidCallback? onRemoveFromQueue;
  @override
  Widget build(BuildContext context) {
    final runtime = PodcastRuntime.instance,
        controller = PodcastRuntime.instance.controller;
    final settings = preferences ?? runtime.store.effective(episode.channelId),
        state = controller.state(episode.id);
    final task = controller.downloadFor(episode.id);
    final title = runtime.episodeTitle(episode);
    final transfer = runtime.controller.transferProgress(episode.id);
    final compact = settings.text('density') == 'compact';
    final menu = PodcastMenuButton(
      compact: true,
      title: '节目操作',
      subtitle: title,
      tooltip: '节目操作',
      onSelected: (value) => _action(context, value),
      // Queue snapshots can contain thousands of entries. Read them, and
      // construct the actions, only when this menu is actually opened.
      actionsBuilder: () {
        final state = controller.state(episode.id);
        final task = controller.downloadFor(episode.id);
        final hidden = runtime.store.presentation(episode.id)['hidden'] == true;
        return [
          const PodcastMenuAction(
            'transcribe',
            transcriptionQueueLabel,
            transcriptionQueueIcon,
            section: '节目',
          ),
          if (task?.status == PodcastDownloadStatus.downloading ||
              task?.status == PodcastDownloadStatus.queued)
            const PodcastMenuAction(
              'pause',
              '暂停下载',
              Icons.pause_circle_outline_rounded,
              section: '离线与存储',
            )
          else
            PodcastMenuAction(
              'download',
              task?.status == PodcastDownloadStatus.completed
                  ? '重新下载'
                  : task?.status == PodcastDownloadStatus.paused
                  ? '继续下载'
                  : task?.status == PodcastDownloadStatus.failed
                  ? '重试下载'
                  : '下载完整节目',
              Icons.download_rounded,
              description: '保存完整音视频，离线时也能收听',
              section: '离线与存储',
            ),
          const PodcastMenuAction(
            'rename',
            '重命名',
            Icons.edit_outlined,
            description: '设置应用内别名，保留 RSS 原始标题',
            section: '节目',
          ),
          const PodcastMenuAction(
            'links',
            '节目链接',
            Icons.link_rounded,
            description: '查看并复制原始节目、频道与媒体地址',
            section: '节目',
          ),
          PodcastMenuAction(
            'favorite',
            state.favorite ? '取消收藏' : '收藏节目',
            state.favorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
            section: '收听',
          ),
          if (!state.played && state.positionMs > 0) ...[
            const PodcastMenuAction(
              'played',
              '标记为已听',
              Icons.done_all_rounded,
              section: '收听',
            ),
            const PodcastMenuAction(
              'unplayed',
              '标记为未听',
              Icons.unpublished_outlined,
              section: '收听',
            ),
          ] else
            PodcastMenuAction(
              'played',
              state.played ? '标记为未听' : '标记为已听',
              state.played
                  ? Icons.unpublished_outlined
                  : Icons.done_all_rounded,
              section: '收听',
            ),
          PodcastMenuAction(
            hidden ? 'unhide' : 'hide',
            hidden ? '恢复显示' : '隐藏节目',
            hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            description: hidden ? '回到频道列表' : '可在「已隐藏」中恢复',
            section: '节目',
          ),
          const PodcastMenuAction(
            'queue',
            '加入播放列表',
            Icons.playlist_add_rounded,
            section: '收听',
          ),
          if ((runtime.store.read('queue', 'current')?['ids'] as List? ?? [])
              .contains(episode.id))
            const PodcastMenuAction(
              'dequeue',
              '从队列移除',
              Icons.playlist_remove_rounded,
              section: '收听',
            ),
          for (var i = 0; i < episode.media.length; i++)
            if (episode.media.length > 1)
              PodcastMenuAction(
                'version:$i',
                '下载 ${episode.media[i].label.isNotEmpty
                    ? episode.media[i].label
                    : episode.media[i].isVideo
                    ? '视频版'
                    : '音频版'}',
                episode.media[i].isVideo
                    ? Icons.videocam_outlined
                    : Icons.headphones_rounded,
                section: '离线与存储',
              ),
          if (task != null)
            const PodcastMenuAction(
              'cancel',
              '取消下载任务',
              Icons.close_rounded,
              description: '保留已经缓存的数据',
              section: '离线与存储',
            ),
          PodcastMenuAction(
            'retain',
            state.retained ? '取消保留' : '始终保留文件',
            Icons.shield_outlined,
            description: state.retained ? '重新应用自动清理规则' : '不参与自动清理',
            section: '离线与存储',
          ),
          if (task?.status == PodcastDownloadStatus.completed) ...[
            const PodcastMenuAction(
              'export',
              '导出媒体文件（遵守来源许可）',
              Icons.ios_share_rounded,
              section: '离线与存储',
            ),
            const PodcastMenuAction(
              'delete',
              '删除下载',
              Icons.delete_outline_rounded,
              description: '收听进度和收藏会保留',
              destructive: true,
            ),
          ],
        ];
      },
    );
    if (channelStyle) {
      final corners = BorderRadius.circular(14);
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding ?? 16),
        child: Column(
          children: [
            Material(
              key: ValueKey('podcast-episode-surface-${episode.id}'),
              color: selected ? AppTokens.accentSoft : Colors.transparent,
              borderRadius: corners,
              clipBehavior: Clip.antiAlias,
              child: PodcastEpisodePress(
                keyboardItemId: episode.id,
                selected: selected,
                borderRadius: corners,
                selecting: selecting,
                onOpen: () =>
                    openPodcastEpisode(context, episode, queue: queue),
                onSelect: onSelect,
                onRangeSelect: onRangeSelect,
                onLongPress: onLongPress,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: compact ? 8 : 10,
                  ),
                  child: Builder(
                    builder: (context) {
                      final play = MediaLibraryKeyboardDirectionalAction(
                        child: PodcastIconButton(
                          tooltip: '播放节目',
                          onPressed: () => openPodcastEpisode(
                            context,
                            episode,
                            queue: queue,
                          ),
                          icon: const Icon(
                            Icons.play_arrow_rounded,
                            size: 24,
                            color: AppTokens.text2,
                          ),
                        ),
                      );
                      final rowMenu = MediaLibraryKeyboardDirectionalAction(
                        child: menu,
                      );
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (selecting) ...[
                            Icon(
                              selected
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: selected
                                  ? AppTokens.accent
                                  : AppTokens.text3,
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _PodcastTitleHint(
                                  title: title,
                                  child: Text(
                                    title,
                                    key: ValueKey(
                                      'podcast-episode-title-${episode.id}',
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: PodcastType.label.copyWith(
                                      fontSize: 15,
                                      height: 1.4,
                                      color: state.played
                                          ? AppTokens.text2
                                          : AppTokens.text1,
                                    ),
                                  ),
                                ),
                                if (!compact &&
                                    settings.flag('summaries') &&
                                    episode.description.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  PodcastEpisodeSummary(
                                    key: ValueKey(
                                      'podcast-summary-${episode.id}',
                                    ),
                                    text: podcastArticleText(
                                      episode.description,
                                    ),
                                    enabled: !selecting,
                                  ),
                                ],
                                const SizedBox(height: 7),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      [
                                            podcastDay(episode.publishedMs),
                                            if (episode.durationMs > 0)
                                              podcastTime(episode.durationMs),
                                            if (episode.media.first.isVideo)
                                              '视频',
                                          ]
                                          .where((value) => value.isNotEmpty)
                                          .join(' · '),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        height: 1.4,
                                        color: AppTokens.text3,
                                      ),
                                    ),
                                    if (state.favorite)
                                      const Icon(
                                        Icons.favorite_rounded,
                                        size: 12,
                                        color: AppTokens.text2,
                                      ),
                                    if (state.retained)
                                      const Text(
                                        '保留',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppTokens.text2,
                                        ),
                                      ),
                                    PodcastListenLabel(state: state),
                                    if (task != null)
                                      Text(
                                        _downloadLabel(task),
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppTokens.text2,
                                        ),
                                      ),
                                  ],
                                ),
                                if (task?.status ==
                                    PodcastDownloadStatus.downloading)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: LinearProgressIndicator(
                                      value: _downloadProgress(task!, transfer),
                                      color: AppTokens.text2,
                                      minHeight: 2,
                                      backgroundColor: AppTokens.bgCard,
                                    ),
                                  ),
                                if (task?.error.isNotEmpty == true)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      task!.error,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTokens.text2,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (!selecting) ...[
                            const SizedBox(width: 8),
                            if (channelWide)
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [play, rowMenu],
                              )
                            else
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [play, rowMenu],
                              ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Divider(
                height: 1,
                thickness: .7,
                color: AppTokens.lineSubtle,
              ),
            ),
          ],
        ),
      );
    }
    final channelImage =
        runtime.store.channel(episode.channelId)?.imageUrl ?? '';
    final image = episode.imageUrl.isEmpty ? channelImage : episode.imageUrl;
    final inset = max(4.0, (horizontalPadding ?? 24) - 16);
    final corners = BorderRadius.circular(18);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: inset),
      child: Column(
        children: [
          Material(
            color: selected ? AppTokens.accentSoft : Colors.transparent,
            borderRadius: corners,
            clipBehavior: Clip.antiAlias,
            child: PodcastEpisodePress(
              keyboardItemId: episode.id,
              selected: selected,
              borderRadius: corners,
              selecting: selecting,
              onOpen: () => openPodcastEpisode(context, episode, queue: queue),
              onSelect: onSelect,
              onRangeSelect: onRangeSelect,
              onLongPress: onLongPress,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  onRemoveFromQueue != null ? 4 : 16,
                  compact ? 14 : 20,
                  onRemoveFromQueue != null ? 12 : 16,
                  compact ? 14 : 20,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (selecting)
                      Padding(
                        padding: const EdgeInsets.only(right: 12, top: 14),
                        child: Icon(
                          selected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: selected ? AppTokens.accent : AppTokens.text3,
                        ),
                      ),
                    ...[
                      PodcastArtwork(
                        url: image,
                        fallbackUrl: episode.imageUrl.isEmpty
                            ? ''
                            : channelImage,
                        ownerKind: 'episode',
                        ownerId: episode.id,
                        size: compact || onRemoveFromQueue != null ? 48 : 60,
                        radius: 8,
                      ),
                      SizedBox(width: onRemoveFromQueue != null ? 8 : 16),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            [
                              podcastDay(episode.publishedMs),
                              if (episode.durationMs > 0)
                                podcastTime(episode.durationMs),
                              if (episode.media.first.isVideo) '视频',
                            ].where((s) => s.isNotEmpty).join(' · '),
                            style: const TextStyle(
                              color: AppTokens.text3,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 5),
                          _PodcastTitleHint(
                            title: title,
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: PodcastType.label.copyWith(
                                letterSpacing: -.15,
                                color: state.played
                                    ? AppTokens.text2
                                    : AppTokens.text1,
                                height: 1.4,
                              ),
                            ),
                          ),
                          if (!compact &&
                              settings.flag('summaries') &&
                              episode.description.isNotEmpty) ...[
                            const SizedBox(height: 5),
                            Text(
                              podcastArticleText(episode.description),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: PodcastType.prose.copyWith(
                                color: AppTokens.text2,
                                fontSize: 13,
                                height: 1.65,
                              ),
                            ),
                          ],
                          const SizedBox(height: 7),
                          Wrap(
                            spacing: 10,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (state.favorite)
                                const Icon(
                                  Icons.favorite_rounded,
                                  size: 13,
                                  color: AppTokens.text2,
                                ),
                              if (state.retained)
                                const Text(
                                  '保留',
                                  style: TextStyle(
                                    color: AppTokens.text2,
                                    fontSize: 11,
                                  ),
                                ),
                              PodcastListenLabel(state: state),
                              if (task != null)
                                ValueListenableBuilder<int>(
                                  valueListenable: controller.transferTick,
                                  builder: (_, _, _) => Text(
                                    _downloadLabel(task),
                                    style: const TextStyle(
                                      color: AppTokens.text2,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (task?.status == PodcastDownloadStatus.downloading)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: ValueListenableBuilder<int>(
                                valueListenable: controller.transferTick,
                                builder: (_, _, _) {
                                  final live = controller.transferProgress(
                                    episode.id,
                                  );
                                  return LinearProgressIndicator(
                                    value: _downloadProgress(task!, live),
                                    color: AppTokens.text2,
                                    minHeight: 2,
                                    backgroundColor: AppTokens.bgCard,
                                  );
                                },
                              ),
                            ),
                          if (task?.error.isNotEmpty == true)
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Text(
                                task!.error,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTokens.text2,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!selecting) menu,
                    if (!selecting && onRemoveFromQueue != null) ...[
                      const SizedBox(width: 8),
                      PlaybackQueueRemoveButton(
                        key: ValueKey('podcast-queue-remove-${episode.id}'),
                        title: title,
                        color: AppTokens.text2,
                        onPressed: onRemoveFromQueue!,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double? _downloadProgress(
    PodcastDownload task,
    PodcastTransferProgress? progress,
  ) {
    final total = progress?.totalBytes ?? task.total;
    if (total == null || total <= 0) return null;
    return ((progress?.receivedBytes ?? task.received) / total).clamp(0, 1);
  }

  String _downloadLabel(PodcastDownload task) => switch (task.status) {
    PodcastDownloadStatus.completed => '已下载 · ${podcastSize(task.received)}',
    PodcastDownloadStatus.downloading => _liveDownloadLabel(task),
    PodcastDownloadStatus.queued => '等待下载',
    PodcastDownloadStatus.waitingNetwork => '正在恢复下载',
    PodcastDownloadStatus.paused =>
      task.error.isEmpty ? '已暂停' : '已暂停 · ${task.error}',
    PodcastDownloadStatus.failed =>
      task.error.isEmpty ? '下载失败，可重试' : '下载失败 · ${task.error}',
  };
  String _liveDownloadLabel(PodcastDownload task) {
    final transfer = PodcastRuntime.instance.controller.transferProgress(
      task.episodeId,
    );
    final received = transfer?.receivedBytes ?? task.received;
    final total = transfer?.totalBytes ?? task.total;
    final speed = transfer?.bytesPerSecond ?? 0;
    return '${transfer?.message.isNotEmpty == true ? transfer!.message : '下载中'} · ${podcastSize(received)}${total == null ? '' : ' / ${podcastSize(total)}'}${speed > 0 ? ' · ${podcastSize(speed.round())}/s' : ''}';
  }

  Future<void> _action(BuildContext context, String action) async {
    final runtime = PodcastRuntime.instance, c = runtime.controller;
    try {
      if (action == 'rename') {
        await _renamePodcastEpisode(context, runtime, episode);
        return;
      }
      if (action == 'links') {
        final channel = runtime.store.channel(episode.channelId);
        await showPodcastLinks(
          context,
          title: '节目链接',
          links: [
            PodcastLink('单集原始页面', episode.link),
            if (channel != null) ...[
              PodcastLink('频道主页', channel.link),
              PodcastLink('RSS 订阅地址', channel.feedUrl),
            ],
            for (final media in episode.media)
              PodcastLink(media.isVideo ? '视频文件' : '音频文件', media.url),
          ],
        );
      }
      if (action == 'favorite') {
        c.updateState(episode.id, (s) => s.favorite = !s.favorite);
      }
      if (action == 'played') {
        c.setPlayed(episode.id, !c.state(episode.id).played);
      }
      if (action == 'unplayed') {
        c.setPlayed(episode.id, false);
      }
      if (action == 'hide' || action == 'unhide') {
        runtime.store.setPresentation(episode.id, hidden: action == 'hide');
        c.publish();
      }
      if (action == 'retain') {
        c.updateState(episode.id, (s) => s.retained = !s.retained);
      }
      if (action == 'transcribe' && context.mounted) {
        await openTranscriptionQueue(
          context,
          TranscriptionMediaSelection(podcastEpisodeIds: [episode.id]),
        );
      }
      if (action == 'queue') await runtime.addToQueue(episode);
      if (action == 'dequeue') runtime.removeFromQueue(episode.id);
      if (action == 'pause') c.pause(episode.id);
      if (action == 'cancel') await c.cancel(episode.id);
      if (action == 'delete') {
        if (c.state(episode.id).retained) {
          c.updateState(episode.id, (s) => s.retained = false);
        }
        await c.cancel(episode.id, removeFile: true);
      }
      if (action == 'download') {
        if (c.downloads.any(
          (t) =>
              t.episodeId == episode.id &&
              t.status == PodcastDownloadStatus.completed,
        )) {
          await c.cancel(episode.id, removeFile: true);
        }
        c.enqueue(episode);
      }
      if (action.startsWith('version:')) {
        c.enqueue(
          episode,
          mediaUrl: episode.media[int.parse(action.split(':').last)].url,
        );
      }
      if (action == 'export') {
        final task = c.downloads.firstWhere((t) => t.episodeId == episode.id);
        final media =
            episode.media.where((m) => m.url == task.mediaUrl).firstOrNull ??
            PodcastMedia(url: task.mediaUrl);
        final file = await c.mediaStore.assemble(episode, media);
        final extension = file.path.split('.').last;
        await savePodcastMediaFile(
          file,
          '${runtime.episodeTitle(episode).replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}.$extension',
        );
      }
    } catch (error) {
      onError?.call(
        error is FormatException
            ? error.message
            : error is HttpException
            ? error.message
            : '操作暂时未完成，请稍后重试',
      );
    }
  }
}

class PodcastDiscoverPage extends StatefulWidget {
  const PodcastDiscoverPage({
    super.key,
    this.targetFolderId,
    this.initialPreview,
    this.initialInput,
    this.autoResolveInitialInput = false,
    this.initialQuery,
  });
  final String? targetFolderId;

  /// Feed already in hand. It stays on this page until the user leaves the
  /// preview; opening it does not subscribe or write the library.
  final PodcastResolution? initialPreview;
  final String? initialInput;
  final bool autoResolveInitialInput;

  /// A query submitted from the home search scope selector.
  final String? initialQuery;
  @override
  State<PodcastDiscoverPage> createState() => _PodcastDiscoverPageState();
}

class _PodcastDiscoverPageState extends State<PodcastDiscoverPage> {
  final _query = TextEditingController(), _url = TextEditingController();
  final _queryFocus = FocusNode(), _urlFocus = FocusNode();
  final _initialSearchWork = RouteTransitionWork();
  bool _initialSearchScheduled = false;
  Timer? _debounce;
  int _tab = 0, _request = 0;
  String _region = 'CN', _provider = 'apple';
  bool _busy = false;
  String? _status;
  List<PodcastSearchResult> _results = [];
  String? _searchedQuery;
  PodcastResolution? _preview;
  PodcastResolveRequest? _previewRequest;
  String? _previewInput, _previewNotice;
  bool _refreshingPreview = false;

  /// Episodes currently held for this preview, focus episode first.
  /// Older pages are appended only after the user scrolls to the end.
  List<PodcastEpisode> _previewEpisodes = const [];

  /// How many of [_previewEpisodes] the list is allowed to build.
  static const _previewPageSize = 20;
  int _shown = _previewPageSize;
  bool _loadingMore = false;
  bool _revealScheduled = false;
  int _moreRequest = 0;
  String? _moreError;
  String? _folderId;
  bool _folderExplicit = false;
  @override
  void initState() {
    super.initState();
    _folderId = widget.targetFolderId;
    _queryFocus.addListener(_searchFocusChanged);
    _query.text = widget.initialQuery?.trim() ?? '';
    if (widget.initialInput != null) {
      _url.text = widget.initialInput!;
      _tab = 1;
    }
    final initial = widget.initialPreview;
    if (initial != null) _adoptPreview(initial);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _initialSearchWork.bind(ModalRoute.of(context));
    if (!_initialSearchScheduled &&
        widget.autoResolveInitialInput &&
        widget.initialPreview == null &&
        _url.text.trim().isNotEmpty) {
      _initialSearchScheduled = true;
      _initialSearchWork.schedule(
        'initial-input',
        () => unawaited(_resolve(_url.text)),
      );
    }
  }

  void _scheduleInitialSearch() {
    if (_initialSearchScheduled ||
        widget.initialQuery?.trim().isNotEmpty != true ||
        _query.text.isEmpty ||
        _tab != 0) {
      return;
    }
    _initialSearchScheduled = true;
    _initialSearchWork.schedule('initial-search', () => unawaited(_search()));
  }

  @override
  void dispose() {
    _initialSearchWork.dispose();
    _previewRequest?.cancel();
    _queryFocus.removeListener(_searchFocusChanged);
    _queryFocus.dispose();
    _urlFocus.dispose();
    _query.dispose();
    _url.dispose();
    _debounce?.cancel();
    if (PodcastRuntime.instance.ready) {
      PodcastRuntime.instance.controller.client.cancelSearch();
    }
    super.dispose();
  }

  void _focusInput(int tab) {
    _initialSearchScheduled = true;
    _initialSearchWork.cancel('initial-search');
    _debounce?.cancel();
    _request++;
    setState(() {
      _dropPreview();
      _busy = false;
      _status = null;
      _tab = tab;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (tab == 0) _queryFocus.requestFocus();
      if (tab == 1) _urlFocus.requestFocus();
      if (tab == 2) FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  void _updateDiscovery(VoidCallback action) => setState(action);

  void _searchFocusChanged() {
    if (mounted) setState(() {});
  }

  void _clearQuery({bool focusInput = true}) {
    _initialSearchScheduled = true;
    _initialSearchWork.cancel('initial-search');
    _debounce?.cancel();
    _request++;
    PodcastRuntime.instance.controller.client.cancelSearch();
    _query.clear();
    setState(() {
      _busy = false;
      _results = [];
      _searchedQuery = null;
      _status = null;
      _dropPreview();
    });
    if (focusInput) {
      _queryFocus.requestFocus();
    } else {
      _queryFocus.unfocus();
    }
  }

  void _queryChanged(String value) {
    _initialSearchScheduled = true;
    _initialSearchWork.cancel('initial-search');
    _debounce?.cancel();
    _cancelPreviewLoad();
    _previewInput = null;
    _previewNotice = null;
    // Invalidate immediately, including while the next query is debouncing.
    _request++;
    PodcastRuntime.instance.controller.client.cancelSearch();
    setState(() {
      _busy = false;
      _results = [];
      _searchedQuery = null;
      _status = null;
    });
    if (value.trim().isEmpty) return;
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => _search(remember: false),
    );
  }

  void _searchFor(String value) {
    _query.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _search();
  }

  Future<void> _search({bool remember = true}) async {
    _initialSearchScheduled = true;
    _initialSearchWork.cancel('initial-search');
    _debounce?.cancel();
    final query = _query.text.trim();
    if (query.isEmpty) {
      _clearQuery();
      return;
    }
    if (remember) _queryFocus.unfocus();
    final request = ++_request;
    if (remember) PodcastRuntime.instance.store.rememberSearch(query);
    setState(() {
      _busy = true;
      _results = [];
      _searchedQuery = query;
      _status = null;
      _dropPreview();
    });
    try {
      final results = await PodcastRuntime.instance.controller.client.search(
        query,
        region: _region,
        provider: _provider,
      );
      if (mounted && request == _request) {
        if (!remember) PodcastRuntime.instance.store.rememberSearch(query);
        setState(() => _results = results);
      }
    } catch (error) {
      if (mounted && request == _request) {
        setState(
          () => _status = error is FormatException
              ? error.message
              : '搜索暂时不可用，可更换目录或导入 RSS 链接',
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _resolve(String value) async {
    _initialSearchWork.cancel('initial-input');
    value = value.trim();
    if (_previewRequest != null && _previewInput == value) return;
    _debounce?.cancel();
    final controller = PodcastRuntime.instance.controller;
    controller.client.cancelSearch();
    final request = ++_request;
    final cached = controller.previews.cached(value);
    setState(() {
      _busy = cached == null;
      _status = null;
      _dropPreview();
      _previewInput = value;
      _refreshingPreview = true;
      if (cached != null) _adoptPreview(cached);
      _previewNotice = cached == null ? '正在加载播客…' : '正在检查节目更新…';
    });
    final operation = PodcastResolveRequest();
    _previewRequest = operation;
    bool current() =>
        mounted && request == _request && identical(_previewRequest, operation);
    try {
      final result = await controller.previews.load(
        value,
        request: operation,
        onRetry: () {
          if (current()) {
            setState(() => _previewNotice = '连接暂时中断，正在重新加载…');
          }
        },
      );
      if (current()) {
        setState(() {
          _adoptPreview(result);
          _previewNotice = null;
        });
      }
    } catch (error) {
      if (current() && error is! PodcastResolveCancelled) {
        final message = podcastPreviewErrorMessage(error);
        setState(() {
          if (_preview == null) {
            _status = message;
          } else {
            _previewNotice = '$message 当前显示最近成功加载的节目。';
          }
        });
      }
    } finally {
      if (current()) {
        setState(() {
          _previewRequest = null;
          _refreshingPreview = false;
          _busy = false;
        });
      }
      operation.dispose();
    }
  }

  void _cancelPreviewLoad() {
    _previewRequest?.cancel();
    _previewRequest = null;
    _refreshingPreview = false;
  }

  bool get _hasDiscoveryBackStep =>
      _preview != null ||
      _previewInput != null ||
      (_tab == 0 && (_query.text.isNotEmpty || _searchedQuery != null));

  bool _backWithinDiscovery() {
    if (_preview != null || _previewInput != null) {
      _returnToResults();
      return true;
    }
    if (_tab == 0 && (_query.text.isNotEmpty || _searchedQuery != null)) {
      _clearQuery(focusInput: false);
      return true;
    }
    return false;
  }

  void _returnToResults() => setState(() {
    _request++;
    _busy = false;
    _status = null;
    _dropPreview();
  });

  Future<void> _subscribe() async {
    final result = _preview;
    if (result == null) return;
    setState(() {
      _request++;
      _cancelPreviewLoad();
      _previewNotice = null;
      _busy = true;
    });
    try {
      final card = await PodcastRuntime.instance.subscribe(
        result.feed,
        parentId: _folderId,
        standalone: result.singleEpisode,
        explicitPlacement: _folderExplicit,
      );
      if (!mounted) return;
      if (card != null) {
        Navigator.pushReplacement(
          context,
          AppMaterialPageRoute<void>(
            builder: (_) =>
                PodcastChannelPage(channelId: card.podcastRef!.channelId),
          ),
        );
      } else {
        setState(() => _status = '已导入节目，可从媒体库打开播放');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _status = error is FormatException ? error.message : '订阅未完成，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importOpml() async {
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['opml', 'xml', 'json'],
      withData: true,
    );
    if (selection == null) return;
    final placement = _folderExplicit
        ? ImportPlacementRequest.explicit(ImportCardFeature.podcast, _folderId)
        : SettingsService().captureImportPlacement(
            ImportCardFeature.podcast,
            openedFromFolderId: _folderId,
          );
    setState(() {
      _busy = true;
      _status = '正在逐个导入频道…';
    });
    try {
      final file = selection.files.single;
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      final source = utf8.decode(bytes);
      if (file.name.endsWith('.json')) {
        final bundle = jsonDecode(source) as Map;
        if (bundle['version'] != 1 && bundle['version'] != 2) {
          throw const FormatException('无法识别的播客备份');
        }
        for (final raw in bundle['channels'] as List) {
          final data = Map<String, dynamic>.from(raw);
          PodcastRuntime.instance.store.importChannel(data);
          final channel = PodcastChannel.fromJson(
            Map<String, dynamic>.from(data['channel']),
          );
          await PodcastRuntime.instance.subscribe(
            PodcastFeed(
              channel,
              PodcastRuntime.instance.store.episodes(channel.id),
            ),
            parentId: _folderId,
            importPlacement: placement,
          );
        }
        if (mounted) setState(() => _status = '已恢复订阅、收听进度和频道设置');
      } else {
        var count = 0;
        final failures = await PodcastRuntime.instance.controller.importOpml(
          source,
          (feed) async {
            await PodcastRuntime.instance.subscribe(
              feed,
              parentId: _folderId,
              importPlacement: placement,
            );
            count++;
          },
        );
        if (mounted) {
          setState(
            () => _status =
                '已导入 $count 个频道${failures.isEmpty ? '' : '，${failures.length} 个未能导入：\n${failures.join('\n')}'}',
          );
        }
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _status = error is FormatException
              ? error.message
              : '文件未能导入，请检查内容后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_hasDiscoveryBackStep,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) _backWithinDiscovery();
    },
    child: PodcastPageShortcuts(
      bindings: {
        LogicalKeyboardKey.keyS: () => _focusInput(0),
        LogicalKeyboardKey.keyI: () => _focusInput(1),
        LogicalKeyboardKey.keyP: () => _openSettings(context),
      },
      onEscape: _backWithinDiscovery,
      child: PodcastTypography(
        child: Scaffold(
          backgroundColor: AppTokens.bgBase,
          appBar: AppBar(
            backgroundColor: AppTokens.bgBase,
            foregroundColor: AppTokens.text1,
            scrolledUnderElevation: 0,
            title: Text(switch (_tab) {
              0 => '搜索播客',
              1 => '链接导入',
              _ => 'OPML / 备份',
            }),
          ),
          body: MediaLibrarySafeArea(
            child: PodcastGate(
              builder: (runtime) {
                _scheduleInitialSearch();
                return Column(
                  children: [
                    _discoveryNavigation(),
                    Expanded(
                      child: _preview != null
                          ? Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1120,
                                ),
                                child: _previewView(),
                              ),
                            )
                          : _discoverySurface(runtime),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  /// Adopting a preview never writes subscription or playback state.
  void _adoptPreview(PodcastResolution result) {
    _moreRequest++;
    final focusId = result.focusEpisodeId;
    final focus = result.feed.episodes
        .where((episode) => episode.id == focusId)
        .firstOrNull;
    _preview = result;
    _previewEpisodes = [
      ?focus,
      ...result.feed.episodes.where((episode) => episode.id != focus?.id),
    ];
    _shown = _previewPageSize;
    _loadingMore = false;
    _moreError = null;
  }

  void _dropPreview() {
    _cancelPreviewLoad();
    _previewInput = null;
    _previewNotice = null;
    _moreRequest++;
    _preview = null;
    _previewEpisodes = const [];
    _shown = _previewPageSize;
    _loadingMore = false;
    _moreError = null;
  }

  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (mounted) _revealMore();
    });
  }

  void _revealMore({bool fromScroll = false}) {
    final resolution = _preview;
    if (resolution == null || _loadingMore) return;
    if (_shown < _previewEpisodes.length) {
      setState(
        () => _shown = min(_shown + _previewPageSize, _previewEpisodes.length),
      );
      return;
    }
    final next = resolution.feed.channel.nextPage;
    if (next == null || next.isEmpty) return;
    // A failed page waits for another scroll, so a rebuild cannot retry itself.
    if (_moreError != null && !fromScroll) return;
    unawaited(_loadNextPage(next));
  }

  Future<void> _loadNextPage(String url) async {
    final request = ++_moreRequest;
    final channel = _preview?.feed.channel;
    if (channel == null) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final client = PodcastRuntime.instance.controller.client;
      final response = await client.http.get(url);
      if (!mounted || request != _moreRequest || _preview == null) return;
      final parsed = client.parser.parse(
        response.bytes,
        response.url,
        channelId: channel.id,
      );
      final known = _previewEpisodes.map((episode) => episode.id).toSet();
      final fresh = parsed.episodes
          .where((episode) => known.add(episode.id))
          .toList(growable: false);
      final next = parsed.channel.nextPage;
      // The same link with nothing new would spin if we asked for it again.
      channel.nextPage = fresh.isEmpty && next == url ? null : next;
      // Subscription reads this same feed, so older pages have to land here too.
      _preview!.feed.episodes.addAll(fresh);
      setState(() {
        _previewEpisodes = [..._previewEpisodes, ...fresh];
        _shown = min(_shown + _previewPageSize, _previewEpisodes.length);
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || request != _moreRequest) return;
      setState(() {
        _loadingMore = false;
        _moreError = '更早的节目暂时没有载入，继续下滑可重试';
      });
    }
  }

  void _openEpisode(PodcastEpisode episode) {
    final channel = _preview?.feed.channel;
    if (channel == null) return;
    Navigator.of(context).push(
      AppMaterialPageRoute<void>(
        builder: (_) => _PodcastDiscoverEpisodePage(
          channelTitle: PodcastRuntime.instance.channelTitle(channel),
          channelImage: channel.imageUrl,
          episode: episode,
        ),
      ),
    );
  }

  Widget _previewView() {
    final resolution = _preview!, channel = resolution.feed.channel;
    final shown = min(_shown, _previewEpisodes.length);
    final hasNext = channel.nextPage?.isNotEmpty == true;
    final footer = _loadingMore || _moreError != null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 16, 4),
          child: Row(
            children: [
              DesktopButtonClickRegion(
                child: IconButton(
                  tooltip: '返回',
                  onPressed: _returnToResults,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
              Expanded(
                child: Text(
                  PodcastRuntime.instance.channelTitle(channel),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              DesktopButtonClickRegion(
                child: IconButton(
                  key: const ValueKey('podcast-preview-refresh'),
                  tooltip: '重新加载',
                  onPressed: _busy || _refreshingPreview
                      ? null
                      : () => _resolve(_previewInput ?? channel.feedUrl),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ),
              DesktopButtonClickRegion(
                child: FilledButton.tonal(
                  onPressed: _busy ? null : _subscribe,
                  child: Text(resolution.singleEpisode ? '导入这一集' : '订阅整个频道'),
                ),
              ),
            ],
          ),
        ),
        if (_previewNotice != null || _busy)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _previewNotice ?? '正在导入播客…',
                key: const ValueKey('podcast-preview-notice'),
                style: const TextStyle(color: AppTokens.text2, fontSize: 12),
              ),
            ),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.metrics.axis != Axis.vertical) return false;
              if (notification is! ScrollUpdateNotification &&
                  notification is! OverscrollNotification) {
                return false;
              }
              final metrics = notification.metrics;
              if (metrics.maxScrollExtent > 0 &&
                  metrics.pixels >= metrics.maxScrollExtent - 160) {
                _revealMore(fromScroll: true);
              }
              return false;
            },
            child: ListView.builder(
              key: const ValueKey('podcast-discover-episodes'),
              primary: true,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              itemCount: shown + 1 + (footer ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == 0) return _previewHeader(resolution);
                if (index == shown + 1) return _previewFooter();
                final episode = _previewEpisodes[index - 1];
                if (index == shown &&
                    (shown < _previewEpisodes.length || hasNext)) {
                  _scheduleReveal();
                }
                return _previewEpisodeTile(
                  episode,
                  focused: episode.id == resolution.focusEpisodeId,
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _previewHeader(PodcastResolution resolution) {
    final channel = resolution.feed.channel;
    final description = podcastArticleText(channel.description);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PodcastArtwork(url: channel.imageUrl, size: 84, radius: 12),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      PodcastRuntime.instance.channelTitle(channel),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (channel.author.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        channel.author,
                        style: const TextStyle(color: AppTokens.text2),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (resolution.message != null) ...[
            const SizedBox(height: 14),
            Text(
              resolution.message!,
              style: PodcastType.prose.copyWith(color: AppTokens.text2),
            ),
          ],
          if (resolution.singleEpisode) ...[
            const SizedBox(height: 8),
            Text(
              '当前链接只能确认这一集的媒体地址，没有找到可持续更新的频道订阅源。',
              style: PodcastType.prose.copyWith(color: AppTokens.text2),
            ),
          ],
          if (description.isNotEmpty) ...[
            const SizedBox(height: 12),
            PodcastEpisodeSummary(text: description),
          ],
          const SizedBox(height: 16),
          Text('节目预览', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '点某一集查看简介。滑到末尾会继续载入。',
            style: PodcastType.prose.copyWith(color: AppTokens.text3),
          ),
        ],
      ),
    );
  }

  Widget _previewFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: PodcastLoadingNotice(message: '正在载入更多节目…')),
      );
    }
    return Padding(
      key: const ValueKey('podcast-discover-more-error'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        _moreError ?? '',
        style: PodcastType.prose.copyWith(color: AppTokens.text2),
      ),
    );
  }

  Widget _previewEpisodeTile(PodcastEpisode episode, {required bool focused}) {
    final channelImage = _preview?.feed.channel.imageUrl ?? '';
    final notes = podcastPlainText(episode.description);
    final meta = [
      if (focused) '你分享的节目',
      podcastDay(episode.publishedMs),
      if (episode.durationMs > 0) podcastTime(episode.durationMs),
      if (episode.media.any((media) => media.isVideo)) '视频',
    ].where((part) => part.isNotEmpty).join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('podcast-discover-episode-${episode.id}'),
        onTap: () {
          unawaited(AppHaptics.cardTap(SettingsService()));
          _openEpisode(episode);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PodcastArtwork(
                url: episode.imageUrl.isEmpty ? channelImage : episode.imageUrl,
                fallbackUrl: episode.imageUrl.isEmpty ? '' : channelImage,
                size: 56,
                radius: 8,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      PodcastRuntime.instance.episodeTitle(episode),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w500,
                        height: 1.4,
                      ),
                    ),
                    if (notes.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        notes,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: PodcastType.prose.copyWith(
                          color: AppTokens.text2,
                        ),
                      ),
                    ],
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        meta,
                        style: const TextStyle(
                          color: AppTokens.text3,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 8, top: 4),
                child: Icon(Icons.chevron_right, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One episode from a search preview. Notes and trial playback stay on this route.
class _PodcastDiscoverEpisodePage extends StatefulWidget {
  const _PodcastDiscoverEpisodePage({
    required this.channelTitle,
    required this.channelImage,
    required this.episode,
  });

  final String channelTitle;
  final String channelImage;
  final PodcastEpisode episode;

  @override
  State<_PodcastDiscoverEpisodePage> createState() =>
      _PodcastDiscoverEpisodePageState();
}

class _PodcastDiscoverEpisodePageState
    extends State<_PodcastDiscoverEpisodePage> {
  VideoPlayerController? _player;
  VideoItem? _previewItem;
  bool _starting = false;
  String? _status;

  /// Clock or scrub target requested before the controller is ready.
  Duration? _pendingSeek;

  /// Bumped on dispose so a late initialize cannot attach a discarded player.
  int _startSerial = 0;

  PodcastMedia? get _media {
    final media = widget.episode.media;
    if (media.isEmpty) return null;
    return media.where((item) => !item.isVideo).firstOrNull ?? media.first;
  }

  @override
  void dispose() {
    _startSerial++;
    final player = _player;
    _player = null;
    _previewItem = null;
    player?.dispose();
    super.dispose();
  }

  Duration _bounded(VideoPlayerController player, Duration target) {
    if (target < Duration.zero) return Duration.zero;
    final duration = player.value.duration;
    if (duration > Duration.zero && target > duration) return duration;
    return target;
  }

  /// Same clock jump as the player notes: the published label, not a parsed cue index.
  Future<void> _seekClock(String clock) =>
      _seekTo(Duration(milliseconds: podcastDuration(clock)));

  Future<void> _seekTo(Duration target) async {
    final player = _player;
    if (player == null || !player.value.isInitialized) {
      _pendingSeek = target;
      if (!_starting) unawaited(_start());
      return;
    }
    await player.seekTo(_bounded(player, target));
  }

  /// Play and pause keep the controller, the way a normal episode does.
  /// Leaving the page is what ends the trial.
  Future<void> _toggle() async {
    final player = _player;
    if (player == null) {
      await _start();
      return;
    }
    if (player.value.isPlaying) {
      await player.pause();
    } else {
      final duration = player.value.duration;
      final atEnd =
          duration > Duration.zero &&
          player.value.position >= duration - const Duration(milliseconds: 300);
      if (atEnd) await player.seekTo(Duration.zero);
      await player.play();
    }
    if (mounted) setState(() {});
  }

  /// Streams this episode without a subscription, queue entry, or progress row.
  Future<void> _start() async {
    final media = _media;
    if (media == null || _starting || _player != null) return;
    final serial = ++_startSerial;
    setState(() {
      _starting = true;
      _status = null;
    });
    VideoPlayerController? player;
    try {
      final session = PodcastRuntime.instance.playback;
      if (session != null && session.isPlaying) {
        await session.pause();
      }
      if (!mounted || serial != _startSerial) return;
      final uri = await PodcastRuntime.instance.controller.mediaStore
          .playbackUri(widget.episode, media);
      if (!mounted || serial != _startSerial) return;
      final item = VideoItem(
        id: 'podcast-preview-${widget.episode.id}',
        path: uri.toString(),
        title: PodcastRuntime.instance.episodeTitle(widget.episode),
        durationMs: widget.episode.durationMs,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
        type: media.isVideo ? MediaType.video : MediaType.audio,
        isTransient: true,
      );
      player = AppVideoPlayerController.networkUrl(
        uri,
        httpHeaders: {
          PodcastPlaybackPolicy.streamHeader: media.isVideo ? 'video' : 'audio',
        },
      );
      await player.initialize().timeout(const Duration(seconds: 8));
      if (!mounted || serial != _startSerial) {
        await player.dispose();
        return;
      }
      _player = player;
      _previewItem = item;
      final pending = _pendingSeek;
      _pendingSeek = null;
      if (pending != null) {
        await player.seekTo(_bounded(player, pending));
      }
      await player.play();
      if (!mounted || serial != _startSerial) return;
      setState(() => _starting = false);
    } catch (_) {
      // dispose() may already have released this controller.
      if (serial == _startSerial) {
        if (identical(_player, player)) _player = null;
        await player?.dispose();
      }
      if (!mounted || serial != _startSerial) return;
      setState(() {
        _starting = false;
        _player = null;
        _previewItem = null;
        _pendingSeek = null;
        _status = '暂时无法试听，请检查网络后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final article = podcastArticleText(episode.description);
    final image = episode.imageUrl.isEmpty
        ? widget.channelImage
        : episode.imageUrl;
    final meta = [
      widget.channelTitle,
      podcastDay(episode.publishedMs),
      if (episode.durationMs > 0) podcastTime(episode.durationMs),
    ].where((part) => part.isNotEmpty).join(' · ');
    final media = _media;
    return PodcastPageShortcuts(
      bindings: {
        LogicalKeyboardKey.space: () {
          if (media != null && !_starting) unawaited(_toggle());
        },
        LogicalKeyboardKey.arrowLeft: () {
          if (media != null) {
            unawaited(
              _seekTo(
                (_player?.value.position ?? Duration.zero) -
                    const Duration(seconds: 5),
              ),
            );
          }
        },
        LogicalKeyboardKey.arrowRight: () {
          if (media != null) {
            unawaited(
              _seekTo(
                (_player?.value.position ?? Duration.zero) +
                    const Duration(seconds: 5),
              ),
            );
          }
        },
      },
      child: PodcastTypography(
        child: Scaffold(
          backgroundColor: AppTokens.bgBase,
          appBar: AppBar(
            backgroundColor: AppTokens.bgBase,
            title: const Text('节目预览'),
          ),
          body: MediaLibrarySafeArea(
            child: Column(
              children: [
                Expanded(
                  child: ListView(
                    key: const ValueKey('podcast-discover-episode-notes'),
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          PodcastArtwork(url: image, size: 88, radius: 12),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  PodcastRuntime.instance.episodeTitle(episode),
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                  ),
                                ),
                                if (meta.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    meta,
                                    style: const TextStyle(
                                      color: AppTokens.text2,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_previewItem != null &&
                          media?.isVideo == true &&
                          _player?.value.isInitialized == true) ...[
                        const SizedBox(height: 18),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: _player!,
                            builder: (context, value, child) => AspectRatio(
                              aspectRatio: value.aspectRatio,
                              child: child,
                            ),
                            child: VideoPlayer(_player!),
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      if (article.isEmpty)
                        Text(
                          '这一集暂无简介。',
                          style: PodcastType.prose.copyWith(
                            color: AppTokens.text2,
                          ),
                        )
                      else
                        PodcastArticleView(
                          source: episode.description,
                          onSeek: media == null ? null : _seekClock,
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_status != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              _status!,
                              style: PodcastType.prose.copyWith(
                                color: AppTokens.text2,
                              ),
                            ),
                          ),
                        _PodcastPreviewTransport(
                          player: _player,
                          fallbackDurationMs: episode.durationMs,
                          starting: _starting,
                          enabled: media != null,
                          onToggle: media == null || _starting ? null : _toggle,
                          onSeek: _seekTo,
                        ),
                      ],
                    ),
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

/// Trial transport: a scrubber over the same frosted action as the player.
///
/// Position ticks stay inside this subtree so the article is not rebuilt
/// on every frame.
class _PodcastPreviewTransport extends StatefulWidget {
  const _PodcastPreviewTransport({
    required this.player,
    required this.fallbackDurationMs,
    required this.starting,
    required this.enabled,
    required this.onToggle,
    required this.onSeek,
  });

  final VideoPlayerController? player;
  final int fallbackDurationMs;
  final bool starting;
  final bool enabled;
  final VoidCallback? onToggle;
  final ValueChanged<Duration> onSeek;

  @override
  State<_PodcastPreviewTransport> createState() =>
      _PodcastPreviewTransportState();
}

class _PodcastPreviewTransportState extends State<_PodcastPreviewTransport> {
  bool _scrubbing = false;
  double _scrub = 0;
  int _span = 0;

  @override
  Widget build(BuildContext context) {
    final player = widget.player;
    if (player == null) {
      return _bar(
        position: Duration.zero,
        duration: Duration(milliseconds: widget.fallbackDurationMs),
        ready: false,
        playing: false,
      );
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, value, _) {
        final duration = value.duration.inMilliseconds > 0
            ? value.duration
            : Duration(milliseconds: widget.fallbackDurationMs);
        return _bar(
          position: value.position,
          duration: duration,
          ready: value.isInitialized,
          playing: value.isInitialized && value.isPlaying,
        );
      },
    );
  }

  Widget _bar({
    required Duration position,
    required Duration duration,
    required bool ready,
    required bool playing,
  }) {
    final totalMs = duration.inMilliseconds;
    final int shownMs = _scrubbing
        ? (_scrub * _span).round()
        : position.inMilliseconds
              .clamp(0, totalMs <= 0 ? 1 << 30 : totalMs)
              .toInt();
    final fraction = totalMs <= 0
        ? 0.0
        : (shownMs / totalMs).clamp(0.0, 1.0).toDouble();
    final canScrub = widget.enabled && !widget.starting && totalMs > 0;
    final label = !widget.enabled
        ? '这一集没有可播放的地址'
        : playing
        ? '暂停试听'
        : ready
        ? '继续试听'
        : '试听这一集';
    final timeStyle = PodcastType.time.copyWith(
      color: Colors.white.withValues(alpha: .62),
      fontSize: 12,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 28,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: _scrubbing ? 5 : 3.5,
              thumbShape: _scrubbing
                  ? const RoundSliderThumbShape(enabledThumbRadius: 6)
                  : SliderComponentShape.noThumb,
              overlayShape: _scrubbing
                  ? const RoundSliderOverlayShape(overlayRadius: 14)
                  : SliderComponentShape.noOverlay,
              activeTrackColor: Colors.white.withValues(alpha: .62),
              inactiveTrackColor: Colors.white.withValues(alpha: .24),
              thumbColor: Colors.white.withValues(alpha: .92),
              overlayColor: Colors.white.withValues(alpha: .10),
            ),
            child: Slider(
              key: const ValueKey('podcast-discover-preview-progress'),
              value: fraction,
              padding: EdgeInsets.zero,
              onChanged: canScrub
                  ? (value) => setState(() => _scrub = value)
                  : null,
              onChangeStart: canScrub
                  ? (value) => setState(() {
                      _scrubbing = true;
                      _scrub = value;
                      _span = totalMs;
                    })
                  : null,
              onChangeEnd: canScrub
                  ? (value) {
                      final span = _span;
                      setState(() => _scrubbing = false);
                      if (span > 0) {
                        widget.onSeek(
                          Duration(milliseconds: (value * span).round()),
                        );
                      }
                    }
                  : null,
            ),
          ),
        ),
        Row(
          children: [
            Text(podcastTime(shownMs), style: timeStyle),
            const Spacer(),
            Text(
              podcastTime(totalMs),
              key: const ValueKey('podcast-discover-preview-duration'),
              style: timeStyle,
            ),
          ],
        ),
        const SizedBox(height: 12),
        _PodcastGlassAction(
          key: const ValueKey('podcast-discover-preview-play'),
          expanded: true,
          icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          onPressed: widget.onToggle,
          label: label,
          textStyle: PodcastType.title.copyWith(fontSize: 15),
        ),
      ],
    );
  }
}

/// Hover-only hints leave touch long-press available for episode selection.
class _PodcastTitleHint extends StatelessWidget {
  const _PodcastTitleHint({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => TooltipTheme(
    data: TooltipTheme.of(context).copyWith(
      triggerMode: TooltipTriggerMode.manual,
      textStyle: PodcastType.meta.copyWith(
        fontSize: 12,
        height: 1.4,
        color: AppTokens.text1,
      ),
      decoration: BoxDecoration(
        color: AppTokens.bgRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTokens.lineSubtle),
      ),
      constraints: BoxConstraints(
        maxWidth: min(360, MediaQuery.sizeOf(context).width - 24),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    child: MediaLibraryTooltip(
      message: title,
      waitDuration: const Duration(milliseconds: 450),
      excludeFromSemantics: true,
      child: child,
    ),
  );
}
