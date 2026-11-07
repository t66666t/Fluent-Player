import '../utils/app_branding.dart';
import '../widgets/bilibili_part_cover.dart';
import '../widgets/media_library_card_preload.dart';
import '../widgets/library_card_rebuild.dart';
import '../services/experimental_layout.dart';
import '../widgets/experimental_layout_widgets.dart';
export '../utils/clipboard_link.dart' show clipboardWatchBvid;

import '../widgets/clipboard_detection_scope.dart';
import '../widgets/media_library_card_scale.dart';
import '../widgets/storage_settings_dialog.dart';
import '../widgets/keyboard_shortcut_help.dart';
import '../utils/keyboard_shortcut_hints.dart';
import 'dart:io';
import '../features/podcasts/podcast_pages.dart';
import '../features/podcasts/podcast_widgets.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import '../theme/app_tokens.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../widgets/settings_export_action.dart';
import '../widgets/default_settings_trial_action.dart';
import '../features/onboarding/onboarding_flow.dart';
import '../features/onboarding/onboarding_store.dart';
import '../services/app_haptics.dart';
import 'collection_screen.dart';
import '../widgets/media_library_folder_route.dart';
import '../widgets/media_library_shell.dart';
import '../widgets/media_query_padding_remover.dart';
import '../widgets/playback_source_viewport.dart';
import '../utils/stable_system_ui_insets.dart';
import 'recycle_bin_screen.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../widgets/folder_drop_target.dart';
import '../widgets/cached_thumbnail_widget.dart';
import '../widgets/folder_placeholder_cover.dart';
import '../widgets/library_rename_dialog.dart';
import '../widgets/media_library_list_tile.dart';
import '../widgets/media_display_title.dart';
import '../widgets/media_library_item_interaction_wrapper.dart';
import '../widgets/media_library_grid_card.dart';
import '../widgets/media_library_keyboard_navigation.dart';
import '../widgets/media_library_gestures.dart';
import '../widgets/media_library_activity_menu.dart';
import '../widgets/media_library_action_dock.dart';
import '../widgets/media_library_empty_state.dart';
import '../widgets/media_library_folder_sync_button.dart';
import '../widgets/media_library_layout_profile.dart';
import '../widgets/media_library_scroll_viewport.dart';
import '../widgets/media_library_style_sheet.dart';
import '../widgets/media_list_layout_metrics.dart';
import '../debug/debug_log_overlay.dart';
import '../widgets/media_library_settings_sheet.dart';
import '../widgets/media_library_search_prompt.dart';
import '../services/home_search_navigation.dart';
import '../widgets/media_library_compact_app_bar.dart';
import '../features/external_ai/external_ai_toolbar_action.dart';
import '../features/external_ai/external_ai_workspace_context.dart';
import '../widgets/media_library_entry_switcher.dart';
import '../widgets/media_library_recent_intent.dart';
import '../widgets/media_library_recent_view.dart';
import '../widgets/media_library_continue_view.dart';
import '../widgets/media_library_root_surface_host.dart';
import '../models/media_library_root_entry.dart';
import '../models/media_library_view_mode.dart';
import '../widgets/media_library_table_header.dart';
import '../widgets/media_library_table_sort.dart';
import '../models/media_library_root_entry_order.dart';
import '../services/media_library_navigation.dart';
import '../widgets/media_library_selection_bottom_bar.dart';
import '../widgets/media_library_selection_drop_targets.dart';
import '../widgets/media_library_top_bar_import_progress.dart';
import '../widgets/media_library_virtual_selection_host.dart';
import '../utils/media_library_virtual_selection_actions.dart';
import '../features/portable_transfer/portable_transfer_navigation.dart';
import 'package:flutter/services.dart';

import '../widgets/playback_card_layout.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../widgets/video_action_buttons.dart';
import '../widgets/responsive_icon_button.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/playlist_manager.dart';
import '../services/startup_notification_permission.dart';
import 'dart:convert';
import '../utils/app_toast.dart';
import '../utils/media_library_range_selection.dart';
import '../utils/desktop_media_management_shortcuts.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/hardware_keyboard_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';
import '../utils/media_library_entry_shortcuts.dart';

