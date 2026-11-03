import 'dart:async';

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
import 'media_library_group_header.dart';
import 'media_library_empty_state.dart';
import 'media_library_layout_profile.dart';
import 'media_library_scroll_viewport.dart';
import 'media_library_list_tile.dart';
import 'media_library_virtual_selection_host.dart';
import 'media_list_layout_metrics.dart';
import 'playback_source_viewport.dart';

/// Recently-added surface hosted by HomeScreen. Batches are grouping chrome,
/// not folders, and members are built lazily.
class MediaLibraryRecentView extends StatefulWidget {
  const MediaLibraryRecentView({
    super.key,
    required this.scrollController,
    required this.cardBottomPadding,
    required this.onOpenMedia,
    required this.onLocateMedia,
    required this.onOpenFolder,
    required this.onLocateFolder,
    this.expandBatchId,
    this.isActive = true,
    this.selection,
    this.onBrowseLibrary,
  });

  final ScrollController scrollController;
  final double cardBottomPadding;
  final ValueChanged<VideoItem> onOpenMedia;
  final ValueChanged<VideoItem> onLocateMedia;
  final ValueChanged<VideoCollection> onOpenFolder;
  final ValueChanged<VideoCollection> onLocateFolder;
  final VoidCallback? onBrowseLibrary;
  final String? expandBatchId;

  /// Hidden keep-alive copies skip Provider watches and reuse the last tree.
  final bool isActive;

  /// Null keeps the page read-only (tests / keep-alive copies).
  final MediaLibraryVirtualSelectionBinding? selection;

  @override
  State<MediaLibraryRecentView> createState() => _MediaLibraryRecentViewState();
}

