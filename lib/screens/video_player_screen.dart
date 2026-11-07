import '../services/subtitle_editor_persistence.dart';
import '../widgets/bilibili_startup_poster.dart';
import '../widgets/mobile_system_navigation_bar.dart';
import '../models/subtitle_stream.dart';
import '../services/subtitle_font_service.dart';
import '../services/subtitle_debug_session.dart';
import '../features/podcasts/podcast_playback_hooks.dart';
import 'dart:async';
import '../services/drag_haptic_session.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';
import 'package:video_player_app/utils/media_duration_probe.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:math' as math;
import '../debug/developer_log.dart' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/operation_status.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:cross_file/cross_file.dart';
import 'package:path/path.dart' as p;
import '../services/embedded_subtitle_service.dart';
import '../services/bilibili/bilibili_video_shot_backfill.dart';
import '../services/media_playback_service.dart';
import '../services/native_playback_control_session.dart';
import '../features/cloud_drive/models/cloud_drive_models.dart';
import '../features/cloud_drive/presentation/cloud_drive_screen.dart';
import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../features/cloud_drive/services/seek_preview_policy.dart';
import '../services/playback_navigation_service.dart';
import '../services/playlist_manager.dart';
import '../services/playback_behavior_policy.dart';
import '../services/playback_exit_guard.dart';
import '../utils/route_transition_work.dart';
import '../services/player_panel_history.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../services/subtitle_word_timing_store.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_style.dart';
import '../models/danmaku_style.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../models/media_chapter.dart';
import '../models/managed_subtitle_asset.dart';
import '../models/ocr_subtitle_models.dart';
import 'music_player_screen.dart'; // Experimental Apple Music page
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../services/bilibili/bilibili_danmaku_auto_update.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/library_service.dart';
import '../services/task_subtitle_storage_service.dart';
import '../widgets/subtitle_overlay.dart';
import '../widgets/subtitle_display_layer.dart';
import '../models/subtitle_display_state.dart';
import '../widgets/relocate_local_media_source.dart';
import '../widgets/video_controls_overlay.dart';
import '../widgets/player_control_metrics.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/danmaku_settings_dialog.dart';
import '../widgets/episode_picker_panel.dart';
import '../widgets/settings_panel.dart';
import '../widgets/ambient_letterbox_layer.dart';
import '../widgets/subtitle_settings_sheet.dart';
import '../widgets/subtitle_sidebar.dart';
import '../widgets/bilibili_portrait_tabs.dart';
import '../utils/bilibili_panel_tab_shortcuts.dart';
import '../widgets/subtitle_chat_sidebar.dart';
import '../widgets/subtitle_position_sidebar.dart';
import '../widgets/landscape_subtitle_editor_sidebar.dart';
import '../widgets/subtitle_management_sheet.dart';
import '../widgets/ai_transcription_panel.dart';
import '../widgets/video_compose_panel.dart';
import '../widgets/ocr_subtitle_panel.dart';
import '../features/ai_chat/ai_chat_panel.dart';
import '../features/ai_chat/ai_chat_layout.dart';
import '../features/ai_chat/ai_sidebar_width.dart';
import '../theme/app_tokens.dart';
import '../widgets/chapter_sidebar.dart';
import '../widgets/landscape_sidebar_layout.dart';
import '../widgets/desktop_player_sidebar.dart';
import '../widgets/player_sidebar_motion.dart';
import '../widgets/sidebar_activity.dart';
import '../widgets/player_sidebar_resize_indicator.dart';
import '../widgets/player_subtitle_sidebar_toggle.dart';
import '../widgets/stable_video_surface.dart';
import '../widgets/bilibili_cover_image.dart';
import '../widgets/bilibili_panel_overlay.dart';
import '../widgets/bilibili_player_panel.dart';
import '../widgets/bilibili_subtitle_tracks_section.dart';
import '../widgets/cloud_drive_subtitle_tracks_section.dart';
import '../services/transcription_manager.dart';
import '../services/ocr_subtitle_manager.dart';
import '../services/bilibili/bilibili_player_panel_memory.dart';
import '../services/bilibili/bilibili_player_panel_policy.dart';
import '../services/bilibili/bilibili_player_video.dart';
import '../services/subtitle_discovery_service.dart';
import '../services/video_compose/video_compose_preview_controller.dart';
import '../utils/app_toast.dart';
import '../utils/linux_audio_device.dart';
import '../utils/playback_page_visibility.dart';
import '../models/subtitle_position.dart';
import '../services/subtitle_position_actions.dart';
import '../services/subtitle_position_controller.dart';
import '../utils/subtitle_position_geometry.dart';
import '../utils/subtitle_file_picker.dart';
import '../utils/video_gesture_session_gate.dart';
import '../utils/landscape_sidebar_safe_insets.dart';
import '../widgets/media_query_padding_remover.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

enum SidebarType {
  none,
  chapters,
  subtitles,
  settings,
  subtitleStyle,
  subtitlePosition,
  subtitleManager,
  subtitleEditor,
  aiTranscription,
  videoCompose,
  ocrSubtitle,
  aiChat,
  bilibili,
}

@visibleForTesting
bool shouldMountPlaybackControls({
  required bool initialized,
  required bool controllerAssigned,
  required bool sourceMissing,
  required bool subtitleDragActive,
  required bool ghostDragActive,
}) {
  // Chrome owns its visibility independently of native initialization. Keep
  // the same overlay through source resolution and controller hand-off.
  return !subtitleDragActive && !ghostDragActive;
}

@visibleForTesting
bool isLandscapeSubtitleViewportReady({
  required Size size,
  required bool isMobilePlatform,
}) {
  if (!isMobilePlatform) return true;
  // Phones must wait until the forced-orientation metrics have reached the
  // landscape page. Tablets can legitimately keep a portrait-shaped viewport
  // in split-screen or when the platform does not enforce app orientation.
  return size.shortestSide >= 600 || size.width >= size.height;
}

/// Chrome shown on the landscape overlay after leaving the portrait player.
///
/// Prefer the live overlay state so a just-hidden (or still-visible) portrait
/// chrome survives the route change. Fall back to the last intent only when
/// the overlay is unmounted (subtitle drag, missing source, etc.).
bool landscapePlaybackChromeFromPortrait({
  required bool? overlayControlsVisible,
  required bool lastIntent,
}) {
  return overlayControlsVisible ?? lastIntent;
}

class VideoPlayerScreen extends StatefulWidget {
  final XFile? videoFile; // Optional now
  final VideoPlayerController? existingController; // New
  final VideoItem? videoItem; // New
  final bool skipAutoPauseOnExit;
  final bool? autoPlayOnEntry;

  /// Immediate chrome intent from the portrait overlay. Direct landscape
  /// entry (skip-portrait, desktop) starts hidden until user interaction.
  final bool initialShowControls;

  /// The source owner is preparing this item. Show this page immediately and
  /// join its session once published, without starting a second play request.
  final bool deferPlaybackUntilCurrent;

