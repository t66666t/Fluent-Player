import '../services/subtitle_editor_persistence.dart';
import '../widgets/bilibili_startup_poster.dart';
import '../widgets/mobile_system_navigation_bar.dart';
import '../services/subtitle_font_service.dart';
import '../services/subtitle_debug_session.dart';
import '../widgets/subtitle_debug_speed_gateway.dart';
import 'dart:async';
import '../services/drag_haptic_session.dart';
import 'dart:io';
import '../debug/developer_log.dart' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/keyboard_inset_padding.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/video_item.dart';
import '../models/media_source_ref.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';
import '../models/subtitle_style.dart';
import '../models/danmaku_style.dart';
import '../models/managed_subtitle_asset.dart';
import '../models/ocr_subtitle_models.dart';
import '../services/bilibili/bilibili_player_panel_memory.dart';
import '../services/bilibili/bilibili_player_panel_policy.dart';
import '../services/bilibili/bilibili_player_video.dart';
import '../widgets/bilibili_cover_image.dart';
import '../widgets/bilibili_player_panel.dart';
import '../widgets/bilibili_subtitle_tracks_section.dart';
import '../widgets/cloud_drive_subtitle_tracks_section.dart';
import '../features/cloud_drive/services/seek_preview_policy.dart';
import '../widgets/bilibili_portrait_tabs.dart';
import '../utils/bilibili_panel_tab_shortcuts.dart';
import '../services/bilibili/bilibili_danmaku_auto_update.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/bilibili/bilibili_video_shot_backfill.dart';
import '../services/library_service.dart';
import '../services/task_subtitle_storage_service.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../services/media_playback_service.dart';
import '../services/native_playback_control_session.dart';
import '../services/playback_navigation_service.dart';
import '../services/playback_behavior_policy.dart';
import '../services/playback_exit_guard.dart';
import '../utils/route_transition_work.dart';
import '../services/player_panel_history.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../services/video_compose/video_compose_preview_controller.dart';
import '../services/playlist_manager.dart';
import '../widgets/subtitle_sidebar.dart';
import '../widgets/subtitle_chat_sidebar.dart';
import '../widgets/portrait_player_panel_switcher.dart';
import '../widgets/portrait_playback_layout.dart';
import '../widgets/compact_stream_quality_layout.dart';
import '../widgets/subtitle_settings_sheet.dart';
import '../widgets/relocate_local_media_source.dart';
import '../widgets/playback_failure_panel.dart';
import '../widgets/video_controls_overlay.dart';
import '../widgets/playback_speed_dialog.dart';
import '../widgets/playback_mode_button.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/danmaku_settings_dialog.dart';
import '../widgets/subtitle_overlay.dart';
import '../widgets/subtitle_display_layer.dart';
import '../widgets/subtitle_position_hint.dart';
import '../models/subtitle_display_state.dart';
import '../widgets/settings_panel.dart';
import '../widgets/ai_transcription_panel.dart';
import '../services/transcription_manager.dart';
import '../services/ocr_subtitle_manager.dart';
import '../widgets/subtitle_management_sheet.dart';
import 'video_player_screen.dart'; // Landscape screen
import 'music_player_screen.dart'; // Experimental Apple Music page
import 'package:path/path.dart' as p;
import '../services/embedded_subtitle_service.dart';
import '../utils/app_toast.dart';
import '../utils/playback_page_visibility.dart';
import '../utils/stable_system_ui_insets.dart';
import '../models/subtitle_position.dart';
import '../services/subtitle_position_actions.dart';
import '../services/subtitle_position_controller.dart';
import '../utils/subtitle_file_picker.dart';

import '../widgets/episode_picker_panel.dart';
import '../widgets/video_compose_panel.dart';
import '../widgets/ocr_subtitle_panel.dart';
import '../features/ai_chat/ai_chat_panel.dart';
import '../features/ai_chat/ai_chat_layout.dart';
import '../widgets/subtitle_editor_panel.dart';
import '../widgets/mobile_system_bar_surface.dart';
import '../theme/app_tokens.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

enum PortraitPanel {
  subtitles,

  /// The Bilibili details tab of a Bilibili video. Like [subtitles] this is
  /// the panel shown when no other one is open.
  bilibili,
  settings,
  subtitleStyle,
  ai,
  subtitleManager,
  subtitleEditor,
  episodePicker,
  videoCompose,
  ocrSubtitle,
  aiChat,
}

class PortraitVideoScreen extends StatefulWidget {
  final VideoItem videoItem;
  final bool? autoPlayOnEntry;

  const PortraitVideoScreen({
    super.key,
    required this.videoItem,
    this.autoPlayOnEntry,
  });

  @override
  State<PortraitVideoScreen> createState() => _PortraitVideoScreenState();
}