class _MediaLibraryRecentViewState extends State<MediaLibraryRecentView> {
  final MediaLibraryGroupExpandMemory _expand = MediaLibraryGroupExpandMemory();
  final Map<String, GlobalKey> _headerKeys = <String, GlobalKey>{};
  String? _appliedExpandBatchId;
  Widget? _frozenSubtree;
  LibraryService? _library;
  bool _libraryChangedWhileAway = false;
  bool _tryReuseFrozen = false;
  int? _frozenViewMode;
  double? _frozenBottomPadding;
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
  }

  @override
  void didUpdateWidget(covariant MediaLibraryRecentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expandBatchId != widget.expandBatchId) {
      _appliedExpandBatchId = null;
      _tryReuseFrozen = false;
    }
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

  /// Same selection click as a folder-card long press. These rows are not
  /// draggable, so the framework will not pulse for them.
  void _enterSelection(String id) {
    final selection = widget.selection;
    if (selection == null) return;
    unawaited(AppHaptics.selectionClick(SettingsService()));
    selection.onEnter(id);
  }

  void _expandRequestedBatch(List<RecentAddedEntry> entries) {
    final batchId = widget.expandBatchId;
    if (batchId == null || batchId.isEmpty) return;
    if (_appliedExpandBatchId == batchId) return;
    _appliedExpandBatchId = batchId;
    for (final entry in entries) {
      if (entry.sourceBatchId == batchId || entry.rowId == 'batch:$batchId') {
        _expand.forceOpen(entry.rowId);
      }
    }
  }

  bool _canReuseFrozen(SettingsService settings) {
    return _tryReuseFrozen &&
        _frozenSubtree != null &&
        !_libraryChangedWhileAway &&
        _frozenViewMode == settings.mediaLibraryViewMode &&
        _frozenBottomPadding == widget.cardBottomPadding &&
        _frozenSelectionToken == (widget.selection?.freezeToken ?? 'off');
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
    if (_canReuseFrozen(settings)) {
      _tryReuseFrozen = false;
      _libraryChangedWhileAway = false;
      return _frozenSubtree!;
    }
    _tryReuseFrozen = false;
    _libraryChangedWhileAway = false;
    final entries = library.activityProjection.recentAddedEntries();
    _expandRequestedBatch(entries);
    widget.selection?.host.updateOrderedIds(_visibleChildIds(entries));

    if (entries.isEmpty) {
      _frozenViewMode = settings.mediaLibraryViewMode;
      _frozenBottomPadding = widget.cardBottomPadding;
      _frozenSelectionToken = widget.selection?.freezeToken ?? 'off';
      _frozenSubtree = MediaLibraryEmptyState(
        icon: Icons.video_library_outlined,
        message: '暂无最近添加的内容',
        actionLabel: '浏览媒体库',
        onAction: widget.onBrowseLibrary,
        bottomPadding: widget.cardBottomPadding,
      );
      return _frozenSubtree!;
    }

    final useList = settings.mediaLibraryViewMode == 1;
    final screenSize = MediaQuery.sizeOf(context);
    // Match 文件夹: first-row inset equals mainSpacing so cards sit off the app bar.
    final flow = _flowSpacing(settings, screenSize, useList);
    _frozenViewMode = settings.mediaLibraryViewMode;
    _frozenBottomPadding = widget.cardBottomPadding;
    _frozenSelectionToken = widget.selection?.freezeToken ?? 'off';
    _frozenSubtree = CustomScrollView(
      scrollCacheExtent: const ScrollCacheExtent.viewport(1),
      controller: widget.scrollController,
      slivers: [
        ?flow.gap(flow.leading),
        ..._sliversForEntries(
          context: context,
          library: library,
          settings: settings,
          entries: entries,
          useList: useList,
          flow: flow,
        ),
        SliverToBoxAdapter(
          child: SizedBox(height: 24 + widget.cardBottomPadding),
        ),
      ],
    );
    return _frozenSubtree!;
  }

  List<Widget> _sliversForEntries({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<RecentAddedEntry> entries,
    required bool useList,
    required MediaLibraryFlowSpacing flow,
  }) {
    final slivers = <Widget>[];
    var singles = <RecentAddedChild>[];
    var singlesRegion = 0;
    void startRegion() {
      if (slivers.isNotEmpty) flow.addGap(slivers, flow.section);
    }

    void flushSingles() {
      if (singles.isEmpty) return;
      startRegion();
      slivers.add(
        _memberGridOrListSliver(
          regionId: ('singles', singlesRegion++),
          context: context,
          library: library,
          settings: settings,
          children: List<RecentAddedChild>.from(singles),
          useList: useList,
        ),
      );
      singles = <RecentAddedChild>[];
    }

    for (final entry in entries) {
      if (entry.kind == RecentAddedKind.single) {
        final id = entry.mediaId;
        if (id != null && library.getVideo(id) != null) {
          singles.add(RecentAddedChild.media(id));
        }
        continue;
      }
      flushSingles();
      startRegion();
      slivers.addAll(
        _sliversForGroup(
          context: context,
          library: library,
          settings: settings,
          entry: entry,
          entries: entries,
          useList: useList,
          flow: flow,
        ),
      );
    }
    flushSingles();
    return slivers;
  }

  List<Widget> _sliversForGroup({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required RecentAddedEntry entry,
    required List<RecentAddedEntry> entries,
    required bool useList,
    required MediaLibraryFlowSpacing flow,
  }) {
    final newestBatch = _newestMultiItemBatch(entries);
    final count = entry.visibleCount;
    final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
    final defaultExpanded = MediaLibraryGroupExpandPolicy.recentDefaultExpanded(
      isNewestMultiItemBatch:
          newestBatch != null && newestBatch.rowId == entry.rowId,
      count: count,
      isUnknownBucket: entry.kind == RecentAddedKind.unknown,
    );
    final expanded =
        flat ||
        _expand.isExpanded(entry.rowId, defaultExpanded: defaultExpanded);
    final covers = _coverItems(library, entry);
    final header = SliverToBoxAdapter(
      key: ValueKey(entry.rowId),
      child: KeyedSubtree(
        key: _headerKey(entry.rowId),
        child: MediaLibraryGroupHeader(
          title: entry.groupHeaderLabel(),
          coverItems: covers,
          expanded: expanded,
          padding: EdgeInsets.symmetric(horizontal: flow.outer),
          showChevron: !flat,
          remainderCount: expanded ? 0 : count,
          onToggle: flat
              ? null
              : () => _toggleGroup(
                  rowId: entry.rowId,
                  currentlyExpanded: expanded,
                  memberCount: count,
                  siblingCounts: {
                    for (final other in entries)
                      if (other.kind != RecentAddedKind.single)
                        other.rowId: other.visibleCount,
                  },
                ),
        ),
      ),
    );
    if (!expanded) return [header];
    return [
      header,
      ?flow.gap(flow.attached),
      _memberGridOrListSliver(
        regionId: entry.rowId,
        context: context,
        library: library,
        settings: settings,
        children: entry.children,
        useList: useList,
      ),
    ];
  }

  RecentAddedEntry? _newestMultiItemBatch(List<RecentAddedEntry> entries) {
    for (final entry in entries) {
      if (entry.kind == RecentAddedKind.single) return null;
      if (entry.kind == RecentAddedKind.batch) return entry;
      return null;
    }
    return null;
  }

  /// Visible cards only: collapsed batches contribute no children.
  List<String> _visibleChildIds(List<RecentAddedEntry> entries) {
    final out = <String>[];
    final newestBatch = _newestMultiItemBatch(entries);
    for (final entry in entries) {
      if (entry.kind == RecentAddedKind.single) {
        final id = entry.mediaId;
        if (id != null) out.add(id);
        continue;
      }
      final count = entry.visibleCount;
      final flat = MediaLibraryGroupExpandPolicy.alwaysExpanded(count);
      final defaultExpanded =
          MediaLibraryGroupExpandPolicy.recentDefaultExpanded(
            isNewestMultiItemBatch:
                newestBatch != null && newestBatch.rowId == entry.rowId,
            count: count,
            isUnknownBucket: entry.kind == RecentAddedKind.unknown,
          );
      final expanded =
          flat ||
          _expand.isExpanded(entry.rowId, defaultExpanded: defaultExpanded);
      if (!expanded) continue;
      for (final child in entry.children) {
        out.add(child.id);
      }
    }
    return out;
  }

  List<VideoItem> _coverItems(LibraryService library, RecentAddedEntry entry) {
    final out = <VideoItem>[];
    void takeMedia(String id) {
      if (out.length >= MediaLibraryGroupExpandPolicy.coverPreviewMax) return;
      final item = library.getVideo(id);
      if (item != null) out.add(item);
    }

    void takeFolder(String id) {
      final collection = library.getCollection(id);
      if (collection == null) return;
      for (final childId in collection.childrenIds) {
        if (out.length >= MediaLibraryGroupExpandPolicy.coverPreviewMax) return;
        final item = library.getVideo(childId);
        if (item != null) {
          out.add(item);
          continue;
        }
        if (library.getCollection(childId) != null) takeFolder(childId);
      }
    }

    for (final child in entry.children) {
      if (out.length >= MediaLibraryGroupExpandPolicy.coverPreviewMax) break;
      if (child.kind == RecentAddedChildKind.media) {
        takeMedia(child.id);
      } else {
        takeFolder(child.id);
      }
    }
    return out;
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

  MediaLibraryFlowSpacing _flowSpacing(
    SettingsService settings,
    Size screenSize,
    bool useList,
  ) {
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

  Widget _memberGridOrListSliver({
    required Object regionId,
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<RecentAddedChild> children,
    required bool useList,
  }) {
    if (useList) {
      return _memberListSliver(library, settings, children, regionId);
    }
    return _memberGridSliver(context, library, settings, children, regionId);
  }

  Widget _memberListSliver(
    LibraryService library,
    SettingsService settings,
    List<RecentAddedChild> children,
    Object regionId,
  ) {
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
        itemCount: children.length,
        itemKey: (index) => (children[index].kind, children[index].id),
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
            child: _childTile(
              context: context,
              library: library,
              settings: settings,
              child: children[index],
              index: index,
              useList: true,
              listStyle: listStyle,
            ),
          );
        }, childCount: children.length),
      ),
    );
  }

  Widget _memberGridSliver(
    BuildContext context,
    LibraryService library,
    SettingsService settings,
    List<RecentAddedChild> children,
    Object regionId,
  ) {
    final metrics = MediaLibraryLayoutDefaults.cardGrid(
      textScaler: MediaQuery.textScalerOf(context),
      textStyle: DefaultTextStyle.of(context).style,
      screenSize: Size(
        MediaLibraryScrollViewport.contentWidthOf(context),
        MediaQuery.sizeOf(context).height,
      ),
      style: settings.collectionCardStyleFor(MediaQuery.sizeOf(context)),
    );
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: metrics.outerPadding),
      sliver: PlaybackSliverGrid(
        regionId: regionId,
        itemCount: children.length,
        itemKey: (index) => (children[index].kind, children[index].id),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: metrics.crossAxisCount,
          childAspectRatio: metrics.aspectRatio.clamp(0.1, 5.0),
          crossAxisSpacing: metrics.crossSpacing,
          mainAxisSpacing: metrics.mainSpacing,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          return MediaCoverRevealStamp(
            index: index,
            crossAxisCount: metrics.crossAxisCount,
            child: _childTile(
              context: context,
              library: library,
              settings: settings,
              child: children[index],
              index: index,
              useList: false,
            ),
          );
        }, childCount: children.length),
      ),
    );
  }

  Widget _childTile({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required RecentAddedChild child,
    required int index,
    required bool useList,
    MediaListStyleSettings? listStyle,
  }) {
    if (child.kind == RecentAddedChildKind.folder) {
      final collection = library.getCollection(child.id);
      if (collection == null) return const SizedBox.shrink();
      return _folderTile(
        context: context,
        settings: settings,
        collection: collection,
        useList: useList,
        listStyle: listStyle,
      );
    }
    final item = library.getVideo(child.id);
    if (item == null) return const SizedBox.shrink();
    return _mediaTile(
      context: context,
      library: library,
      settings: settings,
      item: item,
      index: index,
      useList: useList,
      listStyle: listStyle,
    );
  }

  Widget _folderTile({
    required BuildContext context,
    required SettingsService settings,
    required VideoCollection collection,
    required bool useList,
    MediaListStyleSettings? listStyle,
  }) {
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

    final Widget tile;
    if (useList) {
      final style =
          listStyle ?? settings.listStyleFor(MediaQuery.sizeOf(context));
      tile = MediaLibraryListTile.collection(
        collection: collection,
        index: 0,
        showIndex: false,
        showThumbnail: style.showThumbnail,
        isSelected: selected,
        isSelectionMode: selecting,
        titleScale: style.titleScale,
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
        onShowInParentFolder: () => widget.onLocateFolder(collection),
        showActivityMenu: !selecting,
        allowHide: false,
        allowDismissFromRecent: !selecting,
      );
    } else {
      tile = MediaLibraryFolderGridCard(
        collection: collection,
        titleScale: settings
            .collectionCardStyleFor(MediaQuery.sizeOf(context))
            .titleScale,
        onTap: open,
        onLocate: () => widget.onLocateFolder(collection),
        allowDismissFromRecent: !selecting,
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
    return KeyedSubtree(
      key: selection?.host.keyFor(collection.id),
      child: tile,
    );
  }

  Widget _mediaTile({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required VideoItem item,
    required int index,
    required bool useList,
    MediaListStyleSettings? listStyle,
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

    final Widget tile;
    if (useList) {
      final style =
          listStyle ?? settings.listStyleFor(MediaQuery.sizeOf(context));
      tile = MediaLibraryListTile.video(
        item: item,
        index: index,
        showIndex: style.showIndex,
        showThumbnail: style.showThumbnail,
        isSelected: selected,
        isSelectionMode: selecting,
        titleScale: style.titleScale,
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
        allowDismissFromRecent: !selecting,
        relativePath: MediaLibraryMediaGridCard.pathFromLibraryRoot(
          library,
          item,
        ),
      );
    } else {
      tile = MediaLibraryMediaGridCard(
        item: item,
        titleScale: settings
            .collectionCardStyleFor(MediaQuery.sizeOf(context))
            .titleScale,
        onTap: open,
        onLocate: () => widget.onLocateMedia(item),
        allowDismissFromRecent: !selecting,
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
    return KeyedSubtree(key: selection?.host.keyFor(item.id), child: tile);
  }
}
