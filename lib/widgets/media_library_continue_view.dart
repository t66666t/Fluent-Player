import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';

import '../models/media_library_group_expand_policy.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../services/app_haptics.dart';
import '../services/library_activity_projection.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import 'cached_thumbnail_widget.dart';
import 'media_library_browse_grid_cards.dart';
import 'media_library_anchor_menu.dart';
import 'media_library_continue_policy_sheet.dart';
import 'media_library_group_header.dart';
import 'media_library_empty_state.dart';
import 'media_library_item_interaction_wrapper.dart';
import 'media_library_gestures.dart';
import 'media_library_layout_profile.dart';
import 'media_library_scroll_viewport.dart';
import 'media_library_list_tile.dart';
import 'media_library_virtual_selection_host.dart';
import 'media_list_layout_metrics.dart';
import 'playback_source_viewport.dart';

/// Continue-learning surface: pins on top, then in-progress groups.
class MediaLibraryContinueView extends StatefulWidget {
  const MediaLibraryContinueView({
    super.key,
    required this.scrollController,
    required this.cardBottomPadding,
    required this.onOpenMedia,
    required this.onOpenFolder,
    required this.onLocateMedia,
    required this.onLocateFolder,
    this.isActive = true,
    this.selection,
    this.onBrowseLibrary,
  });

  final ScrollController scrollController;
  final double cardBottomPadding;
  final ValueChanged<VideoItem> onOpenMedia;
  final ValueChanged<VideoCollection> onOpenFolder;
  final ValueChanged<VideoItem> onLocateMedia;
  final ValueChanged<VideoCollection> onLocateFolder;
  final VoidCallback? onBrowseLibrary;

  /// Hidden keep-alive copies skip Provider watches and reuse the last tree.
  final bool isActive;

  /// Null keeps the page read-only (tests / keep-alive copies).
  final MediaLibraryVirtualSelectionBinding? selection;

  @override
  State<MediaLibraryContinueView> createState() =>
      _MediaLibraryContinueViewState();
}