class _PortraitVideoScreenState extends State<PortraitVideoScreen>
    with WidgetsBindingObserver, RouteAware {
  final GlobalKey<SelectionAreaState> _selectionKey =
      GlobalKey<SelectionAreaState>();
  final GlobalKey<SubtitleSidebarState> _subtitleSidebarKey =
      GlobalKey<SubtitleSidebarState>();
  final _subtitleViewportReady = ValueNotifier<bool>(true);
  final FocusNode _selectionFocusNode = FocusNode();
  final FocusNode _videoFocusNode =
      FocusNode(); // Dedicated focus node for video controls
  final FocusNode _playbackPageFocusNode = FocusNode(
    debugLabel: 'PortraitPlaybackPageShortcutFocus',
  );
  final GlobalKey<VideoControlsOverlayState> _controlsKey =
      GlobalKey<VideoControlsOverlayState>();
  final GlobalKey _portraitProgressGestureKey = GlobalKey();

  /// Last overlay chrome intent. Used when handing off to landscape so a
  /// hidden portrait overlay does not reopen on the landscape page.
  bool _playbackChromeVisible = true;
  final _playbackControlsVisibility = ValueNotifier<bool>(true);
  final GlobalKey _videoTextureKey = GlobalKey(
    debugLabel: 'PortraitPlaybackVideoTexture',
  );
  late VideoPlayerController _controller;
  bool _initialized = false;
  bool _pageEntryAutoPlayConsumed = false;
  bool _isControllerAssigned = false;

  /// The loading overlay is fully opaque. Keep VideoPlayer mounted whenever
  /// the assigned controller already has a decoded picture.
  bool get _hasDecodedVideoTexture {
    if (!_isControllerAssigned) return false;
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
    if (!_isControllerAssigned) return false;
    return identical(MediaPlaybackService().controller, _controller);
  }

  bool _musicCoverHidesVideoSurface = false;

  void _syncMusicCoverVideoSurface(MediaPlaybackService service) {
    final hides = service.musicCoverOwnsVideoSurface;
    if (hides == _musicCoverHidesVideoSurface) return;
    setState(() => _musicCoverHidesVideoSurface = hides);
  }

  /// Never mount [VideoPlayer] until the assigned controller is still the
  /// service's live player. The landscape music cover borrows the same
  /// output and this page only drops the view while that card is showing it.
  bool get _shouldKeepVideoSurface => shouldKeepPlaybackVideoSurface(
    controllerIsCurrent: _pageControllerIsCurrent,
    initialized: _initialized,
    hasDecodedTexture: _hasDecodedVideoTexture,
    musicCoverOwnsSurface: _musicCoverHidesVideoSurface,
  );

  bool get _isCurrentBilibiliOnlineStream => false;

  /// Poster over an empty texture until the first decoded frame arrives.
  Widget _buildVisibleVideoFrameCover() {
    return ListenableBuilder(
      listenable: MediaPlaybackService(),
      builder: (context, _) {
        final playback = MediaPlaybackService();
        if (_isCurrentBilibiliOnlineStream || playback.onlineStartup != null) {
          return BilibiliStartupPoster(
            startup: playback.currentItem?.id == _currentItem.id
                ? playback.onlineStartup
                : null,
            thumbnailPath: _currentItem.thumbnailPath,
            covered: playback.isCoveringUntilVisibleVideoFrame,
            onRetry: () => unawaited(playback.retryOnlineStartup()),
          );
        }
        if (!MediaPlaybackService().isCoveringUntilVisibleVideoFrame) {
          return const SizedBox.shrink();
        }
        final path = _currentItem.thumbnailPath;
        if (path != null && path.isNotEmpty && File(path).existsSync()) {
          return IgnorePointer(
            child: Image.file(
              File(path),
              // Already clipped to the video. Contain keeps a 16:10 cover
              // from cropping in and looking bigger than the frame.
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

  bool _isSourceMissing = false;
  String? _playbackFailure;
  int _danmakuRevision = 0;
  bool _isControllerOwner = false;
  bool _isOrientationSetup = false;
  bool get _supportsOcrSubtitle =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;
  List<SubtitleItem> _subtitles = [];
  List<SubtitleItem> _secondarySubtitles = [];
  List<String> _currentSubtitlePaths = [];
  int _subtitleRevision = -1;

  // Shared State Logic
  bool _isLocked = false;
  bool _isLongPressing = false;
  String _longPressFeedbackText = "";
  double _preLongPressSpeed = 1.0;
  MediaPlaybackService? _longPressPlaybackService;
  String _currentSubtitleText = "";
  String? _currentSecondaryText;
  int _currentSubtitleIndex = -1;
  int _currentSecondarySubtitleIndex = -1;
  List<int> _currentSubtitleIndices = [];
  List<int> _currentSecondarySubtitleIndices = [];
  List<SubtitleOverlayEntry> _currentSubtitleEntries = [];
  final VideoComposePreviewController _videoComposePreviewController =
      VideoComposePreviewController();
  bool _videoComposePreviewActive = false;
  final Map<int, Uint8List?> _currentSubtitleImages = <int, Uint8List?>{};
  int _subtitleImageRequestId = 0;
  SubtitleTimelineResolver _subtitleTimeline = SubtitleTimelineResolver(
    const <SubtitleItem>[],
  );
  SubtitleTimelineResolver _secondarySubtitleTimeline =
      SubtitleTimelineResolver(const <SubtitleItem>[]);
  Timer? _subtitleSeekTimer;
  final SubtitlePositionController _subtitlePositions =
      SubtitlePositionController();
  bool _isSubtitleDragMode = false;
  String? _subtitlePositionError;
  bool _isSubtitleSnappedX = false;
  bool _isSubtitleSnappedY = false;
  bool _isSubtitleNearCenterX = false;
  bool _isSubtitleNearCenterY = false;
  bool _isStylePanelDragMode = false;
  PortraitPanel _activePanel = _panelOf(portraitDefaultPanel());
  final _panelHistory = PlayerPanelHistory<PortraitPanel>();
  int _panelNavigationVersion = 0;

  /// The 「详情 | 字幕」 tab the loading page left this page on; it wins over
  /// the remembered one until the switch here is tapped.
  PortraitBilibiliTab? _portraitTabHandedOff;
  bool get _suppressSubtitleOverlayForOcr =>
      _activePanel == PortraitPanel.ocrSubtitle;
  bool _isSubtitleEditorExpanded = false;

  // Bottom Control Bar State
  bool _isDraggingProgress = false;
  double _dragProgressValue = 0.0;
  bool _isProgressDragCanceling = false;
  bool _progressDragWasCancelled = false;
  final _progressHaptics = DragHapticSession();
  final bool _showVolumeSlider = false;
  final LayerLink _volumeButtonLayerLink = LayerLink();

  bool _routeObserverSubscribed = false;
  bool _isPushingLandscape = false;
  // True for the whole landscape round trip (push -> pop -> remount). While it
  // is set, didPopNext / MediaPlaybackService notifications must not start a
  // second _initPlayer: the round-trip continuation owns controller
  // remounting, and a concurrent init reloads the media and races the
  // restoration (blank video output on Android).
  bool _isRestoringFromLandscape = false;
  bool _isOpeningMusicPlayer = false;
  bool _pendingSubtitleSidebarViewportRestore = false;
  bool _subtitleSidebarRestoreCallbackScheduled = false;
  int _subtitleSidebarRestoreRetries = 0;
  static const int _subtitleSidebarRestoreMaxRetries = 30;

  /// 状态栏/底部触控条的稳定安全区预留。
  ///
  /// 退出沉浸式横屏页时系统栏带回场动画，实时 MediaQuery.padding 会被逐帧
  /// 压缩底部字幕面板（"被触控条挤一下"）。这里记住稳定值并作为 SafeArea 的
  /// minimum 使用，系统栏显示/隐藏不再改变页面几何。
  late final StableSystemUiInsetController _systemUiInsetController =
      StableSystemUiInsetController(
        includeSystemGestureInsets: true,
        onChanged: () {
          if (mounted) setState(() {});
        },
      );
  bool _forceExit = false;
  bool _explicitPlaybackExitRequested = false;
  final PlaybackExitGuard _exitGuard = PlaybackExitGuard();
  Future<void>? _exitCleanupFuture;
  bool _iosBackSwipeActive = false;
  double _iosBackSwipeDistance = 0.0;
  static const double _iosBackSwipeEdgeWidth = 20.0;
  static const double _iosBackSwipeTriggerDistance = 60.0;
  TranscriptionManager? _transcriptionManager;
  OcrSubtitleManager? _ocrSubtitleManager;

  // Audio state
  bool _isAudio = false;
  late VideoItem _currentItem;
  SettingsService? _settingsService;
  late SettingsService _exitSettings;
  late MediaPlaybackService _exitPlaybackService;
  late LibraryService _exitLibraryService;
  MediaPlaybackService? _subtitlePlaybackService;
  bool _elementActive = true;
  bool? _lastShowSubtitles;
  Duration? _lastSubtitleOffset;
  bool? _lastSplitSubtitleByLine;
  bool? _lastVideoContinuousSubtitle;
  bool? _lastAudioContinuousSubtitle;
  bool? _lastSkipPortraitPlayer;
  bool? _lastIsPlayingForServiceSync;
  String? _autoEmbeddedAttemptedForItemId;
  bool _isLoadingEmbeddedSubtitle = false;
  String? _embeddedSubtitleError;
  String? _embeddedSubtitleErrorMediaKey;
  bool _embeddedSubtitleDetected = false;

  Timer? _customAspectDraftSaveTimer;
  int _postInitWorkToken = 0;
  final _routeWork = RouteTransitionWork();

  bool _isImageSubtitleCodec(String codecName) {
    final codec = codecName.toLowerCase();
    return codec == 'hdmv_pgs_subtitle' ||
        codec == 'dvd_subtitle' ||
        codec == 'pgs' ||
        codec == 'pgs_subtitle' ||
        codec == 'vobsub' ||
        codec == 'xsub';
  }

  @override
  void initState() {
    super.initState();
    _bindSubtitlePositions();
    _currentItem = widget.videoItem;
    _portraitTabHandedOff = BilibiliPortraitTabMemory.takeHandOff(
      widget.videoItem.id,
    );
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_handlePlaybackEarlyKeyEvent);
    _showSystemBars();
    // Orientation is handled in didChangeDependencies to support tablet adaptive layout
    _initPlayer();
    _scheduleVideoFocusRestore();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        playbackService.addListener(_onPlaybackServiceChange);
        _subtitlePlaybackService = playbackService;
        playbackService.positionNotifier.addListener(
          _onSubtitlePositionChanged,
        );
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
      _lastSkipPortraitPlayer = settings.skipPortraitPlayer;
      settings.addListener(_onSettingsChanged);
      _onSettingsChanged();
    });
  }

  void _scheduleVideoFocusRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
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

  void _onSettingsChanged() {
    final settings = _settingsService;
    if (settings == null) return;

    // 「跳过竖屏播放页」需独立于字幕缓存比对，在字幕无关的设置变更中也
    // 能即时响应（off→on 边沿触发一次）。
    _handleSkipPortraitPlayerChanged(settings.skipPortraitPlayer);

    final bool changed =
        _lastShowSubtitles != settings.showSubtitles ||
        _lastSubtitleOffset != settings.subtitleOffset ||
        _lastSplitSubtitleByLine != settings.splitSubtitleByLine ||
        _lastVideoContinuousSubtitle != settings.videoContinuousSubtitle ||
        _lastAudioContinuousSubtitle != settings.audioContinuousSubtitle;

    if (!changed) return;

    _lastShowSubtitles = settings.showSubtitles;
    _lastSubtitleOffset = settings.subtitleOffset;
    _lastSplitSubtitleByLine = settings.splitSubtitleByLine;
    _lastVideoContinuousSubtitle = settings.videoContinuousSubtitle;
    _lastAudioContinuousSubtitle = settings.audioContinuousSubtitle;

    if (_initialized) {
      _updateSubtitle();
    }
  }

  /// 「跳过竖屏播放页」在竖屏页内被打开时，立即切入横屏播放页。
  ///
  /// 仅在 off→on 边沿触发一次，且要求当前路由位于栈顶、没有正在进行的
  /// 横屏跳转，避免横屏页覆盖本页时误触发或重复导航。
  void _handleSkipPortraitPlayerChanged(bool enabled) {
    final bool? previous = _lastSkipPortraitPlayer;
    _lastSkipPortraitPlayer = enabled;
    if (previous != false || !enabled) return;
    if (!mounted || _isPushingLandscape) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _goToLandscape();
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
    currentItem.showFloatingSubtitles = value;
  }

  void _scheduleDeferredPostInitWork(VideoItem item) {
    final int token = ++_postInitWorkToken;
    _routeWork.schedule('post-init', () {
      if (!mounted ||
          token != _postInitWorkToken ||
          _currentItem.id != item.id) {
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
      unawaited(_runDeferredPostInitWork(item, token));
    });
  }

  Future<void> _scheduleDanmakuAutoUpdate(VideoItem item, int token) async {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
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
          mounted && token == _postInitWorkToken && _currentItem.id == item.id,
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
        if (!mounted || _currentItem.id != item.id) return;
        setState(() => _danmakuRevision++);
      },
    );
  }

  void _applyDeferredDanmakuReload() {
    final autoUpdate = BilibiliDanmakuAutoUpdate.instance;
    if (!autoUpdate.hasPendingVisual(_currentItem.id)) return;
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
      videoId: _currentItem.id,
      position: position,
      playing: playing,
    )) {
      return;
    }
    setState(() => _danmakuRevision++);
  }

  Future<void> _runDeferredPostInitWork(VideoItem item, int token) async {
    if (!mounted || token != _postInitWorkToken) return;
    _checkAndLoadAiSubtitle(item);

    if (item.subtitlePath != null) {
      final List<String> paths = [item.subtitlePath!];
      if (item.secondarySubtitlePath != null) {
        paths.add(item.secondarySubtitlePath!);
      }
      await _loadSubtitles(paths);
    } else {
      final loadedAssociated = await _tryLoadAssociatedSubtitleAsPrimary(item);
      if (!loadedAssociated && mounted && token == _postInitWorkToken) {
        _maybeAutoLoadEmbeddedSubtitle();
      }
    }

    if (!mounted || token != _postInitWorkToken) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && token == _postInitWorkToken) {
        _updateSubtitle();
      }
    });
  }

  void _bindControllerListener() {
    try {
      _controller.removeListener(_videoListener);
    } catch (_) {}
    _controller.addListener(_videoListener);
  }

  bool _tryAdoptBilibiliQualityHandoff(MediaPlaybackService service) {
    final replacement = service.controller;
    // Same-item replacements must keep the page initialized. The loading
    // branch covers an already-decoded picture with a black overlay.
    if (replacement == null ||
        service.currentItem?.id != _currentItem.id ||
        !service.canMountControllerFor(
          _currentItem.id,
          controller: replacement,
        ) ||
        !_isControllerAssigned ||
        identical(_controller, replacement) ||
        !replacement.value.isInitialized) {
      return false;
    }

    final previousController = _controller;
    try {
      previousController.removeListener(_videoListener);
    } catch (_) {}

    setState(() {
      _controller = replacement;
      _isControllerAssigned = true;
      _isControllerOwner = false;
      _isSourceMissing = false;
      _initialized = true;
      _lastIsPlayingForServiceSync = replacement.value.isPlaying;
    });
    _bindControllerListener();
    _syncSubtitlesFromService(service);
    return true;
  }

  void _showMissingSource(VideoItem item) {
    if (_isSourceMissing) return;

    VideoPlayerController? previousController;
    final bool disposePrevious = _isControllerAssigned && _isControllerOwner;
    if (_isControllerAssigned) {
      previousController = _controller;
      try {
        previousController.removeListener(_videoListener);
      } catch (_) {}
    }

    _isControllerAssigned = false;
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
      _lastIsPlayingForServiceSync = false;
    });
  }

  void _onPlaybackServiceChange() {
    if (!mounted) return;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    final nextItem = service.currentItem;
    if (nextItem != null && nextItem.id != _currentItem.id) {
      _progressHaptics.reset();
      _panelNavigationVersion++;
      _panelHistory.clear();
      _resetPanelEditing();
      _portraitTabHandedOff = BilibiliPortraitTabMemory.takeHandOff(
        nextItem.id,
      );
      _subtitleStyleFromCompose = false;
      _clearVideoComposePreview();
      final base = _panelOf(
        portraitDefaultPanel(
          isBilibiliVideo: false,
          rememberedTab: _portraitTab,
        ),
      );
      if (!_isDefaultPanel) {
        _panelHistory.open(current: base, target: _activePanel);
      }
    }
    _syncMusicCoverVideoSurface(service);
    // Do not let a controller-loading/replacement branch swallow the only
    // notification that an automatic subtitle download has completed.
    _syncSubtitlesFromService(service);

    // 检查当前路由是否在最顶层（即竖屏页是否可见）
    // 如果不在最顶层（被横屏页覆盖），则不处理控制器变更，只更新字幕等状态
    final bool isOnTop = ModalRoute.of(context)?.isCurrent ?? false;

    if (service.currentItem?.id == _currentItem.id && service.isSourceMissing) {
      _showMissingSource(service.currentItem!);
      _syncSubtitlesFromService(service);
      return;
    }
    if (service.currentItem?.id == _currentItem.id &&
        service.state == PlaybackState.error) {
      _detachStalePageController();
      final message =
          service.onlineStartup?.failure ??
          (service.session.error?.startsWith('画面恢复失败') == true
              ? '画面恢复失败，请重试'
              : '播放失败，请重试');
      if (_playbackFailure != message) {
        setState(() => _playbackFailure = message);
      }
      return;
    }
    if (_playbackFailure != null) {
      setState(() => _playbackFailure = null);
    }
    if (service.currentItem?.id == _currentItem.id &&
        service.state == PlaybackState.loading &&
        _isSourceMissing) {
      setState(() => _isSourceMissing = false);
    }

    if (_tryAdoptBilibiliQualityHandoff(service)) return;

    if (_isRestoringFromLandscape) {
      // Drop a released controller so a rebuild cannot paint it, but leave
      // remounting to the landscape-return continuation.
      if (_holdsStalePageController(service)) {
        _detachStalePageController();
      }
      // Landscape round trip in flight: the round-trip continuation owns
      // controller remounting on return. A concurrent _initPlayer here
      // previously double-initialized the player (media reloaded from scratch)
      // and could leave the portrait page with a blank video output. Keep
      // tracking item fields so the continuation never reinitializes a stale
      // item, but never start _initPlayer within this window.
      final serviceItem = service.currentItem;
      if (serviceItem != null && _currentItem.id != serviceItem.id) {
        setState(() {
          _currentItem = serviceItem;
          _isAudio = serviceItem.type == MediaType.audio;
          _isSourceMissing = false;
        });
      }
      _syncSubtitlesFromService(service);
      return;
    }

    if (service.currentItem != null &&
        service.currentItem!.id != _currentItem.id) {
      // 视频发生变化
      if (isOnTop) {
        // 竖屏页在最顶层，正常处理视频切换
        setState(() {
          _currentItem = service.currentItem!;
          _isAudio = service.currentItem!.type == MediaType.audio;
          _isSourceMissing = false;
          _initialized = false;
          _isControllerAssigned = false;
          _subtitles = [];
          _secondarySubtitles = [];
          _currentSubtitlePaths = [];
          _currentSubtitleText = "";
          _currentSecondaryText = null;
          _currentSubtitleIndex = -1;
          _currentSecondarySubtitleIndex = -1;
          _currentSubtitleIndices = [];
          _currentSecondarySubtitleIndices = [];
          _currentSubtitleEntries = [];
          _currentSubtitleImages.clear();
          _autoEmbeddedAttemptedForItemId = null;
          _embeddedSubtitleDetected = false;
        });
        _applyItemSubtitlePreference(service.currentItem!, force: true);
        _postInitWorkToken++;
        _initPlayer();
      } else {
        // 竖屏页在后台（被横屏页覆盖），只更新当前项信息，不处理控制器
        // 这样当返回竖屏页时，会重新同步状态
        setState(() {
          _currentItem = service.currentItem!;
          _isAudio = service.currentItem!.type == MediaType.audio;
          _isSourceMissing = false;
          _initialized = false;
          _isControllerAssigned = false;
        });
        // 不调用 _initPlayer，让页面重新可见时再处理
      }
      _syncSubtitlesFromService(service);
    } else if (_holdsStalePageController(service)) {
      // Includes stop() clearing the session (current item becomes null).
      // The same-id branch below never sees that, and the page would keep
      // painting the disposed player.
      _detachStalePageController();
      if (service.currentItem?.id == _currentItem.id &&
          (service.state == PlaybackState.loading ||
              service.canMountControllerFor(_currentItem.id))) {
        _postInitWorkToken++;
        _initPlayer();
      }
      return;
    } else if (service.currentItem?.id == _currentItem.id &&
        service.canMountControllerFor(_currentItem.id) &&
        (!_initialized ||
            !_isControllerAssigned ||
            !identical(_controller, service.controller))) {
      if (_isControllerAssigned &&
          !identical(_controller, service.controller)) {
        final previousController = _controller;
        final shouldDisposePrevious = _isControllerOwner;
        try {
          previousController.removeListener(_videoListener);
        } catch (_) {}
        setState(() {
          _isControllerAssigned = false;
          _isControllerOwner = false;
        });
        if (shouldDisposePrevious) {
          unawaited(previousController.dispose());
        }
      }
      // Same item became mountable again (loading finished / recovery).
      _postInitWorkToken++;
      _initPlayer();
    } else if (service.currentItem?.id == _currentItem.id) {
      _syncSubtitlesFromService(service);
    }
  }

  bool _holdsStalePageController(MediaPlaybackService service) {
    return _isControllerAssigned && !identical(_controller, service.controller);
  }

  void _detachStalePageController() {
    if (!_isControllerAssigned) return;
    try {
      _controller.removeListener(_videoListener);
    } catch (_) {}
    final previous = _controller;
    final shouldDispose = _isControllerOwner;
    setState(() {
      _isControllerAssigned = false;
      _isControllerOwner = false;
      _initialized = false;
    });
    if (shouldDispose) {
      unawaited(previous.dispose());
    }
  }

  /// Sync subtitle state from [MediaPlaybackService] to local state if the
  /// service's subtitle data differs from the local copy. Called from
  /// [_onPlaybackServiceChange] for live updates and from [_goToLandscape]'s
  /// continuation to catch any subtitle changes that occurred while the
  /// portrait page was in the background (covered by the landscape page).
  void _syncSubtitlesFromService(MediaPlaybackService service) {
    if (!mounted) return;
    if (service.currentItem?.id != _currentItem.id) return;

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
        _currentSubtitlePaths = List<String>.from(service.subtitlePaths);
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
      _currentSubtitleIndex = -1;
      _currentSecondarySubtitleIndex = -1;
      _currentSubtitleIndices = [];
      _currentSecondarySubtitleIndices = [];
      _currentSubtitleEntries = [];
      _currentSubtitleImages.clear();
    });
    _rebuildSubtitleIndex();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateSubtitle();
    });
  }

  Matrix4 _buildVideoDisplayTransformMatrix() {
    return Matrix4.identity()..multiply(
      Matrix4.diagonal3Values(
        _currentItem.isVideoMirroredH ? -1.0 : 1.0,
        _currentItem.isVideoMirroredV ? -1.0 : 1.0,
        1.0,
      ),
    );
  }

  Future<void> _updateVideoDisplayTransform({
    bool? isMirroredH,
    bool? isMirroredV,
  }) async {
    final bool nextMirroredH = isMirroredH ?? _currentItem.isVideoMirroredH;
    final bool nextMirroredV = isMirroredV ?? _currentItem.isVideoMirroredV;

    setState(() {
      _currentItem.isVideoMirroredH = nextMirroredH;
      _currentItem.isVideoMirroredV = nextMirroredV;
    });

    final library = Provider.of<LibraryService>(context, listen: false);
    await library.updateVideoDisplayTransform(
      _currentItem.id,
      isMirroredH: nextMirroredH,
      isMirroredV: nextMirroredV,
    );
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
    final normalizedPrimary = p.normalize(subtitlePath);
    final currentPrimary = _currentItem.subtitlePath == null
        ? null
        : p.normalize(_currentItem.subtitlePath!);
    if (currentPrimary == normalizedPrimary) return;
    try {
      final settingsService = Provider.of<SettingsService>(
        context,
        listen: false,
      );
      final libraryService = Provider.of<LibraryService>(
        context,
        listen: false,
      );
      await libraryService.updateVideoSubtitles(
        _currentItem.id,
        normalizedPrimary,
        settingsService.autoCacheSubtitles,
        secondarySubtitlePath: secondarySubtitlePath,
        isSecondaryCached: settingsService.autoCacheSubtitles,
      );
      if (mounted) {
        final updated = libraryService.getVideo(_currentItem.id);
        if (updated != null) {
          setState(() {
            _currentItem = updated;
          });
        }
      }
    } catch (_) {}
  }

  Future<bool> _tryLoadAssociatedSubtitleAsPrimary(VideoItem item) async {
    if (item.blockAutoAssociatedSubtitleSelection) {
      return false;
    }
    final associatedPath = _resolveFirstAssociatedSubtitlePath(item);
    if (associatedPath == null) {
      return false;
    }

    await _persistPrimarySubtitlePathIfNeeded(
      associatedPath,
      secondarySubtitlePath: item.secondarySubtitlePath,
    );
    if (!mounted) {
      return true;
    }

    final refreshedItem = _currentItem;
    final primaryPath = refreshedItem.subtitlePath ?? associatedPath;
    final paths = <String>[primaryPath];
    final secondaryPath = refreshedItem.secondarySubtitlePath;
    if (secondaryPath != null &&
        secondaryPath.isNotEmpty &&
        secondaryPath != primaryPath) {
      paths.add(secondaryPath);
    }
    await _loadSubtitles(paths);
    return true;
  }

  void _maybeAutoLoadEmbeddedSubtitle() {
    if (isCloudDriveMedia(
      source: _currentItem.sourceRef,
      path: _currentItem.path,
    )) {
      return;
    }
    final currentId = _currentItem.id;
    if (_currentItem.blockAutoAssociatedSubtitleSelection) return;
    if (_currentItem.prefersManagedAssociatedSubtitles) return;
    if (_currentItem.hasAttemptedAutoEmbeddedSubtitleLoad) return;
    if (_autoEmbeddedAttemptedForItemId == currentId) return;
    if (_currentItem.subtitlePath != null) return;
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

    _currentItem.hasAttemptedAutoEmbeddedSubtitleLoad = true;
    _persistAutoEmbeddedAttemptedFlag(currentId);
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeWork.bind(ModalRoute.of(context));
    // Exit/dispose can run after this element loses its inherited context.
    _exitSettings = context.read<SettingsService>();
    _exitPlaybackService = context.read<MediaPlaybackService>();
    _exitLibraryService = context.read<LibraryService>();
    if (!_isOrientationSetup) {
      _updateOrientations();
      _isOrientationSetup = true;
    }
    if (!_routeObserverSubscribed) {
      final route = ModalRoute.of(context);
      if (route is PageRoute) {
        AppToast.routeObserver.subscribe(this, route);
        _routeObserverSubscribed = true;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      registerPlaybackPageIfCurrent(context, this);
    });

    // Listen to TranscriptionManager for auto-mounting subtitles
    final manager = Provider.of<TranscriptionManager>(context, listen: false);
    if (_transcriptionManager != manager) {
      _transcriptionManager?.removeListener(_onTranscriptionUpdate);
      _transcriptionManager = manager;
      _transcriptionManager?.addListener(_onTranscriptionUpdate);
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
    if (_currentItem.id == job.videoId) {
      unawaited(_applyCompletedOcrSubtitles(paths));
    }
  }

  void _onTranscriptionUpdate() {
    if (!mounted || _transcriptionManager == null) return;

    final stream = _transcriptionManager!.streamForVideo(
      _currentItem.path,
      videoId: _currentItem.id,
    );
    if (_transcriptionManager!.hasSubtitleStreamForVideo(
      _currentItem.path,
      videoId: _currentItem.id,
    )) {
      if (stream?.complete ?? true) {
        _transcriptionManager!.consumeResultNotificationForVideo(
          _currentItem.path,
          videoId: _currentItem.id,
        );
      }
      return;
    }

    final path = _transcriptionManager!.getGeneratedSrtPathForVideo(
      _currentItem.path,
      videoId: _currentItem.id,
    );
    if (path != null &&
        _transcriptionManager!.consumeResultNotificationForVideo(
          _currentItem.path,
          videoId: _currentItem.id,
        )) {
      final translation = _transcriptionManager!
          .getGeneratedTranslationPathForVideo(
            _currentItem.path,
            videoId: _currentItem.id,
          );
      List<String> pathsToLoad = [path];
      if (translation != null) {
        pathsToLoad.add(translation);
      } else if (_currentSubtitlePaths.length > 1) {
        pathsToLoad.add(_currentSubtitlePaths[1]);
      }

      // Auto load
      _loadSubtitles(pathsToLoad);

      // 不需要在这里保存到 library，TranscriptionManager 已经保存了
    }
  }

  void _checkAndLoadAiSubtitle(VideoItem currentItem) {
    try {
      final manager = Provider.of<TranscriptionManager>(context, listen: false);
      if (manager.hasSubtitleStreamForVideo(
        currentItem.path,
        videoId: currentItem.id,
      )) {
        return;
      }

      final srtPath = manager.getGeneratedSrtPathForVideo(
        currentItem.path,
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
            currentItem.path,
            videoId: currentItem.id,
          );
        }
      }
    } catch (e) {
      debugPrint("检查AI字幕失败: $e");
    }
  }

  void _updateOrientations() {
    final size = MediaQuery.sizeOf(context);
    final isTablet = size.shortestSide >= 600;
    SystemChrome.setPreferredOrientations(
      isTablet
          ? const <DeviceOrientation>[
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const <DeviceOrientation>[
              DeviceOrientation.portraitUp,
              DeviceOrientation.portraitDown,
            ],
    );
  }

  bool _isPortraitSidebarViewportReady() {
    final size = MediaQuery.maybeSizeOf(context);
    if (size == null) return false;
    // Tablets intentionally keep the portrait-player layout available in
    // either physical orientation. Phones must wait for the actual portrait
    // metrics; locating against the transient landscape viewport can leave
    // ScrollablePositionedList with no painted children after the pop.
    return size.shortestSide >= 600 || size.height >= size.width;
  }

  void _requestSubtitleSidebarViewportRestore() {
    _pendingSubtitleSidebarViewportRestore = true;
    _subtitleSidebarRestoreRetries = 0;
    _tryRestoreSubtitleSidebarForCurrentViewport();
  }

  void _tryRestoreSubtitleSidebarForCurrentViewport() {
    if (!mounted ||
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
      if (!mounted || !_pendingSubtitleSidebarViewportRestore) return;
      if (ModalRoute.of(context)?.isCurrent != true ||
          !_isPortraitSidebarViewportReady()) {
        return;
      }
      if (_shownPanel != PortraitPanel.subtitles) {
        _pendingSubtitleSidebarViewportRestore = false;
        return;
      }

      final sidebar = _subtitleSidebarKey.currentState;
      if (sidebar == null) {
        _scheduleSubtitleSidebarRestoreRetry();
        return;
      }
      // Route restoration is a viewport repair, not playback auto-follow. It
      // must run while paused and when automatic following is disabled.
      if (!sidebar.locateToCurrentSubtitle(ignorePointer: true)) {
        // 面板/列表尚未就绪（切页瞬间仍在用横屏尺寸布局）。请求保持挂起并
        // 在后续帧重试，避免修复被静默丢弃后文稿停在空白状态。
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

  @override
  void didPush() {
    MediaPlaybackService().setPlaybackPageVisible(this, true);
    _showSystemBars();
  }

  @override
  void didPopNext() {
    MediaPlaybackService().setPlaybackPageVisible(this, true);
    _showSystemBars();
    _scheduleVideoFocusRestore();
    // The shared player may have replaced its controller or advanced to a
    // different item while MusicPlayerScreen covered this route. No further
    // service notification is guaranteed after the pop, so explicitly adopt
    // the authoritative controller before rebuilding the bottom controls.
    _onPlaybackServiceChange();
    final playbackService = MediaPlaybackService();
    // While a landscape round trip is unwinding, its continuation remounts the
    // controller itself; starting _initPlayer here as well would race it.
    if (!_isRestoringFromLandscape &&
        !_isControllerAssigned &&
        (playbackService.state != PlaybackState.loading ||
            playbackService.hasMountableController) &&
        playbackService.currentItem != null) {
      _postInitWorkToken++;
      unawaited(_initPlayer());
    }
    // RouteAware also reports dialogs and unrelated child pages. Only a
    // landscape-player pop owns this viewport repair; otherwise returning
    // from settings could unexpectedly move a manually scrolled transcript.
    if (_isPushingLandscape) {
      _requestSubtitleSidebarViewportRestore();
    }
  }

  @override
  void didPushNext() {
    _progressHaptics.reset();
    if (_isPushingLandscape) return;
    if (!_isOpeningMusicPlayer) {
      unawaited(
        pausePlaybackPageWhenCovered(
          coveringRoute: AppToast.routeObserver.coveringRoute,
          settings: _exitSettings,
          playbackService: _exitPlaybackService,
          itemId: _currentItem.id,
          controller: _isControllerAssigned ? _controller : null,
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

  void _setEmbeddedSubtitleError(String mediaKey, String? message) {
    if (!mounted || (_currentItem.id) != mediaKey) return;
    setState(() {
      _embeddedSubtitleErrorMediaKey = mediaKey;
      _embeddedSubtitleError = message;
    });
  }

  Future<void> _checkAndLoadEmbeddedSubtitle() async {
    // If we already have subtitles loaded (e.g. from file), don't override
    if (_subtitles.isNotEmpty) return;
    if (_isLoadingEmbeddedSubtitle) return;

    // Determine video path
    String path = _currentItem.path;
    if (path.startsWith('bilibili://stream/')) return;

    final mediaKey = _currentItem.id;
    _setEmbeddedSubtitleError(mediaKey, null);
    // Check embedded
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      _isLoadingEmbeddedSubtitle = true;
      final service = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
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

        final settings = Provider.of<SettingsService>(context, listen: false);
        final subDir = await const TaskSubtitleStorageService().taskDirectory(
          _currentItem.id,
          create: true,
        );

        // Extract
        final extractedPath = await service.extractSubtitle(
          path,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: _currentItem.id,
        );

        if (extractedPath != null) {
          await library.registerManagedSubtitleAsset(
            _currentItem.id,
            path: extractedPath,
            kind: ManagedSubtitleAssetKind.embedded,
            displayName: track.title,
          );
        }

        if (extractedPath != null && mounted) {
          // Check again
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

          if (_currentItem.subtitlePath == null) {
            try {
              final String? currentSecondary = _currentSubtitlePaths.length > 1
                  ? _currentSubtitlePaths[1]
                  : _currentItem.secondarySubtitlePath;
              await library.updateVideoSubtitles(
                _currentItem.id,
                extractedPath,
                settings.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settings.autoCacheSubtitles,
              );
              final updated = library.getVideo(_currentItem.id);
              if (updated != null && mounted) {
                setState(() {
                  _currentItem = updated;
                });
              }
            } catch (_) {}
          }

          if (!mounted) return;
        } else if (mounted && extractedPath == null) {
          _setEmbeddedSubtitleError(mediaKey, '内嵌字幕未能提取，请重试或选择其他字幕。');
        }
      } else {
        if (mounted) {
          if (_embeddedSubtitleDetected) {
            setState(() {
              _embeddedSubtitleDetected = false;
            });
          }
        }
      }
    } catch (e) {
      debugPrint("Auto load embedded subtitle failed: $e");
      if (mounted) {
        if (_embeddedSubtitleDetected) {
          setState(() {
            _embeddedSubtitleDetected = false;
          });
        }
        _setEmbeddedSubtitleError(mediaKey, '内嵌字幕未能读取，请重试或选择其他字幕。');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingEmbeddedSubtitle = false);
      } else {
        _isLoadingEmbeddedSubtitle = false;
      }
    }
  }

  Future<void> _initPlayer() async {
    // Refresh video item
    VideoItem currentItem = _currentItem;
    try {
      final libItem = Provider.of<LibraryService>(
        context,
        listen: false,
      ).getVideo(currentItem.id);
      if (libItem != null && libItem.lastUpdated >= currentItem.lastUpdated) {
        currentItem = libItem;
      }
    } catch (e) {
      debugPrint("Error refreshing item: $e");
    }
    _currentItem = currentItem;
    if (mounted) {
      _routeWork.schedule('video-shot', () {
        if (!mounted || _currentItem.id != currentItem.id) return;
        scheduleBilibiliVideoShotBackfill(
          context: context,
          item: currentItem,
          isStillCurrent: () => mounted && _currentItem.id == currentItem.id,
          onUpdated: () {
            if (mounted) setState(() {});
          },
        );
      });
    }
    _applyItemSubtitlePreference(currentItem, force: true);
    // Check if this is audio
    _isAudio = currentItem.type == MediaType.audio;

    final visiblePlaybackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    visiblePlaybackService.setPlaybackPageVisible(this, true);
    if (visiblePlaybackService.needsVisibleVideoOutputRecovery(
      currentItem.id,
    )) {
      unawaited(
        visiblePlaybackService.ensureVisibleVideoOutput(currentItem.id),
      );
    }

    // 检查 MediaPlaybackService 状态
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
          "PortraitVideoScreen: Waiting for service to load ${currentItem.title}",
        );
        if (mounted && !(_initialized && _isControllerAssigned)) {
          setState(() {
            _initialized = false;
          });
        }
        return;
      }

      // 如果 Service 已经有这个视频的 controller，直接复用
      if (playbackService.canMountControllerFor(currentItem.id)) {
        // 如果之前持有本地 controller，先释放，防止声音重叠
        if (_isControllerAssigned && _isControllerOwner) {
          try {
            _controller.removeListener(_videoListener);
            _controller.dispose();
          } catch (e) {
            debugPrint("Error disposing old controller: $e");
          }
        }

        // 使用现有的 controller
        _controller = playbackService.controller!;
        _isControllerAssigned = true;
        _isControllerOwner = false; // 不拥有这个 controller，不应该 dispose

        if (!mounted) return;

        // Mark the texture visible before the aspect-ratio persist await.
        // That await yields; a rebuild in the gap used to swap in the opaque
        // loading overlay and unmount an already-decoded Bilibili picture.
        setState(() {
          _isSourceMissing = false;
          _initialized = true;
        });

        await _applyInitialPortraitDefaultAspectRatioIfNeeded();

        _bindControllerListener();
        _scheduleDeferredPostInitWork(currentItem);

        final bool? pageEntryAutoPlay = _consumePageEntryAutoPlay();
        if (pageEntryAutoPlay == true && !playbackService.desiredPlaying) {
          unawaited(playbackService.resume());
          return;
        }

        // MediaPlaybackService owns the authoritative position and state for
        // this controller. Do not read the native position here: an online
        // backend can briefly expose its byte-zero probe during hand-off.
        // Same intent-first rule as the landscape page: while a switch is
        // still loading the service owns the transport and commits the
        // play/pause intent itself; afterwards the session intent (not the
        // transient isPlaying flag) decides, so the auto-play-after-switch
        // setting is never overwritten by a page-side "correction".
        if (playbackService.state != PlaybackState.loading) {
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
        return;
      }
    } catch (e) {
      debugPrint("无法获取 MediaPlaybackService: $e");
      // 继续使用原有逻辑创建新的 controller
    }

    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (mounted && !(_initialized && _isControllerAssigned)) {
        setState(() {
          _initialized = false;
          _isSourceMissing = false;
        });
      }
      if (playbackService.currentItem?.id == currentItem.id &&
          playbackService.state == PlaybackState.loading &&
          !playbackService.hasMountableController) {
        return;
      }
      if (playbackService.shouldDeferPlayForActiveSession(currentItem.id)) {
        return;
      }
      // Native controllers are created and owned only by the playback service.
      // The service listener re-enters this method once this exact session is
      // mountable, missing, or failed.
      unawaited(
        playbackService.play(
          currentItem,
          autoPlay: resolvePlaybackPageEntryAutoPlay(
            entryAutoPlay: _consumePageEntryAutoPlay(),
            isCurrentItem: playbackService.currentItem?.id == currentItem.id,
            desiredPlaying: playbackService.desiredPlaying,
          ),
          startPosition: MediaPlaybackService.startPositionForCurrentSession(
            currentItemId: playbackService.currentItem?.id,
            itemId: currentItem.id,
            currentPosition: playbackService.position,
          ),
        ),
      );
    } catch (error) {
      debugPrint('Unable to start service-owned playback: $error');
    }
  }

  bool? _consumePageEntryAutoPlay() {
    if (_pageEntryAutoPlayConsumed) return null;
    _pageEntryAutoPlayConsumed = true;
    return widget.autoPlayOnEntry;
  }

  void _retryFailedPlayback() {
    final service = context.read<MediaPlaybackService>();
    if (service.currentItem?.id != _currentItem.id ||
        service.state != PlaybackState.error) {
      return;
    }
    unawaited(
      service.play(
        _currentItem,
        startPosition: service.position,
        autoPlay: service.desiredPlaying,
        forceRecreate: true,
        bilibiliQualityId: service.selectedStreamQuality?.id,
        cloudDriveQualityId: service.selectedCloudDriveQualityId,
      ),
    );
  }

  Size? _lastVideoLayoutSize;

  void _videoListener() {
    if (!_isControllerAssigned) return;
    _applyDeferredDanmakuReload();
    final bool isPlayingNow;
    try {
      isPlayingNow = _controller.value.isPlaying;
    } catch (_) {
      return;
    }
    if (mounted && _lastVideoLayoutSize != _controller.value.size) {
      setState(() => _lastVideoLayoutSize = _controller.value.size);
    }
    if (_lastIsPlayingForServiceSync != isPlayingNow) {
      _lastIsPlayingForServiceSync = isPlayingNow;
      try {
        final playbackService = Provider.of<MediaPlaybackService>(
          context,
          listen: false,
        );
        if (playbackService.controller == _controller) {
          playbackService.updatePlaybackStateFromController();
        }
      } catch (_) {}
    }
    _updateSubtitle();
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
        !_isControllerAssigned ||
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
          _currentSubtitleIndex != -1 ||
          _currentSecondarySubtitleIndex != -1 ||
          _currentSubtitleEntries.isNotEmpty) {
        setState(() {
          _currentSubtitleText = "";
          _currentSecondaryText = null;
          _currentSubtitleIndex = -1;
          _currentSecondarySubtitleIndex = -1;
          _currentSubtitleIndices = [];
          _currentSecondarySubtitleIndices = [];
          _currentSubtitleEntries = [];
          _currentSubtitleImages.clear();
        });
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
        _areIntListsEqual(primaryIndices, _currentSubtitleIndices) &&
        _areIntListsEqual(secondaryIndices, _currentSecondarySubtitleIndices)) {
      return;
    }

    final List<SubtitleItem> secondaryOverlapItems = secondaryIndices
        .map((i) => _secondarySubtitles[i])
        .toList();
    final List<SubtitleOverlayEntry> entries = <SubtitleOverlayEntry>[];

    if (primaryIndices.isNotEmpty) {
      for (final int index in primaryIndices) {
        final SubtitleItem item = _subtitles[index];
        final Uint8List? image = _currentSubtitleImages[index];
        final bool hasImage = item.imageLoader != null;
        String text = hasImage ? "" : item.text;
        String? secondaryText;

        if (!hasImage &&
            _secondarySubtitles.isEmpty &&
            settings.splitSubtitleByLine) {
          if (text.contains('\n')) {
            final lines = text.split('\n');
            text = lines[0];
            secondaryText = lines.sublist(1).join('\n');
          }
        } else if (!hasImage && secondaryOverlapItems.isNotEmpty) {
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

        entries.add(
          SubtitleOverlayEntry(
            sourcePath: _fontSource(false),
            secondarySourcePath: _fontSource(true),
            language: _fontLanguage(false),
            secondaryLanguage: _fontLanguage(true),
            index: index,
            text: text,
            secondaryText: hasImage ? null : secondaryText,
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
        !_areIntListsEqual(primaryIndices, _currentSubtitleIndices) ||
        !_areIntListsEqual(secondaryIndices, _currentSecondarySubtitleIndices);
    final bool entriesChanged = !_areSubtitleEntryListsEqual(
      entries,
      _currentSubtitleEntries,
    );
    final bool anchorChanged =
        anchorPrimaryIndex != _currentSubtitleIndex ||
        anchorSecondaryIndex != _currentSecondarySubtitleIndex;

    if (!indicesChanged && !entriesChanged && !anchorChanged) return;

    setState(() {
      _currentSubtitleIndices = primaryIndices;
      _currentSecondarySubtitleIndices = secondaryIndices;
      _currentSubtitleEntries = entries;
      _currentSubtitleIndex = anchorPrimaryIndex;
      _currentSecondarySubtitleIndex = anchorSecondaryIndex;
      _currentSubtitleText = anchorEntry?.text ?? "";
      _currentSecondaryText = anchorEntry?.secondaryText;
    });

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
    if (syncSubtitleSidebar && _shownPanel == PortraitPanel.subtitles) {
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
  }

  void _seekToSubtitleFast(Duration target) {
    _seekPlaybackPosition(target, source: 'subtitle_hop');
  }

  void _togglePlay() {
    unawaited(AppHaptics.lightTap(SettingsService()));
    if (_isSourceMissing) {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      unawaited(playbackService.resume());
      return;
    }
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (identical(playbackService.controller, _controller)) {
        if (playbackService.desiredPlaying) {
          unawaited(playbackService.pause());
        } else {
          unawaited(playbackService.resume());
        }
        return;
      }
    } catch (_) {}

    if (_controller.value.isPlaying) {
      unawaited(_controller.pause());
    } else {
      unawaited(_controller.play());
    }
  }

  bool _startLongPressSpeed() {
    if (_isSourceMissing) return false;
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
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
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    await settings.setPlaybackSpeedLock(speed, locked);
    await _syncPlaybackSpeedToCurrentController(speed);
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

  SubtitlePositionTarget _subtitleTarget() {
    return SubtitlePositionTarget.resolve(
      ghost: false,
      audio: _isAudio,
      presetId: SubtitleDebugSession.instance.preset?.id,
    );
  }

  void _enterSubtitleDragMode() {
    final settings =
        _settingsService ??
        Provider.of<SettingsService>(context, listen: false);
    if (!settings.showSubtitles || _suppressSubtitleOverlayForOcr) {
      return;
    }
    _subtitlePositions.beginEditing(_subtitleTarget());
    setState(() {
      _isSubtitleDragMode = true;
      _isStylePanelDragMode = false;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _exitSubtitleDragMode() {
    _subtitlePositions.endEditing();
    setState(() {
      _isSubtitleDragMode = false;
      _isStylePanelDragMode = false;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  void _enableStylePanelDragMode() {
    _subtitlePositions.beginEditing(_subtitleTarget());
    setState(() {
      _isStylePanelDragMode = true;
      _isSubtitleDragMode = true;
      _isSubtitleSnappedX = false;
      _isSubtitleSnappedY = false;
      _isSubtitleNearCenterX = false;
      _isSubtitleNearCenterY = false;
    });
  }

  Widget _buildPageSubtitleOverlay({
    required Alignment alignment,
    required SubtitleStyle style,
    bool isDragging = false,
    bool isGestureOnly = false,
    bool presetPositionOverride = false,
    ValueListenable<SubtitleDisplayState>? displayNotifier,
    List<Rect> playbackControlRects = const [],
    bool avoidPlaybackControls = false,
  }) {
    final Widget surface = displayNotifier == null
        ? SubtitleOverlayGroup(
            entries: _currentSubtitleEntries,
            alignment: alignment,
            style: style,
            isDragging: isDragging,
            isGestureOnly: isGestureOnly,
            positionController: _subtitlePositions,
            positionInteractive: isDragging && !isGestureOnly,
            showPositionFrame: isDragging && !isGestureOnly,
            presetPositionOverride: presetPositionOverride,
            playbackControlsVisibility: _playbackControlsVisibility,
            playbackControlRects: () => playbackControlRects,
            avoidPlaybackControls: avoidPlaybackControls,
          )
        : SubtitleDisplayLayer(
            notifier: displayNotifier,
            alignment: alignment,
            style: style,
            isDragging: isDragging,
            isGestureOnly: isGestureOnly,
            positionController: _subtitlePositions,
            positionInteractive: isDragging && !isGestureOnly,
            showPositionFrame: isDragging && !isGestureOnly,
            presetPositionOverride: presetPositionOverride,
            playbackControlsVisibility: _playbackControlsVisibility,
            playbackControlRects: () => playbackControlRects,
            avoidPlaybackControls: avoidPlaybackControls,
          );
    return Positioned.fill(child: ClipRect(child: surface));
  }

  Widget _buildPortraitDanmakuOverlay(SettingsService settings) {
    final path = _currentItem.danmakuPath;
    if (_isAudio ||
        !_currentItem.isBilibiliExported ||
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
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportSize = constraints.biggest;
          final aspectRatio = _nativeVideoAspectRatio();
          final videoSize = applyBoxFit(
            BoxFit.contain,
            Size(aspectRatio, 1),
            viewportSize,
          ).destination;
          final overlay = DanmakuOverlay(
            key: ValueKey('$path:$_danmakuRevision'),
            path: path,
            position: position,
            presentationMode: DanmakuPresentationMode.portrait,
            displayArea: settings.danmakuDisplayAreaFor(
              DanmakuPresentationMode.portrait,
            ),
            density: settings.danmakuDensityFor(
              DanmakuPresentationMode.portrait,
            ),
            opacity: settings.bilibiliDanmakuOpacity,
            fontScale: settings.danmakuFontScaleFor(
              DanmakuPresentationMode.portrait,
            ),
            useReadableFontDefaults:
                settings.bilibiliDanmakuReadableFontDefaults,
            // Locked playback already advances the position clock; compensate here.
            speed: settings.effectiveBilibiliDanmakuSpeedFor(
              DanmakuPresentationMode.portrait,
            ),
            fontFamily: settings.bilibiliDanmakuFontFamily,
            fontWeight: settings.bilibiliDanmakuFontWeight,
            outlineType: settings.bilibiliDanmakuOutlineType,
            outlineScale: settings.bilibiliDanmakuOutlineScale,
            shadowScale: settings.bilibiliDanmakuShadowScale,
            letterSpacing: settings.bilibiliDanmakuLetterSpacing,
            playerHeight: viewportSize.height,
          );
          return ClipRect(
            child: settings.bilibiliDanmakuOnlyInVideoArea
                ? Center(
                    child: SizedBox(
                      width: videoSize.width,
                      height: videoSize.height,
                      child: overlay,
                    ),
                  )
                : overlay,
          );
        },
      ),
    );
  }

  Future<void> _pickSubtitle() async {
    try {
      final settings = Provider.of<SettingsService>(context, listen: false);
      final library = Provider.of<LibraryService>(context, listen: false);

      final pickedSubtitle = await pickSubtitleFile(
        allowedExtensions: ['srt', 'lrc', 'vtt'],
      );

      if (!mounted) return;

      if (pickedSubtitle != null) {
        final path = pickedSubtitle.path;
        final shouldCacheSubtitle =
            settings.autoCacheSubtitles || pickedSubtitle.requiresPersistence;

        // Auto Cache Logic
        final String? currentSecondary = _currentSubtitlePaths.length > 1
            ? _currentSubtitlePaths[1]
            : _currentItem.secondarySubtitlePath;
        await library.updateVideoSubtitles(
          _currentItem.id,
          path,
          shouldCacheSubtitle,
          secondarySubtitlePath: currentSecondary,
          isSecondaryCached: settings.autoCacheSubtitles,
        );

        final storedItem = library.getVideo(_currentItem.id);
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

  bool _subtitleStyleFromCompose = false;

  void _openSubtitleStyleSettings() {
    _openPanel(PortraitPanel.subtitleStyle);
  }

  void _openSubtitleManager() {
    _openPanel(PortraitPanel.subtitleManager);
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

  Future<void> _prepareEmbeddedSubtitlesForCompose() async {
    if (_currentItem.sourceRef?.kind == MediaSourceKind.bilibiliStream) return;
    if (_currentItem.path.isEmpty) return;
    try {
      final embeddedService = Provider.of<EmbeddedSubtitleService>(
        context,
        listen: false,
      );
      final library = Provider.of<LibraryService>(context, listen: false);
      final tracks = await embeddedService.getEmbeddedSubtitles(
        _currentItem.path,
      );
      if (tracks.isEmpty) return;
      final subDir = await const TaskSubtitleStorageService().taskDirectory(
        _currentItem.id,
        create: true,
      );
      for (final track in tracks) {
        final extractedPath = await embeddedService.extractSubtitle(
          _currentItem.path,
          track.index,
          subDir.path,
          codecName: track.codecName,
          videoId: _currentItem.id,
        );
        if (extractedPath == null || extractedPath.isEmpty) {
          continue;
        }
        await library.registerManagedSubtitleAsset(
          _currentItem.id,
          path: extractedPath,
          kind: ManagedSubtitleAssetKind.embedded,
          displayName: track.title,
        );
      }
    } catch (e) {
      debugPrint('Prepare embedded subtitles for compose failed: $e');
    }
  }

  void _openVideoCompose() async {
    if (_activePanel == PortraitPanel.videoCompose) {
      _closePanel();
      return;
    }
    final version = ++_panelNavigationVersion;
    final itemId = _currentItem.id;
    unawaited(AppHaptics.lightTap(SettingsService()));
    await _prepareEmbeddedSubtitlesForCompose();
    if (!mounted ||
        version != _panelNavigationVersion ||
        itemId != _currentItem.id ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _openPanel(PortraitPanel.videoCompose, feedback: false);
  }

  void _openOcrSubtitle() {
    if (!_supportsOcrSubtitle || _isAudio) return;
    _openPanel(PortraitPanel.ocrSubtitle);
  }

  void _openAiChat() {
    _openPanel(PortraitPanel.aiChat);
  }

  void _returnToSubtitles() {
    unawaited(AppHaptics.lightTap(SettingsService()));
    setState(() {
      _panelNavigationVersion++;
      _resetPanelEditing();
      _panelHistory.clear();
      _portraitTabHandedOff = PortraitBilibiliTab.subtitles;
      _activePanel = PortraitPanel.subtitles;
    });
    _syncPanelNavigation();
    _scheduleVideoFocusRestore();
  }

  Future<void> _applyCompletedOcrSubtitles(List<String> paths) async {
    final available = <String>[];
    for (final path in paths) {
      if (await File(path).exists()) available.add(path);
    }
    if (available.isEmpty) return;
    final itemId = _currentItem.id;
    final primary = available.first;
    final secondary = available.length > 1
        ? available[1]
        : (_currentSubtitlePaths.length > 1
              ? _currentSubtitlePaths[1]
              : _currentItem.secondarySubtitlePath);
    await _loadSubtitles([primary, ?secondary]);
    if (!mounted || _currentItem.id != itemId) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    await library.updateVideoSubtitles(
      itemId,
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
        if (_initialized && _isControllerAssigned) {
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

  /// The panel [target] stands for on this page.
  static PortraitPanel _panelOf(PortraitPanelTarget target) {
    switch (target) {
      case PortraitPanelTarget.videoCompose:
        return PortraitPanel.videoCompose;
      case PortraitPanelTarget.bilibili:
        return PortraitPanel.bilibili;
      case PortraitPanelTarget.subtitles:
        return PortraitPanel.subtitles;
    }
  }

  void _resetPanelEditing() {
    _subtitlePositions.endEditing();
    _isStylePanelDragMode = false;
    _isSubtitleDragMode = false;
    _isSubtitleSnappedX = false;
    _isSubtitleSnappedY = false;
    _isSubtitleNearCenterX = false;
    _isSubtitleNearCenterY = false;
    _isSubtitleEditorExpanded = false;
  }

  void _syncPanelNavigation() {
    _subtitleStyleFromCompose =
        _activePanel == PortraitPanel.subtitleStyle &&
        _panelHistory.contains(PortraitPanel.videoCompose);
    if (_activePanel != PortraitPanel.videoCompose &&
        !_panelHistory.contains(PortraitPanel.videoCompose)) {
      _clearVideoComposePreview();
    }
    if (_activePanel == PortraitPanel.subtitleStyle && _initialized) {
      _enableStylePanelDragMode();
    }
  }

  void _openPanel(PortraitPanel target, {bool feedback = true}) {
    if (_activePanel == target) {
      _closePanel();
      return;
    }
    if (feedback) unawaited(AppHaptics.lightTap(SettingsService()));
    setState(() {
      _panelNavigationVersion++;
      _resetPanelEditing();
      _panelHistory.open(current: _shownPanel, target: target);
      _activePanel = target;
    });
    _syncPanelNavigation();
  }

  void _closePanel() {
    if (!mounted) return;
    unawaited(AppHaptics.lightTap(SettingsService()));
    setState(() {
      _panelNavigationVersion++;
      _resetPanelEditing();
      _activePanel = _panelHistory.pop(
        fallback: _panelOf(
          portraitDefaultPanel(
            isBilibiliVideo: _isBilibiliVideo,
            rememberedTab: _portraitTab,
          ),
        ),
      );
    });
    _syncPanelNavigation();
    if (_activePanel != PortraitPanel.aiChat &&
        _activePanel != PortraitPanel.subtitleEditor) {
      _scheduleVideoFocusRestore();
    }
  }

  bool get _isBilibiliVideo => false;

  BilibiliPortraitTabMemory get _portraitTabMemory =>
      BilibiliPortraitTabMemory.of(
        Provider.of<SettingsService>(context, listen: false),
      );

  /// The 「详情 | 字幕」 tab shown for Bilibili videos.
  PortraitBilibiliTab get _portraitTab =>
      _portraitTabHandedOff ?? _portraitTabMemory.remembered;

  /// Whether the panel shown when no other one is open is up.
  bool get _isDefaultPanel =>
      _activePanel == PortraitPanel.subtitles ||
      _activePanel == PortraitPanel.bilibili;

  /// The panel actually shown: the default one follows the current video and
  /// the 「详情 | 字幕」 tab.
  PortraitPanel get _shownPanel => _isDefaultPanel
      ? _panelOf(
          portraitDefaultPanel(
            isBilibiliVideo: _isBilibiliVideo,
            rememberedTab: _portraitTab,
          ),
        )
      : _activePanel;

  void _pickPortraitTab(PortraitBilibiliTab tab) {
    _portraitTabMemory.userPicked(tab);
    setState(() {
      _panelNavigationVersion++;
      _panelHistory.clear();
      _resetPanelEditing();
      _portraitTabHandedOff = null;
      _activePanel = tab == PortraitBilibiliTab.details
          ? PortraitPanel.bilibili
          : PortraitPanel.subtitles;
    });
    _syncPanelNavigation();
  }

  void _closeSubtitleStyleSettings() {
    _closePanel();
  }

  void _closeSubtitleManager() {
    _closePanel();
  }

  Map<String, String> _buildSubtitleEditorGroups() {
    final Map<String, String> groups = <String, String>{};
    groups.addAll(_currentItem.downloadAssociatedSubtitles);
    groups.addAll(_currentItem.localSubtitleGroups);
    if (_currentItem.subtitlePath != null &&
        _currentItem.subtitlePath!.isNotEmpty) {
      groups.putIfAbsent('主字幕', () => _currentItem.subtitlePath!);
    }
    if (_currentSubtitlePaths.isNotEmpty &&
        _currentSubtitlePaths.first.isNotEmpty) {
      groups.putIfAbsent('当前主字幕', () => _currentSubtitlePaths.first);
    }
    if (_currentItem.secondarySubtitlePath != null &&
        _currentItem.secondarySubtitlePath!.isNotEmpty) {
      groups.putIfAbsent('副字幕', () => _currentItem.secondarySubtitlePath!);
    }
    return groups;
  }

  String? _resolveActiveSubtitleEditorPath() {
    if (_currentSubtitlePaths.isNotEmpty &&
        _currentSubtitlePaths.first.isNotEmpty) {
      return _currentSubtitlePaths.first;
    }
    if (_currentItem.subtitlePath != null &&
        _currentItem.subtitlePath!.isNotEmpty) {
      return _currentItem.subtitlePath;
    }
    return null;
  }

  String _normalizeGroupName(String name) {
    final String normalized = name.trim();
    return normalized.isEmpty ? '手动字幕' : normalized;
  }

  Future<String> _createManualSubtitleGroup(String desiredName) async {
    final String groupName = _normalizeGroupName(desiredName);
    final library = Provider.of<LibraryService>(context, listen: false);
    final String filePath = await library.allocateSubtitleFile(
      _currentItem.id,
      'manual.${DateTime.now().millisecondsSinceEpoch}.srt',
    );
    await _writeSubtitlesToSrt(filePath, _subtitles);
    await library.registerManagedSubtitleAsset(
      _currentItem.id,
      path: filePath,
      kind: ManagedSubtitleAssetKind.manual,
      displayName: groupName,
    );

    final Map<String, String> local = Map<String, String>.from(
      _currentItem.localSubtitles ?? <String, String>{},
    );
    String unique = groupName;
    int serial = 2;
    while (local.containsKey(unique)) {
      unique = '$groupName $serial';
      serial++;
    }
    local[unique] = filePath;
    _currentItem.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem.id, local);
    await _applyPrimarySubtitlePath(filePath);
    return filePath;
  }

  Future<void> _renameSubtitleGroup(String oldName, String newName) async {
    final String normalized = _normalizeGroupName(newName);
    final library = Provider.of<LibraryService>(context, listen: false);
    final associated = Map<String, String>.from(
      _currentItem.additionalSubtitles ?? const <String, String>{},
    );
    final downloadAssociated = _currentItem.downloadAssociatedSubtitles;
    final local = Map<String, String>.from(
      _currentItem.localSubtitles ?? <String, String>{},
    );
    if (downloadAssociated.containsKey(oldName)) {
      final path = associated.remove(oldName)!;
      if (associated.containsKey(normalized) || local.containsKey(normalized)) {
        return;
      }
      associated[normalized] = path;
      _currentItem.additionalSubtitles = associated;
      await library.updateVideoAdditionalSubtitles(_currentItem.id, associated);
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
    _currentItem.localSubtitles = local;
    await library.updateVideoLocalSubtitles(_currentItem.id, local);
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
    if (path.isEmpty) return;
    final settings = Provider.of<SettingsService>(context, listen: false);
    final library = Provider.of<LibraryService>(context, listen: false);
    String? secondaryPath;
    if (_currentSubtitlePaths.length > 1) {
      secondaryPath = _currentSubtitlePaths[1];
    } else {
      secondaryPath = _currentItem.secondarySubtitlePath;
    }
    final List<String> paths = <String>[path];
    if (secondaryPath != null &&
        secondaryPath.isNotEmpty &&
        secondaryPath != path) {
      paths.add(secondaryPath);
    }
    await _loadSubtitles(paths);
    await library.updateVideoSubtitles(
      _currentItem.id,
      path,
      settings.autoCacheSubtitles,
      secondarySubtitlePath: secondaryPath,
      isSecondaryCached: settings.autoCacheSubtitles,
    );
  }

  String? _subtitleEditorDocumentId(String? path) {
    final item = _currentItem;
    if (path == null) return null;
    return SubtitleEditorPersistence.documentKey(
      Provider.of<LibraryService>(context, listen: false),
      item.id,
      path,
    );
  }

  SubtitleItemsPersistCallback _bindSubtitleEditorSave(String? sourcePath) {
    final item = _currentItem;
    if (sourcePath == null || sourcePath.isEmpty) {
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
          _currentItem.id == videoId &&
          _resolveActiveSubtitleEditorPath() != null &&
          SubtitleEditorPersistence.documentKey(
                library,
                videoId,
                _resolveActiveSubtitleEditorPath()!,
              ) ==
              documentId;
      bool canSelect(String path) {
        if (mounted && _currentItem.id == videoId) {
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
        } else if (!mounted || _currentItem.id != videoId) {
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

  Future<void> _loadSubtitles(
    List<String> paths, {
    bool autoEnableSubtitles = true,
    bool userInitiated = true,
  }) async {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final bool committed = await playbackService
        .loadSubtitlePathsForCurrentItem(
          itemId: _currentItem.id,
          paths: paths,
          userInitiated: userInitiated,
        );
    if (!committed || !mounted) return;

    final primary = playbackService.subtitles;
    final secondary = playbackService.secondarySubtitles;

    setState(() {
      _subtitleRevision = playbackService.subtitleRevision;
      _subtitles = primary;
      _secondarySubtitles = secondary;
      _currentSubtitlePaths = List<String>.from(playbackService.subtitlePaths);
      _currentSubtitleText = "";
      _currentSecondaryText = null;
      _currentSubtitleIndex = -1;
      _currentSecondarySubtitleIndex = -1;
      _currentSubtitleIndices = [];
      _currentSecondarySubtitleIndices = [];
      _currentSubtitleEntries = [];
      _currentSubtitleImages.clear();
    });
    _rebuildSubtitleIndex();

    if (autoEnableSubtitles && (primary.isNotEmpty || secondary.isNotEmpty)) {
      // Keep the per-item snapshot aligned with the persisted global toggle
      // without overriding the user's current floating subtitle preference.
      _applyItemSubtitlePreference(_currentItem, force: true);
    }
    _updateSubtitle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateSubtitle();
    });
  }

  void _rebuildSubtitleIndex() {
    _subtitleTimeline = SubtitleTimelineResolver(_subtitles);
    _secondarySubtitleTimeline = SubtitleTimelineResolver(_secondarySubtitles);
  }

  bool _areIntListsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _areSubtitleEntryListsEqual(
    List<SubtitleOverlayEntry> a,
    List<SubtitleOverlayEntry> b,
  ) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final SubtitleOverlayEntry left = a[i];
      final SubtitleOverlayEntry right = b[i];
      if (left.index != right.index) return false;
      if (left.text != right.text) return false;
      if (left.secondaryText != right.secondaryText) return false;
      if (left.image != right.image) return false;
    }
    return true;
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

        setState(() {
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
        });
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _progressHaptics.reset();
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_isLongPressing) _endLongPressSpeed();
      _subtitlePositions.seal();
      final settings = _settingsService;
      if (settings != null) unawaited(settings.flushSubtitlePositions());
      _saveProgress();
    } else if (state == AppLifecycleState.resumed) {
      _scheduleVideoFocusRestore();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        _showSystemBars();
      });
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (_pendingSubtitleSidebarViewportRestore) {
      _tryRestoreSubtitleSidebarForCurrentViewport();
    }
  }

  @override
  void deactivate() {
    _elementActive = false;
    _saveProgress();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _elementActive = true;
  }

  Future<void> _handleExit() => _exitCleanupFuture ??= _handleExitOnce();

  Future<void> _handleExitOnce() async {
    try {
      final settings = _exitSettings;
      final playbackService = _exitPlaybackService;
      final libraryService = _exitLibraryService;
      final itemId = _currentItem.id;
      final exitController = _isControllerAssigned ? _controller : null;
      final exitControllerOwner = _isControllerOwner;
      final suppressRouteCleanup =
          PlaybackNavigationService.instance.suppressAutoPauseOnRouteCleanup;
      final shouldAutoPause =
          PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
            autoPauseOnExit: settings.autoPauseOnExit,
            explicitExit: _explicitPlaybackExitRequested,
            suppressRouteCleanup: suppressRouteCleanup,
            transportPlaying: playbackService.isTransportPlaying,
          );
      if (exitController == null) {
        if (shouldAutoPause && playbackService.currentItem?.id == itemId) {
          await playbackService.pause(expectedItemId: itemId, notify: false);
        }
        await playbackService.persistCurrentProgress(expectedItemId: itemId);
        return;
      }

      bool serviceOwnsExitSession() =>
          playbackService.currentItem?.id == itemId &&
          identical(playbackService.controller, exitController);

      if (!exitControllerOwner && !serviceOwnsExitSession()) return;

      final shouldAutoPauseSession =
          PlaybackBehaviorPolicy.shouldPauseOnPlaybackPageExit(
            autoPauseOnExit: settings.autoPauseOnExit,
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

  void _popPlaybackRoute(NavigatorState navigator) {
    PlaybackNavigationService.instance.clearBrowseHistoryOnExit();
    _explicitPlaybackExitRequested = true;
    // _handleExitOnce captures its providers, item and controller before its
    // first await. Persistence can therefore finish after pop without keeping
    // the route transition behind storage or platform-player latency.
    unawaited(
      _handleExit().catchError((Object error) {
        debugPrint('Saving portrait exit state failed: $error');
      }),
    );
    SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    navigator.pop();
  }

  Future<void> _handleBackRequest() async {
    _panelNavigationVersion++;
    final navigator = Navigator.of(context);
    if (_forceExit) {
      if (!_exitGuard.tryStart()) return;
      _popPlaybackRoute(navigator);
      return;
    }

    if (View.of(context).viewInsets.bottom > 0 &&
        FocusManager.instance.primaryFocus?.hasFocus == true) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }

    if (_activePanel == PortraitPanel.subtitleStyle &&
        (_subtitleSettingsKey.currentState?.handleBack() ?? false)) {
      return;
    }

    if (_isSubtitleDragMode && !_isStylePanelDragMode) {
      _exitSubtitleDragMode();
      return;
    }

    if (_activePanel == PortraitPanel.subtitleEditor &&
        _isSubtitleEditorExpanded) {
      if (!mounted) return;
      setState(() {
        _isSubtitleEditorExpanded = false;
      });
      return;
    }

    if (!_isDefaultPanel) {
      _closePanel();
      return;
    }

    if (await PlaybackNavigationService.instance
        .exitWindowFullScreenIfNeeded()) {
      _scheduleVideoFocusRestore();
      return;
    }
    if (!mounted) return;
    if (await PlaybackNavigationService.instance.returnToBrowseOrigin(
      context.read<MediaPlaybackService>(),
      context.read<PlaylistManager>(),
    )) {
      return;
    }
    if (!mounted || !_exitGuard.tryStart()) return;
    _popPlaybackRoute(navigator);
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

  @override
  void dispose() {
    _progressHaptics.reset();
    _playbackControlsVisibility.dispose();
    _routeWork.dispose();
    _subtitleViewportReady.dispose();
    if (_isLongPressing) {
      _isLongPressing = false;
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

    _subtitlePlaybackService?.removeListener(_onPlaybackServiceChange);
    _settingsService?.removeListener(_onSettingsChanged);
    _subtitlePlaybackService?.positionNotifier.removeListener(
      _onSubtitlePositionChanged,
    );

    _transcriptionManager?.removeListener(_onTranscriptionUpdate);
    _ocrSubtitleManager?.removeListener(_onOcrSubtitleUpdate);
    _selectionFocusNode.dispose();
    _subtitlePositions.endEditing();
    _subtitlePositions.dispose();
    _videoComposePreviewController.dispose();
    _videoFocusNode.dispose();
    _playbackPageFocusNode.dispose();
    _subtitleSeekTimer?.cancel();
    _customAspectDraftSaveTimer?.cancel();
    _systemUiInsetController.dispose();

    WidgetsBinding.instance.removeObserver(this);
    _showSystemBars();
    if (_isControllerAssigned) {
      _controller.removeListener(_videoListener);
      // 只有当我们拥有 controller 时才 dispose
      if (_isControllerOwner) {
        try {
          final playbackService = _exitPlaybackService;
          if (playbackService.controller == _controller) {
            playbackService.clearController();
          }
        } catch (e) {
          debugPrint("Error clearing controller from service: $e");
        }
        _controller.dispose();
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
      if (_activePanel == PortraitPanel.aiChat) return KeyEventResult.ignored;
      if (event is KeyDownEvent) unawaited(_handleBackRequest());
      return KeyEventResult.handled;
    }
    final tab = bilibiliPanelTabForKey(event);
    if (_isBilibiliVideo && !_isLocked && tab != null) {
      if (event is KeyDownEvent) _pickPortraitTab(tab);
      return KeyEventResult.handled;
    }
    final KeyEventResult transcriptResult =
        _subtitleSidebarKey.currentState?.handleTranscriptShortcut(event) ??
        KeyEventResult.ignored;
    if (transcriptResult != KeyEventResult.ignored) {
      return transcriptResult;
    }
    final result =
        _controlsKey.currentState?.handleKeyEvent(
          _playbackPageFocusNode,
          event,
        ) ??
        KeyEventResult.ignored;
    if (result != KeyEventResult.ignored) return result;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) unawaited(_handleBackRequest());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showSystemBars() {
    if (kIsWeb) return;
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      SystemChrome.setSystemUIOverlayStyle(
        MobileSystemNavigationBar.overlayStyle,
      );
    }
  }

  Future<void> _saveProgress() async {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (!_isControllerAssigned) {
      await playbackService.persistCurrentProgress(
        expectedItemId: _currentItem.id,
      );
      return;
    }
    await _saveProgressForSession(
      itemId: _currentItem.id,
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
    if (controllerOwner && controller.value.isInitialized) {
      await libraryService.updateVideoProgress(
        itemId,
        controller.value.position.inMilliseconds,
      );
    }
  }

  Future<void> _goToLandscape() async {
    if (_isPushingLandscape) {
      return;
    }
    _isPushingLandscape = true;
    try {
      await _runLandscapeRoundTrip();
    } finally {
      _isPushingLandscape = false;
      _isRestoringFromLandscape = false;
    }
  }

  Future<void> _runLandscapeRoundTrip() async {
    // A controller and its subtitles must cross the layout boundary as one
    // coherent snapshot. On a cold start the service's initial subtitle parse
    // can still be in flight here, which previously let landscape observe the
    // primary track before the secondary track had been committed.
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    VideoItem handoffItem = _currentItem;
    try {
      final latest = Provider.of<LibraryService>(
        context,
        listen: false,
      ).getVideo(_currentItem.id);
      if (latest != null) handoffItem = latest;
    } catch (_) {}
    final servicePaths = playbackService.subtitlePaths;
    final List<String> handoffPaths = <String>[];
    final primaryPath = servicePaths.isNotEmpty
        ? servicePaths.first
        : handoffItem.subtitlePath;
    if (primaryPath != null && primaryPath.isNotEmpty) {
      handoffPaths.add(primaryPath);
    }
    final secondaryPath = servicePaths.length > 1
        ? servicePaths[1]
        : handoffItem.secondarySubtitlePath;
    if (secondaryPath != null &&
        secondaryPath.isNotEmpty &&
        secondaryPath != primaryPath) {
      handoffPaths.add(secondaryPath);
    }
    // Subtitle refresh is not part of the visual fullscreen transition. The
    // landscape page already listens to the shared service and adopts the
    // result when it arrives.
    unawaited(
      playbackService
          .ensureSubtitlePathsForCurrentItem(
            itemId: handoffItem.id,
            paths: handoffPaths,
          )
          .catchError((Object error) {
            debugPrint('Subtitle hand-off refresh failed: $error');
            return false;
          }),
    );
    if (!mounted) {
      _isPushingLandscape = false;
      return;
    }
    _currentItem = playbackService.currentItem ?? handoffItem;
    _syncSubtitlesFromService(playbackService);

    // Push landscape page with current controller
    unawaited(_saveProgress()); // Save before switch just in case
    final navigator = Navigator.of(context);

    // Missing-source placeholders stay local. A real controller is handed to
    // landscape and keeps the existing ownership semantics.
    final VideoPlayerController? controllerForHandoff =
        !_isSourceMissing &&
            _isControllerAssigned &&
            playbackService.canMountControllerFor(
              _currentItem.id,
              controller: _controller,
            )
        ? _controller
        : null;
    if (controllerForHandoff != null) {
      _isControllerOwner = false;
    }
    final bool landscapeChromeVisible = landscapePlaybackChromeFromPortrait(
      overlayControlsVisible: _controlsKey.currentState?.controlsVisible,
      lastIntent: _playbackChromeVisible,
    );
    _playbackChromeVisible = landscapeChromeVisible;

    // From here on the portrait page is (or will be) the covered route: open
    // the restoration window so didPopNext / service notifications cannot run
    // a second _initPlayer while the continuation below remounts the
    // controller. Double initialization reloaded the media and could leave a
    // blank video output after returning.
    _isRestoringFromLandscape = true;

    try {
      final bool? landscapeChromeOnExit = await navigator.push<bool>(
        PlaybackNavigationService.buildPlaybackPageRoute<bool>(
          settings: PlaybackNavigationService.landscapeRouteSettings(
            _currentItem,
          ),
          builder: (context) => VideoPlayerScreen(
            videoFile: null, // Legacy param, ignored
            existingController: controllerForHandoff,
            videoItem: _currentItem, // Pass item for context
            skipAutoPauseOnExit: true,
            initialShowControls: landscapeChromeVisible,
          ),
        ),
      );
      if (mounted && landscapeChromeOnExit != null) {
        _playbackChromeVisible = landscapeChromeOnExit;
        _controlsKey.currentState?.applyControlsVisibilityIntent(
          landscapeChromeOnExit,
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Opening landscape playback failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      return;
    } finally {
      _isPushingLandscape = false;
    }

    if (!mounted) return;

    // 从横屏返回后，需要重新同步控制器状态
    // 因为横屏页可能已经切换了视频，导致控制器被替换
    if (_isControllerAssigned) {
      try {
        _controller.removeListener(_videoListener);
      } catch (_) {}
      if (_isControllerOwner) {
        unawaited(_controller.dispose());
      }
    }

    // Restore orientation logic based on device type
    _updateOrientations();

    // 重新初始化播放器以同步 Service 的状态。
    // 复用 Service controller 前必须通过完整的可挂载校验（会话归属、初始化、
    // 无错误、视频输出仍有效——见 canMountControllerFor）。此前缺少该校验：
    // 横屏往返期间视频输出失效时，这里会挂上纹理已失效的 controller，
    // Android 上表现为视频区域整体变白的空白帧。
    final bool canReuseServiceController =
        playbackService.currentItem != null &&
        playbackService.controller != null &&
        playbackService.currentItem!.id == _currentItem.id &&
        playbackService.canMountControllerFor(_currentItem.id);
    final bool needsReinit =
        !canReuseServiceController ||
        playbackService.needsVisibleVideoOutputRecovery(_currentItem.id);
    if (needsReinit) {
      // Only drop the decoded picture once reuse is impossible. Clearing
      // these flags first painted the opaque loading overlay over a still-
      // valid Bilibili texture while _initPlayer awaited aspect-ratio work.
      _isControllerAssigned = false;
      _initialized = false;
      _isSourceMissing = false;
      _postInitWorkToken++;
      _initPlayer();
    } else {
      _currentItem = playbackService.currentItem!;
      _controller = playbackService.controller!;
      _isControllerAssigned = true;
      _isControllerOwner = false;
      _isAudio = _currentItem.type == MediaType.audio;
      _initialized = _controller.value.isInitialized;
      _bindControllerListener();
      _scheduleDeferredPostInitWork(_currentItem);
      if (mounted) {
        setState(() {});
      }
    }

    // 同步字幕状态
    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      final updated = library.getVideo(_currentItem.id);
      if (updated != null) {
        _currentItem = updated;
      }
    } catch (_) {}

    final bool hasServiceSubtitleState =
        playbackService.subtitles.isNotEmpty ||
        playbackService.secondarySubtitles.isNotEmpty;
    if (hasServiceSubtitleState) {
      setState(() {
        _subtitles = playbackService.subtitles;
        _secondarySubtitles = playbackService.secondarySubtitles;
        _currentSubtitlePaths = List<String>.from(
          playbackService.subtitlePaths,
        );
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
      });
      _rebuildSubtitleIndex();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateSubtitle();
      });
    } else if (playbackService.subtitlePaths.isNotEmpty) {
      await _loadSubtitles(playbackService.subtitlePaths, userInitiated: false);
    } else if (_currentItem.subtitlePath != null) {
      final List<String> paths = [_currentItem.subtitlePath!];
      if (_currentItem.secondarySubtitlePath != null) {
        paths.add(_currentItem.secondarySubtitlePath!);
      }
      await _loadSubtitles(paths, userInitiated: false);
    } else if (!_currentItem.blockAutoAssociatedSubtitleSelection &&
        _resolveFirstAssociatedSubtitlePath(_currentItem) != null) {
      await _tryLoadAssociatedSubtitleAsPrimary(_currentItem);
    } else {
      setState(() {
        _subtitles = [];
        _secondarySubtitles = [];
        _currentSubtitlePaths = [];
        _currentSubtitleText = "";
        _currentSecondaryText = null;
        _currentSubtitleIndex = -1;
        _currentSecondarySubtitleIndex = -1;
        _currentSubtitleIndices = [];
        _currentSecondarySubtitleIndices = [];
        _currentSubtitleEntries = [];
        _currentSubtitleImages.clear();
      });
      // This is a layout restore with no subtitle snapshot yet. Clearing the
      // service here would count as a user choice and cancel an in-flight
      // automatic cloud subtitle download.
    }

    // The subtitle loading above awaited; the page may have been disposed in
    // the meantime and every following statement needs a live element.
    if (!mounted) return;

    setState(() {});

    // The route may become current before the phone has finished rotating.
    // Restore once the final portrait metrics are laid out; unlike playback
    // auto-follow, this repair is also required while paused.
    _requestSubtitleSidebarViewportRestore();
  }

  double _nativeVideoAspectRatio() {
    final bilibili =
        _currentItem.sourceRef?.kind == MediaSourceKind.bilibiliStream;
    try {
      final playbackService = Provider.of<MediaPlaybackService>(
        context,
        listen: false,
      );
      if (bilibili) {
        return playbackService.bilibiliVideoAspectRatioFor(
              _currentItem.id,
              controller: _isControllerAssigned ? _controller : null,
            ) ??
            16 / 9;
      }
    } catch (_) {}
    if (bilibili) return 16 / 9;
    if (_isControllerAssigned) {
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

  double _portraitDisplayAspectRatio() {
    if (_isAudio) {
      final settings =
          _settingsService ??
          Provider.of<SettingsService>(context, listen: false);
      final globalRatio = settings.audioPortraitDisplayAspectRatio;
      if (globalRatio != null && globalRatio.isFinite && globalRatio > 0) {
        return globalRatio;
      }
      return 1.0;
    }
    final manual = _currentItem.portraitDisplayAspectRatio;
    if (manual != null && manual.isFinite && manual > 0) {
      return manual;
    }
    return _nativeVideoAspectRatio();
  }

  String _portraitAspectRatioLabel(double? ratio) {
    if (ratio == null) return '原始';
    if ((ratio - 1.0).abs() < 0.01) return '1:1';
    if ((ratio - (16 / 9)).abs() < 0.01) return '16:9';
    if ((ratio - (4 / 3)).abs() < 0.01) return '4:3';
    if ((ratio - (3 / 2)).abs() < 0.01) return '3:2';
    return '${ratio.toStringAsFixed(2)}:1';
  }

  bool _isPresetAspectRatio(double ratio, {bool includeSquare = false}) {
    return (includeSquare && (ratio - 1.0).abs() < 0.01) ||
        (ratio - (16 / 9)).abs() < 0.01 ||
        (ratio - (4 / 3)).abs() < 0.01 ||
        (ratio - (3 / 2)).abs() < 0.01;
  }

  Future<void> _applyInitialPortraitDefaultAspectRatioIfNeeded() async {
    if (_isAudio ||
        !_isControllerAssigned ||
        !_controller.value.isInitialized ||
        _currentItem.hasPortraitAspectPreferenceInitialized) {
      return;
    }

    const double portraitThreshold = 1.0 - 0.0001;
    final double nativeRatio = _nativeVideoAspectRatio();
    if (nativeRatio <= 0) return;

    final double? manual = _currentItem.portraitDisplayAspectRatio;
    if (manual != null && manual.isFinite && manual > 0) {
      setState(() {
        _currentItem.hasPortraitAspectPreferenceInitialized = true;
      });
      try {
        final library = Provider.of<LibraryService>(context, listen: false);
        await library.updateVideoPortraitDisplayAspectRatio(
          _currentItem.id,
          manual,
          customWidth: _currentItem.portraitCustomAspectWidth,
          customHeight: _currentItem.portraitCustomAspectHeight,
          markInitialized: true,
        );
      } catch (_) {}
      return;
    }

    if (nativeRatio < portraitThreshold) {
      await _persistPortraitAspectRatio(4 / 3);
    }
  }

  Future<void> _persistPortraitAspectRatio(
    double? ratio, {
    double? customWidth,
    double? customHeight,
  }) async {
    final normalized =
        (ratio != null && ratio.isFinite && ratio > 0 && ratio <= 10)
        ? ratio
        : null;
    final normalizedWidth =
        (customWidth != null && customWidth.isFinite && customWidth > 0)
        ? customWidth
        : null;
    final normalizedHeight =
        (customHeight != null && customHeight.isFinite && customHeight > 0)
        ? customHeight
        : null;

    // 音频：保存到全局设置（所有音频共享同一比例）
    if (_isAudio) {
      final settings =
          _settingsService ??
          Provider.of<SettingsService>(context, listen: false);
      await settings.saveAudioPortraitDisplayAspectRatio(
        normalized,
        customWidth: normalizedWidth,
        customHeight: normalizedHeight,
      );
      if (!mounted) return;
      setState(() {});
      return;
    }

    // 视频：保存到当前视频项
    setState(() {
      _currentItem.portraitDisplayAspectRatio = normalized;
      _currentItem.portraitCustomAspectWidth = normalizedWidth;
      _currentItem.portraitCustomAspectHeight = normalizedHeight;
      _currentItem.hasPortraitAspectPreferenceInitialized = true;
    });

    try {
      final library = Provider.of<LibraryService>(context, listen: false);
      await library.updateVideoPortraitDisplayAspectRatio(
        _currentItem.id,
        normalized,
        customWidth: normalizedWidth,
        customHeight: normalizedHeight,
      );
      if (!mounted) return;
      final updated = library.getVideo(_currentItem.id);
      if (updated != null) {
        setState(() {
          _currentItem = updated;
        });
      }
    } catch (_) {}
  }

  /// 实验性功能：五连击标题进入 Apple Music 风格播放页面
  void _navigateToMusicPlayer() {
    unawaited(_openMusicPlayer());
  }

  Future<void> _openMusicPlayer() async {
    if (_isOpeningMusicPlayer) return;
    _isOpeningMusicPlayer = true;
    final service = Provider.of<MediaPlaybackService>(context, listen: false);
    try {
      await prepareMusicPlayerArtwork(context, _currentItem.thumbnailPath);
      if (!mounted) return;
      await Navigator.of(context).push(
        buildMusicPlayerRoute<void>(
          builder: (_) => MusicPlayerScreen(
            coverImagePath: _currentItem.thumbnailPath,
            title: _currentItem.title,
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
  }

  Future<void> _showPortraitAspectRatioSheet() async {
    final settings = Provider.of<SettingsService>(context, listen: false);
    final String initWidthText = settings.portraitCustomAspectDraftWidthText;
    final String initHeightText = settings.portraitCustomAspectDraftHeightText;

    final TextEditingController widthController = TextEditingController(
      text: initWidthText,
    );
    final TextEditingController heightController = TextEditingController(
      text: initHeightText,
    );

    String lastSavedWidthText = initWidthText;
    String lastSavedHeightText = initHeightText;
    Timer? customAspectLiveApplyTimer;
    double? lastLiveAppliedRatio;

    Future<void> persistCustomAspectDraft({bool immediate = false}) async {
      final widthText = widthController.text;
      final heightText = heightController.text;
      if (widthText == lastSavedWidthText &&
          heightText == lastSavedHeightText) {
        return;
      }

      Future<void> doSave() async {
        await settings.savePortraitCustomAspectDraftTexts(
          widthText: widthText,
          heightText: heightText,
        );
        lastSavedWidthText = widthText;
        lastSavedHeightText = heightText;
      }

      _customAspectDraftSaveTimer?.cancel();
      if (immediate) {
        await doSave();
      } else {
        _customAspectDraftSaveTimer = Timer(
          const Duration(milliseconds: 180),
          () {
            doSave();
          },
        );
      }
    }

    final Color panelColor = const Color(0xFF1E1E1E);

    final Color chipColor = const Color(0xFF2B2B2B);

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: panelColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (sheetContext) {
          double? selected = _isAudio
              ? (settings.audioPortraitDisplayAspectRatio ?? 1.0)
              : _currentItem.portraitDisplayAspectRatio;
          String? errorText;

          Future<void> apply(
            double? ratio, {
            double? customWidth,
            double? customHeight,
          }) async {
            await _persistPortraitAspectRatio(
              ratio,
              customWidth: customWidth,
              customHeight: customHeight,
            );
          }

          return StatefulBuilder(
            builder: (context, setSheetState) {
              bool shouldLiveSyncCustomInput() {
                final applied = _isAudio
                    ? settings.audioPortraitDisplayAspectRatio
                    : _currentItem.portraitDisplayAspectRatio;
                return applied != null &&
                    applied.isFinite &&
                    applied > 0 &&
                    !_isPresetAspectRatio(applied, includeSquare: _isAudio);
              }

              void scheduleLiveCustomApply() {
                if (!shouldLiveSyncCustomInput()) return;
                final double? width = double.tryParse(
                  widthController.text.trim(),
                );
                final double? height = double.tryParse(
                  heightController.text.trim(),
                );
                if (width == null ||
                    height == null ||
                    !width.isFinite ||
                    !height.isFinite ||
                    width <= 0 ||
                    height <= 0) {
                  return;
                }
                final double ratio = width / height;
                if (!ratio.isFinite || ratio <= 0 || ratio > 10) return;
                if (lastLiveAppliedRatio != null &&
                    (lastLiveAppliedRatio! - ratio).abs() < 0.0001) {
                  return;
                }

                customAspectLiveApplyTimer?.cancel();
                customAspectLiveApplyTimer = Timer(
                  const Duration(milliseconds: 120),
                  () async {
                    await apply(
                      ratio,
                      customWidth: width,
                      customHeight: height,
                    );
                    if (!mounted) return;
                    setSheetState(() {
                      selected = ratio;
                      errorText = null;
                    });
                    lastLiveAppliedRatio = ratio;
                  },
                );
              }

              Widget option(String title, double? ratio) {
                final bool isSelected =
                    (selected == null && ratio == null) ||
                    (selected != null &&
                        ratio != null &&
                        (selected! - ratio).abs() < 0.01);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  margin: const EdgeInsets.only(right: 8, bottom: 8),
                  child: Material(
                    color: isSelected
                        ? const Color(0xFF1565C0).withValues(alpha: 0.28)
                        : chipColor,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        if (!isSelected) {
                          unawaited(
                            AppHaptics.selectionClick(SettingsService()),
                          );
                        }
                        setSheetState(() {
                          selected = ratio;
                          errorText = null;
                        });
                        await apply(
                          ratio,
                          customWidth: null,
                          customHeight: null,
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              isSelected
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked,
                              size: 16,
                              color: isSelected
                                  ? const Color(0xFF64B5F6)
                                  : Colors.white60,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              title,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }

              return KeyboardInsetPadding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.aspect_ratio,
                          color: Colors.white70,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          '竖屏页显示比例',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '当前：${_portraitAspectRatioLabel(_isAudio ? (settings.audioPortraitDisplayAspectRatio ?? 1.0) : _currentItem.portraitDisplayAspectRatio)}',
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      children: [
                        if (_isAudio)
                          option('1:1', 1.0)
                        else
                          option('原始比例', null),
                        option('16:9', 16 / 9),
                        option('4:3', 4 / 3),
                        option('3:2', 3 / 2),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Material(
                      color: chipColor,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () async {
                                final double? width = double.tryParse(
                                  widthController.text.trim(),
                                );
                                final double? height = double.tryParse(
                                  heightController.text.trim(),
                                );
                                if (width == null ||
                                    height == null ||
                                    !width.isFinite ||
                                    !height.isFinite ||
                                    width <= 0 ||
                                    height <= 0) {
                                  setSheetState(() {
                                    errorText = '请输入有效的宽高数值';
                                  });
                                  return;
                                }

                                final double ratio = width / height;
                                if (!ratio.isFinite ||
                                    ratio <= 0 ||
                                    ratio > 10) {
                                  setSheetState(() {
                                    errorText = '宽高比最大支持 10:1';
                                  });
                                  return;
                                }

                                setSheetState(() {
                                  selected = ratio;
                                  errorText = null;
                                });
                                await apply(
                                  ratio,
                                  customWidth: width,
                                  customHeight: height,
                                );
                                lastLiveAppliedRatio = ratio;
                              },
                              child: Padding(
                                padding: const EdgeInsets.only(right: 10),
                                child: Icon(
                                  selected != null &&
                                          !_isPresetAspectRatio(
                                            selected!,
                                            includeSquare: _isAudio,
                                          )
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  size: 18,
                                  color:
                                      selected != null &&
                                          !_isPresetAspectRatio(
                                            selected!,
                                            includeSquare: _isAudio,
                                          )
                                      ? const Color(0xFF64B5F6)
                                      : Colors.white60,
                                ),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: Text(
                                '自定义',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                controller: widthController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                onChanged: (_) {
                                  setSheetState(() {
                                    errorText = null;
                                  });
                                  persistCustomAspectDraft();
                                  scheduleLiveCustomApply();
                                },
                                style: const TextStyle(color: Colors.white),
                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: const Color(0xFF232323),
                                  hintText: '宽',
                                  hintStyle: const TextStyle(
                                    color: Colors.white38,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6),
                              child: Text(
                                ':',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                            Expanded(
                              child: TextField(
                                controller: heightController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                onChanged: (_) {
                                  setSheetState(() {
                                    errorText = null;
                                  });
                                  persistCustomAspectDraft();
                                  scheduleLiveCustomApply();
                                },
                                style: const TextStyle(color: Colors.white),

                                decoration: InputDecoration(
                                  filled: true,
                                  fillColor: const Color(0xFF232323),
                                  hintText: '高',
                                  hintStyle: const TextStyle(
                                    color: Colors.white38,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorText!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                    const SizedBox(height: 8),
                  ],
                ),
              );
            },
          );
        },
      );
    } finally {
      await persistCustomAspectDraft(immediate: true);
      _customAspectDraftSaveTimer?.cancel();
      customAspectLiveApplyTimer?.cancel();
      widthController.dispose();
      heightController.dispose();
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  bool _isInCancelArea(Offset globalPosition) {
    if (!mounted) return false;
    final box = _portraitProgressGestureKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final localOffset = box.globalToLocal(globalPosition);
    // Measure upwards from the actual progress row. A fixed fraction of the
    // screen can include the slider itself after the keyboard shrinks playback.
    // Local coordinates also follow the control area's visual scale.
    return localOffset.dy < -48;
  }

  /// Resume point already stored on the library item. Used before the
  /// service clock is published so the opening frame is not zero.
  Duration _portraitLibraryBookmark() {
    final metadataDuration = Duration(
      milliseconds: _currentItem.durationMs > 0 ? _currentItem.durationMs : 0,
    );
    return PlaybackBehaviorPolicy.normalizeEpisodeStartPosition(
      savedPosition: Duration(milliseconds: _currentItem.lastPositionMs),
      duration: metadataDuration,
    );
  }

  /// Position painted by the portrait progress bar.
  ///
  /// Loading and the first mounted frames share this value. The native clock
  /// is still the open probe until the resume seek lands; following it is
  /// what made the thumb visit the bookmark, then zero, then the bookmark.
  Duration _portraitDisplayedPosition(
    VideoPlayerValue? value,
    MediaPlaybackService service,
  ) {
    final libraryBookmark = _portraitLibraryBookmark();
    final ownsItem = service.currentItem?.id == _currentItem.id;
    final ready =
        value != null &&
        value.isInitialized &&
        _pageControllerIsCurrent &&
        ownsItem;
    if (!ready) {
      final published = service.position < Duration.zero
          ? Duration.zero
          : service.position;
      // Idle with a live clock is a mini-player handoff; its position is
      // newer than the library bookmark. Idle at zero has not published yet.
      if (ownsItem &&
          (service.state != PlaybackState.idle || published > Duration.zero)) {
        final stillOpening =
            service.state == PlaybackState.loading ||
            service.state == PlaybackState.idle;
        if (!stillOpening ||
            published > Duration.zero ||
            libraryBookmark <= Duration.zero) {
          return published;
        }
      }
      return libraryBookmark;
    }
    return service.positionForProgressChrome(
      value.position,
      libraryBookmark: libraryBookmark,
    );
  }

  /// Duration that scales the portrait track.
  ///
  /// A short native probe must not replace library metadata, or the track
  /// collapses and the thumb jumps when the real length arrives.
  Duration _portraitProgressDuration(
    VideoPlayerValue? value,
    MediaPlaybackService service,
  ) {
    return PlaybackBehaviorPolicy.progressChromeDuration(
      nativeDuration: value != null && value.isInitialized
          ? value.duration
          : Duration.zero,
      serviceDuration: service.currentItem?.id == _currentItem.id
          ? service.duration
          : Duration.zero,
      metadataDuration: Duration(
        milliseconds: _currentItem.durationMs > 0 ? _currentItem.durationMs : 0,
      ),
      controllerReady:
          value != null && value.isInitialized && _pageControllerIsCurrent,
    );
  }

  Widget _buildBottomControlBar() {
    final settings = Provider.of<SettingsService>(context);
    // Progress is already driven by the controller's ValueListenableBuilder
    // below. Listening to the whole service rebuilt the portrait player for
    // every coarse media-position notification.
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (!_pageControllerIsCurrent) {
      return _portraitBottomControlBar(settings, playbackService, null);
    }

    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _controller,
      builder: (context, value, child) {
        return _portraitBottomControlBar(settings, playbackService, value);
      },
    );
  }

  Widget _buildSleepTimerSmallButton(MediaPlaybackService playbackService) {
    return AnimatedBuilder(
      animation: playbackService.sleepTimer,
      builder: (context, _) {
        final timer = playbackService.sleepTimer;
        return DesktopButtonClickRegion(
          child: IconButton(
            icon: Icon(
              timer.isActive ? Icons.alarm_on_rounded : Icons.schedule_rounded,
              color: timer.isActive ? Colors.blueAccent : Colors.white70,
              size: 17,
            ),
            onPressed: () => unawaited(showSleepTimerDialog(context)),
            tooltip: timer.isActive ? timer.statusText : '定时关闭',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 30, height: 36),
          ),
        );
      },
    );
  }

  Widget _buildExternalControls() {
    final settings = Provider.of<SettingsService>(context);
    // Playlist edits can change previous/next without a playback notification.
    // The listen is the rebuild signal; the buttons read the playback service.
    Provider.of<PlaylistManager>(context);
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    if (!_pageControllerIsCurrent) {
      return _portraitExternalControls(settings, playbackService, null);
    }

    // Reduced sizes by ~50-60% to meet user request (80% reduction requested but that would be too small, so aiming for "much smaller")
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: _controller,
      builder: (context, value, child) {
        return _portraitExternalControls(settings, playbackService, value);
      },
    );
  }

  /// Transport row shared by the loading page and the ready page.
  ///
  /// The two used to be separate trees (a raw play icon versus this button,
  /// a fixed 50px row versus the intrinsic row). Swapping them moved the
  /// buttons when the controller mounted.
  Widget _portraitExternalControls(
    SettingsService settings,
    MediaPlaybackService playbackService,
    VideoPlayerValue? value,
  ) {
    final compactWidth = MediaQuery.sizeOf(context).width < 360;
    const double iconSize = 50.0;
    const double seekIconSize = 28.0;
    final interactive =
        value != null && value.isInitialized && !_isSourceMissing;
    final seekBase = _portraitDisplayedPosition(value, playbackService);
    final seekColor = interactive ? Colors.white : Colors.white38;

    Widget seekButton({required bool forward}) {
      return InkWell(
        onTap: interactive
            ? () {
                unawaited(AppHaptics.lightTap(settings));
                final delta = Duration(seconds: settings.doubleTapSeekSeconds);
                final target = forward ? seekBase + delta : seekBase - delta;
                final duration = _portraitProgressDuration(
                  value,
                  playbackService,
                );
                var pos = target < Duration.zero ? Duration.zero : target;
                if (duration > Duration.zero && pos > duration) {
                  pos = duration;
                }
                _seekPlaybackPosition(pos);
              }
            : null,
        borderRadius: BorderRadius.circular(30),
        child: SizedBox(
          width: seekIconSize + 16,
          height: seekIconSize + 16,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform(
                alignment: Alignment.center,
                transform: forward
                    ? Matrix4.rotationY(3.14159)
                    : Matrix4.identity(),
                child: Icon(Icons.replay, color: seekColor, size: seekIconSize),
              ),
              Text(
                '${settings.doubleTapSeekSeconds}',
                style: TextStyle(
                  color: seekColor,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final playEnabled = interactive || _isSourceMissing;
    return Container(
      key: const ValueKey('portrait-external-controls'),
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.symmetric(vertical: 0.1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DesktopButtonClickRegion(
            child: IconButton(
              icon: Icon(
                Icons.skip_previous,
                color: playbackService.hasPlayablePrevious
                    ? Colors.white
                    : Colors.white38,
              ),
              onPressed: playbackService.hasPlayablePrevious
                  ? () {
                      unawaited(AppHaptics.lightTap(settings));
                      playbackService.playPrevious();
                    }
                  : null,
              iconSize: 32,
              tooltip: '上一集',
            ),
          ),
          SizedBox(width: compactWidth ? 12 : 16),
          seekButton(forward: false),
          SizedBox(width: compactWidth ? 24 : 30),
          SizedBox(
            width: iconSize,
            height: iconSize,
            child: value != null && _pageControllerIsCurrent
                ? _SessionPlayPauseButton(
                    controller: _controller,
                    service: playbackService,
                    iconSize: iconSize,
                    enabled: playEnabled,
                    onPressed: _togglePlay,
                  )
                : const DesktopButtonClickRegion(
                    child: IconButton(
                      key: ValueKey('portrait-loading-play-button'),
                      iconSize: 50,
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(),
                      onPressed: null,
                      icon: Icon(Icons.play_circle_fill, color: Colors.white38),
                    ),
                  ),
          ),
          SizedBox(width: compactWidth ? 24 : 30),
          seekButton(forward: true),
          SizedBox(width: compactWidth ? 12 : 16),
          DesktopButtonClickRegion(
            child: IconButton(
              icon: Icon(
                Icons.skip_next,
                color: playbackService.hasPlayableNext
                    ? Colors.white
                    : Colors.white38,
              ),
              onPressed: playbackService.hasPlayableNext
                  ? () {
                      unawaited(AppHaptics.lightTap(settings));
                      playbackService.playNext();
                    }
                  : null,
              iconSize: 32,
              tooltip: '下一集',
            ),
          ),
        ],
      ),
    );
  }

  /// Bottom chrome shared by the loading page and the ready page.
  ///
  /// Track inset, clock slot, speed slot and button slots stay put. Only the
  /// enabled state changes, so mounting the controller cannot resize the bar.
  Widget _portraitBottomControlBar(
    SettingsService settings,
    MediaPlaybackService playbackService,
    VideoPlayerValue? value,
  ) {
    final canSeek =
        value != null && value.isInitialized && _pageControllerIsCurrent;
    final duration = _portraitProgressDuration(value, playbackService);
    final position = _isDraggingProgress
        ? Duration(milliseconds: _dragProgressValue.toInt())
        : _portraitDisplayedPosition(value, playbackService);
    final maxDuration = duration.inMilliseconds.toDouble();
    final sliderMax = maxDuration > 0 ? maxDuration : 1.0;
    // A 1ms stand-in max would pin a known bookmark at the end of the track.
    final sliderValue = maxDuration > 0
        ? position.inMilliseconds.toDouble().clamp(0.0, sliderMax).toDouble()
        : 0.0;
    var bufferedValue = sliderValue;
    if (_currentItem.sourceRef?.kind == MediaSourceKind.bilibiliStream) {
      if (canSeek) {
        for (final range in value.buffered) {
          final end = range.end.inMilliseconds.toDouble();
          if (end > bufferedValue) bufferedValue = end;
        }
      } else {
        final end = playbackService.bufferedPosition.inMilliseconds.toDouble();
        if (end > bufferedValue) bufferedValue = end;
      }
    }
    bufferedValue = bufferedValue.clamp(sliderValue, sliderMax).toDouble();

    final configuredSpeed = settings.effectiveGlobalPlaybackSpeed;
    final speed = PlaybackBehaviorPolicy.progressChromeSpeed(
      nativeSpeed: value?.playbackSpeed ?? configuredSpeed,
      configuredSpeed: configuredSpeed,
      speedSettled:
          canSeek &&
          playbackService.currentItem?.id == _currentItem.id &&
          playbackService.state != PlaybackState.loading,
    );
    final thumbColor = _isProgressDragCanceling
        ? Colors.grey
        : const Color(0xFF1565C0);
    final trackColor = _isProgressDragCanceling
        ? Colors.grey
        : const Color(0xFF0D47A1);

    return Container(
      key: const ValueKey('portrait-bottom-control-bar'),
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      height: 36,
      child: Row(
        children: [
          _StablePortraitClock(
            '${_formatDuration(position)} / ${_formatDuration(duration)}',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Listener(
              key: _portraitProgressGestureKey,
              behavior: HitTestBehavior.translucent,
              onPointerDown: _progressHaptics.pointerDown,
              onPointerMove: (event) {
                _progressHaptics.pointerMove(event);
                if (!_isDraggingProgress || _isLocked) return;
                final isInCancelArea = _isInCancelArea(event.position);
                if (isInCancelArea != _isProgressDragCanceling) {
                  _progressHaptics.setCanceling(isInCancelArea);
                  setState(() {
                    _isProgressDragCanceling = isInCancelArea;
                  });
                }
              },
              onPointerCancel: (event) {
                _progressHaptics.reset();
                _progressDragWasCancelled = true;
                if (!_isDraggingProgress) return;
                setState(() {
                  _isDraggingProgress = false;
                  _isProgressDragCanceling = false;
                });
              },
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: trackColor,
                  inactiveTrackColor: Colors.white24,
                  secondaryActiveTrackColor: Colors.white54,
                  thumbColor: thumbColor,
                  // Disabled colors match the enabled bar so the thumb and
                  // track do not recolor or change inset when seeking unlocks.
                  disabledActiveTrackColor: trackColor,
                  disabledInactiveTrackColor: Colors.white24,
                  disabledSecondaryActiveTrackColor: Colors.white54,
                  disabledThumbColor: thumbColor,
                  overlayColor: const Color(0x291565C0),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6.0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 10,
                  ),
                  trackHeight: 2.0,
                ),
                child: Slider(
                  key: const ValueKey('portrait-progress'),
                  min: 0.0,
                  max: sliderMax,
                  value: _isDraggingProgress ? _dragProgressValue : sliderValue,
                  secondaryTrackValue: _isDraggingProgress
                      ? (_dragProgressValue > bufferedValue
                            ? _dragProgressValue
                            : bufferedValue)
                      : bufferedValue,
                  onChangeStart: canSeek
                      ? (newValue) {
                          _progressDragWasCancelled = false;
                          _progressHaptics.begin(newValue / sliderMax);
                          setState(() {
                            _isDraggingProgress = true;
                            _isProgressDragCanceling = false;
                            _dragProgressValue = newValue;
                          });
                        }
                      : null,
                  onChanged: canSeek
                      ? (newValue) {
                          _progressHaptics.update(newValue / sliderMax);
                          setState(() {
                            _isDraggingProgress = true;
                            _dragProgressValue = newValue;
                          });
                        }
                      : null,
                  onChangeEnd: canSeek
                      ? (newValue) {
                          final commit =
                              !_isProgressDragCanceling &&
                              !_progressDragWasCancelled &&
                              !_isLocked;
                          _progressHaptics.end(committed: commit);
                          if (commit) {
                            _seekPlaybackPosition(
                              Duration(milliseconds: newValue.toInt()),
                            );
                          }
                          setState(() {
                            _isDraggingProgress = false;
                            _isProgressDragCanceling = false;
                          });
                        }
                      : null,
                ),
              ),
            ),
          ),
          SubtitleDebugSpeedGateway(
            builder: (speedButtonContext, toggleSubtitlePresets) => Tooltip(
              message: '倍速',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: canSeek
                      ? () => unawaited(
                          showPlaybackSpeedDialog(
                            context: context,
                            anchorContext: speedButtonContext,
                            initialSpeed: speed,
                            settings: settings,
                            onSpeedSelected: _handlePlaybackSpeedSelected,
                          ),
                        )
                      : null,
                  // Preset entry stays on long-press so this tap is not deferred.
                  onLongPress: toggleSubtitlePresets,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 5,
                    ),
                    child: PlaybackSpeedText(
                      speed: speed,
                      style: TextStyle(
                        color: canSeek ? Colors.white : Colors.white38,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // The former three compact Material buttons occupied 3 × 40dp.
          // Four equal 30dp cells preserve that width and the progress track.
          SizedBox(
            key: const ValueKey('portrait-playback-quick-controls'),
            width: 120,
            height: 36,
            child: Row(
              children: [
                const PlaybackModeButton(
                  key: ValueKey('portrait-playback-mode'),
                  size: Size(30, 36),
                  iconSize: 17,
                ),
                SizedBox(
                  width: 30,
                  child: _buildSleepTimerSmallButton(playbackService),
                ),
                SizedBox(
                  width: 30,
                  child: DesktopButtonClickRegion(
                    child: IconButton(
                      icon: Icon(
                        settings.showSubtitles
                            ? Icons.subtitles
                            : Icons.subtitles_off,
                        color: settings.showSubtitles
                            ? Colors.blueAccent
                            : Colors.white70,
                        size: 17,
                      ),
                      onPressed: () =>
                          _setFloatingSubtitles(!settings.showSubtitles),
                      tooltip: '字幕开关',
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 36,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 30,
                  child: DesktopButtonClickRegion(
                    child: IconButton(
                      icon: Icon(
                        playbackService.isMuted
                            ? Icons.volume_off
                            : Icons.volume_up,
                        color: playbackService.isMuted
                            ? Colors.redAccent
                            : Colors.white,
                        size: 17,
                      ),
                      onPressed: () {
                        unawaited(playbackService.toggleMute());
                      },
                      tooltip: playbackService.isMuted ? '取消静音' : '静音',
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 30,
                        height: 36,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitVideoSurface(
    BuildContext context,
    SettingsService settings,
  ) => BilibiliVideoAspectRatio(
    geometry: _isCurrentBilibiliOnlineStream ? MediaPlaybackService() : null,
    aspectRatio: _portraitDisplayAspectRatio,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final controls = context
            .select<MediaPlaybackService, ({bool video, bool audio})>((
              service,
            ) {
              final ownsItem = service.currentItem?.id == _currentItem.id;
              return (
                video:
                    ownsItem &&
                    ((service.isCurrentItemBilibiliStream &&
                            service.streamQualities.isNotEmpty) ||
                        (service.cloudDriveQualities.isNotEmpty && !_isAudio)),
                audio:
                    ownsItem &&
                    service.isCurrentItemBilibiliStream &&
                    service.streamAudioQualities.any(
                      (quality) => quality.isSpecial,
                    ),
              );
            });
        final playerSize = constraints.biggest;
        final layout = CompactStreamQualityLayout.fromSize(
          playerSize,
          controlCount: (controls.video ? 1 : 0) + (controls.audio ? 1 : 0),
          viewPadding:
              MediaQuery.maybeViewPaddingOf(context) ?? EdgeInsets.zero,
        );
        final rects = layout.bounds.isEmpty
            ? <Rect>[]
            : [
                layout.bounds.inflate(
                  subtitlePlaybackControlsClearance(playerSize.height),
                ),
              ];
        final videoSize = applyBoxFit(
          BoxFit.contain,
          Size(_nativeVideoAspectRatio(), 1),
          playerSize,
        ).destination;
        return _buildPortraitPlaybackStack(
          context,
          settings,
          playerControlRects: rects,
          videoControlRects: [
            for (final rect in rects)
              rect.translate(
                -(playerSize.width - videoSize.width) / 2,
                -(playerSize.height - videoSize.height) / 2,
              ),
          ],
        );
      },
    ),
  );

  Widget _buildPortraitPlaybackStack(
    BuildContext context,
    SettingsService settings, {
    required List<Rect> playerControlRects,
    required List<Rect> videoControlRects,
  }) => Stack(
    fit: StackFit.expand,
    children: [
      if (_isSourceMissing)
        MissingLocalSourcePanel(item: _currentItem, fontSize: 18)
      else if (_playbackFailure != null)
        PlaybackFailurePanel(
          message: _playbackFailure!,
          onRetry: _retryFailedPlayback,
        )
      else if (_shouldKeepVideoSurface)
        if (_isAudio)
          Container(
            color: Colors.black,
            child: const Center(
              child: Icon(Icons.music_note, size: 80, color: Colors.white24),
            ),
          )
        else
          Center(
            child: AspectRatio(
              aspectRatio: _nativeVideoAspectRatio(),
              child: Transform(
                alignment: Alignment.center,
                transform: _buildVideoDisplayTransformMatrix(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    VideoPlayer(_controller, key: _videoTextureKey),
                    _buildVisibleVideoFrameCover(),
                  ],
                ),
              ),
            ),
          )
      else ...[
        if (_isCurrentBilibiliOnlineStream)
          BilibiliVideoPosterSlot(
            geometry: MediaPlaybackService(),
            aspectRatioOf: _nativeVideoAspectRatio,
            aspectRatio: _nativeVideoAspectRatio(),
            child: _buildVisibleVideoFrameCover(),
          )
        else if (!_isAudio &&
            _currentItem.thumbnailPath != null &&
            File(_currentItem.thumbnailPath!).existsSync())
          // Same rectangle as the
          // video below, not the
          // whole player box.
          BilibiliVideoPosterSlot(
            aspectRatio: _nativeVideoAspectRatio(),
            child: Image.file(
              File(_currentItem.thumbnailPath!),
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          )
        else
          Container(color: Colors.black),
        if (!_isCurrentBilibiliOnlineStream)
          Center(
            child: CircularProgressIndicator(
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
      ],
      if (_isDraggingProgress && !_isLocked)
        Positioned.fill(
          child: Container(
            color: Colors.black.withValues(
              alpha: _isProgressDragCanceling ? 0.28 : 0.16,
            ),
            alignment: Alignment.center,
            child: Text(
              _isProgressDragCanceling ? "松手取消" : "上滑至此区域取消",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      if (_initialized) _buildPortraitDanmakuOverlay(settings),
      // Controls Overlay
      if (_pageControllerIsCurrent && !_isSubtitleDragMode)
        VideoControlsOverlay(
          key: _controlsKey,
          enableSeekThumbnailPreview: decideSeekPreview(
            audio: _isAudio,
            bilibili:
                _currentItem.sourceRef?.kind == MediaSourceKind.bilibiliStream,
            bilibiliSpritesReady:
                _currentItem.bilibiliVideoShot?.hasLocalSprites == true,
            cloudDrive: isCloudDriveMedia(
              source: _currentItem.sourceRef,
              path: _currentItem.path,
            ),
            cloudLocalFramesReady: false,
          ).showsImage,
          bilibiliVideoShot:
              _currentItem.bilibiliVideoShot?.hasLocalSprites == true
              ? _currentItem.bilibiliVideoShot
              : null,
          showBufferedProgress:
              _currentItem.sourceRef?.kind == MediaSourceKind.bilibiliStream,
          controller: _controller,
          mediaItemId: _currentItem.id,
          isLocked: _isLocked,
          onTogglePlay: _togglePlay,
          onBackPressed: _handleBackRequest,
          onSeekTo: (position) {
            _seekPlaybackPosition(position);
          },
          onHopSeekTo: (position) {
            _seekPlaybackPosition(position, source: 'subtitle_hop');
          },
          onExitPressed: () async {
            _forceExit = true;
            await _handleBackRequest();
          },
          onToggleSidebar: null,
          onToggleFullScreen: () => settings.toggleFullScreen(),
          onOpenSettings: null,
          onOpenSleepTimer: () => unawaited(showSleepTimerDialog(context)),
          onOpenSubtitleEditor: null,
          onOpenVideoCompose: null,
          showOcrSubtitleButton: false,
          onOpenOcrSubtitle: _supportsOcrSubtitle && !_isAudio
              ? _openOcrSubtitle
              : null,
          ocrUnavailableReason: _isAudio
              ? '音频没有画面，请使用语音转录生成字幕。'
              : !_supportsOcrSubtitle
              ? '当前平台暂不支持识别画面字幕。'
              : null,
          onOpenAiChat: _openAiChat,
          aiChatOpen: _activePanel == PortraitPanel.aiChat,

          onToggleLock: () => setState(() => _isLocked = !_isLocked),
          showDanmakuControls: _currentItem.isBilibiliExported,
          danmakuEnabled: settings.showBilibiliDanmaku,
          onToggleDanmaku: () => unawaited(
            settings.saveShowBilibiliDanmaku(!settings.showBilibiliDanmaku),
          ),
          onOpenDanmakuSettings: () => unawaited(
            showDanmakuSettingsDialog(
              context,
              initialMode: DanmakuPresentationMode.portrait,
              videoItem: _currentItem,
              onDanmakuUpdated: () {
                if (mounted) {
                  setState(() => _danmakuRevision++);
                }
              },
            ),
          ),
          onSpeedUpdate: _handlePlaybackSpeedSelected,
          doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
          enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
          subtitles: _subtitles,
          longPressSpeed: settings.longPressSpeed,
          showSubtitles: settings.showSubtitles,
          suppressSubtitleOverlay: _suppressSubtitleOverlayForOcr,
          allowPlayWhenUninitialized: _isSourceMissing,
          onToggleSubtitles: () =>
              _setFloatingSubtitles(!settings.showSubtitles),
          onMoveSubtitles: _enterSubtitleDragMode,
          subtitleEntries: _currentSubtitleEntries,
          subtitleStyle: _isAudio
              ? settings.audioSubtitleStylePortrait
              : settings.subtitleStylePortrait,
          subtitleAlignment: _isAudio
              ? settings.audioSubtitleAlignment
              : settings.subtitleAlignment,
          onEnterSubtitleDragMode: _enterSubtitleDragMode,
          onClearSelection: () =>
              _selectionKey.currentState?.selectableRegion.clearSelection(),
          showPlayControls: false,
          showBottomBar: false,
          showCompactStreamQualityControls: true,
          playbackControlsVisibility: _playbackControlsVisibility,
          focusNode: _videoFocusNode,
          isLongPressing: _isLongPressing,
          longPressFeedbackText: _longPressFeedbackText,
          onLongPressStart: _startLongPressSpeed,
          onLongPressEnd: _endLongPressSpeed,
          mediaTitle: _currentItem.title,
          onExperimentalTrigger: _navigateToMusicPlayer,
          onOpenAspectRatio: _showPortraitAspectRatioSheet,
          aspectRatioLabel: _portraitAspectRatioLabel(
            _isAudio
                ? (_settingsService?.audioPortraitDisplayAspectRatio ?? 1.0)
                : _currentItem.portraitDisplayAspectRatio,
          ),
          compactTopRightButtons: true,
          initialShowControls: _playbackChromeVisible,
          onControlsVisibilityIntent: (visible) {
            _playbackChromeVisible = visible;
          },
        ),

      // Fullscreen Button (Custom for Portrait)
      if (!_isLocked && !_isSubtitleDragMode)
        Positioned(
          bottom: 10,
          right: 10,
          child: DesktopButtonClickRegion(
            child: IconButton(
              key: const ValueKey('portrait-fullscreen'),
              icon: Icon(
                Icons.fullscreen,
                color: (_initialized || _isSourceMissing)
                    ? Colors.white
                    : Colors.white38,
                size: 30,
              ),
              onPressed: (_initialized || _isSourceMissing)
                  ? () {
                      unawaited(AppHaptics.lightTap(SettingsService()));
                      _goToLandscape();
                    }
                  : null,
              style: IconButton.styleFrom(backgroundColor: Colors.black45),
            ),
          ),
        ),
      // Keep ordinary subtitles above every playback
      // control so low-positioned text is never hidden
      // behind the progress bar or buttons.
      if (_initialized &&
          ((settings.showSubtitles && !_suppressSubtitleOverlayForOcr) ||
              _videoComposePreviewActive))
        _isAudio
            ? _buildPageSubtitleOverlay(
                alignment: displayedSubtitleAlignment(
                  settings: settings,
                  target: _subtitleTarget(),
                ),
                style: settings.audioSubtitleStylePortrait,
                isDragging: _isSubtitleDragMode || _isStylePanelDragMode,
                presetPositionOverride: targetHasPresetOverride(
                  settings,
                  _subtitleTarget(),
                ),
                displayNotifier: _videoComposePreviewActive
                    ? _videoComposePreviewController.displayNotifier
                    : null,
                playbackControlRects: playerControlRects,
                avoidPlaybackControls:
                    settings.avoidPlaybackControlsWithSubtitles &&
                    !_isLocked &&
                    !_isSubtitleDragMode,
              )
            : Positioned.fill(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _nativeVideoAspectRatio(),
                    child: _videoComposePreviewActive
                        ? SubtitleDisplayLayer(
                            notifier:
                                _videoComposePreviewController.displayNotifier,
                            alignment: displayedSubtitleAlignment(
                              settings: settings,
                              target: _subtitleTarget(),
                            ),
                            style: settings.subtitleStylePortrait,
                            isDragging:
                                _isSubtitleDragMode || _isStylePanelDragMode,
                            positionController: _subtitlePositions,
                            positionInteractive:
                                _isSubtitleDragMode || _isStylePanelDragMode,
                            showPositionFrame:
                                _isSubtitleDragMode || _isStylePanelDragMode,
                            presetPositionOverride: targetHasPresetOverride(
                              settings,
                              _subtitleTarget(),
                            ),
                            playbackControlsVisibility:
                                _playbackControlsVisibility,
                            playbackControlRects: () => videoControlRects,
                            avoidPlaybackControls:
                                settings.avoidPlaybackControlsWithSubtitles &&
                                !_isLocked &&
                                !_isSubtitleDragMode,
                          )
                        : SubtitleOverlayGroup(
                            entries: _currentSubtitleEntries,
                            alignment: displayedSubtitleAlignment(
                              settings: settings,
                              target: _subtitleTarget(),
                            ),
                            style: settings.subtitleStylePortrait,
                            isDragging:
                                _isSubtitleDragMode || _isStylePanelDragMode,
                            positionController: _subtitlePositions,
                            positionInteractive:
                                _isSubtitleDragMode || _isStylePanelDragMode,
                            showPositionFrame:
                                _isSubtitleDragMode || _isStylePanelDragMode,
                            presetPositionOverride: targetHasPresetOverride(
                              settings,
                              _subtitleTarget(),
                            ),
                            playbackControlsVisibility:
                                _playbackControlsVisibility,
                            playbackControlRects: () => videoControlRects,
                            avoidPlaybackControls:
                                settings.avoidPlaybackControlsWithSubtitles &&
                                !_isLocked &&
                                !_isSubtitleDragMode,
                          ),
                  ),
                ),
              ),
      if (_initialized && (_isSubtitleDragMode || _isStylePanelDragMode)) ...[
        if (_isSubtitleNearCenterX)
          Center(
            child: Container(
              width: _isSubtitleSnappedX ? 2 : 1,
              height: double.infinity,
              color: Colors.white.withValues(
                alpha: _isSubtitleSnappedX ? 0.52 : 0.22,
              ),
            ),
          ),
        if (_isSubtitleNearCenterY)
          Center(
            child: Container(
              width: double.infinity,
              height: _isSubtitleSnappedY ? 2 : 1,
              color: Colors.white.withValues(
                alpha: _isSubtitleSnappedY ? 0.52 : 0.22,
              ),
            ),
          ),
        Positioned(
          top: 20,
          left: 0,
          right: 0,
          child: Center(
            child: SubtitlePositionHint(
              errorMessage: _subtitlePositionError,
              onExit: _isStylePanelDragMode ? null : _exitSubtitleDragMode,
            ),
          ),
        ),
        if (!_isStylePanelDragMode)
          Positioned(
            top: 64,
            child: DesktopButtonClickRegion(
              child: TextButton(
                onPressed: _exitSubtitleDragMode,
                child: const Text(
                  '完成',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final isolateKeyboard =
        _activePanel == PortraitPanel.aiChat ||
        (!kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS));
    return AiPlaybackKeyboardBoundary(
      enabled: isolateKeyboard,
      child: Consumer<SettingsService>(
        builder: (context, settings, child) {
          // 稳定化后的状态栏/触控条安全区（见 _systemUiInsetController 的说明）。
          final EdgeInsets stableSystemUiInsets = _systemUiInsetController
              .observe(
                MediaQuery.of(context),
                active: ModalRoute.isCurrentOf(context) ?? true,
              );
          final media = MediaQuery.of(context);
          final chatActive = _activePanel == PortraitPanel.aiChat;
          final subtitleStyleActive =
              _activePanel == PortraitPanel.subtitleStyle;
          final contentSystemUiInsets = stableSystemUiInsets.copyWith(
            bottom: media.viewInsets.bottom > 0 && !chatActive
                ? 0
                : stableSystemUiInsets.bottom,
          );
          // Use WillPopScope to handle back button and reset orientation early
          // This helps reduce the "jank" when returning to a landscape screen
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
                backgroundColor: Colors.black,
                resizeToAvoidBottomInset: !isolateKeyboard,
                body: SelectionArea(
                  key: _selectionKey,
                  focusNode: _selectionFocusNode,
                  child: GestureDetector(
                    onTap: () {
                      // 点击空白区域取消文字选择，仅清除选择焦点，
                      // 不调用 unfocus() 避免清除视频控制焦点的键盘快捷键
                      _selectionKey.currentState?.selectableRegion
                          .clearSelection();
                      _subtitleSidebarKey.currentState?.clearTextSelection();
                      _selectionFocusNode.unfocus();
                      _scheduleVideoFocusRestore();
                    },
                    behavior: HitTestBehavior.translucent,
                    child: OrientationBuilder(
                      builder: (context, orientation) {
                        // If device is in landscape (e.g. tablet), limit width to simulate portrait mode
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 500),
                            child: MobileSystemBarSurface(
                              topColor: Colors.black,
                              bottomColor: _bottomSystemBarColor,
                              insets: contentSystemUiInsets,
                              child: SafeArea(
                                top: true,
                                bottom: true,
                                maintainBottomViewPadding: isolateKeyboard,
                                // 从沉浸式横屏播放页退回时，状态栏与底部触控条会带动画
                                // 重新出现，实时安全区逐帧变化会把底部字幕面板压缩
                                // （看上去被触控条"挤"了一下）。这里提前把安全区预留
                                // 稳定下来，系统栏的显示/隐藏不再改变页面几何。
                                minimum: contentSystemUiInsets,
                                child: AiKeyboardViewport(
                                  enabled: isolateKeyboard,
                                  reservedBottomInset:
                                      media.viewPadding.bottom >
                                          stableSystemUiInsets.bottom
                                      ? media.viewPadding.bottom
                                      : stableSystemUiInsets.bottom,
                                  child: PortraitPlaybackLayout(
                                    keyboardVideoHeightFraction:
                                        subtitleStyleActive ? .12 : null,
                                    videoHeightFraction: chatActive
                                        ? .32
                                        : subtitleStyleActive
                                        ? .42
                                        : _isCurrentBilibiliOnlineStream
                                        ? .58
                                        : null,
                                    video:
                                        _activePanel ==
                                                PortraitPanel.subtitleEditor &&
                                            _isSubtitleEditorExpanded
                                        ? null
                                        : _buildPortraitVideoSurface(
                                            context,
                                            settings,
                                          ),
                                    controls:
                                        _activePanel ==
                                                PortraitPanel.subtitleEditor &&
                                            _isSubtitleEditorExpanded
                                        ? null
                                        : Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Column(
                                                children: [
                                                  _buildExternalControls(),
                                                  _buildBottomControlBar(),
                                                ],
                                              ),
                                            ],
                                          ),
                                    panel: PortraitPlayerPanelSwitcher(
                                      key: ValueKey((
                                        'portrait-player-panels',
                                        _currentItem.id,
                                      )),
                                      returnPanelIds: _panelHistory.panels
                                          .toSet(),
                                      readingReady:
                                          _shownPanel == PortraitPanel.subtitles
                                          ? _subtitleViewportReady
                                          : null,
                                      readingPanel: _buildReadingPanel(),
                                      panelId: _isDefaultPanel || chatActive
                                          ? null
                                          : _activePanel,
                                      panel: _isDefaultPanel || chatActive
                                          ? null
                                          : _buildBottomPanel(settings),
                                    ),
                                    overlays: [
                                      // Volume Slider Overlay (Global)
                                      if (_showVolumeSlider &&
                                          _isControllerAssigned)
                                        CompositedTransformFollower(
                                          link: _volumeButtonLayerLink,
                                          targetAnchor: Alignment.bottomCenter,
                                          followerAnchor: Alignment.topCenter,
                                          offset: const Offset(0, 5),
                                          child: Material(
                                            color: Colors.transparent,
                                            child: Container(
                                              height: 120,
                                              width: 32,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF1E1E1E),
                                                borderRadius:
                                                    BorderRadius.circular(16),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.black45,
                                                    blurRadius: 4,
                                                    offset: Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    vertical: 8,
                                                  ),
                                              child: RotatedBox(
                                                quarterTurns: -1,
                                                child: SliderTheme(
                                                  data: SliderTheme.of(context).copyWith(
                                                    activeTrackColor:
                                                        Colors.white,
                                                    inactiveTrackColor:
                                                        Colors.white24,
                                                    thumbColor: Colors.white,
                                                    thumbShape:
                                                        const RoundSliderThumbShape(
                                                          enabledThumbRadius:
                                                              6.0,
                                                        ),
                                                    trackHeight: 2.0,
                                                    overlayShape:
                                                        const RoundSliderOverlayShape(
                                                          overlayRadius: 12,
                                                        ),
                                                  ),
                                                  child: Slider(
                                                    value: _controller
                                                        .value
                                                        .volume,
                                                    onChanged: (v) {
                                                      final playbackService =
                                                          Provider.of<
                                                            MediaPlaybackService
                                                          >(
                                                            context,
                                                            listen: false,
                                                          );
                                                      unawaited(
                                                        playbackService
                                                            .setVolume(v),
                                                      );
                                                    },
                                                  ),
                                                ),
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
                                            behavior:
                                                HitTestBehavior.translucent,
                                            onHorizontalDragStart:
                                                _onIosBackSwipeStart,
                                            onHorizontalDragUpdate:
                                                _onIosBackSwipeUpdate,
                                            onHorizontalDragEnd:
                                                _onIosBackSwipeEnd,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Color get _bottomSystemBarColor {
    if (_activePanel == PortraitPanel.aiChat) return AppTokens.bgBase;
    if (_activePanel == PortraitPanel.ocrSubtitle) {
      return _isAudio || !_isControllerAssigned || !_initialized
          ? Colors.black
          : const Color(0xFF17191D);
    }
    if (_isDefaultPanel &&
        _currentItem.isBilibiliExported &&
        _portraitTab == PortraitBilibiliTab.details) {
      return AppTokens.bgBase;
    }
    return const Color(0xFF1E1E1E);
  }

  Widget _buildAiChatPanel() => AiChatPanel(
    key: ValueKey('ai_chat_${_currentItem.id}'),
    videoItem: _currentItem,
    primarySubtitles: _subtitles,
    secondarySubtitles: _secondarySubtitles,
    primaryPath: _currentSubtitlePaths.isNotEmpty
        ? _currentSubtitlePaths.first
        : _currentItem.subtitlePath,
    secondaryPath: _currentSubtitlePaths.length > 1
        ? _currentSubtitlePaths[1]
        : _currentItem.secondarySubtitlePath,
    position: MediaPlaybackService().positionNotifier.value,
    positionListenable: MediaPlaybackService().positionNotifier,
    onSeek: _seekToSubtitleFast,
    isVisible: _activePanel == PortraitPanel.aiChat,
    onBackToSubtitles: _returnToSubtitles,
    onBack: () => unawaited(_handleBackRequest()),
    onClose: _closePanel,
  );

  Widget _buildBottomPanel(SettingsService settings) {
    switch (_activePanel) {
      case PortraitPanel.ai:
        return AiTranscriptionPanel(
          videoPath: _currentItem.path,
          videoId: _currentItem.id,
          onBack: _closePanel,
          onCompleted: (completion) async {
            final settingsService = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            final libraryService = Provider.of<LibraryService>(
              context,
              listen: false,
            );
            final path = completion.primaryPath;

            // Auto load generated subtitle. A finished translation replaces
            // the secondary track; otherwise the previous secondary stays.
            if (await File(path).exists()) {
              List<String> pathsToLoad = [path];
              if (completion.translated) {
                pathsToLoad.add(completion.translationPath!);
              } else if (_currentSubtitlePaths.length > 1) {
                pathsToLoad.add(_currentSubtitlePaths[1]);
              }
              await _loadSubtitles(pathsToLoad);
              // Also update library
              final String? currentSecondary = completion.translated
                  ? completion.translationPath
                  : (_currentSubtitlePaths.length > 1
                        ? _currentSubtitlePaths[1]
                        : _currentItem.secondarySubtitlePath);
              libraryService.updateVideoSubtitles(
                _currentItem.id,
                path,
                settingsService.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settingsService.autoCacheSubtitles,
              );
            }
          },
        );
      case PortraitPanel.subtitleManager:
        final List<String> selectedPathsForSheet =
            _currentSubtitlePaths.isNotEmpty
            ? List<String>.from(_currentSubtitlePaths)
            : <String>[
                if (_currentItem.subtitlePath != null &&
                    _currentItem.subtitlePath!.isNotEmpty)
                  _currentItem.subtitlePath!,
                if (_currentItem.secondarySubtitlePath != null &&
                    _currentItem.secondarySubtitlePath!.isNotEmpty)
                  _currentItem.secondarySubtitlePath!,
              ];
        final associatedSubtitlesForSheet =
            _currentItem.downloadAssociatedSubtitles;
        final localSubtitlesForSheet = _currentItem.localSubtitleGroups;
        return SubtitleManagementSheet(
          key: ValueKey(_currentItem.path),
          videoPath: _currentItem.path,
          videoId: _currentItem.id,
          showEmbeddedSubtitles: true,
          embeddedError: _embeddedSubtitleErrorMediaKey == _currentItem.id
              ? _embeddedSubtitleError
              : null,
          onRetryEmbedded: () => unawaited(_checkAndLoadEmbeddedSubtitle()),
          associatedSubtitles: associatedSubtitlesForSheet,
          localSubtitles: localSubtitlesForSheet,
          initialSelectedPaths: selectedPathsForSheet,
          bilibiliTracks: bilibiliSubtitleTracksFor(context, _currentItem),
          cloudDriveTracks: cloudDriveSubtitleTracksFor(context, _currentItem),
          onSubtitleChanged: () {
            // Reload if needed or handled by logic
          },
          onSubtitleSelected: (paths) async {
            final settingsService = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            final libraryService = Provider.of<LibraryService>(
              context,
              listen: false,
            );

            await _loadSubtitles(paths);
            if (mounted) {
              String? path0;
              String? path1;

              if (paths.isNotEmpty) path0 = paths[0];
              if (paths.length > 1) path1 = paths[1];

              await libraryService.updateVideoSubtitles(
                _currentItem.id,
                path0,
                settingsService.autoCacheSubtitles,
                secondarySubtitlePath: path1,
                isSecondaryCached: settingsService.autoCacheSubtitles,
              );
              final updated = libraryService.getVideo(_currentItem.id);
              if (updated != null && mounted) {
                setState(() {
                  _currentItem = updated;
                });
              }
              // Keep open, no pop needed here as it is an inline panel replacement
            }
          },
          onSubtitlePreview: (path) async {
            final settingsService = Provider.of<SettingsService>(
              context,
              listen: false,
            );
            final libraryService = Provider.of<LibraryService>(
              context,
              listen: false,
            );

            List<String> pathsToLoad = [path];
            if (_currentSubtitlePaths.length > 1) {
              pathsToLoad.add(_currentSubtitlePaths[1]);
            }
            await _loadSubtitles(pathsToLoad);
            // Do not close panel
            if (mounted) {
              final String? currentSecondary = _currentSubtitlePaths.length > 1
                  ? _currentSubtitlePaths[1]
                  : _currentItem.secondarySubtitlePath;
              libraryService.updateVideoSubtitles(
                _currentItem.id,
                path,
                settingsService.autoCacheSubtitles,
                secondarySubtitlePath: currentSecondary,
                isSecondaryCached: settingsService.autoCacheSubtitles,
              );
            }
          },
          onClose: _closeSubtitleManager,
          onOpenAi: () => _openPanel(PortraitPanel.ai),
          onOpenOcrSubtitle: _supportsOcrSubtitle && !_isAudio
              ? _openOcrSubtitle
              : null,
        );
      case PortraitPanel.episodePicker:
        return LayoutBuilder(
          builder: (context, constraints) {
            return EpisodePickerPanel(
              key: const ValueKey("EpisodePickerPanel_Portrait"),
              panelWidth: constraints.maxWidth,
              panelHeight: constraints.maxHeight,
              onClose: _closePanel,
              isPortrait: true,
            );
          },
        );
      case PortraitPanel.videoCompose:
        return VideoComposePanel(
          key: ValueKey('video_compose_${_currentItem.id}'),
          videoItem: _currentItem,
          currentSelectedPaths: List<String>.from(_currentSubtitlePaths),
          availableSubtitleMap: _buildAvailableSubtitleMap(),
          onBack: () {
            _clearVideoComposePreview();
            _closePanel();
          },
          onOpenSubtitleStyle: () => _openSubtitleStyleSettings(),
          onOpenSubtitleManager: () => _openSubtitleManager(),
          onPreviewChanged: _applyVideoComposePreview,
          beforeEnqueue: () async {
            _subtitlePositions.seal();
            final settings =
                _settingsService ??
                Provider.of<SettingsService>(context, listen: false);
            await settings.flushSubtitlePositions();
          },
        );
      case PortraitPanel.ocrSubtitle:
        if (_isAudio) return const SizedBox.shrink();
        if (!_isControllerAssigned || !_initialized) {
          return const Center(
            child: Text(
              '播放器加载完成后可使用 OCR 字幕',
              style: TextStyle(color: Colors.white54),
            ),
          );
        }
        return OcrSubtitlePanel(
          key: ValueKey('ocr_subtitle_${_currentItem.id}'),
          videoItem: _currentItem,
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
          onBack: _closePanel,
          onCompleted: _applyCompletedOcrSubtitles,
        );
      case PortraitPanel.subtitleEditor:
        final Map<String, String> groups = _buildSubtitleEditorGroups();
        String? activePath = _resolveActiveSubtitleEditorPath();
        if (activePath == null && groups.isNotEmpty) {
          activePath = groups.values.first;
        }
        return SubtitleEditorPanel(
          groups: groups,
          activeGroupPath: activePath,
          documentId: _subtitleEditorDocumentId(activePath),
          subtitles: _subtitles,
          currentSubtitleIndex: _currentSubtitleIndex,
          currentPlaybackPosition:
              _isControllerAssigned && _controller.value.isInitialized
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
          onBack: () => unawaited(_handleBackRequest()),
          isExpanded: _isSubtitleEditorExpanded,
          onToggleExpanded: () => setState(() {
            _isSubtitleEditorExpanded = !_isSubtitleEditorExpanded;
          }),
        );
      case PortraitPanel.settings:
        final displayedPlaybackSpeed =
            _isControllerAssigned && _controller.value.isInitialized
            ? _controller.value.playbackSpeed
            : settings.effectiveGlobalPlaybackSpeed;
        final bool showMobilePlaybackControls =
            !kIsWeb && (Platform.isAndroid || Platform.isIOS);
        return SettingsPanel(
          key: const ValueKey("SettingsPanel"),
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
          isPlaybackSpeedLocked: settings.isPlaybackSpeedLocked,
          lockedPlaybackSpeed: settings.isPlaybackSpeedLocked
              ? settings.playbackSpeed
              : null,
          showSubtitles: settings.showSubtitles,
          isMirroredH: _currentItem.isVideoMirroredH,
          isMirroredV: _currentItem.isVideoMirroredV,
          doubleTapSeekSeconds: settings.doubleTapSeekSeconds,
          enableDoubleTapSubtitleSeek: settings.enableDoubleTapSubtitleSeek,
          onDoubleTapSubtitleSeekChanged: (val) =>
              settings.saveEnableDoubleTapSubtitleSeek(val),
          subtitleDelay: settings.subtitleDelay,
          longPressSpeed: settings.longPressSpeed,
          showLongPressSpeedIndicator: settings.showLongPressSpeedIndicator,
          autoCacheSubtitles: settings.autoCacheSubtitles,
          onSpeedChanged: (val) => unawaited(_handlePlaybackSpeedSelected(val)),
          onSpeedLockChanged: _handlePlaybackSpeedLockChanged,
          onSubtitleToggle: (val) => _setFloatingSubtitles(val),
          onMirrorHChanged: (val) =>
              unawaited(_updateVideoDisplayTransform(isMirroredH: val)),
          onMirrorVChanged: (val) =>
              unawaited(_updateVideoDisplayTransform(isMirroredV: val)),
          onSeekSecondsChanged: (val) => settings.saveDoubleTapSeekSeconds(val),
          onSubtitleDelayChanged: (val) => settings.setSubtitleDelay(val),
          onSubtitleDelayChangeEnd: (val) => settings.saveSubtitleDelay(val),
          onLongPressSpeedChanged: (val) => settings.saveLongPressSpeed(val),
          onShowLongPressSpeedIndicatorChanged: (val) =>
              settings.saveShowLongPressSpeedIndicator(val),
          onAutoCacheSubtitlesChanged: (val) =>
              settings.saveAutoCacheSubtitles(val),
          splitSubtitleByLine: settings.splitSubtitleByLine,
          onSplitSubtitleByLineChanged: (val) =>
              settings.saveSplitSubtitleByLine(val),
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
          autoPauseOnExit: settings.autoPauseOnExit,
          onAutoPauseOnExitChanged: (val) => settings.saveAutoPauseOnExit(val),
          avoidPlaybackControlsWithSubtitles:
              settings.avoidPlaybackControlsWithSubtitles,
          showSubtitleSidebarToggle: settings.showSubtitleSidebarToggle,
          onShowSubtitleSidebarToggleChanged:
              settings.saveShowSubtitleSidebarToggle,
          onAvoidPlaybackControlsWithSubtitlesChanged: (val) =>
              settings.saveAvoidPlaybackControlsWithSubtitles(val),
          pausePlaybackWhenAppBackgrounded:
              settings.pausePlaybackWhenAppBackgrounded,
          onPausePlaybackWhenAppBackgroundedChanged: (val) =>
              settings.savePausePlaybackWhenAppBackgrounded(val),
          allowConcurrentPlayback: settings.allowConcurrentPlayback,
          onAllowConcurrentPlaybackChanged: (val) =>
              settings.saveAllowConcurrentPlayback(val),
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
          onEnableHeadsetMediaControlsChanged: (val) =>
              settings.saveEnableHeadsetMediaControls(val),
          showMobilePlaybackControls: showMobilePlaybackControls,
          autoPlayOnPageEntry: settings.autoPlayOnPageEntry,
          onAutoPlayOnPageEntryChanged: (val) =>
              settings.saveAutoPlayOnPageEntry(val),
          autoPlayNextVideo: settings.autoPlayNextVideo,
          onAutoPlayNextVideoChanged: (val) =>
              settings.saveAutoPlayNextVideo(val),
          autoPlayOnCompletion: settings.autoPlayOnCompletion,
          onAutoPlayOnCompletionChanged: (val) =>
              settings.saveAutoPlayOnCompletion(val),
          autoPlayOnCompletionFromStart: settings.autoPlayOnCompletionFromStart,
          onAutoPlayOnCompletionFromStartChanged: (val) =>
              settings.saveAutoPlayOnCompletionFromStart(val),
          playlistWrapToFirst: settings.playlistWrapToFirst,
          onPlaylistWrapToFirstChanged: (val) =>
              settings.savePlaylistWrapToFirst(val),
          enableSeekPreview: settings.enableSeekPreview,
          onEnableSeekPreviewChanged: (val) =>
              settings.saveEnableSeekPreview(val),
          enableHapticFeedback: settings.enableHapticFeedback,
          onEnableHapticFeedbackChanged: (val) =>
              settings.saveEnableHapticFeedback(val),
          isLeftHandedMode: settings.isLeftHandedMode,
          onLeftHandedModeChanged: (val) => settings.saveLeftHandedMode(val),
          experimentalAmbientLetterbox: settings.experimentalAmbientLetterbox,
          onExperimentalAmbientLetterboxChanged: (val) =>
              settings.saveExperimentalAmbientLetterbox(val),
          onClose: _closePanel,
          onLoadSubtitle: _pickSubtitle,
          onOpenSubtitleSettings: _openSubtitleStyleSettings,
        );
      case PortraitPanel.subtitleStyle:
        return SubtitleSettingsSheet(
          positionError: _subtitlePositionError,
          primarySource: _fontSource(false),
          secondarySource: _fontSource(true),
          primaryLanguage: _fontLanguage(false),
          secondaryLanguage: _fontLanguage(true),
          key: _subtitleSettingsKey,
          style: _isAudio
              ? settings.audioSubtitleStylePortrait
              : settings.subtitleStylePortrait,
          isLandscape: false,
          isAudio: _isAudio,
          syncAudioSubtitleStyleWithVideo:
              settings.syncAudioSubtitleStyleWithVideo,
          onSyncAudioSubtitleStyleWithVideoChanged: _isAudio
              ? (value) => settings.setAudioSubtitleStyleSyncWithVideo(value)
              : null,
          hideGhostModeToggle: true,
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
              settings.saveAudioSubtitleLayoutPortrait(newLayoutStyle);
            } else {
              settings.saveSubtitleLayoutPortrait(newLayoutStyle);
            }
          },
          // 向后兼容的回调
          onStyleChanged: (newStyle) {
            if (_isAudio) {
              if (settings.syncAudioSubtitleStyleWithVideo) {
                settings.saveSubtitleTextStyle(newStyle.textStyle);
                settings.saveAudioSubtitleLayoutPortrait(newStyle.layoutStyle);
              } else {
                settings.saveAudioSubtitleStylePortrait(newStyle);
              }
            } else {
              settings.saveSubtitleStylePortrait(newStyle);
            }
          },
          onClose: _closeSubtitleStyleSettings,
          onBack: () => unawaited(_handleBackRequest()),
        );
      case PortraitPanel.bilibili:
      case PortraitPanel.subtitles:
      case PortraitPanel.aiChat:
        return _buildReadingPanel();
    }
  }

  Widget _buildReadingPanel() {
    final subtitleList = SubtitleSidebar(
      key: _subtitleSidebarKey,
      onViewportReadyChanged: (ready) {
        if (mounted) _subtitleViewportReady.value = ready;
      },
      subtitles: _subtitles,
      secondarySubtitles: _secondarySubtitles,
      controller: _pageControllerIsCurrent ? _controller : null,
      positionListenable: MediaPlaybackService().positionNotifier,
      onItemTap: _seekToSubtitleFast,
      onClose: () {}, // Maybe close app? or hide sidebar?
      onOpenSettings: () {
        developer.log('Opening settings panel');
        _openPanel(PortraitPanel.settings);
      },
      onLoadSubtitle: _pickSubtitle,
      onOpenSubtitleStyle: _openSubtitleStyleSettings,
      onOpenSubtitleManager: _openSubtitleManager,
      onClearSelection: () =>
          _selectionKey.currentState?.selectableRegion.clearSelection(),
      onOpenEpisodePicker: () => _openPanel(PortraitPanel.episodePicker),
      onOpenVideoCompose: _openVideoCompose,
      onOpenOcrSubtitle: _supportsOcrSubtitle && !_isAudio
          ? _openOcrSubtitle
          : null,
      ocrUnavailableReason: _isAudio
          ? '音频没有画面，请使用语音转录生成字幕。'
          : !_supportsOcrSubtitle
          ? '当前平台暂不支持识别画面字幕。'
          : null,
      onOpenAiChat: _openAiChat,
      onOpenSubtitleEditor: () => _openPanel(PortraitPanel.subtitleEditor),
      isCompact: true,
      isPortrait: true,
      preserveReadingPositionWhenNotFollowing: true,
      focusNode: _videoFocusNode,
      isVisible: _shownPanel == PortraitPanel.subtitles,
      showEmbeddedLoadingMessage:
          _embeddedSubtitleDetected &&
          _isLoadingEmbeddedSubtitle &&
          _subtitles.isEmpty &&
          _secondarySubtitles.isEmpty,
    );
    // Retain the subtitle element and reading position across both tabs and
    // switches between Bilibili and other videos.
    return SubtitleChatSidebar(
      key: const ValueKey('portrait-default-panel'),
      showChat: _activePanel == PortraitPanel.aiChat,
      isVisible: _isDefaultPanel || _activePanel == PortraitPanel.aiChat,
      chat: _buildAiChatPanel(),
      subtitles: subtitleList,
    );
  }

  Map<String, String> _buildAvailableSubtitleMap() {
    final Map<String, String> map = <String, String>{};
    final additional = <String, String>{
      ..._currentItem.downloadAssociatedSubtitles,
      ..._currentItem.localSubtitleGroups,
    };
    final Map<String, String> nameByPath = <String, String>{};
    if (additional.isNotEmpty) {
      additional.forEach((name, path) {
        if (path.isEmpty) return;
        nameByPath[_subtitlePathKey(path)] = name;
      });
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

    final String? primary = _currentItem.subtitlePath;
    if (primary != null && primary.isNotEmpty) {
      map[primary] = '主字幕（${nameForPath(primary, fallback: '主字幕')}）';
    }
    final String? secondary = _currentItem.secondarySubtitlePath;
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
      additional.forEach((name, path) {
        if (path.isEmpty) return;
        map[path] = name;
      });
    }
    return map;
  }
}

/// Clock slot with a fixed width so the progress track beside it does not
/// resize when the digits change between loading and playback.
class _StablePortraitClock extends StatelessWidget {
  const _StablePortraitClock(this.label);

  final String label;

  /// [_formatDuration] is always `HH:MM:SS`. Zeros are the widest digits in
  /// proportional fonts, so the slot stays put even without tabular figures.
  static const String _probe = '00:00:00 / 00:00:00';

  static const TextStyle _style = TextStyle(
    color: Colors.white,
    fontSize: 10,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        const ExcludeSemantics(
          child: Text(
            _probe,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: Color(0x00000000),
              fontSize: 10,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        Text(label, maxLines: 1, softWrap: false, style: _style),
      ],
    );
  }
}

/// Play/pause icon for the portrait bar. Rebuilds only when the session
/// intent changes, so a Windows libmpv acknowledgement cannot hold the icon.
class _SessionPlayPauseButton extends StatefulWidget {
  const _SessionPlayPauseButton({
    required this.controller,
    required this.service,
    required this.iconSize,
    required this.enabled,
    required this.onPressed,
  });

  final VideoPlayerController controller;
  final MediaPlaybackService service;
  final double iconSize;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  State<_SessionPlayPauseButton> createState() =>
      _SessionPlayPauseButtonState();
}

class _SessionPlayPauseButtonState extends State<_SessionPlayPauseButton> {
  late bool _transportPlaying;

  @override
  void initState() {
    super.initState();
    _transportPlaying = _readPlaying();
    widget.service.addListener(_handleService);
    widget.controller.addListener(_handleController);
  }

  @override
  void didUpdateWidget(_SessionPlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      oldWidget.service.removeListener(_handleService);
      widget.service.addListener(_handleService);
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleController);
      widget.controller.addListener(_handleController);
    }
    _publish();
  }

  @override
  void dispose() {
    widget.service.removeListener(_handleService);
    widget.controller.removeListener(_handleController);
    super.dispose();
  }

  bool _readPlaying() {
    if (identical(widget.service.controller, widget.controller)) {
      return widget.service.desiredPlaying;
    }
    return widget.controller.value.isPlaying;
  }

  void _handleService() => _publish();

  void _handleController() {
    if (identical(widget.service.controller, widget.controller)) return;
    _publish();
  }

  void _publish() {
    final bool next = _readPlaying();
    if (!mounted || next == _transportPlaying) return;
    setState(() => _transportPlaying = next);
  }

  @override
  Widget build(BuildContext context) {
    return DesktopButtonClickRegion(
      child: IconButton(
        iconSize: widget.iconSize,
        icon: Icon(
          _transportPlaying
              ? Icons.pause_circle_filled
              : Icons.play_circle_fill,
          color: widget.enabled ? Colors.white : Colors.white38,
        ),
        onPressed: widget.enabled ? widget.onPressed : null,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }
}