import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class _BoxSelectionPainter extends CustomPainter {
  final Rect selectionRect;

  _BoxSelectionPainter({required this.selectionRect});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawRect(selectionRect, paint);
    canvas.drawRect(selectionRect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _BoxSelectionPainter oldDelegate) {
    return selectionRect != oldDelegate.selectionRect;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.revealItemId,
    this.returnToSearchResults = false,
  });

  final String? revealItemId;
  final bool returnToSearchResults;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = {};
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
  MediaPlaybackService? _listenedPlaybackService;

  // Track items that have been "touched" by the current box selection session
  final Set<String> _capturedIds = {};
  Offset? _lastDragSelectionGlobalPos;
  MediaLibrarySelectionAutoScroller? _selectionAutoScroller;
  final MediaLibrarySelectionPointerSession _selectionPointer =
      MediaLibrarySelectionPointerSession();
  final MediaLibraryReorderDragSession _reorderDrag =
      MediaLibraryReorderDragSession();

  // Added variables for missing definitions
  bool _hasPendingPlaybackState = false;
  double _stablePlaybackBottomInset = 0.0;
  late final _playbackInsets = StableSystemUiInsetController(
    includeSystemGestureInsets: true,
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  bool _showExportSettingsButton = false;
  final FocusNode _shortcutFocusNode = FocusNode();
  final GlobalKey<MediaLibraryKeyboardRegionState> _keyboardRegionKey =
      GlobalKey<MediaLibraryKeyboardRegionState>();
  bool? _lastIsFullScreen;
  late final AnimationController _revealHighlightController;
  Timer? _revealHighlightTimer;
  bool _didScheduleReveal = false;
  bool _didPersistRootEntryDefault = false;
  bool _didRestoreLastFolderRoute = false;
  bool _libraryNavigationScheduled = false;
  final ScrollController _recentScrollController = PlaybackScrollController();
  final ScrollController _continueScrollController = PlaybackScrollController();
  // The Bilibili page scrolls its own lists; this one is never attached.
  final ScrollController _bilibiliScrollController = ScrollController();
  final ScrollController _podcastsScrollController = ScrollController();
  final PodcastOverviewController _podcastOverviewController =
      PodcastOverviewController();
  final MediaLibraryVirtualSelectionHost _continueSelectionHost =
      MediaLibraryVirtualSelectionHost();
  final MediaLibraryVirtualSelectionHost _recentSelectionHost =
      MediaLibraryVirtualSelectionHost();
  final ValueNotifier<MediaLibraryRootEntry?> _rootEntryOverride =
      ValueNotifier<MediaLibraryRootEntry?>(null);
  final ValueNotifier<double> _rootSwipeHighlight = ValueNotifier<double>(0);
  final ValueNotifier<bool> _rootSwipeSettled = ValueNotifier<bool>(true);
  final ValueNotifier<List<MediaLibraryRootEntry>> _rootEntryOrder =
      ValueNotifier<List<MediaLibraryRootEntry>>(
        List<MediaLibraryRootEntry>.of(MediaLibraryRootEntryOrder.defaults),
      );
  final GlobalKey _rootSurfaceHostKey = GlobalKey();
  String? _pendingRecentBatchId;

  static const Set<MediaLibraryRootEntry> _mountedRootEntries = {
    MediaLibraryRootEntry.continueLearning,
    MediaLibraryRootEntry.recent,
    MediaLibraryRootEntry.folders,
    MediaLibraryRootEntry.podcasts,
  };

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _libraryShell = MediaLibraryShell.maybeOf(context);
    _publishExternalAiWorkspace();
  }

  void _publishExternalAiWorkspace() {
    final workspace = ExternalAiWorkspaceContext.instance;
    if (!mounted || !isMediaLibraryRouteCurrent(context)) {
      workspace.clear(this);
      return;
    }
    final library = context.read<LibraryService>();
    final view = !library.isInitialized || !_rootSwipeSettled.value
        ? ExternalAiWorkspaceView.unknown
        : switch (_displayedRootEntry()) {
            MediaLibraryRootEntry.folders =>
              ExternalAiWorkspaceView.libraryRoot,
            MediaLibraryRootEntry.recent => ExternalAiWorkspaceView.recent,
            MediaLibraryRootEntry.continueLearning =>
              ExternalAiWorkspaceView.continueLearning,
            _ => ExternalAiWorkspaceView.unknown,
          };
    workspace.publish(owner: this, viewType: view);
  }

  List<dynamic> _visibleBrowseContents(
    LibraryService library,
    SettingsService settings,
  ) {
    final raw = library.browseContents(null);
    if (settings.mediaLibraryContentLayout == MediaLibraryContentLayout.table) {
      return sortMediaLibraryContents(
        raw,
        settings.mediaTableSort,
        settings.mediaTableSortDescending,
        library: library,
      );
    }
    return raw;
  }

  bool _showUndockedFolderTreeButton(SettingsService settings) {
    if (!settings.mediaLibraryShowsFolderTree) return false;
    final shell = _libraryShell ?? MediaLibraryShell.maybeOf(context);
    return shell != null && !shell.folderTreeDocked;
  }

  Widget _buildFolderTreeToolbarButton({required bool compact}) {
    void openTree() => _libraryShell?.openFolderTree();
    if (compact) {
      return MediaLibraryCompactIconButton(
        icon: Icons.account_tree_outlined,
        tooltip: '文件夹树',
        onPressed: openTree,
      );
    }
    return DesktopButtonClickRegion(
      child: IconButton(
        icon: const Icon(Icons.account_tree_outlined, color: AppTokens.text2),
        tooltip: '文件夹树',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        onPressed: openTree,
      ),
    );
  }

  Widget _wrapScrollAreaWithTableHeader({
    required BuildContext context,
    required SettingsService settings,
    required Widget child,
  }) {
    final isTable =
        settings.mediaLibraryContentLayout == MediaLibraryContentLayout.table;
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final duration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 200);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final style = settings.listStyleFor(MediaQuery.sizeOf(context));
        final headerHeight = isTable
            ? MediaLibraryTableHeader.heightFor(style, width: width)
            : 0.0;

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            AnimatedPadding(
              duration: duration,
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(top: headerHeight),
              child: child,
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedSize(
                duration: duration,
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: AnimatedOpacity(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  opacity: isTable ? 1 : 0,
                  child: isTable
                      ? MediaLibraryTableHeader(style: style, width: width)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The drop cover dims the frame's mini player as well as this page.
  void _setDraggingFiles(bool value) {
    setState(() => _isDraggingFiles = value);
    _libraryShell?.setFileDropActive(this, value);
  }

  bool _openingSearch = false;

  Future<void> _openSearch() async {
    if (_openingSearch) return;
    _openingSearch = true;
    try {
      final request = await showHomeSearchPrompt(context);
      if (!mounted || request == null) return;
      await openHomeSearchResults(context, request);
    } finally {
      _openingSearch = false;
      if (mounted && _supportsDesktopManagementShortcuts) {
        _shortcutFocusNode.requestFocus();
      }
    }
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
          onPressed: _toggleSelectAllOnHome,
        ),
        const SizedBox(width: 2),
      ];
    }

    return [
      if (ExternalAiToolbarAction.isSupported)
        const ExternalAiToolbarAction(compact: true),
      // An active timer stays outside the trio so it cannot split them.
      _buildCompactSleepTimerButton(),
      // Search, library settings, and more stay on the bar at every compact
      // width. Settings used to live only inside「更多」; it is opened too
      // often to fold. The shared narrow slot keeps the cluster from
      // outweighing the page titles on the left.
      MediaLibraryCompactIconButton(
        icon: Icons.search_rounded,
        tooltip: _managementTooltip(
          '搜索媒体库',
          DesktopMediaManagementShortcutAction.openSearch,
        ),
        onPressed: _openSearch,
        width: mediaLibraryHomePinnedActionWidth,
        iconSize: mediaLibraryHomePinnedActionIconSize,
      ),
      MediaLibraryCompactIconButton(
        icon: Icons.settings_outlined,
        tooltip: _managementTooltip(
          '媒体库设置',
          DesktopMediaManagementShortcutAction.openLibrarySettings,
        ),
        onPressed: () => showMediaLibrarySettingsBottomSheet(context, settings),
        onLongPress: () => unawaited(toggleDebugDeveloperMode(context)),
        width: mediaLibraryHomePinnedActionWidth,
        iconSize: mediaLibraryHomePinnedActionIconSize,
      ),
      SizedBox(
        width: mediaLibraryHomePinnedActionWidth,
        height: 48,
        child: MediaLibraryCompactMoreButton(
          width: mediaLibraryHomePinnedActionWidth,
          iconSize: mediaLibraryHomePinnedActionIconSize,
          itemBuilder: (menuContext) => [
            mediaLibraryCompactMenuItem(
              icon: Icons.schedule_rounded,
              label: '定时关闭',
              onSelected: () => unawaited(showSleepTimerDialog(context)),
            ),
            mediaLibraryCompactMenuItem(
              icon: Icons.delete_outline,
              label: _managementTooltip(
                '回收站',
                DesktopMediaManagementShortcutAction.openRecycleBin,
              ),
              onLongPress: _toggleExportButtonVisibility,
              onSelected: () {
                pushAboveMediaLibrary(
                  context,
                  AppMaterialPageRoute(
                    builder: (_) => const RecycleBinScreen(),
                  ),
                );
              },
            ),
            if (KeyboardShortcutHints.of(menuContext))
              mediaLibraryCompactMenuItem(
                icon: Icons.keyboard_outlined,
                label: '快捷键 (F1)',
                onSelected: () => unawaited(showKeyboardShortcutHelp(context)),
              ),
            if (_showExportSettingsButton)
              mediaLibraryCompactMenuItem(
                icon: Icons.explore_outlined,
                label: '使用前设置',
                onSelected: _previewOnboarding,
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
              icon: Icons.checklist,
              label: _managementTooltip(
                '批量管理',
                DesktopMediaManagementShortcutAction.enterSelectionMode,
              ),
              onSelected: () {
                if (!mounted) return;
                _enterActiveSelection();
              },
            ),
          ],
        ),
      ),
      const SizedBox(width: 2),
    ];
  }

  Widget _buildCompactSleepTimerButton() {
    final timer = MediaPlaybackService().sleepTimer;
    return AnimatedBuilder(
      animation: timer,
      builder: (context, _) => !timer.isActive
          ? const SizedBox.shrink()
          : MediaLibraryCompactIconButton(
              icon: timer.isActive
                  ? Icons.alarm_on_rounded
                  : Icons.schedule_rounded,
              tooltip: _managementTooltip(
                timer.isActive ? timer.statusText : '定时关闭',
                DesktopMediaManagementShortcutAction.openSleepTimer,
              ),
              color: timer.isActive ? Colors.blueAccent : null,
              width: 40,
              iconSize: 20,
              onPressed: () => unawaited(showSleepTimerDialog(context)),
            ),
    );
  }

  // ... (existing code)

  final ScrollController _scrollController =
      PlaybackScrollController(); // Need scroll controller for calculation
  static const double _mediaCardCoverAspectRatio = 16 / 9;

  double _resolveCardTitleFontSize(double cardWidth, double settingValue) {
    return MediaLibraryLayoutDefaults.titleFontSize(cardWidth, settingValue);
  }

  double _resolveCardMetaFontSize(double titleFontSize) {
    return MediaLibraryLayoutDefaults.metaFontSize(titleFontSize);
  }

  void _openCardStyleSheet() {
    unawaited(
      MediaLibraryStyleSheet.show(
        context: context,
        scope: MediaLibraryCardStyleScope.home,
      ),
    );
  }

  MediaCardStyleSettings _homeCardStyle() {
    return Provider.of<SettingsService>(
      context,
      listen: false,
    ).homeCardStyleFor(MediaQuery.sizeOf(context));
  }

  MediaListStyleSettings _listStyle() {
    return Provider.of<SettingsService>(
      context,
      listen: false,
    ).listStyleFor(MediaQuery.sizeOf(context));
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

  MediaLibraryRootEntry _displayedRootEntry() {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    return _effectiveRootEntry(_rootNavigationPlan(library, settings));
  }

  bool get _podcastSelectionActive =>
      _displayedRootEntry() == MediaLibraryRootEntry.podcasts &&
      _podcastOverviewController.isSelecting;

  void _podcastSelectionChanged() {
    if (mounted) setState(() {});
  }

  void _createCollectionForActiveEntry() {
    if (_displayedRootEntry() == MediaLibraryRootEntry.podcasts) {
      unawaited(_podcastOverviewController.createCollection());
    } else {
      unawaited(VideoActionButtons.openCreateCollectionDialog(context, null));
    }
  }

  void _enterActiveSelection() {
    if (_displayedRootEntry() == MediaLibraryRootEntry.podcasts) {
      _podcastOverviewController.enterSelection();
    } else {
      setState(() => _isSelectionMode = true);
    }
  }

  void _exitActiveSelection() {
    if (_podcastSelectionActive) {
      _podcastOverviewController.exitSelection();
    } else {
      _exitSelectionMode();
    }
  }

  bool _isVirtualSelectionSurface([MediaLibraryRootEntry? entry]) {
    final displayed = entry ?? _displayedRootEntry();
    return displayed == MediaLibraryRootEntry.continueLearning ||
        displayed == MediaLibraryRootEntry.recent;
  }

  MediaLibraryVirtualSelectionHost? _virtualSelectionHost([
    MediaLibraryRootEntry? entry,
  ]) {
    switch (entry ?? _displayedRootEntry()) {
      case MediaLibraryRootEntry.continueLearning:
        return _continueSelectionHost;
      case MediaLibraryRootEntry.recent:
        return _recentSelectionHost;
      case MediaLibraryRootEntry.folders:
      case MediaLibraryRootEntry.bilibili:
      case MediaLibraryRootEntry.podcasts:
      case MediaLibraryRootEntry.cloudDrive:
        return null;
    }
  }

  ScrollController _activeSelectionScrollController() {
    return _scrollControllerFor(_displayedRootEntry());
  }

  MediaLibraryVirtualSelectionBinding _virtualSelectionBinding(
    MediaLibraryVirtualSelectionHost host,
  ) {
    return MediaLibraryVirtualSelectionBinding(
      isSelectionMode: _isSelectionMode,
      selectedIds: _selectedIds,
      host: host,
      onToggle: _toggleListSelection,
      onEnter: _enterSelectionFromDrag,
      onSecondaryTap: _handleCardSecondaryTap,
      onRangeStart: _startVirtualRangeSelection,
      onRangeUpdate: _updateDragSelection,
      onRangeEnd: _endListSelectionGesture,
    );
  }

  /// Helper: Get total item count safely
  int _getItemCount() {
    final host = _virtualSelectionHost();
    if (host != null) return host.itemCount;
    final library = Provider.of<LibraryService>(context, listen: false);
    return library.browseContents(null).length;
  }

  List<String> _queueSelectionInViewOrder(LibraryService library) {
    final host = _virtualSelectionHost();
    if (host != null) {
      return [
        for (var i = 0; i < host.itemCount; i++)
          if (_selectedIds.contains(host.idAt(i))) host.idAt(i)!,
      ];
    }
    return [
      for (final item in library.browseContents(null))
        if (_selectedIds.contains(item.id)) item.id as String,
    ];
  }

  List<String> _keyboardOrderedIds() {
    if (_displayedRootEntry() == MediaLibraryRootEntry.podcasts) {
      return _podcastOverviewController.visibleKeyboardIds;
    }
    final host = _virtualSelectionHost();
    if (host != null) return host.orderedIds;
    return [
      for (final item in context.read<LibraryService>().browseContents(null))
        (item as dynamic).id as String,
    ];
  }

  /// Helper: Get content ID at index
  String? _getItemId(int index) {
    final host = _virtualSelectionHost();
    if (host != null) return host.idAt(index);
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = library.browseContents(null);
    if (index < 0 || index >= contents.length) return null;
    return (contents[index] as dynamic).id;
  }

  /// Helper: Check if a point (relative to scrollable content) is inside an item
  /// Returns the index of the item, or null if in spacing/padding
  int? _getIndexAt(Offset contentOffset) {
    if (_isVirtualSelectionSurface()) return null;
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
    if (settings.mediaLibraryUsesRowPipeline) {
      final listStyle = settings.listStyleFor(mediaSize);
      final metrics = MediaListLayoutMetrics.forStyle(
        style: listStyle,
        screenShortestSide: mediaSize.shortestSide,
        availableWidth: viewportSize.width,
      );
      return MediaLibraryGridGeometry(
        crossAxisCount: listStyle.isTable ? 1 : listStyle.crossAxisCount,
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
      style: settings.homeCardStyleFor(mediaSize),
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
    final scrollController = _activeSelectionScrollController();
    if (!scrollController.hasClients) return null;
    final scrollContext = scrollController.position.context.notificationContext;
    final box = scrollContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final local = box.globalToLocal(_selectionHitGlobal(globalPos));
    return Offset(local.dx, local.dy + scrollController.offset);
  }

  Offset? _viewportLocalFromGlobal(Offset globalPos) {
    final scrollController = _activeSelectionScrollController();
    if (!scrollController.hasClients) return null;
    final scrollContext = scrollController.position.context.notificationContext;
    final box = scrollContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.globalToLocal(_selectionHitGlobal(globalPos));
  }

  ({double top, double bottom})? _selectionViewportGlobalY() {
    final scrollController = _activeSelectionScrollController();
    if (!scrollController.hasClients) return null;
    final scrollContext = scrollController.position.context.notificationContext;
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
    final settings = Provider.of<SettingsService>(context, listen: false);
    final host = _virtualSelectionHost();
    final int? currentIndex;
    final Set<String> newSelection;
    if (host != null) {
      currentIndex = host.indexForDragSelection(_selectionHitGlobal(globalPos));
      if (currentIndex == null) return;
      newSelection = host.mergeRange(
        snapshot: _dragSelectionSnapshot,
        startIndex: startIndex,
        currentIndex: currentIndex,
      );
    } else {
      final contentOffset = _contentOffsetFromGlobal(globalPos);
      if (contentOffset == null) return;
      final count = _getItemCount();
      currentIndex = _getMediaGridGeometry(
        settings,
      ).indexForDragSelection(contentOffset, count);
      if (currentIndex == null) return;
      newSelection = MediaLibraryRangeSelection.mergeSnapshotWithIndexRange(
        snapshot: _dragSelectionSnapshot,
        startIndex: startIndex,
        currentIndex: currentIndex,
        itemCount: count,
        idAt: _getItemId,
      );
    }

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
    final controller = _activeSelectionScrollController();
    if (_selectionAutoScroller != null &&
        !identical(_selectionAutoScroller!.scrollController, controller)) {
      _selectionAutoScroller!.dispose();
      _selectionAutoScroller = null;
    }
    return _selectionAutoScroller ??= MediaLibrarySelectionAutoScroller(
      scrollController: controller,
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

  void _startVirtualRangeSelection(String id, Offset globalPosition) {
    final host = _virtualSelectionHost();
    final index = host?.indexOf(id);
    if (index == null) {
      _enterSelectionFromDrag(id);
      return;
    }
    _startListSelectionGesture(index, id, globalPosition);
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

  /// Box select and pinch stay off while the online page is shown, so they
  /// never compete with its text field and lists.
  _MouseOrPinchScaleRecognizer _createScaleRecognizer() {
    return _MouseOrPinchScaleRecognizer(
      isSuspended: () =>
          (_displayedRootEntry() == MediaLibraryRootEntry.bilibili ||
          (_displayedRootEntry() == MediaLibraryRootEntry.podcasts ||
              _displayedRootEntry() == MediaLibraryRootEntry.cloudDrive)),
    );
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
    // The online page has no library items to box-select.
    if ((_displayedRootEntry() == MediaLibraryRootEntry.bilibili ||
        (_displayedRootEntry() == MediaLibraryRootEntry.podcasts ||
            _displayedRootEntry() == MediaLibraryRootEntry.cloudDrive))) {
      return false;
    }
    final host = _virtualSelectionHost();
    if (host != null) {
      if (host.hitsCard(globalPos)) return false;
      final local = _viewportLocalFromGlobal(globalPos);
      if (local == null) return false;
      _isBoxSelecting = true;
      _boxStartContentPos = local;
      _lastDragSelectionGlobalPos = globalPos;
      _capturedIds.clear();
      _dragSelectionSnapshot = _isSelectionMode
          ? Set<String>.from(_selectedIds)
          : <String>{};
      _applyMouseBoxSelectionAt(globalPos);
      _syncSelectionAutoScroll(globalPos);
      return true;
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

  Set<String> _idsInMouseBox(Offset globalPos) {
    final host = _virtualSelectionHost();
    if (host != null) {
      final startLocal = _boxStartContentPos;
      final currentLocal = _viewportLocalFromGlobal(globalPos);
      if (startLocal == null || currentLocal == null) {
        return const <String>{};
      }
      final scrollController = _activeSelectionScrollController();
      final scrollContext =
          scrollController.position.context.notificationContext;
      final box = scrollContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return const <String>{};
      final globalRect = Rect.fromPoints(
        box.localToGlobal(startLocal),
        box.localToGlobal(currentLocal),
      );
      return host.idsOverlapping(globalRect);
    }
    final currentContent = _contentOffsetFromGlobal(globalPos);
    if (currentContent == null || _boxStartContentPos == null) {
      return const <String>{};
    }
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
    return currentInBox;
  }

  void _applyMouseBoxSelectionAt(Offset globalPos) {
    if (!_isBoxSelecting || _boxStartContentPos == null) return;
    _lastDragSelectionGlobalPos = globalPos;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final host = _virtualSelectionHost();
    final Offset boxStart;
    final Offset boxCurrent;
    if (host != null) {
      final currentLocal = _viewportLocalFromGlobal(globalPos);
      if (currentLocal == null) return;
      boxStart = _boxStartContentPos!;
      boxCurrent = currentLocal;
    } else {
      final currentContent = _contentOffsetFromGlobal(globalPos);
      if (currentContent == null) return;
      final scroll = _activeSelectionScrollController().hasClients
          ? _activeSelectionScrollController().offset
          : 0.0;
      boxStart = _boxStartContentPos! - Offset(0, scroll);
      boxCurrent = currentContent - Offset(0, scroll);
    }
    final currentInBox = _idsInMouseBox(globalPos);

    setState(() {
      _boxStartPos = boxStart;
      _boxCurrentPos = boxCurrent;
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
      final newSelected = _idsInMouseBox(_lastDragSelectionGlobalPos!);
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
    setState(() {
      _isBoxSelecting = false;
      _boxStartPos = null;
      _boxCurrentPos = null;
      _boxStartContentPos = null;
      _capturedIds.clear();
    });
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
    // Keep next/previous inside the item's original folder, not the current view.
    Provider.of<PlaylistManager>(
      context,
      listen: false,
    ).prepareLibraryPlayback(item);
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

  /// 检查是否有待恢复的播放状态（用于首次启动时预留空间）
  Future<void> _checkPendingPlaybackState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString('playback_state_snapshot');
      if (jsonString != null && jsonString.isNotEmpty) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final currentItemId = json['currentItemId'] as String?;
        _hasPendingPlaybackState = currentItemId != null;
      }
    } catch (e) {
      debugPrint('检查播放状态失败: $e');
    }
  }

  Future<void> _loadExportButtonPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('show_export_settings_button') ?? false;
    if (mounted) {
      setState(() {
        _showExportSettingsButton = value;
      });
    } else {
      _showExportSettingsButton = value;
    }
  }

  /// Hidden entry: long-press the recycle-bin icon on the media-library app bar.
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

  void _openPortableTransfer() {
    unawaited(PortableTransferNavigation.open(context));
  }

  Future<void> _exportSettingsSnapshot() => exportAppSettings(context);

  void _previewOnboarding() {
    unawaited(
      OnboardingFlow.open(
        context,
        context.read<SettingsService>(),
        preview: true,
      ),
    );
  }

  Future<void> _runStartupIntroduction() async {
    // This runs after startup has initialized settings and the library. Keep
    // permission/login/clipboard dialogs out of the first-use walkthrough.
    try {
      final offer = await OnboardingStore.shouldShow();
      if (!mounted) return;
      final library = context.read<LibraryService>();
      if (offer &&
          library.storageVideos.isEmpty &&
          library.storageCollections.isEmpty) {
        if (mediaLibraryRouteIsCurrent(context) == false) {
          await ClipboardDetectionScope.maybeOf(context)?.completeStartup();
          return;
        }
        await OnboardingFlow.open(context, context.read<SettingsService>());
      }
      if (offer) await OnboardingStore.markHandled();
    } catch (error) {
      debugPrint('新手引导启动失败: $error');
    }
    if (!mounted) return;
    // Finish first-use setup before presenting the one-time system prompt.
    // Keep clipboard prompts behind it so dialogs cannot overlap.
    await _requestNotificationPermission();
    if (!mounted) return;
    await ClipboardDetectionScope.maybeOf(context)?.completeStartup();
  }

  @override
  void initState() {
    super.initState();
    _rootEntryOverride.addListener(_publishExternalAiWorkspace);
    _rootSwipeSettled.addListener(_publishExternalAiWorkspace);
    _podcastOverviewController.addListener(_podcastSelectionChanged);
    ExperimentalLayout.instance.addListener(_layoutChanged);
    unawaited(ExperimentalLayout.instance.initialize());
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);
    HardwareKeyboard.instance.addHandler(_handleGlobalHardwareKeyEvent);
    MediaLibraryRecentIntent.pendingBatchId.addListener(
      _onRecentBatchViewRequested,
    );
    _revealHighlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
      reverseDuration: const Duration(milliseconds: 560),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_supportsDesktopManagementShortcuts && mounted) {
        _shortcutFocusNode.requestFocus();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadExportButtonPreference();
      if (!widget.returnToSearchResults) {
        // 使用非阻塞方式调用,避免卡住UI
        unawaited(_runStartupIntroduction());
        _checkPendingPlaybackState();
      }
    });

    // 监听播放服务状态，当播放状态恢复完成后清除待恢复标志
    if (!widget.returnToSearchResults) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        _listenedPlaybackService = playbackService;
        playbackService.addListener(_onPlaybackServiceChanged);
      });
    }
  }

  void _layoutChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ExternalAiWorkspaceContext.instance.clear(this);
    _rootEntryOverride.removeListener(_publishExternalAiWorkspace);
    _rootSwipeSettled.removeListener(_publishExternalAiWorkspace);
    _podcastOverviewController.removeListener(_podcastSelectionChanged);
    _podcastOverviewController.dispose();
    ExperimentalLayout.instance.removeListener(_layoutChanged);
    _playbackInsets.dispose();
    _libraryShell?.setFileDropActive(this, false);
    _listenedPlaybackService?.removeListener(_onPlaybackServiceChanged);
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    HardwareKeyboard.instance.removeHandler(_handleGlobalHardwareKeyEvent);
    _revealHighlightTimer?.cancel();
    _revealHighlightController.dispose();
    _shortcutFocusNode.dispose();
    _recentScrollController.dispose();
    _continueScrollController.dispose();
    _bilibiliScrollController.dispose();
    _podcastsScrollController.dispose();
    _rootEntryOverride.dispose();
    _rootSwipeHighlight.dispose();
    _rootSwipeSettled.dispose();
    _rootEntryOrder.dispose();
    MediaLibraryRecentIntent.pendingBatchId.removeListener(
      _onRecentBatchViewRequested,
    );
    _reorderDrag.end();
    _selectionAutoScroller?.dispose();
    super.dispose();
  }

  bool get _supportsDesktopManagementShortcuts {
    return supportsNativeHardwareKeyboardShortcuts;
  }

  bool get _isDesktopPlatform {
    return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  }

  bool _isTextInputFocused() => isEditableTextFocused();

  bool _handleGlobalHardwareKeyEvent(KeyEvent event) {
    // Focus already consumes the event when it owns the node; this catches
    // desktop keys after a click stole focus without going through Focus.
    if (_shortcutFocusNode.hasFocus) return false;
    return _handleShortcutKeyEvent(event) != KeyEventResult.ignored;
  }

  void _handleAndroidHardwareKeyEvent(AndroidHardwareKeyMessage message) {
    _handleShortcutKeyEvent(
      message.toKeyEvent(),
      fromAndroidNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
      shiftPressedOverride: message.isShiftPressed,
    );
  }

  String _managementTooltip(
    String label,
    DesktopMediaManagementShortcutAction action,
  ) {
    final platform = currentNativeTargetPlatform;
    if (platform == null ||
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

  MediaLibraryNavigationPlan _rootNavigationPlan(
    LibraryService library,
    SettingsService settings,
  ) {
    return MediaLibraryNavigation.plan(
      libraryInitialized: library.isInitialized,
      hasExistingLibraryContent: library.hasExistingLibraryContent,
      storedEntry: settings.mediaLibraryRootEntry,
      userChosen: settings.mediaLibraryRootEntryUserChosen,
      lastFolderId: settings.mediaLibraryLastFolderId,
      restoreLastPage: settings.mediaLibraryRestoreLastPage,
      startupEntry: settings.mediaLibraryStartupEntry,
      availableEntries: _mountedRootEntries,
      revealItemId: widget.revealItemId,
      returnToSearchResults: widget.returnToSearchResults,
      isActiveFolder: (id) {
        final collection = library.getCollection(id);
        return collection != null && !collection.isRecycled;
      },
      parentIdOf: (id) => library.getCollection(id)?.parentId,
    );
  }

  void _persistScrollForEntry(
    MediaLibraryRootEntry displayed,
    SettingsService settings, {
    double? capturedOffset,
  }) {
    final library = Provider.of<LibraryService>(context, listen: false);
    final visibleIds = library
        .getContents(null)
        .map((item) => (item as dynamic).id as String)
        .toSet();
    final previous = Map<MediaLibraryRootEntry, MediaLibraryScrollAnchor>.from(
      MediaLibraryNavigation.decodeAnchors(settings.mediaLibraryEntryAnchors),
    );
    final previousAnchor =
        previous[displayed] ?? const MediaLibraryScrollAnchor();
    final sanitized = MediaLibraryNavigation.sanitizeAnchor(
      anchor: previousAnchor,
      visibleItemIds: visibleIds,
    );
    final controller = _scrollControllerFor(displayed);
    final offset =
        capturedOffset ??
        (controller.hasClients ? controller.offset : sanitized.offset);
    previous[displayed] = MediaLibraryScrollAnchor(
      itemId:
          sanitized.itemId ?? (visibleIds.isEmpty ? null : visibleIds.first),
      offset: offset,
    );
    unawaited(
      settings.saveMediaLibraryEntryAnchors(
        MediaLibraryNavigation.encodeAnchors(previous),
      ),
    );
  }

  ScrollController _scrollControllerFor(MediaLibraryRootEntry entry) {
    switch (entry) {
      case MediaLibraryRootEntry.continueLearning:
        return _continueScrollController;
      case MediaLibraryRootEntry.recent:
        return _recentScrollController;
      case MediaLibraryRootEntry.folders:
        return _scrollController;
      case MediaLibraryRootEntry.bilibili:
        return _bilibiliScrollController;
      case MediaLibraryRootEntry.podcasts:
      case MediaLibraryRootEntry.cloudDrive:
        return _podcastsScrollController;
    }
  }

  MediaLibraryRootEntry _effectiveRootEntry(MediaLibraryNavigationPlan plan) {
    if (plan.forceFoldersForLocate) return MediaLibraryRootEntry.folders;
    final entry = _rootEntryOverride.value ?? plan.displayedEntry;
    return entry.isAvailable ? entry : MediaLibraryRootEntry.folders;
  }

  void _syncRootEntryOrder(SettingsService settings) {
    final parsed = MediaLibraryRootEntryOrder.parse(
      settings.mediaLibraryRootEntryOrder,
    );
    if (listEquals(_rootEntryOrder.value, parsed)) return;
    _rootEntryOrder.value = parsed;
  }

  void _onRootEntryReorder(
    int oldIndex,
    int newIndex,
    SettingsService settings,
    MediaLibraryNavigationPlan plan,
  ) {
    if (!_rootSwipeSettled.value || plan.forceFoldersForLocate) return;
    final next = MediaLibraryRootEntryOrder.moved(
      _rootEntryOrder.value,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    if (listEquals(next, _rootEntryOrder.value)) return;
    _rootEntryOrder.value = next;
    final selected = _effectiveRootEntry(plan);
    final index = next.indexOf(selected);
    if (index >= 0) {
      _rootSwipeHighlight.value = index.toDouble();
    }
    unawaited(
      settings.saveMediaLibraryRootEntryOrder(
        MediaLibraryRootEntryOrder.encode(next),
      ),
    );
  }

  void _selectRootEntry(MediaLibraryRootEntry entry, SettingsService settings) {
    if (!_mountedRootEntries.contains(entry)) return;
    final library = Provider.of<LibraryService>(context, listen: false);
    final plan = _rootNavigationPlan(library, settings);
    if (plan.forceFoldersForLocate) return;
    final leaving = _effectiveRootEntry(plan);
    if (leaving == entry) return;
    if (_isSelectionMode) {
      _exitSelectionMode();
    }
    final leavingController = _scrollControllerFor(leaving);
    final capturedOffset = leavingController.hasClients
        ? leavingController.offset
        : null;
    final index = _rootEntryOrder.value.indexOf(entry);
    if (index >= 0) _rootSwipeHighlight.value = index.toDouble();
    _rootEntryOverride.value = entry;
    // Prefs IO shares the UI isolate. Doing it on the tap frame lands in
    // the middle of the fade.
    unawaited(
      Future<void>.delayed(kMediaLibraryRootFadeDuration, () {
        settings.saveMediaLibraryRootChoice(entry.storageValue, notify: false);
        if (!mounted) return;
        _persistScrollForEntry(
          leaving,
          settings,
          capturedOffset: capturedOffset,
        );
      }),
    );
  }

  void _onRecentBatchViewRequested() {
    final batchId = MediaLibraryRecentIntent.pendingBatchId.value;
    if (batchId == null || !mounted) return;
    MediaLibraryRecentIntent.pendingBatchId.value = null;
    final settings = Provider.of<SettingsService>(context, listen: false);
    setState(() => _pendingRecentBatchId = batchId);
    _selectRootEntry(MediaLibraryRootEntry.recent, settings);
  }

  void _locateLibraryItem(VideoItem item) {
    _locateLibraryEntry(id: item.id, parentId: item.parentId);
  }

  void _locateLibraryEntry({required String id, required String? parentId}) {
    final Widget page = parentId == null
        ? HomeScreen(revealItemId: id, returnToSearchResults: true)
        : CollectionScreen(
            collectionId: parentId,
            revealItemId: id,
            returnToSearchResults: true,
          );
    final Route<void> route = parentId == null
        ? AppMaterialPageRoute<void>(builder: (_) => page)
        : buildMediaLibraryFolderRoute<void>(
            folderId: parentId,
            builder: (_) => page,
          );
    Navigator.of(context).push(route);
  }

  void _applyLibraryNavigationAfterInit(
    LibraryService library,
    SettingsService settings,
  ) {
    final plan = _rootNavigationPlan(library, settings);
    if (plan.persistPreferred && !_didPersistRootEntryDefault) {
      _didPersistRootEntryDefault = true;
      unawaited(
        settings.updateSetting(
          'mediaLibraryRootEntry',
          plan.preferredEntry.storageValue,
        ),
      );
    }
    if (_didRestoreLastFolderRoute) return;
    _didRestoreLastFolderRoute = true;
    final folderId = plan.folderToOpen;
    if (folderId == null ||
        widget.revealItemId != null ||
        widget.returnToSearchResults) {
      return;
    }
    unawaited(
      Navigator.of(context)
          .push(
            buildMediaLibraryFolderRoute<void>(
              folderId: folderId,
              restored: true,
              builder: (context) => CollectionScreen(collectionId: folderId),
            ),
          )
          .then((_) {
            if (!mounted) return;
            unawaited(settings.saveMediaLibraryLastFolder(''));
          }),
    );
  }

  /// Root library has no parent folder, so drop-target payload is recycle-only.
  List<String> _idsForSelectionDrop({int? draggedIndex}) {
    final library = Provider.of<LibraryService>(context, listen: false);
    return resolveMediaLibrarySelectionDropIds(
      contents: library.browseContents(null),
      selectedIds: _selectedIds,
      draggedIndex: draggedIndex,
    );
  }

  Future<void> _moveItemsToRecycleBin({int? draggedIndex}) async {
    final itemsToMove = _idsForSelectionDrop(draggedIndex: draggedIndex);
    if (itemsToMove.isEmpty) return;

    final library = Provider.of<LibraryService>(context, listen: false);
    final saving = library.moveToRecycleBin(itemsToMove);
    setState(() {
      _selectedIds.removeAll(itemsToMove);
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
    await saving;
    if (!mounted) return;
    AppToast.show("已移入回收站", type: AppToastType.success);
  }

  void _toggleSelectAllOnHome() {
    final host = _virtualSelectionHost();
    if (host != null) {
      setState(() {
        if (_selectedIds.length == host.itemCount &&
            host.orderedIds.every(_selectedIds.contains)) {
          _selectedIds.clear();
        } else {
          _selectedIds
            ..clear()
            ..addAll(host.orderedIds);
          _isSelectionMode = true;
        }
      });
      return;
    }
    final library = Provider.of<LibraryService>(context, listen: false);
    final contents = library.browseContents(null);
    setState(() {
      if (_selectedIds.length == contents.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.addAll(contents.map((e) => (e as dynamic).id as String));
      }
    });
  }

  void _pruneVirtualSelectionToVisible() {
    if (!_isSelectionMode) return;
    final host = _virtualSelectionHost();
    if (host == null) return;
    final visible = host.orderedIds.toSet();
    final stale = _selectedIds.where((id) => !visible.contains(id)).toList();
    if (stale.isEmpty) return;
    setState(() {
      _selectedIds.removeAll(stale);
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
  }

  List<MediaLibraryVirtualSelectionAction> _selectionBottomActions(
    LibraryService library,
  ) {
    final pinned = library.pinnedItemIds.toSet();
    switch (_displayedRootEntry()) {
      case MediaLibraryRootEntry.continueLearning:
        return MediaLibraryVirtualSelectionActions.forContinueLearning(
          selectedIds: _selectedIds,
          pinnedIds: pinned,
        );
      case MediaLibraryRootEntry.recent:
        return MediaLibraryVirtualSelectionActions.forRecentAdded(
          selectedIds: _selectedIds,
          pinnedIds: pinned,
        );
      case MediaLibraryRootEntry.folders:
        return MediaLibraryVirtualSelectionActions.forFolders(
          selectedIds: _selectedIds,
        );
      case MediaLibraryRootEntry.bilibili:
      case MediaLibraryRootEntry.podcasts:
      case MediaLibraryRootEntry.cloudDrive:
        return const <MediaLibraryVirtualSelectionAction>[];
    }
  }

  Future<void> _onVirtualSelectionAction(
    MediaLibraryVirtualSelectionActionKind kind,
  ) async {
    final library = Provider.of<LibraryService>(context, listen: false);
    final ids = _selectedIds.toList(growable: false);
    if (ids.isEmpty) return;
    switch (kind) {
      case MediaLibraryVirtualSelectionActionKind.recycle:
        await _moveItemsToRecycleBin();
        return;
      case MediaLibraryVirtualSelectionActionKind.export:
        setState(() {
          _selectedIds.clear();
          _isSelectionMode = false;
        });
        await PortableTransferNavigation.openExportSettings(context, ids);
        return;
      case MediaLibraryVirtualSelectionActionKind.rename:
        if (ids.length != 1) return;
        final id = ids.first;
        final col = library.getCollection(id);
        final vid = library.getVideo(id);
        final name = col?.name ?? vid?.title ?? '';
        _showRenameDialog(context, id, name);
        return;
      case MediaLibraryVirtualSelectionActionKind.pin:
        for (final id in ids) {
          await library.pinLibraryItem(id);
        }
        if (!mounted) return;
        AppToast.show('已置顶', type: AppToastType.success);
        return;
      case MediaLibraryVirtualSelectionActionKind.unpin:
        for (final id in ids) {
          await library.unpinLibraryItem(id);
        }
        if (!mounted) return;
        AppToast.show('已取消置顶', type: AppToastType.success);
        return;
      case MediaLibraryVirtualSelectionActionKind.hideContinue:
        for (final id in ids) {
          if (library.getVideo(id) == null) continue;
          MediaPlaybackService().noteLibraryMediaHidden(id);
          await library.hideLibraryMedia(id);
        }
        if (!mounted) return;
        setState(() {
          _selectedIds.removeAll(ids);
          if (_selectedIds.isEmpty) _isSelectionMode = false;
        });
        AppToast.show('已从本页移除', type: AppToastType.success);
        return;
      case MediaLibraryVirtualSelectionActionKind.dismissRecent:
        final removed = <String>[];
        for (final id in ids) {
          if (await library.dismissFromRecentAdded(id)) {
            removed.add(id);
          }
        }
        if (!mounted) return;
        setState(() {
          _selectedIds.removeAll(removed);
          if (_selectedIds.isEmpty) _isSelectionMode = false;
        });
        if (removed.isEmpty) return;
        AppToast.show(
          removed.length == 1 ? '已从本页移除' : '已从本页移除 ${removed.length} 项',
          type: AppToastType.success,
          duration: const Duration(seconds: 4),
          action: AppToastAction(
            label: '撤销',
            onPressed: () {
              unawaited(() async {
                for (final id in removed) {
                  await library.restoreRecentAdded(id);
                }
              }());
            },
          ),
        );
        return;
    }
  }

  KeyEventResult _handleManagementShortcut(
    DesktopMediaManagementShortcutAction action,
  ) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    switch (action) {
      case DesktopMediaManagementShortcutAction.backOrExitSelection:
        if (_isSelectionMode) {
          _exitSelectionMode();
          return KeyEventResult.handled;
        }
        if (widget.returnToSearchResults) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case DesktopMediaManagementShortcutAction.toggleViewMode:
        unawaited(settings.cycleMediaLibraryViewStyle());
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
        _enterActiveSelection();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.toggleSelectAll:
        if (!_isSelectionMode) return KeyEventResult.handled;
        _toggleSelectAllOnHome();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openSearch:
        if (_isSelectionMode) return KeyEventResult.handled;
        unawaited(_openSearch());
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openLibrarySettings:
        if (_isSelectionMode) return KeyEventResult.handled;
        showMediaLibrarySettingsBottomSheet(context, settings);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openExternalAi:
        if (_isSelectionMode || _podcastSelectionActive) {
          return KeyEventResult.handled;
        }
        ExternalAiToolbarAction.open(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openSleepTimer:
        unawaited(showSleepTimerDialog(context));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.createCollection:
        if (_isSelectionMode) {
          if (_selectedIds.length == 1) {
            final library = Provider.of<LibraryService>(context, listen: false);
            final id = _selectedIds.first;
            final name =
                library.getCollection(id)?.name ??
                library.getVideo(id)?.title ??
                '';
            _showRenameDialog(context, id, name);
          }
          return KeyEventResult.handled;
        }
        _createCollectionForActiveEntry();
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.importMedia:
        if (_isSelectionMode) return KeyEventResult.handled;
        unawaited(VideoActionButtons.showImportMenu(context, null));
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBilibiliDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openBilibiliDownloadPage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openYtDlpDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openYtDlpDownloadPage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openDouyinDownload:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openDouyinDownloadPage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openWebMedia:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openWebMediaPage(context);
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
        VideoActionButtons.openBatchSubtitlePage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.openBatchImport:
        if (_isSelectionMode) return KeyEventResult.handled;
        VideoActionButtons.openCacheManagementPage(context);
        return KeyEventResult.handled;
      case DesktopMediaManagementShortcutAction.moveToParent:
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

  KeyEventResult _handleShortcutKeyEvent(
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
    bool? shiftPressedOverride,
  }) {
    if (!_supportsDesktopManagementShortcuts) return KeyEventResult.ignored;
    // 当视频播放页或其他子页面活跃时，不处理键盘事件，避免与播放器快捷键冲突
    if (!isMediaLibraryRouteCurrent(context)) return KeyEventResult.ignored;
    if (!_isTextInputFocused()) {
      final keyboardForCards = HardwareKeyboard.instance;
      final keyForCards = event.logicalKey;
      final isArrow =
          keyForCards == LogicalKeyboardKey.arrowLeft ||
          keyForCards == LogicalKeyboardKey.arrowRight ||
          keyForCards == LogicalKeyboardKey.arrowUp ||
          keyForCards == LogicalKeyboardKey.arrowDown;
      final shiftForCards =
          shiftPressedOverride ?? keyboardForCards.isShiftPressed;
      final blockingForCards =
          hasBlockingModifierOverride ??
          (keyboardForCards.isControlPressed ||
              keyboardForCards.isAltPressed ||
              keyboardForCards.isMetaPressed);
      if (event is KeyDownEvent &&
          _shortcutFocusNode.hasPrimaryFocus &&
          isArrow &&
          !blockingForCards &&
          !shiftForCards &&
          (_keyboardRegionKey.currentState?.focusInitial(
                event: event,
                fromNativeBridge: fromAndroidNativeBridge,
              ) ??
              false)) {
        return KeyEventResult.handled;
      }
      if (fromAndroidNativeBridge &&
          MediaLibraryKeyboardItem.handlesNativeKey(
            keyForCards,
            shift: shiftForCards,
          )) {
        return KeyEventResult.ignored;
      }
      if (!fromAndroidNativeBridge &&
          _isSelectionMode &&
          event is KeyDownEvent &&
          keyForCards == LogicalKeyboardKey.keyA &&
          (keyboardForCards.isControlPressed ||
              keyboardForCards.isMetaPressed) &&
          !keyboardForCards.isAltPressed &&
          !keyboardForCards.isShiftPressed) {
        setState(() {
          _selectedIds.addAll(_keyboardOrderedIds());
        });
        return KeyEventResult.handled;
      }
      if ((keyForCards == LogicalKeyboardKey.space ||
              keyForCards == LogicalKeyboardKey.arrowLeft ||
              keyForCards == LogicalKeyboardKey.arrowRight) &&
          MediaLibraryKeyboardItem.interactiveControlHasFocus) {
        return KeyEventResult.ignored;
      }
    }
    if (!_isTextInputFocused() &&
        !_isSelectionMode &&
        !_podcastSelectionActive &&
        !false) {
      final settings = context.read<SettingsService>();
      final plan = _rootNavigationPlan(
        context.read<LibraryService>(),
        settings,
      );
      final keyboard = HardwareKeyboard.instance;
      final order = _rootEntryOrder.value;
      final index = mediaLibraryEntryShortcutIndex(
        event.logicalKey,
        currentIndex: order.indexOf(_effectiveRootEntry(plan)),
        count: order.length,
        control: !fromAndroidNativeBridge && keyboard.isControlPressed,
        shift: shiftPressedOverride ?? keyboard.isShiftPressed,
        alt: fromAndroidNativeBridge
            ? (hasBlockingModifierOverride ?? false)
            : keyboard.isAltPressed,
        meta: !fromAndroidNativeBridge && keyboard.isMetaPressed,
      );
      if (!plan.hideSwitcher && index != null) {
        if (Platform.isAndroid &&
            !_androidKeyDeduplicator.shouldDispatch(
              event,
              fromNativeBridge: fromAndroidNativeBridge,
            )) {
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent) {
          _selectRootEntry(order[index], settings);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && isMediaLibraryRouteCurrent(context)) {
              MediaLibrarySpatialNavigation.focusInitial(context);
            }
          });
        }
        return KeyEventResult.handled;
      }
    }
    final isExternalAiShortcut =
        DesktopMediaManagementShortcuts.matchAction(event.logicalKey) ==
        DesktopMediaManagementShortcutAction.openExternalAi;
    if (!isExternalAiShortcut &&
        (_displayedRootEntry() == MediaLibraryRootEntry.podcasts ||
            _displayedRootEntry() == MediaLibraryRootEntry.cloudDrive)) {
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
        hasBlockingModifierOverride ?? hasBlockingKeyboardModifier();
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
    // Library management keys have nothing to act on in the online page.
    if (managementAction != null &&
        managementAction !=
            DesktopMediaManagementShortcutAction.openExternalAi &&
        (_displayedRootEntry() == MediaLibraryRootEntry.bilibili ||
            (_displayedRootEntry() == MediaLibraryRootEntry.podcasts ||
                _displayedRootEntry() == MediaLibraryRootEntry.cloudDrive))) {
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

  /// 播放服务状态变化监听器
  void _onPlaybackServiceChanged() {
    if (_hasPendingPlaybackState) {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      // 当播放状态恢复完成（currentItem 被设置）后，清除待恢复标志
      if (playbackService.currentItem != null) {
        setState(() {
          _hasPendingPlaybackState = false;
        });
      }
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (!mounted ||
        OnboardingFlow.isShowing ||
        mediaLibraryRouteIsCurrent(context) == false ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
      return;
    }
    await StartupNotificationPermission.instance.requestOnce();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsService>(context);
    final library = context.read<LibraryService>();
    context.select<LibraryService, int>((service) => service.browseRevision);
    _syncRootEntryOrder(settings);
    final experimental = ExperimentalLayout.instance.value;
    final useCompactTopBar =
        experimental || useCompactMediaLibraryTopBar(context);
    final rootNavPlan = _rootNavigationPlan(library, settings);
    _publishExternalAiWorkspace();
    final podcastSelecting = _podcastSelectionActive;
    final homeSelecting = _isSelectionMode || podcastSelecting;
    // The root tabs share the cards' left edge, including user spacing and
    // grid/list settings. Navigation/selection titles still sit after leading.
    final cardInset = MediaLibraryScrollViewport.cardEdgeFor(
      MediaQuery.sizeOf(context).width -
          MediaQuery.paddingOf(context).horizontal,
      MediaLibraryScrollViewport.libraryInsetFraction(
        settings,
        MediaQuery.sizeOf(context),
      ),
    );
    final titleInset = !homeSelecting && !rootNavPlan.hideSwitcher
        ? cardInset
        : useCompactTopBar
        ? 3.0
        : 8.0;
    // Align the visible icon, preserving the larger touch target around it.
    // Both action layouts already include a trailing 2px spacer.
    // The compact home's last control is the pinned "more" button, which is
    // narrower than the selection-mode slot.
    final actionSize = (MediaQuery.sizeOf(context).width * .032).clamp(
      32.0,
      40.0,
    );
    final actionIconSize = (actionSize * .58).clamp(20.0, 24.0);
    final actionInnerInset = useCompactTopBar
        ? (homeSelecting
              ? (40 - 21) / 2
              : (mediaLibraryHomePinnedActionWidth -
                        mediaLibraryHomePinnedActionIconSize) /
                    2)
        : (actionSize - actionIconSize) / 2;
    if (library.isInitialized && !_libraryNavigationScheduled) {
      _libraryNavigationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyLibraryNavigationAfterInit(library, settings);
      });
    }
    // The mini player lives in the library frame; line up with its inset.
    _stablePlaybackBottomInset =
        MediaLibraryShell.stableBottomInsetOf(context) ??
        _playbackInsets
            .observe(
              MediaQueryData.fromView(View.of(context)),
              active: mediaLibraryRouteIsCurrent(context) ?? true,
            )
            .bottom;
    final selectionBarObstruction = MediaLibraryShell.selectionBarObstructionOf(
      context,
    );
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      if (_lastIsFullScreen != settings.isFullScreen) {
        _lastIsFullScreen = settings.isFullScreen;
        if (_lastIsFullScreen == true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_shortcutFocusNode.hasFocus) {
              _shortcutFocusNode.requestFocus();
            }
          });
        }
      }
    }

    return PopScope(
      canPop: !homeSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (podcastSelecting) {
          _podcastOverviewController.exitSelection();
          return;
        }
        setState(() {
          _isSelectionMode = false;
          _selectedIds.clear();
          _isBoxSelecting = false;
          _boxStartPos = null;
          _boxCurrentPos = null;
          _capturedIds.clear();
        });
      },
      child: Scaffold(
        backgroundColor: AppTokens.bgBase,
        // Search owns its keyboard avoidance inside the dialog route. Keeping
        // the library viewport fixed prevents Android IME animation from
        // relaying out every visible media card behind that dialog.
        resizeToAvoidBottomInset: false,
        // 关键：设置 extendBody 为 true，让 body 延伸到底部导航栏后面
        // 避免 MiniPlaybackCard 位置偏下
        extendBody: true,
        appBar: AppBar(
          backgroundColor: AppTokens.bgBase,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          iconTheme: const IconThemeData(color: AppTokens.text2),
          actionsIconTheme: const IconThemeData(color: AppTokens.text2),
          shape: const Border(bottom: BorderSide(color: AppTokens.lineSubtle)),
          toolbarHeight: useCompactTopBar ? 44 : 48,
          automaticallyImplyLeading: false,
          leadingWidth: useCompactTopBar ? 40 : 44,
          titleSpacing: useCompactTopBar ? 2 : titleInset,
          title: experimental && !homeSelecting
              ? const Text(
                  kAppDisplayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                )
              : homeSelecting
              ? podcastSelecting
                    ? _podcastOverviewController.buildSelectionDropTargets()
                    : MediaLibrarySelectionDropTargets(
                        hasSelectedItems: _selectedIds.isNotEmpty,
                        onMoveToRecycleBin: (draggedIndex) {
                          unawaited(
                            _moveItemsToRecycleBin(draggedIndex: draggedIndex),
                          );
                        },
                      )
              : rootNavPlan.hideSwitcher
              ? const MediaLibraryCompactTitle(text: '我的媒体库')
              : ValueListenableBuilder<MediaLibraryRootEntry?>(
                  valueListenable: _rootEntryOverride,
                  builder: (context, selectedOverride, child) {
                    return ValueListenableBuilder<List<MediaLibraryRootEntry>>(
                      valueListenable: _rootEntryOrder,
                      builder: (context, order, child) {
                        return ValueListenableBuilder<bool>(
                          valueListenable: _rootSwipeSettled,
                          builder: (context, settled, child) {
                            return ValueListenableBuilder<double>(
                              valueListenable: _rootSwipeHighlight,
                              builder: (context, highlight, child) {
                                return Padding(
                                  padding: EdgeInsets.only(
                                    left: useCompactTopBar
                                        ? (titleInset - 2).clamp(
                                            0.0,
                                            double.infinity,
                                          )
                                        : 0,
                                  ),
                                  child: MediaLibraryEntrySwitcher(
                                    selected: _effectiveRootEntry(rootNavPlan),
                                    highlightIndex: highlight,
                                    entries: order,
                                    availableEntries: _mountedRootEntries,
                                    compact: useCompactTopBar,
                                    reorderEnabled: settled && !homeSelecting,
                                    onReorder: (oldIndex, newIndex) =>
                                        _onRootEntryReorder(
                                          oldIndex,
                                          newIndex,
                                          settings,
                                          rootNavPlan,
                                        ),
                                    onSelected: (entry) {
                                      final keyboard =
                                          HardwareKeyboard.instance;
                                      final fromKeyboard =
                                          keyboard.isLogicalKeyPressed(
                                            LogicalKeyboardKey.enter,
                                          ) ||
                                          keyboard.isLogicalKeyPressed(
                                            LogicalKeyboardKey.numpadEnter,
                                          ) ||
                                          keyboard.isLogicalKeyPressed(
                                            LogicalKeyboardKey.space,
                                          );
                                      _selectRootEntry(entry, settings);
                                      if (fromKeyboard) {
                                        MediaLibrarySpatialNavigation.focusInitial(
                                          context,
                                        );
                                      }
                                    },
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                ),
          centerTitle: false,
          leading: homeSelecting
              ? (useCompactTopBar
                    ? MediaLibraryCompactIconButton(
                        icon: Icons.close,
                        tooltip: '退出选择',
                        onPressed: _exitActiveSelection,
                      )
                    : DesktopButtonClickRegion(
                        child: IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: _exitActiveSelection,
                          tooltip: _managementTooltip(
                            "退出选择",
                            DesktopMediaManagementShortcutAction
                                .backOrExitSelection,
                          ),
                        ),
                      ))
              : widget.returnToSearchResults
              ? (useCompactTopBar
                    ? MediaLibraryCompactIconButton(
                        icon: Icons.arrow_back,
                        tooltip: '返回搜索结果',
                        onPressed: () => Navigator.of(context).maybePop(),
                      )
                    : DesktopButtonClickRegion(
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back),
                          tooltip: '返回搜索结果',
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ))
              : _showUndockedFolderTreeButton(settings)
              ? _buildFolderTreeToolbarButton(compact: useCompactTopBar)
              : null,
          actionsPadding: EdgeInsets.only(
            right: (cardInset - actionInnerInset - 2).clamp(
              0.0,
              double.infinity,
            ),
          ),
          actions: podcastSelecting
              ? [
                  if (useCompactTopBar)
                    MediaLibraryCompactIconButton(
                      icon: Icons.select_all,
                      tooltip: '全选',
                      onPressed: _podcastOverviewController.toggleSelectAll,
                    )
                  else
                    ResponsiveIconButton(
                      icon: Icons.select_all,
                      tooltip: '全选',
                      onPressed: _podcastOverviewController.toggleSelectAll,
                    ),
                  const SizedBox(width: 2),
                ]
              : useCompactTopBar
              ? _buildCompactTopBarActions(settings)
              : [
                  ResponsiveActionButtons(
                    spacing: 2,
                    buttons: [
                      if (!_isSelectionMode) ...[
                        if (ExternalAiToolbarAction.isSupported)
                          const ExternalAiToolbarAction(),
                        if (KeyboardShortcutHints.of(context))
                          ResponsiveIconButton(
                            icon: Icons.keyboard_outlined,
                            tooltip: '快捷键 (F1)',
                            onPressed: () =>
                                unawaited(showKeyboardShortcutHelp(context)),
                          ),
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
                            onPressed: () => _showLargeDataPathDialog(context),
                          ),
                        if (_showExportSettingsButton)
                          ResponsiveIconButton(
                            icon: Icons.explore_outlined,
                            tooltip: '使用前设置',
                            onPressed: _previewOnboarding,
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
                          onPressed: _openPortableTransfer,
                        ),
                        ResponsiveIconButton(
                          icon: Icons.search_rounded,
                          tooltip: _managementTooltip(
                            "搜索媒体库",
                            DesktopMediaManagementShortcutAction.openSearch,
                          ),
                          onPressed: _openSearch,
                        ),
                        AnimatedBuilder(
                          animation: MediaPlaybackService().sleepTimer,
                          builder: (context, _) {
                            final timer = MediaPlaybackService().sleepTimer;
                            return ResponsiveIconButton(
                              icon: timer.isActive
                                  ? Icons.alarm_on_rounded
                                  : Icons.schedule_rounded,
                              color: timer.isActive ? Colors.blueAccent : null,
                              tooltip: _managementTooltip(
                                timer.isActive ? timer.statusText : '定时关闭',
                                DesktopMediaManagementShortcutAction
                                    .openSleepTimer,
                              ),
                              onPressed: () =>
                                  unawaited(showSleepTimerDialog(context)),
                            );
                          },
                        ),
                        ResponsiveIconButton(
                          icon: Icons.delete_outline,
                          tooltip: _managementTooltip(
                            "回收站",
                            DesktopMediaManagementShortcutAction.openRecycleBin,
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
                            DesktopMediaManagementShortcutAction.openCardStyle,
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
                          onLongPress: () =>
                              unawaited(toggleDebugDeveloperMode(context)),
                          onPressed: () => showMediaLibrarySettingsBottomSheet(
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
                          onPressed: _enterActiveSelection,
                        ),
                      ] else ...[
                        ResponsiveIconButton(
                          icon: Icons.select_all,
                          tooltip: _managementTooltip(
                            "全选",
                            DesktopMediaManagementShortcutAction
                                .toggleSelectAll,
                          ),
                          onPressed: _toggleSelectAllOnHome,
                        ),
                      ],
                    ],
                  ),
                ],
          bottom: const MediaLibraryTopBarImportProgress(),
        ),
        // 使用 MediaQuery.removePadding 移除底部 padding，
        // 避免退出横屏播放页后 MiniPlaybackCard 位置偏下
        body: _experimentalFrame(
          enabled:
              experimental &&
              !homeSelecting &&
              !rootNavPlan.forceFoldersForLocate,
          settings: settings,
          plan: rootNavPlan,
          child: SafeArea(
            top: false,
            bottom: false,
            child: MediaQueryPaddingRemover(
              bottom: true,
              child: Focus(
                focusNode: _shortcutFocusNode,
                autofocus: _supportsDesktopManagementShortcuts,
                onKeyEvent: (node, event) => _handleShortcutKeyEvent(event),
                child: MediaLibraryKeyboardRegion(
                  key: _keyboardRegionKey,
                  surface: _displayedRootEntry,
                  orderedIds: _keyboardOrderedIds,
                  selectionMode: () =>
                      _isSelectionMode || _podcastSelectionActive,
                  selectedIds: () => _podcastSelectionActive
                      ? _podcastOverviewController.selectedIds
                      : _selectedIds,
                  onSelectionChanged: (ids) {
                    if (_podcastSelectionActive) {
                      _podcastOverviewController.setKeyboardSelection(ids);
                    } else {
                      setState(() {
                        _selectedIds
                          ..clear()
                          ..addAll(ids);
                      });
                    }
                  },
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      _selectionPointer.down(event.pointer);
                      if (_supportsDesktopManagementShortcuts &&
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
                    child: Selector<LibraryService, int>(
                      selector: (_, service) => service.browseRevision,
                      builder: (context, _, child) {
                        final library = context.read<LibraryService>();
                        final contents = _visibleBrowseContents(
                          library,
                          settings,
                        );
                        _scheduleRevealIfNeeded(contents);

                        return DropTarget(
                          onDragDone: (details) {
                            if (!isMediaLibraryRouteCurrent(context)) return;
                            _setDraggingFiles(false);
                            final paths = details.files
                                .map((f) => f.path)
                                .toList();
                            if (paths.isNotEmpty) {
                              VideoActionButtons.processDroppedPaths(
                                context,
                                paths,
                                null,
                              );
                            }
                          },
                          onDragEntered: (_) {
                            if (!isMediaLibraryRouteCurrent(context)) return;
                            _setDraggingFiles(true);
                          },
                          onDragExited: (_) => _setDraggingFiles(false),
                          child: ValueListenableBuilder<MediaLibraryRootEntry?>(
                            valueListenable: _rootEntryOverride,
                            builder: (context, selectedOverride, child) {
                              final displayed = _effectiveRootEntry(
                                rootNavPlan,
                              );
                              final showingVirtual =
                                  !rootNavPlan.forceFoldersForLocate &&
                                  displayed != MediaLibraryRootEntry.folders;
                              return Stack(
                                children: [
                                  Listener(
                                    onPointerDown: (event) {
                                      _activePointerKind = event.kind;
                                    },
                                    child: RawGestureDetector(
                                      gestures: {
                                        _MouseOrPinchScaleRecognizer:
                                            GestureRecognizerFactoryWithHandlers<
                                              _MouseOrPinchScaleRecognizer
                                            >(_createScaleRecognizer, (
                                              recognizer,
                                            ) {
                                              recognizer
                                                ..onStart = (details) {
                                                  if (_tryStartMouseBoxSelection(
                                                    pointerCount:
                                                        details.pointerCount,
                                                    globalPos:
                                                        details.focalPoint,
                                                  )) {
                                                    return;
                                                  }
                                                  _baseCrossAxisCount =
                                                      settings
                                                          .mediaLibraryUsesRowPipeline
                                                      ? _listStyle()
                                                            .crossAxisCount
                                                      : _homeCardStyle()
                                                            .crossAxisCount;
                                                }
                                                ..onUpdate = (details) {
                                                  if (_isBoxSelecting) {
                                                    _applyMouseBoxSelectionAt(
                                                      details.focalPoint,
                                                    );
                                                    _syncSelectionAutoScroll(
                                                      details.focalPoint,
                                                    );
                                                    return;
                                                  }
                                                  if (details.pointerCount <
                                                      2) {
                                                    return;
                                                  }

                                                  double newScale =
                                                      details.scale;
                                                  int newCount =
                                                      _baseCrossAxisCount;

                                                  if (newScale > 1.3) {
                                                    newCount =
                                                        (_baseCrossAxisCount -
                                                                1)
                                                            .clamp(1, 20);
                                                  } else if (newScale < 0.7) {
                                                    newCount =
                                                        (_baseCrossAxisCount +
                                                                1)
                                                            .clamp(1, 20);
                                                  }

                                                  final currentCount =
                                                      settings
                                                          .mediaLibraryUsesRowPipeline
                                                      ? _listStyle()
                                                            .crossAxisCount
                                                      : _homeCardStyle()
                                                            .crossAxisCount;
                                                  if (newCount !=
                                                      currentCount) {
                                                    final size =
                                                        MediaQuery.sizeOf(
                                                          context,
                                                        );
                                                    if (settings
                                                        .mediaLibraryUsesRowPipeline) {
                                                      unawaited(
                                                        settings
                                                            .updateActiveListColumnsFor(
                                                              size,
                                                              newCount,
                                                            ),
                                                      );
                                                    } else {
                                                      unawaited(
                                                        settings
                                                            .updateHomeCardStyleFor(
                                                              size,
                                                              crossAxisCount:
                                                                  newCount,
                                                            ),
                                                      );
                                                    }
                                                  }
                                                }
                                                ..onEnd = (details) {
                                                  if (_isBoxSelecting) {
                                                    _finishMouseBoxSelection();
                                                  }
                                                };
                                            }),
                                      },
                                      child: Selector<MediaPlaybackService, bool>(
                                        selector: (_, playbackService) =>
                                            playbackService
                                                .shouldShowMiniPlaybackCard,
                                        builder: (context, isCardVisible, child) {
                                          final cardBottomPadding =
                                              PlaybackCardOverlayLayout.contentBottomPadding(
                                                stableBottomInset:
                                                    _stablePlaybackBottomInset,
                                                selectionBarHeight:
                                                    selectionBarObstruction,
                                                cardHeight:
                                                    PlaybackCardLayout.calculate(
                                                      context,
                                                    ).height,
                                                isCardVisible:
                                                    isCardVisible ||
                                                    _hasPendingPlaybackState,
                                              );

                                          return ValueListenableBuilder<
                                            List<MediaLibraryRootEntry>
                                          >(
                                            valueListenable: _rootEntryOrder,
                                            builder: (context, order, child) {
                                              return MediaLibraryRootSurfaceHost(
                                                key: _rootSurfaceHostKey,
                                                displayedEntry: displayed,
                                                entryOrder: order,
                                                swipeEnabled:
                                                    !_isSelectionMode &&
                                                    !podcastSelecting &&
                                                    !false,
                                                swipeHighlightIndex:
                                                    _rootSwipeHighlight,
                                                swipeSettled: _rootSwipeSettled,
                                                onUserSwipe: (entry) =>
                                                    _selectRootEntry(
                                                      entry,
                                                      settings,
                                                    ),
                                                continueBuilder: (context, active) {
                                                  if (active &&
                                                      _isSelectionMode) {
                                                    WidgetsBinding.instance
                                                        .addPostFrameCallback((
                                                          _,
                                                        ) {
                                                          _pruneVirtualSelectionToVisible();
                                                        });
                                                  }
                                                  return MediaLibraryScrollViewport.library(
                                                    settings: settings,
                                                    screenSize:
                                                        MediaQuery.sizeOf(
                                                          context,
                                                        ),
                                                    controller:
                                                        _continueScrollController,
                                                    isActive: active,
                                                    bottomObstruction:
                                                        cardBottomPadding,
                                                    child: MediaLibraryContinueView(
                                                      onBrowseLibrary: () =>
                                                          _selectRootEntry(
                                                            MediaLibraryRootEntry
                                                                .folders,
                                                            settings,
                                                          ),
                                                      isActive: active,
                                                      scrollController:
                                                          _continueScrollController,
                                                      cardBottomPadding:
                                                          cardBottomPadding,
                                                      selection: active
                                                          ? _virtualSelectionBinding(
                                                              _continueSelectionHost,
                                                            )
                                                          : null,
                                                      onOpenMedia: (item) {
                                                        final playback =
                                                            Provider.of<
                                                              MediaPlaybackService
                                                            >(
                                                              context,
                                                              listen: false,
                                                            );
                                                        final controller =
                                                            playback
                                                                    .currentItem
                                                                    ?.id ==
                                                                item.id
                                                            ? playback
                                                                  .controller
                                                            : null;
                                                        _openPlaybackScreen(
                                                          item,
                                                          existingController:
                                                              controller,
                                                        );
                                                      },
                                                      onOpenFolder: (collection) {
                                                        Navigator.of(
                                                          context,
                                                        ).push(
                                                          buildMediaLibraryFolderRoute<
                                                            void
                                                          >(
                                                            folderId:
                                                                collection.id,
                                                            builder: (_) =>
                                                                CollectionScreen(
                                                                  collectionId:
                                                                      collection
                                                                          .id,
                                                                ),
                                                          ),
                                                        );
                                                      },
                                                      onLocateMedia:
                                                          _locateLibraryItem,
                                                      onLocateFolder:
                                                          (
                                                            collection,
                                                          ) => _locateLibraryEntry(
                                                            id: collection.id,
                                                            parentId: collection
                                                                .parentId,
                                                          ),
                                                    ),
                                                  );
                                                },
                                                recentBuilder: (context, active) {
                                                  if (active &&
                                                      _isSelectionMode) {
                                                    WidgetsBinding.instance
                                                        .addPostFrameCallback((
                                                          _,
                                                        ) {
                                                          _pruneVirtualSelectionToVisible();
                                                        });
                                                  }
                                                  return MediaLibraryScrollViewport.library(
                                                    settings: settings,
                                                    screenSize:
                                                        MediaQuery.sizeOf(
                                                          context,
                                                        ),
                                                    controller:
                                                        _recentScrollController,
                                                    isActive: active,
                                                    bottomObstruction:
                                                        cardBottomPadding,
                                                    child: MediaLibraryRecentView(
                                                      onBrowseLibrary: () =>
                                                          _selectRootEntry(
                                                            MediaLibraryRootEntry
                                                                .folders,
                                                            settings,
                                                          ),
                                                      isActive: active,
                                                      scrollController:
                                                          _recentScrollController,
                                                      cardBottomPadding:
                                                          cardBottomPadding,
                                                      expandBatchId:
                                                          _pendingRecentBatchId,
                                                      selection: active
                                                          ? _virtualSelectionBinding(
                                                              _recentSelectionHost,
                                                            )
                                                          : null,
                                                      onOpenMedia: (item) {
                                                        final playback =
                                                            Provider.of<
                                                              MediaPlaybackService
                                                            >(
                                                              context,
                                                              listen: false,
                                                            );
                                                        final controller =
                                                            playback
                                                                    .currentItem
                                                                    ?.id ==
                                                                item.id
                                                            ? playback
                                                                  .controller
                                                            : null;
                                                        _openPlaybackScreen(
                                                          item,
                                                          existingController:
                                                              controller,
                                                        );
                                                      },
                                                      onOpenFolder: (collection) {
                                                        Navigator.of(
                                                          context,
                                                        ).push(
                                                          buildMediaLibraryFolderRoute<
                                                            void
                                                          >(
                                                            folderId:
                                                                collection.id,
                                                            builder: (_) =>
                                                                CollectionScreen(
                                                                  collectionId:
                                                                      collection
                                                                          .id,
                                                                ),
                                                          ),
                                                        );
                                                      },
                                                      onLocateMedia:
                                                          _locateLibraryItem,
                                                      onLocateFolder:
                                                          (
                                                            collection,
                                                          ) => _locateLibraryEntry(
                                                            id: collection.id,
                                                            parentId: collection
                                                                .parentId,
                                                          ),
                                                    ),
                                                  );
                                                },
                                                foldersBuilder: (context, active) {
                                                  if (contents.isEmpty) {
                                                    return MediaLibraryEmptyState(
                                                      icon: Icons
                                                          .folder_open_outlined,
                                                      message: '暂无媒体内容',
                                                      actionLabel: '导入媒体',
                                                      onAction: () =>
                                                          VideoActionButtons.showImportMenu(
                                                            context,
                                                            null,
                                                          ),
                                                      bottomPadding:
                                                          cardBottomPadding,
                                                    );
                                                  }
                                                  return _wrapScrollAreaWithTableHeader(
                                                    context: context,
                                                    settings: settings,
                                                    child:
                                                        _buildMediaGridOrList(
                                                          context: context,
                                                          library: library,
                                                          settings: settings,
                                                          contents: contents,
                                                          cardBottomPadding:
                                                              cardBottomPadding,
                                                          isActive: active,
                                                        ),
                                                  );
                                                },
                                                podcastsBuilder:
                                                    (
                                                      context,
                                                      active,
                                                    ) => PodcastOverviewPage(
                                                      controller:
                                                          _podcastOverviewController,
                                                      bottomPadding:
                                                          cardBottomPadding,
                                                      isActive: active,
                                                    ),
                                              );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  if (!showingVirtual && contents.length < 20)
                                    Positioned.fill(
                                      key: MediaLibraryOverlayKeys
                                          .emptySpaceHitTarget,
                                      child: Listener(
                                        behavior: HitTestBehavior.translucent,
                                        onPointerDown: (_) {},
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
                                  if (_isDraggingFiles)
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
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ), // 关闭 MediaQuery.removePadding 的 child
            ),
          ), // 关闭 body: MediaQuery.removePadding(...)
        ),
        floatingActionButtonLocation: const PlaybackActionButtonsLocation(),
        floatingActionButton:
            !homeSelecting &&
                !(experimental &&
                    ExperimentalSidebarMetrics.usesSidebar(
                      MediaQuery.sizeOf(context).width,
                    ))
            ? Selector<MediaPlaybackService, bool>(
                selector: (_, service) =>
                    _hasPendingPlaybackState ||
                    service.shouldShowMiniPlaybackCard,
                builder: (context, isCardVisible, child) =>
                    ValueListenableBuilder<MediaLibraryRootEntry?>(
                      valueListenable: _rootEntryOverride,
                      builder: (context, _, child) {
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
                            onCreateCollection: _createCollectionForActiveEntry,
                            collectionId: null,
                            maxExpandedHeight: maxExpandedHeight,
                          ),
                        );
                      },
                    ),
              )
            : null,
        bottomNavigationBar: MediaLibrarySelectionBarTransition(
          child: podcastSelecting
              ? _podcastOverviewController.buildSelectionBottomBar()
              : _isSelectionMode && _selectedIds.isNotEmpty
              ? MediaLibrarySelectionBottomBar(
                  cacheSelectedIds: Set.of(_selectedIds),
                  queueSelectedIds: _queueSelectionInViewOrder(library),
                  onQueueProcessed: (ids) {
                    if (!mounted) return;
                    setState(() {
                      _selectedIds.removeAll(ids);
                      if (_selectedIds.isEmpty) _isSelectionMode = false;
                    });
                  },
                  actions: _selectionBottomActions(library),
                  onAction: (kind) {
                    unawaited(_onVirtualSelectionAction(kind));
                  },
                )
              : null,
        ),
      ),
    );
  }

  Widget _experimentalFrame({
    required bool enabled,
    required SettingsService settings,
    required MediaLibraryNavigationPlan plan,
    required Widget child,
  }) {
    if (!enabled) return child;
    return Selector<MediaPlaybackService, bool>(
      selector: (_, playback) => playback.shouldShowMiniPlaybackCard,
      builder: (context, cardVisible, _) =>
          ValueListenableBuilder<List<MediaLibraryRootEntry>>(
            valueListenable: _rootEntryOrder,
            builder: (context, order, _) =>
                ValueListenableBuilder<MediaLibraryRootEntry?>(
                  valueListenable: _rootEntryOverride,
                  builder: (context, _, _) => ExperimentalHomeFrame(
                    selected: _effectiveRootEntry(plan),
                    bottomObstruction: cardVisible || _hasPendingPlaybackState
                        ? PlaybackCardLayout.calculate(context).height +
                              _stablePlaybackBottomInset +
                              16
                        : 0,
                    available: _mountedRootEntries,
                    entries: order,
                    onReorder: (oldIndex, newIndex) =>
                        _onRootEntryReorder(oldIndex, newIndex, settings, plan),
                    onSelected: (entry) => _selectRootEntry(entry, settings),
                    onSettings: () =>
                        showMediaLibrarySettingsBottomSheet(context, settings),
                    shortcutsEnabled: () => isMediaLibraryRouteCurrent(context),
                    actions: [
                      ExperimentalSidebarAction(
                        '导入媒体',
                        Icons.video_call,
                        () => unawaited(
                          VideoActionButtons.showImportMenu(context, null),
                        ),
                      ),
                      ExperimentalSidebarAction(
                        '新建合集',
                        Icons.create_new_folder,
                        _createCollectionForActiveEntry,
                      ),
                      ExperimentalSidebarAction(
                        '语音转录',
                        Icons.closed_caption,
                        () => VideoActionButtons.openBatchSubtitlePage(context),
                      ),
                    ],
                    child: child,
                  ),
                ),
          ),
    );
  }

  Widget _buildMediaGridOrList({
    required BuildContext context,
    required LibraryService library,
    required SettingsService settings,
    required List<dynamic> contents,
    required double cardBottomPadding,
    required bool isActive,
  }) => MediaLibraryScrollViewport.library(
    settings: settings,
    screenSize: MediaQuery.sizeOf(context),
    controller: _scrollController,
    isActive: isActive,
    bottomObstruction: cardBottomPadding,
    child: LayoutBuilder(
      builder: (context, constraints) => MediaLibraryCardPreload.library(
        context: context,
        settings: settings,
        controller: _scrollController,
        contents: contents,
        availableWidth: constraints.maxWidth,
        active: isActive,
        child: _buildMediaGridOrListContent(
          context: context,
          library: library,
          settings: settings,
          contents: contents,
          cardBottomPadding: cardBottomPadding,
          isActive: isActive,
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
    required double cardBottomPadding,
    required bool isActive,
    required double availableWidth,
  }) {
    if (!settings.mediaLibraryUsesRowPipeline) {
      final metrics = MediaLibraryLayoutDefaults.cardGrid(
        textScaler: MediaQuery.textScalerOf(context),
        textStyle: DefaultTextStyle.of(context).style,
        screenSize: Size(availableWidth, MediaQuery.sizeOf(context).height),
        style: settings.homeCardStyleFor(MediaQuery.sizeOf(context)),
      );
      return MediaLibraryFrozenWhenInactive(
        active: isActive,
        changes: library,
        child: PlaybackGridView.builder(
          itemKey: (index) => (contents[index] as dynamic).id as String,
          controller: _scrollController,
          padding: EdgeInsets.only(
            left: metrics.outerPadding,
            right: metrics.outerPadding,
            top: metrics.topPadding,
            bottom: metrics.outerPadding + cardBottomPadding,
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
        ),
      );
    }

    return MediaLibraryFrozenWhenInactive(
      active: isActive,
      changes: library,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final listStyle = settings.listStyleFor(MediaQuery.sizeOf(context));
          final columns = listStyle.isTable ? 1 : listStyle.crossAxisCount;
          final metrics = MediaListLayoutMetrics.forStyle(
            style: listStyle,
            screenShortestSide: MediaQuery.sizeOf(context).shortestSide,
            availableWidth: constraints.maxWidth,
          );

          return PlaybackGridView.builder(
            itemKey: (index) => (contents[index] as dynamic).id as String,
            controller: _scrollController,
            padding: EdgeInsets.only(
              left: metrics.outerPadding,
              right: metrics.outerPadding,
              top: metrics.topPadding,
              bottom: metrics.outerPadding + cardBottomPadding,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
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
                  crossAxisCount: columns,
                  child: card,
                );
              },
            ),
          );
        },
      ),
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
        setState(() {
          if (_selectedIds.contains(collection.id)) {
            _selectedIds.remove(collection.id);
          } else {
            _selectedIds.add(collection.id);
          }
        });
      } else {
        Navigator.of(context)
            .push(
              buildMediaLibraryFolderRoute<void>(
                folderId: collection.id,
                builder: (context) =>
                    CollectionScreen(collectionId: collection.id),
              ),
            )
            .then((_) {
              if (!context.mounted) return;
              unawaited(
                Provider.of<SettingsService>(
                  context,
                  listen: false,
                ).saveMediaLibraryLastFolder(''),
              );
            });
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
      style: listStyle,
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
      allowReorder: settings.mediaLibraryAllowsManualOrder,
      onReorder: (oldIndex, newIndex) {
        _reorderMediaItems(library, contents, null, oldIndex, newIndex);
      },
      folderId: collection.id,
      onMoveToFolder: (draggedIndex, targetId) async {
        await _moveMediaItemsToFolder(
          library,
          contents,
          currentParentId: null,
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
        setState(() {
          if (_selectedIds.contains(item.id)) {
            _selectedIds.remove(item.id);
          } else {
            _selectedIds.add(item.id);
          }
        });
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
      style: listStyle,
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
      allowHidePodcastFromFolders: true,
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
      allowReorder: settings.mediaLibraryAllowsManualOrder,
      onReorder: (oldIndex, newIndex) {
        _reorderMediaItems(library, contents, null, oldIndex, newIndex);
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
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (!settings.mediaLibraryAllowsManualOrder) return;
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
          final textInset = MediaLibraryActionDockMetrics.textInset(
            chipSize: chipSize,
            showMore: showMenu,
            showSync: showSync,
            showLocate: false,
            existingPadding: MediaListLayoutMetrics.cardGridContentPadding(
              cardWidth,
            ).right,
          );
          final double radius = MediaLibraryLayoutDefaults.cardCornerRadius(
            cardWidth,
          );
          final double titleFontSize = _resolveCardTitleFontSize(
            cardWidth,
            settings.homeCardStyleFor(MediaQuery.sizeOf(context)).titleScale,
          );
          final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);
          final isSelected = _selectedIds.contains(collection.id);
          final thumbnailPath = collection.thumbnailPath;
          final hasThumbnail =
              thumbnailPath != null && thumbnailPath.isNotEmpty;

          // 1. The Visual Content of the Card
          Widget cardVisual = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Thumbnail Area (Fixed Folder Icon)
              AspectRatio(
                aspectRatio: _mediaCardCoverAspectRatio,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (collection.isPodcast) {
                      return PodcastCardCover(collection: collection);
                    }
                    final iconSize = constraints.maxWidth * 0.15;
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
                              : '${library.browseContents(collection.id).length} 个项目',
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
              setState(() {
                if (isSelected) {
                  _selectedIds.remove(collection.id);
                } else {
                  _selectedIds.add(collection.id);
                }
              });
            } else {
              Navigator.of(context)
                  .push(
                    buildMediaLibraryFolderRoute<void>(
                      folderId: collection.id,
                      builder: (context) =>
                          CollectionScreen(collectionId: collection.id),
                    ),
                  )
                  .then((_) {
                    if (!context.mounted) return;
                    unawaited(
                      Provider.of<SettingsService>(
                        context,
                        listen: false,
                      ).saveMediaLibraryLastFolder(''),
                    );
                  });
            }
          }

          Widget interactiveCard = MediaLibraryGridCard(
            keyboardItemId: collection.id,
            isSelectionMode: _isSelectionMode,
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
                          fillSlot: true,
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
                  allowReorder: settings.mediaLibraryAllowsManualOrder,
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
                        currentParentId: null,
                        attemptedItemIds: itemsToMove,
                      );
                      AppToast.show("已移动到文件夹", type: AppToastType.success);
                    }
                  },
                  onReorder: (oldIndex, newIndex) {
                    if (!settings.mediaLibraryAllowsManualOrder) return;
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
                        null,
                        itemsToMove,
                        oldIndex,
                        newIndex,
                      );
                    } else {
                      library.reorderItems(null, oldIndex, newIndex);
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
                    onTap: () {
                      setState(() {
                        if (isSelected) {
                          _selectedIds.remove(collection.id);
                        } else {
                          _selectedIds.add(collection.id);
                        }
                      });
                    },
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
          final textInset = MediaLibraryActionDockMetrics.textInset(
            chipSize: chipSize,
            showMore: showMenu,
            showLocate: false,
            existingPadding: MediaListLayoutMetrics.cardGridContentPadding(
              cardWidth,
            ).right,
          );
          final double radius = MediaLibraryLayoutDefaults.cardCornerRadius(
            cardWidth,
          );
          final double titleFontSize = _resolveCardTitleFontSize(
            cardWidth,
            settings.homeCardStyleFor(MediaQuery.sizeOf(context)).titleScale,
          );
          final double metaFontSize = _resolveCardMetaFontSize(titleFontSize);
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
                          mediaLibraryItemTitle(context, item),
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
              setState(() {
                if (isSelected) {
                  _selectedIds.remove(item.id);
                } else {
                  _selectedIds.add(item.id);
                }
              });
            } else {
              // 通过 MediaPlaybackService 开始播放
              final playbackService = Provider.of<MediaPlaybackService>(
                context,
                listen: false,
              );
              // 进入播放页面
              if (!mounted) return;

              // 仅当当前播放的视频与点击的视频一致时，才复用控制器
              // 否则传入 null，让 VideoPlayerScreen 自行处理初始化（它会调用 MediaPlaybackService.play）
              final currentController =
                  playbackService.currentItem?.id == item.id
                  ? playbackService.controller
                  : null;

              _openPlaybackScreen(item, existingController: currentController);
            }
          }

          Widget interactiveCard = MediaLibraryGridCard(
            keyboardItemId: item.id,
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
                          fillSlot: true,
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
                        child: _selectedIds.length > 1 && isSelected
                            ? Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.movie,
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
                      settings.mediaLibraryAllowsManualOrder &&
                      details.data != index,
                  onAcceptWithDetails: (details) {
                    if (!settings.mediaLibraryAllowsManualOrder) return;
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
                        null,
                        itemsToMove,
                        oldIndex,
                        index,
                      );
                    } else {
                      library.reorderItems(null, oldIndex, index);
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
                    onTap: () {
                      setState(() {
                        if (isSelected) {
                          _selectedIds.remove(item.id);
                        } else {
                          _selectedIds.add(item.id);
                        }
                      });
                    },
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

  Future<void> _showLargeDataPathDialog(BuildContext context) async {
    await showAppStorageSettingsDialog(context);
  }
}

/// One-finger touch must not become a scale pan: that would steal vertical
/// scrolling and the adjacent-tab swipe. Mouse still uses one pointer for
/// box select; pinch still needs two fingers.
class _MouseOrPinchScaleRecognizer extends ScaleGestureRecognizer {
  _MouseOrPinchScaleRecognizer({this.isSuspended});

  /// True while a page that owns its own gestures (text fields, lists) is
  /// shown, so box select and pinch never compete with it.
  final bool Function()? isSuspended;

  int _touchPointers = 0;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (isSuspended?.call() ?? false) return false;
    return super.isPointerAllowed(event);
  }

  bool _isTouchLike(PointerDeviceKind kind) {
    return kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_isTouchLike(event.kind)) {
      _touchPointers++;
    }
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_isTouchLike(event.kind) &&
        (event is PointerUpEvent || event is PointerCancelEvent) &&
        _touchPointers > 0) {
      _touchPointers--;
    }
    if (event is PointerMoveEvent &&
        _isTouchLike(event.kind) &&
        _touchPointers < 2) {
      return;
    }
    super.handleEvent(event);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _touchPointers = 0;
    super.didStopTrackingLastPointer(pointer);
  }
}
