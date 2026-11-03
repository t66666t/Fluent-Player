import '../widgets/bilibili_part_cover.dart';
import '../widgets/media_library_card_preload.dart';
import '../widgets/library_card_rebuild.dart';
import '../widgets/media_library_card_scale.dart';
import '../widgets/storage_settings_dialog.dart';
import 'dart:async';
import '../features/podcasts/podcast_pages.dart';
import '../features/podcasts/podcast_widgets.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import '../utils/stable_system_ui_insets.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../theme/app_tokens.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../widgets/settings_export_action.dart';
import '../widgets/default_settings_trial_action.dart';
import '../services/app_haptics.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../models/media_library_root_entry.dart';
import '../widgets/folder_drop_target.dart';
import '../widgets/cached_thumbnail_widget.dart';
import '../widgets/folder_placeholder_cover.dart';
import '../widgets/library_rename_dialog.dart';
import '../widgets/media_library_list_tile.dart';
import '../widgets/media_library_item_interaction_wrapper.dart';
import '../widgets/media_library_grid_card.dart';
import '../widgets/media_library_gestures.dart';
import '../widgets/media_library_activity_menu.dart';
import '../widgets/media_library_action_dock.dart';
import '../widgets/media_library_empty_state.dart';
import '../widgets/media_library_actions_menu.dart';
import '../widgets/media_library_folder_sync_button.dart';
import '../widgets/media_library_layout_profile.dart';
import '../widgets/media_library_scroll_viewport.dart';
import '../widgets/media_library_style_sheet.dart';
import '../widgets/media_list_layout_metrics.dart';
import '../debug/debug_log_overlay.dart';
import '../widgets/media_library_settings_sheet.dart';
import '../widgets/media_library_search_prompt.dart';
import '../widgets/media_library_compact_app_bar.dart';
import '../widgets/media_library_selection_bottom_bar.dart';
import '../widgets/media_library_selection_drop_targets.dart';
import '../widgets/media_library_top_bar_import_progress.dart';
import '../widgets/media_library_locate_button.dart';
import '../widgets/media_library_folder_breadcrumb.dart';
import '../widgets/media_library_folder_route.dart';
import '../services/media_library_folder_walk.dart';
import '../widgets/media_library_shell.dart';
import '../widgets/playback_source_viewport.dart';
import '../widgets/playback_card_layout.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'recycle_bin_screen.dart';
import '../widgets/video_action_buttons.dart';
import '../widgets/responsive_icon_button.dart';
import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/playlist_manager.dart';
import 'home_screen.dart';
import '../utils/app_toast.dart';
import '../utils/route_transition_work.dart';
import '../utils/media_library_range_selection.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/desktop_media_management_shortcuts.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../features/portable_transfer/portable_transfer_navigation.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class CollectionScreen extends StatefulWidget {
  final String collectionId;
  final String? searchQuery;
  final String? revealItemId;
  final bool returnToSearchResults;

  const CollectionScreen({
    super.key,
    required this.collectionId,
    this.revealItemId,
    this.returnToSearchResults = false,
  }) : searchQuery = null;

  const CollectionScreen.search({super.key, required String query})
    : collectionId = '',
      searchQuery = query,
      revealItemId = null,
      returnToSearchResults = false;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen>
    with SingleTickerProviderStateMixin {
  bool _isSelectionMode = false;
  bool _showExportSettingsButton = false;
  double _stablePlaybackBottomInset = 0.0;
  late final _playbackInsets = StableSystemUiInsetController(
    includeSystemGestureInsets: true,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  double _selectionBarObstruction = 0.0;
  final Set<String> _selectedIds = {};
  final FocusNode _shortcutFocusNode = FocusNode(
    debugLabel: 'CollectionShortcutFocus',
  );
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();

  // Pinch to zoom state
  int _baseCrossAxisCount = 2;

  // Selection Logic State
  // 1. Circle Drag Selection (All Platforms)
  int? _dragSelectionStartIndex;
  Set<String> _dragSelectionSnapshot = {};

  // 2. Box Selection
  bool _isBoxSelecting = false;
  Offset? _boxStartPos;
  Offset? _boxCurrentPos;
  Offset? _boxStartContentPos;
  PointerDeviceKind? _activePointerKind;

  // File Drag & Drop (Windows)
  bool _isDraggingFiles = false;
  MediaLibraryShellController? _libraryShell;

  // Track items that have been "touched" by the current box selection session
  final Set<String> _capturedIds = {};
  Offset? _lastDragSelectionGlobalPos;
  MediaLibrarySelectionAutoScroller? _selectionAutoScroller;
  final MediaLibrarySelectionPointerSession _selectionPointer =
      MediaLibrarySelectionPointerSession();
  final MediaLibraryReorderDragSession _reorderDrag =
      MediaLibraryReorderDragSession();

  // Thumbnail preloading
  final ScrollController _scrollController = PlaybackScrollController();
  final _entryWork = RouteTransitionWork();
  late final AnimationController _revealHighlightController;
  Timer? _revealHighlightTimer;
  bool _didScheduleReveal = false;
  bool get _isSearchResults => widget.searchQuery != null;

  bool _includeDescendantsNow() {
    if (_isSearchResults || widget.collectionId.isEmpty) return false;
    final settings = Provider.of<SettingsService>(context, listen: false);
    return MediaLibraryFolderBrowseMemory.includeFor(
      folderId: widget.collectionId,
      lastFolderId: settings.mediaLibraryLastFolderId,
      persistedLast: settings.mediaLibraryLastFolderIncludeDescendants,
    );
  }

  bool _allowsFolderReorder() => !_isSearchResults && !_includeDescendantsNow();

  bool _showParentLocate() => _isSearchResults || _includeDescendantsNow();

  List<dynamic> _visibleContents(LibraryService library) {
    if (_isSearchResults) {
      return library.searchContents(widget.searchQuery!);
    }
    if (_includeDescendantsNow()) {
      return library.mediaInFolderTree(widget.collectionId);
    }
    return library.browseContents(widget.collectionId);
  }

  String? _relativePathFor(LibraryService library, VideoItem item) {
    if (!_includeDescendantsNow()) return null;
    final path = library.relativeFolderPath(widget.collectionId, item.parentId);
    return path.isEmpty ? null : path;
  }

  Future<void> _toggleIncludeDescendants() async {
    if (_isSearchResults || widget.collectionId.isEmpty) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final next = !_includeDescendantsNow();
    MediaLibraryFolderBrowseMemory.remember(widget.collectionId, next);
    if (widget.collectionId == settings.mediaLibraryLastFolderId ||
        settings.mediaLibraryLastFolderId.isEmpty) {
      await settings.updateSetting(
        'mediaLibraryLastFolderIncludeDescendants',
        next,
      );
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _libraryShell = MediaLibraryShell.maybeOf(context);
  }

  /// The drop cover dims the frame's mini player as well as this page.
  void _setDraggingFiles(bool value) {
    setState(() => _isDraggingFiles = value);
    _libraryShell?.setFileDropActive(this, value);
  }

  void _openBreadcrumbTarget(String? folderId) {
    if (folderId == widget.collectionId) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final navigator = Navigator.of(context);
    if (folderId == null) {
      unawaited(
        settings.updateSetting(
          'mediaLibraryRootEntry',
          MediaLibraryRootEntry.folders.storageValue,
        ),
      );
      unawaited(
        settings.updateSetting('mediaLibraryRootEntryUserChosen', true),
      );
      popMediaLibraryToFolder(navigator);
      return;
    }
    final found = popMediaLibraryToFolder(navigator, folderId: folderId);
    if (!found) {
      navigator.push(
        buildMediaLibraryFolderRoute<void>(
          folderId: folderId,
          restored: true,
          builder: (_) => CollectionScreen(
            collectionId: folderId,
            returnToSearchResults: widget.returnToSearchResults,
          ),
        ),
      );
    }
    unawaited(settings.saveMediaLibraryLastFolder(folderId));
  }

  List<MediaLibraryBreadcrumbCrumb> _folderCrumbs(LibraryService library) {
    final trail = <MediaLibraryBreadcrumbCrumb>[];
    final visited = <String>{};
    var id = widget.collectionId;
    while (id.isNotEmpty && visited.add(id)) {
      final folder = library.getCollection(id);
      if (folder == null) break;
      trail.add(
        MediaLibraryBreadcrumbCrumb(folderId: folder.id, label: folder.name),
      );
      id = folder.parentId ?? '';
    }
    return [
      const MediaLibraryBreadcrumbCrumb(folderId: null, label: '媒体库'),
      ...trail.reversed,
    ];
  }

  Future<void> _openSearch() async {
    final query = await showMediaLibrarySearchPrompt(context);
    if (!mounted || query == null) return;
    await Navigator.of(context).push(
      buildMediaLibrarySearchResultsRoute(
        CollectionScreen.search(query: query),
      ),
    );
    if (mounted && _supportsManagementKeyboardShortcuts) {
      _shortcutFocusNode.requestFocus();
    }
  }

  void _openPortableTransfer() {
    unawaited(
      PortableTransferNavigation.open(
        context,
        libraryFolderId: widget.collectionId,
      ),
    );
  }

  Route<void> _buildDirectoryLocationRoute(Widget page) {
    return AppMaterialPageRoute<void>(builder: (_) => page);
  }

  void _showInParentDirectory(dynamic item) {
    final itemId = (item as dynamic).id as String;
    final parentId = (item as dynamic).parentId as String?;
    final Widget page = parentId == null
        ? HomeScreen(revealItemId: itemId, returnToSearchResults: true)
        : CollectionScreen(
            collectionId: parentId,
            revealItemId: itemId,
            returnToSearchResults: true,
          );
    Navigator.of(context).push(_buildDirectoryLocationRoute(page));
  }

  void _openParentDirectory(VideoCollection currentCollection) {
    final Widget page = currentCollection.parentId == null
        ? HomeScreen(
            revealItemId: currentCollection.id,
            returnToSearchResults: true,
          )
        : CollectionScreen(
            collectionId: currentCollection.parentId!,
            revealItemId: currentCollection.id,
            returnToSearchResults: true,
          );
    Navigator.of(context).pushReplacement(_buildDirectoryLocationRoute(page));
  }

  void _scheduleRevealIfNeeded(List<dynamic> contents) {
    final targetId = widget.revealItemId;
    if (_didScheduleReveal || targetId == null) return;
    final targetIndex = contents.indexWhere(
      (item) => (item as dynamic).id == targetId,
    );
    if (targetIndex < 0) return;
    _didScheduleReveal = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final targetRect = _getItemRect(targetIndex);
      if (targetRect == null) return;

      final position = _scrollController.position;
      final viewportTop = position.pixels;
      final viewportBottom = viewportTop + position.viewportDimension;
      final isFullyVisible =
          targetRect.top >= viewportTop && targetRect.bottom <= viewportBottom;

      if (!isFullyVisible) {
        final desiredOffset =
            targetRect.center.dy - position.viewportDimension / 2;
        final targetOffset = desiredOffset.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        final distance = (targetOffset - position.pixels).abs();
        final durationMs = (280 + distance * 0.22).round().clamp(280, 620);
        unawaited(
          _scrollController.animateTo(
            targetOffset,
            duration: Duration(milliseconds: durationMs),
            curve: Curves.easeOutCubic,
          ),
        );
      }

      _revealHighlightController.forward(from: 0);
      _revealHighlightTimer?.cancel();
      _revealHighlightTimer = Timer(const Duration(milliseconds: 1700), () {
        if (mounted) _revealHighlightController.reverse();
      });
    });
  }

  Widget _buildRevealHighlight(String itemId, Widget child) {
    if (widget.revealItemId != itemId) return child;
    return AnimatedBuilder(
      animation: _revealHighlightController,
      child: child,
      builder: (context, highlightedChild) {
        final value = Curves.easeOut.transform(
          _revealHighlightController.value,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            highlightedChild!,
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(
                    0xFF6EA8FF,
                  ).withValues(alpha: 0.09 * value),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(
                      0xFF8DBBFF,
                    ).withValues(alpha: 0.72 * value),
                    width: 1 + value,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildCompactTopBarActions(SettingsService settings) {
    if (_isSelectionMode) {
      return [
        MediaLibraryCompactIconButton(
          icon: Icons.select_all,
          tooltip: _managementTooltip(
            '全选',
            DesktopMediaManagementShortcutAction.toggleSelectAll,
          ),
          onPressed: _toggleSelectAllInCollection,
        ),
        const SizedBox(width: 2),
      ];
    }

    return [
      if (widget.returnToSearchResults)
        MediaLibraryCompactIconButton(
          icon: Icons.drive_folder_upload_outlined,
          tooltip: '上一级目录',
          onPressed: () {
            final library = Provider.of<LibraryService>(context, listen: false);
            final current = library.getCollection(widget.collectionId);
            if (current != null) _openParentDirectory(current);
          },
        ),
      MediaLibraryCompactIconButton(
        icon: Icons.search_rounded,
        tooltip: _managementTooltip(
          '搜索媒体库',
          DesktopMediaManagementShortcutAction.openSearch,
        ),
        onPressed: _openSearch,
      ),
      if (settings.defaultSettingsTrial.hasBackup)
        MediaLibraryCompactIconButton(
          icon: Icons.settings_backup_restore,
          tooltip: settings.defaultSettingsTrial.label,
          color: Colors.amberAccent,
          onPressed: () =>
              unawaited(toggleDefaultSettingsTrial(context, settings)),
        ),
      MediaLibraryCompactIconButton(
        icon: Icons.delete_outline,
        tooltip: _managementTooltip(
          '回收站',
          DesktopMediaManagementShortcutAction.openRecycleBin,
        ),
        onLongPress: _toggleExportButtonVisibility,
        onPressed: () {
          pushAboveMediaLibrary(
            context,
            AppMaterialPageRoute(builder: (_) => const RecycleBinScreen()),
          );
        },
      ),
      SizedBox(
        width: 40,
        height: 48,
        child: MediaLibraryCompactMoreButton(
          itemBuilder: (menuContext) => [
            if (!_isSearchResults &&
                _visibleContents(context.read<LibraryService>()).isEmpty)
              ...mediaLibraryActionMenuItems(
                context,
                collectionId: widget.collectionId,
              ),
            if (!_isSearchResults)
              mediaLibraryCompactMenuItem(
                icon: _includeDescendantsNow()
                    ? Icons.account_tree
                    : Icons.account_tree_outlined,
                label: _includeDescendantsNow() ? '仅显示当前目录' : '包含子文件夹内容',
                onSelected: () {
                  unawaited(_toggleIncludeDescendants());
                },
              ),
            mediaLibraryCompactMenuItem(
              icon: settings.mediaLibraryViewMode == 0
                  ? Icons.view_list_rounded
                  : Icons.grid_view_rounded,
              label: settings.mediaLibraryViewMode == 0 ? '切换列表视图' : '切换卡片视图',
              onSelected: () {
                final nextMode = settings.mediaLibraryViewMode == 0 ? 1 : 0;
                settings.updateSetting('mediaLibraryViewMode', nextMode);
              },
            ),
            if (_showExportSettingsButton)
              mediaLibraryCompactMenuItem(
                icon: Icons.file_download,
                label: _managementTooltip(
                  '导出设置',
                  DesktopMediaManagementShortcutAction.exportSettings,
                ),
                onSelected: _exportSettingsSnapshot,
              ),
            if (_showExportSettingsButton ||
                settings.defaultSettingsTrial.hasBackup)
              mediaLibraryCompactMenuItem(
                icon: settings.defaultSettingsTrial.hasBackup
                    ? Icons.settings_backup_restore
                    : Icons.science_outlined,
                label: settings.defaultSettingsTrial.label,
                color: settings.defaultSettingsTrial.hasBackup
                    ? Colors.amberAccent
                    : null,
                onSelected: () =>
                    unawaited(toggleDefaultSettingsTrial(context, settings)),
              ),
            if (_showExportSettingsButton ||
                settings.defaultSettingsTrial.hasBackup)
              mediaLibraryCompactMenuItem(
                icon: Icons.info_outline,
                label: '查看默认设置方案',
                onSelected: () =>
                    unawaited(showDefaultSettingsPlan(context, settings)),
              ),
            mediaLibraryCompactMenuItem(
              icon: Icons.swap_vert_circle_outlined,
              label: _managementTooltip(
                '导入与导出',
                DesktopMediaManagementShortcutAction.exportFluentPack,
              ),
              onSelected: _openPortableTransfer,
            ),
            mediaLibraryCompactMenuItem(
              icon: Icons.tune,
              label: _managementTooltip(
                '调整卡片样式',
                DesktopMediaManagementShortcutAction.openCardStyle,
              ),
              onSelected: () => _openCardStyleSheet(),
            ),
            mediaLibraryCompactMenuItem(
              icon: Icons.settings_outlined,
              label: _managementTooltip(
                '媒体库设置',
                DesktopMediaManagementShortcutAction.openLibrarySettings,
              ),
              onSelected: () =>
                  showMediaLibrarySettingsBottomSheet(context, settings),
              onLongPress: () => unawaited(toggleDebugDeveloperMode(context)),
            ),
            mediaLibraryCompactMenuItem(
              icon: Icons.checklist,
              label: _managementTooltip(
                '批量管理',
                DesktopMediaManagementShortcutAction.enterSelectionMode,
              ),
              onSelected: () {
                if (!mounted) return;
                setState(() => _isSelectionMode = true);
              },
            ),
          ],
        ),
      ),
      const SizedBox(width: 2),
    ];
  }

  static const double _mediaCardCoverAspectRatio = 16 / 9;

  double _resolveCardTitleFontSize(double cardWidth, double settingValue) {
    return MediaLibraryLayoutDefaults.titleFontSize(cardWidth, settingValue);
  }

  double _resolveCardMetaFontSize(double titleFontSize) {
    return MediaLibraryLayoutDefaults.metaFontSize(titleFontSize);
  }

  /// Portrait and landscape styles are stored separately for this collection.
  void _openCardStyleSheet() {
    unawaited(
      MediaLibraryStyleSheet.show(
        context: context,
        scope: MediaLibraryCardStyleScope.collection,
      ),
    );
  }

  MediaCardStyleSettings _collectionCardStyle() {
    return Provider.of<SettingsService>(
      context,
      listen: false,
    ).collectionCardStyleFor(MediaQuery.sizeOf(context));
  }

  MediaListStyleSettings _listStyle() {
    return Provider.of<SettingsService>(
      context,
      listen: false,
    ).listStyleFor(MediaQuery.sizeOf(context));
  }

  Duration get _mediaCardLongPressDelay => mediaLibraryLongPressDelay;

  void _resetSelectionInteractionState() {
    _reorderDrag.end();
    _stopSelectionAutoScroll();
    _isBoxSelecting = false;
    _boxStartPos = null;
    _boxCurrentPos = null;
    _boxStartContentPos = null;
    _capturedIds.clear();
    _dragSelectionStartIndex = null;
    _dragSelectionSnapshot.clear();
    _lastDragSelectionGlobalPos = null;
  }

  Future<void> _syncSelectionAfterMove(
    LibraryService library, {
    required String? currentParentId,
    required Iterable<String> attemptedItemIds,
  }) async {
    if (!mounted) return;

    final remainingIds = library
        .getContents(currentParentId)
        .map((item) => (item as dynamic).id as String)
        .toSet();
    final movedIds = attemptedItemIds
        .where((id) => !remainingIds.contains(id))
        .toSet();

    if (movedIds.isEmpty) return;

    setState(() {
      _selectedIds.removeAll(movedIds);
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
      }
      _resetSelectionInteractionState();
    });
  }

  List<String> _idsForSelectionDrop({int? draggedIndex}) {
    final library = Provider.of<LibraryService>(context, listen: false);
    return resolveMediaLibrarySelectionDropIds(
      contents: _visibleContents(library),
      selectedIds: _selectedIds,
      draggedIndex: draggedIndex,
    );
  }

  Future<void> _moveItemsToParentCollection(
    LibraryService library,
    VideoCollection collection, {
    int? draggedIndex,
  }) async {
    final itemsToMove = _idsForSelectionDrop(draggedIndex: draggedIndex);
    if (itemsToMove.isEmpty) return;

    await library.moveItemsToCollection(itemsToMove, collection.parentId);
    await _syncSelectionAfterMove(
      library,
      currentParentId: widget.collectionId,
      attemptedItemIds: itemsToMove,
    );
    AppToast.show("已移出 ${itemsToMove.length} 个项目", type: AppToastType.success);
  }

  /// Card overflow action: move this one item, not the current selection.
  Future<void> _moveSingleItemToParent(String itemId) async {
    if (_isSearchResults) return;
    final library = Provider.of<LibraryService>(context, listen: false);
    final collection = library.getCollection(widget.collectionId);
    if (collection == null) return;
    await library.moveItemsToCollection([itemId], collection.parentId);
    if (!mounted) return;
    AppToast.show('已移出 1 个项目', type: AppToastType.success);
  }

  VoidCallback? _moveToParentMenuAction(String itemId) {
    if (_isSearchResults) return null;
    return () {
      unawaited(_moveSingleItemToParent(itemId));
    };
  }

  Future<void> _moveItemsToRecycleBin({int? draggedIndex}) async {
    final itemsToMove = _idsForSelectionDrop(draggedIndex: draggedIndex);
    if (itemsToMove.isEmpty) return;

    final library = Provider.of<LibraryService>(context, listen: false);
    final saving = library.moveToRecycleBin(itemsToMove);
    await _syncSelectionAfterMove(
      library,
      currentParentId: widget.collectionId,
      attemptedItemIds: itemsToMove,
    );
    await saving;
    if (!mounted) return;
    AppToast.show("已移入回收站", type: AppToastType.success);
  }

  Widget _scaledThumbnailIcon({
    required double extent,
    required IconData icon,
    Color color = Colors.white24,
  }) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Icon(
          icon,
          size: MediaListLayoutMetrics.cardGridThumbnailIconSize(extent),
          color: color,
        ),
      ),
    );
  }

  /// Helper: Get total item count safely
  int _getItemCount() {
    final library = Provider.of<LibraryService>(context, listen: false);
    return _visibleContents(library).length;
  }

  /// Helper: Get content ID at index
  String? _getItemId(int index) {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = _visibleContents(library);
    if (index < 0 || index >= contents.length) return null;
    return (contents[index] as dynamic).id;
  }

  /// Helper: Check if a point (relative to scrollable content) is inside an item
  /// Returns the index of the item, or null if in spacing/padding
  int? _getIndexAt(Offset contentOffset) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final count = _getItemCount();
    return _getMediaGridGeometry(settings).indexAt(contentOffset, count);
  }

  /// Helper: Get the Rect of an item at [index] relative to the scrollable content area
  Rect? _getItemRect(int index) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final count = _getItemCount();
    if (index < 0 || index >= count) return null;
    return _getMediaGridGeometry(settings).rectForIndex(index);
  }

  MediaLibraryGridGeometry _getMediaGridGeometry(SettingsService settings) {
    final mediaSize = MediaQuery.sizeOf(context);
    final scrollBox = _scrollController.hasClients
        ? _scrollController.position.context.notificationContext
                  ?.findRenderObject()
              as RenderBox?
        : null;
    final viewportSize = Size(
      scrollBox?.size.width ?? mediaSize.width,
      mediaSize.height,
    );
    if (settings.mediaLibraryViewMode == 1) {
      final listStyle = settings.listStyleFor(mediaSize);
      final metrics = MediaListLayoutMetrics.forGrid(
        screenShortestSide: mediaSize.shortestSide,
        availableWidth: viewportSize.width,
        crossAxisCount: listStyle.crossAxisCount,
        heightSetting: listStyle.heightScale,
        titleSetting: listStyle.titleScale,
        mainSpacingSetting: listStyle.mainSpacingScale,
        crossSpacingSetting: listStyle.crossSpacingScale,
      );
      return MediaLibraryGridGeometry(
        crossAxisCount: listStyle.crossAxisCount,
        itemWidth: metrics.cellWidth,
        itemHeight: metrics.rowHeight,
        horizontalSpacing: metrics.crossSpacing,
        verticalSpacing: metrics.mainSpacing,
        horizontalPadding: metrics.outerPadding,
        topPadding: metrics.topPadding,
      );
    }

    final metrics = MediaLibraryLayoutDefaults.cardGrid(
      textScaler: MediaQuery.textScalerOf(context),
      textStyle: DefaultTextStyle.of(context).style,
      screenSize: viewportSize,
      style: settings.collectionCardStyleFor(mediaSize),
    );
    return MediaLibraryGridGeometry(
      crossAxisCount: metrics.crossAxisCount,
      itemWidth: metrics.cellWidth,
      itemHeight: metrics.cellHeight,
      horizontalSpacing: metrics.crossSpacing,
      verticalSpacing: metrics.mainSpacing,
      horizontalPadding: metrics.outerPadding,
      topPadding: metrics.topPadding,
    );
  }

  /// Handle checkbox drag: select a contiguous reading-order range.
  void _updateDragSelection(Offset globalPos) {
    _lastDragSelectionGlobalPos = globalPos;
    _applyDragSelectionAt(globalPos);
    _syncSelectionAutoScroll(globalPos);
  }

  /// Hit-testing coordinate. Outside the list this is the viewport edge, not
  /// the raw pointer, so the range cannot jump to the first or last item.
  Offset _selectionHitGlobal(Offset globalPos) {
    final bounds = _selectionViewportGlobalY();
    if (bounds == null) return globalPos;
    return MediaLibraryRangeSelection.clampPointerToVerticalViewport(
      global: globalPos,
      viewportTop: bounds.top,
      viewportBottom: bounds.bottom,
    );
  }

  Offset? _contentOffsetFromGlobal(Offset globalPos) {
    if (!_scrollController.hasClients) return null;
    final scrollContext =
        _scrollController.position.context.notificationContext;
    final box = scrollContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(_selectionHitGlobal(globalPos));
    return Offset(local.dx, local.dy + _scrollController.offset);
  }

  ({double top, double bottom})? _selectionViewportGlobalY() {
    if (!_scrollController.hasClients) return null;
    final scrollContext =
        _scrollController.position.context.notificationContext;
    final box = scrollContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final top = box.localToGlobal(Offset.zero).dy;
    var bottom = top + box.size.height;
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (playbackService.shouldShowMiniPlaybackCard) {
      final cardHeight = PlaybackCardLayout.calculate(context).height;
      final cardBottom = PlaybackCardOverlayLayout.cardBottomAbove(
        stableBottomInset: _stablePlaybackBottomInset,
        selectionBarHeight: MediaLibraryShell.selectionBarObstructionPeek(
          context,
        ),
      );
      bottom -= MediaLibraryRangeSelection.miniPlayerOverlayHeight(
        visible: true,
        cardHeight: cardHeight,
        cardBottomInset: cardBottom,
      );
    }
    return (top: top, bottom: bottom);
  }

  void _applyDragSelectionAt(Offset globalPos) {
    final startIndex = _dragSelectionStartIndex;
    if (startIndex == null) return;
    final contentOffset = _contentOffsetFromGlobal(globalPos);
    if (contentOffset == null) return;

    final settings = Provider.of<SettingsService>(context, listen: false);
    final count = _getItemCount();
    final currentIndex = _getMediaGridGeometry(
      settings,
    ).indexForDragSelection(contentOffset, count);
    if (currentIndex == null) return;

    final newSelection = MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
      snapshot: _dragSelectionSnapshot,
      startIndex: startIndex,
      currentIndex: currentIndex,
      itemCount: count,
      idAt: _getItemId,
    );

    if (newSelection.length != _selectedIds.length ||
        !_selectedIds.containsAll(newSelection)) {
      setState(() {
        _selectedIds
          ..clear()
          ..addAll(newSelection);
      });
      unawaited(AppHaptics.selectionClick(settings));
    }
  }

  MediaLibrarySelectionAutoScroller _ensureSelectionAutoScroller() {
    return _selectionAutoScroller ??= MediaLibrarySelectionAutoScroller(
      scrollController: _scrollController,
      onScrolled: () {
        final pos = _lastDragSelectionGlobalPos;
        if (_dragSelectionStartIndex != null && pos != null) {
          _applyDragSelectionAt(pos);
        } else if (_isBoxSelecting && pos != null) {
          _applyMouseBoxSelectionAt(pos);
        } else if (_reorderDrag.isActive) {
          // 卡片还按在边缘，列表已经往前走，落点要跟着新的可见卡片更新。
          _reorderDrag.scheduleHitRefresh();
        }
      },
    );
  }

  void _syncSelectionAutoScroll(Offset globalPos) {
    if (_dragSelectionStartIndex == null &&
        !_isBoxSelecting &&
        !_reorderDrag.isActive) {
      _stopSelectionAutoScroll();
      return;
    }
    final bounds = _selectionViewportGlobalY();
    if (bounds == null) {
      _stopSelectionAutoScroll();
      return;
    }
    _ensureSelectionAutoScroller().update(
      pointerY: globalPos.dy,
      viewportTop: bounds.top,
      viewportBottom: bounds.bottom,
    );
  }

  void _stopSelectionAutoScroll() {
    _selectionAutoScroller?.stop();
  }

  /// The checkbox recognizer dies when its card scrolls out of the cache.
  /// This list-level listener keeps the range and the edge scroll tied to the
  /// finger until it lifts, including after that recognizer is gone.
  void _followActiveSelectionPointer(Offset globalPos) {
    if (_dragSelectionStartIndex != null) {
      _updateDragSelection(globalPos);
      return;
    }
    if (_isBoxSelecting) {
      _applyMouseBoxSelectionAt(globalPos);
      _syncSelectionAutoScroll(globalPos);
    }
  }

  void _endActiveSelectionPointer() {
    if (_dragSelectionStartIndex != null) {
      _endListSelectionGesture();
      return;
    }
    if (_isBoxSelecting) {
      _finishMouseBoxSelection();
    }
  }

  /// 选择模式下拖卡片换位置：沿用勾选拖选 / 鼠标框选的边缘滚速。
  void _updateReorderDragPosition(
    Offset globalPosition,
    int pointer,
    int viewId,
    PointerDeviceKind kind,
  ) {
    if (!mounted) return;
    _reorderDrag.update(
      globalPosition: globalPosition,
      pointer: pointer,
      viewId: viewId,
      kind: kind,
    );
    _syncSelectionAutoScroll(globalPosition);
  }

  void _endReorderDrag() {
    if (!mounted || !_reorderDrag.isActive) return;
    _reorderDrag.end();
    if (_dragSelectionStartIndex == null && !_isBoxSelecting) {
      _stopSelectionAutoScroll();
    }
  }

  void _endReorderDragIfPointer(PointerEvent event) {
    if (_reorderDrag.pointer != event.pointer) return;
    _endReorderDrag();
  }

  /// 抬起沿按下时的命中路径到达列表，卡片滚出缓存后这里仍能收到。
  /// 勾选拖选和排序拖拽都靠它停掉边缘滚动。
  void _endLibraryPointer(PointerEvent event) {
    if (_selectionPointer.up(event.pointer)) {
      _endActiveSelectionPointer();
    }
    _endReorderDragIfPointer(event);
  }

  bool _tryStartMouseBoxSelection({
    required int pointerCount,
    required Offset globalPos,
  }) {
    if (!MediaLibraryRangeSelection.isMouseBoxGesture(
      pointerKind: _activePointerKind,
      pointerCount: pointerCount,
    )) {
      return false;
    }
    final contentOffset = _contentOffsetFromGlobal(globalPos);
    if (contentOffset == null || _getIndexAt(contentOffset) != null) {
      return false;
    }
    _isBoxSelecting = true;
    _boxStartContentPos = contentOffset;
    _lastDragSelectionGlobalPos = globalPos;
    _capturedIds.clear();
    _dragSelectionSnapshot = _isSelectionMode
        ? Set<String>.from(_selectedIds)
        : <String>{};
    _applyMouseBoxSelectionAt(globalPos);
    _syncSelectionAutoScroll(globalPos);
    return true;
  }

  void _applyMouseBoxSelectionAt(Offset globalPos) {
    if (!_isBoxSelecting || _boxStartContentPos == null) return;
    _lastDragSelectionGlobalPos = globalPos;
    final currentContent = _contentOffsetFromGlobal(globalPos);
    if (currentContent == null) return;
    final scroll = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final geometry = _getMediaGridGeometry(settings);
    final contentRect = Rect.fromPoints(_boxStartContentPos!, currentContent);
    final currentInBox = <String>{};
    for (final index in geometry.indicesOverlapping(
      contentRect,
      _getItemCount(),
    )) {
      final id = _getItemId(index);
      if (id != null) currentInBox.add(id);
    }

    setState(() {
      _boxStartPos = _boxStartContentPos! - Offset(0, scroll);
      _boxCurrentPos = currentContent - Offset(0, scroll);
      if (!_isSelectionMode) return;
      _capturedIds.addAll(currentInBox);
      final newSelection = <String>{};
      for (final id in _dragSelectionSnapshot) {
        if (!_capturedIds.contains(id)) newSelection.add(id);
      }
      newSelection.addAll(currentInBox);
      if (newSelection.length != _selectedIds.length ||
          !_selectedIds.containsAll(newSelection)) {
        _selectedIds
          ..clear()
          ..addAll(newSelection);
        unawaited(AppHaptics.selectionClick(settings));
      }
    });
  }

  void _finishMouseBoxSelection() {
    _stopSelectionAutoScroll();
    if (!_isSelectionMode &&
        _boxStartContentPos != null &&
        _lastDragSelectionGlobalPos != null) {
      final currentContent = _contentOffsetFromGlobal(
        _lastDragSelectionGlobalPos!,
      );
      if (currentContent != null) {
        final settings = Provider.of<SettingsService>(context, listen: false);
        final geometry = _getMediaGridGeometry(settings);
        final contentRect = Rect.fromPoints(
          _boxStartContentPos!,
          currentContent,
        );
        final newSelected = <String>{};
        for (final index in geometry.indicesOverlapping(
          contentRect,
          _getItemCount(),
        )) {
          final id = _getItemId(index);
          if (id != null) newSelected.add(id);
        }
        if (newSelected.isNotEmpty) {
          setState(() {
            _isSelectionMode = true;
            _selectedIds.addAll(newSelected);
            _isBoxSelecting = false;
            _boxStartPos = null;
            _boxCurrentPos = null;
            _boxStartContentPos = null;
            _capturedIds.clear();
          });
          return;
        }
      }
    }
    setState(() {
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      _boxStartContentPos = null;
      _capturedIds.clear();
    });
  }

  /// 计算播放卡片的底部填充，确保内容不被遮挡
  double _getPlaybackCardBottomPadding({required bool isVisible}) {
    return PlaybackCardOverlayLayout.contentBottomPadding(
      stableBottomInset: _stablePlaybackBottomInset,
      selectionBarHeight: _selectionBarObstruction,
      cardHeight: PlaybackCardLayout.calculate(context).height,
      isCardVisible: isVisible,
    );
  }

  Route<void> _buildVideoPlayerRoute(
    VideoItem item,
    VideoPlayerController? existingController,
  ) {
    // 桌面端或开启"跳过竖屏播放页"时直入横屏播放页，否则进入竖屏播放页
    return PlaybackNavigationService.buildPlaybackEntryRoute(
      item,
      existingController: existingController,
    );
  }

  void _preparePlaybackQueue(VideoItem item) {
    if (!mounted) return;
    final playlistManager = Provider.of<PlaylistManager>(
      context,
      listen: false,
    );
    // Search is only a locator. The queue still follows the video's original
    // folder order, matching collection/home open behavior.
    playlistManager.prepareLibraryPlayback(item);
  }

  void _openPlaybackScreen(
    VideoItem item, {
    VideoPlayerController? existingController,
  }) {
    _preparePlaybackQueue(item);
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    PlaybackNavigationService.instance.primeLibraryPlaybackEntry(
      playbackService: playbackService,
      item: item,
      existingController: existingController,
    );
    pushAboveMediaLibrary(
      context,
      _buildVideoPlayerRoute(item, existingController),
    );
  }

  @override
  void initState() {
    super.initState();
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    _revealHighlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 560),
    );
    _loadExportButtonPreference();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.searchQuery != null) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      final includedDescendants = _includeDescendantsNow();
      unawaited(settings.saveMediaLibraryLastFolder(widget.collectionId));
      // Last-folder identity also selects the persisted descendant preference.
      // Preserve that visible update locally without rebuilding covered levels.
      if (_includeDescendantsNow() != includedDescendants) {
        setState(() {});
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_supportsManagementKeyboardShortcuts && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _entryWork.dispose();
    _playbackInsets.dispose();
    _libraryShell?.setFileDropActive(this, false);
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _revealHighlightTimer?.cancel();
    _revealHighlightController.dispose();
    _scrollController.dispose();
    _shortcutFocusNode.dispose();
    _reorderDrag.end();
    _selectionAutoScroller?.dispose();
    super.dispose();
  }

  bool get _supportsManagementKeyboardShortcuts {
    return supportsNativeHardwareKeyboardShortcuts;
  }

  bool get _isDesktopPlatform {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool _isTextInputFocused() {
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  String _managementTooltip(
    String label,
    DesktopMediaManagementShortcutAction action,
  ) {
    final platform = currentNativeTargetPlatform;
    if (platform == null ||
        !supportsPlayerPointerHoverOn(platform) ||
        !DesktopMediaManagementShortcuts.isAvailableOnPlatform(
          action,
          platform,
        )) {
      return label;
    }
    return DesktopMediaManagementShortcuts.buildTooltip(
      label,
      action,
      context: context,
    );
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      _capturedIds.clear();
    });
  }

  void _toggleSelectAllInCollection() {
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = _visibleContents(library);
    setState(() {
      if (_selectedIds.length == contents.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(contents.map((e) => (e as dynamic).id as String));
      }
    });
  }

  KeyEventResult _handleManagementShortcut(
    DesktopMediaManagementShortcutAction action,
  ) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    switch (action) {
      case DesktopMediaManagementShortcutAction.backOrExitSelection:
        if (_isSelectionMode) {
          _exitSelectionMode();
        } else {
          Navigator.of(context).maybePop();
        }
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleViewMode:
        final nextMode = settings.mediaLibraryViewMode == 0 ? 1 : 0;
        settings.updateSetting('mediaLibraryViewMode', nextMode);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleFullScreen:
        if (!_isDesktopPlatform) {
          return KeyEventResult.ignored;
        }
        settings.toggleFullScreen();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openLargeDataDirectory:
        if (_isSelectionMode || !(Platform.isWindows || Platform.isLinux)) {
          return KeyEventResult.handled;
        }
        _showLargeDataPathDialog(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.exportSettings:
        if (_isSelectionMode || !_showExportSettingsButton) {
          return KeyEventResult.handled;
        }
        _exportSettingsSnapshot();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openRecycleBin:
        if (_isSelectionMode) {
          unawaited(_moveItemsToRecycleBin());
          return KeyEventResult.handled;
        }
        pushAboveMediaLibrary(
          context,
          AppMaterialPageRoute(builder: (_) => const RecycleBinScreen()),
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openCardStyle:
        if (_isSelectionMode) return KeyEventResult.handled;
        _openCardStyleSheet();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.enterSelectionMode:
        if (_isSelectionMode) return KeyEventResult.handled;
        setState(() {
          _isSelectionMode = true;
        });
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleSelectAll:
        if (!_isSelectionMode) return KeyEventResult.handled;
        _toggleSelectAllInCollection();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openSearch:
        if (_isSelectionMode) return KeyEventResult.handled;
        unawaited(_openSearch());
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openLibrarySettings:
        if (_isSelectionMode) return KeyEventResult.handled;
        showMediaLibrarySettingsBottomSheet(context, settings);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openSleepTimer:
        unawaited(showSleepTimerDialog(context));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.createCollection:
        if (_isSelectionMode) {
          if (_selectedIds.length == 1) {
            final id = _selectedIds.first;
            final name =
                library.getCollection(id)?.name ??
                library.getVideo(id)?.title ??
                '';
            _showRenameDialog(context, id, name);
          }
          return KeyEventResult.handled;
        }
        VideoActionButtons.openCreateCollectionDialog(
          context,
          widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.importMedia:
        if (_isSelectionMode) return KeyEventResult.handled;
        unawaited(
          VideoActionButtons.showImportMenu(context, widget.collectionId),
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBilibiliDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBilibiliDownloadPage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openYtDlpDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openYtDlpDownloadPage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openDouyinDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openDouyinDownloadPage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openWebMedia:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openWebMediaPage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleActionButtons:
        if (_isSelectionMode) return KeyEventResult.handled;
        settings.updateSetting(
          'isActionButtonsCollapsed',
          !settings.isActionButtonsCollapsed,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBatchSubtitle:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBatchSubtitlePage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBatchImport:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openCacheManagementPage(
          context,
          collectionId: widget.collectionId,
        );
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.moveToParent:
        if (!_isSelectionMode || _isSearchResults) {
          return KeyEventResult.handled;
        }
        final collection = library.getCollection(widget.collectionId);
        if (collection == null) return KeyEventResult.handled;
        unawaited(_moveItemsToParentCollection(library, collection));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.exportFluentPack:
        // Same letter as the toolbar button: browse mode opens the page,
        // selection mode opens the Fluent Pack / Zip choice.
        if (!_isSelectionMode) {
          _openPortableTransfer();
          return KeyEventResult.handled;
        }
        if (_selectedIds.isEmpty) {
          return KeyEventResult.handled;
        }
        final ids = _selectedIds.toList();
        setState(() {
          _selectedIds.clear();
          _isSelectionMode = false;
        });
        unawaited(PortableTransferNavigation.openExportSettings(context, ids));
        return KeyEventResult.handled;
    }
  }

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    if (_shortcutFocusNode.hasFocus) return false;
    return _handleShortcutKeyEvent(event) != KeyEventResult.ignored;
  }

  void _handleAndroidHardwareKeyEvent(AndroidHardwareKeyMessage message) {
    _handleShortcutKeyEvent(
      message.toKeyEvent(),
      fromAndroidNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
    );
  }

  KeyEventResult _handleShortcutKeyEvent(
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
  }) {
    if (!_supportsManagementKeyboardShortcuts) return KeyEventResult.ignored;
    // 当视频播放页或其他子页面活跃时，不处理键盘事件，避免与播放器快捷键冲突
    if (!isMediaLibraryRouteCurrent(context)) return KeyEventResult.ignored;
    // Podcast channels own their keyboard commands, even though this folder
    // route remains mounted around them. Do not also run library commands.
    if (!_isSearchResults &&
        context
                .read<LibraryService>()
                .getCollection(widget.collectionId)
                ?.podcastRef !=
            null) {
      return KeyEventResult.ignored;
    }
    if (Platform.isAndroid &&
        !_androidKeyDeduplicator.shouldDispatch(
          event,
          fromNativeBridge: fromAndroidNativeBridge,
        )) {
      return KeyEventResult.handled;
    }
    if (_isTextInputFocused()) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    final bool hasBlockingModifier =
        hasBlockingModifierOverride ??
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    if (hasBlockingModifier) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final DesktopMediaManagementShortcutAction? managementAction =
        DesktopMediaManagementShortcuts.matchAction(key);
    final platform = currentNativeTargetPlatform;
    final bool isManagementActionAvailable =
        managementAction != null &&
        platform != null &&
        DesktopMediaManagementShortcuts.isAvailableOnPlatform(
          managementAction,
          platform,
        );
    final isTargetKey =
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.escape;
    if (!isTargetKey && !isManagementActionAvailable) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    if (isManagementActionAvailable &&
        managementAction !=
            DesktopMediaManagementShortcutAction.backOrExitSelection) {
      return _handleManagementShortcut(managementAction);
    }

    if (key == LogicalKeyboardKey.escape) {
      if (isManagementActionAvailable) {
        return _handleManagementShortcut(managementAction);
      }
      return KeyEventResult.ignored;
    }

    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final settings = Provider.of<SettingsService>(context, listen: false);
    final canControl =
        playbackService.currentItem != null &&
        (playbackService.state == PlaybackState.playing ||
            playbackService.state == PlaybackState.paused);
    if (!canControl) return KeyEventResult.handled;

    if (key == LogicalKeyboardKey.space) {
      if (playbackService.desiredPlaying) {
        playbackService.pause();
      } else {
        playbackService.resume();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      playbackService.handleExternalDoubleTapSeek(
        isLeft: true,
        doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
        enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
        subtitleOffset: settings.subtitleOffset,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      playbackService.handleExternalDoubleTapSeek(
        isLeft: false,
        doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
        enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
        subtitleOffset: settings.subtitleOffset,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) =>
      RouteTransitionWorkHost(work: _entryWork, child: _buildContent(context));

  Widget _buildContent(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final isPlaybackCardVisible = context.select<MediaPlaybackService, bool>(
      (playback) => playback.shouldShowMiniPlaybackCard,
    );
    final useCompactTopBar = useCompactMediaLibraryTopBar(context);
    // The mini player lives in the library frame; line up with its inset.
    _stablePlaybackBottomInset =
        MediaLibraryShell.stableBottomInsetOf(context) ??
        _playbackInsets
            .observe(
              MediaQueryData.fromView(View.of(context)),
              active: mediaLibraryRouteIsCurrent(context) ?? true,
            )
            .bottom;
    // Subscribes this page so the list padding grows when the mini player
    // lifts above the selection bar.
    _selectionBarObstruction = MediaLibraryShell.selectionBarObstructionOf(
      context,
    );
    final playbackCardBottomPadding = _getPlaybackCardBottomPadding(
      isVisible: isPlaybackCardVisible,
    );

    return Selector<LibraryService, int>(
      selector: (_, service) => service.browseRevision,
      builder: (context, _, child) {
        final library = context.read<LibraryService>();
        final collection = _isSearchResults
            ? VideoCollection(
                id: '',
                name: '搜索：“${widget.searchQuery}”',
                createTime: 0,
              )
            : library.getCollection(widget.collectionId) ??
                  VideoCollection(id: '', name: '未知合集', createTime: 0);

        if (collection.podcastRef != null) {
          return PodcastChannelPage(
            channelId: collection.podcastRef!.channelId,
          );
        }
        final contents = _visibleContents(library);
        _scheduleRevealIfNeeded(contents);
        final baseTheme = Theme.of(context);

        return Theme(
          data: _isSearchResults
              ? mediaLibrarySearchResultsTheme(baseTheme)
              : baseTheme,
          child: PopScope(
            canPop: !_isSelectionMode,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              _exitSelectionMode();
            },
            child: Scaffold(
              backgroundColor: AppTokens.bgBase,
              extendBody: true,
              // Only the search prompt follows the Android keyboard. The
              // folder/search-result grid stays at its original dimensions
              // underneath the IME to avoid a full card-grid relayout.
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                clipBehavior: Clip.hardEdge,
                backgroundColor: AppTokens.bgBase,
                surfaceTintColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                iconTheme: const IconThemeData(color: AppTokens.text2),
                actionsIconTheme: const IconThemeData(color: AppTokens.text2),
                shape: const Border(
                  bottom: BorderSide(color: AppTokens.lineSubtle),
                ),
                toolbarHeight: useCompactTopBar ? 44 : 48,
                leadingWidth: useCompactTopBar ? 40 : 44,
                titleSpacing: useCompactTopBar ? 3 : 8,
                title: _isSelectionMode
                    ? (_isSearchResults
                          ? (useCompactTopBar
                                ? MediaLibraryCompactTitle(
                                    text: '已选择 ${_selectedIds.length} 项',
                                  )
                                : Text('已选择 ${_selectedIds.length} 项'))
                          : MediaLibrarySelectionDropTargets(
                              showMoveToParent: true,
                              hasSelectedItems: _selectedIds.isNotEmpty,
                              onMoveToParent: (draggedIndex) {
                                unawaited(
                                  _moveItemsToParentCollection(
                                    library,
                                    collection,
                                    draggedIndex: draggedIndex,
                                  ),
                                );
                              },
                              onMoveToRecycleBin: (draggedIndex) {
                                unawaited(
                                  _moveItemsToRecycleBin(
                                    draggedIndex: draggedIndex,
                                  ),
                                );
                              },
                            ))
                    : useCompactTopBar
                    ? (_isSearchResults
                          ? MediaLibraryCompactTitle(text: collection.name)
                          : MediaLibraryFolderBreadcrumb(
                              crumbs: _folderCrumbs(library),
                              compact: true,
                              onSelected: _openBreadcrumbTarget,
                            ))
                    : Row(
                        children: [
                          DesktopButtonClickRegion(
                            child: IconButton(
                              icon: Icon(
                                settings.mediaLibraryViewMode == 0
                                    ? Icons.view_list_rounded
                                    : Icons.grid_view_rounded,
                                color: AppTokens.text2,
                              ),
                              tooltip: settings.mediaLibraryViewMode == 0
                                  ? _managementTooltip(
                                      "切换列表视图",
                                      DesktopMediaManagementShortcutAction
                                          .toggleViewMode,
                                    )
                                  : _managementTooltip(
                                      "切换卡片视图",
                                      DesktopMediaManagementShortcutAction
                                          .toggleViewMode,
                                    ),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 36,
                                height: 36,
                              ),
                              onPressed: () {
                                final nextMode =
                                    settings.mediaLibraryViewMode == 0 ? 1 : 0;
                                settings.updateSetting(
                                  'mediaLibraryViewMode',
                                  nextMode,
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: _isSearchResults
                                      ? MediaLibraryCompactTitle(
                                          text: collection.name,
                                        )
                                      : MediaLibraryFolderBreadcrumb(
                                          crumbs: _folderCrumbs(library),
                                          onSelected: _openBreadcrumbTarget,
                                        ),
                                ),
                                if (!_isSearchResults)
                                  ValueListenableBuilder<bool>(
                                    valueListenable: library.isImporting,
                                    builder: (context, isImporting, _) {
                                      if (!isImporting) {
                                        return const SizedBox.shrink();
                                      }
                                      return ValueListenableBuilder<String>(
                                        valueListenable: library.importStatus,
                                        builder: (context, status, _) {
                                          return Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              status,
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.white70,
                                                height: 1.0,
                                                leadingDistribution:
                                                    TextLeadingDistribution
                                                        .even,
                                              ),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                centerTitle: false,
                leading: _isSelectionMode
                    ? (useCompactTopBar
                          ? MediaLibraryCompactIconButton(
                              icon: Icons.close,
                              tooltip: '退出选择',
                              onPressed: _exitSelectionMode,
                            )
                          : DesktopButtonClickRegion(
                              child: IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: _managementTooltip(
                                  "退出选择",
                                  DesktopMediaManagementShortcutAction
                                      .backOrExitSelection,
                                ),
                                onPressed: _exitSelectionMode,
                              ),
                            ))
                    : (useCompactTopBar
                          ? MediaLibraryCompactIconButton(
                              icon: Icons.arrow_back,
                              tooltip: widget.returnToSearchResults
                                  ? '返回搜索结果'
                                  : '返回上一级',
                              onPressed: () => Navigator.of(context).maybePop(),
                            )
                          : DesktopButtonClickRegion(
                              child: IconButton(
                                icon: const Icon(Icons.arrow_back),
                                tooltip: widget.returnToSearchResults
                                    ? '返回搜索结果'
                                    : _managementTooltip(
                                        "返回上一级",
                                        DesktopMediaManagementShortcutAction
                                            .backOrExitSelection,
                                      ),
                                onPressed: () =>
                                    Navigator.of(context).maybePop(),
                              ),
                            )),
                actions: useCompactTopBar
                    ? _buildCompactTopBarActions(settings)
                    : [
                        ResponsiveActionButtons(
                          buttons: [
                            if (!_isSelectionMode) ...[
                              if (Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS)
                                ResponsiveIconButton(
                                  icon: settings.isFullScreen
                                      ? Icons.fullscreen_exit
                                      : Icons.fullscreen,
                                  tooltip: _managementTooltip(
                                    settings.isFullScreen ? "退出全屏" : "全屏",
                                    DesktopMediaManagementShortcutAction
                                        .toggleFullScreen,
                                  ),
                                  onPressed: () => settings.toggleFullScreen(),
                                ),
                              if (Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS)
                                ResponsiveIconButton(
                                  icon: Icons.folder_open,
                                  tooltip: _managementTooltip(
                                    "大文件目录",
                                    DesktopMediaManagementShortcutAction
                                        .openLargeDataDirectory,
                                  ),
                                  onPressed: () =>
                                      _showLargeDataPathDialog(context),
                                ),
                              if (_showExportSettingsButton)
                                ResponsiveIconButton(
                                  icon: Icons.file_download,
                                  tooltip: _managementTooltip(
                                    "导出设置",
                                    DesktopMediaManagementShortcutAction
                                        .exportSettings,
                                  ),
                                  onPressed: _exportSettingsSnapshot,
                                ),
                              if (_showExportSettingsButton ||
                                  settings.defaultSettingsTrial.hasBackup)
                                DefaultSettingsTrialButton(settings: settings),
                              ResponsiveIconButton(
                                icon: Icons.swap_vert_circle_outlined,
                                tooltip: _managementTooltip(
                                  "导入与导出",
                                  DesktopMediaManagementShortcutAction
                                      .exportFluentPack,
                                ),
                                onPressed: () {
                                  if (contents.isEmpty) {
                                    unawaited(
                                      showMediaLibraryActionsMenu(
                                        context,
                                        collectionId: widget.collectionId,
                                        onTransfer: _openPortableTransfer,
                                      ),
                                    );
                                  } else {
                                    _openPortableTransfer();
                                  }
                                },
                              ),
                              if (widget.returnToSearchResults)
                                ResponsiveIconButton(
                                  icon: Icons.drive_folder_upload_outlined,
                                  tooltip: '上一级目录',
                                  onPressed: () =>
                                      _openParentDirectory(collection),
                                ),
                              if (!_isSearchResults)
                                ResponsiveIconButton(
                                  icon: _includeDescendantsNow()
                                      ? Icons.account_tree
                                      : Icons.account_tree_outlined,
                                  tooltip: _includeDescendantsNow()
                                      ? '仅显示当前目录'
                                      : '包含子文件夹内容',
                                  onPressed: () {
                                    unawaited(_toggleIncludeDescendants());
                                  },
                                ),
                              ResponsiveIconButton(
                                icon: Icons.search_rounded,
                                tooltip: _managementTooltip(
                                  '搜索媒体库',
                                  DesktopMediaManagementShortcutAction
                                      .openSearch,
                                ),
                                onPressed: _openSearch,
                              ),
                              ResponsiveIconButton(
                                icon: Icons.delete_outline,
                                tooltip: _managementTooltip(
                                  "回收站",
                                  DesktopMediaManagementShortcutAction
                                      .openRecycleBin,
                                ),
                                onLongPress: _toggleExportButtonVisibility,
                                onPressed: () {
                                  pushAboveMediaLibrary(
                                    context,
                                    AppMaterialPageRoute(
                                      builder: (_) => const RecycleBinScreen(),
                                    ),
                                  );
                                },
                              ),
                              ResponsiveIconButton(
                                icon: Icons.tune,
                                tooltip: _managementTooltip(
                                  "调整卡片样式",
                                  DesktopMediaManagementShortcutAction
                                      .openCardStyle,
                                ),
                                onPressed: _openCardStyleSheet,
                              ),
                              ResponsiveIconButton(
                                icon: Icons.settings_outlined,
                                tooltip: _managementTooltip(
                                  "媒体库设置",
                                  DesktopMediaManagementShortcutAction
                                      .openLibrarySettings,
                                ),
                                onLongPress: () => unawaited(
                                  toggleDebugDeveloperMode(context),
                                ),
                                onPressed: () =>
                                    showMediaLibrarySettingsBottomSheet(
                                      context,
                                      settings,
                                    ),
                              ),
                              ResponsiveIconButton(
                                icon: Icons.checklist,
                                tooltip: _managementTooltip(
                                  "批量管理",
                                  DesktopMediaManagementShortcutAction
                                      .enterSelectionMode,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _isSelectionMode = true;
                                  });
                                },
                              ),
                            ] else ...[
                              ResponsiveIconButton(
                                icon: Icons.select_all,
                                tooltip: _managementTooltip(
                                  "全选",
                                  DesktopMediaManagementShortcutAction
                                      .toggleSelectAll,
                                ),
                                onPressed: _toggleSelectAllInCollection,
                              ),
                            ],
                          ],
                        ),
                      ],
                bottom: const MediaLibraryTopBarImportProgress(),
              ),
              body: SafeArea(
                top: false,
                bottom: false,
                child: Focus(
                  focusNode: _shortcutFocusNode,
                  autofocus: _supportsManagementKeyboardShortcuts,
                  onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      _selectionPointer.down(event.pointer);
                      if (_supportsManagementKeyboardShortcuts &&
                          !_shortcutFocusNode.hasFocus) {
                        _shortcutFocusNode.requestFocus();
                      }
                    },
                    onPointerMove: (event) {
                      if (!_selectionPointer.move(event.pointer)) return;
                      _followActiveSelectionPointer(event.position);
                    },
                    onPointerUp: _endLibraryPointer,
                    onPointerCancel: _endLibraryPointer,
                    child: DropTarget(
                      onDragDone: (details) {
                        if (!isMediaLibraryRouteCurrent(context)) return;
                        if (_isSearchResults) return;
                        _setDraggingFiles(false);
                        final paths = details.files.map((f) => f.path).toList();
                        if (paths.isNotEmpty) {
                          VideoActionButtons.processDroppedPaths(
                            context,
                            paths,
                            widget.collectionId,
                          );
                        }
                      },
                      onDragEntered: (_) {
                        if (!isMediaLibraryRouteCurrent(context)) return;
                        if (_isSearchResults) return;
                        _setDraggingFiles(true);
                      },
                      onDragExited: (_) => _setDraggingFiles(false),
                      child: Stack(
                        children: [
                          contents.isEmpty
                              ? MediaLibraryEmptyState(
                                  icon: _isSearchResults
                                      ? Icons.search_off_rounded
                                      : Icons.folder_open_outlined,
                                  message: _isSearchResults
                                      ? '没有找到匹配项目'
                                      : '此文件夹为空',
                                  bottomPadding: playbackCardBottomPadding,
                                  actionLabel: _isSearchResults
                                      ? '修改搜索'
                                      : '导入媒体',
                                  onAction: _isSearchResults
                                      ? _openSearch
                                      : () => VideoActionButtons.showImportMenu(
                                          context,
                                          widget.collectionId,
                                        ),
                                )
                              : Listener(
                                  onPointerDown: (event) {
                                    _activePointerKind = event.kind;
                                  },
                                  child: GestureDetector(
                                    onScaleStart: (details) {
                                      if (_tryStartMouseBoxSelection(
                                        pointerCount: details.pointerCount,
                                        globalPos: details.focalPoint,
                                      )) {
                                        return;
                                      }
                                      _baseCrossAxisCount =
                                          settings.mediaLibraryViewMode == 1
                                          ? _listStyle().crossAxisCount
                                          : _collectionCardStyle()
                                                .crossAxisCount;
                                    },
                                    onScaleUpdate: (details) {
                                      if (_isBoxSelecting) {
                                        _applyMouseBoxSelectionAt(
                                          details.focalPoint,
                                        );
                                        _syncSelectionAutoScroll(
                                          details.focalPoint,
                                        );
                                        return;
                                      }

                                      double newScale = details.scale;
                                      int newCount = _baseCrossAxisCount;

                                      if (newScale > 1.3) {
                                        newCount = (_baseCrossAxisCount - 1)
                                            .clamp(1, 20);
                                      } else if (newScale < 0.7) {
                                        newCount = (_baseCrossAxisCount + 1)
                                            .clamp(1, 20);
                                      }

                                      final currentCount =
                                          settings.mediaLibraryViewMode == 1
                                          ? _listStyle().crossAxisCount
                                          : _collectionCardStyle()
                                                .crossAxisCount;
                                      if (newCount != currentCount) {
                                        final size = MediaQuery.sizeOf(context);
                                        if (settings.mediaLibraryViewMode ==
                                            1) {
                                          unawaited(
                                            settings.updateListStyleFor(
                                              size,
                                              crossAxisCount: newCount,
                                            ),
                                          );
                                        } else {
                                          unawaited(
                                            settings
                                                .updateCollectionCardStyleFor(
                                                  size,
                                                  crossAxisCount: newCount,
                                                ),
                                          );
                                        }
                                      }
                                    },
                                    onScaleEnd: (details) {
                                      if (_isBoxSelecting) {
                                        _finishMouseBoxSelection();
                                        return;
                                      }
                                    },
                                    child: Container(
                                      height: MediaQuery.sizeOf(context).height,
                                      color: Colors.transparent,
                                      child: _buildMediaGridOrList(
                                        context: context,
                                        library: library,
                                        settings: settings,
                                        contents: contents,
                                        playbackCardBottomPadding:
                                            playbackCardBottomPadding,
                                      ),
                                    ),
                                  ),
                                ),
                          // Fill the rest of the screen with a transparent hit target to ensure GestureDetector catches taps in empty space
                          if (contents.length <
                              20) // Only if potentially empty space at bottom
                            Positioned.fill(
                              key: MediaLibraryOverlayKeys.emptySpaceHitTarget,
                              child: Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerDown:
                                    (
                                      _,
                                    ) {}, // Consumes touch to pass to GestureDetector parent? No, Listener doesn't consume.
                                // We need a widget that participates in hit test but lets events bubble up?
                                // GestureDetector with translucent behavior catches it.
                                // But GridView might not fill the height.
                                // So we place this BEHIND GridView? No, GridView is in GestureDetector child.
                                // If GridView shrinks, GestureDetector child shrinks.
                                // So GestureDetector might not cover full screen.
                                // FIX: Wrap GridView in a Container with double.infinity height.
                              ),
                            ),
                          if (_isBoxSelecting &&
                              _boxStartPos != null &&
                              _boxCurrentPos != null)
                            Positioned.fill(
                              key: MediaLibraryOverlayKeys.boxSelection,
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _BoxSelectionPainter(
                                    selectionRect: Rect.fromPoints(
                                      _boxStartPos!,
                                      _boxCurrentPos!,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (_isDraggingFiles && !_isSearchResults)
                            Positioned.fill(
                              key: MediaLibraryOverlayKeys.fileDrop,
                              child: Container(
                                color: Colors.black54,
                                child: const Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.cloud_upload,
                                        size: 80,
                                        color: Colors.blueAccent,
                                      ),
                                      SizedBox(height: 16),
                                      Text(
                                        "松开以导入媒体文件、压缩包或文件夹",
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 24,
                                          fontWeight: FontWeight.bold,
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
                  ),
                ),
              ),
              floatingActionButtonLocation:
                  const PlaybackActionButtonsLocation(),
              floatingActionButton:
                  !_isSelectionMode && !_isSearchResults && contents.isNotEmpty
                  ? Consumer<MediaPlaybackService>(
                      builder: (context, playbackService, child) {
                        final isCardVisible =
                            playbackService.shouldShowMiniPlaybackCard;
                        final cardHeight = PlaybackCardLayout.calculate(
                          context,
                        ).height;
                        final actionBottom =
                            PlaybackCardOverlayLayout.actionButtonsBottom(
                              stableBottomInset: _stablePlaybackBottomInset,
                              cardHeight: cardHeight,
                              isCardVisible: isCardVisible,
                            );
                        final topBoundary =
                            MediaQuery.viewPaddingOf(context).top +
                            (useCompactTopBar ? 50.0 : kToolbarHeight) +
                            8.0;
                        final maxExpandedHeight =
                            MediaQuery.sizeOf(context).height -
                            topBoundary -
                            actionBottom;
                        return AnimatedPadding(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          padding: EdgeInsets.only(bottom: actionBottom),
                          child: VideoActionButtons(
                            collectionId: widget.collectionId,
                            maxExpandedHeight: maxExpandedHeight,
                          ),
                        );
                      },
                    )
                  : null,
              bottomNavigationBar: MediaLibrarySelectionBarTransition(
                child: _isSelectionMode && _selectedIds.isNotEmpty
                    ? MediaLibrarySelectionBottomBar.folders(
                        cacheSelectedIds: Set.of(_selectedIds),
                        queueSelectedIds: [
                          for (final item in contents)
                            if (_selectedIds.contains(item.id))
                              item.id as String,
                        ],
                        onQueueProcessed: (ids) {
                          if (!mounted) return;
                          setState(() {
                            _selectedIds.removeAll(ids);
                            if (_selectedIds.isEmpty) _isSelectionMode = false;
                          });
                        },
                        onMoveToRecycleBin: () {
                          unawaited(_moveItemsToRecycleBin());
                        },
                        onExportFluentPack: () {
                          final ids = _selectedIds.toList();
                          setState(() {
                            _selectedIds.clear();
                            _isSelectionMode = false;
                          });
                          unawaited(
                            PortableTransferNavigation.openExportSettings(
                              context,
                              ids,
                            ),
                          );
                        },
                        onRename: _selectedIds.length == 1
                            ? () {
                                final id = _selectedIds.first;
                                final col = library.getCollection(id);
                                final vid = library.getVideo(id);
                                final name = col?.name ?? vid?.title ?? "";
                                _showRenameDialog(context, id, name);
                              }
                            : null,
                      )
                    : null,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMediaGridOrList({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<dynamic> contents,
    required double playbackCardBottomPadding,
  }) => MediaLibraryScrollViewport.library(
    settings: settings,
    screenSize: MediaQuery.sizeOf(context),
    controller: _scrollController,
    bottomObstruction: playbackCardBottomPadding,
    child: LayoutBuilder(
      builder: (context, constraints) => MediaLibraryCardPreload.library(
        context: context,
        settings: settings,
        controller: _scrollController,
        contents: contents,
        availableWidth: constraints.maxWidth,
        child: _buildMediaGridOrListContent(
          context: context,
          library: library,
          settings: settings,
          contents: contents,
          playbackCardBottomPadding: playbackCardBottomPadding,
          availableWidth: constraints.maxWidth,
        ),
      ),
    ),
  );

  Widget _buildMediaGridOrListContent({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<dynamic> contents,
    required double playbackCardBottomPadding,
    required double availableWidth,
  }) {
    if (settings.mediaLibraryViewMode == 0) {
      final metrics = MediaLibraryLayoutDefaults.cardGrid(
        textScaler: MediaQuery.textScalerOf(context),
        textStyle: DefaultTextStyle.of(context).style,
        screenSize: Size(availableWidth, MediaQuery.sizeOf(context).height),
        style: settings.collectionCardStyleFor(MediaQuery.sizeOf(context)),
      );
      return PlaybackGridView.builder(
        itemKey: (index) => (contents[index] as dynamic).id as String,
        controller: _scrollController,
        padding: EdgeInsets.only(
          left: metrics.outerPadding,
          right: metrics.outerPadding,
          top: metrics.topPadding,
          bottom: metrics.outerPadding + playbackCardBottomPadding,
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: metrics.crossAxisCount,
          childAspectRatio: metrics.aspectRatio.clamp(0.1, 5.0),
          crossAxisSpacing: metrics.crossSpacing,
          mainAxisSpacing: metrics.mainSpacing,
        ),
        itemCount: contents.length,
        itemBuilder: (context, index) => LibraryCardRebuild(
          itemId: (contents[index] as dynamic).id as String,
          key: ValueKey((contents[index] as dynamic).id),
          builder: (context) {
            final item = contents[index];
            final Widget card;
            if (item is VideoCollection) {
              card = _buildRevealHighlight(
                item.id,
                _buildCollectionCard(
                  context,
                  library,
                  item,
                  index,
                  settings,
                  contents,
                ),
              );
            } else if (item is VideoItem) {
              card = _buildRevealHighlight(
                item.id,
                _buildVideoCard(context, item, index, settings, contents),
              );
            } else {
              return const SizedBox.shrink();
            }
            return MediaCoverRevealStamp(
              index: index,
              crossAxisCount: metrics.crossAxisCount,
              child: card,
            );
          },
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
        final metrics = MediaListLayoutMetrics.forGrid(
          screenShortestSide: MediaQuery.sizeOf(context).shortestSide,
          availableWidth: constraints.maxWidth,
          crossAxisCount: listStyle.crossAxisCount,
          heightSetting: listStyle.heightScale,
          titleSetting: listStyle.titleScale,
          mainSpacingSetting: listStyle.mainSpacingScale,
          crossSpacingSetting: listStyle.crossSpacingScale,
        );

        return PlaybackGridView.builder(
          itemKey: (index) => (contents[index] as dynamic).id as String,
          controller: _scrollController,
          padding: EdgeInsets.only(
            left: metrics.outerPadding,
            right: metrics.outerPadding,
            top: metrics.topPadding,
            bottom: metrics.outerPadding + playbackCardBottomPadding,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: listStyle.crossAxisCount,
            mainAxisExtent: metrics.rowHeight,
            crossAxisSpacing: metrics.crossSpacing,
            mainAxisSpacing: metrics.mainSpacing,
          ),
          itemCount: contents.length,
          itemBuilder: (context, index) => LibraryCardRebuild(
            itemId: (contents[index] as dynamic).id as String,
            key: ValueKey((contents[index] as dynamic).id),
            builder: (context) {
              final item = contents[index];
              final Widget card;
              if (item is VideoCollection) {
                card = _buildRevealHighlight(
                  item.id,
                  _buildCollectionListCard(
                    context: context,
                    library: library,
                    collection: item,
                    index: index,
                    settings: settings,
                    contents: contents,
                  ),
                );
              } else if (item is VideoItem) {
                card = _buildRevealHighlight(
                  item.id,
                  _buildVideoListCard(
                    context: context,
                    library: library,
                    item: item,
                    index: index,
                    settings: settings,
                    contents: contents,
                  ),
                );
              } else {
                return const SizedBox.shrink();
              }
              return MediaCoverRevealStamp(
                index: index,
                crossAxisCount: listStyle.crossAxisCount,
                child: card,
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildCollectionListCard({
    required BuildContext context,
    required LibraryService library,
    required VideoCollection collection,
    required int index,
    required SettingsService settings,
    required List<dynamic> contents,
  }) {
    final isSelected = _selectedIds.contains(collection.id);
    void handleTap() {
      if (_isSelectionMode) {
        _toggleListSelection(collection.id);
      } else {
        Navigator.of(context).push(
          buildMediaLibraryFolderRoute<void>(
            folderId: collection.id,
            builder: (context) => CollectionScreen(collectionId: collection.id),
          ),
        );
      }
    }

    final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
    final tile = MediaLibraryListTile.collection(
      collection: collection,
      index: index,
      showIndex: listStyle.showIndex,
      showThumbnail: listStyle.showThumbnail,
      isSelected: isSelected,
      isSelectionMode: _isSelectionMode,
      titleScale: listStyle.titleScale,
      onShowInParentFolder: _isSearchResults
          ? () => _showInParentDirectory(collection)
          : null,
      onSelectionTap: () => _toggleListSelection(collection.id),
      onSelectionPanStart: (details) => _startListSelectionGesture(
        index,
        collection.id,
        details.globalPosition,
      ),
      onSelectionPanUpdate: (details) {
        _updateDragSelection(details.globalPosition);
      },
      onSelectionPanEnd: (_) => _endListSelectionGesture(),
      onSelectionLongPressStart: (details) => _startListSelectionGesture(
        index,
        collection.id,
        details.globalPosition,
      ),
      onSelectionLongPressMoveUpdate: (details) {
        _updateDragSelection(details.globalPosition);
      },
      onSelectionLongPressEnd: (_) => _endListSelectionGesture(),
      onTap: handleTap,
      onSecondaryTap: () => _handleCardSecondaryTap(collection.id),
      showActivityMenu: !_isSelectionMode,
      allowHidePodcastFromFolders: true,
      onMoveToParent: _moveToParentMenuAction(collection.id),
    );
    return MediaLibraryItemInteractionWrapper(
      index: index,
      dragDelay: _mediaCardLongPressDelay,
      isSelected: isSelected,
      selectedCount: _selectedIds.length,
      onDragStarted: () => _enterSelectionFromDrag(collection.id),
      onDragPosition: _updateReorderDragPosition,
      onDragEnd: _endReorderDrag,
      onTap: handleTap,
      allowReorder: _allowsFolderReorder(),
      onReorder: (oldIndex, newIndex) {
        if (!_allowsFolderReorder()) return;
        _reorderMediaItems(
          library,
          contents,
          widget.collectionId,
          oldIndex,
          newIndex,
        );
      },
      folderId: collection.id,
      onMoveToFolder: (draggedIndex, targetId) async {
        await _moveMediaItemsToFolder(
          library,
          contents,
          currentParentId: widget.collectionId,
          draggedIndex: draggedIndex,
          targetId: targetId,
        );
      },
      child: tile,
    );
  }

  Widget _buildVideoListCard({
    required BuildContext context,
    required LibraryService library,
    required VideoItem item,
    required int index,
    required SettingsService settings,
    required List<dynamic> contents,
  }) {
    final isSelected = _selectedIds.contains(item.id);
    void handleTap() {
      if (_isSelectionMode) {
        _toggleListSelection(item.id);
        return;
      }
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (!mounted) return;
      final controller = playbackService.currentItem?.id == item.id
          ? playbackService.controller
          : null;
      _openPlaybackScreen(item, existingController: controller);
    }

    final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
    final tile = MediaLibraryListTile.video(
      item: item,
      index: index,
      showIndex: listStyle.showIndex,
      showThumbnail: listStyle.showThumbnail,
      isSelected: isSelected,
      isSelectionMode: _isSelectionMode,
      titleScale: listStyle.titleScale,
      relativePath: _relativePathFor(library, item),
      onShowInParentFolder: _showParentLocate()
          ? () => _showInParentDirectory(item)
          : null,
      onSelectionTap: () => _toggleListSelection(item.id),
      onSelectionPanStart: (details) =>
          _startListSelectionGesture(index, item.id, details.globalPosition),
      onSelectionPanUpdate: (details) {
        _updateDragSelection(details.globalPosition);
      },
      onSelectionPanEnd: (_) => _endListSelectionGesture(),
      onSelectionLongPressStart: (details) =>
          _startListSelectionGesture(index, item.id, details.globalPosition),
      onSelectionLongPressMoveUpdate: (details) {
        _updateDragSelection(details.globalPosition);
      },
      onSelectionLongPressEnd: (_) => _endListSelectionGesture(),
      onTap: handleTap,
      onSecondaryTap: () => _handleCardSecondaryTap(item.id),
      showActivityMenu: !_isSelectionMode,
      onMoveToParent: _moveToParentMenuAction(item.id),
    );
    return MediaLibraryItemInteractionWrapper(
      index: index,
      dragDelay: _mediaCardLongPressDelay,
      isSelected: isSelected,
      selectedCount: _selectedIds.length,
      onDragStarted: () => _enterSelectionFromDrag(item.id),
      onDragPosition: _updateReorderDragPosition,
      onDragEnd: _endReorderDrag,
      onTap: handleTap,
      allowReorder: _allowsFolderReorder(),
      onReorder: (oldIndex, newIndex) {
        if (!_allowsFolderReorder()) return;
        _reorderMediaItems(
          library,
          contents,
          widget.collectionId,
          oldIndex,
          newIndex,
        );
      },
      child: tile,
    );
  }

  void _toggleListSelection(String itemId) {
    setState(() {
      if (_selectedIds.contains(itemId)) {
        _selectedIds.remove(itemId);
      } else {
        _selectedIds.add(itemId);
      }
    });
  }

  /// 键鼠右击卡片：未在选择模式则进入并选中；已在选择模式则切换该项。
  void _handleCardSecondaryTap(String itemId) {
    if (!_isSelectionMode) {
      setState(() {
        _isSelectionMode = true;
        _selectedIds.add(itemId);
      });
      return;
    }
    _toggleListSelection(itemId);
  }

  void _enterSelectionFromDrag(String itemId) {
    // 已在选择模式时不要把未选中项强行加入选区：用户可能只是想单独拖动这一项。
    if (_isSelectionMode) return;
    setState(() {
      _isSelectionMode = true;
      _selectedIds.add(itemId);
    });
  }

  void _startListSelectionGesture(
    int index,
    String itemId,
    Offset globalPosition,
  ) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    // The anchor is copied into the snapshot before the range merge, so the
    // merge sees no difference and would stay silent on the card under the
    // finger. Cards entered later already pulse in [_applyDragSelectionAt].
    final newlySelected = !_selectedIds.contains(itemId);
    setState(() {
      _dragSelectionStartIndex = index;
      _dragSelectionSnapshot = Set.from(_selectedIds);
      _capturedIds.clear();
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      if (newlySelected) {
        _selectedIds.add(itemId);
        _dragSelectionSnapshot.add(itemId);
      }
      _updateDragSelection(globalPosition);
    });
    if (newlySelected) {
      unawaited(AppHaptics.selectionClick(settings));
    }
  }

  void _endListSelectionGesture() {
    _stopSelectionAutoScroll();
    _lastDragSelectionGlobalPos = null;
    setState(() {
      _dragSelectionStartIndex = null;
      _dragSelectionSnapshot.clear();
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      _capturedIds.clear();
    });
  }

  void _reorderMediaItems(
    LibraryService library,
    List<dynamic> contents,
    String? parentId,
    int oldIndex,
    int newIndex,
  ) {
    if (!_allowsFolderReorder()) return;
    if (oldIndex < 0 || oldIndex >= contents.length) return;
    final draggedId = (contents[oldIndex] as dynamic).id as String;
    if (_selectedIds.contains(draggedId)) {
      final itemIds = contents
          .where((item) => _selectedIds.contains((item as dynamic).id))
          .map((item) => (item as dynamic).id as String)
          .toList();
      library.reorderMultipleItems(parentId, itemIds, oldIndex, newIndex);
    } else {
      library.reorderItems(parentId, oldIndex, newIndex);
    }
  }

  Future<void> _moveMediaItemsToFolder(
    LibraryService library,
    List<dynamic> contents, {
    required String? currentParentId,
    required int draggedIndex,
    required String targetId,
  }) async {
    if (draggedIndex < 0 || draggedIndex >= contents.length) return;
    final draggedId = (contents[draggedIndex] as dynamic).id as String;
    final itemIds = _selectedIds.contains(draggedId)
        ? contents
              .where((item) => _selectedIds.contains((item as dynamic).id))
              .map((item) => (item as dynamic).id as String)
              .toList()
        : <String>[draggedId];
    await library.moveItemsToCollection(itemIds, targetId);
    await _syncSelectionAfterMove(
      library,
      currentParentId: currentParentId,
      attemptedItemIds: itemIds,
    );
    AppToast.show("已移动到文件夹", type: AppToastType.success);
  }

  Widget _buildCollectionCard(
    BuildContext context,
    LibraryService library,
    VideoCollection collection,
    int index,
    SettingsService settings,
    List<dynamic> contents,
  ) {
    return MediaLibraryCardScale(
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final double cardWidth = constraints.maxWidth;
          final chipSize = MediaLibraryActionDockMetrics.gridChipSize(
            cardWidth,
          );
          final showMenu = !_isSelectionMode;
          final showSync =
              showMenu && mediaLibraryFolderIsSynced(context, collection.id);
          final showLocate = _isSearchResults && !_isSelectionMode;
          final textInset = MediaLibraryActionDockMetrics.textInset(
            chipSize: chipSize,
            showMore: showMenu,
            showSync: showSync,
            showLocate: showLocate,
            existingPadding: MediaListLayoutMetrics.cardGridContentPadding(
              cardWidth,
            ).right,
          );
          final double radius = MediaLibraryLayoutDefaults.cardCornerRadius(
            cardWidth,
          );
          final double titleFontSize = _resolveCardTitleFontSize(
            cardWidth,
            settings
                .collectionCardStyleFor(MediaQuery.sizeOf(context))
                .titleScale,
          );
          final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);

          final isSelected = _selectedIds.contains(collection.id);
          final thumbnailPath = collection.thumbnailPath;
          final hasThumbnail =
              thumbnailPath != null && thumbnailPath.isNotEmpty;

          // 1. Visual Content
          Widget cardVisual = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Thumbnail Area (Fixed Folder Icon)
              AspectRatio(
                aspectRatio: _mediaCardCoverAspectRatio,
                child: LayoutBuilder(
                  builder: (context, iconConstraints) {
                    if (collection.isPodcast) {
                      return PodcastCardCover(collection: collection);
                    }
                    final iconSize = iconConstraints.maxWidth * 0.15;
                    final iconPadding = iconSize * 0.4;
                    final borderRadius = iconSize * 0.6;
                    final Widget placeholder = FolderPlaceholderCover(
                      folderId: collection.id,
                      folderName: collection.name,
                      coverLabel: collection.coverLabel,
                    );

                    return Container(
                      color: Colors.black26,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Layer 1: Thumbnail or Placeholder
                          hasThumbnail
                              ? CachedThumbnailWidget(
                                  videoId: collection.id,
                                  thumbnailPath: thumbnailPath,
                                  cacheWidth:
                                      (constraints.maxWidth *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .round(),
                                  cacheHeight:
                                      (constraints.maxHeight *
                                              MediaQuery.devicePixelRatioOf(
                                                context,
                                              ))
                                          .round(),
                                  placeholder: const SizedBox.expand(
                                    child: ColoredBox(color: Colors.black26),
                                  ),
                                  errorWidget: placeholder,
                                )
                              : placeholder,
                          // Layer 2: Folder Badge (Top-Left) - Only if has thumbnail
                          if (hasThumbnail)
                            Positioned(
                              left: 0,
                              top: 0,
                              child: Container(
                                padding: EdgeInsets.all(iconPadding),
                                decoration: BoxDecoration(
                                  color: Colors.black45,
                                  borderRadius: BorderRadius.only(
                                    bottomRight: Radius.circular(borderRadius),
                                  ),
                                ),
                                child: Icon(
                                  Icons.folder,
                                  size: iconSize,
                                  color: Colors.blueAccent.withValues(
                                    alpha: 0.9,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // Info Area
              Expanded(
                child: Container(
                  padding: MediaListLayoutMetrics.cardGridContentPadding(
                    cardWidth,
                  ),
                  color: isSelected
                      ? Colors.blueAccent.withValues(alpha: 0.1)
                      : Colors.transparent,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          collection.name,
                          style: TextStyle(
                            fontSize: titleFontSize,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                          maxLines: settings.cardTitleMaxLinesFor(
                            MediaQuery.sizeOf(context),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Padding(
                        padding: EdgeInsets.only(right: textInset),
                        child: Text(
                          collection.isPodcast
                              ? podcastLibrarySummary(collection)
                              : '${collection.childrenIds.length} 个项目',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
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
          );

          // 2. Interaction Wrapper
          void handleTap() {
            if (_isSelectionMode) {
              _toggleListSelection(collection.id);
            } else {
              Navigator.of(context).push(
                buildMediaLibraryFolderRoute<void>(
                  folderId: collection.id,
                  builder: (context) =>
                      CollectionScreen(collectionId: collection.id),
                ),
              );
            }
          }

          Widget interactiveCard = MediaLibraryGridCard(
            radius: radius,
            isSelected: isSelected,
            onTap: handleTap,
            onSecondaryTap: () => _handleCardSecondaryTap(collection.id),
            elevation: isSelected ? 3 : 0,
            child: Stack(
              fit: StackFit.expand,
              children: [
                cardVisual,
                MediaLibraryActionDock(
                  chipSize: chipSize,
                  sync: showSync
                      ? MediaLibraryFolderSyncButton(
                          collectionId: collection.id,
                          fillSlot: true,
                        )
                      : null,
                  more: showMenu
                      ? MediaLibraryActivityMenuButton(
                          targetId: collection.id,
                          isCollection: true,
                          allowHide: false,
                          allowHidePodcastFromFolders: true,
                          onMoveToParent: _moveToParentMenuAction(
                            collection.id,
                          ),
                          fillSlot: true,
                        )
                      : null,
                  locate: showLocate
                      ? MediaLibraryLocateButton(
                          onPressed: () => _showInParentDirectory(collection),
                        )
                      : null,
                ),
              ],
            ),
          );

          return Stack(
            children: [
              MediaLibraryAdaptiveDraggable<int>(
                delay: _mediaCardLongPressDelay,
                data: index,
                onTap: handleTap,
                onDragStarted: () {
                  if (!_isSelectionMode) {
                    setState(() {
                      _isSelectionMode = true;
                      if (!_selectedIds.contains(collection.id)) {
                        _selectedIds.add(collection.id);
                      }
                    });
                  }
                },
                onDragPosition: _updateReorderDragPosition,
                onDragEnd: _endReorderDrag,
                feedback: SizedBox(
                  width: 140,
                  height: 160,
                  child: Opacity(
                    opacity: 0.9,
                    child: Card(
                      color: const Color(0xFF333333),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(140 * 0.09),
                      ),
                      child: Center(
                        child: _selectedIds.length > 1 && isSelected
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.folder,
                                    size: 50,
                                    color: Colors.blueAccent,
                                  ),
                                  Text(
                                    "${_selectedIds.length} 个项目",
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              )
                            : Icon(
                                Icons.folder,
                                size: 60,
                                color: Colors.blueAccent,
                              ),
                      ),
                    ),
                  ),
                ),
                childWhenDragging: Opacity(
                  opacity: 0.3,
                  child: interactiveCard,
                ),
                child: FolderDropTarget(
                  folderId: collection.id,
                  index: index,
                  allowReorder: _allowsFolderReorder(),
                  onMoveToFolder: (draggedIndex, targetId) async {
                    if (draggedIndex >= 0 && draggedIndex < contents.length) {
                      final draggedItem = contents[draggedIndex];
                      final draggedId = (draggedItem as dynamic).id;

                      List<String> itemsToMove = [];
                      if (_selectedIds.contains(draggedId)) {
                        itemsToMove = contents
                            .where(
                              (item) =>
                                  _selectedIds.contains((item as dynamic).id),
                            )
                            .map((item) => (item as dynamic).id as String)
                            .toList();
                      } else {
                        itemsToMove = [draggedId];
                      }

                      await library.moveItemsToCollection(
                        itemsToMove,
                        targetId,
                      );
                      await _syncSelectionAfterMove(
                        library,
                        currentParentId: widget.collectionId,
                        attemptedItemIds: itemsToMove,
                      );
                      AppToast.show("已移动到文件夹", type: AppToastType.success);
                    }
                  },
                  onReorder: (oldIndex, newIndex) {
                    if (!_allowsFolderReorder()) return;
                    final draggedItem = contents[oldIndex];
                    final draggedId = (draggedItem as dynamic).id;

                    if (_selectedIds.contains(draggedId)) {
                      final itemsToMove = contents
                          .where(
                            (item) =>
                                _selectedIds.contains((item as dynamic).id),
                          )
                          .map((item) => (item as dynamic).id as String)
                          .toList();
                      library.reorderMultipleItems(
                        widget.collectionId,
                        itemsToMove,
                        oldIndex,
                        newIndex,
                      );
                    } else {
                      library.reorderItems(
                        widget.collectionId,
                        oldIndex,
                        newIndex,
                      );
                    }
                  },
                  child: interactiveCard,
                ),
              ),
              if (_isSelectionMode)
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => _toggleListSelection(collection.id),
                    onPanStart: (details) {
                      setState(() {
                        _dragSelectionStartIndex = index;
                        _dragSelectionSnapshot = Set.from(_selectedIds);
                        _capturedIds.clear();
                        _isBoxSelecting = false;
                        _boxStartPos = null;
                        _boxCurrentPos = null;
                        if (!_selectedIds.contains(collection.id)) {
                          _selectedIds.add(collection.id);
                          _dragSelectionSnapshot.add(collection.id);
                        }
                        _updateDragSelection(details.globalPosition);
                      });
                    },
                    onPanUpdate: (details) {
                      _updateDragSelection(details.globalPosition);
                    },
                    onPanEnd: (_) => _endListSelectionGesture(),
                    onLongPressStart: (details) {
                      setState(() {
                        _dragSelectionStartIndex = index;
                        _dragSelectionSnapshot = Set.from(_selectedIds);
                        _capturedIds.clear();
                        _isBoxSelecting = false;
                        _boxStartPos = null;
                        _boxCurrentPos = null;
                        if (!_selectedIds.contains(collection.id)) {
                          _selectedIds.add(collection.id);
                          _dragSelectionSnapshot.add(collection.id);
                        }
                        _updateDragSelection(details.globalPosition);
                      });
                    },
                    onLongPressMoveUpdate: (details) {
                      _updateDragSelection(details.globalPosition);
                    },
                    onLongPressEnd: (_) => _endListSelectionGesture(),
                    behavior: HitTestBehavior
                        .opaque, // Opaque to ensure it captures touches in this area
                    child: Padding(
                      padding: EdgeInsets.all(
                        MediaListLayoutMetrics.gridSelectionHitPadding(
                          cardWidth,
                        ),
                      ),
                      child: Icon(
                        isSelected ? Icons.check_circle : Icons.circle_outlined,
                        color: isSelected ? Colors.blueAccent : Colors.white70,
                        size: MediaListLayoutMetrics.gridSelectionIconSize(
                          cardWidth,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildVideoCard(
    BuildContext context,
    VideoItem item,
    int index,
    SettingsService settings,
    List<dynamic> contents,
  ) {
    return MediaLibraryCardScale(
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          final double cardWidth = constraints.maxWidth;
          final chipSize = MediaLibraryActionDockMetrics.gridChipSize(
            cardWidth,
          );
          final showMenu = !_isSelectionMode;
          final showLocate = _showParentLocate() && !_isSelectionMode;
          final textInset = MediaLibraryActionDockMetrics.textInset(
            chipSize: chipSize,
            showMore: showMenu,
            showLocate: showLocate,
            existingPadding: MediaListLayoutMetrics.cardGridContentPadding(
              cardWidth,
            ).right,
          );
          final double radius = MediaLibraryLayoutDefaults.cardCornerRadius(
            cardWidth,
          );
          final double titleFontSize = _resolveCardTitleFontSize(
            cardWidth,
            settings
                .collectionCardStyleFor(MediaQuery.sizeOf(context))
                .titleScale,
          );
          final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);
          final library = Provider.of<LibraryService>(context, listen: false);
          final relativePath = _relativePathFor(library, item);

          final isSelected = _selectedIds.contains(item.id);

          // 1. Visual Content
          Widget cardVisual = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Thumbnail Area
              AspectRatio(
                aspectRatio: _mediaCardCoverAspectRatio,
                child: Container(
                  color: Colors.black26,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      item.type == MediaType.audio
                          ? LayoutBuilder(
                              builder: (context, thumbConstraints) {
                                final icon = _scaledThumbnailIcon(
                                  extent: thumbConstraints.biggest.shortestSide,
                                  icon: Icons.music_note,
                                );
                                if (item.thumbnailPath != null &&
                                    item.thumbnailPath!.isNotEmpty) {
                                  return CachedThumbnailWidget(
                                    videoId: item.id,
                                    thumbnailPath: item.thumbnailPath,
                                    fit: BoxFit.cover,
                                    placeholder: icon,
                                    errorWidget: icon,
                                  );
                                }
                                return icon;
                              },
                            )
                          : LayoutBuilder(
                              builder: (context, constraints) {
                                final partPage = bilibiliPartCoverPage(item);
                                if (partPage != null) {
                                  return BilibiliPartCover(
                                    identity: item.id,
                                    page: partPage,
                                  );
                                }
                                final dpr = MediaQuery.devicePixelRatioOf(
                                  context,
                                );
                                final cacheWidth = (constraints.maxWidth * dpr)
                                    .round()
                                    .clamp(1, 4096);
                                final cacheHeight =
                                    (constraints.maxHeight * dpr).round().clamp(
                                      1,
                                      4096,
                                    );
                                final icon = _scaledThumbnailIcon(
                                  extent: constraints.biggest.shortestSide,
                                  icon: Icons.movie,
                                );

                                return CachedThumbnailWidget(
                                  videoId: item.id,
                                  thumbnailPath: item.thumbnailPath,
                                  fit: BoxFit.cover,
                                  cacheWidth: cacheWidth,
                                  cacheHeight: cacheHeight,
                                  placeholder: icon,
                                  errorWidget: icon,
                                );
                              },
                            ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child:
                            Selector<
                              MediaPlaybackService,
                              ({bool isCurrent, int durationMs})
                            >(
                              selector: (context, service) {
                                final isCurrent =
                                    service.currentItem?.id == item.id;
                                if (!isCurrent) {
                                  return (isCurrent: false, durationMs: 0);
                                }
                                return (
                                  isCurrent: true,
                                  durationMs: service.duration.inMilliseconds,
                                );
                              },
                              builder: (context, data, child) {
                                final bool isCurrent = data.isCurrent;
                                final int durationMs = isCurrent
                                    ? data.durationMs
                                    : item.durationMs;
                                Widget buildProgress(int positionMs) {
                                  final shouldShow =
                                      durationMs > 0 &&
                                      (isCurrent || positionMs > 0);
                                  if (!shouldShow) {
                                    return const SizedBox.shrink();
                                  }
                                  return SizedBox(
                                    height: 4,
                                    child: LinearProgressIndicator(
                                      value: (positionMs / durationMs).clamp(
                                        0.0,
                                        1.0,
                                      ),
                                      backgroundColor: Colors.white24,
                                      color: Colors.redAccent,
                                    ),
                                  );
                                }

                                if (!isCurrent) {
                                  return buildProgress(item.lastPositionMs);
                                }
                                final service = context
                                    .read<MediaPlaybackService>();
                                return ValueListenableBuilder<Duration>(
                                  valueListenable:
                                      service.coarsePositionNotifier,
                                  builder: (_, position, _) =>
                                      buildProgress(position.inMilliseconds),
                                );
                              },
                            ),
                      ),
                    ],
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
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: titleFontSize,
                            fontWeight: FontWeight.w500,
                            color: Colors.white,
                          ),
                          maxLines: settings.cardTitleMaxLinesFor(
                            MediaQuery.sizeOf(context),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (relativePath != null)
                        Padding(
                          padding: EdgeInsets.only(right: textInset),
                          child: Text(
                            relativePath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: metaFontSize,
                              color: Colors.white38,
                            ),
                          ),
                        ),
                      if (item.durationMs > 0) ...[
                        const SizedBox(height: 4),
                        Padding(
                          padding: EdgeInsets.only(right: textInset),
                          child: Text(
                            "${(item.durationMs / 1000 / 60).floor()}:${((item.durationMs / 1000) % 60).floor().toString().padLeft(2, '0')}",
                            style: TextStyle(
                              fontSize: metaFontSize,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );

          // 2. Interaction Wrapper
          void handleTap() {
            if (_isSelectionMode) {
              _toggleListSelection(item.id);
            } else {
              final playbackService = Provider.of<MediaPlaybackService>(
                context,
                listen: false,
              );

              if (!context.mounted) return;

              final currentController =
                  playbackService.currentItem?.id == item.id
                  ? playbackService.controller
                  : null;
              _openPlaybackScreen(item, existingController: currentController);
            }
          }

          Widget interactiveCard = MediaLibraryGridCard(
            radius: radius,
            isSelected: isSelected,
            onTap: handleTap,
            onSecondaryTap: () => _handleCardSecondaryTap(item.id),
            cacheItem: item,
            isSelectionMode: _isSelectionMode,
            child: Stack(
              fit: StackFit.expand,
              children: [
                cardVisual,
                MediaLibraryActionDock(
                  chipSize: chipSize,
                  more: showMenu
                      ? MediaLibraryActivityMenuButton(
                          targetId: item.id,
                          isCollection: false,
                          onMoveToParent: _moveToParentMenuAction(item.id),
                          fillSlot: true,
                        )
                      : null,
                  locate: showLocate
                      ? MediaLibraryLocateButton(
                          onPressed: () => _showInParentDirectory(item),
                        )
                      : null,
                ),
              ],
            ),
          );

          return Stack(
            children: [
              MediaLibraryAdaptiveDraggable<int>(
                delay: _mediaCardLongPressDelay,
                data: index,
                onTap: handleTap,
                onDragStarted: () {
                  if (!_isSelectionMode) {
                    setState(() {
                      _isSelectionMode = true;
                      if (!_selectedIds.contains(item.id)) {
                        _selectedIds.add(item.id);
                      }
                    });
                  }
                },
                onDragPosition: _updateReorderDragPosition,
                onDragEnd: _endReorderDrag,
                feedback: SizedBox(
                  width: 140,
                  height: 160,
                  child: Opacity(
                    opacity: 0.9,
                    child: Card(
                      color: const Color(0xFF333333),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(140 * 0.09),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.movie,
                          size: 60,
                          color: Colors.blueAccent,
                        ),
                      ),
                    ),
                  ),
                ),
                childWhenDragging: Opacity(
                  opacity: 0.3,
                  child: interactiveCard,
                ),
                child: DragTarget<int>(
                  onWillAcceptWithDetails: (details) =>
                      _allowsFolderReorder() && details.data != index,
                  onAcceptWithDetails: (details) {
                    if (!_allowsFolderReorder()) return;
                    final oldIndex = details.data;
                    final library = Provider.of<LibraryService>(
                      context,
                      listen: false,
                    );
                    final draggedItem = contents[oldIndex];
                    final draggedId = (draggedItem as dynamic).id;

                    if (_selectedIds.contains(draggedId)) {
                      final itemsToMove = contents
                          .where(
                            (item) =>
                                _selectedIds.contains((item as dynamic).id),
                          )
                          .map((item) => (item as dynamic).id as String)
                          .toList();
                      library.reorderMultipleItems(
                        widget.collectionId,
                        itemsToMove,
                        oldIndex,
                        index,
                      );
                    } else {
                      library.reorderItems(
                        widget.collectionId,
                        oldIndex,
                        index,
                      );
                    }
                  },
                  builder: (context, candidateData, rejectedData) {
                    Widget targetChild = interactiveCard;
                    if (candidateData.isNotEmpty) {
                      targetChild = Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.blueAccent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(radius),
                        ),
                        child: interactiveCard,
                      );
                    }
                    return targetChild;
                  },
                ),
              ),
              if (_isSelectionMode)
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => _toggleListSelection(item.id),
                    onPanStart: (details) {
                      setState(() {
                        _dragSelectionStartIndex = index;
                        _dragSelectionSnapshot = Set.from(_selectedIds);
                        _capturedIds.clear();
                        _isBoxSelecting = false;
                        _boxStartPos = null;
                        _boxCurrentPos = null;
                        if (!_selectedIds.contains(item.id)) {
                          _selectedIds.add(item.id);
                          _dragSelectionSnapshot.add(item.id);
                        }
                        _updateDragSelection(details.globalPosition);
                      });
                    },
                    onPanUpdate: (details) {
                      _updateDragSelection(details.globalPosition);
                    },
                    onPanEnd: (_) => _endListSelectionGesture(),
                    onLongPressStart: (details) {
                      setState(() {
                        _dragSelectionStartIndex = index;
                        _dragSelectionSnapshot = Set.from(_selectedIds);
                        _capturedIds.clear();
                        _isBoxSelecting = false;
                        _boxStartPos = null;
                        _boxCurrentPos = null;
                        if (!_selectedIds.contains(item.id)) {
                          _selectedIds.add(item.id);
                          _dragSelectionSnapshot.add(item.id);
                        }
                        _updateDragSelection(details.globalPosition);
                      });
                    },
                    onLongPressMoveUpdate: (details) {
                      _updateDragSelection(details.globalPosition);
                    },
                    onLongPressEnd: (_) => _endListSelectionGesture(),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: EdgeInsets.all(
                        MediaListLayoutMetrics.gridSelectionHitPadding(
                          cardWidth,
                        ),
                      ),
                      child: Icon(
                        isSelected ? Icons.check_circle : Icons.circle_outlined,
                        color: isSelected ? Colors.blueAccent : Colors.white70,
                        size: MediaListLayoutMetrics.gridSelectionIconSize(
                          cardWidth,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _showRenameDialog(BuildContext context, String id, String currentName) {
    showLibraryRenameDialog(
      context: context,
      itemId: id,
      currentName: currentName,
    );
  }

  Future<void> _loadExportButtonPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('show_export_settings_button') ?? false;
    if (value == _showExportSettingsButton) return;
    if (!mounted) {
      _showExportSettingsButton = value;
      return;
    }
    setState(() {
      _showExportSettingsButton = value;
    });
  }

  /// Hidden entry: long-press the recycle-bin icon on the collection app bar.
  Future<void> _toggleExportButtonVisibility() async {
    final newValue = !_showExportSettingsButton;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('show_export_settings_button', newValue);
    if (!mounted) return;
    setState(() {
      _showExportSettingsButton = newValue;
    });
    AppToast.show(
      newValue ? '导出与测试设置入口已显示' : '导出与测试设置入口已隐藏',
      type: AppToastType.info,
    );
  }

  Future<void> _exportSettingsSnapshot() => exportAppSettings(context);

  Future<void> _showLargeDataPathDialog(BuildContext context) async {
    await showAppStorageSettingsDialog(context);
  }
}

class _BoxSelectionPainter extends CustomPainter {
  final Rect? selectionRect;

  _BoxSelectionPainter({this.selectionRect});

  @override
  void paint(Canvas canvas, Size size) {
    if (selectionRect == null) return;

    final paint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawRect(selectionRect!, paint);
    canvas.drawRect(selectionRect!, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BoxSelectionPainter oldDelegate) {
    return oldDelegate.selectionRect != selectionRect;
  }
}