class _MediaLibraryContinueViewState extends State<MediaLibraryContinueView> {
  final MediaLibraryGroupExpandMemory _expand = MediaLibraryGroupExpandMemory();
  final Map<String, GlobalKey> _headerKeys = <String, GlobalKey>{};
  List<String> _frozenRecentKeys = <String>[];
  List<String> _frozenUnknownKeys = <String>[];
  List<String> _frozenHistoryDayKeys = <String>[];
  bool _wasRouteCurrent = true;
  Widget? _frozenSubtree;
  LibraryService? _library;
  bool _libraryChangedWhileAway = false;
  bool _tryReuseFrozen = false;
  int? _frozenViewMode;
  double? _frozenBottomPadding;
  bool? _frozenSeriousOnly;
  String? _frozenSelectionToken;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final library = context.read<LibraryService>();
    if (!identical(library, _library)) {
      _library?.removeListener(_onLibraryQuiet);
      _library = library;
      _library!.addListener(_onLibraryQuiet);
    }
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (isCurrent && !_wasRouteCurrent) {
      _frozenRecentKeys = <String>[];
      _frozenUnknownKeys = <String>[];
      _frozenHistoryDayKeys = <String>[];
      _expand.clear();
      _tryReuseFrozen = false;
    }
    _wasRouteCurrent = isCurrent;
  }

  @override
  void didUpdateWidget(covariant MediaLibraryContinueView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _tryReuseFrozen = true;
    }
  }

  @override
  void dispose() {
    _library?.removeListener(_onLibraryQuiet);
    super.dispose();
  }

  void _onLibraryQuiet() {
    if (!mounted || widget.isActive) return;
    _libraryChangedWhileAway = true;
  }

  /// Folder cards vibrate because [LongPressDraggable] starts a drag. These
  /// cards only enter selection, so the click has to be fired here. Pin
  /// reorder keeps its own pulse and does not call this.
  void _enterSelection(String id) {
    final selection = widget.selection;
    if (selection == null) return;
    unawaited(AppHaptics.selectionClick(SettingsService()));
    selection.onEnter(id);
  }

  List<ContinueLearningGroup> _stabilize(
    List<String> frozen,
    List<ContinueLearningGroup> live,
  ) {
    final liveMap = <String, ContinueLearningGroup>{
      for (final group in live) group.rowId: group,
    };
    final out = <ContinueLearningGroup>[];
    for (final key in frozen) {
      final group = liveMap.remove(key);
      if (group != null) out.add(group);
    }
    for (final group in live) {
      if (liveMap.containsKey(group.rowId)) out.add(group);
    }
    return out;
  }

  List<PlaybackHistoryDayGroup> _stabilizeDays(
    List<String> frozen,
    List<PlaybackHistoryDayGroup> live,
  ) {
    final liveMap = <String, PlaybackHistoryDayGroup>{
      for (final group in live) group.rowId: group,
    };
    final out = <PlaybackHistoryDayGroup>[];
    for (final key in frozen) {
      final group = liveMap.remove(key);
      if (group != null) out.add(group);
    }
    for (final group in live) {
      if (liveMap.containsKey(group.rowId)) out.add(group);
    }
    return out;
  }

  String _folderTitle(LibraryService library, ContinueLearningGroup group) {
    if (group.parentId == null) return '根目录';
    return library.getCollection(group.parentId!)?.name ?? '未知目录';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive) {
      context.read<LibraryService>();
      context.read<SettingsService>();
      _tryReuseFrozen = false;
      return _frozenSubtree ?? const SizedBox.expand();
    }
    final library = context.read<LibraryService>();
    context.select<LibraryService, (int, int)>(
      (service) => (service.browseRevision, service.activityRevision.value),
    );
    final settings = context.watch<SettingsService>();
    final selectionToken = widget.selection?.freezeToken ?? 'off';
    if (_tryReuseFrozen &&
        _frozenSubtree != null &&
        !_libraryChangedWhileAway &&
        _frozenViewMode == settings.mediaLibraryViewMode &&
        _frozenBottomPadding == widget.cardBottomPadding &&
        _frozenSeriousOnly == settings.mediaLibraryContinueSeriousOnly &&
        _frozenSelectionToken == selectionToken) {
      _tryReuseFrozen = false;
      _libraryChangedWhileAway = false;
      return _frozenSubtree!;
    }
    _tryReuseFrozen = false;
    _libraryChangedWhileAway = false;
    final projection = library.activityProjection;
    final seriousOnly = settings.mediaLibraryContinueSeriousOnly;
    final pins = projection.visiblePinnedIds();
    final sections = projection.continueLearningSections(
      policy: settings.continueWatchPolicy,
    );
    final recent = _stabilize(_frozenRecentKeys, sections.recent);
    final unknown = _stabilize(_frozenUnknownKeys, sections.unknown);
    final historyDays = _stabilizeDays(
      _frozenHistoryDayKeys,
      projection.playbackHistoryDayGroups(),
    );
    _frozenRecentKeys = recent.map((group) => group.rowId).toList();
    _frozenUnknownKeys = unknown.map((group) => group.rowId).toList();
    _frozenHistoryDayKeys = historyDays.map((group) => group.rowId).toList();
    final recordsEmpty = seriousOnly
        ? recent.isEmpty && unknown.isEmpty
        : historyDays.isEmpty;

    final useList = settings.mediaLibraryViewMode == 1;
    final flow = _flowSpacing(settings, useList);
    final ordered = <String>[
      ...pins,
      if (seriousOnly) ...[
        ..._visibleSeriousIds(recent, section: 'recent'),
        ..._visibleSeriousIds(unknown, section: 'unknown'),
      ] else
        ..._visibleHistoryIds(historyDays),
    ];
    widget.selection?.host.updateOrderedIds(ordered);
    _frozenViewMode = settings.mediaLibraryViewMode;
    _frozenBottomPadding = widget.cardBottomPadding;
    _frozenSeriousOnly = seriousOnly;
    _frozenSelectionToken = selectionToken;
    _frozenSubtree = Material(
      color: Colors.transparent,
      child: CustomScrollView(
        scrollCacheExtent: const ScrollCacheExtent.viewport(1),
        controller: widget.scrollController,
        slivers: [
          if (pins.isNotEmpty || !recordsEmpty || historyDays.isNotEmpty)
            SliverToBoxAdapter(child: _filterTile(settings, flow)),
          if (pins.isEmpty && recordsEmpty)
            SliverFillRemaining(
              hasScrollBody: true,
              child: _emptyBody(seriousOnly, historyDays.isNotEmpty),
            )
          else ...[
            if (pins.isNotEmpty) ...[
              ..._sectionSlivers(
                flow,
                title: '置顶',
                beforeTitle: flow.attached,
                body: [
                  _idGridOrListSliver(
                    regionId: 'pins',
                    library: library,
                    settings: settings,
                    ids: pins,
                    useList: useList,
                    pinMode: true,
                  ),
                ],
              ),
            ],
            if (seriousOnly) ...[
              if (recent.isNotEmpty)
                ..._sectionSlivers(
                  flow,
                  title: '最近在看',
                  beforeTitle: pins.isEmpty ? flow.attached : flow.section,
                  body: _seriousGroupSlivers(
                    library,
                    settings,
                    recent,
                    useList,
                    flow,
                    section: 'recent',
                  ),
                ),
              if (unknown.isNotEmpty)
                ..._sectionSlivers(
                  flow,
                  title: '之前未看完',
                  beforeTitle: pins.isEmpty && recent.isEmpty
                      ? flow.attached
                      : flow.section,
                  body: _seriousGroupSlivers(
                    library,
                    settings,
                    unknown,
                    useList,
                    flow,
                    section: 'unknown',
                  ),
                ),
            ] else ...[
              for (var i = 0; i < historyDays.length; i++)
                ..._daySlivers(
                  library,
                  settings,
                  historyDays[i],
                  historyDays,
                  useList,
                  flow,
                  beforeHeader: i == 0 && pins.isEmpty
                      ? flow.attached
                      : flow.section,
                ),
            ],
            SliverToBoxAdapter(
              child: SizedBox(height: 24 + widget.cardBottomPadding),
            ),
          ],
        ],
      ),
    );
    return _frozenSubtree!;
  }

  MediaLibraryFlowSpacing _flowSpacing(SettingsService settings, bool useList) {
    final screenSize = MediaQuery.sizeOf(context);
    return mediaLibraryFlowSpacingFor(
      screenSize: Size(
        MediaLibraryScrollViewport.contentWidthOf(context),
        screenSize.height,
      ),
      useList: useList,
      cardStyle: settings.collectionCardStyleFor(screenSize),
      listStyle: settings.listStyleFor(screenSize),
    );
  }

  /// Same visibility rules as the slivers: collapsed groups keep the featured
  /// card only; collapsed history days contribute nothing.
  List<String> _visibleSeriousIds(
    List<ContinueLearningGroup> groups, {
    required String section,
  }) {
    final out = <String>[];
    for (final group in groups) {
      final count = group.mediaIds.length;
      final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
      if (group.parentId == null || flat) {
        out.addAll(group.mediaIds);
        continue;
      }
      final expanded = _expand.isExpanded(
        '$section:${group.rowId}',
        defaultExpanded: false,
      );
      out.add(group.featuredMediaId);
      if (expanded) {
        out.addAll(group.mediaIds.skip(1));
      }
    }
    return out;
  }

  List<String> _visibleHistoryIds(List<PlaybackHistoryDayGroup> days) {
    final out = <String>[];
    for (final day in days) {
      final count = day.mediaIds.length;
      final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
      final expanded =
          flat ||
          _expand.isExpanded(
            day.rowId,
            defaultExpanded:
                MediaLibraryGroupExpandPolicy.historyDefaultExpanded(
                  count: count,
                  dayStartMs: day.dayStartMs,
                ),
          );
      if (expanded) out.addAll(day.mediaIds);
    }
    return out;
  }

  List<Widget> _sectionSlivers(
    MediaLibraryFlowSpacing flow, {
    required String title,
    required double beforeTitle,
    required List<Widget> body,
  }) {
    return [
      ?flow.gap(beforeTitle),
      SliverToBoxAdapter(
        child: _SectionHeader(title: title, horizontalPadding: flow.outer),
      ),
      ?flow.gap(flow.attached),
      ...body,
    ];
  }

  Widget _filterTile(SettingsService settings, MediaLibraryFlowSpacing flow) {
    final on = settings.mediaLibraryContinueSeriousOnly;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.fromLTRB(flow.outer, flow.leading, flow.outer, 0),
        child: _ContinueFilterPill(
          active: on,
          onToggleSeriousOnly: () {
            setState(() {
              _frozenRecentKeys = <String>[];
              _frozenUnknownKeys = <String>[];
              _frozenHistoryDayKeys = <String>[];
              _expand.clear();
            });
            unawaited(
              settings.updateSetting('mediaLibraryContinueSeriousOnly', !on),
            );
          },
          onOpenPolicy: () {
            unawaited(MediaLibraryContinuePolicySheet.show(context));
          },
        ),
      ),
    );
  }

  Widget _emptyBody(bool seriousOnly, bool hasHistory) {
    final text = seriousOnly
        ? (hasHistory ? '暂无符合筛选条件的内容' : '暂无可继续观看的内容')
        : '暂无播放记录';
    return MediaLibraryEmptyState(
      icon: Icons.play_circle_outline_rounded,
      message: text,
      actionLabel: '浏览媒体库',
      onAction: widget.onBrowseLibrary,
      bottomPadding: widget.cardBottomPadding,
    );
  }

  List<Widget> _seriousGroupSlivers(
    LibraryService library,
    SettingsService settings,
    List<ContinueLearningGroup> groups,
    bool useList,
    MediaLibraryFlowSpacing flow, {
    required String section,
  }) {
    final slivers = <Widget>[];
    final rootIds = <String>[];
    var rootRegion = 0;
    void flushRoot() {
      if (rootIds.isEmpty) return;
      if (slivers.isNotEmpty) flow.addGap(slivers, flow.block);
      slivers.add(
        _idGridOrListSliver(
          regionId: (section, 'root', rootRegion++),
          library: library,
          settings: settings,
          ids: List<String>.from(rootIds),
          useList: useList,
        ),
      );
      rootIds.clear();
    }

    for (final group in groups) {
      if (group.parentId == null) {
        rootIds.addAll(group.mediaIds);
        continue;
      }
      flushRoot();
      if (slivers.isNotEmpty) flow.addGap(slivers, flow.block);
      slivers.addAll(
        _groupSlivers(
          library,
          settings,
          group,
          groups,
          useList,
          flow,
          section: section,
        ),
      );
    }
    flushRoot();
    return slivers;
  }

  List<Widget> _daySlivers(
    LibraryService library,
    SettingsService settings,
    PlaybackHistoryDayGroup day,
    List<PlaybackHistoryDayGroup> siblings,
    bool useList,
    MediaLibraryFlowSpacing flow, {
    required double beforeHeader,
  }) {
    final count = day.mediaIds.length;
    final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
    final expanded =
        flat ||
        _expand.isExpanded(
          day.rowId,
          defaultExpanded: MediaLibraryGroupExpandPolicy.historyDefaultExpanded(
            count: count,
            dayStartMs: day.dayStartMs,
          ),
        );
    final covers = _coverItems(library, day.mediaIds);
    final header = SliverToBoxAdapter(
      key: ValueKey(day.rowId),
      child: KeyedSubtree(
        key: _headerKey(day.rowId),
        child: MediaLibraryGroupHeader(
          title: '${day.label}·$count项',
          coverItems: covers,
          expanded: expanded,
          padding: EdgeInsets.symmetric(horizontal: flow.outer),
          showChevron: !flat,
          remainderCount: expanded ? 0 : count,
          onToggle: flat
              ? null
              : () => _toggleGroup(
                  rowId: day.rowId,
                  currentlyExpanded: expanded,
                  memberCount: count,
                  siblingCounts: {
                    for (final other in siblings)
                      other.rowId: other.mediaIds.length,
                  },
                ),
        ),
      ),
    );
    if (!expanded) {
      return [?flow.gap(beforeHeader), header];
    }
    return [
      ?flow.gap(beforeHeader),
      header,
      ?flow.gap(flow.attached),
      _idGridOrListSliver(
        regionId: ('history', day.rowId),
        library: library,
        settings: settings,
        ids: day.mediaIds,
        useList: useList,
      ),
    ];
  }

  Widget _idGridOrListSliver({
    required Object regionId,
    required LibraryService library,
    required SettingsService settings,
    required List<String> ids,
    required bool useList,
    bool pinMode = false,
  }) {
    if (ids.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    if (useList) {
      final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
      final metrics = MediaListLayoutMetrics.forGrid(
        screenShortestSide: MediaQuery.sizeOf(context).shortestSide,
        availableWidth: MediaLibraryScrollViewport.contentWidthOf(context),
        crossAxisCount: listStyle.crossAxisCount,
        heightSetting: listStyle.heightScale,
        titleSetting: listStyle.titleScale,
        mainSpacingSetting: listStyle.mainSpacingScale,
        crossSpacingSetting: listStyle.crossSpacingScale,
      );
      return SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: metrics.outerPadding),
        sliver: PlaybackSliverGrid(
          regionId: regionId,
          itemCount: ids.length,
          itemKey: (index) => ids[index],
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: listStyle.crossAxisCount,
            mainAxisExtent: metrics.rowHeight,
            crossAxisSpacing: metrics.crossSpacing,
            mainAxisSpacing: metrics.mainSpacing,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            return MediaCoverRevealStamp(
              index: index,
              crossAxisCount: listStyle.crossAxisCount,
              child: _pinTile(
                library,
                settings,
                ids[index],
                true,
                allowHide: !pinMode,
                pinIndex: pinMode ? index : null,
                pinCount: pinMode ? ids.length : 0,
              ),
            );
          }, childCount: ids.length),
        ),
      );
    }
    final cardMetrics = MediaLibraryLayoutDefaults.cardGrid(
      textScaler: MediaQuery.textScalerOf(context),
      textStyle: DefaultTextStyle.of(context).style,
      screenSize: Size(
        MediaLibraryScrollViewport.contentWidthOf(context),
        MediaQuery.sizeOf(context).height,
      ),
      style: settings.collectionCardStyleFor(MediaQuery.sizeOf(context)),
    );
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: cardMetrics.outerPadding),
      sliver: PlaybackSliverGrid(
        regionId: regionId,
        itemCount: ids.length,
        itemKey: (index) => ids[index],
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cardMetrics.crossAxisCount,
          childAspectRatio: cardMetrics.aspectRatio.clamp(0.1, 5.0),
          crossAxisSpacing: cardMetrics.crossSpacing,
          mainAxisSpacing: cardMetrics.mainSpacing,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          return MediaCoverRevealStamp(
            index: index,
            crossAxisCount: cardMetrics.crossAxisCount,
            child: _pinTile(
              library,
              settings,
              ids[index],
              false,
              allowHide: !pinMode,
              pinIndex: pinMode ? index : null,
              pinCount: pinMode ? ids.length : 0,
            ),
          );
        }, childCount: ids.length),
      ),
    );
  }

  Duration get _pinDragDelay => mediaLibraryLongPressDelay;

  Widget _pinTile(
    LibraryService library,
    SettingsService settings,
    String id,
    bool useList, {
    bool allowHide = true,
    int? pinIndex,
    int pinCount = 0,
  }) {
    final collection = library.getCollection(id);
    late final Widget tile;
    late final VoidCallback onOpen;
    if (collection != null) {
      tile = _folderPin(library, settings, collection, useList);
      onOpen = () => widget.onOpenFolder(collection);
    } else {
      final item = library.getVideo(id);
      if (item == null) return const SizedBox.shrink();
      tile = _mediaCard(library, settings, item, useList, allowHide: allowHide);
      onOpen = () => widget.onOpenMedia(item);
    }
    final keyed = KeyedSubtree(
      key: widget.selection?.host.keyFor(id),
      child: tile,
    );
    final selecting = widget.selection?.isSelectionMode == true;
    if (selecting || pinIndex == null || pinCount < 2) return keyed;
    return MediaLibraryPinnedReorderWrapper(
      key: ValueKey('continue-pin-$id'),
      visibleIndex: pinIndex,
      dragDelay: _pinDragDelay,
      onTap: onOpen,
      onDragStarted: () {
        unawaited(AppHaptics.reorderDragStarted(settings));
      },
      onReorder: (from, to) {
        unawaited(library.reorderVisiblePinnedLibraryItems(from, to));
      },
      child: keyed,
    );
  }

  Widget _folderPin(
    LibraryService library,
    SettingsService settings,
    VideoCollection collection,
    bool useList,
  ) {
    final selection = widget.selection;
    final selected = selection?.isSelected(collection.id) ?? false;
    final selecting = selection?.isSelectionMode ?? false;
    void open() {
      if (selecting) {
        selection!.onToggle(collection.id);
        return;
      }
      widget.onOpenFolder(collection);
    }

    if (useList) {
      return SizedBox(
        height: 72,
        child: MediaLibraryListTile.collection(
          collection: collection,
          index: 0,
          showIndex: false,
          showThumbnail: true,
          isSelected: selected,
          isSelectionMode: selecting,
          titleScale: settings
              .listStyleFor(MediaQuery.sizeOf(context))
              .titleScale,
          onTap: open,
          onLongPress: selection == null || selecting
              ? null
              : () => _enterSelection(collection.id),
          onSecondaryTap: selection == null
              ? null
              : () => selection.onSecondaryTap(collection.id),
          onSelectionTap: selection == null
              ? null
              : () => selection.onToggle(collection.id),
          onSelectionPanStart: selection == null
              ? null
              : (details) => selection.onRangeStart(
                  collection.id,
                  details.globalPosition,
                ),
          onSelectionPanUpdate: selection == null
              ? null
              : (details) => selection.onRangeUpdate(details.globalPosition),
          onSelectionPanEnd: selection == null
              ? null
              : (_) => selection.onRangeEnd(),
          onSelectionLongPressStart: selection == null
              ? null
              : (details) => selection.onRangeStart(
                  collection.id,
                  details.globalPosition,
                ),
          onSelectionLongPressMoveUpdate: selection == null
              ? null
              : (details) => selection.onRangeUpdate(details.globalPosition),
          onSelectionLongPressEnd: selection == null
              ? null
              : (_) => selection.onRangeEnd(),
          onShowInParentFolder: () => widget.onLocateFolder(collection),
          showActivityMenu: !selecting,
          allowHide: false,
        ),
      );
    }
    return MediaLibraryFolderGridCard(
      collection: collection,
      titleScale: settings
          .collectionCardStyleFor(MediaQuery.sizeOf(context))
          .titleScale,
      onTap: open,
      onLocate: () => widget.onLocateFolder(collection),
      showActivityMenu: !selecting,
      isSelected: selected,
      isSelectionMode: selecting,
      onSecondaryTap: selection == null
          ? null
          : () => selection.onSecondaryTap(collection.id),
      onSelectionTap: selection == null
          ? null
          : () => selection.onToggle(collection.id),
      onSelectionPanStart: selection == null
          ? null
          : (details) =>
                selection.onRangeStart(collection.id, details.globalPosition),
      onSelectionPanUpdate: selection == null
          ? null
          : (details) => selection.onRangeUpdate(details.globalPosition),
      onSelectionPanEnd: selection == null
          ? null
          : (_) => selection.onRangeEnd(),
      onSelectionLongPressStart: selection == null
          ? null
          : (details) =>
                selection.onRangeStart(collection.id, details.globalPosition),
      onSelectionLongPressMoveUpdate: selection == null
          ? null
          : (details) => selection.onRangeUpdate(details.globalPosition),
      onSelectionLongPressEnd: selection == null
          ? null
          : (_) => selection.onRangeEnd(),
      onLongPress: selection == null || selecting
          ? null
          : () => _enterSelection(collection.id),
    );
  }

  List<Widget> _groupSlivers(
    LibraryService library,
    SettingsService settings,
    ContinueLearningGroup group,
    List<ContinueLearningGroup> siblings,
    bool useList,
    MediaLibraryFlowSpacing flow, {
    required String section,
  }) {
    // One folder can have both dated and legacy progress. Those rows are
    // siblings in the same viewport and need separate keys and expand state.
    final rowId = '$section:${group.rowId}';
    final ids = group.mediaIds;
    final count = ids.length;
    final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
    final expanded = flat || _expand.isExpanded(rowId, defaultExpanded: false);
    final featured = library.getVideo(group.featuredMediaId);
    final rest = ids.skip(1).toList(growable: false);
    final collection = group.parentId == null
        ? null
        : library.getCollection(group.parentId!);
    final header = SliverToBoxAdapter(
      key: ValueKey(rowId),
      child: KeyedSubtree(
        key: _headerKey(rowId),
        child: MediaLibraryGroupHeader(
          title: '${_folderTitle(library, group)}·当前$count项',
          subtitle: _resumeSubtitle(featured),
          coverItems: _coverItems(library, ids),
          expanded: expanded,
          padding: EdgeInsets.symmetric(horizontal: flow.outer),
          showChevron: !flat && rest.isNotEmpty,
          remainderCount: rest.length,
          progress: _progressOf(featured),
          onOpenFolder: collection == null
              ? null
              : () => widget.onOpenFolder(collection),
          onToggle: flat || rest.isEmpty
              ? null
              : () => _toggleGroup(
                  rowId: rowId,
                  currentlyExpanded: expanded,
                  memberCount: count,
                  siblingCounts: {
                    for (final other in siblings)
                      '$section:${other.rowId}': other.mediaIds.length,
                  },
                ),
        ),
      ),
    );
    if (flat) {
      return [
        header,
        ?flow.gap(flow.attached),
        _idGridOrListSliver(
          regionId: (rowId, 'all'),
          library: library,
          settings: settings,
          ids: ids,
          useList: useList,
        ),
      ];
    }
    return [
      header,
      ?flow.gap(flow.attached),
      _idGridOrListSliver(
        regionId: (rowId, 'featured'),
        library: library,
        settings: settings,
        ids: <String>[group.featuredMediaId],
        useList: useList,
      ),
      if (expanded && rest.isNotEmpty) ...[
        ?flow.gap(flow.row),
        _idGridOrListSliver(
          regionId: (rowId, 'rest'),
          library: library,
          settings: settings,
          ids: rest,
          useList: useList,
        ),
      ],
    ];
  }

  List<VideoItem> _coverItems(LibraryService library, List<String> ids) {
    final out = <VideoItem>[];
    for (final id in ids) {
      if (out.length >= MediaLibraryGroupExpandPolicy.coverPreviewMax) break;
      final item = library.getVideo(id);
      if (item != null) out.add(item);
    }
    return out;
  }

  String? _resumeSubtitle(VideoItem? item) {
    if (item == null) return null;
    if (item.lastPositionMs <= 0) return item.title;
    return '${item.title} · ${MediaLibraryMediaGridCard.durationLabel(item.lastPositionMs)}';
  }

  double? _progressOf(VideoItem? item) {
    if (item == null || item.durationMs <= 0 || item.lastPositionMs <= 0) {
      return null;
    }
    return item.lastPositionMs / item.durationMs;
  }

  GlobalKey _headerKey(String rowId) {
    return _headerKeys.putIfAbsent(rowId, GlobalKey.new);
  }

  void _pinHeader(String rowId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _headerKeys[rowId]?.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.06,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _toggleGroup({
    required String rowId,
    required bool currentlyExpanded,
    required int memberCount,
    required Map<String, int> siblingCounts,
  }) {
    setState(() {
      _expand.toggle(rowId, currentlyExpanded: currentlyExpanded);
      if (!currentlyExpanded &&
          MediaLibraryGroupExpandPolicy.isHuge(memberCount)) {
        siblingCounts.forEach((id, count) {
          if (id == rowId) return;
          if (MediaLibraryGroupExpandPolicy.isHuge(count)) {
            _expand.collapse(id);
          }
        });
      }
    });
    if (!currentlyExpanded &&
        memberCount >
            MediaLibraryGroupExpandPolicy.recentLatestAutoExpandMaxItems) {
      _pinHeader(rowId);
    }
  }

  Widget _mediaCard(
    LibraryService library,
    SettingsService settings,
    VideoItem item,
    bool useList, {
    bool allowHide = true,
  }) {
    final selection = widget.selection;
    final selected = selection?.isSelected(item.id) ?? false;
    final selecting = selection?.isSelectionMode ?? false;
    void open() {
      if (selecting) {
        selection!.onToggle(item.id);
        return;
      }
      widget.onOpenMedia(item);
    }

    final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
    if (useList) {
      return MediaLibraryListTile.video(
        item: item,
        index: 0,
        showIndex: listStyle.showIndex,
        showThumbnail: listStyle.showThumbnail,
        isSelected: selected,
        isSelectionMode: selecting,
        titleScale: listStyle.titleScale,
        onTap: open,
        onLongPress: selection == null || selecting
            ? null
            : () => _enterSelection(item.id),
        onSecondaryTap: selection == null
            ? null
            : () => selection.onSecondaryTap(item.id),
        onSelectionTap: selection == null
            ? null
            : () => selection.onToggle(item.id),
        onSelectionPanStart: selection == null
            ? null
            : (details) =>
                  selection.onRangeStart(item.id, details.globalPosition),
        onSelectionPanUpdate: selection == null
            ? null
            : (details) => selection.onRangeUpdate(details.globalPosition),
        onSelectionPanEnd: selection == null
            ? null
            : (_) => selection.onRangeEnd(),
        onSelectionLongPressStart: selection == null
            ? null
            : (details) =>
                  selection.onRangeStart(item.id, details.globalPosition),
        onSelectionLongPressMoveUpdate: selection == null
            ? null
            : (details) => selection.onRangeUpdate(details.globalPosition),
        onSelectionLongPressEnd: selection == null
            ? null
            : (_) => selection.onRangeEnd(),
        onShowInParentFolder: () => widget.onLocateMedia(item),
        showActivityMenu: !selecting,
        allowHide: allowHide && !selecting,
        relativePath: MediaLibraryMediaGridCard.pathFromLibraryRoot(
          library,
          item,
        ),
      );
    }
    return MediaLibraryMediaGridCard(
      item: item,
      titleScale: settings
          .collectionCardStyleFor(MediaQuery.sizeOf(context))
          .titleScale,
      onTap: open,
      onLocate: () => widget.onLocateMedia(item),
      allowHide: allowHide && !selecting,
      showActivityMenu: !selecting,
      isSelected: selected,
      isSelectionMode: selecting,
      onSecondaryTap: selection == null
          ? null
          : () => selection.onSecondaryTap(item.id),
      onSelectionTap: selection == null
          ? null
          : () => selection.onToggle(item.id),
      onSelectionPanStart: selection == null
          ? null
          : (details) =>
                selection.onRangeStart(item.id, details.globalPosition),
      onSelectionPanUpdate: selection == null
          ? null
          : (details) => selection.onRangeUpdate(details.globalPosition),
      onSelectionPanEnd: selection == null
          ? null
          : (_) => selection.onRangeEnd(),
      onSelectionLongPressStart: selection == null
          ? null
          : (details) =>
                selection.onRangeStart(item.id, details.globalPosition),
      onSelectionLongPressMoveUpdate: selection == null
          ? null
          : (details) => selection.onRangeUpdate(details.globalPosition),
      onSelectionLongPressEnd: selection == null
          ? null
          : (_) => selection.onRangeEnd(),
      onLongPress: selection == null || selecting
          ? null
          : () => _enterSelection(item.id),
      relativePath: MediaLibraryMediaGridCard.pathFromLibraryRoot(
        library,
        item,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.horizontalPadding});

  final String title;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Compact filter pill. Options open beside it, same popover as card ⋯.
class _ContinueFilterPill extends StatefulWidget {
  const _ContinueFilterPill({
    required this.active,
    required this.onToggleSeriousOnly,
    required this.onOpenPolicy,
  });

  static const Color _accent = Color(0xFF0A84FF);

  final bool active;
  final VoidCallback onToggleSeriousOnly;
  final VoidCallback onOpenPolicy;

  @override
  State<_ContinueFilterPill> createState() => _ContinueFilterPillState();
}

class _ContinueFilterPillState extends State<_ContinueFilterPill> {
  bool _opening = false;

  Future<void> _openMenu() async {
    if (_opening || !mounted) return;
    _opening = true;
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.maybeOf(context, rootOverlay: true)?.context.findRenderObject()
            as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) {
      _opening = false;
      return;
    }
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final anchor = origin & box.size;
    try {
      final choice = await MediaLibraryAnchorMenu.show(
        context: context,
        anchor: anchor,
        alignStart: true,
        items: [
          MediaLibraryAnchorMenuEntry(
            key: const ValueKey('continueFilterSeriousOnly'),
            value: 'toggle',
            label: '只看未完成',
            icon: widget.active
                ? Icons.check_box_outlined
                : Icons.check_box_outline_blank,
            checked: widget.active,
          ),
          const MediaLibraryAnchorMenuEntry(
            key: ValueKey('continueFilterPolicy'),
            value: 'policy',
            label: '门槛设置',
            icon: Icons.tune,
          ),
        ],
      );
      if (!mounted || choice == null) return;
      if (choice == 'toggle') widget.onToggleSeriousOnly();
      if (choice == 'policy') widget.onOpenPolicy();
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final label = active ? '继续观看' : '全部记录';
    final accent = active
        ? _ContinueFilterPill._accent
        : const Color(0xFFEBEBF5);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('continueFilterMenu'),
        borderRadius: BorderRadius.circular(20),
        onTap: () => unawaited(_openMenu()),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3C).withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.filter_list,
                      size: 14,
                      color: accent.withValues(alpha: active ? 1 : 0.62),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.2,
                        color: accent.withValues(alpha: active ? 1 : 0.72),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 16,
                      color: accent.withValues(alpha: 0.45),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