  const VideoPlayerScreen({
    super.key,
    this.videoFile,
    this.existingController,
    this.videoItem,
    this.skipAutoPauseOnExit = false,
    this.autoPlayOnEntry,
    this.initialShowControls = false,
    this.deferPlaybackUntilCurrent = false,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin, RouteAware {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<SelectionAreaState> _selectionKey =
      GlobalKey<SelectionAreaState>();
  final FocusNode _selectionFocusNode = FocusNode();
  bool _hasPageTextSelection = false;
  final FocusNode _videoFocusNode =
      FocusNode(); // New: Dedicated focus node for video controls
  final FocusNode _playbackPageFocusNode = FocusNode(
    debugLabel: 'PlaybackPageShortcutFocus',
  );
  final GlobalKey<VideoControlsOverlayState> _controlsKey =
      GlobalKey<VideoControlsOverlayState>();
  final GlobalKey _videoTextureKey = GlobalKey(
    debugLabel: 'LandscapePlaybackVideoTexture',
  );
  late final ValueNotifier<bool> _playbackControlsVisibility;

  /// Last immediate chrome intent. Survives overlay remounts (episode skip,
  /// subtitle drag) so hidden controls do not flash back on.
  late bool _playbackChromeVisible;
  final GlobalKey<SubtitleSidebarState> _subtitleSidebarKey =
      GlobalKey<SubtitleSidebarState>();
  late VideoPlayerController _controller;
  bool _controllerAssigned = false;
  bool _initialized = false;
  bool _pageEntryAutoPlayConsumed = false;
  bool _isSourceMissing = false;
  bool _isPlaying = false;
  bool _isControllerOwner = false;
  bool _isSubtitleSidebarVisible = true;
  bool _initialControllerConsumed = false;
  bool _routeObserverSubscribed = false;
  bool _isOpeningMusicPlayer = false;
  bool _pendingSubtitleSidebarViewportRestore = false;
  bool _subtitleSidebarRestoreCallbackScheduled = false;
  int _subtitleSidebarRestoreRetries = 0;
  static const int _subtitleSidebarRestoreMaxRetries = 30;
  int _danmakuRevision = 0;
  bool get _supportsOcrSubtitle =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;

  // Local UI State
  bool _isLocked = false;
  bool _isLongPressing = false;
  String _longPressFeedbackText = "";
  double _preLongPressSpeed = 1.0;
  MediaPlaybackService? _longPressPlaybackService;

  // Sidebar
  SidebarType _activeSidebar = SidebarType.none;
  late final PlayerSidebarMotion _sidebarMotion;
  Size? _sidebarMotionViewport;
  Object _readingSurface = PlayerSidebarMotion.subtitleSurface;
  final _sidebarHistory = PlayerPanelHistory<SidebarType>();
  int _sidebarNavigationVersion = 0;
  bool _bilibiliOpenedManually = false;
  SidebarType? _sidebarBaseOverride;
  bool get _isSidebarOpen => _activeSidebar != SidebarType.none;
  bool get _suppressSubtitleOverlayForOcr =>
      _activeSidebar == SidebarType.ocrSubtitle;
  bool _isResizingSidebar = false;
  final _sidebarResizeHaptics = DragHapticSession(step: 12);
  final ValueNotifier<bool> _sidebarResizeHovered = ValueNotifier(false);
  double? _subtitleSidebarWidthOverride;
  double? _aiSidebarWidthOverride;
  bool _resizingAiSidebar = false;
  final LayerLink _sidebarDividerLink = LayerLink();
  final LayerLink _sidebarToggleLink = LayerLink();
  VideoPlayerController? _videoSurfaceController;
  String? _videoSurfaceItemId;
  Widget? _videoSurfaceWidget;
  int? _sidebarResizeFrame;
  int _sidebarResizeRevision = 0;
  bool _forceExit = false;
  bool _explicitPlaybackExitRequested = false;
  final PlaybackExitGuard _exitGuard = PlaybackExitGuard();
  Future<void>? _exitCleanupFuture;
  bool _iosBackSwipeActive = false;
  double _iosBackSwipeDistance = 0.0;
  static const double _iosBackSwipeEdgeWidth = 20.0;
  static const double _iosBackSwipeTriggerDistance = 60.0;
  static const double _subtitleSidebarResizerLayoutWidth = 12.0;
  static const double _subtitleSidebarResizerHitWidth = 20.0;
  static const double _subtitleSidebarMinWidth = 100.0;
  static const double _subtitleSidebarMinRemainingPlayerWidth = 24.0;

  /// 退出横屏页时沿用最早版本的行为：立即释放方向限制并返回。
  Future<void> _returnToPortrait({bool saveExitState = true}) async {
    if (!_exitGuard.tryStart()) return;
    if (saveExitState) _explicitPlaybackExitRequested = true;
    final navigator = Navigator.of(context);
    PlaybackNavigationService.instance.clearBrowseHistoryOnExit();
    _restoreSystemUIMode();

    // Capture every context-bound dependency before the route is popped, then
    // let pause/progress persistence finish outside the visual transition.
    // dispose() joins the same memoized cleanup future as a final safeguard.
    if (saveExitState) {
      final pendingCancel = _cancelPendingPlaybackIfNeeded();
      final pendingExit = _handleExit();
      unawaited(
        (() async {
          try {
            await Future.wait<void>(<Future<void>>[pendingCancel, pendingExit]);
          } catch (error) {
            debugPrint('Saving landscape exit state failed: $error');
          }
        })(),
      );
    }

    SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    if (mounted) {
      navigator.pop<bool>(
        _controlsKey.currentState?.controlsVisible ?? _playbackChromeVisible,
      );
    }
  }

  Future<void> _forceExitPlayer() async {
    _forceExit = true;
    await _returnToPortrait();
  }

  double _getMaxResizableSidebarWidth(BuildContext context) {
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double maxWidth =
        screenWidth -
        _subtitleSidebarResizerLayoutWidth -
        _subtitleSidebarMinRemainingPlayerWidth;
    return maxWidth.clamp(_subtitleSidebarMinWidth, screenWidth);
  }

  double _clampResizableSidebarWidth(BuildContext context, double width) {
    return width.clamp(
      _subtitleSidebarMinWidth,
      _getMaxResizableSidebarWidth(context),
    );
  }

  double _getSidebarWidth(BuildContext context, SettingsService settings) {
    final effectiveSubtitleSidebarWidth = _clampResizableSidebarWidth(
      context,
      _subtitleSidebarWidthOverride ?? settings.userSubtitleSidebarWidth,
    );
    final bool canEditGhostStyle = _canUseGhostSidebarEditing(
      context,
      settings,
    );
    if (_activeSidebar == SidebarType.aiChat) {
      return AiSidebarWidth.resolve(
        MediaQuery.sizeOf(context),
        preference: _aiSidebarWidthOverride ?? settings.userAiSidebarWidth,
      );
    }
    if (_activeSidebar == SidebarType.subtitles ||
        _activeSidebar == SidebarType.subtitleEditor) {
      return effectiveSubtitleSidebarWidth;
    }
    if (_activeSidebar == SidebarType.subtitlePosition && _isGhostDragMode) {
      // Add the visible resizer lane to match the total occupied width.
      return effectiveSubtitleSidebarWidth + _subtitleSidebarResizerLayoutWidth;
    }
    if (_activeSidebar == SidebarType.subtitleStyle && canEditGhostStyle) {
      return effectiveSubtitleSidebarWidth + _subtitleSidebarResizerLayoutWidth;
    }
    final screenSize = MediaQuery.sizeOf(context);
    final screenWidth = screenSize.width;
    if (_activeSidebar == SidebarType.chapters) {
      return screenWidth < 600
          ? screenWidth * 0.78
          : (screenWidth * 0.3).clamp(300.0, 440.0);
    }
    return LandscapeSidebarLayout.functionalWidthFor(screenSize);
  }

  void _startSidebarResize(SettingsService settings, BuildContext context) {
    _cancelSidebarResizeFrame();
    setState(() {
      _sidebarResizeRevision++;
      _isResizingSidebar = true;
      _resizingAiSidebar = _activeSidebar == SidebarType.aiChat;
      if (_resizingAiSidebar) {
        _aiSidebarWidthOverride = _getSidebarWidth(context, settings);
      } else {
        _subtitleSidebarWidthOverride = _clampResizableSidebarWidth(
          context,
          _subtitleSidebarWidthOverride ?? settings.userSubtitleSidebarWidth,
        );
      }
    });
    final width = _resizingAiSidebar
        ? _aiSidebarWidthOverride!
        : _subtitleSidebarWidthOverride!;
    _sidebarResizeHaptics.begin(
      width,
      dragging: true,
      boundary: _sidebarResizeBoundary(context, width),
    );
  }

  int? _sidebarResizeBoundary(BuildContext context, double width) {
    final size = MediaQuery.sizeOf(context);
    final minimum = _resizingAiSidebar
        ? AiSidebarWidth.clamp(size, 0)
        : _subtitleSidebarMinWidth;
    final maximum = _resizingAiSidebar
        ? AiSidebarWidth.clamp(size, double.infinity)
        : _getMaxResizableSidebarWidth(context);
    return width <= minimum ? -1 : (width >= maximum ? 1 : null);
  }

  void _cancelSidebarResizeFrame() {
    final frame = _sidebarResizeFrame;
    if (frame != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(frame);
    }
    _sidebarResizeFrame = null;
  }

  void _updateSidebarResize(
    SettingsService settings,
    BuildContext context,
    bool isLeftHandedMode,
    DragUpdateDetails details,
  ) {
    if (!_isResizingSidebar) return;
    final currentWidth = _resizingAiSidebar
        ? (_aiSidebarWidthOverride ?? _getSidebarWidth(context, settings))
        : (_subtitleSidebarWidthOverride ?? settings.userSubtitleSidebarWidth);
    final nextWidth = isLeftHandedMode
        ? currentWidth + details.delta.dx
        : currentWidth - details.delta.dx;
    final clampedWidth = _resizingAiSidebar
        ? AiSidebarWidth.clamp(MediaQuery.sizeOf(context), nextWidth)
        : _clampResizableSidebarWidth(context, nextWidth);
    _sidebarResizeHaptics.update(
      clampedWidth,
      boundary: _sidebarResizeBoundary(context, clampedWidth),
    );
    if (currentWidth == clampedWidth) {
      return;
    }
    if (_resizingAiSidebar) {
      _aiSidebarWidthOverride = clampedWidth;
    } else {
      _subtitleSidebarWidthOverride = clampedWidth;
    }
    _sidebarResizeFrame ??= SchedulerBinding.instance.scheduleFrameCallback((
      _,
    ) {
      _sidebarResizeFrame = null;
      if (mounted && _isResizingSidebar) setState(() {});
    });
  }

  Future<void> _endSidebarResize(
    SettingsService settings, {
    bool cancelled = false,
  }) async {
    if (!_isResizingSidebar) return;
    _sidebarResizeHaptics.end(committed: !cancelled);
    _cancelSidebarResizeFrame();
    final revision = _sidebarResizeRevision;
    final resizingAi = _resizingAiSidebar;
    final widthToPersist = resizingAi
        ? _aiSidebarWidthOverride
        : _subtitleSidebarWidthOverride;
    if (mounted) {
      setState(() {
        _isResizingSidebar = false;
      });
    }
    final savedWidth = resizingAi
        ? settings.userAiSidebarWidth
        : settings.userSubtitleSidebarWidth;
    if (widthToPersist != null && (widthToPersist - savedWidth).abs() > 0.01) {
      if (resizingAi) {
        await settings.saveUserAiSidebarWidth(widthToPersist);
      } else {
        await settings.saveUserSubtitleSidebarWidth(widthToPersist);
      }
    }
    if (mounted && revision == _sidebarResizeRevision) {
      setState(() {
        if (resizingAi) {
          _aiSidebarWidthOverride = null;
        } else {
          _subtitleSidebarWidthOverride = null;
        }
      });
    }
    if (_activeSidebar != SidebarType.subtitles) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subtitleSidebarKey.currentState?.triggerLocateForAutoFollow();
    });
  }

  bool _isLandscapeSidebarViewportReady() {
    final screenSize = MediaQuery.maybeSizeOf(context);
    if (screenSize == null) return false;
    return isLandscapeSubtitleViewportReady(
      size: screenSize,
      isMobilePlatform: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
    );
  }

  void _requestSubtitleSidebarViewportRestore() {
    _pendingSubtitleSidebarViewportRestore = true;
    _subtitleSidebarRestoreRetries = 0;
    _tryRestoreSubtitleSidebarForCurrentViewport();
  }

  void _tryRestoreSubtitleSidebarForCurrentViewport() {
    if (!mounted ||
        !_elementActive ||
        !_pendingSubtitleSidebarViewportRestore ||
        _subtitleSidebarRestoreCallbackScheduled) {
      return;
    }
    _subtitleSidebarRestoreCallbackScheduled = true;
    // post-frame 回调只在有帧被调度时执行；播放已暂停、界面静止时没有任何
    // 东西会调度帧，只注册回调会让修复定位永远悬空。
    WidgetsBinding.instance.ensureVisualUpdate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subtitleSidebarRestoreCallbackScheduled = false;
      if (!mounted ||
          !_elementActive ||
          !_pendingSubtitleSidebarViewportRestore) {
        return;
      }
      if (ModalRoute.of(context)?.isCurrent != true ||
          !_isLandscapeSidebarViewportReady()) {
        return;
      }
      if (!_isSubtitleSidebarVisible ||
          _activeSidebar != SidebarType.subtitles ||
          !_showingSubtitleTab) {
        _pendingSubtitleSidebarViewportRestore = false;
        return;
      }
      if (_subtitles.isEmpty && _secondarySubtitles.isEmpty) return;

      final sidebar = _subtitleSidebarKey.currentState;
      if (sidebar == null) {
        _scheduleSubtitleSidebarRestoreRetry();
        return;
      }
      // Entering/restoring the route is a viewport repair. It must work while
      // paused and when automatic subtitle following is disabled.
      if (!sidebar.locateToCurrentSubtitle(ignorePointer: true)) {
        // 列表尚未挂载（旋转/转场那一帧）：保留请求并在后续帧重试，避免
        // 修复被静默丢弃后文稿停在空白状态。
        _scheduleSubtitleSidebarRestoreRetry();
        return;
      }
      _pendingSubtitleSidebarViewportRestore = false;
      _subtitleSidebarRestoreRetries = 0;
    });
  }

  void _scheduleSubtitleSidebarRestoreRetry() {
    if (_subtitleSidebarRestoreRetries >= _subtitleSidebarRestoreMaxRetries) {
      _pendingSubtitleSidebarViewportRestore = false;
      _subtitleSidebarRestoreRetries = 0;
      return;
    }
    _subtitleSidebarRestoreRetries++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _tryRestoreSubtitleSidebarForCurrentViewport();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _canShowGhostSidebarControls(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    // AI can open while the remembered subtitle sidebar preference is closed.
    // Both reading panels must enable ghost captions while they are visible.
    final hasReadingSidebar =
        _isSubtitleSidebarVisible ||
        _activeSidebar == SidebarType.subtitles ||
        _activeSidebar == SidebarType.aiChat;
    return !_isAudio && hasReadingSidebar && isLandscape;
  }

  bool _canUseGhostSidebarEditing(
    BuildContext context,
    SettingsService settings,
  ) {
    return _canShowGhostSidebarControls(context) && settings.isGhostModeEnabled;
  }

  /// Preset captions can be dragged only in landscape video ghost editing.
  /// This does not require the subtitle list sidebar to stay open.
  bool _presetMoveSurfaceAllowsGhost(BuildContext context) {
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return !_isAudio && isLandscape && !_subtitleStyleFromCompose;
  }

  bool _presetGhostMoveActive(BuildContext context, SettingsService settings) {
    return SubtitleDebugSession.instance.usesPresets &&
        _isGhostDragMode &&
        settings.isGhostModeEnabled &&
        _presetMoveSurfaceAllowsGhost(context);
  }

  /// The panel [target] stands for on this page.
  SidebarType _sidebarOf(LandscapeSidebarTarget target) {
    switch (target) {
      case LandscapeSidebarTarget.previous:
        return _sidebarHistory.previous ?? _defaultSidebar;
      case LandscapeSidebarTarget.subtitles:
        return SidebarType.subtitles;
      case LandscapeSidebarTarget.videoCompose:
        return SidebarType.videoCompose;
      case LandscapeSidebarTarget.bilibili:
        return _isBilibiliVideo ? SidebarType.bilibili : SidebarType.none;
      case LandscapeSidebarTarget.none:
        return SidebarType.none;
    }
  }

  /// The Bilibili video playing, or null for any other media.
  BilibiliPlayerVideo? get _bilibiliVideo => null;

  bool get _isBilibiliVideo => false;

  /// Desktops and tablets share one resizable reading sidebar. Phones keep
  /// their compact Bilibili overlay over the video.
  bool get _usesBilibiliSidebarTabs {
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    final size = view == null
        ? Size.zero
        : view.physicalSize / view.devicePixelRatio;
    return _isBilibiliVideo &&
        !bilibiliPanelOverlaysVideo(
          isMobilePlatform: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
          shortestSide: size.shortestSide,
        );
  }

  PortraitBilibiliTab get _landscapeBilibiliTab =>
      SettingsService().bilibiliLandscapeShowsSubtitles
      ? PortraitBilibiliTab.subtitles
      : PortraitBilibiliTab.details;

  bool get _showingSubtitleTab =>
      !_usesBilibiliSidebarTabs ||
      _landscapeBilibiliTab == PortraitBilibiliTab.subtitles;

  void _pickLandscapeBilibiliTab(PortraitBilibiliTab tab) {
    if (!_usesBilibiliSidebarTabs || _isLocked || _isResizingSidebar) return;
    unawaited(
      SettingsService().saveBilibiliLandscapeShowsSubtitles(
        tab == PortraitBilibiliTab.subtitles,
      ),
    );
    setState(() {
      _sidebarNavigationVersion++;
      _resetSidebarEditing();
      _sidebarHistory.clear();
      _showEpisodePicker = false;
      _isSubtitleSidebarVisible = true;
      _sidebarBaseOverride = SidebarType.subtitles;
      _activeSidebar = SidebarType.subtitles;
    });
    unawaited(SettingsService().saveLandscapeSubtitleSidebarVisible(true));
    _syncSidebarNavigation();
    _returnFocusToVideo();
    if (tab == PortraitBilibiliTab.subtitles) {
      _userRequestedSubtitles = true;
      unawaited(_maybeLoadSubtitlesForCurrentItem(force: true));
    }
  }

  // The docked sidebar resets per media item. Reparent only the Bilibili
  // panel so a part/collection switch keeps its list and expansion state.
  final GlobalKey _dockedBilibiliPanelKey = GlobalKey();

  /// The Bilibili panel is open and, on a phone, shown over the video.
  bool get _bilibiliPanelOverVideo =>
      _activeSidebar == SidebarType.bilibili &&
      bilibiliPanelOverlaysVideo(
        isMobilePlatform: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
        shortestSide: MediaQuery.sizeOf(context).shortestSide,
      );

  late final BilibiliPlayerPanelMemory _bilibiliPanelMemory =
      BilibiliPlayerPanelMemory.of(SettingsService());

  /// Whether the window leaves room to open the Bilibili panel by itself.
  bool get _bilibiliPanelMayAutoOpen {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    final view =
        dispatcher.implicitView ??
        (dispatcher.views.isEmpty ? null : dispatcher.views.first);
    if (view == null || view.devicePixelRatio <= 0) return false;
    final size = view.physicalSize / view.devicePixelRatio;
    return bilibiliPanelMayAutoOpen(
      windowWidth: size.width,
      panelWidth: LandscapeSidebarLayout.functionalWidthFor(size),
      isMobilePlatform: !kIsWeb && (Platform.isAndroid || Platform.isIOS),
      shortestSide: size.shortestSide,
    );
  }

  /// What the page shows when no other panel is asked for.
  LandscapeSidebarTarget get _defaultTarget => landscapeDefaultSidebar(
    subtitleSidebarRemembered: _isSubtitleSidebarVisible,
    isBilibiliVideo: _isBilibiliVideo && !_usesBilibiliSidebarTabs,
    bilibiliPanelRemembered: _bilibiliPanelMemory.remembered,
    allowAutoOpen: _bilibiliPanelMayAutoOpen,
  );

  /// The panel shown when no other one is asked for.
  SidebarType get _defaultSidebar =>
      _sidebarBaseOverride ?? _sidebarOf(_defaultTarget);

  void _resetSidebarEditing() {
    _subtitlePositions.endEditing();
    _isStyleSidebarDragMode = false;
    _isSubtitleDragMode = false;
    _isGhostDragMode = false;
    _isSubtitleSnappedX = false;
    _isSubtitleSnappedY = false;
    _isSubtitleNearCenterX = false;
    _isSubtitleNearCenterY = false;
  }

  void _syncSidebarNavigation() {
    _subtitleStyleFromCompose =
        _activeSidebar == SidebarType.subtitleStyle &&
        _sidebarHistory.contains(SidebarType.videoCompose);
    if (_activeSidebar != SidebarType.videoCompose &&
        !_sidebarHistory.contains(SidebarType.videoCompose)) {
      _clearVideoComposePreview();
    }
    if (_activeSidebar == SidebarType.subtitleStyle && _initialized) {
      final settings = Provider.of<SettingsService>(context, listen: false);
      _enableStyleSidebarDragMode(
        isGhost:
            !_subtitleStyleFromCompose &&
            _canUseGhostSidebarEditing(context, settings),
      );
    }
  }

  /// Every tool button/shortcut toggles, and every close restores its source.
  void _openSidebar(SidebarType target, {bool feedback = true}) {
    if (_activeSidebar == target) {
      _closeSidebar();
      return;
    }
    if (feedback) unawaited(AppHaptics.lightTap(SettingsService()));
    setState(() {
      _sidebarNavigationVersion++;
      _showEpisodePicker = false;
      _resetSidebarEditing();
      // Position editing is a mode, not a destination to reopen later.
      if (_activeSidebar == SidebarType.subtitlePosition) {
        _activeSidebar = _sidebarHistory.pop(fallback: _defaultSidebar);
      }
      _sidebarHistory.open(current: _activeSidebar, target: target);
      _activeSidebar = target;
    });
    _syncSidebarNavigation();
  }

  void _closeSidebar() {
    if (!mounted) return;
    unawaited(AppHaptics.lightTap(SettingsService()));
    setState(() {
      _sidebarNavigationVersion++;
      _resetSidebarEditing();
      _activeSidebar = _sidebarHistory.pop(fallback: _defaultSidebar);
    });
    _syncSidebarNavigation();
    if (_activeSidebar != SidebarType.aiChat &&
        _activeSidebar != SidebarType.subtitleEditor) {
      _returnFocusToVideo();
    }
  }

  /// The panel button or its shortcut: opens or closes the Bilibili panel
  /// and remembers that for every Bilibili video.
  void _toggleBilibiliPanel() {
    if (!_isBilibiliVideo) return;
    if (_usesBilibiliSidebarTabs) {
      final openedSidebar = !_isSidebarOpen;
      _pickLandscapeBilibiliTab(
        _activeSidebar == SidebarType.subtitles &&
                _landscapeBilibiliTab == PortraitBilibiliTab.details
            ? PortraitBilibiliTab.subtitles
            : PortraitBilibiliTab.details,
      );
      // Switching a tab in an existing reading slot is navigation. Opening
      // the whole slot from a hidden state is a temporary panel destination:
      // Back closes that destination before leaving playback.
      _bilibiliOpenedManually =
          _bilibiliOpenedManually ||
          (openedSidebar && _activeSidebar == SidebarType.subtitles);
      return;
    }
    final open = _bilibiliPanelMemory.userToggled(
      showing: _activeSidebar == SidebarType.bilibili,
    );
    if (open) {
      _sidebarBaseOverride = null;
      _bilibiliOpenedManually = true;
      _openSidebar(SidebarType.bilibili);
    } else {
      _closeBilibiliPanel();
    }
    _returnFocusToVideo();
  }

  /// The panel's own collapse button: closed, and remembered closed.
  void _collapseBilibiliPanel() {
    _bilibiliPanelMemory.userCollapsed();
    _closeBilibiliPanel();
  }

  void _closeBilibiliPanel() {
    _bilibiliOpenedManually = false;
    final fallback = _sidebarOf(
      landscapeSidebarAfterBilibiliClosed(
        subtitleSidebarRemembered: _isSubtitleSidebarVisible,
      ),
    );
    setState(() {
      _sidebarNavigationVersion++;
      _resetSidebarEditing();
      _sidebarHistory.remap(
        (panel) => panel == SidebarType.bilibili ? fallback : panel,
      );
      _activeSidebar = _sidebarHistory.pop(fallback: fallback);
      if (_activeSidebar == SidebarType.subtitles ||
          _activeSidebar == SidebarType.none) {
        _sidebarBaseOverride = _activeSidebar;
      }
    });
    _syncSidebarNavigation();
    _returnFocusToVideo();
  }

  /// Follows the room beside the docked Bilibili panel; see
  /// [LandscapeSidebarRoom].
  late final LandscapeSidebarRoom<SidebarType> _bilibiliPanelRoom;

  /// The window was resized: the docked Bilibili panel gives way to the
  /// video while it does not fit and comes back as remembered. Nothing is
  /// remembered here.
  void _followRoomForBilibiliPanel() {
    if (!mounted) return;
    if (_usesBilibiliSidebarTabs) {
      // A phone overlay can become a dock when a tablet leaves split view.
      // Restore the same reading destination through any tools above it.
      if (_activeSidebar == SidebarType.bilibili ||
          _sidebarHistory.contains(SidebarType.bilibili)) {
        setState(() {
          if (_activeSidebar == SidebarType.bilibili) {
            _activeSidebar = SidebarType.subtitles;
          }
          _sidebarHistory.remap(
            (panel) =>
                panel == SidebarType.bilibili ? SidebarType.subtitles : panel,
          );
          _sidebarHistory.discardCurrent(_activeSidebar);
          _isSubtitleSidebarVisible = true;
          _sidebarBaseOverride = SidebarType.subtitles;
          _bilibiliOpenedManually = false;
        });
      }
      return;
    }
    final fittedBefore = _bilibiliPanelRoom.fits;
    final fits = _bilibiliPanelMayAutoOpen;
    if (fits == fittedBefore) return;
    SidebarType defaultFor(bool fits) =>
        _sidebarBaseOverride ??
        _sidebarOf(
          landscapeDefaultSidebar(
            subtitleSidebarRemembered: _isSubtitleSidebarVisible,
            isBilibiliVideo: _isBilibiliVideo,
            bilibiliPanelRemembered: _bilibiliPanelMemory.remembered,
            allowAutoOpen: fits,
          ),
        );
    final before = defaultFor(fittedBefore);
    final after = defaultFor(fits);
    final next = _bilibiliPanelRoom.follow(
      fits: fits,
      shown: _activeSidebar,
      previous: _sidebarHistory.previous ?? SidebarType.none,
      bilibili: SidebarType.bilibili,
      none: SidebarType.none,
      defaultFor: defaultFor,
    );
    final panelChanged = next != null && next.shown != _activeSidebar;
    setState(() {
      if (next != null) _activeSidebar = next.shown;
      _sidebarHistory.remap((panel) {
        if (!fits && panel == SidebarType.bilibili) return after;
        if (fits && panel == before) return after;
        return panel;
      });
      _sidebarHistory.discardCurrent(_activeSidebar);
      if (panelChanged) _bilibiliOpenedManually = false;
    });
    if (panelChanged) _returnFocusToVideo();
  }

  /// Keeps the Bilibili panel in step after the video changed on this page.
  void _followVideoChangeForBilibiliPanel(bool showingDefaultBefore) {
    _sidebarNavigationVersion++;
    _resetSidebarEditing();
    _sidebarHistory.clear();
    _subtitleStyleFromCompose = false;
    _clearVideoComposePreview();
    final next = landscapeSidebarOnVideoChange(
      showingBilibili: _activeSidebar == SidebarType.bilibili,
      showingDefaultBefore: showingDefaultBefore,
      isBilibiliVideo: _isBilibiliVideo,
      newDefault: _defaultTarget,
    );
    if (next != null) _activeSidebar = _sidebarOf(next);
    if (_usesBilibiliSidebarTabs && _activeSidebar == SidebarType.bilibili) {
      _activeSidebar = SidebarType.subtitles;
    }
    if (_activeSidebar == SidebarType.subtitlePosition) {
      _activeSidebar = _defaultSidebar;
    }
    if (_activeSidebar != SidebarType.none &&
        _activeSidebar != SidebarType.subtitles &&
        _activeSidebar != SidebarType.bilibili) {
      _sidebarHistory.open(current: _defaultSidebar, target: _activeSidebar);
    }
    if (!_isBilibiliVideo) _bilibiliOpenedManually = false;
  }

  void _returnFocusToVideo() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _videoFocusNode.canRequestFocus) {
        _videoFocusNode.requestFocus();
      }
    });
  }

  bool get _canUseVideoTransformGestures {
    return _initialized &&
        (_settingsService ?? SettingsService()).enableVideoTransformGestures &&
        !_isAudio &&
        !_isLocked &&
        !_isLongPressing &&
        !_videoGestureSession.blocksTransforms &&
        !_isSubtitleDragMode &&
        !_isGhostDragMode &&
        !_isStyleSidebarDragMode;
  }

  /// The loading overlay is fully opaque. Keep the texture mounted whenever
  /// the assigned controller already has a decoded picture, even if a later
  /// init pass briefly cleared [_initialized].
  bool get _hasDecodedVideoTexture {
    if (!_controllerAssigned) return false;
    try {
      return _controller.value.isInitialized && !_controller.value.hasError;
    } catch (_) {
      return false;
    }
  }

  /// The page may still hold a controller the service has already released.
  /// Mounting that id throws in the Android player view and becomes a white
  /// [ErrorWidget] in release.
  bool get _pageControllerIsCurrent {
    if (!_controllerAssigned) return false;
    return identical(MediaPlaybackService().controller, _controller);
  }

  bool _musicCoverHidesVideoSurface = false;

  void _syncMusicCoverVideoSurface(MediaPlaybackService service) {
    final hides = service.musicCoverOwnsVideoSurface;
    if (hides == _musicCoverHidesVideoSurface) return;
    setState(() => _musicCoverHidesVideoSurface = hides);
  }

  /// Never mount [VideoPlayer] until the assigned controller is still the
  /// service's live player. Keeping [_initialized] alone caused
  /// LateInitializationError on Bilibili re-entry when a service notification
  /// cleared the assignment before _initVideo ran.
  ///
  /// The landscape music cover borrows this same output while its card is
  /// showing video. Leave the controller running and only drop the view.
  bool get _shouldKeepVideoSurface => shouldKeepPlaybackVideoSurface(
    controllerIsCurrent: _pageControllerIsCurrent,
    initialized: _initialized,
    hasDecodedTexture: _hasDecodedVideoTexture,
    musicCoverOwnsSurface: _musicCoverHidesVideoSurface,
  );

  bool get _isCurrentBilibiliOnlineStream => false;

  /// Poster over an empty texture until the first decoded frame (or a
  /// background→foreground track re-enable) arrives. Instantly removed once
  /// the video track is on the audio clock — no spinner and no fade.
  Widget _buildVisibleVideoFrameCover() {
    return ListenableBuilder(
      listenable: MediaPlaybackService(),
      builder: (context, _) {
        final playback = MediaPlaybackService();
        if (_isCurrentBilibiliOnlineStream || playback.onlineStartup != null) {
          return BilibiliStartupPoster(
            startup: playback.currentItem?.id == _currentItem?.id
                ? playback.onlineStartup
                : null,
            thumbnailPath: _currentItem?.thumbnailPath,
            covered: playback.isCoveringUntilVisibleVideoFrame,
            onRetry: () => unawaited(playback.retryOnlineStartup()),
          );
        }
        if (!MediaPlaybackService().isCoveringUntilVisibleVideoFrame) {
          return const SizedBox.shrink();
        }
        final path = _currentItem?.thumbnailPath;
        if (path != null && path.isNotEmpty && File(path).existsSync()) {
          return IgnorePointer(
            child: Image.file(
              File(path),
              // Contain: a 16:10 cover cropped with BoxFit.cover looks bigger
              // than the video that replaces it. This widget is already the
              // video's rectangle, so a matching image still fills it.
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: Color(0xFF141414)),
            ),
          );
        }
        return const IgnorePointer(child: ColoredBox(color: Color(0xFF141414)));
      },
    );
  }

  Widget _buildVideoTexture() {
    if (_videoSurfaceController != _controller ||
        _videoSurfaceItemId != _currentItem?.id) {
      _videoSurfaceController = _controller;
      _videoSurfaceItemId = _currentItem?.id;
      _videoSurfaceWidget = ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            VideoPlayer(_controller, key: _videoTextureKey),
            _buildVisibleVideoFrameCover(),
          ],
        ),
      );
    }
    return _videoSurfaceWidget!;
  }

  bool get _hasCustomVideoTransform {
    return (_videoUserScale - 1.0).abs() > 0.001 ||
        _videoUserRotation.abs() > 0.001 ||
        _videoUserOffsetNormalized.distance > 0.001;
  }

  void _setScreenLock(bool locked) {
    if (_isLocked == locked) return;
    _cancelVideoTransformAnimation();
    setState(() {
      _isLocked = locked;
      if (locked) {
        _activeVideoTransformPointers.clear();
        _isVideoTransformGestureActive = false;
      }
    });
  }

  bool _resolvedVideoMirrorH(SettingsService settings) {
    return _currentItem?.isVideoMirroredH ?? _fallbackVideoMirroredH;
  }

  bool _resolvedVideoMirrorV(SettingsService settings) {
    return _currentItem?.isVideoMirroredV ?? _fallbackVideoMirroredV;
  }

  Offset _denormalizeVideoOffset(Offset normalizedOffset, Size viewportSize) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return Offset.zero;
    }
    return Offset(
      normalizedOffset.dx * (viewportSize.width / 2),
      normalizedOffset.dy * (viewportSize.height / 2),
    );
  }

  Offset _normalizeOffsetInViewport(Offset pixelOffset, Size viewportSize) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return Offset.zero;
    }
    return Offset(
      pixelOffset.dx / (viewportSize.width / 2),
      pixelOffset.dy / (viewportSize.height / 2),
    );
  }

  Size _computeContainedVideoSize(Size viewportSize, double aspectRatio) {
    if (viewportSize.width <= 0 || viewportSize.height <= 0) {
      return Size.zero;
    }
    final double safeAspectRatio = aspectRatio > 0 ? aspectRatio : 16 / 9;
    final double viewportAspectRatio = viewportSize.width / viewportSize.height;
    double width = viewportSize.width;
    double height = viewportSize.height;

    if (safeAspectRatio > viewportAspectRatio) {
      height = width / safeAspectRatio;
    } else {
      width = height * safeAspectRatio;
    }

    return Size(width, height);
  }

  List<Rect> _playbackControlAvoidanceRects({
    required BuildContext context,
    required Size playerSize,
    required PlayerControlMetrics metrics,
    required double clearance,
  }) {
    final double baseControlsTop =
        playerSize.height -
        metrics.bottomControlsHeight(hasChapterButton: false) -
        clearance;
    final rects = <Rect>[
      Rect.fromLTRB(0, baseControlsTop, playerSize.width, playerSize.height),
    ];

    final chapters = _currentItem?.chapters ?? const <MediaChapter>[];
    final Duration position = _controllerAssigned
        ? _controller.value.position
        : Duration.zero;
    final TextDirection textDirection = Directionality.of(context);
    final TextStyle progressPillTextStyle = DefaultTextStyle.of(context).style
        .merge(
          TextStyle(
            color: Colors.white,
            fontSize: metrics.progressPillFontSize,
            fontWeight: FontWeight.w600,
          ),
        );
    final double trackInset = math.max(
      metrics.overlayRadius,
      metrics.thumbRadius,
    );
    final double sliderWidth = math
        .max(0, playerSize.width - (metrics.bottomHorizontalPadding * 2))
        .toDouble();
    final double maxButtonWidth = math
        .max(
          0,
          (sliderWidth - (trackInset * 2)) * metrics.chapterButtonWidthFactor,
        )
        .toDouble();
    final double buttonTop =
        playerSize.height -
        metrics.bottomPadding -
        metrics.bottomRowHeight -
        metrics.progressHitHeight -
        metrics.chapterButtonHeight -
        clearance;
    final double buttonBottom =
        playerSize.height -
        metrics.bottomPadding -
        metrics.bottomRowHeight -
        metrics.progressHitHeight;

    if (chapters.isNotEmpty) {
      final MediaChapter chapter =
          MediaChapter.atPosition(chapters, position) ?? chapters.first;
      final double buttonWidth = metrics.measureProgressPillWidth(
        labels: [chapter.title],
        textStyle: progressPillTextStyle,
        textDirection: textDirection,
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxWidth: maxButtonWidth,
      );
      final double buttonLeft = metrics.bottomHorizontalPadding + trackInset;
      rects.add(
        Rect.fromLTRB(
          buttonLeft,
          buttonTop,
          buttonLeft + buttonWidth,
          buttonBottom,
        ),
      );
    }

    final playbackService = MediaPlaybackService();
    if (playbackService.isCurrentItemBilibiliStream &&
        playbackService.streamQualities.isNotEmpty) {
      final qualityLabels = playbackService.streamQualities
          .map((quality) => quality.label)
          .toList(growable: false);
      final double buttonWidth = metrics.measureProgressPillWidth(
        labels: qualityLabels.isEmpty ? const ['清晰度'] : qualityLabels,
        textStyle: progressPillTextStyle,
        textDirection: textDirection,
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
        maxWidth: maxButtonWidth,
      );
      final double buttonRight =
          playerSize.width - metrics.bottomHorizontalPadding - trackInset;
      rects.add(
        Rect.fromLTRB(
          buttonRight - buttonWidth,
          buttonTop,
          buttonRight,
          buttonBottom,
        ),
      );
    }
    return rects;
  }

  double _normalizeVideoRotation(double radians) {
    final double fullTurn = math.pi * 2;
    double normalized = radians % fullTurn;
    if (normalized > math.pi) normalized -= fullTurn;
    if (normalized < -math.pi) normalized += fullTurn;
    return normalized;
  }

  double _applyRotationSnap(double radians) {
    final double quarterTurn = math.pi / 2;
    final double target = (radians / quarterTurn).round() * quarterTurn;
    if ((radians - target).abs() <= _videoRotationSnapThreshold) {
      return _normalizeVideoRotation(target);
    }
    return _normalizeVideoRotation(radians);
  }

  Offset _rotateVector(Offset vector, double radians) {
    final double cosValue = math.cos(radians);
    final double sinValue = math.sin(radians);
    return Offset(
      vector.dx * cosValue - vector.dy * sinValue,
      vector.dx * sinValue + vector.dy * cosValue,
    );
  }

  double _angleDeltaBetween(double startAngle, double currentAngle) {
    return _normalizeVideoRotation(currentAngle - startAngle);
  }

  double _movementDirectionCosine(Offset first, Offset second) {
    final double firstDistance = first.distance;
    final double secondDistance = second.distance;
    if (firstDistance <= 0.0001 || secondDistance <= 0.0001) {
      return 1.0;
    }
    final double dotProduct = first.dx * second.dx + first.dy * second.dy;
    final num clampedCosine = (dotProduct / (firstDistance * secondDistance))
        .clamp(-1.0, 1.0);
    return clampedCosine.toDouble();
  }

  Offset _contentVectorForFocalPoint({
    required Offset focalPoint,
    required Rect viewportRect,
    required double scale,
    required double rotation,
    required Offset normalizedOffset,
  }) {
    final Offset pixelOffset = _denormalizeVideoOffset(
      normalizedOffset,
      viewportRect.size,
    );
    final double safeScale = scale
        .clamp(_minVideoUserScale, _maxVideoUserScale)
        .toDouble();
    final Offset centeredVector =
        focalPoint - viewportRect.center - pixelOffset;
    return _rotateVector(centeredVector / safeScale, -rotation);
  }

  Offset _normalizedOffsetForContentVector({
    required Offset contentVector,
    required Offset focalPoint,
    required Rect viewportRect,
    required double scale,
    required double rotation,
  }) {
    final double safeScale = scale
        .clamp(_minVideoUserScale, _maxVideoUserScale)
        .toDouble();
    final Offset transformedVector = _rotateVector(
      contentVector * safeScale,
      rotation,
    );
    final Offset pixelOffset =
        focalPoint - viewportRect.center - transformedVector;
    return _normalizeOffsetInViewport(pixelOffset, viewportRect.size);
  }

  double _filteredVideoGestureRotationDelta({
    required double rawRotationDelta,
    required double startDistance,
    required double distanceDelta,
    required double focalTranslationDistance,
    required double pointerDirectionCosine,
  }) {
    final double deltaMagnitude = rawRotationDelta.abs();
    if (deltaMagnitude <= 0.0001) {
      return 0.0;
    }
    final double rotationArcDistance = (startDistance * deltaMagnitude) / 2;
    final bool likelyPanGesture =
        pointerDirectionCosine > 0.82 &&
        focalTranslationDistance > 10.0 &&
        focalTranslationDistance > rotationArcDistance * 1.2;
    if (likelyPanGesture) {
      return 0.0;
    }
    final bool likelyScaleGesture =
        pointerDirectionCosine < -0.35 &&
        distanceDelta > 8.0 &&
        distanceDelta > rotationArcDistance * 1.35 &&
        focalTranslationDistance < distanceDelta * 0.75;
    if (likelyScaleGesture &&
        deltaMagnitude <= _videoRotationScaleBiasThreshold) {
      return 0.0;
    }
    final double rotationDeadZone = likelyScaleGesture
        ? _videoRotationScaleBiasThreshold
        : (pointerDirectionCosine > 0.6
              ? _videoRotationPanBiasThreshold
              : _videoRotationIntentThreshold);
    if (deltaMagnitude <= rotationDeadZone) {
      return 0.0;
    }
    final double preservedMagnitude = deltaMagnitude - rotationDeadZone;
    return rawRotationDelta.isNegative
        ? -preservedMagnitude
        : preservedMagnitude;
  }

  Matrix4 _buildVideoTransformMatrix(
    Size viewportSize,
    SettingsService settings,
  ) {
    final Offset pixelOffset = _denormalizeVideoOffset(
      _videoUserOffsetNormalized,
      viewportSize,
    );
    final Matrix4 transform = Matrix4.identity()
      ..setEntry(0, 3, pixelOffset.dx)
      ..setEntry(1, 3, pixelOffset.dy)
      ..multiply(Matrix4.rotationZ(_videoUserRotation))
      ..multiply(Matrix4.diagonal3Values(_videoUserScale, _videoUserScale, 1.0))
      ..multiply(
        Matrix4.diagonal3Values(
          _resolvedVideoMirrorH(settings) ? -1.0 : 1.0,
          _resolvedVideoMirrorV(settings) ? -1.0 : 1.0,
          1.0,
        ),
      );
    return transform;
  }

  Widget _buildVideoBoundSubtitleOverlay({
    required Size videoSize,
    required Alignment alignment,
    required SubtitleStyle style,
    bool isDragging = false,
    bool isGestureOnly = false,
    bool isVisualOnly = false,
    bool animateAlignment = false,
    ValueListenable<SubtitleDisplayState>? displayNotifier,
    ValueListenable<bool>? playbackControlsVisibility,
    double? playbackControlsTop,
    List<Rect> Function()? playbackControlRects,
    bool avoidPlaybackControls = false,
    bool presetPositionOverride = false,
  }) {
    if (videoSize.width <= 0 || videoSize.height <= 0) {
      return const SizedBox.shrink();
    }

    Widget overlay = SizedBox(
      width: videoSize.width,
      height: videoSize.height,
      child: SubtitleDisplayLayer(
        notifier: displayNotifier ?? subtitleDisplayNotifier,
        alignment: alignment,
        style: style,
        isDragging: isDragging,
        isGestureOnly: isGestureOnly,
        isVisualOnly: isVisualOnly,
        animateAlignment: animateAlignment,
        playbackControlsVisibility: playbackControlsVisibility,
        playbackControlsTop: playbackControlsTop,
        playbackControlRects: playbackControlRects,
        avoidPlaybackControls: avoidPlaybackControls,
        positionController: _subtitlePositions,
        positionInteractive: isDragging,
        showPositionFrame: isDragging,
        presetPositionOverride: presetPositionOverride,
        onPositionPointerClaimed: _claimSubtitlePointer,
      ),
    );

    return Positioned.fill(
      child: ClipRect(child: Center(child: overlay)),
    );
  }

  Widget _buildDanmakuContent(SettingsService settings, double playerHeight) {
    final item = _currentItem;
    final path = item?.danmakuPath;
    if (item == null ||
        !item.isBilibiliExported ||
        path == null ||
        path.isEmpty ||
        !settings.showBilibiliDanmaku ||
        !File(path).existsSync()) {
      return const SizedBox.shrink();
    }
    final position = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    ).danmakuPosition;
    final overlay = DanmakuOverlay(
      key: ValueKey('$path:$_danmakuRevision'),
      path: path,
      position: position,
      displayArea: settings.bilibiliDanmakuDisplayArea,
      density: settings.danmakuDensityFor(DanmakuPresentationMode.landscape),
      opacity: settings.bilibiliDanmakuOpacity,
      fontScale: settings.bilibiliDanmakuFontScale,
      useReadableFontDefaults: settings.bilibiliDanmakuReadableFontDefaults,
      // Locked playback already advances the position clock; compensate here.
      speed: settings.effectiveBilibiliDanmakuSpeed,
      fontFamily: settings.bilibiliDanmakuFontFamily,
      fontWeight: settings.bilibiliDanmakuFontWeight,
      outlineType: settings.bilibiliDanmakuOutlineType,
      outlineScale: settings.bilibiliDanmakuOutlineScale,
      shadowScale: settings.bilibiliDanmakuShadowScale,
      letterSpacing: settings.bilibiliDanmakuLetterSpacing,
      playerHeight: playerHeight,
    );
    return overlay;
  }

  Widget _buildVideoBoundDanmakuOverlay({
    required Size videoSize,
    required SettingsService settings,
    required Widget content,
  }) {
    return Positioned.fill(
      child: ClipRect(
        child: settings.bilibiliDanmakuOnlyInVideoArea
            ? Center(
                child: SizedBox(
                  width: videoSize.width,
                  height: videoSize.height,
                  child: content,
                ),
              )
            : content,
      ),
    );
  }

  Widget _buildFreeSubtitleOverlay({
    required Alignment alignment,
    required SubtitleStyle style,
    bool isDragging = false,
    bool isGestureOnly = false,
    bool isVisualOnly = false,
    bool animateAlignment = false,
    bool isGhost = false,
    Size? fullPageSize,
    ValueListenable<SubtitleDisplayState>? displayNotifier,
    ValueListenable<bool>? playbackControlsVisibility,
    double? playbackControlsTop,
    List<Rect> Function()? playbackControlRects,
    bool avoidPlaybackControls = false,
    bool presetPositionOverride = false,
  }) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ClipRect(
            child: SizedBox.expand(
              child: SubtitleDisplayLayer(
                isGhostMode: isGhost,
                notifier: displayNotifier ?? subtitleDisplayNotifier,
                alignment: alignment,
                style: style,
                fullPageSize: fullPageSize,
                isDragging: isDragging,
                isGestureOnly: isGestureOnly,
                isVisualOnly: isVisualOnly,
                animateAlignment: animateAlignment && !isDragging,
                playbackControlsVisibility: playbackControlsVisibility,
                playbackControlsTop: playbackControlsTop,
                playbackControlRects: playbackControlRects,
                avoidPlaybackControls: avoidPlaybackControls,
                positionController: _subtitlePositions,
                positionInteractive: isDragging,
                showPositionFrame: isDragging,
                presetPositionOverride: presetPositionOverride,
                onPositionPointerClaimed: _claimSubtitlePointer,
              ),
            ),
          );
        },
      ),
    );
  }

  void _setVideoTransformValues({
    required double scale,
    required double rotation,
    required Offset normalizedOffset,
  }) {
    _videoUserScale = scale.clamp(_minVideoUserScale, _maxVideoUserScale);
    _videoUserRotation = _normalizeVideoRotation(rotation);
    _videoUserOffsetNormalized = normalizedOffset;
  }

  void _cancelVideoTransformAnimation() {
    if (_videoTransformAnimationController.isAnimating) {
      _videoTransformAnimationController.stop();
    }
  }

  void _animateVideoTransformTo({
    required double scale,
    required double rotation,
    required Offset normalizedOffset,
    Duration duration = const Duration(milliseconds: 180),
    Curve curve = Curves.easeOutCubic,
  }) {
    _cancelVideoTransformAnimation();
    final Animation<double> progress = CurvedAnimation(
      parent: _videoTransformAnimationController,
      curve: curve,
    );
    _videoScaleAnimation = Tween<double>(
      begin: _videoUserScale,
      end: scale.clamp(_minVideoUserScale, _maxVideoUserScale),
    ).animate(progress);
    _videoRotationAnimation = Tween<double>(
      begin: _videoUserRotation,
      end: _normalizeVideoRotation(rotation),
    ).animate(progress);
    _videoOffsetAnimation = Tween<Offset>(
      begin: _videoUserOffsetNormalized,
      end: normalizedOffset,
    ).animate(progress);
    _videoTransformAnimationController.duration = duration;
    _videoTransformAnimationController.forward(from: 0);
  }

  /// 实验性功能：五连击标题进入 Apple Music 风格播放页面
  Future<void> _navigateToMusicPlayer() async {
    if (_isOpeningMusicPlayer) return;
    _isOpeningMusicPlayer = true;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    try {
      await prepareMusicPlayerArtwork(context, _currentItem?.thumbnailPath);
      if (!mounted) return;
      await Navigator.of(context).push(
        _currentItem?.sourceRef?.podcast != null &&
                PodcastPlaybackHooks.musicRoute != null
            ? PodcastPlaybackHooks.musicRoute!(_currentItem!)
            : buildMusicPlayerRoute<void>(
                builder: (_) => MusicPlayerScreen(
                  coverImagePath: _currentItem?.thumbnailPath,
                  title: _currentItem?.title ?? '',
                  restoreSystemUiOnExit: false,
                  onPlayPause: () {
                    if (service.isPlaying) {
                      service.pause();
                    } else {
                      service.resume();
                    }
                  },
                  onPrevious: service.playPrevious,
                  onNext: service.playNext,
                ),
              ),
      );
    } finally {
      _isOpeningMusicPlayer = false;
    }
    // 从音乐播放页切回视频播放页完成：将字幕文稿自动定位到当前字幕，
    // 同时修复切回时字幕文稿显示区偶发空白的问题。
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subtitleSidebarKey.currentState?.locateToCurrentSubtitle(
        ignorePointer: true,
      );
    });
    // 音乐播放页返回可能与播放暂停同时发生：没有帧被调度时 post-frame 回调
    // 不会执行，显式确保下一帧发生，修复定位才能落地。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _resetVideoUserTransform({bool animated = true}) {
    if (animated) {
      _animateVideoTransformTo(
        scale: 1.0,
        rotation: 0.0,
        normalizedOffset: Offset.zero,
      );
      return;
    }
    _cancelVideoTransformAnimation();
    setState(() {
      _setVideoTransformValues(
        scale: 1.0,
        rotation: 0.0,
        normalizedOffset: Offset.zero,
      );
    });
  }

  List<MapEntry<int, Offset>> _activeVideoTransformPair() {
    final List<MapEntry<int, Offset>> entries =
        _activeVideoTransformPointers.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    return entries.take(2).toList();
  }

  double _distanceBetween(Offset a, Offset b) {
    return (a - b).distance;
  }

  double _angleBetween(Offset a, Offset b) {
    final Offset vector = b - a;
    return math.atan2(vector.dy, vector.dx);
  }

  void _rebaseVideoTransformGesture() {
    final List<MapEntry<int, Offset>> pair = _activeVideoTransformPair();
    if (pair.length < 2) return;
    _gestureStartPointerA = pair[0].value;
    _gestureStartPointerB = pair[1].value;
    _gestureStartFocalPoint = Offset.lerp(pair[0].value, pair[1].value, 0.5)!;
    _gestureCurrentFocalPoint = _gestureStartFocalPoint;
    _gestureStartDistance = _distanceBetween(
      pair[0].value,
      pair[1].value,
    ).clamp(1.0, double.infinity);
    _gestureStartAngle = _angleBetween(pair[0].value, pair[1].value);
    _gestureBaseScale = _videoUserScale;
    _gestureBaseRotation = _videoUserRotation;
    _gestureBaseOffsetNormalized = _videoUserOffsetNormalized;
    _gestureBaseContentVector = _contentVectorForFocalPoint(
      focalPoint: _gestureStartFocalPoint,
      viewportRect: _lastVideoViewportRect,
      scale: _gestureBaseScale,
      rotation: _gestureBaseRotation,
      normalizedOffset: _gestureBaseOffsetNormalized,
    );
  }

  bool _isWithinVideoViewport(Offset localPosition) {
    return _lastVideoViewportRect.contains(localPosition);
  }

  void _beginVideoTransformGesture() {
    if (!_canUseVideoTransformGestures) return;
    final List<MapEntry<int, Offset>> pair = _activeVideoTransformPair();
    if (pair.length < 2) return;
    if (!_isWithinVideoViewport(pair[0].value) &&
        !_isWithinVideoViewport(pair[1].value)) {
      return;
    }
    _cancelVideoTransformAnimation();
    _rebaseVideoTransformGesture();
    if (!_isVideoTransformGestureActive) {
      setState(() {
        _isVideoTransformGestureActive = true;
      });
    }
  }

  void _updateVideoTransformGesture() {
    if (!_canUseVideoTransformGestures || !_isVideoTransformGestureActive) {
      return;
    }
    final List<MapEntry<int, Offset>> pair = _activeVideoTransformPair();
    if (pair.length < 2 || _lastVideoViewportRect.isEmpty) return;

    final Offset focalPoint = Offset.lerp(pair[0].value, pair[1].value, 0.5)!;
    final double distance = _distanceBetween(pair[0].value, pair[1].value);
    final double angle = _angleBetween(pair[0].value, pair[1].value);
    final double distanceDelta = (distance - _gestureStartDistance).abs();
    final double nextScale =
        (_gestureBaseScale *
                (distance / _gestureStartDistance).clamp(
                  0.0001,
                  double.infinity,
                ))
            .clamp(_minVideoUserScale, _maxVideoUserScale)
            .toDouble();
    final Offset pointerMoveA = pair[0].value - _gestureStartPointerA;
    final Offset pointerMoveB = pair[1].value - _gestureStartPointerB;
    final double pointerDirectionCosine = _movementDirectionCosine(
      pointerMoveA,
      pointerMoveB,
    );
    final double effectiveRotationDelta = _filteredVideoGestureRotationDelta(
      rawRotationDelta: _angleDeltaBetween(_gestureStartAngle, angle),
      startDistance: _gestureStartDistance,
      distanceDelta: distanceDelta,
      focalTranslationDistance: (focalPoint - _gestureStartFocalPoint).distance,
      pointerDirectionCosine: pointerDirectionCosine,
    );
    final double nextRotation = _gestureBaseRotation + effectiveRotationDelta;
    final Offset normalizedOffset = _normalizedOffsetForContentVector(
      contentVector: _gestureBaseContentVector,
      focalPoint: focalPoint,
      viewportRect: _lastVideoViewportRect,
      scale: nextScale,
      rotation: nextRotation,
    );

    setState(() {
      _gestureCurrentFocalPoint = focalPoint;
      _setVideoTransformValues(
        scale: nextScale,
        rotation: nextRotation,
        normalizedOffset: normalizedOffset,
      );
    });
  }

  void _endVideoTransformGesture() {
    if (!_isVideoTransformGestureActive) return;
    final double snappedRotation = _applyRotationSnap(_videoUserRotation);
    final Offset snapFocalPoint =
        _lastVideoViewportRect.contains(_gestureCurrentFocalPoint)
        ? _gestureCurrentFocalPoint
        : _lastVideoViewportRect.center;
    final Offset snapContentVector = _contentVectorForFocalPoint(
      focalPoint: snapFocalPoint,
      viewportRect: _lastVideoViewportRect,
      scale: _videoUserScale,
      rotation: _videoUserRotation,
      normalizedOffset: _videoUserOffsetNormalized,
    );
    final Offset snappedOffset = _normalizedOffsetForContentVector(
      contentVector: snapContentVector,
      focalPoint: snapFocalPoint,
      viewportRect: _lastVideoViewportRect,
      scale: _videoUserScale,
      rotation: snappedRotation,
    );
    setState(() {
      _isVideoTransformGestureActive = false;
    });
    if ((snappedRotation - _videoUserRotation).abs() > 0.0001) {
      _animateVideoTransformTo(
        scale: _videoUserScale,
        rotation: snappedRotation,
        normalizedOffset: snappedOffset,
      );
    }
  }

  void _handleVideoTransformPointerDown(PointerDownEvent event) {
    // Keep an independent view of every pointer in this player. This is also
    // updated while transform gestures are locked so that a finger left on
    // screen after long-press ends cannot start a new transform session.
    _videoGestureSession.pointerDown(event.pointer);
    if (SubtitleDragPointerOwner.owns(event.pointer) ||
        SubtitleDragPointerOwner.claimsGlobal(event.position)) {
      return;
    }
    if (!_canUseVideoTransformGestures ||
        !_isWithinVideoViewport(event.localPosition)) {
      return;
    }
    _activeVideoTransformPointers[event.pointer] = event.localPosition;
    if (_activeVideoTransformPointers.length == 2) {
      _beginVideoTransformGesture();
    } else if (_isVideoTransformGestureActive &&
        _activeVideoTransformPointers.length > 2) {
      _rebaseVideoTransformGesture();
    }
  }

  void _handleVideoTransformPointerMove(PointerMoveEvent event) {
    if (SubtitleDragPointerOwner.owns(event.pointer)) {
      _activeVideoTransformPointers.remove(event.pointer);
      return;
    }
    if (!_canUseVideoTransformGestures) {
      _activeVideoTransformPointers.clear();
      if (_isVideoTransformGestureActive) {
        setState(() {
          _isVideoTransformGestureActive = false;
        });
      }
      return;
    }
    if (!_activeVideoTransformPointers.containsKey(event.pointer)) return;
    _activeVideoTransformPointers[event.pointer] = event.localPosition;
    if (_activeVideoTransformPointers.length >= 2 &&
        !_isVideoTransformGestureActive) {
      _beginVideoTransformGesture();
    }
    _updateVideoTransformGesture();
  }

  void _handleVideoTransformPointerEnd(int pointer) {
    _videoGestureSession.pointerUp(pointer);
    final bool wasTracking =
        _activeVideoTransformPointers.remove(pointer) != null;

    if (_videoGestureSession.blocksTransforms) {
      // The long-press lock used to return here and leave the pinch flag set.
      // That flag is what disables taps and swipe-seek, so a finger sequence
      // that crossed both gestures could not get the controls back.
      if (_isVideoTransformGestureActive &&
          _activeVideoTransformPointers.length < 2) {
        _endVideoTransformGesture();
      }
      return;
    }

    if (!wasTracking) return;
    if (_activeVideoTransformPointers.length >= 2) {
      _rebaseVideoTransformGesture();
      return;
    }
    _endVideoTransformGesture();
  }

  // Subtitles
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = []; // New: Secondary subtitle list
  List<String> _currentSubtitlePaths = []; // Track loaded paths
  int _subtitleRevision = -1;
  String _currentSubtitleText = "";
  String? _currentSecondaryText; // New: Secondary text state
  Uint8List? _currentSubtitleImage;
  int _currentSubtitleIndex = -1;
  int _currentSecondarySubtitleIndex = -1;
  List<int> _currentSubtitleIndices = [];
  List<int> _currentSecondarySubtitleIndices = [];
  List<SubtitleOverlayEntry> _currentSubtitleEntries = [];
  final Map<int, Uint8List?> _currentSubtitleImages = <int, Uint8List?>{};

  /// 字幕显示状态通知器 — 字幕更新时仅重建字幕叠加层，不触发整页 setState。
  final ValueNotifier<SubtitleDisplayState> subtitleDisplayNotifier =
      ValueNotifier<SubtitleDisplayState>(SubtitleDisplayState.empty);
  final VideoComposePreviewController _videoComposePreviewController =
      VideoComposePreviewController();
  bool _videoComposePreviewActive = false;
  int _subtitleImageRequestId = 0;
  SubtitleTimelineResolver _subtitleTimeline = SubtitleTimelineResolver(
    const <SubtitleItem>[],
  );
  SubtitleTimelineResolver _secondarySubtitleTimeline =
      SubtitleTimelineResolver(const <SubtitleItem>[]);
  Timer? _subtitleSeekTimer;
  bool _isParsingSubtitles = false;
  bool _userRequestedSubtitles = false;

  // Subtitle Positioning Mode
  bool _isSubtitleDragMode = false;
  String? _subtitlePositionError;
  bool _isGhostDragMode = false;
  final SubtitlePositionController _subtitlePositions =
      SubtitlePositionController();
  bool _isSubtitleSnappedX = false;
  bool _isSubtitleSnappedY = false;
  bool _isSubtitleNearCenterX = false;
  bool _isSubtitleNearCenterY = false;
  bool _isStyleSidebarDragMode = false;
  bool _showEpisodePicker = false; // Add state for episode picker

  // Temporary user transform state for landscape video surface
  static const double _minVideoUserScale = 0.02;
  static const double _maxVideoUserScale = 1000.0;
  static const double _videoRotationSnapThreshold = 8 * math.pi / 180;
  static const double _videoRotationIntentThreshold = 10 * math.pi / 180;
  static const double _videoRotationPanBiasThreshold = 14 * math.pi / 180;
  static const double _videoRotationScaleBiasThreshold = 18 * math.pi / 180;
  double _videoUserScale = 1.0;
  double _videoUserRotation = 0.0;
  Offset _videoUserOffsetNormalized = Offset.zero;
  bool _fallbackVideoMirroredH = false;
  bool _fallbackVideoMirroredV = false;
  bool _isVideoTransformGestureActive = false;
  bool _ambientScrubbing = false;
  final _ambientSeekHold = ValueNotifier<bool>(false);
  Timer? _ambientHoldTimer;
  Rect _lastVideoViewportRect = Rect.zero;
  final Map<int, Offset> _activeVideoTransformPointers = <int, Offset>{};
  // Once touch long-press wins a gesture session, transform gestures stay
  // suppressed until every finger from that session has left the screen.
  // Merely clearing this when the primary long-press finger lifts would let a
  // remaining second finger accidentally zoom or rotate the video.
  final VideoGestureSessionGate _videoGestureSession =
      VideoGestureSessionGate();
  Offset _gestureStartFocalPoint = Offset.zero;
  Offset _gestureCurrentFocalPoint = Offset.zero;
  Offset _gestureStartPointerA = Offset.zero;
  Offset _gestureStartPointerB = Offset.zero;
  double _gestureStartDistance = 0.0;
  double _gestureStartAngle = 0.0;
  double _gestureBaseScale = 1.0;
  double _gestureBaseRotation = 0.0;
  Offset _gestureBaseOffsetNormalized = Offset.zero;
  Offset _gestureBaseContentVector = Offset.zero;
  late final AnimationController _videoTransformAnimationController;
  Animation<double>? _videoScaleAnimation;
  Animation<double>? _videoRotationAnimation;
  Animation<Offset>? _videoOffsetAnimation;
  final ValueNotifier<double> _keyboardInsetBottom = ValueNotifier<double>(0);

  // Repair state
  bool _isRepairing = false;
  double _repairProgress = 0.0;
  bool _repairAvailable = false;
  String? _repairFailureDetails;

  // Audio state
  bool _isAudio = false;
  String? _fatalErrorMessage;

  // Embedded subtitle loading state
  bool _isLoadingEmbeddedSubtitle = false;
  String? _embeddedSubtitleError;
  String? _embeddedSubtitleErrorMediaKey;
  String? _autoEmbeddedAttemptedForItemId;
  bool _embeddedSubtitleDetected = false;
  bool _suppressAutoEmbeddedForCurrentItem = false;

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'pgs' ||
        codec == 'pgs_subtitle' ||
        codec == 'vobsub' ||
        codec == 'xsub';
  }

  TranscriptionManager? _transcriptionManager;
  OcrSubtitleManager? _ocrSubtitleManager;
  VideoItem? _currentItem;
  SettingsService? _settingsService;
  late SettingsService _exitSettings;
  late MediaPlaybackService _exitPlaybackService;
  late LibraryService _exitLibraryService;
  MediaPlaybackService? _subtitlePlaybackService;
  bool? _lastShowSubtitles;
  Duration? _lastSubtitleOffset;
  bool? _lastSplitSubtitleByLine;
  bool? _lastVideoContinuousSubtitle;
  bool? _lastAudioContinuousSubtitle;
  bool? _lastGhostModeEnabled;
  bool? _lastSkipPortraitPlayer;
  int _subtitleRefreshToken = 0;
  int _postInitWorkToken = 0;
  final _routeWork = RouteTransitionWork();

  @override
  void initState() {
    super.initState();
    _sidebarMotion = PlayerSidebarMotion(vsync: this);
    _bindSubtitlePositions();
    _playbackChromeVisible =
        VideoControlsOverlay.takeEntryVisibility(widget.videoItem?.id) ??
        widget.initialShowControls;
    _playbackControlsVisibility = ValueNotifier(_playbackChromeVisible);
    _videoTransformAnimationController = AnimationController(vsync: this)
      ..addListener(() {
        final Animation<double>? scaleAnimation = _videoScaleAnimation;
        final Animation<double>? rotationAnimation = _videoRotationAnimation;
        final Animation<Offset>? offsetAnimation = _videoOffsetAnimation;
        if (!mounted ||
            scaleAnimation == null ||
            rotationAnimation == null ||
            offsetAnimation == null) {
          return;
        }
        setState(() {
          _setVideoTransformValues(
            scale: scaleAnimation.value,
            rotation: rotationAnimation.value,
            normalizedOffset: offsetAnimation.value,
          );
        });
      });
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_handlePlaybackEarlyKeyEvent);
    _keyboardInsetBottom.value = _readBottomViewInset();
    _currentItem = widget.videoItem;
    _isAudio = widget.videoItem?.type == MediaType.audio;
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _enterImmersiveMode();
    final settings = Provider.of<SettingsService>(context, listen: false);
    _isSubtitleSidebarVisible = settings.isLandscapeSubtitleSidebarVisible;
    _activeSidebar = _defaultSidebar;
    _bilibiliPanelRoom = LandscapeSidebarRoom<SidebarType>(
      fits: _bilibiliPanelMayAutoOpen,
    );
    _routeWork.schedule('platform-prompts', () {
      if (!mounted) return;
      if (Platform.isLinux) {
        unawaited(LinuxAudioDevice.maybeShowNoAudioDeviceHint());
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_initVideo());
      if (_videoFocusNode.canRequestFocus) {
        _videoFocusNode.requestFocus();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _elementActive) {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        playbackService.addListener(_onPlaybackServiceChange);
        _subtitlePlaybackService = playbackService;
        playbackService.positionNotifier.addListener(
          _onSubtitlePositionChanged,
        );
        // Re-sync subtitles from the service to catch any subtitle changes
        // that occurred between _initVideo and listener registration.
        // This fixes the race condition where the portrait page finishes
        // loading subtitles (and calls setSubtitleState → notifyListeners)
        // after _initVideo already read the old state but before this
        // listener was registered, causing the notification to be missed.
        _syncSubtitlesFromService(playbackService);
        _onPlaybackServiceChange();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = Provider.of<SettingsService>(context, listen: false);
      _settingsService = settings;
      _lastShowSubtitles = settings.showSubtitles;
      _lastSubtitleOffset = settings.subtitleOffset;
      _lastSplitSubtitleByLine = settings.splitSubtitleByLine;
      _lastVideoContinuousSubtitle = settings.videoContinuousSubtitle;
      _lastAudioContinuousSubtitle = settings.audioContinuousSubtitle;
      _lastGhostModeEnabled = settings.isGhostModeEnabled;
      _lastSkipPortraitPlayer = settings.skipPortraitPlayer;
      settings.addListener(_onSettingsChanged);
      _onSettingsChanged();
    });

    // Keep this request pending until route transition/orientation, controller,
    // subtitle data, and the sidebar's first layout have all settled.
    _requestSubtitleSidebarViewportRestore();
  }

  @override
  void didUpdateWidget(VideoPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deferPlaybackUntilCurrent &&
        !widget.deferPlaybackUntilCurrent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _onPlaybackServiceChange();
        unawaited(_initVideo());
      });
    }
  }


  void _onSettingsChanged() {
    final settings = _settingsService;
    if (settings == null) return;

    if (!settings.enableVideoTransformGestures &&
        (_videoUserScale != 1.0 ||
            _videoUserRotation != 0.0 ||
            _videoUserOffsetNormalized != Offset.zero ||
            _isVideoTransformGestureActive ||
            _activeVideoTransformPointers.isNotEmpty ||
            _videoTransformAnimationController.isAnimating)) {
      _activeVideoTransformPointers.clear();
      _isVideoTransformGestureActive = false;
      _resetVideoUserTransform(animated: false);
    }

    // 「跳过竖屏播放页」需独立于字幕缓存比对，在字幕无关的设置变更中
    // 也能即时响应（off→on 边沿触发一次）。
    _handleSkipPortraitPlayerChanged(settings.skipPortraitPlayer);

    final bool showSubtitlesBecameTrue =
        (_lastShowSubtitles == false || _lastShowSubtitles == null) &&
        settings.showSubtitles;

    final bool changed =
        _lastShowSubtitles != settings.showSubtitles ||
        _lastSubtitleOffset != settings.subtitleOffset ||
        _lastSplitSubtitleByLine != settings.splitSubtitleByLine ||
        _lastVideoContinuousSubtitle != settings.videoContinuousSubtitle ||
        _lastAudioContinuousSubtitle != settings.audioContinuousSubtitle;

    final bool ghostModeChanged =
        _lastGhostModeEnabled != settings.isGhostModeEnabled;

    if (!changed && !ghostModeChanged) return;

    _lastShowSubtitles = settings.showSubtitles;
    _lastSubtitleOffset = settings.subtitleOffset;
    _lastSplitSubtitleByLine = settings.splitSubtitleByLine;
    _lastVideoContinuousSubtitle = settings.videoContinuousSubtitle;
    _lastAudioContinuousSubtitle = settings.audioContinuousSubtitle;
    _lastGhostModeEnabled = settings.isGhostModeEnabled;

    if (ghostModeChanged &&
        (_isSubtitleDragMode ||
            _isGhostDragMode ||
            _isStyleSidebarDragMode ||
            _activeSidebar == SidebarType.subtitlePosition)) {
      final shouldGhost = _canUseGhostSidebarEditing(context, settings);
      _subtitlePositions.seal();
      _subtitlePositions.beginEditing(_subtitleTarget(ghost: shouldGhost));
      setState(() {
        _isGhostDragMode = shouldGhost;
        _isSubtitleDragMode = !shouldGhost;
        _isSubtitleSnappedX = false;
        _isSubtitleSnappedY = false;
        _isSubtitleNearCenterX = false;
        _isSubtitleNearCenterY = false;
      });
    }

    if (_initialized) {
      _updateSubtitle();
    }

    if (showSubtitlesBecameTrue) {
      unawaited(_maybeLoadSubtitlesForCurrentItem(force: true));
    }
  }

  /// 「跳过竖屏播放页」在横屏页内被打开时，移除正下方的竖屏播放路由，
  /// 使退出横屏后直接回到媒体库而不是竖屏页。
  ///
  /// 仅在 off→on 边沿触发一次。竖屏页在跳转横屏前已将控制器所有权让出
  /// （_isControllerOwner == false），移除其路由只会触发状态同步，不会
  /// 释放仍在播放的控制器。
  void _handleSkipPortraitPlayerChanged(bool enabled) {
    final bool? previous = _lastSkipPortraitPlayer;
    _lastSkipPortraitPlayer = enabled;
    if (previous != false || !enabled) return;
    if (!mounted) return;

    final navigator = Navigator.of(context, rootNavigator: true);
    final portraitRoutes = PlaybackNavigationService.instance.observer.routes
        .where(
          (route) =>
              route.settings.name ==
              PlaybackNavigationService.portraitRouteName,
        )
        .toList(growable: false);
    for (final route in portraitRoutes) {
      PlaybackNavigationService.instance.removeRouteSuppressed(
        navigator,
        route,
      );
    }
  }

  void _applyItemSubtitlePreference(VideoItem item, {bool force = false}) {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    if (force || item.showFloatingSubtitles != settings.showSubtitles) {
      item.showFloatingSubtitles = settings.showSubtitles;
    }
  }

  void _setFloatingSubtitles(bool value) {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    settings.saveShowSubtitles(value);
    final currentItem = _currentItem;
    if (currentItem != null) {
      currentItem.showFloatingSubtitles = value;
    }
  }

  Future<void> _updateCurrentVideoDisplayTransform({
    bool? isMirroredH,
    bool? isMirroredV,
  }) async {
    final currentItem = _currentItem;
    final bool nextMirroredH =
        isMirroredH ?? currentItem?.isVideoMirroredH ?? _fallbackVideoMirroredH;
    final bool nextMirroredV =
        isMirroredV ?? currentItem?.isVideoMirroredV ?? _fallbackVideoMirroredV;

    setState(() {
      if (currentItem != null) {
        currentItem.isVideoMirroredH = nextMirroredH;
        currentItem.isVideoMirroredV = nextMirroredV;
      } else {
        _fallbackVideoMirroredH = nextMirroredH;
        _fallbackVideoMirroredV = nextMirroredV;
      }
    });

    if (currentItem == null) {
      return;
    }

    final library = Provider.of<LibraryService>(context, listen: false);
    await library.updateVideoDisplayTransform(
      currentItem.id,
      isMirroredH: nextMirroredH,
      isMirroredV: nextMirroredV,
    );
  }

  bool _shouldLoadSubtitlesNow(SettingsService settings) {
    if (settings.showSubtitles) return true;
    if (_userRequestedSubtitles) return true;
    return false;
  }

  String? _resolveFirstAssociatedSubtitlePath(VideoItem item) {
    final associated = item.downloadAssociatedSubtitles;
    if (associated.isEmpty) return null;
    for (final path in associated.values) {
      if (path.isEmpty) continue;
      final normalized = p.normalize(path);
      if (File(normalized).existsSync()) {
        return normalized;
      }
    }
    return null;
  }

  Future<void> _persistPrimarySubtitlePathIfNeeded(
    String subtitlePath, {
    String? secondarySubtitlePath,
  }) async {
    final currentItem = _currentItem;
    if (currentItem == null) return;
    final normalizedPrimary = p.normalize(subtitlePath);
    final currentPrimary = currentItem.subtitlePath == null
        ? null
        : p.normalize(currentItem.subtitlePath!);
    if (currentPrimary == normalizedPrimary) return;
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);
      await library.updateVideoSubtitles(
        currentItem.id,
        normalizedPrimary,
        settings.autoCacheSubtitles,
        secondarySubtitlePath: secondarySubtitlePath,
        isSecondaryCached: settings.autoCacheSubtitles,
      );
      if (mounted) {
        final updated = library.getVideo(currentItem.id);
        if (updated != null) {
          setState(() {
            _currentItem = updated;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _maybeLoadSubtitlesForCurrentItem({bool force = false}) async {
    if (!mounted) return;
    final currentItem = _currentItem;
    if (currentItem == null) return;
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    if (_isParsingSubtitles && !force) return;
    if (_currentSubtitlePaths.isNotEmpty) return;

    if (currentItem.subtitlePath != null) {
      final List<String> paths = <String>[currentItem.subtitlePath!];
      if (currentItem.secondarySubtitlePath != null) {
        paths.add(currentItem.secondarySubtitlePath!);
      }
      await _loadSubtitles(
        paths,
        autoEnableSubtitles: true,
        userInitiated: false,
      );
      return;
    }
    final associatedPath = _resolveFirstAssociatedSubtitlePath(currentItem);
    if (!force &&
        !currentItem.blockAutoAssociatedSubtitleSelection &&
        associatedPath != null) {
      await _persistPrimarySubtitlePathIfNeeded(
        associatedPath,
        secondarySubtitlePath: currentItem.secondarySubtitlePath,
      );
      if (!mounted) return;
      final refreshedItem = _currentItem ?? currentItem;
      final primaryPath = refreshedItem.subtitlePath ?? associatedPath;
      final List<String> paths = <String>[primaryPath];
      final secondaryPath = refreshedItem.secondarySubtitlePath;
      if (secondaryPath != null &&
          secondaryPath.isNotEmpty &&
          secondaryPath != primaryPath) {
        paths.add(secondaryPath);
      }
      await _loadSubtitles(
        paths,
        autoEnableSubtitles: true,
        userInitiated: false,
      );
      return;
    }

    // 首次进入播放页：媒体既没有已绑定字幕也没有下载关联字幕时，自动把
    // 同目录"最匹配"（自动级别、排序第一）的字幕作为主字幕加载并持久化。
    if (!currentItem.blockAutoAssociatedSubtitleSelection &&
        !isCloudDriveMedia(
          source: currentItem.sourceRef,
          path: currentItem.path,
        ) &&
        !currentItem.path.startsWith('bilibili://')) {
      try {
        final entries = await const SubtitleDiscoveryService()
            .scanVideoDirectory(
              videoPath: currentItem.path,
              videoDurationMs: currentItem.durationMs > 0
                  ? currentItem.durationMs
                  : null,
            );
        final autoPaths = entries
            .where((entry) => entry.isAuto)
            .take(2)
            .map((entry) => entry.path)
            .toList();
        if (autoPaths.isNotEmpty && mounted) {
          final secondaryHint = autoPaths.length > 1
              ? autoPaths[1]
              : currentItem.secondarySubtitlePath;
          await _persistPrimarySubtitlePathIfNeeded(
            autoPaths.first,
            secondarySubtitlePath: secondaryHint,
          );
          if (!mounted) return;
          final refreshedItem = _currentItem ?? currentItem;
          final primaryPath = refreshedItem.subtitlePath ?? autoPaths.first;
          final List<String> paths = <String>[primaryPath];
          final secondaryPath = refreshedItem.secondarySubtitlePath;
          if (secondaryPath != null &&
              secondaryPath.isNotEmpty &&
              secondaryPath != primaryPath) {
            paths.add(secondaryPath);
          }
          await _loadSubtitles(
            paths,
            autoEnableSubtitles: true,
            userInitiated: false,
          );
          return;
        }
      } catch (_) {
        // 扫描失败不影响正常播放。
      }
    }

    if (!force && !_shouldLoadSubtitlesNow(settings)) return;
    _maybeAutoLoadEmbeddedSubtitle();
  }

  void _triggerSubtitleRefreshBurst() {
    _requestSubtitleSidebarViewportRestore();
    final int token = ++_subtitleRefreshToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && token == _subtitleRefreshToken) {
        _updateSubtitle();
      }
    });
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted &&
          token == _subtitleRefreshToken &&
          _initialized &&
          _currentSubtitleText.isEmpty &&
          _currentSecondaryText == null) {
        _updateSubtitle();
      }
    });
  }

  void _scheduleDeferredPostInitWork(VideoItem? item) {
    if (item == null) return;
    final int token = ++_postInitWorkToken;
    _routeWork.schedule('post-init', () {
      if (!mounted ||
          token != _postInitWorkToken ||
          _currentItem?.id != item.id) {
        return;
      }
      unawaited(
        _scheduleDanmakuAutoUpdate(item, token).catchError((
          Object error,
          StackTrace stack,
        ) {
          debugPrint('Danmaku auto-update was not scheduled: $error\n$stack');
        }),
      );
      _checkAndLoadAiSubtitle(item);
      unawaited(_maybeLoadSubtitlesForCurrentItem());
    });
  }

  Future<void> _scheduleDanmakuAutoUpdate(VideoItem item, int token) async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (!settings.bilibiliDanmakuAutoUpdate || !item.isBilibiliExported) {
      return;
    }
    final downloads = Provider.of<BilibiliDownloadService>(
      context,
      listen: false,
    );
    final library = Provider.of<LibraryService>(context, listen: false);
    return BilibiliDanmakuAutoUpdate.instance.scheduleForPlayback(
      item: item,
      surface: this,
      playbackToken: token,
      enabled: settings.bilibiliDanmakuAutoUpdate,
      downloads: downloads,
      library: library,
      playingCachedMedia: () =>
          context
              .read<MediaPlaybackService>()
              .selectedStreamQuality
              ?.isLocalMaterialized ==
          true,
      stillCurrent: () =>
          mounted && token == _postInitWorkToken && _currentItem?.id == item.id,
      position: () {
        try {
          return Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          ).positionNotifier.value;
        } catch (_) {
          return Duration.zero;
        }
      },
      playing: () {
        try {
          return Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          ).isPlaying;
        } catch (_) {
          return true;
        }
      },
      reloadVisual: () {
        if (!mounted || _currentItem?.id != item.id) return;
        setState(() => _danmakuRevision++);
      },
    );
  }

  void _applyDeferredDanmakuReload() {
    final item = _currentItem;
    if (item == null) return;
    final autoUpdate = BilibiliDanmakuAutoUpdate.instance;
    if (!autoUpdate.hasPendingVisual(item.id)) return;
    final Duration position;
    final bool playing;
    try {
      final playback = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      position = playback.positionNotifier.value;
      playing = playback.isPlaying;
    } catch (_) {
      return;
    }
    if (!autoUpdate.consumePendingVisual(
      videoId: item.id,
      position: position,
      playing: playing,
    )) {
      return;
    }
    setState(() => _danmakuRevision++);
  }

  void _bindControllerListener() {
    try {
      _controller.removeListener(_videoListener);
    } catch (_) {}
    _controller.addListener(_videoListener);
  }

  bool _tryAdoptBilibiliQualityHandoff(MediaPlaybackService service) {
    final replacement = service.controller;
    // Same-item controller replacement (quality, local materialize, reopen)
    // must not drop through to the generic loading branch. That branch covers
    // the already-decoded picture with a black overlay even though audio is
    // still running.
    if (replacement == null ||
        service.currentItem?.id != _currentItem?.id ||
        !service.canMountControllerFor(
          _currentItem!.id,
          controller: replacement,
        ) ||
        !_controllerAssigned ||
        identical(_controller, replacement) ||
        !replacement.value.isInitialized) {
      return false;
    }

    final previousController = _controller;
    try {
      previousController.removeListener(_videoListener);
    } catch (_) {}

    // The replacement texture is already decoded and belongs to the same
    // Bilibili item. Keep the page initialized for the entire widget update so
    // it never renders the generic loading branch between qualities.
    setState(() {
      _controller = replacement;
      _controllerAssigned = true;
      _isControllerOwner = false;
      _isSourceMissing = false;
      _initialized = true;
      _isPlaying = service.isPlaying;
    });
    _bindControllerListener();
    _syncSubtitlesFromService(service);
    return true;
  }

  void _showMissingSource(VideoItem item) {
    if (_isSourceMissing) return;

    VideoPlayerController? previousController;
    final bool disposePrevious = _controllerAssigned && _isControllerOwner;
    if (_controllerAssigned) {
      previousController = _controller;
      try {
        previousController.removeListener(_videoListener);
      } catch (_) {}
    }

    _controllerAssigned = false;
    _isControllerOwner = false;

    if (disposePrevious && previousController != null) {
      unawaited(previousController.dispose());
    }

    if (!mounted) return;
    setState(() {
      _currentItem = item;
      _isAudio = item.type == MediaType.audio;
      _isSourceMissing = true;
      _initialized = false;
      _isPlaying = false;
      _fatalErrorMessage = null;
    });
  }

  void _onPlaybackServiceChange() {
    if (!mounted) return;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    if (widget.deferPlaybackUntilCurrent &&
        service.currentItem?.id != widget.videoItem?.id) {
      return;
    }
    _syncMusicCoverVideoSurface(service);
    if (_isCurrentBilibiliOnlineStream &&
        service.state == PlaybackState.loading &&
        _fatalErrorMessage != null &&
        service.currentItem?.id == _currentItem?.id) {
      setState(() => _fatalErrorMessage = null);
    }
    // Subtitle downloads finish independently of controller preparation. A
    // controller hand-off below may return without another service event.
    _syncSubtitlesFromService(service);

    // Debug Log
    debugPrint(
      "VideoPlayerScreen: _onPlaybackServiceChange. Service Item: ${service.currentItem?.title}, State: ${service.state}",
    );

    if (service.currentItem?.id == _currentItem?.id &&
        service.isSourceMissing) {
      _showMissingSource(service.currentItem!);
      _syncSubtitlesFromService(service);
      return;
    }
    if (service.currentItem?.id == _currentItem?.id &&
        service.state == PlaybackState.loading &&
        _isSourceMissing) {
      setState(() => _isSourceMissing = false);
    }

    if (service.currentItem?.id == _currentItem?.id &&
        service.state == PlaybackState.error &&
        _fatalErrorMessage == null) {
      final cloud = isCloudDriveMedia(
        source: service.currentItem?.sourceRef,
        path: service.currentItem?.path ?? '',
      );
      _setFatalError(
        service.onlineStartup?.failure ??
            (cloud
                ? (service.cloudDriveNotice ?? '暂时无法播放这个网盘视频')
                : '媒体加载失败，请重试'),
      );
      return;
    }

    if (_tryAdoptBilibiliQualityHandoff(service)) return;

    // 如果服务中的 currentItem 发生变化，且不是当前播放的项
    if (service.currentItem != null &&
        (_currentItem == null || service.currentItem!.id != _currentItem!.id)) {
      debugPrint(
        "VideoPlayerScreen: Detected video change. New: ${service.currentItem!.title}",
      );

      // 先移除旧控制器的监听器，防止状态冲突
      VideoPlayerController? ownedControllerToDispose;
      if (_controllerAssigned) {
        try {
          _controller.removeListener(_videoListener);
        } catch (_) {}
        if (_isControllerOwner) {
          ownedControllerToDispose = _controller;
        }
      }

      final showingDefaultBefore = _activeSidebar == _sidebarOf(_defaultTarget);
      setState(() {
        _currentItem = service.currentItem;
        _followVideoChangeForBilibiliPanel(showingDefaultBefore);
        _isSourceMissing = false;
        _initialized = false;
        _isPlaying = false; // Reset play state until init
        _fatalErrorMessage = null;
        _repairAvailable = false;
        _repairFailureDetails = null;
        _subtitles = [];
        _secondarySubtitles = [];
        _currentSubtitlePaths = [];
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleImage = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
        subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
        _autoEmbeddedAttemptedForItemId = null;
        _suppressAutoEmbeddedForCurrentItem = false;
        _isParsingSubtitles = false;
        _embeddedSubtitleDetected = false;
        _userRequestedSubtitles = false;
        _rebuildSubtitleIndex();
        // 重置控制器相关状态，让 _initVideo 重新设置
        _controllerAssigned = false;
        _isControllerOwner = false;
      });

      if (ownedControllerToDispose != null) {
        unawaited(ownedControllerToDispose.dispose());
      }

      _syncSubtitlesFromService(service);
      _applyItemSubtitlePreference(service.currentItem!, force: true);

      // 直接调用 _initVideo 来处理控制器的初始化和同步
      // 避免在这里直接设置 _controller，让 _initVideo 统一处理
      _initVideo();
    } else if (_holdsStalePageController(service)) {
      // stop() nulls the current item after releasing the player. A same-id
      // check never matches that, so the page would keep the disposed view.
      _detachStalePageController();
      final itemId = _currentItem?.id;
      if (itemId != null &&
          service.currentItem?.id == itemId &&
          (service.state == PlaybackState.loading ||
              service.canMountControllerFor(itemId))) {
        _initVideo();
      }
      return;
    } else if (service.currentItem?.id == _currentItem?.id &&
        service.canMountControllerFor(_currentItem!.id) &&
        (!_initialized ||
            !_controllerAssigned ||
            !identical(_controller, service.controller))) {
      debugPrint(
        "VideoPlayerScreen: Service ready for current video. Re-initializing.",
      );
      if (_controllerAssigned && !identical(_controller, service.controller)) {
        final previousController = _controller;
        final shouldDisposePrevious = _isControllerOwner;
        try {
          previousController.removeListener(_videoListener);
        } catch (_) {}
        // Swap in place. Setting _initialized false here unmounts VideoPlayer
        // and covers a ready Bilibili stream with the loading overlay.
        setState(() {
          _controllerAssigned = false;
          _isControllerOwner = false;
        });
        if (shouldDisposePrevious) {
          unawaited(previousController.dispose());
        }
      }
      // ID unchanged; service became mountable again -> retry init.
      _initVideo();
    } else if (service.currentItem?.id == _currentItem?.id) {
      _syncSubtitlesFromService(service);
    }
  }

  bool _holdsStalePageController(MediaPlaybackService service) {
    return _controllerAssigned && !identical(_controller, service.controller);
  }

  void _detachStalePageController() {
    if (!_controllerAssigned) return;
    try {
      _controller.removeListener(_videoListener);
    } catch (_) {}
    final previous = _controller;
    final shouldDispose = _isControllerOwner;
    setState(() {
      _controllerAssigned = false;
      _isControllerOwner = false;
      _initialized = false;
    });
    if (shouldDispose) {
      unawaited(previous.dispose());
    }
  }

  /// Sync subtitle state from [MediaPlaybackService] to local state if the
  /// service's subtitle data differs from the local copy. This is called both
  /// from [_onPlaybackServiceChange] (for live updates) and from the post-frame
  /// callback in [initState] (to catch any subtitle changes that occurred
  /// between [_initVideo] and listener registration — e.g. when the portrait
  /// page finishes loading subtitles after the landscape page is already
  /// created but before the listener is registered).
  void _syncSubtitlesFromService(MediaPlaybackService service) {
    if (!mounted) return;
    if (service.currentItem?.id != _currentItem?.id) return;

    if (_subtitleRevision == service.subtitleRevision) return;

    if (service.subtitleWasAppend &&
        isSubtitleAppend(_subtitles, service.subtitles)) {
      final secondaryAppended =
          _secondarySubtitles.isEmpty ||
          isSubtitleAppend(_secondarySubtitles, service.secondarySubtitles);
      setState(() {
        _subtitleRevision = service.subtitleRevision;
        _subtitles = service.subtitles;
        _secondarySubtitles = service.secondarySubtitles;
        _currentSubtitlePaths = service.subtitlePaths;
        _subtitleTimeline.append(_subtitles);
        if (secondaryAppended) {
          _secondarySubtitleTimeline.append(_secondarySubtitles);
        } else {
          _secondarySubtitleTimeline = SubtitleTimelineResolver(
            _secondarySubtitles,
          );
        }
      });
      _updateSubtitle();
      return;
    }

    setState(() {
      _subtitleRevision = service.subtitleRevision;
      _subtitles = service.subtitles;
      _secondarySubtitles = service.secondarySubtitles;
      _currentSubtitlePaths = List<String>.from(service.subtitlePaths);
      _currentSubtitleText = "";
      _currentSecondaryText = null;
      _currentSubtitleImage = null;
      _currentSubtitleIndex = -1;
      _currentSecondarySubtitleIndex = -1;
      _currentSubtitleIndices = [];
      _currentSecondarySubtitleIndices = [];
      _currentSubtitleEntries = [];
      _currentSubtitleImages.clear();
      subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
    });
    _rebuildSubtitleIndex();
    _requestSubtitleSidebarViewportRestore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateSubtitle();
    });
  }

  void _setFatalError(String message) {
    if (!mounted) return;
    setState(() {
      _fatalErrorMessage = message;
      _initialized = false;
      _isPlaying = false;
    });
  }

  void _retryFailedPlayback() {
    final item = _currentItem;
    if (item == null) return;
    final service = context.read<MediaPlaybackService>();
    if (service.currentItem?.id != item.id) return;
    setState(() {
      _fatalErrorMessage = null;
      _repairAvailable = false;
      _repairFailureDetails = null;
    });
    unawaited(
      service.play(
        item,
        startPosition: service.position,
        autoPlay: service.desiredPlaying,
        forceRecreate: true,
        bilibiliQualityId: service.selectedStreamQuality?.id,
        cloudDriveQualityId: service.selectedCloudDriveQualityId,
      ),
    );
  }

  void _maybeAutoLoadEmbeddedSubtitle() {
    if (isCloudDriveMedia(
      source: _currentItem?.sourceRef,
      path: _currentItem?.path ?? widget.videoFile?.path ?? '',
    )) {
      return;
    }
    final currentId = _currentItem?.id ?? widget.videoFile?.path;
    if (currentId == null) return;
    if (_currentItem?.blockAutoAssociatedSubtitleSelection ?? false) return;
    if (_currentItem?.prefersManagedAssociatedSubtitles ?? false) return;
    if (_currentItem?.hasAttemptedAutoEmbeddedSubtitleLoad ?? false) return;
    if (_suppressAutoEmbeddedForCurrentItem) return;
    if (_autoEmbeddedAttemptedForItemId == currentId) return;
    if (_currentItem?.subtitlePath != null) return;
    if (_currentSubtitlePaths.isNotEmpty) return;
    if (_subtitles.isNotEmpty || _secondarySubtitles.isNotEmpty) return;
    try {
      final service = Provider.of<MediaPlaybackService>(context, listen: false);
      if (service.subtitlePaths.isNotEmpty ||
          service.subtitles.isNotEmpty ||
          service.secondarySubtitles.isNotEmpty) {
        return;
      }
    } catch (_) {}

    final currentItem = _currentItem;
    if (currentItem != null) {
      currentItem.hasAttemptedAutoEmbeddedSubtitleLoad = true;
      _persistAutoEmbeddedAttemptedFlag(currentItem.id);
    }
    _autoEmbeddedAttemptedForItemId = currentId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _checkAndLoadEmbeddedSubtitle();
    });
  }

  Future<void> _persistAutoEmbeddedAttemptedFlag(String videoId) async {
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      await library.markAutoEmbeddedSubtitleLoadAttempted(videoId);
      if (!mounted) return;
      final refreshed = library.getVideo(videoId);
      if (refreshed != null) {
        setState(() {
          _currentItem = refreshed;
        });
      }
    } catch (_) {}
  }

  Future<void> _handleExit() => _exitCleanupFuture ??= _handleExitOnce();

  Future<void> _handleExitOnce() async {
    try {
      final settings = _exitSettings;
      final playbackService = _exitPlaybackService;
      final libraryService = _exitLibraryService;
      final itemId = _currentItem?.id;
      final exitController = _controllerAssigned ? _controller : null;
      final exitControllerOwner = _isControllerOwner;
      final shouldSkipAutoPause = widget.skipAutoPauseOnExit && !_forceExit;
      final sidebarVisible = _isSubtitleSidebarVisible;
      final suppressRouteCleanup =
          PlaybackNavigationService.instance.suppressAutoPauseOnRouteCleanup;

      // The value is applied immediately. Notifying here rebuilds the player
      // on the same turn as the exit zoom is held, which is the stall before
      // the transition. The next landscape entry reads the field directly.
      await settings.saveLandscapeSubtitleSidebarVisible(
        sidebarVisible,
        notify: false,
      );
      final shouldAutoPause =
          PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
            autoPauseOnExit: settings.autoPauseOnExit && !shouldSkipAutoPause,
            explicitExit: _explicitPlaybackExitRequested,
            suppressRouteCleanup: suppressRouteCleanup,
            transportPlaying: playbackService.isTransportPlaying,
          );
      if (exitController == null) {
        if (itemId != null) {
          if (shouldAutoPause && playbackService.currentItem?.id == itemId) {
            await playbackService.pause(expectedItemId: itemId, notify: false);
          }
          await playbackService.persistCurrentProgress(expectedItemId: itemId);
        }
        return;
      }
      if (itemId == null) return;

      bool serviceOwnsExitSession() =>
          playbackService.currentItem?.id == itemId &&
          identical(playbackService.controller, exitController);

      // A service-owned controller that no longer matches belongs to an old
      // route. The service has already handed off to another media item, so
      // this route must not pause, sync, or persist through global state.
      if (!exitControllerOwner && !serviceOwnsExitSession()) return;

      final shouldAutoPauseSession =
          PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
            autoPauseOnExit: settings.autoPauseOnExit && !shouldSkipAutoPause,
            explicitExit: _explicitPlaybackExitRequested,
            suppressRouteCleanup: suppressRouteCleanup,
            transportPlaying: serviceOwnsExitSession()
                ? playbackService.isTransportPlaying
                : exitController.value.isPlaying,
          );
      if (shouldAutoPauseSession && serviceOwnsExitSession()) {
        await playbackService.pause(
          expectedItemId: itemId,
          expectedController: exitController,
          notify: false,
        );
      } else if (shouldAutoPauseSession) {
        await exitController.pause();
      }

      if (!exitControllerOwner) {
        playbackService.updatePlaybackStateFromController(
          expectedItemId: itemId,
          expectedController: exitController,
          notify: false,
        );
      }
      await _saveProgressForSession(
        itemId: itemId,
        controller: exitController,
        controllerOwner: exitControllerOwner,
        playbackService: playbackService,
        libraryService: libraryService,
      );
    } catch (e) {
      debugPrint("Exit sync error: $e");
    }
  }

  @override
  void dispose() {
    _sidebarMotion.dispose();
    _sidebarResizeHaptics.reset();
    _routeWork.dispose();
    _cancelSidebarResizeFrame();
    _sidebarResizeHovered.dispose();
    if (_isLongPressing) {
      _isLongPressing = false;
      _videoGestureSession.endLongPress();
      final playbackService = _longPressPlaybackService;
      _longPressPlaybackService = null;
      if (playbackService != null) {
        unawaited(playbackService.endTemporaryPlaybackSpeed());
      }
    }
    FocusManager.instance.removeEarlyKeyEventHandler(
      _handlePlaybackEarlyKeyEvent,
    );
    // Try to sync one last time (fire and forget)
    unawaited(_handleExit());
    _exitPlaybackService.setPlaybackPageVisible(this, false);
    if (_routeObserverSubscribed) {
      AppToast.routeObserver.unsubscribe(this);
    }

    _transcriptionManager?.removeListener(_onTranscriptionUpdate);
    _ocrSubtitleManager?.removeListener(_onOcrSubtitleUpdate);
    _subtitlePlaybackService?.removeListener(_onPlaybackServiceChange);
    _settingsService?.removeListener(_onSettingsChanged);
    _subtitlePlaybackService?.positionNotifier.removeListener(
      _onSubtitlePositionChanged,
    );
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    _restoreSystemUIMode();

    _selectionFocusNode.dispose();
    _videoFocusNode.dispose();
    _playbackPageFocusNode.dispose();
    _subtitlePositions.endEditing();
    _subtitlePositions.dispose();
    subtitleDisplayNotifier.dispose();
    _playbackControlsVisibility.dispose();
    _videoComposePreviewController.dispose();
    _subtitleSeekTimer?.cancel();
    _ambientHoldTimer?.cancel();
    _ambientSeekHold.dispose();
    _videoTransformAnimationController.dispose();
    _keyboardInsetBottom.dispose();
    WidgetsBinding.instance.removeObserver(this);

    if (_controllerAssigned) {
      try {
        _controller.removeListener(_videoListener);
      } catch (_) {}
      if (_isControllerOwner) {
        // 告诉 Service 清理对该控制器的引用，防止持有已销毁的控制器
        try {
          final playbackService = _exitPlaybackService;
          if (playbackService.controller == _controller) {
            playbackService.clearController();
          }
        } catch (e) {
          debugPrint("Error clearing controller from service: $e");
        }
        try {
          _controller.dispose();
        } catch (_) {}
      }
    }

    super.dispose();
  }

  KeyEventResult _handlePlaybackEarlyKeyEvent(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    final editable = focusContext?.widget is EditableText
        ? focusContext!.widget as EditableText
        : focusContext?.findAncestorWidgetOfExactType<EditableText>();
    if (editable != null) {
      if (event.logicalKey != LogicalKeyboardKey.escape) {
        return KeyEventResult.ignored;
      }
      final composing = editable.controller.value.composing;
      if (composing.isValid && !composing.isCollapsed) {
        return KeyEventResult.skipRemainingHandlers;
      }
      // The composer also handles Escape in its fullscreen dialog.
      if (_activeSidebar == SidebarType.aiChat) return KeyEventResult.ignored;
      if (event is KeyDownEvent) unawaited(_handleBackRequest());
      return KeyEventResult.handled;
    }
    final tab = bilibiliPanelTabForKey(event);
    if (_usesBilibiliSidebarTabs && !_isLocked && tab != null) {
      if (event is KeyDownEvent) _pickLandscapeBilibiliTab(tab);
      return KeyEventResult.handled;
    }
    final KeyEventResult transcriptResult =
        _subtitleSidebarKey.currentState?.handleTranscriptShortcut(event) ??
        KeyEventResult.ignored;
    if (transcriptResult != KeyEventResult.ignored) {
      return transcriptResult;
    }
    final controlsResult = _controlsKey.currentState?.handleKeyEvent(
      _playbackPageFocusNode,
      event,
    );
    if (controlsResult != null && controlsResult != KeyEventResult.ignored) {
      return controlsResult;
    }

    // Keep Escape as a page-level escape hatch while the controls are not
    // mounted (initial route frame, loading or errors).
    // The regular controls still own the full desktop shortcut behavior once
    // available.
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) {
        unawaited(_handleBackRequest());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _enterImmersiveMode() {
    if (kIsWeb) return;
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    }
  }

  void _restoreSystemUIMode() {
    if (kIsWeb) return;
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      SystemChrome.setSystemUIOverlayStyle(
        MobileSystemNavigationBar.overlayStyle,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _sidebarResizeHaptics.reset();
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // A platform interruption may consume pointer-up events. Explicitly
      // release both gesture ownership and temporary speed so neither can be
      // left stuck when the app resumes.
      if (_isLongPressing) {
        _endLongPressSpeed();
      }
      _subtitlePositions.seal();
      final settings = _settingsService;
      if (settings != null) unawaited(settings.flushSubtitlePositions());
      _videoGestureSession.reset();
      _activeVideoTransformPointers.clear();
      if (_isVideoTransformGestureActive && mounted) {
        setState(() {
          _isVideoTransformGestureActive = false;
        });
      }
      _saveProgress();
    } else if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        _enterImmersiveMode();
        final BuildContext? focusContext =
            FocusManager.instance.primaryFocus?.context;
        final bool isEditingText =
            focusContext?.widget is EditableText ||
            focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
        if (!isEditingText && _videoFocusNode.canRequestFocus) {
          _videoFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    final double nextInset = _readBottomViewInset();
    final bool insetChanged =
        (_keyboardInsetBottom.value - nextInset).abs() >= 0.5;
    if (insetChanged) {
      _keyboardInsetBottom.value = nextInset;
    }
    _tryRestoreSubtitleSidebarForCurrentViewport();
    _followRoomForBilibiliPanel();
  }

  @override
  void didPush() {
    MediaPlaybackService().setPlaybackPageVisible(this, true);
    _enterImmersiveMode();
    _requestSubtitleSidebarViewportRestore();
  }

  @override
  void didPopNext() {
    MediaPlaybackService().setPlaybackPageVisible(this, true);
    _enterImmersiveMode();
    _requestSubtitleSidebarViewportRestore();
  }

  @override
  void didPushNext() {
    _sidebarResizeHaptics.reset();
    if (!_isOpeningMusicPlayer) {
      unawaited(
        pausePlaybackPageWhenCovered(
          coveringRoute: AppToast.routeObserver.coveringRoute,
          settings: _exitSettings,
          playbackService: _exitPlaybackService,
          itemId: _currentItem?.id,
          controller: _controllerAssigned ? _controller : null,
          controllerOwner: _isControllerOwner,
        ),
      );
    }
    MediaPlaybackService().setPlaybackPageVisible(this, false);
  }

  @override
  void didPop() {
    MediaPlaybackService().setPlaybackPageVisible(this, false);
  }

  double _readBottomViewInset() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return view.viewInsets.bottom / view.devicePixelRatio;
  }

  bool get _shouldUseSmoothVideoKeyboardAvoidance =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isIOS) &&
      _activeSidebar == SidebarType.subtitleEditor;

  double _resolveVideoKeyboardShift(double keyboardInsetBottom) {
    if (!_shouldUseSmoothVideoKeyboardAvoidance || keyboardInsetBottom <= 0) {
      return 0;
    }
    // Keep the original "上移避让" feel while avoiding Scaffold-driven relayout.
    return -(keyboardInsetBottom / 2);
  }

  @override
  void deactivate() {
    _elementActive = false;
    _saveProgress();
    super.deactivate();
  }

  bool _elementActive = true;

  @override
  void activate() {
    super.activate();
    _elementActive = true;
    _tryRestoreSubtitleSidebarForCurrentViewport();
  }

  Future<void> _saveProgress() async {
    if (!_initialized || _currentItem == null) return;
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    await _saveProgressForSession(
      itemId: _currentItem!.id,
      controller: _controller,
      controllerOwner: _isControllerOwner,
      playbackService: playbackService,
      libraryService: Provider.of<LibraryService>(context, listen: false),
    );
  }

  Future<void> _saveProgressForSession({
    required String itemId,
    required VideoPlayerController controller,
    required bool controllerOwner,
    required MediaPlaybackService playbackService,
    required LibraryService libraryService,
  }) async {
    if (playbackService.currentItem?.id == itemId &&
        identical(playbackService.controller, controller)) {
      await playbackService.persistCurrentProgress(
        expectedItemId: itemId,
        expectedController: controller,
      );
      return;
    }
    if (!controllerOwner || !controller.value.isInitialized) return;
    await libraryService.updateVideoProgress(
      itemId,
      controller.value.position.inMilliseconds,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled) _sidebarMotion.finish();
    _routeWork.bind(ModalRoute.of(context));
    // Exit/dispose can run after this element loses its inherited context.
    _exitSettings = context.read<SettingsService>();
    _exitPlaybackService = context.read<MediaPlaybackService>();
    _exitLibraryService = context.read<LibraryService>();

    if (!_routeObserverSubscribed) {
      final route = ModalRoute.of(context);
      if (route is PageRoute) {
        AppToast.routeObserver.subscribe(this, route);
        _routeObserverSubscribed = true;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_elementActive) return;
      registerPlaybackPageIfCurrent(context, this);
    });

    // Listen to TranscriptionManager
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    if (_transcriptionManager != manager) {
      _transcriptionManager?.removeListener(_onTranscriptionUpdate);
      _transcriptionManager = manager;
      _transcriptionManager?.addListener(_onTranscriptionUpdate);

      // Check immediately in case it completed while we were away
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onTranscriptionUpdate();
      });
    }

    final ocrManager = Provider.of<OcrSubtitleManager>(context, listen: false);
    if (_ocrSubtitleManager != ocrManager) {
      _ocrSubtitleManager?.removeListener(_onOcrSubtitleUpdate);
      _ocrSubtitleManager = ocrManager;
      _ocrSubtitleManager?.addListener(_onOcrSubtitleUpdate);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onOcrSubtitleUpdate();
      });
    }
  }

  void _onOcrSubtitleUpdate() {
    if (!mounted || _ocrSubtitleManager == null) return;
    final job = _ocrSubtitleManager!.job;
    if (job?.status != OcrSubtitleJobStatus.completed) return;
    final paths = _ocrSubtitleManager!.consumeCompletedPaths(job!.videoId);
    if (paths == null || paths.isEmpty) return;
    if (_currentItem?.id == job.videoId) {
      unawaited(_applyCompletedOcrSubtitles(paths));
    }
  }

  void _onTranscriptionUpdate() {
    if (!mounted || _transcriptionManager == null) return;

    final currentPath = widget.videoFile?.path ?? widget.videoItem?.path;
    if (currentPath == null) return;

    final currentVideoId = _currentItem?.id ?? widget.videoItem?.id;
    final streaming = _transcriptionManager!.streamForVideo(
      currentPath,
      videoId: currentVideoId,
    );
    if (_transcriptionManager!.hasSubtitleStreamForVideo(
      currentPath,
      videoId: currentVideoId,
    )) {
      if (streaming?.complete ?? true) {
        _transcriptionManager!.consumeResultNotificationForVideo(
          currentPath,
          videoId: currentVideoId,
        );
      }
      return;
    }
    final path = _transcriptionManager!.getGeneratedSrtPathForVideo(
      currentPath,
      videoId: currentVideoId,
    );
    if (path != null &&
        _transcriptionManager!.consumeResultNotificationForVideo(
          currentPath,
          videoId: currentVideoId,
        )) {
      final translation = _transcriptionManager!
          .getGeneratedTranslationPathForVideo(
            currentPath,
            videoId: currentVideoId,
          );
      List<String> pathsToLoad = [path];
      if (translation != null) {
        pathsToLoad.add(translation);
      } else if (_currentSubtitlePaths.length > 1) {
        pathsToLoad.add(_currentSubtitlePaths[1]);
      }

      _loadSubtitles(pathsToLoad);

      // 不需要在这里保存，TranscriptionManager 已经保存了
    }
  }

  void _checkAndLoadAiSubtitle(VideoItem? currentItem) {
    if (currentItem == null) return;

    final currentPath = currentItem.path;
    if (currentPath.isEmpty) return;

    try {
      final manager = Provider.of<TranscriptionManager>(context, listen: false);
      if (manager.hasSubtitleStreamForVideo(
        currentPath,
        videoId: currentItem.id,
      )) {
        return;
      }

      final srtPath = manager.getGeneratedSrtPathForVideo(
        currentPath,
        videoId: currentItem.id,
      );
      if (srtPath != null) {
        if (File(srtPath).existsSync()) {
          debugPrint("检测到AI字幕已完成，自动加载: $srtPath");

          List<String> pathsToLoad = [srtPath];
          if (currentItem.secondarySubtitlePath != null) {
            pathsToLoad.add(currentItem.secondarySubtitlePath!);
          }

          _loadSubtitles(pathsToLoad);

          manager.consumeResultNotificationForVideo(
            currentPath,
            videoId: currentItem.id,
          );
        }
      }
    } catch (e) {
      debugPrint("检查AI字幕失败: $e");
    }
  }

  // --- Auto Load External Subtitles (Windows) ---
  Future<void> _tryLoadFirstExternalSubtitle() async {
    // 简单的重试机制，因为Windows下文件扫描可能稍有延迟
    int attempts = 0;
    const maxAttempts = 3;

    while (attempts < maxAttempts) {
      if (!mounted) return;
      // 如果用户在重试期间已经手动加载了字幕，则停止
      if (_subtitles.isNotEmpty) return;

      bool found = await _scanAndLoadExternalSubtitle();
      if (found) return;

      attempts++;
      if (attempts < maxAttempts) {
        // 间隔一定时间重试
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }
  }

  Future<bool> _scanAndLoadExternalSubtitle() async {
    final currentItem = _currentItem;
    final path = currentItem?.path ?? widget.videoFile?.path;
    if (path == null) return false;

    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final subtitleEntries = await const SubtitleDiscoveryService()
          .scanVideoDirectory(
            videoPath: path,
            videoDurationMs: currentItem != null && currentItem.durationMs > 0
                ? currentItem.durationMs
                : null,
          );
      final autoPaths = subtitleEntries
          .where((entry) => entry.isAuto)
          .take(2)
          .map((entry) => entry.path)
          .toList();
      if (autoPaths.isEmpty) return false;
      final primaryPath = autoPaths.first;

      // 加载字幕（命中一个时主字幕；命中两个时按语言权重作为主 + 副字幕）。
      if (mounted) {
        debugPrint("Auto loading external subtitle: $primaryPath");
        final library = Provider.of<LibraryService>(context, listen: false);
        final pathsToLoad = List<String>.of(autoPaths);
        await _loadSubtitles(pathsToLoad);

        // 更新媒体库记录（持久化）
        try {
          if (_currentItem != null) {
            library.updateVideoSubtitles(
              _currentItem!.id,
              primaryPath,
              settings.autoCacheSubtitles,
              secondarySubtitlePath: autoPaths.length > 1 ? autoPaths[1] : null,
              isSecondaryCached: settings.autoCacheSubtitles,
            );
          }
        } catch (_) {}

        return true;
      }
    } catch (e) {
      debugPrint("Error scanning external subtitles: $e");
    }
    return false;
  }

  // --- Auto Load Embedded Subtitles ---
  void _setEmbeddedSubtitleError(String mediaKey, String? message) {
    if (!mounted || (_currentItem?.id ?? widget.videoFile?.path) != mediaKey) {
      return;
    }
    setState(() {
      _embeddedSubtitleErrorMediaKey = mediaKey;
      _embeddedSubtitleError = message;
    });
  }

  Future<void> _checkAndLoadEmbeddedSubtitle() async {
    // If we already have subtitles loaded (e.g. from file), don't override
    if (_subtitles.isNotEmpty) return;

    // Prevent multiple concurrent checks
    if (_isLoadingEmbeddedSubtitle) return;

    // Determine video path
    String? path;
    if (_currentItem != null) {
      path = _currentItem!.path;
    } else if (widget.videoFile != null) {
      path = widget.videoFile!.path;
    }

    if (path == null) return;
    if (path.startsWith('bilibili://stream/')) return;

    final mediaKey = _currentItem?.id ?? path;
    _setEmbeddedSubtitleError(mediaKey, null);
    // Check embedded
    try {
      _isLoadingEmbeddedSubtitle = true;
      final SettingsService settings = Provider.of<SettingsService>(
        context,
        listen: false,
      );
      final LibraryService library = Provider.of<LibraryService>(
        context,
        listen: false,
      );

      final service = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      // Note: getEmbeddedSubtitles is fast (probe only)
      final tracks = await service.getEmbeddedSubtitles(path);

      if (tracks.isNotEmpty && mounted && _subtitles.isEmpty) {
        setState(() {
          _embeddedSubtitleDetected = true;
        });
        final EmbeddedSubtitleTrack track = tracks.firstWhere(
          (t) => !_isImageSubtitleCodec(t.codecName),
          orElse: () => tracks.first,
        );
        if (_isImageSubtitleCodec(track.codecName)) {
          setState(() {
            _embeddedSubtitleDetected = false;
          });
          _setEmbeddedSubtitleError(mediaKey, '当前播放器不支持图像字幕，可选择文本字幕或识别画面字幕。');
          return;
        }

        final itemId = _currentItem!.id;
        final subDir = await const TaskSubtitleStorageService().taskDirectory(
          itemId,
          create: true,
        );

        // Extract
        final extractedPath = await service.extractSubtitle(
          path,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: itemId,
        );

        if (extractedPath != null) {
          await library.registerManagedSubtitleAsset(
            itemId,
            path: extractedPath,
            kind: ManagedSubtitleAssetKind.embedded,
            displayName: track.title,
          );
        }

        if (extractedPath != null && mounted) {
          // Check again if user loaded something while we were extracting
          if (_subtitles.isNotEmpty) return;

          List<String> pathsToLoad = [extractedPath];
          if (_currentSubtitlePaths.length > 1) {
            pathsToLoad.add(_currentSubtitlePaths[1]);
          }
          await _loadSubtitles(pathsToLoad);
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _subtitleSidebarKey.currentState?.jumpToFirstSubtitleTop();
            });
          }

          if (_currentItem != null) {
            try {
              final String? currentSecondary = _currentSubtitlePaths.length > 1
                  ? _currentSubtitlePaths[1]
                  : _currentItem!.secondarySubtitlePath;
              await library.updateVideoSubtitles(
                _currentItem!.id,
                extractedPath,
                settings.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settings.autoCacheSubtitles,
              );
              final updated = library.getVideo(_currentItem!.id);
              if (updated != null && mounted) {
                setState(() {
                  _currentItem = updated;
                });
              }
            } catch (_) {}
          }

          if (!mounted) return;
        } else if (mounted && extractedPath == null) {
          // Extraction failed
          _setEmbeddedSubtitleError(mediaKey, '内嵌字幕未能提取，请重试或选择其他字幕。');
        }
      } else if (mounted && tracks.isEmpty) {
        // No embedded subtitles found
        if (_embeddedSubtitleDetected) {
          setState(() {
            _embeddedSubtitleDetected = false;
          });
        }

        // Windows/Mac端：如果没有内嵌字幕，尝试自动加载本地文件夹中的第一个外挂字幕
        if ((Platform.isWindows || Platform.isMacOS) && _subtitles.isEmpty) {
          _tryLoadFirstExternalSubtitle();
        }
      }
    } catch (e) {
      debugPrint("Auto load embedded subtitle failed: $e");
      if (_embeddedSubtitleDetected && mounted) {
        setState(() {
          _embeddedSubtitleDetected = false;
        });
      }
      _setEmbeddedSubtitleError(mediaKey, '内嵌字幕未能读取，请重试或选择其他字幕。');
    } finally {
      if (mounted) {
        setState(() => _isLoadingEmbeddedSubtitle = false);
      } else {
        _isLoadingEmbeddedSubtitle = false;
      }
    }
  }

  /// Single-flight guard for [_initVideo]. The service notifies listeners at
  /// several settling points of one media switch (loading → mountable →
  /// ready); without coalescing each notification re-entered initialization
  /// concurrently, racing controller adoption and subtitle state.
  Future<void>? _initVideoInFlight;
  bool _initVideoRerunPending = false;

  Future<void> _initVideo() {
    final inFlight = _initVideoInFlight;
    if (inFlight != null) {
      _initVideoRerunPending = true;
      return inFlight;
    }
    final run = _runInitVideoGuarded();
    _initVideoInFlight = run;
    return run;
  }

  Future<void> _runInitVideoGuarded() async {
    try {
      await _initVideoInternal();
    } catch (error, stackTrace) {
      debugPrint('VideoPlayerScreen: _initVideo failed: $error\n$stackTrace');
    } finally {
      _initVideoInFlight = null;
      if (_initVideoRerunPending && mounted) {
        _initVideoRerunPending = false;
        unawaited(_initVideo());
      }
    }
  }

  Future<void> _initVideoInternal() async {
    if (widget.deferPlaybackUntilCurrent &&
        context.read<MediaPlaybackService>().currentItem?.id !=
            widget.videoItem?.id) {
      return;
    }
    if (_fatalErrorMessage != null && mounted) {
      setState(() {
        _fatalErrorMessage = null;
      });
    }

    // Refresh video item from library to ensure we have latest subtitle settings
    VideoItem? currentItem = _currentItem;
    final legacyPath = widget.videoFile?.path;
    if (currentItem == null && legacyPath != null && legacyPath.isNotEmpty) {
      currentItem = VideoItem(
        id: legacyPath,
        path: legacyPath,
        title: p.basename(legacyPath),
        durationMs: 0,
        lastUpdated: 0,
      );
    }
    if (currentItem != null) {
      try {
        final libItem = Provider.of<LibraryService>(
          context,
          listen: false,
        ).getVideo(currentItem.id);
        if (libItem != null && libItem.lastUpdated >= currentItem.lastUpdated) {
          currentItem = libItem;
        }
      } catch (e) {
        debugPrint("Error refreshing video item: $e");
      }
    }

    _currentItem = currentItem;
    if (mounted && currentItem != null) {
      final item = currentItem;
      _routeWork.schedule('video-shot', () {
        if (!mounted || _currentItem?.id != item.id) return;
        scheduleBilibiliVideoShotBackfill(
          context: context,
          item: item,
          isStillCurrent: () => mounted && _currentItem?.id == item.id,
          onUpdated: () {
            if (mounted) setState(() {});
          },
        );
      });
    }

    if (currentItem != null) {
      _applyItemSubtitlePreference(currentItem, force: true);
    }

    // Check if this is audio
    _isAudio = currentItem?.type == MediaType.audio;

    if (currentItem != null) {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      playbackService.setPlaybackPageVisible(this, true);
      if (playbackService.needsVisibleVideoOutputRecovery(currentItem.id)) {
        unawaited(playbackService.ensureVisibleVideoOutput(currentItem.id));
      }
    }

    // 检查是否是从竖屏页传递过来的控制器（首次进入横屏）
    // 这种情况下，视频ID应该与传入的videoItem一致
    bool isInitialEntryFromPortrait =
        widget.existingController != null &&
        widget.videoItem != null &&
        _currentItem?.id == widget.videoItem!.id &&
        !_controllerAssigned &&
        !_initialControllerConsumed;
    if (isInitialEntryFromPortrait) {
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        if (playbackService.controller != widget.existingController ||
            !playbackService.canMountControllerFor(
              currentItem!.id,
              controller: widget.existingController,
            )) {
          isInitialEntryFromPortrait = false;
        }
      } catch (_) {}
    }

    if (isInitialEntryFromPortrait) {
      _controller = widget.existingController!;
      _controllerAssigned = true;
      _isControllerOwner = false;
      _initialized = true;
      _initialControllerConsumed = true;

      // 从 MediaPlaybackService 获取正确的播放状态，而不是直接从 controller
      // 这样可以确保状态同步（例如用户在快捷播放卡片暂停后进入播放页面）
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        _isPlaying = playbackService.isPlaying;

        final bool? pageEntryAutoPlay = _consumePageEntryAutoPlay();
        if (pageEntryAutoPlay == true && !playbackService.desiredPlaying) {
          unawaited(playbackService.resume());
        }

        // MediaPlaybackService already owns this controller and its
        // authoritative position. Avoid replacing it with a transient native
        // byte-zero sample while an online stream is being handed off.
        // The play/pause repair follows the session intent (desiredPlaying),
        // never the transient isPlaying flag: during an episode switch the
        // service still reports "loading" while the controller already plays,
        // and pausing here used to kill the auto-play-after-switch setting.
        if (pageEntryAutoPlay != true &&
            playbackService.state != PlaybackState.loading) {
          if (MediaPlaybackService.shouldResumeOnPageAdopt(
            desiredPlaying: playbackService.desiredPlaying,
            state: playbackService.state,
          )) {
            unawaited(playbackService.resume());
          } else if (MediaPlaybackService.shouldPauseOnPageAdopt(
            desiredPlaying: playbackService.desiredPlaying,
            state: playbackService.state,
            controllerPlaying: _controller.value.isPlaying,
          )) {
            unawaited(playbackService.pause());
          }
        }

        final existingSubtitles = playbackService.subtitles;
        final existingSecondary = playbackService.secondarySubtitles;
        final existingPaths = playbackService.subtitlePaths;
        if (existingSubtitles.isNotEmpty ||
            existingSecondary.isNotEmpty ||
            existingPaths.isNotEmpty) {
          setState(() {
            _subtitles = existingSubtitles;
            _secondarySubtitles = existingSecondary;
            _currentSubtitlePaths = List<String>.from(existingPaths);
            _currentSubtitleText = "";
            _currentSecondaryText = null;
            _currentSubtitleImage = null;
            _currentSubtitleIndex = -1;
            _currentSecondarySubtitleIndex = -1;
            _currentSubtitleIndices = [];
            _currentSecondarySubtitleIndices = [];
            _currentSubtitleEntries = [];
            _currentSubtitleImages.clear();
            subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
          });
          _rebuildSubtitleIndex();
        }
      } catch (e) {
        // 如果无法获取 MediaPlaybackService，回退到使用 controller 的状态
        debugPrint("无法获取 MediaPlaybackService 状态: $e");
        _isPlaying = _controller.value.isPlaying;
      }

      _bindControllerListener();
      _triggerSubtitleRefreshBurst();
      _scheduleDeferredPostInitWork(currentItem);
    } else {
      // 尝试从 MediaPlaybackService 获取 controller (适用于视频切换或未传递 controller 的情况)
      bool usedService = false;
      if (currentItem != null) {
        try {
          final playbackService = Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          );

          if (playbackService.currentItem?.id == currentItem.id &&
              playbackService.isSourceMissing) {
            _showMissingSource(currentItem);
            _syncSubtitlesFromService(playbackService);
            return;
          }

          // 如果 Service 正在加载此视频，等待它完成
          if (playbackService.currentItem?.id == currentItem.id &&
              playbackService.state == PlaybackState.loading &&
              !playbackService.hasMountableController) {
            debugPrint(
              "VideoPlayerScreen: Waiting for service to load ${currentItem.title}",
            );
            // Keep an already-mounted texture. Replacing it with the loading
            // overlay is the "black page stacked on a ready video" flash.
            if (!(_initialized && _controllerAssigned)) {
              setState(() {
                _initialized = false;
              });
            }
            return;
          }

          bool canReuseController = false;
          if (playbackService.canMountControllerFor(currentItem.id)) {
            try {
              // 测试控制器是否存活
              void noOp() {}
              playbackService.controller!.addListener(noOp);
              playbackService.controller!.removeListener(noOp);
              canReuseController = true;
            } catch (_) {
              playbackService.clearController();
            }
          }

          if (canReuseController) {
            // 如果之前持有本地 controller，先释放
            if (_controllerAssigned && _isControllerOwner) {
              try {
                _controller.removeListener(_videoListener);
                _controller.dispose();
              } catch (e) {
                debugPrint("Error disposing old controller: $e");
              }
            }

            _controller = playbackService.controller!;
            _controllerAssigned = true;
            _isControllerOwner = false;

            if (mounted) {
              setState(() {
                _isSourceMissing = false;
                _initialized = _controller.value.isInitialized;
                _isPlaying = playbackService.isPlaying; // 同时更新播放状态
              });
            }

            usedService = true;

            // Sync state logic
            if (_controller.value.isInitialized &&
                playbackService.state != PlaybackState.loading) {
              // The service is already the source of truth for this reused
              // controller; only repair an actual play/pause mismatch — and
              // do it against the session intent, not the transient
              // isPlaying flag. While an episode switch is still loading the
              // service commits the transport intent itself; a page-side
              // "correction" here used to pause the optimistic autoplay and
              // overwrite the「切换上下集自动播放」setting.
              if (MediaPlaybackService.shouldResumeOnPageAdopt(
                desiredPlaying: playbackService.desiredPlaying,
                state: playbackService.state,
              )) {
                unawaited(playbackService.resume());
              } else if (MediaPlaybackService.shouldPauseOnPageAdopt(
                desiredPlaying: playbackService.desiredPlaying,
                state: playbackService.state,
                controllerPlaying: _controller.value.isPlaying,
              )) {
                unawaited(playbackService.pause());
              }
            }

            final existingSubtitles = playbackService.subtitles;
            final existingSecondarySubtitles =
                playbackService.secondarySubtitles;
            final existingPaths = playbackService.subtitlePaths;
            if (existingSubtitles.isNotEmpty ||
                existingSecondarySubtitles.isNotEmpty ||
                existingPaths.isNotEmpty) {
              setState(() {
                _subtitles = existingSubtitles;
                _secondarySubtitles = existingSecondarySubtitles;
                _currentSubtitlePaths = List<String>.from(existingPaths);
                _currentSubtitleText = "";
                _currentSecondaryText = null;
                _currentSubtitleImage = null;
                _currentSubtitleIndex = -1;
                _currentSecondarySubtitleIndex = -1;
                _currentSubtitleIndices = [];
                _currentSecondarySubtitleIndices = [];
                _currentSubtitleEntries = [];
                _currentSubtitleImages.clear();
                subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
              });
              _rebuildSubtitleIndex();
            }

            _bindControllerListener();
            _triggerSubtitleRefreshBurst();
            _scheduleDeferredPostInitWork(currentItem);

            final bool? pageEntryAutoPlay = _consumePageEntryAutoPlay();
            if (pageEntryAutoPlay == true && !playbackService.desiredPlaying) {
              unawaited(playbackService.resume());
              return;
            }
          }
        } catch (e) {
          debugPrint("Check MediaPlaybackService failed: $e");
        }
      }

      if (!usedService && currentItem != null) {
        try {
          final playbackService = Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          );
          if (mounted && !(_initialized && _controllerAssigned)) {
            setState(() {
              _initialized = false;
              _isPlaying = false;
              _isSourceMissing = false;
            });
          }
          // Pages mount a revision-checked controller but never create one.
          // This prevents a page/controller race with notification and mini
          // player episode commands.
          if (playbackService.currentItem?.id == currentItem.id &&
              playbackService.state == PlaybackState.loading) {
            // The service is already preparing exactly this media (e.g. a
            // notification-triggered episode switch still in flight). Forcing
            // a second play() here would tear down and reopen the same source;
            // the service listener below mounts the controller once it is
            // ready.
            return;
          }
          if (playbackService.shouldDeferPlayForActiveSession(currentItem.id)) {
            // Bilibili audio kept playing off-page; wait for video-track
            // re-enable instead of reopening the stream via play().
            return;
          }
          unawaited(
            playbackService.play(
              currentItem,
              autoPlay: resolvePlaybackPageEntryAutoPlay(
                entryAutoPlay: _consumePageEntryAutoPlay(),
                isCurrentItem:
                    playbackService.currentItem?.id == currentItem.id,
                desiredPlaying: playbackService.desiredPlaying,
              ),
              startPosition:
                  MediaPlaybackService.startPositionForCurrentSession(
                    currentItemId: playbackService.currentItem?.id,
                    itemId: currentItem.id,
                    currentPosition: playbackService.position,
                  ),
            ),
          );
        } catch (error) {
          _setFatalError('Unable to start service-owned playback: $error');
        }
      }
    }
  }

  bool? _consumePageEntryAutoPlay() {
    if (_pageEntryAutoPlayConsumed) return null;
    _pageEntryAutoPlayConsumed = true;
    return widget.autoPlayOnEntry;
  }

  Size? _lastVideoLayoutSize;

  void _videoListener() {
    if (!mounted) return;
    if (!_controllerAssigned) return;
    _applyDeferredDanmakuReload();

    try {
      if (_controller.value.isInitialized &&
          (!_initialized || _lastVideoLayoutSize != _controller.value.size)) {
        setState(() {
          _initialized = true;
          _lastVideoLayoutSize = _controller.value.size;
        });
        _triggerSubtitleRefreshBurst();
      }
    } catch (_) {
      return;
    }

    // Check for errors
    if (_controller.value.hasError && !_isRepairing) {
      final errorMsg = _controller.value.errorDescription ?? "";
      final lower = errorMsg.toLowerCase();
      if (_fatalErrorMessage == null &&
          (lower.contains("no such file") ||
              lower.contains("file not found") ||
              lower.contains("cannot open") ||
              lower.contains("filesystemexception"))) {
        final item = _currentItem;
        if (item != null) {
          try {
            Provider.of<MediaPlaybackService>(
              context,
              listen: false,
            ).markCurrentSourceMissing(expectedItemId: item.id);
          } catch (_) {}
          _showMissingSource(item);
        } else {
          _setFatalError("媒体文件已不存在或无法访问");
        }
        return;
      }
      // Specific check for HevcConfig or ExoPlaybackException: Source error
      if (errorMsg.contains("HevcConfig") ||
          errorMsg.contains("Source error") ||
          errorMsg.contains("VideoError")) {
        // Remove listener to prevent loop
        _controller.removeListener(_videoListener);
        _showRepairDialog();
        return;
      }
    }

    final isPlaying = _controller.value.isPlaying;
    if (isPlaying != _isPlaying) {
      setState(() {
        _isPlaying = isPlaying;
      });

      // 始终同步播放状态到 MediaPlaybackService
      // 确保通知栏和快捷控制卡片显示正确的播放/暂停状态
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        // 使用新的同步方法，避免状态检查导致的同步失败
        playbackService.updatePlaybackStateFromController();
      } catch (e) {
        debugPrint("同步播放状态失败: $e");
      }
    }

    // 检测视频播放完成，在末尾暂停而不是自动播放下一集
    if (_controller.value.isInitialized &&
        !_controller.value.isPlaying &&
        _controller.value.position >= _controller.value.duration) {
      // 视频已播放到末尾，暂停播放（不自动播放下一集）
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        // 保存播放进度
        playbackService.updatePlaybackStateFromController();
      } catch (e) {
        debugPrint("保存播放进度失败: $e");
      }
    }

    _updateSubtitle();
  }

  void _showRepairDialog() {
    if (!mounted) return;
    final online =
        _currentItem?.sourceRef?.kind == MediaSourceKind.bilibiliStream;
    setState(() {
      _repairAvailable = !online;
      _repairFailureDetails = null;
      _fatalErrorMessage = online
          ? '当前画质无法播放，请切换在线清晰度后重试。'
          : '视频格式暂时无法播放。可尝试转为 H.264，修复可能需要几分钟。';
    });
  }

  void _showRepairFailure(String message, {Object? error}) {
    if (!mounted) return;
    setState(() {
      _isRepairing = false;
      _repairAvailable = true;
      _fatalErrorMessage = message;
      _repairFailureDetails = error == null
          ? null
          : safeOperationDiagnostic(error);
    });
  }

  Future<void> _repairVideo() async {
    setState(() {
      _isRepairing = true;
      _repairProgress = 0.0;
      _fatalErrorMessage = null;
      _repairFailureDetails = null;
    });

    String? path;
    if (_currentItem != null) {
      path = _currentItem!.path;
    } else if (widget.videoFile != null) {
      path = widget.videoFile!.path;
    }

    if (path == null) return;
    final String videoPath = path;

    final file = File(videoPath);
    final dir = file.parent;
    final filename = p.basenameWithoutExtension(videoPath);
    final ext = p.extension(videoPath);
    final outputPath = p.join(dir.path, "${filename}_repaired$ext");

    // Transcode to H.264 (AVC) which is widely supported
    // -preset ultrafast for speed
    // -crf 23 for decent quality
    // -c:a copy to keep audio untouched
    final command =
        "-y -i \"$videoPath\" -c:v libx264 -preset ultrafast -crf 23 -c:a copy \"$outputPath\"";

    debugPrint("Starting repair: $command");

    // Estimate duration for progress calculation (if available)
    int durationMs = 0;
    if (_controller.value.isInitialized) {
      durationMs = _controller.value.duration.inMilliseconds;
    } else if (_currentItem != null && _currentItem!.durationMs > 0) {
      durationMs = _currentItem!.durationMs;
    }

    // Fallback: Use FFprobe if duration is unknown
    if (durationMs == 0) {
      debugPrint("Duration unknown, probing...");
      try {
        if (FFmpegUtils.preferSystemFfmpeg) {
          durationMs = await MediaDurationProbe.probeDurationMs(
            videoPath,
            allowVideoPlayerFallback: false,
          );
        } else {
          final session = await FFprobeKit.getMediaInformation(videoPath);
          final info = session.getMediaInformation();
          if (info != null) {
            final durationStr = info.getDuration();
            if (durationStr != null) {
              final double d = double.tryParse(durationStr) ?? 0.0;
              durationMs = (d * 1000).toInt();
            }
          }
        }
      } catch (e) {
        debugPrint("Probe failed: $e");
      }
    }

    if (FFmpegUtils.preferSystemFfmpeg) {
      try {
        await FFmpegUtils.ensureAvailable();
      } catch (e) {
        _showRepairFailure(
          operationErrorSummary(e, fallback: '无法启动转码工具，请检查工具后重试。'),
          error: e,
        );
        return;
      }
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      try {
        final process = await Process.start(ffmpegPath, [
          '-y',
          '-i',
          videoPath,
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-crf',
          '23',
          '-c:a',
          'copy',
          outputPath,
        ]);
        final stderrBuf = StringBuffer();
        process.stderr.transform(const SystemEncoding().decoder).listen((line) {
          stderrBuf.write(line);
          final match = RegExp(
            r'time=(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)',
          ).firstMatch(line);
          if (match != null && durationMs > 0 && mounted) {
            final h = double.tryParse(match.group(1)!) ?? 0;
            final m = double.tryParse(match.group(2)!) ?? 0;
            final s = double.tryParse(match.group(3)!) ?? 0;
            final timeMs = ((h * 3600 + m * 60 + s) * 1000).round();
            setState(() {
              _repairProgress = (timeMs / durationMs).clamp(0.0, 1.0);
            });
          }
        });
        final code = await process.exitCode;
        if (code == 0) {
          try {
            final originalBackup = p.join(dir.path, "${filename}_backup$ext");
            if (await File(originalBackup).exists()) {
              await File(originalBackup).delete();
            }
            await file.rename(originalBackup);
            await File(outputPath).rename(videoPath);
            await File(originalBackup).delete();
            if (mounted) {
              setState(() => _isRepairing = false);
              _controller.dispose();
              _initVideo();
            }
          } catch (e) {
            debugPrint("File op failed: $e");
            if (mounted) {
              _showRepairFailure('修复后的视频未能替换原文件，请检查文件权限后重试。', error: e);
            }
          }
        } else {
          final logContent = stderrBuf.toString();
          debugPrint("Repair failed: $logContent");
          _showRepairFailure('转码未完成，请检查媒体文件后重试。', error: logContent);
        }
      } catch (e) {
        _showRepairFailure(
          operationErrorSummary(e, fallback: '修复未完成，请重试。'),
          error: e,
        );
      }
      return;
    }

    await FFmpegKit.executeAsync(
      command,
      (session) async {
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          debugPrint("Repair success!");

          try {
            final originalBackup = p.join(dir.path, "${filename}_backup$ext");
            if (await File(originalBackup).exists()) {
              await File(originalBackup).delete();
            }
            await file.rename(originalBackup);
            await File(outputPath).rename(videoPath);

            // Delete backup if successful rename
            await File(originalBackup).delete();

            if (mounted) {
              setState(() => _isRepairing = false);
              // Re-init video
              _controller.dispose();
              _initVideo();
            }
          } catch (e) {
            debugPrint("File op failed: $e");
            if (mounted) {
              _showRepairFailure('修复后的视频未能替换原文件，请检查文件权限后重试。', error: e);
            }
          }
        } else {
          debugPrint("Repair failed");
          final logs = await session.getAllLogsAsString();
          final logContent = logs ?? "无日志信息";
          debugPrint("FFmpeg logs: $logContent");

          _showRepairFailure('转码未完成，请检查媒体文件后重试。', error: logContent);
        }
      },
      (log) {},
      (statistics) {
        final time = statistics.getTime(); // time in ms
        if (mounted) {
          setState(() {
            if (durationMs > 0) {
              _repairProgress = (time / durationMs).clamp(0.0, 1.0);
            } else {
              // Keep the indeterminate state when probing found no duration.
            }
          });
        }
      },
    );
  }

  /// Hop seeks publish an optimistic service clock immediately. Native
  /// [VideoPlayerController.position] on online Bilibili can lag on the
  /// previous cue and flash the sidebar/overlay backward.
  Duration _subtitleLookupPosition() {
    final native = _controller.value.position;
    try {
      final service = Provider.of<MediaPlaybackService>(context, listen: false);
      if (!identical(service.controller, _controller)) return native;
      return service.positionForSubtitleOverlay(native);
    } catch (_) {
      return native;
    }
  }

  void _onSubtitlePositionChanged() {
    if (!mounted ||
        !_elementActive ||
        !_controllerAssigned ||
        !identical(_subtitlePlaybackService?.controller, _controller)) {
      return;
    }
    _updateSubtitle(positionOnly: true);
  }

  void _updateSubtitle({bool positionOnly = false}) {
    if (!_initialized) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (_videoComposePreviewActive && !positionOnly) {
      _videoComposePreviewController.update(_controller.value.position);
    }

    if (!settings.showSubtitles) {
      if (_currentSubtitleText.isNotEmpty ||
          _currentSecondaryText != null ||
          _currentSubtitleImage != null ||
          _currentSubtitleIndex != -1 ||
          _currentSecondarySubtitleIndex != -1 ||
          _currentSubtitleEntries.isNotEmpty) {
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleImage = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
        subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
      }
      return;
    }

    final position = _subtitleLookupPosition();
    final adjustedPosition = position - settings.subtitleOffset;
    final int posMs = adjustedPosition.inMilliseconds;
    final continuousSubtitleEnabled = _isAudio
        ? settings.audioContinuousSubtitle
        : settings.videoContinuousSubtitle;

    if (_subtitleTimeline.length != _subtitles.length ||
        _secondarySubtitleTimeline.length != _secondarySubtitles.length) {
      _rebuildSubtitleIndex();
    }

    final List<int> primaryIndices = _subtitles.isEmpty
        ? <int>[]
        : _subtitleTimeline.activeIndicesAtMs(
            posMs,
            extendToNextStart: continuousSubtitleEnabled,
          );

    final List<int> secondaryIndices = _secondarySubtitles.isEmpty
        ? <int>[]
        : _secondarySubtitleTimeline.activeIndicesAtMs(
            posMs,
            extendToNextStart: continuousSubtitleEnabled,
          );

    // Frame ticks only need to rebuild content at cue boundaries. Settings,
    // streamed text edits and image loads still use the full refresh path.
    if (positionOnly &&
        listEquals(primaryIndices, _currentSubtitleIndices) &&
        listEquals(secondaryIndices, _currentSecondarySubtitleIndices)) {
      return;
    }

    final List<SubtitleItem> secondaryOverlapItems = secondaryIndices
        .map((i) => _secondarySubtitles[i])
        .toList();
    final List<SubtitleOverlayEntry> entries = <SubtitleOverlayEntry>[];

    if (primaryIndices.isNotEmpty) {
      for (final int index in primaryIndices) {
        final SubtitleItem item = _subtitles[index];
        String text = item.text;
        String? secondaryText;
        final Uint8List? image = _currentSubtitleImages[index];

        if (_secondarySubtitles.isEmpty && settings.splitSubtitleByLine) {
          if (text.contains('\n')) {
            final lines = text.split('\n');
            text = lines[0];
            secondaryText = lines.sublist(1).join('\n');
          }
        } else if (secondaryOverlapItems.isNotEmpty) {
          SubtitleItem? best;
          int bestDelta = 1 << 30;
          for (final sec in secondaryOverlapItems) {
            final int delta =
                (sec.startTime.inMilliseconds - item.startTime.inMilliseconds)
                    .abs();
            if (delta < bestDelta) {
              bestDelta = delta;
              best = sec;
            }
          }
          secondaryText = best?.text;
        }

        final bool hasImage = item.imageLoader != null;
        if (hasImage) {
          text = "";
          secondaryText = null;
        }

        entries.add(
          SubtitleOverlayEntry(
            sourcePath: _fontSource(false),
            secondarySourcePath: _fontSource(true),
            language: _fontLanguage(false),
            secondaryLanguage: _fontLanguage(true),
            index: index,
            text: text,
            secondaryText: secondaryText,
            image: image,
          ),
        );
      }
    } else if (secondaryIndices.isNotEmpty) {
      for (final int index in secondaryIndices) {
        final SubtitleItem item = _secondarySubtitles[index];
        entries.add(
          SubtitleOverlayEntry(
            sourcePath: _fontSource(false),
            secondarySourcePath: _fontSource(true),
            language: _fontLanguage(false),
            secondaryLanguage: _fontLanguage(true),
            index: null,
            text: "",
            secondaryText: item.text,
            image: null,
          ),
        );
      }
    }

    final int anchorPrimaryIndex = primaryIndices.isNotEmpty
        ? primaryIndices.first
        : -1;
    final int anchorSecondaryIndex = secondaryIndices.isNotEmpty
        ? secondaryIndices.first
        : -1;
    final SubtitleOverlayEntry? anchorEntry = entries.isNotEmpty
        ? entries.first
        : null;
    final bool indicesChanged =
        !listEquals(primaryIndices, _currentSubtitleIndices) ||
        !listEquals(secondaryIndices, _currentSecondarySubtitleIndices);
    final bool entriesChanged = !_areSubtitleEntryListsEqual(
      entries,
      _currentSubtitleEntries,
    );
    final bool anchorChanged =
        anchorPrimaryIndex != _currentSubtitleIndex ||
        anchorSecondaryIndex != _currentSecondarySubtitleIndex;

    if (!indicesChanged && !entriesChanged && !anchorChanged) return;

    _currentSubtitleIndices = primaryIndices;
    _currentSecondarySubtitleIndices = secondaryIndices;
    _currentSubtitleEntries = entries;
    _currentSubtitleIndex = anchorPrimaryIndex;
    _currentSecondarySubtitleIndex = anchorSecondaryIndex;
    _currentSubtitleImage = anchorPrimaryIndex >= 0
        ? _currentSubtitleImages[anchorPrimaryIndex]
        : null;
    _currentSubtitleText = anchorEntry?.text ?? "";
    _currentSecondaryText = anchorEntry?.secondaryText;
    subtitleDisplayNotifier.value = SubtitleDisplayState(entries: entries);

    if (primaryIndices.isNotEmpty) {
      _loadSubtitleImages(primaryIndices);
    }
  }

  void _seekPlaybackPosition(
    Duration target, {
    bool syncSubtitleSidebar = false,
    String source = 'ui',
  }) {
    if (!_initialized || !_controller.value.isInitialized) return;
    final duration = _controller.value.duration;
    Duration clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (duration > Duration.zero && clamped > duration) clamped = duration;

    _subtitleSeekTimer?.cancel();
    _subtitleSeekTimer = null;
    if (syncSubtitleSidebar &&
        _activeSidebar == SidebarType.subtitles &&
        _isSubtitleSidebarVisible) {
      _subtitleSidebarKey.currentState?.locateToTime(clamped);
    }
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (playbackService.controller == _controller) {
        unawaited(
          NativePlaybackControlSession.seekOwned(
            service: playbackService,
            expectedController: _controller,
            position: clamped,
            source: source,
          ),
        );
      } else {
        _controller.seekTo(clamped);
      }
    } catch (_) {
      _controller.seekTo(clamped);
    }
    _holdAmbientFrameBriefly();
  }

  /// Keeps the letterbox matte on its last frame while a seek settles.
  /// Scrubbing holds it for the whole drag; this covers the seek after release
  /// and seeks that never go through the progress bar.
  void _holdAmbientFrameBriefly() {
    _ambientHoldTimer?.cancel();
    // Only the matte needs this hold. Rebuilding the page at seek start/end
    // competes with the transcript's first scrolling frames on Android.
    _ambientSeekHold.value = true;
    _ambientHoldTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      _ambientSeekHold.value = false;
    });
  }

  void _seekToSubtitleFast(Duration target) {
    _seekPlaybackPosition(target, source: 'subtitle_hop');
  }

  void _togglePlay() {
    unawaited(AppHaptics.lightTap(SettingsService()));
    MediaPlaybackService? playbackService;
    try {
      playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
    } catch (_) {}

    if (_isSourceMissing) {
      if (playbackService != null) {
        unawaited(playbackService.resume());
      }
      return;
    }

    // Session intent, not the lagging controller flag. A Windows cache-pause
    // sample can say "not playing" while audio is running; branching on that
    // called resume() and swallowed the pause.
    if (playbackService != null &&
        identical(playbackService.controller, _controller)) {
      if (playbackService.desiredPlaying) {
        unawaited(playbackService.pause());
      } else {
        unawaited(playbackService.resume());
      }
      return;
    }

    if (_controller.value.isPlaying) {
      unawaited(_controller.pause());
    } else {
      unawaited(_controller.play());
    }
  }

  bool _startLongPressSpeed() {
    if (_isSourceMissing) return false;
    // The raw two-finger transform listener and Flutter's long-press
    // recognizer use different arbitration paths. Resolve that race here:
    // an established multi-touch/transform session owns this pointer sequence,
    // while an established long-press locks transforms for the whole sequence.
    if (!_videoGestureSession.tryStartLongPress(
      transformActive: _isVideoTransformGestureActive,
      transformPointerCount: _activeVideoTransformPointers.length,
    )) {
      return false;
    }

    final settings = Provider.of<SettingsService>(context, listen: false);
    MediaPlaybackService? playbackService;
    try {
      final candidate = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (candidate.controller == _controller) playbackService = candidate;
    } catch (_) {}
    _longPressPlaybackService = playbackService;
    _preLongPressSpeed =
        playbackService?.confirmedPlaybackSpeed ??
        _controller.value.playbackSpeed;
    _activeVideoTransformPointers.clear();
    _isVideoTransformGestureActive = false;
    _isLongPressing = true;
    _longPressFeedbackText = "${settings.longPressSpeed}x";
    unawaited(
      playbackService?.beginTemporaryPlaybackSpeed(settings.longPressSpeed) ??
          _controller.setPlaybackSpeed(settings.longPressSpeed),
    );
    return true;
  }

  void _endLongPressSpeed() {
    if (!_isLongPressing) return;
    _videoGestureSession.endLongPress();
    _isLongPressing = false;
    _controlsKey.currentState?.cancelLongPressFeedback();
    final playbackService = _longPressPlaybackService;
    _longPressPlaybackService = null;
    unawaited(
      playbackService?.endTemporaryPlaybackSpeed() ??
          _controller.setPlaybackSpeed(_preLongPressSpeed),
    );
  }

  Future<void> _syncPlaybackSpeedToCurrentController(double speed) async {
    if (_isSourceMissing) return;
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (playbackService.controller == _controller) {
        await playbackService.setPlaybackSpeed(speed);
        return;
      }
    } catch (_) {}
    await _controller.setPlaybackSpeed(speed);
  }

  Future<void> _handlePlaybackSpeedSelected(double speed) async {
    await _syncPlaybackSpeedToCurrentController(speed);
  }

  Future<void> _handlePlaybackSpeedLockChanged(
    double speed,
    bool locked,
  ) async {
    if (_currentItem?.sourceRef?.podcast != null) {
      await PodcastPlaybackHooks.setSpeedDefault?.call(
        _currentItem!,
        speed,
        locked,
      );
      await _syncPlaybackSpeedToCurrentController(speed);
      return;
    }
    final settings = Provider.of<SettingsService>(context, listen: false);
    await settings.setPlaybackSpeedLock(speed, locked);
    await _syncPlaybackSpeedToCurrentController(speed);
  }

  Future<void> _pickSubtitle() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);

      final pickedSubtitle = await pickSubtitleFile(
        allowedExtensions: [
          'srt',
          'lrc',
          'vtt',
          'ass',
          'ssa',
          'sup',
          'sub',
          'idx',
          'scc',
        ],
      );

      if (!mounted) return;

      if (pickedSubtitle != null) {
        final path = pickedSubtitle.path;
        final shouldCacheSubtitle =
            settings.autoCacheSubtitles || pickedSubtitle.requiresPersistence;

        // Auto Cache Logic
        if (_currentItem != null) {
          // Preserve secondary subtitle if it exists
          String? currentSecondary;
          if (_currentSubtitlePaths.length > 1) {
            currentSecondary = _currentSubtitlePaths[1];
          }

          await library.updateVideoSubtitles(
            _currentItem!.id,
            path,
            shouldCacheSubtitle,
            secondarySubtitlePath: currentSecondary,
            isSecondaryCached: settings.autoCacheSubtitles,
          );
        }

        // Load with preservation of secondary
        final storedItem = _currentItem == null
            ? null
            : library.getVideo(_currentItem!.id);
        final pathsToLoad = <String>[storedItem?.subtitlePath ?? path];
        final storedSecondary = storedItem?.secondarySubtitlePath;
        if (storedSecondary != null && storedSecondary.isNotEmpty) {
          pathsToLoad.add(storedSecondary);
        }
        await _loadSubtitles(pathsToLoad);
      }
    } catch (e) {
      developer.log('Error picking subtitle', error: e);
    }
  }

  void _showSubtitleManager() {
    _openSidebar(SidebarType.subtitleManager);
    _userRequestedSubtitles = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeLoadSubtitlesForCurrentItem(force: true));
    });
  }

  final _subtitleSettingsKey = GlobalKey<SubtitleSettingsSheetState>();
  String? _fontSource(bool secondary) {
    final preview = _videoComposePreviewController.config;
    if (_subtitleStyleFromCompose &&
        _videoComposePreviewActive &&
        preview != null) {
      return secondary
          ? SubtitleFontService.instance.secondarySource(
              preview.primarySubtitlePath,
              preview.secondarySubtitlePath,
            )
          : preview.primarySubtitlePath;
    }
    final primary = _currentSubtitlePaths.isEmpty
        ? null
        : _currentSubtitlePaths.first;
    return secondary
        ? SubtitleFontService.instance.secondarySource(
            primary,
            _currentSubtitlePaths.length > 1 ? _currentSubtitlePaths[1] : null,
          )
        : primary;
  }

  String? _fontLanguage(bool secondary) {
    if (_subtitleStyleFromCompose && _videoComposePreviewActive) {
      return _videoComposePreviewController.fontLanguage(secondary);
    }
    final source = _fontSource(secondary);
    if (source == null) return null;
    final fonts = SubtitleFontService.instance;
    if (fonts.hasLanguageForSource(source)) {
      return fonts.languageForSource(source);
    }
    final items = secondary && _secondarySubtitles.isNotEmpty
        ? _secondarySubtitles
        : _subtitles;
    return fonts.languageForSource(
      source,
      label: _buildAvailableSubtitleMap()[source],
      texts: items.take(100).map((item) => item.text),
    );
  }

  String _subtitlePathKey(String path) {
    final normalized = p.normalize(path);
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  final Map<(String, String), Future<void>> _composePreparations = {};

  Future<Map<String, String>> _prepareComposeSubtitleOptions(
    VideoItem item,
  ) async {
    final navigationVersion = _sidebarNavigationVersion;
    if (!await _sidebarMotion.whenSettled() || !mounted) return const {};
    if (_currentItem?.id != item.id ||
        (navigationVersion != _sidebarNavigationVersion &&
            _activeSidebar != SidebarType.videoCompose &&
            !_sidebarHistory.contains(SidebarType.videoCompose))) {
      return const {};
    }
    final key = (item.id, item.path);
    _composePreparations.removeWhere((other, _) => other != key);
    final preparation = _composePreparations.putIfAbsent(
      key,
      () => _prepareEmbeddedSubtitlesForCompose(item),
    );
    try {
      await preparation;
    } catch (_) {
      _composePreparations.remove(key);
      rethrow;
    }
    if (!mounted ||
        _currentItem?.id != item.id ||
        _currentItem?.path != item.path) {
      return const {};
    }
    return _buildAvailableSubtitleMap();
  }

  Future<void> _prepareEmbeddedSubtitlesForCompose(VideoItem item) async {
    if (item.sourceRef?.kind == MediaSourceKind.bilibiliStream ||
        item.path.isEmpty) {
      return;
    }
    try {
      final embeddedService = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      final library = Provider.of<LibraryService>(context, listen: false);
      final tracks = await embeddedService.getEmbeddedSubtitles(item.path);
      if (tracks.isEmpty) return;
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        item.id,
        create: true,
      );
      for (final track in tracks) {
        final extractedPath = await embeddedService.extractSubtitle(
          item.path,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: item.id,
        );
        if (extractedPath == null || extractedPath.isEmpty) {
          continue;
        }
        await library.registerManagedSubtitleAsset(
          item.id,
          path: extractedPath,
          kind: ManagedSubtitleAssetKind.embedded,
          displayName: track.title,
        );
      }
    } catch (e) {
      debugPrint('Prepare embedded subtitles for compose failed: $e');
      rethrow;
    }
  }

  void _showVideoCompose() {
    _openSidebar(SidebarType.videoCompose);
  }

  void _showOcrSubtitle() {
    if (!_supportsOcrSubtitle || _currentItem == null || _isAudio) return;
    _openSidebar(SidebarType.ocrSubtitle);
  }

  void _showAiChat() {
    final item = _currentItem;
    if (item == null) return;
    _openSidebar(SidebarType.aiChat);
  }

  void _returnToSubtitleSidebar() {
    if (_usesBilibiliSidebarTabs) {
      _pickLandscapeBilibiliTab(PortraitBilibiliTab.subtitles);
      return;
    }
    unawaited(AppHaptics.lightTap(SettingsService()));
    setState(() {
      _sidebarNavigationVersion++;
      _resetSidebarEditing();
      _sidebarHistory.clear();
      _isSubtitleSidebarVisible = true;
      _bilibiliOpenedManually = false;
      _sidebarBaseOverride = SidebarType.subtitles;
      _activeSidebar = SidebarType.subtitles;
    });
    _syncSidebarNavigation();
    unawaited(SettingsService().saveLandscapeSubtitleSidebarVisible(true));
    _returnFocusToVideo();
  }

  void _toggleSubtitleSidebar() {
    final settings = context.read<SettingsService>();
    final opening =
        !_isSubtitleSidebarVisible ||
        (_activeSidebar != SidebarType.subtitles &&
            _activeSidebar != SidebarType.aiChat);
    unawaited(
      opening
          ? AppHaptics.sidebarOpened(settings)
          : AppHaptics.lightTap(settings),
    );
    setState(() {
      _sidebarNavigationVersion++;
      _resetSidebarEditing();
      _sidebarHistory.clear();
      _bilibiliOpenedManually = false;
      _showEpisodePicker = false;
      if (_isSubtitleSidebarVisible) {
        if (_activeSidebar == SidebarType.subtitles ||
            _activeSidebar == SidebarType.aiChat) {
          _isSubtitleSidebarVisible = false;
          _activeSidebar = _sidebarOf(_defaultTarget);
        } else {
          _activeSidebar = SidebarType.subtitles;
        }
      } else {
        _isSubtitleSidebarVisible = true;
        _activeSidebar = SidebarType.subtitles;
      }
      _sidebarBaseOverride = _activeSidebar == SidebarType.bilibili
          ? null
          : _activeSidebar;
    });
    unawaited(
      settings.saveLandscapeSubtitleSidebarVisible(_isSubtitleSidebarVisible),
    );
    _syncSidebarNavigation();
    _returnFocusToVideo();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isSubtitleSidebarVisible &&
          _activeSidebar == SidebarType.subtitles &&
          _showingSubtitleTab) {
        _requestSubtitleSidebarViewportRestore();
        _userRequestedSubtitles = true;
        unawaited(_maybeLoadSubtitlesForCurrentItem(force: true));
      }
    });
  }

  Future<void> _applyCompletedOcrSubtitles(List<String> paths) async {
    final item = _currentItem;
    if (item == null) return;
    final available = <String>[];
    for (final path in paths) {
      if (await File(path).exists()) available.add(path);
    }
    if (available.isEmpty) return;
    final primary = available.first;
    final secondary = available.length > 1
        ? available[1]
        : (_currentSubtitlePaths.length > 1
              ? _currentSubtitlePaths[1]
              : item.secondarySubtitlePath);
    await _loadSubtitles([primary, ?secondary]);
    if (!mounted || _currentItem?.id != item.id) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    await library.updateVideoSubtitles(
      item.id,
      primary,
      settings.autoCacheSubtitles,
      secondarySubtitlePath: secondary,
      isSecondaryCached: settings.autoCacheSubtitles,
    );
  }

  void _applyVideoComposePreview(VideoComposePreviewConfig config) {
    if (!mounted) return;
    if (!_videoComposePreviewActive) {
      setState(() => _videoComposePreviewActive = true);
    }
    unawaited(
      _videoComposePreviewController.configure(config).then((_) {
        if (_initialized && _controllerAssigned) {
          _videoComposePreviewController.update(_controller.value.position);
        }
      }),
    );
  }

  void _clearVideoComposePreview() {
    _videoComposePreviewController.clear();
    if (mounted && _videoComposePreviewActive) {
      setState(() => _videoComposePreviewActive = false);
    } else {
      _videoComposePreviewActive = false;
    }
  }

  Future<void> _loadSubtitles(
    List<String> paths, {
    bool autoEnableSubtitles = true,
    bool userInitiated = true,
  }) async {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );

    final String? itemIdAtStart = _currentItem?.id;

    if (mounted) {
      setState(() {
        _isParsingSubtitles = true;
      });
    } else {
      _isParsingSubtitles = true;
    }

    try {
      if (itemIdAtStart == null) return;
      final bool committed = await playbackService
          .loadSubtitlePathsForCurrentItem(
            itemId: itemIdAtStart,
            paths: paths,
            userInitiated: userInitiated,
          );
      if (!committed || !mounted || _currentItem?.id != itemIdAtStart) {
        return;
      }

      final primaryList = List<SubtitleItem>.from(playbackService.subtitles);
      final secondaryList = List<SubtitleItem>.from(
        playbackService.secondarySubtitles,
      );

      setState(() {
        _subtitleRevision = playbackService.subtitleRevision;
        _suppressAutoEmbeddedForCurrentItem = paths.isEmpty;
        _subtitles = primaryList;
        _secondarySubtitles = secondaryList;
        _currentSubtitlePaths = List<String>.from(
          playbackService.subtitlePaths,
        );
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleImage = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
        subtitleDisplayNotifier.value = SubtitleDisplayState.empty;
      });
      _rebuildSubtitleIndex();

      if (autoEnableSubtitles &&
          (primaryList.isNotEmpty || secondaryList.isNotEmpty)) {
        final currentItem = _currentItem;
        if (currentItem != null) {
          // Keep the per-item snapshot aligned with the persisted global toggle
          // without overriding the user's current floating subtitle preference.
          _applyItemSubtitlePreference(currentItem, force: true);
        }
      }
      _updateSubtitle();
      _triggerSubtitleRefreshBurst();
    } finally {
      if (!mounted) {
        _isParsingSubtitles = false;
      } else {
        setState(() {
          _isParsingSubtitles = false;
        });
      }
    }
  }

  void _rebuildSubtitleIndex() {
    _subtitleTimeline = SubtitleTimelineResolver(_subtitles);
    _secondarySubtitleTimeline = SubtitleTimelineResolver(_secondarySubtitles);
  }

  void _pruneSubtitleImages(Set<int> keepIndices) {
    if (_currentSubtitleImages.isEmpty) return;
    final keysToRemove = _currentSubtitleImages.keys
        .where((k) => !keepIndices.contains(k))
        .toList();
    for (final key in keysToRemove) {
      _currentSubtitleImages.remove(key);
    }
  }

  bool _areSubtitleEntryListsEqual(
    List<SubtitleOverlayEntry> a,
    List<SubtitleOverlayEntry> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final entryA = a[i];
      final entryB = b[i];
      if (entryA.index != entryB.index) return false;
      if (entryA.text != entryB.text) return false;
      if (entryA.secondaryText != entryB.secondaryText) return false;
      final bool hasImageA = entryA.image != null;
      final bool hasImageB = entryB.image != null;
      if (hasImageA != hasImageB) return false;
    }
    return true;
  }

  void _loadSubtitleImages(List<int> indices) {
    final Set<int> indexSet = indices.toSet();
    _pruneSubtitleImages(indexSet);
    if (indexSet.isEmpty) return;

    final int requestId = ++_subtitleImageRequestId;
    for (final int index in indexSet) {
      final SubtitleItem item = _subtitles[index];
      final imageLoader = item.imageLoader;
      if (imageLoader == null) continue;
      if (_currentSubtitleImages.containsKey(index)) continue;

      imageLoader().then((image) {
        if (!mounted) return;
        if (requestId != _subtitleImageRequestId) return;
        if (!indexSet.contains(index)) return;

        _currentSubtitleImages[index] = image;
        _currentSubtitleEntries = _currentSubtitleEntries
            .map(
              (entry) => entry.index == index
                  ? SubtitleOverlayEntry(
                      sourcePath: _fontSource(false),
                      secondarySourcePath: _fontSource(true),
                      language: _fontLanguage(false),
                      secondaryLanguage: _fontLanguage(true),
                      index: entry.index,
                      text: entry.text,
                      secondaryText: entry.secondaryText,
                      image: image,
                    )
                  : entry,
            )
            .toList();
        if (_currentSubtitleIndex == index) {
          _currentSubtitleImage = image;
        }
        subtitleDisplayNotifier.value = SubtitleDisplayState(
          entries: _currentSubtitleEntries,
        );
      });
    }
  }

  void _bindSubtitlePositions() {
    _subtitlePositions.onCommit = (target, placement) async {
      if (!mounted) return;
      final settings =
          _settingsService ??
          Provider.of<SettingsService>(context, listen: false);
      final result = await commitPlayerSubtitlePosition(
        settings: settings,
        target: target,
        placement: placement,
      );
      if (mounted) {
        setState(
          () => _subtitlePositionError = result.ok ? null : '字幕位置尚未保存，请再次拖动重试。',
        );
      }
    };
  }

  SubtitlePositionTarget _subtitleTarget({required bool ghost}) {
    return SubtitlePositionTarget.resolve(
      ghost: ghost,
      audio: _isAudio,
      presetId: SubtitleDebugSession.instance.preset?.id,
    );
  }

  void _claimSubtitlePointer(int pointer) {
    SubtitleDragPointerOwner.claim(pointer);
    _activeVideoTransformPointers.remove(pointer);
    if (_isVideoTransformGestureActive &&
        _activeVideoTransformPointers.length < 2) {
      _endVideoTransformGesture();
    }
  }

  // --- Drag Logic ---
  void _enterSubtitleDragMode() {
    final settings = Provider.of<SettingsService>(context, listen: false);
    if (!settings.showSubtitles || _suppressSubtitleOverlayForOcr) {
      return;
    }
    if (_activeSidebar == SidebarType.subtitlePosition) {
      _exitSubtitleDragMode();
      return;
    }
    _openSidebar(SidebarType.subtitlePosition);
    _subtitlePositions.beginEditing(_subtitleTarget(ghost: false));
    setState(() {
      _isSubtitleDragMode = true;
      _isGhostDragMode = false;
      _activeSidebar = SidebarType.subtitlePosition;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _enterGhostDragMode() {
    if (_activeSidebar == SidebarType.subtitlePosition) {
      _exitSubtitleDragMode();
      return;
    }
    _openSidebar(SidebarType.subtitlePosition);
    _subtitlePositions.beginEditing(_subtitleTarget(ghost: true));
    setState(() {
      _isGhostDragMode = true;
      _isSubtitleDragMode = false;
      _activeSidebar = SidebarType.subtitlePosition;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _exitSubtitleDragMode() {
    _closeSidebar();
  }

  void _enableStyleSidebarDragMode({required bool isGhost}) {
    _subtitlePositions.beginEditing(_subtitleTarget(ghost: isGhost));
    setState(() {
      _isStyleSidebarDragMode = true;
      _isSubtitleDragMode = !isGhost;
      _isGhostDragMode = isGhost;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  bool _subtitleStyleFromCompose = false;

  void _toggleFloatingSubtitleSettingsSidebar() {
    _openSidebar(SidebarType.subtitleStyle);
  }

  Future<void> _nudgeSubtitleAlignment(Alignment align, {required bool ghost}) {
    final settings = Provider.of<SettingsService>(context, listen: false);
    return commitPlayerSubtitlePosition(
      settings: settings,
      target: _subtitleTarget(ghost: ghost),
      placement: CustomAlignmentPlacement.clamped(align),
    );
  }

  Future<void> _handleBackRequest() async {
    _sidebarNavigationVersion++;
    if (_forceExit) {
      await _returnToPortrait();
      return;
    }

    if (_showEpisodePicker) {
      setState(() => _showEpisodePicker = false);
      _returnFocusToVideo();
      return;
    }

    if (MediaQuery.viewInsetsOf(context).bottom > 0 &&
        FocusManager.instance.primaryFocus?.hasFocus == true) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }

    if (_isSidebarOpen &&
        _activeSidebar == SidebarType.subtitleStyle &&
        (_subtitleSettingsKey.currentState?.handleBack() ?? false)) {
      return;
    }

    if (_isRepairing) return;

    if ((_isSubtitleDragMode || _isGhostDragMode) && !_isStyleSidebarDragMode) {
      _exitSubtitleDragMode();
      return;
    }

    if (_isSidebarOpen) {
      if (!mounted) return;
      if (_usesBilibiliSidebarTabs &&
          _activeSidebar == SidebarType.subtitles &&
          _bilibiliOpenedManually) {
        _toggleSubtitleSidebar();
        return;
      }
      if (_activeSidebar == SidebarType.bilibili &&
          (_bilibiliPanelOverVideo || _bilibiliOpenedManually)) {
        _collapseBilibiliPanel();
        return;
      }
      if (_activeSidebar != SidebarType.subtitles &&
          _activeSidebar != SidebarType.bilibili) {
        _closeSidebar();
        return;
      }
    }

    if (await PlaybackNavigationService.instance
        .exitWindowFullScreenIfNeeded()) {
      _returnFocusToVideo();
      return;
    }
    if (!mounted) return;
    if (await PlaybackNavigationService.instance.returnToBrowseOrigin(
      context.read<MediaPlaybackService>(),
      context.read<PlaylistManager>(),
    )) {
      return;
    }
    if (!mounted) return;
    await _returnToPortrait();
  }

  double _effectiveVideoAspectRatio() {
    final bilibili =
        _currentItem?.sourceRef?.kind == MediaSourceKind.bilibiliStream;
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (bilibili) {
        return playbackService.bilibiliVideoAspectRatioFor(
              _currentItem!.id,
              controller: _controllerAssigned ? _controller : null,
            ) ??
            16 / 9;
      }
    } catch (_) {}
    if (bilibili) return 16 / 9;
    if (_controllerAssigned) {
      try {
        if (_controller.value.isInitialized &&
            !_controller.value.hasError &&
            _controller.value.aspectRatio > 0) {
          return _controller.value.aspectRatio;
        }
      } catch (_) {}
    }
    return 16 / 9;
  }

  void _onIosBackSwipeStart(DragStartDetails details) {
    if (!Platform.isIOS) return;
    _iosBackSwipeActive = true;
    _iosBackSwipeDistance = 0.0;
  }

  void _onIosBackSwipeUpdate(DragUpdateDetails details) {
    if (!_iosBackSwipeActive) return;
    _iosBackSwipeDistance += details.delta.dx;
    if (_iosBackSwipeDistance >= _iosBackSwipeTriggerDistance) {
      _iosBackSwipeActive = false;
      _iosBackSwipeDistance = 0.0;
      _handleBackRequest();
    }
  }

  void _onIosBackSwipeEnd(DragEndDetails details) {
    _iosBackSwipeActive = false;
    _iosBackSwipeDistance = 0.0;
  }

  Future<void> _cancelPendingPlaybackIfNeeded() async {
    if (_controllerAssigned || _initialized) {
      return;
    }
    final currentItem = _currentItem;
    if (currentItem == null) {
      return;
    }
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    await playbackService.cancelPendingPlay(
      expectedItemId: currentItem.id,
      keepBookmark: true,
    );
  }

  Widget _buildLoadingState(BuildContext context) {
    final thumbnailPath = _currentItem?.thumbnailPath;
    final bool hasThumbnail =
        thumbnailPath != null && File(thumbnailPath).existsSync();
    // Promoted copy: [hasThumbnail] does not promote [thumbnailPath].
    final String? posterPath = hasThumbnail ? thumbnailPath : null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_videoFocusNode.canRequestFocus) {
          _videoFocusNode.requestFocus();
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          if (_isCurrentBilibiliOnlineStream)
            BilibiliVideoPosterSlot(
              geometry: MediaPlaybackService(),
              aspectRatioOf: _effectiveVideoAspectRatio,
              aspectRatio: _effectiveVideoAspectRatio(),
              child: _buildVisibleVideoFrameCover(),
            )
          else if (posterPath != null)
            BilibiliVideoPosterSlot(
              aspectRatio: _effectiveVideoAspectRatio(),
              child: Image.file(
                File(posterPath),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: Colors.black),
              ),
            ),
          // Local files keep a light dim so the spinner reads on a bright
          // poster. Online Bilibili loading must not cover the frame.
          if (!_isCurrentBilibiliOnlineStream)
            const DecoratedBox(
              decoration: BoxDecoration(color: Color(0x66000000)),
            ),
          if (!_isCurrentBilibiliOnlineStream)
            Center(
              child: SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white.withValues(alpha: 0.8),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Consume SettingsService
    return Consumer<SettingsService>(
      builder: (context, settings, child) {
        final bool isLeftHandedMode = settings.isLeftHandedMode;
        // Capture the whole window before SafeArea and sidebar allocation.
        // Keyboard insets only move the player; they do not resize ghost text.
        final Size? subtitlePageSize = MediaQuery.maybeSizeOf(context);
        final EdgeInsets viewPadding =
            MediaQuery.maybeViewPaddingOf(context) ?? EdgeInsets.zero;
        final EdgeInsets gestureInsets =
            MediaQuery.maybeSystemGestureInsetsOf(context) ?? EdgeInsets.zero;
        // Some Android landscape devices report the navigation gesture strip
        // only through systemGestureInsets. Respect both sources so the strip
        // cannot cover article text or intercept the paragraph-mode switch.
        final EdgeInsets sidebarSafePadding =
            resolveLandscapeSidebarSafePadding(
              viewPadding: viewPadding,
              systemGestureInsets: gestureInsets,
              isLeftHandedMode: isLeftHandedMode,
            );
        final sidebarBackgroundColor = _activeSidebar == SidebarType.aiChat
            ? AppTokens.bgBase
            : AppTokens.bgPlayerSidebar;
        final Widget sidebarResizer = SizedBox(
          width: _subtitleSidebarResizerLayoutWidth,
          child: PlayerSidebarResizeIndicator(
            hovered: _sidebarResizeHovered,
            resizing: _isResizingSidebar,
            backgroundColor: sidebarBackgroundColor,
          ),
        );
        // 缓存 sidebarWidth，避免单次 build 调用 3 次 _getSidebarWidth
        final double sidebarWidth = _getSidebarWidth(context, settings);
        final isDesktop =
            !kIsWeb &&
            (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
        // On a phone the Bilibili panel goes over the video, not beside it.
        final bool bilibiliOverVideo = !isDesktop && _bilibiliPanelOverVideo;
        final bool sidebarDocked = _isSidebarOpen && !bilibiliOverVideo;
        final bool showResizer =
            _isSidebarOpen &&
            (_activeSidebar == SidebarType.subtitles ||
                _activeSidebar == SidebarType.subtitleEditor ||
                _activeSidebar == SidebarType.aiChat);
        final double resizableSidebarWidth = _clampResizableSidebarWidth(
          context,
          _subtitleSidebarWidthOverride ?? settings.userSubtitleSidebarWidth,
        );

        Widget sidebarContent(Widget content, {bool avoidKeyboard = false}) =>
            Padding(
              key: const ValueKey('player-sidebar-safe-padding'),
              padding: sidebarSafePadding,
              child: MediaQueryPaddingRemover(
                left: true,
                right: true,
                child: AiKeyboardViewport(
                  enabled: avoidKeyboard,
                  reservedBottomInset: sidebarSafePadding.bottom,
                  child: content,
                ),
              ),
            );
        final sidebarViewport = MediaQuery.sizeOf(context);
        if (_activeSidebar == SidebarType.subtitles ||
            _activeSidebar == SidebarType.aiChat) {
          _readingSurface = _activeSidebar == SidebarType.aiChat
              ? PlayerSidebarMotion.chatSurface
              : PlayerSidebarMotion.subtitleSurface;
        }
        final dockId = sidebarDocked
            ? (_activeSidebar == SidebarType.aiChat
                  ? SidebarType.subtitles
                  : _activeSidebar)
            : null;
        final dockExtent = sidebarDocked
            ? sidebarWidth +
                  (showResizer ? _subtitleSidebarResizerLayoutWidth : 0)
            : 0.0;
        final targetPlayerWidth = math.max(
          0.0,
          sidebarViewport.width - dockExtent,
        );
        _sidebarMotion.configure(
          target: _activeSidebar == SidebarType.none ? null : _activeSidebar,
          dockExtent: dockExtent,
          visibleSurfaces: {
            ?dockId,
            _readingSurface,
            if (bilibiliOverVideo) PlayerSidebarMotion.overlaySurface,
          },
          immediate:
              _isResizingSidebar ||
              MediaQuery.disableAnimationsOf(context) ||
              (_sidebarMotionViewport != null &&
                  _sidebarMotionViewport != sidebarViewport),
        );
        _sidebarMotionViewport = sidebarViewport;
        // Seek/position notifications do not change episode
        // navigation. Watching the whole service here rebuilds
        // the video and every control during transcript motion.
        final episodeNavigation = context
            .select<MediaPlaybackService, ({bool previous, bool next})>(
              (service) => (
                previous: service.hasPlayablePrevious,
                next: service.hasPlayableNext,
              ),
            );
        // Ghost Mode Logic
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final canEditGhostStyle = _canUseGhostSidebarEditing(context, settings);
        final presetGhostMove = _presetGhostMoveActive(context, settings);
        final isGhostActive =
            !_subtitleStyleFromCompose &&
            (presetGhostMove ||
                (canEditGhostStyle &&
                    ((_activeSidebar == SidebarType.subtitles) ||
                        _activeSidebar == SidebarType.aiChat ||
                        _isGhostDragMode ||
                        _activeSidebar == SidebarType.subtitleStyle)));
        final SubtitleStyle activeSubtitleStyle = _isAudio
            ? (isLandscape
                  ? settings.audioSubtitleStyleLandscape
                  : settings.audioSubtitleStylePortrait)
            : (isLandscape
                  ? settings.subtitleStyleLandscape
                  : settings.subtitleStylePortrait);
        final Widget playbackControls =
            _fatalErrorMessage == null &&
                shouldMountPlaybackControls(
                  initialized: _initialized,
                  controllerAssigned: _controllerAssigned,
                  sourceMissing: _isSourceMissing,
                  subtitleDragActive: _isSubtitleDragMode,
                  ghostDragActive: _isGhostDragMode,
                )
            ? RepaintBoundary(
                child: VideoControlsOverlay(
                  key: _controlsKey,
                  layoutWidth: targetPlayerWidth,
                  isPreparing: !_initialized && !_isSourceMissing,
                  mediaItemId: _currentItem?.id,
                  initialDuration: Duration(
                    milliseconds: _currentItem?.durationMs ?? 0,
                  ),
                  initialPosition: Duration(
                    milliseconds: _currentItem?.lastPositionMs ?? 0,
                  ),
                  reserveQualityControl:
                      !_isAudio &&
                      (_isCurrentBilibiliOnlineStream ||
                          isCloudDriveMedia(
                            source: _currentItem?.sourceRef,
                            path: _currentItem?.path ?? '',
                          )),
                  enableSeekThumbnailPreview: decideSeekPreview(
                    audio: _isAudio,
                    bilibili:
                        _currentItem?.sourceRef?.kind ==
                        MediaSourceKind.bilibiliStream,
                    bilibiliSpritesReady:
                        _currentItem?.bilibiliVideoShot?.hasLocalSprites ==
                        true,
                    cloudDrive: isCloudDriveMedia(
                      source: _currentItem?.sourceRef,
                      path: _currentItem?.path ?? '',
                    ),
                    cloudLocalFramesReady:
                        CloudDriveRuntime.instance?.materialization
                            ?.readyLocalVideoPath(_currentItem?.id ?? '') !=
                        null,
                  ).showsImage,
                  localSeekPreviewPath:
                      decideSeekPreview(
                        audio: _isAudio,
                        bilibili:
                            _currentItem?.sourceRef?.kind ==
                            MediaSourceKind.bilibiliStream,
                        bilibiliSpritesReady:
                            _currentItem?.bilibiliVideoShot?.hasLocalSprites ==
                            true,
                        cloudDrive: isCloudDriveMedia(
                          source: _currentItem?.sourceRef,
                          path: _currentItem?.path ?? '',
                        ),
                        cloudLocalFramesReady: false,
                      ).showsImage
                      ? CloudDriveRuntime.instance?.materialization
                            ?.readyLocalVideoPath(_currentItem?.id ?? '')
                      : null,
                  bilibiliVideoShot:
                      _currentItem?.bilibiliVideoShot?.hasLocalSprites == true
                      ? _currentItem!.bilibiliVideoShot
                      : null,
                  showBufferedProgress:
                      _currentItem?.sourceRef?.kind ==
                      MediaSourceKind.bilibiliStream,
                  playbackControlsVisibility: _playbackControlsVisibility,
                  initialShowControls: _playbackChromeVisible,
                  onControlsVisibilityIntent: (visible) {
                    _playbackChromeVisible = visible;
                  },
                  controller: _pageControllerIsCurrent ? _controller : null,
                  isLocked: _isLocked,
                  onTogglePlay: _togglePlay,
                  onBackPressed: () => _handleBackRequest(),
                  onSeekTo: (position) {
                    _seekPlaybackPosition(position);
                  },
                  onProgressScrubbingChanged: (dragging) {
                    if (!mounted) return;
                    setState(() => _ambientScrubbing = dragging);
                    if (!dragging) {
                      _holdAmbientFrameBriefly();
                    }
                  },
                  onHopSeekTo: (position) {
                    _seekPlaybackPosition(position, source: 'subtitle_hop');
                  },
                  onExitPressed: () async {
                    await _forceExitPlayer();
                  },
                  onOpenSettings: () => _openSidebar(SidebarType.settings),
                  onOpenSleepTimer: () =>
                      unawaited(showSleepTimerDialog(context)),
                  onOpenSubtitleManager: _showSubtitleManager,
                  onOpenSubtitleEditor: _showSubtitleEditor,
                  showSubtitleEditorButton:
                      kIsWeb || !(Platform.isAndroid || Platform.isIOS),
                  onOpenVideoCompose: _showVideoCompose,
                  onOpenOcrSubtitle: _supportsOcrSubtitle && !_isAudio
                      ? _showOcrSubtitle
                      : null,
                  ocrUnavailableReason: _isAudio
                      ? '音频没有画面，请使用语音转录生成字幕。'
                      : !_supportsOcrSubtitle
                      ? '当前平台暂不支持识别画面字幕。'
                      : null,
                  onOpenAiChat: _currentItem == null ? null : _showAiChat,
                  aiChatOpen: _activeSidebar == SidebarType.aiChat,
                  onToggleBilibiliPanel: _isBilibiliVideo
                      ? _toggleBilibiliPanel
                      : null,
                  bilibiliPanelOpen:
                      _activeSidebar == SidebarType.bilibili ||
                      _usesBilibiliSidebarTabs &&
                          _activeSidebar == SidebarType.subtitles &&
                          _landscapeBilibiliTab == PortraitBilibiliTab.details,
                  usesBilibiliSidebarTabs: _usesBilibiliSidebarTabs,
                  onToggleFloatingSubtitleSettings:
                      _toggleFloatingSubtitleSettingsSidebar,
                  onToggleSidebar: _toggleSubtitleSidebar,
                  isSubtitleSidebarVisible:
                      _activeSidebar == SidebarType.subtitles ||
                      _activeSidebar == SidebarType.aiChat,
                  onToggleFullScreen: () => settings.toggleFullScreen(),
                  onToggleLock: () => _setScreenLock(!_isLocked),
                  showDanmakuControls: _currentItem?.isBilibiliExported == true,
                  danmakuEnabled: settings.showBilibiliDanmaku,
                  onToggleDanmaku: () => unawaited(
                    settings.saveShowBilibiliDanmaku(
                      !settings.showBilibiliDanmaku,
                    ),
                  ),
                  onOpenDanmakuSettings: () => unawaited(
                    showDanmakuSettingsDialog(
                      context,
                      initialMode: DanmakuPresentationMode.landscape,
                      videoItem: _currentItem!,
                      onDanmakuUpdated: () {
                        if (mounted) {
                          setState(() => _danmakuRevision++);
                        }
                      },
                    ),
                  ),
                  onSpeedUpdate: _handlePlaybackSpeedSelected,
                  doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
                  enableDoubleTapSubtitleSeek:
                      settings.enableDoubleTapSubtitleSeek,
                  subtitles: _subtitles,
                  longPressSpeed: settings.longPressSpeed,
                  showSubtitles: settings.showSubtitles,
                  suppressSubtitleOverlay: _suppressSubtitleOverlayForOcr,
                  onToggleSubtitles: () =>
                      _setFloatingSubtitles(!settings.showSubtitles),
                  onMoveSubtitles: () {
                    final useGhostDrag = _canUseGhostSidebarEditing(
                      context,
                      settings,
                    );
                    if (useGhostDrag) {
                      _enterGhostDragMode();
                    } else {
                      _enterSubtitleDragMode();
                    }
                  },
                  isLongPressing: _isLongPressing,
                  longPressFeedbackText: _longPressFeedbackText,
                  onLongPressStart: _startLongPressSpeed,
                  onLongPressEnd: _endLongPressSpeed,
                  subtitleEntries: _currentSubtitleEntries,
                  subtitleStyle: activeSubtitleStyle,
                  subtitleAlignment: _isAudio
                      ? settings.audioSubtitleAlignment
                      : settings.subtitleAlignment,
                  onEnterSubtitleDragMode: _enterSubtitleDragMode,
                  onClearSelection: () => _selectionKey
                      .currentState
                      ?.selectableRegion
                      .clearSelection(),
                  onToggleEpisodePicker: () => setState(() {
                    _sidebarNavigationVersion++;
                    _showEpisodePicker = !_showEpisodePicker;
                  }),
                  focusNode: _videoFocusNode,
                  onPlayPrevious: () => Provider.of<MediaPlaybackService>(
                    context,
                    listen: false,
                  ).playPrevious(),
                  onPlayNext: () => Provider.of<MediaPlaybackService>(
                    context,
                    listen: false,
                  ).playNext(),
                  hasPrevious: episodeNavigation.previous,
                  hasNext: episodeNavigation.next,
                  mediaTitle: _currentItem?.title ?? '',
                  chapters: _currentItem?.chapters ?? const <MediaChapter>[],
                  onOpenChapters: _currentItem?.chapters.isNotEmpty == true
                      ? _toggleChapterSidebar
                      : null,
                  isChapterSidebarVisible:
                      _activeSidebar == SidebarType.chapters,
                  onExperimentalTrigger: _navigateToMusicPlayer,
                  showResetScreenButton: !_isAudio && _hasCustomVideoTransform,
                  onResetScreenTransform: () => _resetVideoUserTransform(),
                  // blocksTransforms can outlive the fingers
                  // that created it. It only has to keep a
                  // leftover finger from pinching; feeding it
                  // into the overlay also disabled swipe-seek
                  // and tapping the controls back on.
                  suppressPrimaryGestures: _isVideoTransformGestureActive,
                  allowPlayWhenUninitialized: _isSourceMissing,
                ),
              )
            : const SizedBox.shrink();
        final danmakuContent = _buildDanmakuContent(
          settings,
          math.max(
            0.0,
            sidebarViewport.height - MediaQuery.paddingOf(context).top,
          ),
        );
        final List<Widget> sidebarWidgets = [
          DesktopPlayerSidebar(
            motion: _sidebarMotion,
            // Scroll history belongs to one media item, not the next
            // episode played in this same page instance.
            key: ValueKey(('landscape-player-sidebar', _currentItem?.id)),
            panelId: sidebarDocked
                ? (_activeSidebar == SidebarType.aiChat
                      ? SidebarType.subtitles
                      : _activeSidebar)
                : null,
            panel:
                _activeSidebar == SidebarType.subtitles ||
                    _activeSidebar == SidebarType.aiChat ||
                    !sidebarDocked
                ? null
                : sidebarContent(
                    _activeSidebar == SidebarType.chapters
                        ? (_buildSidebarContent(settings) ??
                              const SizedBox.shrink())
                        : LandscapeSidebarTheme(
                            child:
                                _buildSidebarContent(settings) ??
                                const SizedBox.shrink(),
                          ),
                    avoidKeyboard: _activeSidebar == SidebarType.aiChat,
                  ),
            width: sidebarWidth,
            retainedId: SidebarType.subtitles,
            returnPanelIds: _sidebarHistory.panels.toSet(),
            retainedPanel: sidebarContent(
              _buildSidebarContent(settings, panelType: SidebarType.subtitles)!,
              avoidKeyboard: _activeSidebar == SidebarType.aiChat,
            ),
            retainedWidth: resizableSidebarWidth,
            viewportSize: MediaQuery.sizeOf(context),
            divider: showResizer ? sidebarResizer : null,
            dividerWidth: showResizer ? _subtitleSidebarResizerLayoutWidth : 0,
            onLeft: isLeftHandedMode,
            resizing: _isResizingSidebar,
            dividerLink: _sidebarDividerLink,
            backgroundColor: showResizer
                ? sidebarBackgroundColor
                : Colors.black,
          ),
        ];
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            _handleBackRequest();
          },
          child: Focus(
            focusNode: _playbackPageFocusNode,
            onKeyEvent: (node, event) =>
                _controlsKey.currentState?.handleKeyEvent(node, event) ??
                KeyEventResult.ignored,
            child: Scaffold(
              key: _scaffoldKey,
              backgroundColor: Colors.black,
              resizeToAvoidBottomInset: false,
              body: SelectionArea(
                key: _selectionKey,
                focusNode: _selectionFocusNode,
                onSelectionChanged: (selection) => _hasPageTextSelection =
                    selection != null && selection.plainText.isNotEmpty,
                child: GestureDetector(
                  onTap: () {
                    // 点击空白区域取消文字选择，仅清除选择焦点，
                    // 不调用 unfocus() 避免清除视频控制焦点的键盘快捷键
                    _selectionKey.currentState?.selectableRegion
                        .clearSelection();
                    _subtitleSidebarKey.currentState?.clearTextSelection();
                    _selectionFocusNode.unfocus();
                    // 恢复焦点到视频控制 FocusNode，确保快捷键持续可用。
                    // 点在输入框或推荐语句上时，焦点要留给输入框，Enter 才能发送。
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted || !_videoFocusNode.canRequestFocus) return;
                      final focusContext =
                          FocusManager.instance.primaryFocus?.context;
                      final isEditingText =
                          focusContext?.widget is EditableText ||
                          focusContext
                                  ?.findAncestorWidgetOfExactType<
                                    EditableText
                                  >() !=
                              null;
                      if (isEditingText) return;
                      _videoFocusNode.requestFocus();
                    });
                  },
                  behavior: HitTestBehavior.translucent,
                  child: SafeArea(
                    top: true,
                    bottom: false,
                    left: false,
                    right: false,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Row(
                          children: [
                            if (isLeftHandedMode) ...sidebarWidgets,
                            Expanded(
                              key: const ValueKey('landscape-player-surface'),
                              child: ValueListenableBuilder<double>(
                                valueListenable: _keyboardInsetBottom,
                                builder: (context, keyboardInsetBottom, child) {
                                  return Transform.translate(
                                    offset: Offset(
                                      0,
                                      _resolveVideoKeyboardShift(
                                        keyboardInsetBottom,
                                      ),
                                    ),
                                    child: child,
                                  );
                                },
                                child: LayoutBuilder(
                                  builder: (context, screenConstraints) {
                                    final Size playerSurfaceSize = Size(
                                      screenConstraints.maxWidth,
                                      screenConstraints.maxHeight,
                                    );
                                    final Rect videoViewportRect =
                                        Rect.fromLTWH(
                                          0,
                                          0,
                                          playerSurfaceSize.width,
                                          playerSurfaceSize.height,
                                        );
                                    _lastVideoViewportRect = videoViewportRect;
                                    // 守卫：当从 MediaPlaybackService 异步加载视频时，
                                    // _initVideo 会在 service 处于 loading 时提前 return，
                                    // 不给 _controller（late 变量）赋值。此时访问
                                    // _controller.value 会抛 LateInitializationError，
                                    // 在 Release 下 ErrorWidget 渲染为空白 → 白屏。
                                    // 加载期间用 16:9 占位（此时仅渲染 loading 态，不渲染视频）。
                                    final double videoAspectRatio =
                                        _effectiveVideoAspectRatio();
                                    final Size containedVideoSize =
                                        _computeContainedVideoSize(
                                          playerSurfaceSize,
                                          videoAspectRatio,
                                        );
                                    // The texture id is the media_kit player key. video_player only
                                    // exposes it for tests and for adapters that own that player.
                                    final int? ambientPlayerId =
                                        _controllerAssigned
                                        // ignore: invalid_use_of_visible_for_testing_member
                                        ? _controller.playerId
                                        : null;
                                    final PlayerControlMetrics
                                    playbackControlMetrics =
                                        PlayerControlMetrics.fromSize(
                                          playerSurfaceSize,
                                          safeBottom:
                                              MediaQuery.maybePaddingOf(
                                                context,
                                              )?.bottom ??
                                              0,
                                        );
                                    final double controlsClearance =
                                        subtitlePlaybackControlsClearance(
                                          playerSurfaceSize.height,
                                        );
                                    final double videoViewportTop =
                                        (playerSurfaceSize.height -
                                            containedVideoSize.height) /
                                        2;
                                    final double videoViewportLeft =
                                        (playerSurfaceSize.width -
                                            containedVideoSize.width) /
                                        2;
                                    List<Rect> playerPlaybackControlRects() =>
                                        _playbackControlAvoidanceRects(
                                          context: context,
                                          playerSize: playerSurfaceSize,
                                          metrics: playbackControlMetrics,
                                          clearance: controlsClearance,
                                        );
                                    List<Rect> videoPlaybackControlRects() =>
                                        playerPlaybackControlRects()
                                            .map(
                                              (rect) => rect.translate(
                                                -videoViewportLeft,
                                                -videoViewportTop,
                                              ),
                                            )
                                            .toList(growable: false);

                                    return Listener(
                                      behavior: HitTestBehavior.translucent,
                                      onPointerDown:
                                          _handleVideoTransformPointerDown,
                                      onPointerMove:
                                          _handleVideoTransformPointerMove,
                                      onPointerUp: (event) =>
                                          _handleVideoTransformPointerEnd(
                                            event.pointer,
                                          ),
                                      onPointerCancel: (event) =>
                                          _handleVideoTransformPointerEnd(
                                            event.pointer,
                                          ),
                                      child: Stack(
                                        alignment: Alignment.center,
                                        children: [
                                          Positioned.fill(
                                            child: Align(
                                              alignment: isLeftHandedMode
                                                  ? Alignment.centerLeft
                                                  : Alignment.centerRight,
                                              child: CompositedTransformTarget(
                                                link: _sidebarToggleLink,
                                                child: const SizedBox.shrink(),
                                              ),
                                            ),
                                          ),
                                          // 1. Video Layer
                                          Center(
                                            child: _isSourceMissing
                                                ? MissingLocalSourcePanel(
                                                    item: _currentItem,
                                                    fontSize: 20,
                                                  )
                                                : _fatalErrorMessage != null &&
                                                      _isCurrentBilibiliOnlineStream &&
                                                      MediaPlaybackService()
                                                              .bilibiliStartup
                                                              ?.hasFailed ==
                                                          true
                                                ? BilibiliVideoPosterSlot(
                                                    geometry:
                                                        MediaPlaybackService(),
                                                    aspectRatioOf:
                                                        _effectiveVideoAspectRatio,
                                                    aspectRatio:
                                                        _effectiveVideoAspectRatio(),
                                                    child:
                                                        _buildVisibleVideoFrameCover(),
                                                  )
                                                : _fatalErrorMessage != null
                                                ? Container(
                                                    color: Colors.black,
                                                    padding:
                                                        const EdgeInsets.all(
                                                          24,
                                                        ),
                                                    child: Center(
                                                      child: ConstrainedBox(
                                                        constraints:
                                                            const BoxConstraints(
                                                              maxWidth: 520,
                                                            ),
                                                        child: SingleChildScrollView(
                                                          child: Column(
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              const Text(
                                                                "无法播放该媒体",
                                                                style: TextStyle(
                                                                  color: Colors
                                                                      .white,
                                                                  fontSize: 18,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                ),
                                                              ),
                                                              const SizedBox(
                                                                height: 8,
                                                              ),
                                                              OperationStatus(
                                                                title:
                                                                    _fatalErrorMessage!,
                                                                kind:
                                                                    OperationStatusKind
                                                                        .error,
                                                                details:
                                                                    _repairFailureDetails,
                                                              ),
                                                              if (_repairAvailable)
                                                                DesktopButtonClickRegion(
                                                                  child: FilledButton(
                                                                    key: const ValueKey(
                                                                      'playback-repair-retry',
                                                                    ),
                                                                    onPressed:
                                                                        _repairVideo,
                                                                    child: Text(
                                                                      _repairFailureDetails ==
                                                                              null
                                                                          ? '尝试修复'
                                                                          : '重试修复',
                                                                    ),
                                                                  ),
                                                                ),
                                                              const SizedBox(
                                                                height: 24,
                                                              ),
                                                              if (_currentItem !=
                                                                  null)
                                                                DesktopButtonClickRegion(
                                                                  child: FilledButton(
                                                                    key: const ValueKey(
                                                                      'playback-retry',
                                                                    ),
                                                                    onPressed:
                                                                        _retryFailedPlayback,
                                                                    child:
                                                                        const Text(
                                                                          '重试',
                                                                        ),
                                                                  ),
                                                                ),
                                                              if (isCloudDriveMedia(
                                                                source: _currentItem
                                                                    ?.sourceRef,
                                                                path:
                                                                    _currentItem
                                                                        ?.path ??
                                                                    '',
                                                              )) ...[
                                                                const SizedBox(
                                                                  height: 8,
                                                                ),
                                                                if (Provider.of<
                                                                          MediaPlaybackService
                                                                        >(
                                                                          context,
                                                                          listen:
                                                                              false,
                                                                        )
                                                                        .cloudDriveFailureKind ==
                                                                    CloudDriveFailureKind
                                                                        .notLoggedIn)
                                                                  DesktopButtonClickRegion(
                                                                    child: FilledButton(
                                                                      onPressed: () {
                                                                        final runtime =
                                                                            CloudDriveRuntime.instance;
                                                                        final providerId = _currentItem
                                                                            ?.sourceRef
                                                                            ?.cloudDrive
                                                                            ?.providerId;
                                                                        final provider =
                                                                            providerId ==
                                                                                null
                                                                            ? null
                                                                            : runtime?.providers[providerId];
                                                                        if (runtime ==
                                                                                null ||
                                                                            provider ==
                                                                                null) {
                                                                          return;
                                                                        }
                                                                        unawaited(
                                                                          Navigator.of(
                                                                            context,
                                                                          ).push(
                                                                            CloudDriveLoginRoute(
                                                                              provider: provider,
                                                                              accounts: runtime.accounts,
                                                                            ),
                                                                          ),
                                                                        );
                                                                      },
                                                                      child: const Text(
                                                                        '重新登录',
                                                                      ),
                                                                    ),
                                                                  ),
                                                                DesktopButtonClickRegion(
                                                                  child: TextButton(
                                                                    onPressed: () async {
                                                                      final report =
                                                                          Provider.of<
                                                                                MediaPlaybackService
                                                                              >(
                                                                                context,
                                                                                listen: false,
                                                                              )
                                                                              .cloudDriveDiagnosticReport;
                                                                      await Clipboard.setData(
                                                                        ClipboardData(
                                                                          text:
                                                                              report ==
                                                                                      null ||
                                                                                  report.isEmpty
                                                                              ? '没有可复制的诊断'
                                                                              : report,
                                                                        ),
                                                                      );
                                                                    },
                                                                    child:
                                                                        const Text(
                                                                          '复制诊断',
                                                                        ),
                                                                  ),
                                                                ),
                                                                const SizedBox(
                                                                  height: 8,
                                                                ),
                                                              ],
                                                              DesktopButtonClickRegion(
                                                                child: ElevatedButton(
                                                                  onPressed: () =>
                                                                      unawaited(
                                                                        _forceExitPlayer(),
                                                                      ),
                                                                  child: Text(
                                                                    isCloudDriveMedia(
                                                                          source:
                                                                              _currentItem?.sourceRef,
                                                                          path:
                                                                              _currentItem?.path ??
                                                                              '',
                                                                        )
                                                                        ? '返回目录'
                                                                        : '返回',
                                                                  ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  )
                                                : _isRepairing
                                                ? Column(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .center,
                                                    children: [
                                                      const CircularProgressIndicator(),
                                                      const SizedBox(
                                                        height: 16,
                                                      ),
                                                      const Text(
                                                        "正在修复视频...",
                                                        style: TextStyle(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 8),
                                                      Text(
                                                        "进度: ${(_repairProgress * 100).toStringAsFixed(1)}%",
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 16,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 8),
                                                      const Text(
                                                        "转码为 H.264 (兼容模式)",
                                                        style: TextStyle(
                                                          color: Colors.white70,
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  )
                                                : _shouldKeepVideoSurface
                                                ? RepaintBoundary(
                                                    child: SizedBox.expand(
                                                      child: Stack(
                                                        fit: StackFit.expand,
                                                        children: [
                                                          if (_isAudio)
                                                            Container(
                                                              color:
                                                                  Colors.black,
                                                              child: const Center(
                                                                child: Icon(
                                                                  Icons
                                                                      .music_note,
                                                                  size: 80,
                                                                  color: Colors
                                                                      .white24,
                                                                ),
                                                              ),
                                                            )
                                                          else
                                                            ClipRect(
                                                              child: Stack(
                                                                fit: StackFit
                                                                    .expand,
                                                                children: [
                                                                  Positioned.fill(
                                                                    child: ValueListenableBuilder<bool>(
                                                                      valueListenable:
                                                                          _ambientSeekHold,
                                                                      builder:
                                                                          (
                                                                            context,
                                                                            seekHold,
                                                                            _,
                                                                          ) => AmbientLetterboxLayer(
                                                                            enabled:
                                                                                settings.experimentalAmbientLetterbox,
                                                                            mediaId:
                                                                                _currentItem?.id,
                                                                            playerId:
                                                                                ambientPlayerId,
                                                                            controller:
                                                                                _controllerAssigned
                                                                                ? _controller
                                                                                : null,
                                                                            scrubbing:
                                                                                _ambientScrubbing,
                                                                            transforming:
                                                                                _isVideoTransformGestureActive,
                                                                            seekHold:
                                                                                seekHold,
                                                                            columnSize:
                                                                                playerSurfaceSize,
                                                                            containedVideoSize:
                                                                                containedVideoSize,
                                                                            userScale:
                                                                                _videoUserScale,
                                                                            userRotation:
                                                                                _videoUserRotation,
                                                                            userOffset: _denormalizeVideoOffset(
                                                                              _videoUserOffsetNormalized,
                                                                              playerSurfaceSize,
                                                                            ),
                                                                          ),
                                                                    ),
                                                                  ),
                                                                  RepaintBoundary(
                                                                    child: Center(
                                                                      child: Transform(
                                                                        alignment:
                                                                            Alignment.center,
                                                                        transform: _buildVideoTransformMatrix(
                                                                          videoViewportRect
                                                                              .size,
                                                                          settings,
                                                                        ),
                                                                        child: SizedBox(
                                                                          width:
                                                                              containedVideoSize.width,
                                                                          height:
                                                                              containedVideoSize.height,
                                                                          child: StableVideoSurface(
                                                                            referenceSize: _computeContainedVideoSize(
                                                                              subtitlePageSize ??
                                                                                  playerSurfaceSize,
                                                                              videoAspectRatio,
                                                                            ),
                                                                            child:
                                                                                _buildVideoTexture(),
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          if (!_isAudio)
                                                            _buildVideoBoundDanmakuOverlay(
                                                              videoSize:
                                                                  containedVideoSize,
                                                              content:
                                                                  danmakuContent,
                                                              settings:
                                                                  settings,
                                                            ),
                                                        ],
                                                      ),
                                                    ),
                                                  )
                                                : _buildLoadingState(context),
                                          ),

                                          if (_initialized &&
                                              _activeSidebar ==
                                                  SidebarType.subtitleStyle)
                                            Positioned.fill(
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.translucent,
                                                onDoubleTap: _isLocked
                                                    ? null
                                                    : _togglePlay,
                                              ),
                                            ),

                                          playbackControls,

                                          // 3. Standard Subtitle Layer
                                          // Keep ordinary subtitles above the controls, just
                                          // like the ghost layer below. Both let playback input
                                          // through unless subtitle position editing is active.
                                          if (_initialized &&
                                              (((settings.showSubtitles &&
                                                      !_suppressSubtitleOverlayForOcr) ||
                                                  _videoComposePreviewActive)) &&
                                              !isGhostActive)
                                            _isAudio
                                                ? _buildFreeSubtitleOverlay(
                                                    alignment:
                                                        displayedSubtitleAlignment(
                                                          settings: settings,
                                                          target:
                                                              _subtitleTarget(
                                                                ghost: false,
                                                              ),
                                                        ),
                                                    style: activeSubtitleStyle,
                                                    isDragging:
                                                        _isSubtitleDragMode,
                                                    presetPositionOverride:
                                                        targetHasPresetOverride(
                                                          settings,
                                                          _subtitleTarget(
                                                            ghost: false,
                                                          ),
                                                        ),
                                                    displayNotifier:
                                                        _videoComposePreviewActive
                                                        ? _videoComposePreviewController
                                                              .displayNotifier
                                                        : null,
                                                    playbackControlsVisibility:
                                                        _playbackControlsVisibility,
                                                    playbackControlRects:
                                                        playerPlaybackControlRects,
                                                    avoidPlaybackControls:
                                                        settings
                                                            .avoidPlaybackControlsWithSubtitles &&
                                                        !_isLocked &&
                                                        !_isSubtitleDragMode,
                                                  )
                                                : _buildVideoBoundSubtitleOverlay(
                                                    videoSize:
                                                        containedVideoSize,
                                                    alignment:
                                                        displayedSubtitleAlignment(
                                                          settings: settings,
                                                          target:
                                                              _subtitleTarget(
                                                                ghost: false,
                                                              ),
                                                        ),
                                                    style: activeSubtitleStyle,
                                                    isDragging:
                                                        _isSubtitleDragMode,
                                                    presetPositionOverride:
                                                        targetHasPresetOverride(
                                                          settings,
                                                          _subtitleTarget(
                                                            ghost: false,
                                                          ),
                                                        ),
                                                    displayNotifier:
                                                        _videoComposePreviewActive
                                                        ? _videoComposePreviewController
                                                              .displayNotifier
                                                        : null,
                                                    playbackControlsVisibility:
                                                        _playbackControlsVisibility,
                                                    playbackControlRects:
                                                        videoPlaybackControlRects,
                                                    avoidPlaybackControls:
                                                        settings
                                                            .avoidPlaybackControlsWithSubtitles &&
                                                        !_isLocked &&
                                                        !_isSubtitleDragMode,
                                                  ),

                                          // Drag hints. Center guides are painted by the
                                          // subtitle surface in video-local space.
                                          // 5. Drag Hints
                                          if (_isSubtitleDragMode ||
                                              _isGhostDragMode) ...[
                                            if (_isSubtitleNearCenterX)
                                              Positioned.fill(
                                                child: Center(
                                                  child: Container(
                                                    width: _isSubtitleSnappedX
                                                        ? 2
                                                        : 1,
                                                    height: double.infinity,
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha:
                                                              _isSubtitleSnappedX
                                                              ? 0.52
                                                              : 0.22,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            if (_isSubtitleNearCenterY)
                                              Positioned.fill(
                                                child: Center(
                                                  child: Container(
                                                    width: double.infinity,
                                                    height: _isSubtitleSnappedY
                                                        ? 2
                                                        : 1,
                                                    color: Colors.white
                                                        .withValues(
                                                          alpha:
                                                              _isSubtitleSnappedY
                                                              ? 0.52
                                                              : 0.22,
                                                        ),
                                                  ),
                                                ),
                                              ),
                                            Positioned(
                                              top: 20,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 8,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.black54,
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                                child: Text(
                                                  _subtitlePositionError ??
                                                      (_isGhostDragMode
                                                          ? "拖拽调整幽灵模式位置"
                                                          : "拖拽调整位置"),
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],

                                          // 6. Ghost Mode Subtitle Layer
                                          if (settings.showSubtitles &&
                                              !_suppressSubtitleOverlayForOcr &&
                                              isGhostActive)
                                            _buildFreeSubtitleOverlay(
                                              isGhost: true,
                                              fullPageSize: subtitlePageSize,
                                              alignment:
                                                  settings.ghostModeAlignment,
                                              style: settings
                                                  .subtitleStyleGhostLandscape,
                                              isDragging: _isGhostDragMode,
                                              animateAlignment:
                                                  !_isGhostDragMode,
                                              playbackControlsVisibility:
                                                  _playbackControlsVisibility,
                                              playbackControlRects:
                                                  playerPlaybackControlRects,
                                              avoidPlaybackControls:
                                                  settings
                                                      .avoidPlaybackControlsWithSubtitles &&
                                                  !_isLocked &&
                                                  !_isGhostDragMode,
                                            ),

                                          // 7. Episode Picker Layer
                                          Positioned.fill(
                                            child: _showEpisodePicker
                                                ? GestureDetector(
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onTap: () {
                                                      setState(() {
                                                        _showEpisodePicker =
                                                            false;
                                                      });
                                                    },
                                                    child: Container(
                                                      color: Colors.transparent,
                                                    ),
                                                  )
                                                : const SizedBox.shrink(),
                                          ),
                                          Align(
                                            alignment: Alignment.center,
                                            child: AnimatedSwitcher(
                                              duration:
                                                  MediaQuery.disableAnimationsOf(
                                                    context,
                                                  )
                                                  ? Duration.zero
                                                  : PlayerSidebarMotion
                                                        .switchDuration,
                                              switchInCurve:
                                                  Curves.easeOutCubic,
                                              switchOutCurve:
                                                  Curves.easeInCubic,
                                              transitionBuilder:
                                                  (
                                                    Widget child,
                                                    Animation<double> animation,
                                                  ) {
                                                    return SlideTransition(
                                                      position: Tween<Offset>(
                                                        begin: const Offset(
                                                          0,
                                                          0.05,
                                                        ),
                                                        end: Offset.zero,
                                                      ).animate(animation),
                                                      child: FadeTransition(
                                                        opacity: animation,
                                                        child: child,
                                                      ),
                                                    );
                                                  },
                                              child: _showEpisodePicker
                                                  ? EpisodePickerPanel(
                                                      key: const ValueKey(
                                                        "EpisodePickerPanel",
                                                      ),
                                                      panelWidth:
                                                          (screenConstraints
                                                                      .maxWidth *
                                                                  0.65)
                                                              .clamp(
                                                                280.0,
                                                                800.0,
                                                              ),
                                                      panelHeight:
                                                          (screenConstraints
                                                                      .maxHeight *
                                                                  0.75)
                                                              .clamp(
                                                                240.0,
                                                                700.0,
                                                              ),
                                                      onClose: () => setState(
                                                        () =>
                                                            _showEpisodePicker =
                                                                false,
                                                      ),
                                                    )
                                                  : const SizedBox.shrink(
                                                      key: ValueKey(
                                                        "EpisodePickerPanel_Empty",
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
                            ),
                            if (!isLeftHandedMode) ...sidebarWidgets,
                          ],
                        ),
                        if (!isDesktop)
                          Positioned.fill(
                            child: BilibiliPanelOverlay(
                              motion: _sidebarMotion,
                              panel: bilibiliOverVideo
                                  ? LandscapeSidebarTheme(
                                      child:
                                          _buildSidebarContent(
                                            settings,
                                            bilibiliOverlay: true,
                                          ) ??
                                          const SizedBox.shrink(),
                                    )
                                  : null,
                              fromLeft: isLeftHandedMode,
                              width: LandscapeSidebarLayout.functionalWidthFor(
                                MediaQuery.sizeOf(context),
                              ),
                              padding: sidebarSafePadding,
                              onDismiss: _collapseBilibiliPanel,
                            ),
                          ),
                        if (showResizer)
                          Positioned.fill(
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: CompositedTransformFollower(
                                link: _sidebarDividerLink,
                                showWhenUnlinked: false,
                                targetAnchor: isLeftHandedMode
                                    ? Alignment.topRight
                                    : Alignment.topLeft,
                                followerAnchor: isLeftHandedMode
                                    ? Alignment.topRight
                                    : Alignment.topLeft,
                                child: SidebarInteractionRegion(
                                  child: SizedBox(
                                    width: _subtitleSidebarResizerHitWidth,
                                    height: double.infinity,
                                    child: GestureDetector(
                                      key: const ValueKey(
                                        'player-sidebar-resize-handle',
                                      ),
                                      behavior: HitTestBehavior.translucent,
                                      onHorizontalDragStart: (_) =>
                                          _startSidebarResize(
                                            settings,
                                            context,
                                          ),
                                      onHorizontalDragUpdate: (details) =>
                                          _updateSidebarResize(
                                            settings,
                                            context,
                                            isLeftHandedMode,
                                            details,
                                          ),
                                      onHorizontalDragEnd: (_) =>
                                          _endSidebarResize(settings),
                                      onHorizontalDragCancel: () =>
                                          _endSidebarResize(
                                            settings,
                                            cancelled: true,
                                          ),
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.resizeColumn,
                                        onEnter: (_) =>
                                            _sidebarResizeHovered.value = true,
                                        onExit: (_) =>
                                            _sidebarResizeHovered.value = false,
                                        child: const SizedBox.expand(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Positioned.fill(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: CompositedTransformFollower(
                              link: _sidebarToggleLink,
                              showWhenUnlinked: false,
                              followerAnchor: isLeftHandedMode
                                  ? Alignment.centerLeft
                                  : Alignment.centerRight,
                              child: PlayerSubtitleSidebarToggle(
                                key: const ValueKey(
                                  'player-subtitle-sidebar-toggle-overlay',
                                ),
                                expanded:
                                    _activeSidebar == SidebarType.subtitles ||
                                    _activeSidebar == SidebarType.aiChat,
                                sidebarLabel: _usesBilibiliSidebarTabs
                                    ? '播放边栏'
                                    : '字幕边栏',
                                onLeft: isLeftHandedMode,
                                outerInset: sidebarDocked
                                    ? 0
                                    : (isLeftHandedMode
                                          ? math.max(
                                              sidebarSafePadding.left,
                                              Platform.isIOS
                                                  ? _iosBackSwipeEdgeWidth
                                                  : 0.0,
                                            )
                                          : sidebarSafePadding.right),
                                visible:
                                    settings.showSubtitleSidebarToggle &&
                                    !_isLocked &&
                                    !_isSubtitleDragMode &&
                                    !_isGhostDragMode,
                                onPressed: _isResizingSidebar
                                    ? null
                                    : _toggleSubtitleSidebar,
                              ),
                            ),
                          ),
                        ),
                        if (Platform.isIOS)
                          Positioned(
                            left: 0,
                            top: 0,
                            bottom: 0,
                            width: _iosBackSwipeEdgeWidth,
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onHorizontalDragStart: _onIosBackSwipeStart,
                              onHorizontalDragUpdate: _onIosBackSwipeUpdate,
                              onHorizontalDragEnd: _onIosBackSwipeEnd,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Map<String, String> _buildSubtitleEditorGroups() {
    final Map<String, String> groups = <String, String>{};
    final currentItem = _currentItem;
    if (currentItem != null) {
      groups.addAll(currentItem.downloadAssociatedSubtitles);
      groups.addAll(currentItem.localSubtitleGroups);
    }
    if (_currentItem?.subtitlePath != null &&
        _currentItem!.subtitlePath!.isNotEmpty) {
      groups.putIfAbsent('主字幕', () => _currentItem!.subtitlePath!);
    }
    if (_currentSubtitlePaths.isNotEmpty &&
        _currentSubtitlePaths.first.isNotEmpty) {
      groups.putIfAbsent('当前主字幕', () => _currentSubtitlePaths.first);
    }
    if (_currentItem?.secondarySubtitlePath != null &&
        _currentItem!.secondarySubtitlePath!.isNotEmpty) {
      groups.putIfAbsent('副字幕', () => _currentItem!.secondarySubtitlePath!);
    }
    return groups;
  }

  String? _resolveActiveSubtitleEditorPath() {
    if (_currentSubtitlePaths.isNotEmpty &&
        _currentSubtitlePaths.first.isNotEmpty) {
      return _currentSubtitlePaths.first;
    }
    if (_currentItem?.subtitlePath != null &&
        _currentItem!.subtitlePath!.isNotEmpty) {
      return _currentItem!.subtitlePath;
    }
    return null;
  }

  String _normalizeGroupName(String name) {
    final String normalized = name.trim();
    return normalized.isEmpty ? '手动字幕' : normalized;
  }

  Future<String> _createManualSubtitleGroup(String desiredName) async {
    if (_currentItem == null) return '';
    final String groupName = _normalizeGroupName(desiredName);
    final library = Provider.of<LibraryService>(context, listen: false);
    final String filePath = await library.allocateSubtitleFile(
      _currentItem!.id,
      'manual.${DateTime.now().millisecondsSinceEpoch}.srt',
    );
    await _writeSubtitlesToSrt(filePath, _subtitles);
    await library.registerManagedSubtitleAsset(
      _currentItem!.id,
      path: filePath,
      kind: ManagedSubtitleAssetKind.manual,
      displayName: groupName,
    );

    final Map<String, String> local = Map<String, String>.from(
      _currentItem!.localSubtitles ?? <String, String>{},
    );
    String unique = groupName;
    int serial = 2;
    while (local.containsKey(unique)) {
      unique = '$groupName $serial';
      serial++;
    }
    local[unique] = filePath;
    _currentItem!.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem!.id, local);
    await _applyPrimarySubtitlePath(filePath);
    return filePath;
  }

  Future<void> _renameSubtitleGroup(String oldName, String newName) async {
    if (_currentItem == null) return;
    final String normalized = _normalizeGroupName(newName);
    final library = Provider.of<LibraryService>(context, listen: false);
    final associated = Map<String, String>.from(
      _currentItem!.additionalSubtitles ?? const <String, String>{},
    );
    final downloadAssociated = _currentItem!.downloadAssociatedSubtitles;
    final local = Map<String, String>.from(
      _currentItem!.localSubtitles ?? <String, String>{},
    );
    if (downloadAssociated.containsKey(oldName)) {
      final path = associated.remove(oldName)!;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      associated[normalized] = path;
      _currentItem!.additionalSubtitles = associated;
      await library.updateVideoAdditionalSubtitles(
        _currentItem!.id,
        associated,
      );
    } else if (!local.containsKey(oldName)) {
      final String? currentPath = _resolveActiveSubtitleEditorPath();
      if (currentPath == null || currentPath.isEmpty) return;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      local[normalized] = currentPath;
    } else {
      final String path = local.remove(oldName)!;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      local[normalized] = path;
    }
    _currentItem!.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem!.id, local);
    if (mounted) setState(() {});
  }

  Future<void> _writeSubtitlesToSrt(
    String path,
    List<SubtitleItem> subtitles,
  ) async {
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < subtitles.length; i++) {
      final SubtitleItem item = subtitles[i];
      final int index = i + 1;
      buffer.writeln(index.toString());
      buffer.writeln(
        '${_formatSrtTime(item.startTime)} --> ${_formatSrtTime(item.endTime)}',
      );
      buffer.writeln(item.text);
      buffer.writeln();
    }
    await File(path).writeAsString(buffer.toString(), flush: true);
    await SubtitleWordTimingStore.write(path, subtitles);
    if (mounted && _currentItem != null) {
      await Provider.of<LibraryService>(
        context,
        listen: false,
      ).refreshSubtitleWordTimingBinding(_currentItem!.id, path);
    }
  }

  String _formatSrtTime(Duration duration) {
    String two(int value) => value.toString().padLeft(2, '0');
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes.remainder(60);
    final int seconds = duration.inSeconds.remainder(60);
    final int milliseconds = duration.inMilliseconds.remainder(1000);
    return '${two(hours)}:${two(minutes)}:${two(seconds)},${milliseconds.toString().padLeft(3, '0')}';
  }

  Future<void> _applyPrimarySubtitlePath(String path) async {
    if (path.isEmpty || _currentItem == null) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    String? secondaryPath;
    if (_currentSubtitlePaths.length > 1) {
      secondaryPath = _currentSubtitlePaths[1];
    } else {
      secondaryPath = _currentItem!.secondarySubtitlePath;
    }
    final List<String> paths = <String>[path];
    if (secondaryPath != null &&
        secondaryPath.isNotEmpty &&
        secondaryPath != path) {
      paths.add(secondaryPath);
    }
    await _loadSubtitles(paths);
    await library.updateVideoSubtitles(
      _currentItem!.id,
      path,
      settings.autoCacheSubtitles,
      secondarySubtitlePath: secondaryPath,
      isSecondaryCached: settings.autoCacheSubtitles,
    );
  }

  String? _subtitleEditorDocumentId(String? path) {
    final item = _currentItem;
    if (item == null || path == null) return null;
    return SubtitleEditorPersistence.documentKey(
      Provider.of<LibraryService>(context, listen: false),
      item.id,
      path,
    );
  }

  SubtitleItemsPersistCallback _bindSubtitleEditorSave(String? sourcePath) {
    final item = _currentItem;
    if (item == null || sourcePath == null || sourcePath.isEmpty) {
      return (_) async {};
    }
    final videoId = item.id;
    final library = Provider.of<LibraryService>(context, listen: false);
    final playback = Provider.of<MediaPlaybackService>(context, listen: false);
    final cache = Provider.of<SettingsService>(
      context,
      listen: false,
    ).autoCacheSubtitles;
    final documentId = SubtitleEditorPersistence.documentKey(
      library,
      videoId,
      sourcePath,
    );
    return (subtitles) async {
      if (library.getVideo(videoId) == null) return;
      bool isActive() =>
          mounted &&
          _currentItem?.id == videoId &&
          _resolveActiveSubtitleEditorPath() != null &&
          SubtitleEditorPersistence.documentKey(
                library,
                videoId,
                _resolveActiveSubtitleEditorPath()!,
              ) ==
              documentId;
      bool canSelect(String path) {
        if (mounted && _currentItem?.id == videoId) {
          return _resolveActiveSubtitleEditorPath() == path;
        }
        final saved = library.getVideo(videoId)?.subtitlePath;
        return saved == sourcePath || saved == path;
      }

      if (isActive()) {
        setState(() => _subtitles = List<SubtitleItem>.from(subtitles));
        _rebuildSubtitleIndex();
        if (playback.currentItem?.id == videoId) {
          playback.setSubtitleState(
            paths: _currentSubtitlePaths,
            primary: _subtitles,
            secondary: _secondarySubtitles,
          );
        }
        _updateSubtitle();
      }
      try {
        final output = await SubtitleEditorPersistence.save(
          library: library,
          videoId: videoId,
          sourcePath: sourcePath,
          subtitles: subtitles,
        );
        if (output == sourcePath) return;
        if (isActive()) {
          // Keep the latest in-memory draft while adopting its editable copy.
          // Reloading this older save from disk could overwrite newer typing.
          final secondary = _currentSubtitlePaths.length > 1
              ? _currentSubtitlePaths[1]
              : item.secondarySubtitlePath;
          setState(() {
            _currentSubtitlePaths = [
              output,
              if (secondary != null && secondary != output) secondary,
            ];
          });
          if (playback.currentItem?.id == videoId) {
            playback.setSubtitleState(
              paths: _currentSubtitlePaths,
              primary: _subtitles,
              secondary: _secondarySubtitles,
            );
          }
          await library.updateVideoSubtitles(
            videoId,
            output,
            cache,
            secondarySubtitlePath: secondary,
            isSecondaryCached: cache,
            shouldApply: () => canSelect(output),
          );
        } else if (!mounted || _currentItem?.id != videoId) {
          final original = library.getVideo(videoId);
          if (original?.subtitlePath == sourcePath) {
            await library.updateVideoSubtitles(
              videoId,
              output,
              cache,
              secondarySubtitlePath: original!.secondarySubtitlePath,
              isSecondaryCached: cache,
              shouldApply: () => canSelect(output),
            );
          }
        }
      } catch (_) {
        rethrow;
      }
    };
  }

  void _showSubtitleEditor() {
    _openSidebar(SidebarType.subtitleEditor);
  }

  void _toggleChapterSidebar() {
    _openSidebar(SidebarType.chapters);
  }

  Widget _buildAiChatPanel() {
    final item = _currentItem;
    if (item == null) return const SizedBox.shrink();
    return AiChatPanel(
      key: ValueKey('ai_chat_${item.id}'),
      videoItem: item,
      primarySubtitles: _subtitles,
      secondarySubtitles: _secondarySubtitles,
      primaryPath: _currentSubtitlePaths.isNotEmpty
          ? _currentSubtitlePaths.first
          : item.subtitlePath,
      secondaryPath: _currentSubtitlePaths.length > 1
          ? _currentSubtitlePaths[1]
          : item.secondarySubtitlePath,
      position: MediaPlaybackService().positionNotifier.value,
      positionListenable: MediaPlaybackService().positionNotifier,
      onSeek: _seekToSubtitleFast,
      isVisible: _activeSidebar == SidebarType.aiChat,
      onBackToSubtitles: _returnToSubtitleSidebar,
      onBack: () => unawaited(_handleBackRequest()),
      onClose: _closeSidebar,
    );
  }

  Widget _buildLandscapeReadingTabs(Widget subtitles) {
    final video = _usesBilibiliSidebarTabs ? _bilibiliVideo : null;
    return BilibiliPortraitTabs(
      key: const ValueKey('landscape-reading-tabs'),
      tab: _landscapeBilibiliTab,
      detailsLabel: '哔哩哔哩',
      keyPrefix: 'bilibili-landscape',
      onSelect: _isLocked || _isResizingSidebar
          ? null
          : _pickLandscapeBilibiliTab,
      onClose: _toggleSubtitleSidebar,
      canStartSwipe: () =>
          _activeSidebar == SidebarType.subtitles &&
          !_isLocked &&
          !_isResizingSidebar &&
          !_hasPageTextSelection &&
          !(_subtitleSidebarKey.currentState?.hasTextSelection ?? false),
      details: video == null
          ? null
          : LandscapeSidebarTheme(
              child: BilibiliPlayerPanel(
                key: _dockedBilibiliPanelKey,
                bvid: video.bvid,
                page: video.page,
                fallbackTitle: _currentItem?.title ?? '',
                showHeader: false,
              ),
            ),
      subtitles: subtitles,
    );
  }

  Widget? _buildSidebarContent(
    SettingsService settings, {
    SidebarType? panelType,
    bool bilibiliOverlay = false,
  }) {
    final type = panelType ?? _activeSidebar;
    if (type == SidebarType.none) return null;

    switch (type) {
      case SidebarType.chapters:
        final item = _currentItem;
        if (item == null) return null;
        if (!_controllerAssigned || !_initialized) {
          return const Center(
            child: Text(
              '播放器加载完成后可查看章节',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        return ChapterSidebar(
          videoItem: item,
          controller: _controller,
          onSeek: _seekPlaybackPosition,
          onClose: _toggleChapterSidebar,
          playerFocusNode: _videoFocusNode,
        );

      case SidebarType.bilibili:
        final video = _bilibiliVideo;
        if (video == null) return null;
        return BilibiliPlayerPanel(
          key: bilibiliOverlay
              ? const PageStorageKey('bilibili-player-panel')
              : _dockedBilibiliPanelKey,
          bvid: video.bvid,
          page: video.page,
          fallbackTitle: _currentItem?.title ?? '',
          onCollapse: _collapseBilibiliPanel,
        );

      case SidebarType.subtitles:
      case SidebarType.aiChat:
        final sidebarContentHorizontalPadding =
            resolveLandscapeSidebarSafePadding(
              viewPadding: MediaQuery.viewPaddingOf(context),
              systemGestureInsets: MediaQuery.systemGestureInsetsOf(context),
              isLeftHandedMode: settings.isLeftHandedMode,
            ).horizontal;
        return SubtitleChatSidebar(
          motion: _sidebarMotion,
          key: const ValueKey('subtitle-chat-sidebar'),
          showChat: _activeSidebar == SidebarType.aiChat,
          isVisible:
              _activeSidebar == SidebarType.subtitles ||
              _activeSidebar == SidebarType.aiChat,
          subtitleWidth: math.max(
            0.0,
            _clampResizableSidebarWidth(
                  context,
                  _subtitleSidebarWidthOverride ??
                      settings.userSubtitleSidebarWidth,
                ) -
                sidebarContentHorizontalPadding,
          ),
          chatWidth: math.max(
            0.0,
            AiSidebarWidth.resolve(
                  MediaQuery.sizeOf(context),
                  preference:
                      _aiSidebarWidthOverride ?? settings.userAiSidebarWidth,
                ) -
                sidebarContentHorizontalPadding,
          ),
          onLeft: settings.isLeftHandedMode,
          chat: _buildAiChatPanel(),
          subtitles: _buildLandscapeReadingTabs(
            SubtitleSidebar(
              key: _subtitleSidebarKey,
              subtitles: _subtitles,
              secondarySubtitles: _secondarySubtitles,
              controller: _pageControllerIsCurrent ? _controller : null,
              positionListenable: MediaPlaybackService().positionNotifier,
              onItemTap: _seekToSubtitleFast,
              onOpenSettings: () => _openSidebar(SidebarType.settings),
              onClose: _toggleSubtitleSidebar,
              onLoadSubtitle: _pickSubtitle,
              onOpenSubtitleStyle: _toggleFloatingSubtitleSettingsSidebar,
              onOpenSubtitleManager: _showSubtitleManager,
              onOpenSubtitleEditor: _showSubtitleEditor,
              onOpenVideoCompose: _showVideoCompose,
              onOpenOcrSubtitle: _supportsOcrSubtitle && !_isAudio
                  ? _showOcrSubtitle
                  : null,
              ocrUnavailableReason: _isAudio
                  ? '音频没有画面，请使用语音转录生成字幕。'
                  : !_supportsOcrSubtitle
                  ? '当前平台暂不支持识别画面字幕。'
                  : null,
              onOpenAiChat: _currentItem == null ? null : _showAiChat,
              onClearSelection: () =>
                  _selectionKey.currentState?.selectableRegion.clearSelection(),
              isCompact: true,
              isPortrait: false,
              preserveReadingPositionWhenNotFollowing: true,
              focusNode: _videoFocusNode, // Pass focus node
              isVisible:
                  _isSubtitleSidebarVisible &&
                  _activeSidebar == SidebarType.subtitles &&
                  _showingSubtitleTab,
              showEmbeddedLoadingMessage:
                  _embeddedSubtitleDetected &&
                  _isLoadingEmbeddedSubtitle &&
                  _subtitles.isEmpty &&
                  _secondarySubtitles.isEmpty,
            ),
          ),
        );

      case SidebarType.subtitleStyle:
        final isLandscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        final canShowGhostControls = _canShowGhostSidebarControls(context);
        final isGhostEditing =
            !_subtitleStyleFromCompose &&
            _canUseGhostSidebarEditing(context, settings);
        final SubtitleStyle sheetStyle = _isAudio
            ? (isLandscape
                  ? settings.audioSubtitleStyleLandscape
                  : settings.audioSubtitleStylePortrait)
            : (isGhostEditing
                  ? settings.subtitleStyleGhostLandscape
                  : (isLandscape
                        ? settings.subtitleStyleLandscape
                        : settings.subtitleStylePortrait));
        return SubtitleSettingsSheet(
          positionError: _subtitlePositionError,
          key: _subtitleSettingsKey,
          primarySource: _fontSource(false),
          secondarySource: _fontSource(true),
          primaryLanguage: _fontLanguage(false),
          secondaryLanguage: _fontLanguage(true),
          style: sheetStyle,
          isGhostMode: isGhostEditing,
          isLandscape: isLandscape,
          isAudio: _isAudio,
          syncAudioSubtitleStyleWithVideo:
              settings.syncAudioSubtitleStyleWithVideo,
          onSyncAudioSubtitleStyleWithVideoChanged: _isAudio
              ? (value) => settings.setAudioSubtitleStyleSyncWithVideo(value)
              : null,
          hideGhostModeToggle:
              _subtitleStyleFromCompose || !canShowGhostControls,
          // 文字样式改变时同步到横竖屏
          onTextStyleChanged: (newTextStyle) {
            if (_isAudio) {
              if (settings.syncAudioSubtitleStyleWithVideo) {
                settings.saveSubtitleTextStyle(newTextStyle);
              } else {
                settings.saveAudioSubtitleTextStyle(newTextStyle);
              }
            } else {
              settings.saveSubtitleTextStyle(newTextStyle);
            }
          },
          // 布局样式改变时同步到横竖屏
          onLayoutStyleChanged: (newLayoutStyle) {
            if (_isAudio) {
              if (isLandscape) {
                settings.saveAudioSubtitleLayoutLandscape(newLayoutStyle);
              } else {
                settings.saveAudioSubtitleLayoutPortrait(newLayoutStyle);
              }
            } else {
              if (isGhostEditing) {
                settings.saveSubtitleLayoutGhostLandscape(newLayoutStyle);
              } else if (isLandscape) {
                settings.saveSubtitleLayoutLandscape(newLayoutStyle);
              } else {
                settings.saveSubtitleLayoutPortrait(newLayoutStyle);
              }
            }
          },
          // 向后兼容的回调
          onStyleChanged: (newStyle) {
            if (_isAudio) {
              if (settings.syncAudioSubtitleStyleWithVideo) {
                settings.saveSubtitleTextStyle(newStyle.textStyle);
                if (isLandscape) {
                  settings.saveAudioSubtitleLayoutLandscape(
                    newStyle.layoutStyle,
                  );
                } else {
                  settings.saveAudioSubtitleLayoutPortrait(
                    newStyle.layoutStyle,
                  );
                }
              } else {
                settings.saveAudioSubtitleStyleLandscape(newStyle);
              }
            } else {
              settings.saveSubtitleStyleLandscape(newStyle);
            }
          },
          onClose: _closeSidebar,
          onBack: () => unawaited(_handleBackRequest()),
        );

      case SidebarType.subtitleEditor:
        final Map<String, String> groups = _buildSubtitleEditorGroups();
        String? activePath = _resolveActiveSubtitleEditorPath();
        if (activePath == null && groups.isNotEmpty) {
          activePath = groups.values.first;
        }
        return LandscapeSubtitleEditorSidebar(
          groups: groups,
          activeGroupPath: activePath,
          documentId: _subtitleEditorDocumentId(activePath),
          subtitles: _subtitles,
          currentSubtitleIndex: _currentSubtitleIndex,
          currentPlaybackPosition:
              _controllerAssigned && _controller.value.isInitialized
              ? _controller.value.position
              : Duration.zero,
          onSelectGroupPath: _applyPrimarySubtitlePath,
          onCreateGroup: (name) async {
            await _createManualSubtitleGroup(name);
            if (mounted) setState(() {});
          },
          onRenameGroup: (oldName, newName) async {
            await _renameSubtitleGroup(oldName, newName);
          },
          onSubtitlesChanged: _bindSubtitleEditorSave(activePath),
          onSeekTo: _seekToSubtitleFast,
          onClose: _closeSidebar,
        );

      case SidebarType.settings:
        final displayedPlaybackSpeed =
            _controllerAssigned && _controller.value.isInitialized
            ? _controller.value.playbackSpeed
            : settings.effectiveGlobalPlaybackSpeed;
        final bool showMobilePlaybackControls =
            !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        return SettingsPanel(
          playbackSpeed: displayedPlaybackSpeed,
          isAudioMode: _isAudio,
          syncAudioSubtitleStyleWithVideo:
              settings.syncAudioSubtitleStyleWithVideo,
          onSyncAudioSubtitleStyleWithVideoChanged: _isAudio
              ? (value) => settings.setAudioSubtitleStyleSyncWithVideo(value)
              : null,
          showSkipPortraitPlayerSetting:
              !kIsWeb && (Platform.isAndroid || Platform.isIOS),
          skipPortraitPlayer: settings.skipPortraitPlayer,
          onSkipPortraitPlayerChanged: (value) =>
              settings.saveSkipPortraitPlayer(value),
          showSubtitles: settings.showSubtitles,
          isMirroredH: _resolvedVideoMirrorH(settings),
          isMirroredV: _resolvedVideoMirrorV(settings),
          onLoadSubtitle: () async {
            await _pickSubtitle();
          },
          onOpenSubtitleSettings: _toggleFloatingSubtitleSettingsSidebar,
          onClose: _closeSidebar,
          isPlaybackSpeedLocked: _currentItem?.sourceRef?.podcast != null
              ? PodcastPlaybackHooks.speedOverridden?.call(_currentItem!) ??
                    false
              : settings.isPlaybackSpeedLocked,
          lockedPlaybackSpeed: _currentItem?.sourceRef?.podcast != null
              ? PodcastPlaybackHooks.speed?.call(_currentItem!)
              : settings.isPlaybackSpeedLocked
              ? settings.playbackSpeed
              : null,
          onSpeedChanged: (speed) =>
              unawaited(_handlePlaybackSpeedSelected(speed)),
          onSpeedLockChanged: _handlePlaybackSpeedLockChanged,
          longPressSpeed: settings.longPressSpeed,
          onLongPressSpeedChanged: (speed) =>
              settings.saveLongPressSpeed(speed),
          showLongPressSpeedIndicator: settings.showLongPressSpeedIndicator,
          onShowLongPressSpeedIndicatorChanged: (value) =>
              settings.saveShowLongPressSpeedIndicator(value),
          onSubtitleToggle: (value) => _setFloatingSubtitles(value),
          onMirrorHChanged: (value) => unawaited(
            _updateCurrentVideoDisplayTransform(isMirroredH: value),
          ),
          onMirrorVChanged: (value) => unawaited(
            _updateCurrentVideoDisplayTransform(isMirroredV: value),
          ),
          doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
          onSeekSecondsChanged: (seconds) =>
              settings.saveDoubleTapSeekSeconds(seconds),
          enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
          onDoubleTapSubtitleSeekChanged: (val) =>
              settings.saveEnableDoubleTapSubtitleSeek(val),
          subtitleDelay: settings.subtitleOffset.inMilliseconds / 1000.0,
          onSubtitleDelayChanged: (delay) =>
              settings.saveSubtitleOffsetMilliseconds((delay * 1000).round()),
          onSubtitleDelayChangeEnd: (_) {},

          // New: Auto Cache Toggle
          autoCacheSubtitles: settings.autoCacheSubtitles,
          onAutoCacheSubtitlesChanged: (value) =>
              settings.saveAutoCacheSubtitles(value),

          // New: Split Subtitle Toggle
          splitSubtitleByLine: settings.splitSubtitleByLine,
          onSplitSubtitleByLineChanged: (val) =>
              settings.saveSplitSubtitleByLine(val),

          // New: Continuous Subtitle Toggle
          continuousSubtitle: _isAudio
              ? settings.audioContinuousSubtitle
              : settings.videoContinuousSubtitle,
          onContinuousSubtitleChanged: (value) {
            if (_isAudio) {
              settings.saveAudioContinuousSubtitle(value);
            } else {
              settings.saveVideoContinuousSubtitle(value);
            }
          },

          // New: Auto Pause on Exit
          autoPauseOnExit: settings.autoPauseOnExit,
          onAutoPauseOnExitChanged: (value) =>
              settings.saveAutoPauseOnExit(value),
          avoidPlaybackControlsWithSubtitles:
              settings.avoidPlaybackControlsWithSubtitles,
          showSubtitleSidebarToggle: settings.showSubtitleSidebarToggle,
          onShowSubtitleSidebarToggleChanged:
              settings.saveShowSubtitleSidebarToggle,
          onAvoidPlaybackControlsWithSubtitlesChanged: (value) =>
              settings.saveAvoidPlaybackControlsWithSubtitles(value),
          pausePlaybackWhenAppBackgrounded:
              settings.pausePlaybackWhenAppBackgrounded,
          onPausePlaybackWhenAppBackgroundedChanged: (value) =>
              settings.savePausePlaybackWhenAppBackgrounded(value),
          allowConcurrentPlayback: settings.allowConcurrentPlayback,
          onAllowConcurrentPlaybackChanged: (value) =>
              settings.saveAllowConcurrentPlayback(value),
          showVideoDecoderSetting:
              !kIsWeb &&
              (Platform.isAndroid ||
                  Platform.isIOS ||
                  Platform.isMacOS ||
                  Platform.isWindows ||
                  Platform.isLinux),
          useHardwareVideoDecoding: settings.useHardwareVideoDecoding,
          onVideoDecoderChanged: (useHardware) async {
            await settings.saveUseHardwareVideoDecoding(useHardware);
            await MediaPlaybackService().reloadCurrentVideoDecoder();
          },
          enableHeadsetMediaControls: settings.enableHeadsetMediaControls,
          onEnableHeadsetMediaControlsChanged: (value) =>
              settings.saveEnableHeadsetMediaControls(value),
          showMobilePlaybackControls: showMobilePlaybackControls,

          autoPlayOnPageEntry: settings.autoPlayOnPageEntry,
          onAutoPlayOnPageEntryChanged: (value) =>
              settings.saveAutoPlayOnPageEntry(value),
          autoPlayNextVideo: settings.autoPlayNextVideo,
          onAutoPlayNextVideoChanged: (value) =>
              settings.saveAutoPlayNextVideo(value),
          autoPlayOnCompletion: settings.autoPlayOnCompletion,
          onAutoPlayOnCompletionChanged: (value) =>
              settings.saveAutoPlayOnCompletion(value),
          autoPlayOnCompletionFromStart: settings.autoPlayOnCompletionFromStart,
          onAutoPlayOnCompletionFromStartChanged: (value) =>
              settings.saveAutoPlayOnCompletionFromStart(value),
          playlistWrapToFirst: settings.playlistWrapToFirst,
          onPlaylistWrapToFirstChanged: (value) =>
              settings.savePlaylistWrapToFirst(value),

          // Seek Preview
          enableSeekPreview: settings.enableSeekPreview,
          onEnableSeekPreviewChanged: (value) =>
              settings.saveEnableSeekPreview(value),
          enableHapticFeedback: settings.enableHapticFeedback,
          enableVideoTransformGestures: settings.enableVideoTransformGestures,
          onEnableVideoTransformGesturesChanged: (value) =>
              settings.saveEnableVideoTransformGestures(value),
          onEnableHapticFeedbackChanged: (value) =>
              settings.saveEnableHapticFeedback(value),
          isLeftHandedMode: settings.isLeftHandedMode,
          onLeftHandedModeChanged: (value) =>
              settings.saveLeftHandedMode(value),
          experimentalAmbientLetterbox: settings.experimentalAmbientLetterbox,
          onExperimentalAmbientLetterboxChanged: (value) =>
              settings.saveExperimentalAmbientLetterbox(value),
        );

      case SidebarType.subtitlePosition:
        final canEditGhostStyle = _canUseGhostSidebarEditing(context, settings);
        final presetGhostMove = _presetGhostMoveActive(context, settings);
        final isGhost =
            (canEditGhostStyle && _isGhostDragMode) || presetGhostMove;
        final canShowGhostControls =
            _canShowGhostSidebarControls(context) ||
            (SubtitleDebugSession.instance.usesPresets &&
                _presetMoveSurfaceAllowsGhost(context));
        final SubtitlePositionTarget positionTarget = _subtitleTarget(
          ghost: isGhost,
        );
        Alignment currentAlign = displayedSubtitleAlignment(
          settings: settings,
          target: positionTarget,
        );
        if (positionTarget.isPreset &&
            !targetHasPresetOverride(settings, positionTarget)) {
          final laid = _subtitlePositions.geometry.current;
          if (laid != null && !laid.contentRect.isEmpty) {
            currentAlign = SubtitleMoveSpace.fromViewport(
              laid.viewportRect,
              laid.contentSize,
            ).originToAlignment(laid.origin, preserved: const Alignment(0, 1));
          }
        }
        final bool presetTarget =
            positionTarget.isPreset && !positionTarget.isGhost;

        return SubtitlePositionSidebar(
          currentAlignment: currentAlign,
          resetHint:
              _subtitlePositionError ??
              (isGhost
                  ? '恢复幽灵模式的默认位置。不会改普通字幕或预设位置。'
                  : presetTarget
                  ? '清除当前预设的位置覆盖，恢复该预设默认底距。不影响其他预设、原样式和幽灵位置。'
                  : '恢复默认位置。'),
          onAlignmentChanged: (align) {
            _nudgeSubtitleAlignment(align, ghost: isGhost);
          },
          presets: settings.subtitlePresets,
          onSavePreset: () {
            final newPresets = List<Map<String, double>>.from(
              settings.subtitlePresets,
            );
            newPresets.insert(0, {'x': currentAlign.x, 'y': currentAlign.y});
            if (newPresets.length > 10) newPresets.removeLast();
            settings.saveSubtitlePresets(newPresets);
          },
          onReset: () {
            if (presetTarget) {
              commitPlayerSubtitlePosition(
                settings: settings,
                target: positionTarget,
                placement: const PresetDefaultPlacement(),
              );
              return;
            }
            _nudgeSubtitleAlignment(const Alignment(0.0, 0.9), ghost: isGhost);
          },
          onConfirm: _exitSubtitleDragMode,
          isGhostModeEnabled: settings.isGhostModeEnabled,
          onGhostModeToggle: (val) {
            settings.saveGhostModeEnabled(val);
            // Force rebuild to update UI state
            setState(() {});
          },
          onEnterGhostMode: _enterGhostDragMode,
          isGhostModeActive: isGhost,
          hideGhostModeControls: !canShowGhostControls,
        );

      case SidebarType.subtitleManager:
        String path = _currentItem?.path ?? widget.videoFile?.path ?? "";
        if (path.isEmpty) return null;
        final List<String> selectedPathsForSheet =
            _currentSubtitlePaths.isNotEmpty
            ? List<String>.from(_currentSubtitlePaths)
            : <String>[
                if (_currentItem?.subtitlePath != null &&
                    _currentItem!.subtitlePath!.isNotEmpty)
                  _currentItem!.subtitlePath!,
                if (_currentItem?.secondarySubtitlePath != null &&
                    _currentItem!.secondarySubtitlePath!.isNotEmpty)
                  _currentItem!.secondarySubtitlePath!,
              ];
        final associatedSubtitlesForSheet =
            _currentItem?.downloadAssociatedSubtitles ??
            const <String, String>{};
        final localSubtitlesForSheet =
            _currentItem?.localSubtitleGroups ?? const <String, String>{};

        return SubtitleManagementSheet(
          key: ValueKey(path),
          videoPath: path,
          videoId: _currentItem?.id,
          showEmbeddedSubtitles: true,
          embeddedError:
              _embeddedSubtitleErrorMediaKey ==
                  (_currentItem?.id ?? widget.videoFile?.path)
              ? _embeddedSubtitleError
              : null,
          onRetryEmbedded: () => unawaited(_checkAndLoadEmbeddedSubtitle()),
          associatedSubtitles: associatedSubtitlesForSheet,
          localSubtitles: localSubtitlesForSheet,
          initialSelectedPaths: selectedPathsForSheet,
          bilibiliTracks: bilibiliSubtitleTracksFor(context, _currentItem),
          cloudDriveTracks: cloudDriveSubtitleTracksFor(context, _currentItem),
          embeddedProbePath: CloudDriveRuntime.instance?.materialization
              ?.readyLocalVideoPath(_currentItem?.id ?? ''),
          onSubtitleChanged: () {
            // Logic to refresh if needed
          },
          onSubtitleSelected: (paths) async {
            final settings = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            final library = Provider.of<LibraryService>(context, listen: false);

            await _loadSubtitles(paths);
            if (_currentItem != null) {
              String? path0;
              String? path1;

              if (paths.isNotEmpty) path0 = paths[0];
              if (paths.length > 1) path1 = paths[1];

              await library.updateVideoSubtitles(
                _currentItem!.id,
                path0,
                settings.autoCacheSubtitles,
                secondarySubtitlePath: path1,
                isSecondaryCached: settings.autoCacheSubtitles,
              );
              final updated = library.getVideo(_currentItem!.id);
              if (updated != null && mounted) {
                setState(() {
                  _currentItem = updated;
                });
              }
            }
          },
          onSubtitlePreview: (path) async {
            List<String> pathsToLoad = [path];
            if (_currentSubtitlePaths.length > 1) {
              pathsToLoad.add(_currentSubtitlePaths[1]);
            }
            await _loadSubtitles(pathsToLoad);
          },
          onOpenAi: () => _openSidebar(SidebarType.aiTranscription),
          onOpenOcrSubtitle:
              _supportsOcrSubtitle && !_isAudio && _currentItem != null
              ? _showOcrSubtitle
              : null,
          onClose: _closeSidebar,
        );

      case SidebarType.aiTranscription:
        String pathAi = _currentItem?.path ?? widget.videoFile?.path ?? "";
        if (pathAi.isEmpty) return null;

        return AiTranscriptionPanel(
          videoPath: pathAi,
          videoId: _currentItem?.id,
          sourceItem: _currentItem,
          onBack: _closeSidebar,
          onCompleted: (completion) async {
            // 只负责UI刷新，数据持久化已由 TranscriptionManager 处理
            final srtPath = completion.primaryPath;
            List<String> pathsToLoad = [srtPath];
            if (completion.translated) {
              pathsToLoad.add(completion.translationPath!);
            } else if (_currentSubtitlePaths.length > 1) {
              pathsToLoad.add(_currentSubtitlePaths[1]);
            }
            await _loadSubtitles(pathsToLoad);
          },
        );

      case SidebarType.videoCompose:
        if (_currentItem == null) return const SizedBox.shrink();
        final composeItem = _currentItem!;
        return VideoComposePanel(
          key: ValueKey('video_compose_${_currentItem!.id}'),
          videoItem: _currentItem!,
          currentSelectedPaths: List<String>.from(_currentSubtitlePaths),
          availableSubtitleMap: _buildAvailableSubtitleMap(),
          prepareSubtitleOptions: () =>
              _prepareComposeSubtitleOptions(composeItem),
          onBack: _closeSidebar,
          onOpenSubtitleStyle: () => _toggleFloatingSubtitleSettingsSidebar(),
          onOpenSubtitleManager: _showSubtitleManager,
          onPreviewChanged: _applyVideoComposePreview,
          beforeEnqueue: () async {
            _subtitlePositions.seal();
            await settings.flushSubtitlePositions();
          },
        );

      case SidebarType.ocrSubtitle:
        if (_currentItem == null || _isAudio) return const SizedBox.shrink();
        if (!_controllerAssigned || !_initialized) {
          return const Center(
            child: Text(
              '播放器加载完成后可使用 OCR 字幕',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        return OcrSubtitlePanel(
          key: ValueKey('ocr_subtitle_${_currentItem!.id}'),
          videoItem: _currentItem!,
          duration: _controller.value.duration,
          currentPosition: () => _controller.value.position,
          pauseForRegionSelection: () async {
            final wasPlaying = _controller.value.isPlaying;
            await _controller.pause();
            return wasPlaying;
          },
          restorePlayback: (wasPlaying) async {
            if (wasPlaying && mounted) await _controller.play();
          },
          onBack: _closeSidebar,
          onCompleted: _applyCompletedOcrSubtitles,
        );

      default:
        return null;
    }
  }

  Map<String, String> _buildAvailableSubtitleMap() {
    final Map<String, String> map = <String, String>{};
    if (_currentItem == null) return map;
    final additional = <String, String>{
      ..._currentItem!.downloadAssociatedSubtitles,
      ..._currentItem!.localSubtitleGroups,
    };
    final Map<String, String> nameByPath = <String, String>{};
    if (additional.isNotEmpty) {
      for (final entry in additional.entries) {
        if (entry.value.isEmpty) continue;
        nameByPath[_subtitlePathKey(entry.value)] = entry.key;
      }
    }
    String embeddedFallbackName(String path, String fallback) {
      final normalized = p.basename(path);
      final match = RegExp(r'\.stream_(\d+)').firstMatch(normalized);
      if (match != null) {
        final index = match.group(1);
        if (index != null && index.isNotEmpty) {
          return '内嵌字幕 $index';
        }
      }
      // 回退到文件名，避免显示"主字幕（主字幕）"这类冗余文本
      final base = p.basenameWithoutExtension(path).trim();
      return base.isNotEmpty ? base : fallback;
    }

    String nameForPath(String path, {String fallback = '未命名字幕'}) {
      final name = nameByPath[_subtitlePathKey(path)];
      if (name != null && name.trim().isNotEmpty) {
        return name;
      }
      return embeddedFallbackName(path, fallback);
    }

    final String? primary = _currentItem!.subtitlePath;
    if (primary != null && primary.isNotEmpty) {
      map[primary] = '主字幕（${nameForPath(primary, fallback: '主字幕')}）';
    }
    final String? secondary = _currentItem!.secondarySubtitlePath;
    if (secondary != null && secondary.isNotEmpty) {
      map[secondary] = '副字幕（${nameForPath(secondary, fallback: '副字幕')}）';
    }
    if (_currentSubtitlePaths.isNotEmpty) {
      for (int i = 0; i < _currentSubtitlePaths.length; i++) {
        final String path = _currentSubtitlePaths[i];
        if (path.isEmpty) continue;
        final String role = i == 0 ? '当前主字幕' : '当前副字幕';
        map[path] = '$role（${nameForPath(path, fallback: role)}）';
      }
    }
    if (additional.isNotEmpty) {
      for (final entry in additional.entries) {
        if (!map.containsKey(entry.value)) {
          map[entry.value] = entry.key;
        }
      }
    }
    return map;
  }
}
