import '../widgets/mobile_system_navigation_bar.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:video_player_app/theme/playback_page_route.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/subtitle_model.dart';
import '../models/subtitle_stream.dart';
import '../models/music_lyric_display_mode.dart';
import '../models/music_lyric_anchor.dart';
import '../models/music_lyric_typography.dart';
import '../models/music_lyric_workspace_layout.dart';
import '../controllers/music_lyric_selection_controller.dart';
import '../controllers/music_volume_controller.dart';
import '../services/media_playback_service.dart';
import '../services/playback_navigation_service.dart';
import '../services/library_service.dart';
import '../services/transcription_manager.dart';
import '../utils/app_toast.dart';
import '../services/audio_playback_compatibility_service.dart';
import '../services/music_artwork_backdrop_cache.dart';
import '../services/settings_service.dart';
import '../services/playlist_manager.dart';
import '../widgets/episode_picker_panel.dart';
import '../utils/android_hardware_input_bridge.dart';
import '../utils/desktop_player_shortcuts.dart';
import '../utils/player_volume_keyboard.dart';
import '../models/video_item.dart';
import '../widgets/cached_thumbnail_widget.dart';
import '../widgets/music_album_cover.dart';
import '../widgets/music_refresh_rate_scope.dart';
import '../widgets/music_backdrop_surface.dart';
import '../widgets/music_ai_chat_page.dart';
import '../widgets/music_lyric_view.dart';
import '../widgets/music_lyric_region.dart';
import '../widgets/music_lyric_anchor_guide.dart';
import '../widgets/music_playback_controls.dart';
import '../widgets/music_volume_panel.dart';
import '../widgets/relocate_local_media_source.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../widgets/music_subtitle_management_dialog.dart';
import 'package:video_player_app/widgets/capsule_selector.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

T? _maybeProvider<T extends Object>(BuildContext context) {
  try {
    return Provider.of<T>(context, listen: false);
  } catch (_) {
    return null;
  }
}

/// Prepares the already-blurred artwork while the source playback page is
/// still visible. This moves image decoding and blur work out of the route's
/// first frame, where it would otherwise interrupt the page transition.
Future<void> prepareMusicPlayerArtwork(
  BuildContext context,
  String? coverPath,
) async {
  final bytes = await MusicArtworkBackdropCache.instance.warm(coverPath);
  if (bytes == null || !context.mounted) return;
  await precacheImage(MemoryImage(bytes), context);
}

Route<T> buildMusicPlayerRoute<T>({required WidgetBuilder builder}) {
  return PlaybackPageRoute<T>(
    settings: const RouteSettings(name: 'music-player'),
    fullscreenDialog: true,
    // This screen may contain a video cover. Keep its texture and late artwork
    // live on exit as well as on entry.
    delayPushOneFrame: true,
    builder: builder,
  );
}

@visibleForTesting
SystemUiMode musicPlayerSystemUiModeForSize(Size viewportSize) {
  return viewportSize.width > viewportSize.height
      ? SystemUiMode.immersiveSticky
      : SystemUiMode.edgeToEdge;
}

bool musicPlayerUsesVerticalLayout(Size viewportSize) {
  return viewportSize.width < 768 && viewportSize.width <= viewportSize.height;
}

/// Input belongs to the modal above the player. Keep the artwork, lyric layout
/// and playback controls at their original viewport throughout the IME motion.
class _MusicPlayerViewport extends StatelessWidget {
  const _MusicPlayerViewport({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return MusicRefreshRateScope(
      child: MediaQuery(
        data: media.copyWith(
          viewInsets: EdgeInsets.zero,
          padding: media.viewPadding,
        ),
        child: child,
      ),
    );
  }
}

@visibleForTesting
bool musicPlayerUsesCompactLandscapeLayout(Size viewportSize) {
  return viewportSize.width > viewportSize.height &&
      viewportSize.shortestSide < 600;
}

/// Cover-to-video is only for a landscape music page. A wide portrait tablet
/// still uses the two-column layout, but it is not landscape.
@visibleForTesting
bool musicPlayerUsesCoverVideoGesture(Size viewportSize) {
  return !musicPlayerUsesVerticalLayout(viewportSize) &&
      viewportSize.width > viewportSize.height;
}

/// Room kept clear for the floating landscape tools.
///
/// The tools sit 16px from the corner and are 44px square. The extra 12px
/// keeps a widened video, and its upward shadow, out from under them.
@visibleForTesting
const double musicLandscapeToolbarClearance = 16 + 44 + 12;

/// Insets relative to the existing SafeArea. Match the visible top tools and
/// bottom transport icon, including asymmetric system bars, without consuming
/// the device's safe area twice.
class _MusicPhoneLandscapeSpacing {
  _MusicPhoneLandscapeSpacing(Size size, EdgeInsets safe) {
    final verticalSafe = safe.top > safe.bottom ? safe.top : safe.bottom;
    final height = size.height - verticalSafe * 2;
    final iconMargin = (height * .07).clamp(24.0, 28.0);
    toolbarTop = verticalSafe - safe.top + iconMargin - (44 - 20) / 2;
    toolbarClearance = toolbarTop + 44 + 12;
    bottomIconInset = verticalSafe - safe.bottom + iconMargin;
  }

  late final double toolbarTop, toolbarClearance, bottomIconInset;
}

/// Responsive geometry for the artwork and playback controls.
class _MusicLandscapeLayout {
  _MusicLandscapeLayout(
    Size viewport,
    double screenHeight,
    TextScaler scaler, {
    _MusicPhoneLandscapeSpacing? phoneSpacing,
  }) {
    compact = musicPlayerUsesCompactLandscapeLayout(viewport);
    // Every landscape width, not only phones. A centered wide video otherwise
    // reaches left into the floating tools.
    topInset = phoneSpacing?.toolbarClearance ?? musicLandscapeToolbarClearance;
    availableHeight = viewport.height - topInset;
    leftFlex = compact
        ? (viewport.width < 540
              ? 55
              : viewport.width < 700
              ? 46
              : 43)
        : 50;
    leftPadding = compact ? (viewport.width * .022).clamp(12.0, 20.0) : 0;
    leftPanelWidth = viewport.width * leftFlex / 100;
    final innerWidth = leftPanelWidth - leftPadding * 2;
    // Reserve the actual metadata/control stack first. A percentage of the
    // remaining height made phone videos unnecessarily small even with room
    // to spare. Larger accessibility text still leaves a scrollable fallback.
    final metadataHeight =
        scaler.scale((screenHeight * .025).clamp(13.0, 22.0)) * 2.6 +
        scaler.scale((screenHeight * .02).clamp(11.0, 18.0)) * 1.4 +
        4;
    // Docked phone controls are measured by the Column below. Its remaining
    // height constrains the cover, rather than the legacy estimated reserve.
    final maxByHeight = compact
        ? phoneSpacing != null
              ? 260.0
              : (availableHeight - metadataHeight - 118).clamp(48.0, 260.0)
        : availableHeight * .42;
    final maxByWidth = compact ? innerWidth * .85 : viewport.width * .5 - 24;
    coverSize = (screenHeight * .48)
        .clamp(120.0, 380.0)
        .clamp(0.0, maxByHeight)
        .clamp(0.0, maxByWidth);
    controlsWidth = compact
        ? innerWidth
        : (coverSize * 1.2).clamp(0.0, innerWidth);
  }
  late final bool compact;
  late final int leftFlex;
  late final double topInset,
      availableHeight,
      leftPadding,
      leftPanelWidth,
      coverSize,
      controlsWidth;
}

double _musicLandscapeEdgeInset(Size viewport) =>
    musicPlayerUsesCompactLandscapeLayout(viewport)
    ? (viewport.width * .018).clamp(10.0, 16.0)
    : viewport.width * .02;

@visibleForTesting
double musicControlsLyricMaskProgress(double controllerValue) {
  return const Interval(
    0.0,
    0.18,
    curve: Curves.easeOutCubic,
  ).transform(controllerValue.clamp(0.0, 1.0));
}

/// Apple Music 风格全屏音乐播放页面（响应式布局）
///
/// 页面布局（严格对标 Apple Music 指导文档）：
/// - Block 1: 全屏背景层（封面高斯模糊 + 半透明黑色遮罩）
/// - Block 2: 右上角窗口控制按钮（最小化 / 关闭）— 仅桌面端
/// - 窄屏竖向布局（< 768px）：
///   - Header: 缩略图 + 歌曲标题/歌手
///   - 中间: 全高同步歌词（与横屏共用 MusicLyricView）
///   - 底部: 进度条 + 控制按钮
/// - 宽屏左右布局（>= 768px）：
///   - 左侧面板: CD 封面 + 歌曲信息 + 进度条 + 控制按钮
///   - 右侧面板: 同步歌词（双语：原文大字+翻译小字）
///
/// 所有尺寸基于 vh/vw 相对单位，适配不同屏幕分辨率。
/// 字体规范：
/// - 英文原文：Inter 字体，ExtraBold (800)，纯白高亮
/// - 中文翻译：Noto Sans SC 字体，Bold (700)，半透明辅助
class MusicPlayerScreen extends StatefulWidget {
  final String? coverImagePath;
  final String title;
  final String artist;
  final String album;
  final Duration totalDuration;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback? onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final bool restoreSystemUiOnExit;

  /// Optional source content. Playback, layout and lyrics stay owned here.
  final Widget? transcriptFallback;

  /// Compact source-specific entry; expanded content never resizes the lyrics.
  final Widget? detailsAction;

  /// Allows source panels to open beneath the entire landscape toolbar.
  final GlobalKey? landscapeToolbarKey;

  /// Existing portrait details; independent of the landscape tools.
  final Widget? detailsPanel;
  final Widget? headerAction;
  final String previousLabel, nextLabel;
  final bool followCurrentSession;

  /// Source readiness, including the period before a session has been adopted.
  final bool isLoading;

  /// Exercises the landscape cover flip without a decoded video item.
  @visibleForTesting
  final bool debugLandscapeVideo;

  @visibleForTesting
  final bool debugVideoFramesReady;

  @visibleForTesting
  final double debugVideoAspectRatio;

  const MusicPlayerScreen({
    super.key,
    this.coverImagePath,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.totalDuration = Duration.zero,
    this.onSeek,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.restoreSystemUiOnExit = true,
    this.transcriptFallback,
    this.detailsAction,
    this.landscapeToolbarKey,
    this.detailsPanel,
    this.headerAction,
    this.previousLabel = '上一曲',
    this.nextLabel = '下一曲',
    this.followCurrentSession = true,
    this.isLoading = false,
    this.debugLandscapeVideo = false,
    this.debugVideoFramesReady = false,
    this.debugVideoAspectRatio = 16 / 9,
  });

  @override
  State<MusicPlayerScreen> createState() => _MusicPlayerScreenState();
}

class _MusicPlayerScreenState extends State<MusicPlayerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  double _dragProgress = 0.0;
  bool _isDragging = false;
  // 用于跟踪 seek 目标位置，避免在 seek 完成前进度条闪烁回旧位置
  double? _seekTargetProgress;
  final FocusNode _focusNode = FocusNode();
  final AndroidHardwareKeyDeduplicator _androidKeyDeduplicator =
      AndroidHardwareKeyDeduplicator();
  late final MediaPlaybackService _positionMediaService;
  TranscriptionManager? _transcription;
  final Set<String> _announcedAiSubtitles = {};
  bool? _lastSystemUiLandscape;
  bool _aiChatOpen = false;

  /// 显示位置通知器 — 驱动进度条每帧平滑更新
  /// 正常播放时跟随 service.positionNotifier，拖动时切到拖动位置
  final ValueNotifier<Duration> _displayPosition = ValueNotifier<Duration>(
    Duration.zero,
  );

  /// The lyric clock follows playback normally, but receives the scrub target
  /// explicitly on drag end so a seek into the prelude can still reposition
  /// the list while keeping the active lyric index at -1.
  final ValueNotifier<Duration> _lyricPosition = ValueNotifier<Duration>(
    Duration.zero,
  );
  final MusicLyricPositionController _lyricPositionController =
      MusicLyricPositionController();

  /// 竖屏底部控件默认常驻；用户打开自动隐藏后才响应闲置和滚动。
  bool _verticalControlsVisible = true;
  bool _portraitControlsAutoHide = false;
  bool _hadTimedSubtitles = false;

  bool get _hasTimedSubtitles =>
      widget.followCurrentSession &&
      (_mediaService.subtitles.any(_cueHasContent) ||
          _mediaService.secondarySubtitles.any(_cueHasContent));

  static bool _cueHasContent(SubtitleItem cue) =>
      cue.text.trim().isNotEmpty ||
      cue.lyricTranslation.trim().isNotEmpty ||
      cue.lyricRomanization.trim().isNotEmpty ||
      cue.imageLoader != null;

  void _syncControlsWithSubtitles() {
    final hasText = _hasTimedSubtitles;
    if (_hadTimedSubtitles == hasText) return;
    _hadTimedSubtitles = hasText;
    if (hasText) {
      _startAutoHideTimer();
    } else {
      _cancelAutoHideTimer();
      _hideControlsTimer?.cancel();
      _setControlsVisible(true);
    }
  }

  /// 隐藏/显示控件的动画时长
  static const Duration _controlsAnimDuration = Duration(milliseconds: 380);

  /// 底部控件显隐动画控制器（实现从下往上出现、从上往下消失）
  late AnimationController _controlsAnimationController;
  late Animation<Offset> _controlsSlideAnimation;

  /// 向下滚动后延迟隐藏的等待时间（避免误触）
  Timer? _hideControlsTimer;

  /// 播放一段时间后自动隐藏控件的定时器（Apple Music 核心逻辑）
  /// 控件显示后，若用户在 _autoHideDelay 时间内没有交互，则自动隐藏
  Timer? _autoHideControlsTimer;

  final GlobalKey<MusicLyricRegionState> _lyricRegionKey =
      GlobalKey<MusicLyricRegionState>();
  bool _lyricSelectionActive = false;
  bool _lyricPointerHolding = false;
  bool _suppressNextBackgroundTap = false;
  bool _isLyricScrollActive = false;
  int _audioCodecProbeGeneration = 0;
  String? _audioCodecProbePath;

  /// 控件显示后，用户无操作自动隐藏的延时（Apple Music 风格：5秒）
  static const Duration _autoHideDelay = Duration(seconds: 5);

  /// 字号和相对间距均在响应式默认值上缩放，横竖屏分别记忆。
  double _lyricFontSizeScalePortrait =
      MusicLyricTypography.defaultFontSizeScale;
  double _lyricFontSizeScaleLandscape =
      MusicLyricTypography.defaultFontSizeScale;
  double _lyricSpacingScalePortrait = MusicLyricTypography.defaultSpacingScale;
  double _lyricSpacingScaleLandscape = MusicLyricTypography.defaultSpacingScale;
  double _lyricAnchorPortrait = MusicLyricAnchor.automatic;
  double _lyricAnchorLandscape = MusicLyricAnchor.automatic;
  bool _isAdjustingLyricAnchor = false;
  bool _showLyricAnchorGuide = false;
  Timer? _lyricAnchorGuideTimer;
  final GlobalKey _pageOverlayKey = GlobalKey();
  final ValueNotifier<Object?> _backdropReady = ValueNotifier(null);
  String? _currentBackdropPath;
  final ValueNotifier<double?> _lyricAnchorGuideY = ValueNotifier(null);
  late final SettingsService _lyricTypographySettings;
  bool _lyricTypographyDirty = false;

  /// 词级歌词逐词点亮。默认打开，和字号一样在进入页面前就读好，避免先亮再灭。
  bool _lyricWordByWordEnabled = true;

  /// 非当前行景深模糊。默认打开，进入页面前读好，避免先虚再清晰。
  bool _lyricBlurEnabled = true;

  /// 是否显示页面设置弹层（字号滑块和开关）
  bool _showFontSizeSlider = false;
  bool _showVolumePanel = false;
  late final MusicVolumeController _volumeController;
  final GlobalKey _volumeButtonKey = GlobalKey();
  Size? _layoutViewport;

  static const double _stylePanelWidth = 304;
  // 字号调节按钮的 GlobalKey，用于定位字号调节滑块
  final GlobalKey _fontSizeButtonKey = GlobalKey();

  MediaPlaybackService get _mediaService =>
      Provider.of<MediaPlaybackService>(context, listen: false);
  bool get _isPlaying => widget.followCurrentSession && _mediaService.isPlaying;

  /// Shown under the elapsed time only while the cover is holding a boost.
  String? _coverSpeedLabel;

  void _setCoverSpeedLabel(String? label) {
    if (!mounted || _coverSpeedLabel == label) return;
    setState(() => _coverSpeedLabel = label);
  }

  /// Video podcasts opened in the music presentation use the same item type.
  bool _coverIsVideo(MediaPlaybackService mediaService) {
    if (widget.debugLandscapeVideo) return true;
    return widget.followCurrentSession &&
        mediaService.currentItem?.type == MediaType.video;
  }

  VoidCallback? get _previousAction =>
      widget.onPrevious ??
      (widget.followCurrentSession && _mediaService.hasPlayablePrevious
          ? _mediaService.playPrevious
          : null);
  VoidCallback? get _nextAction =>
      widget.onNext ??
      (widget.followCurrentSession && _mediaService.hasPlayableNext
          ? _mediaService.playNext
          : null);

  Future<void> _openEpisodes() async {
    _onUserInteraction();
    _cancelAutoHideTimer();
    final playlist = context.read<PlaylistManager?>();
    if (playlist == null || playlist.playlist.isEmpty) return;
    final size = MediaQuery.sizeOf(context);
    final portrait = musicPlayerUsesVerticalLayout(size);
    Widget panel(
      BuildContext context,
      double width,
      double height,
      VoidCallback close,
    ) => EpisodePickerPanel(
      panelWidth: width,
      panelHeight: height,
      isPortrait: portrait,
      onClose: close,
    );
    if (portrait) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: panel(
            sheetContext,
            size.width,
            size.height * 0.78,
            () => Navigator.pop(sheetContext),
          ),
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(20),
          child: panel(
            dialogContext,
            (size.width * 0.52).clamp(340.0, 560.0),
            size.height * 0.8,
            () => Navigator.pop(dialogContext),
          ),
        ),
      );
    }
    if (mounted) _onUserInteraction();
  }

  VoidCallback? get _episodePickerAction =>
      context.watch<PlaylistManager?>()?.playlist.isNotEmpty == true &&
          widget.followCurrentSession
      ? _openEpisodes
      : null;

  @override
  void initState() {
    super.initState();
    _volumeController = MusicVolumeController(_mediaService);
    WidgetsBinding.instance.addObserver(this);
    FocusManager.instance.addEarlyKeyEventHandler(_handleEarlyKeyEvent);
    AndroidHardwareInputBridge.addKeyListener(_handleAndroidHardwareKeyEvent);

    // 同步读取上次保存的歌词字号（竖屏 / 横屏分别记忆）。
    // 在首帧之前同步读取，可避免进入页面时先显示默认字号再跳变（闪烁）。
    final settings = Provider.of<SettingsService>(context, listen: false);
    _lyricTypographySettings = settings;
    _lyricFontSizeScalePortrait = settings.musicLyricFontSizeScalePortrait;
    _lyricFontSizeScaleLandscape = settings.musicLyricFontSizeScaleLandscape;
    _lyricSpacingScalePortrait = settings.musicLyricSpacingScalePortrait;
    _lyricSpacingScaleLandscape = settings.musicLyricSpacingScaleLandscape;
    _lyricAnchorPortrait = settings.musicLyricAnchorPortrait;
    _lyricAnchorLandscape = settings.musicLyricAnchorLandscape;
    _lyricWordByWordEnabled = settings.musicLyricWordByWordEnabled;
    _lyricBlurEnabled = settings.musicLyricBlurEnabled;
    _portraitControlsAutoHide = settings.musicPortraitControlsAutoHide;

    // 初始化底部控件显隐动画控制器
    _controlsAnimationController = AnimationController(
      duration: _controlsAnimDuration,
      reverseDuration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _controlsSlideAnimation =
        Tween<Offset>(
          // Apple Music 的控制区更接近淡出和轻微下沉，而不是整块滑出屏幕。
          begin: const Offset(0, 0.08),
          end: Offset.zero, // 显示位置
        ).animate(
          CurvedAnimation(
            parent: _controlsAnimationController,
            curve: Curves.easeInOutCubic,
          ),
        );
    // 初始状态为显示
    _controlsAnimationController.value = 1.0;

    // 监听 service.positionNotifier，平滑更新 _displayPosition
    _positionMediaService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    _positionMediaService.positionNotifier.addListener(_onPositionNotified);
    _positionMediaService.addListener(_syncControlsWithSubtitles);
    _hadTimedSubtitles = _hasTimedSubtitles;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bindTranscription();
    });
    _displayPosition.value = widget.followCurrentSession
        ? _positionMediaService.position
        : Duration.zero;
    _lyricPosition.value = _displayPosition.value;

    // 请求焦点以接收键盘事件
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreKeyboardFocus();
    });

    // 手机竖屏显示状态栏和手势/导航栏；横屏保持沉浸式播放。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncMobileSystemUiForOrientation(force: true);
    });

    // 启动自动隐藏控件定时器（Apple Music 逻辑：几秒无操作后控件自动隐藏）
    _startAutoHideTimer();
  }

  /// 当 service.positionNotifier 变化时，更新 _displayPosition
  /// - 拖动时（_isDragging）不更新
  /// - seek 过程中（_seekTargetProgress != null）暂时不更新，避免闪烁
  void _onPositionNotified() {
    if (!mounted || _isDragging) return;
    if (!widget.followCurrentSession) {
      _displayPosition.value = _lyricPosition.value = Duration.zero;
      return;
    }

    final service = Provider.of<MediaPlaybackService>(context, listen: false);

    // 如果正在 seek，检查是否已经到达目标位置
    if (_seekTargetProgress != null) {
      final duration = service.duration;
      if (duration.inMilliseconds > 0) {
        final targetMs = (_seekTargetProgress! * duration.inMilliseconds)
            .round();
        final currentMs = service.position.inMilliseconds;
        final diff = (targetMs - currentMs).abs();

        // 如果当前位置已经接近目标位置（误差 < 500ms），认为 seek 完成
        if (diff < 500) {
          setState(() => _seekTargetProgress = null);
        } else {
          // seek 还没完成，不要更新 _displayPosition，避免闪烁
          return;
        }
      } else {
        // 如果 duration 为 0，无法计算，直接清除 _seekTargetProgress
        setState(() => _seekTargetProgress = null);
      }
    }

    if (_displayPosition.value != service.positionNotifier.value) {
      _displayPosition.value = service.positionNotifier.value;
    }
    if (_lyricPosition.value != service.positionNotifier.value) {
      _lyricPosition.value = service.positionNotifier.value;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindTranscription();
  }

  void _bindTranscription() {
    final manager = _maybeProvider<TranscriptionManager>(context);
    if (identical(manager, _transcription)) return;
    _transcription?.removeListener(_onAiSubtitleReady);
    _transcription = manager;
    _transcription?.addListener(_onAiSubtitleReady);
  }

  /// Loads a finished AI subtitle for the episode that is actually playing.
  /// The panel may already have consumed its own completion toast; this path
  /// stays idempotent and does not move the playhead.
  void _onAiSubtitleReady() {
    if (!mounted || !widget.followCurrentSession) return;
    final item = _mediaService.currentItem;
    final manager = _transcription;
    if (item == null || manager == null || item.path.isEmpty) return;
    final streaming = manager.streamForVideo(item.path, videoId: item.id);
    if (manager.hasSubtitleStreamForVideo(item.path, videoId: item.id)) {
      if ((streaming?.complete ?? true) &&
          _announcedAiSubtitles.add(streaming?.generationId ?? item.path) &&
          manager.consumeResultNotificationForVideo(
            item.path,
            videoId: item.id,
          )) {
        AppToast.show('AI 字幕生成完成');
      }
      return;
    }
    final path = manager.getGeneratedSrtPathForVideo(
      item.path,
      videoId: item.id,
    );
    if (path == null || !_announcedAiSubtitles.add(path)) return;
    final translation = manager.getGeneratedTranslationPathForVideo(
      item.path,
      videoId: item.id,
    );
    final alreadyLoaded =
        _mediaService.subtitlePaths.isNotEmpty &&
        _mediaService.subtitlePaths.first == path &&
        (translation == null ||
            (_mediaService.subtitlePaths.length > 1 &&
                _mediaService.subtitlePaths[1] == translation));
    if (!alreadyLoaded) {
      unawaited(
        translation == null
            ? _applyGeneratedSubtitle(item, path)
            : _applyGeneratedSubtitlePair(item, path, translation),
      );
    }
    final note = manager.completionMessageForVideo(item.path, videoId: item.id);
    AppToast.show(
      note.trim().isEmpty || note.trim() == '转录完成' ? 'AI 字幕转录完成并已自动加载' : note,
    );
  }

  Future<void> _applyGeneratedSubtitle(VideoItem item, String path) async {
    final secondary = _mediaService.subtitlePaths.length > 1
        ? _mediaService.subtitlePaths[1]
        : item.secondarySubtitlePath;
    final loaded = await _mediaService.loadSubtitlePathsForCurrentItem(
      itemId: item.id,
      paths: [path, if (secondary != null && secondary.isNotEmpty) secondary],
    );
    if (!loaded || !mounted) return;
    final library = _maybeProvider<LibraryService>(context);
    if (library == null) return;
    final autoCache = _maybeProvider<SettingsService>(
      context,
    )?.autoCacheSubtitles;
    await library.updateVideoSubtitles(
      item.id,
      path,
      autoCache ?? true,
      secondarySubtitlePath: secondary,
      isSecondaryCached: autoCache ?? item.isSecondarySubtitleCached,
    );
  }

  Future<void> _applyGeneratedSubtitlePair(
    VideoItem item,
    String path,
    String translationPath,
  ) async {
    final loaded = await _mediaService.loadSubtitlePathsForCurrentItem(
      itemId: item.id,
      paths: [path, translationPath],
    );
    if (!loaded || !mounted) return;
    final library = _maybeProvider<LibraryService>(context);
    if (library == null) return;
    final autoCache = _maybeProvider<SettingsService>(
      context,
    )?.autoCacheSubtitles;
    await library.updateVideoSubtitles(
      item.id,
      path,
      autoCache ?? true,
      secondarySubtitlePath: translationPath,
      isSecondaryCached: autoCache ?? true,
    );
  }

  @override
  void didUpdateWidget(covariant MusicPlayerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.followCurrentSession != widget.followCurrentSession) {
      _isDragging = false;
      _seekTargetProgress = null;
      _onPositionNotified();
      _syncControlsWithSubtitles();
    }
    if (widget.isLoading != oldWidget.isLoading) {
      if (widget.isLoading) {
        _cancelAutoHideTimer();
        _hideControlsTimer?.cancel();
        _setControlsVisible(true);
      } else {
        _startAutoHideTimer();
      }
    }
  }

  @override
  void dispose() {
    _volumeController.dispose();
    _lyricAnchorGuideTimer?.cancel();
    _lyricAnchorGuideY.dispose();
    _backdropReady.dispose();
    // A route can close while a slider is still held. Save its last preview
    // after unmounting, when notifying settings listeners is safe again.
    if (_lyricTypographyDirty) scheduleMicrotask(_persistLyricTypography);
    AndroidHardwareInputBridge.removeKeyListener(
      _handleAndroidHardwareKeyEvent,
    );
    FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _hideControlsTimer?.cancel();
    _autoHideControlsTimer?.cancel();
    _controlsAnimationController.dispose();
    _focusNode.dispose();
    _positionMediaService.positionNotifier.removeListener(_onPositionNotified);
    _positionMediaService.removeListener(_syncControlsWithSubtitles);
    _transcription?.removeListener(_onAiSubtitleReady);
    _displayPosition.dispose();
    _lyricPosition.dispose();
    _lyricPositionController.dispose();

    // Music 页是播放页的子页时，退出后底下仍然是播放页，
    // 不能先恢复系统栏，否则路由切换期间会发生一次视口抖动。
    if (widget.restoreSystemUiOnExit) {
      _restoreSystemUIMode();
    }

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _persistLyricTypography();
    if (state == AppLifecycleState.resumed) {
      unawaited(_volumeController.refresh());
      _scheduleKeyboardFocusRestore();
      if (ModalRoute.of(context)?.isCurrent == true) {
        _syncMobileSystemUiForOrientation(force: true);
      }
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        _syncMobileSystemUiForOrientation();
      }
    });
  }

  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  _MusicPhoneLandscapeSpacing? get _phoneLandscapeSpacing {
    final screenSize = MediaQuery.sizeOf(context);
    return _isMobilePlatform &&
            musicPlayerUsesCompactLandscapeLayout(screenSize)
        ? _MusicPhoneLandscapeSpacing(
            screenSize,
            MediaQuery.viewPaddingOf(context),
          )
        : null;
  }

  void _syncMobileSystemUiForOrientation({bool force = false}) {
    if (!_isMobilePlatform) return;
    final viewportSize = MediaQuery.sizeOf(context);
    final mode = musicPlayerSystemUiModeForSize(viewportSize);
    final isLandscape = mode == SystemUiMode.immersiveSticky;
    if (!force && _lastSystemUiLandscape == isLandscape) return;
    _lastSystemUiLandscape = isLandscape;

    if (isLandscape) {
      unawaited(SystemChrome.setEnabledSystemUIMode(mode));
      return;
    }

    _restoreSystemUIMode();
  }

  void _restoreSystemUIMode() {
    if (_isMobilePlatform) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      SystemChrome.setSystemUIOverlayStyle(
        MobileSystemNavigationBar.overlayStyle,
      );
    }
  }

  bool _isTextInputFocused() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    return focusContext.widget is EditableText ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _restoreKeyboardFocus() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (_lyricSelectionActive) return;
    if (!_isTextInputFocused() && _focusNode.canRequestFocus) {
      _focusNode.requestFocus();
    }
  }

  void _scheduleKeyboardFocusRestore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreKeyboardFocus();
    });
  }

  KeyEventResult _handleEarlyKeyEvent(KeyEvent event) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    return _handleKeyEvent(_focusNode, event);
  }

  Future<void> _toggleFullScreen(SettingsService settings) async {
    try {
      await settings.toggleFullScreen();
    } finally {
      // Desktop full-screen transitions can replace Flutter's primary focus.
      // Restore it after the native window operation has completed.
      _scheduleKeyboardFocusRestore();
    }
  }

  /// 统一设置竖屏底部控件的可见性，并触发相应动画
  ///
  /// - visible = true: 立即显示控件 + 从下往上进入动画
  /// - visible = false: 延迟隐藏控件 + 从上往下退出动画
  void _setControlsVisible(bool visible) {
    if (!visible &&
        (!_portraitControlsAutoHide ||
            !_hasTimedSubtitles ||
            widget.isLoading ||
            _showFontSizeSlider ||
            _showVolumePanel)) {
      visible = true;
    }
    if (!mounted || _verticalControlsVisible == visible) return;
    setState(() => _verticalControlsVisible = visible);
    if (visible) {
      _controlsAnimationController.forward();
    } else {
      _controlsAnimationController.reverse();
    }
  }

  void _handleExit() {
    Navigator.of(context).pop();
  }

  bool get _windowFullScreen =>
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
      SettingsService().isFullScreen;

  Future<void> _handleBackRequest() async {
    if (_showVolumePanel) {
      _dismissVolumePanel();
      return;
    }
    if (_showFontSizeSlider) {
      _dismissFontSizeSlider();
      return;
    }
    if (_lyricSelectionActive) {
      _lyricRegionKey.currentState?.handleBack();
      return;
    }
    if (await PlaybackNavigationService.instance
        .exitWindowFullScreenIfNeeded()) {
      _scheduleKeyboardFocusRestore();
      return;
    }
    if (mounted && ModalRoute.isCurrentOf(context) == true) _handleExit();
  }

  Future<void> _openAiChat() async {
    if (_aiChatOpen ||
        !widget.followCurrentSession ||
        _mediaService.currentItem == null) {
      return;
    }
    _aiChatOpen = true;
    if (_showVolumePanel) setState(() => _showVolumePanel = false);
    if (_showFontSizeSlider) setState(() => _showFontSizeSlider = false);
    _cancelAutoHideTimer();
    _hideControlsTimer?.cancel();
    try {
      await showMusicAiChatPage(
        context,
        playback: _mediaService,
        onSeek: (position) {
          if (mounted) _handleSeekTo(position);
        },
      );
    } finally {
      _aiChatOpen = false;
      if (mounted) {
        _startAutoHideTimer();
        _scheduleKeyboardFocusRestore();
        _syncMobileSystemUiForOrientation(force: true);
      }
    }
  }

  /// 选集跟定时、AI 对话放在同一排，避免在播放键下方把整组控制顶上去。
  Widget _buildEpisodePickerButton() => DesktopButtonClickRegion(
    child: IconButton(
      key: const ValueKey('music-episode-picker-button'),
      tooltip: DesktopPlayerShortcuts.buildTooltip(
        '选集',
        DesktopPlayerShortcutAction.toggleEpisodePicker,
        context: context,
      ),
      onPressed: _episodePickerAction,
      icon: const Icon(Icons.queue_music_rounded, size: 20),
    ),
  );

  Widget _buildAiChatButton() => DesktopButtonClickRegion(
    child: IconButton(
      key: const ValueKey('music-toolbar-ai-chat'),
      tooltip: DesktopPlayerShortcuts.buildTooltip(
        'AI 对话',
        DesktopPlayerShortcutAction.toggleAiChat,
        context: context,
      ),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed:
          widget.followCurrentSession && _mediaService.currentItem != null
          ? () => unawaited(_openAiChat())
          : null,
      icon: const Icon(Icons.auto_awesome_outlined, size: 20),
    ),
  );

  Widget _buildPortraitMoreButton() => CapsulePopupMenuButton<String>(
    key: const ValueKey('music-portrait-more'),
    tooltip: '更多操作',
    icon: const Icon(
      Icons.more_horiz_rounded,
      size: 20,
      color: Color(0xD9FFFFFF),
    ),
    padding: EdgeInsets.zero,
    color: const Color(0xFF29292D),
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    onSelected: (action) {
      _onUserInteraction();
      switch (action) {
        case 'subtitles':
          showMusicSubtitleManagementDialog(context, artist: widget.artist);
        case 'font':
          _togglePageSettings();
        case 'sleep':
          unawaited(showSleepTimerDialog(context));
      }
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        value: 'subtitles',
        enabled:
            widget.followCurrentSession && _mediaService.currentItem != null,
        child: Tooltip(
          message: DesktopPlayerShortcuts.buildTooltip(
            '字幕与歌词',
            DesktopPlayerShortcutAction.openSubtitleLibrary,
            context: context,
          ),
          child: const Text('字幕与歌词', style: TextStyle(color: Colors.white70)),
        ),
      ),
      PopupMenuItem(
        value: 'font',
        enabled: !_lyricSelectionActive,
        child: Tooltip(
          message: DesktopPlayerShortcuts.buildTooltip(
            '页面设置',
            DesktopPlayerShortcutAction.openSettings,
            context: context,
          ),
          child: const Text('页面设置', style: TextStyle(color: Colors.white70)),
        ),
      ),
      PopupMenuItem(
        value: 'sleep',
        child: Tooltip(
          message: DesktopPlayerShortcuts.buildTooltip(
            '定时关闭',
            DesktopPlayerShortcutAction.openSleepTimer,
            context: context,
          ),
          child: const Text('定时关闭', style: TextStyle(color: Colors.white70)),
        ),
      ),
    ],
  );

  /// 处理键盘快捷键事件
  void _handleAndroidHardwareKeyEvent(AndroidHardwareKeyMessage message) {
    _handleKeyEvent(
      _focusNode,
      message.toKeyEvent(),
      fromAndroidNativeBridge: true,
      hasBlockingModifierOverride: message.hasBlockingModifier,
    );
  }

  KeyEventResult _handleKeyEvent(
    FocusNode node,
    KeyEvent event, {
    bool fromAndroidNativeBridge = false,
    bool? hasBlockingModifierOverride,
  }) {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final hasBlockingModifier =
        hasBlockingModifierOverride ??
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    final supportsSystemEscapeShortcut = !Platform.isAndroid;
    final supportsWindowFullScreenShortcut =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final action = DesktopPlayerShortcuts.matchAction(key);
    final isPageAction = switch (action) {
      DesktopPlayerShortcutAction.toggleEpisodePicker ||
      DesktopPlayerShortcutAction.previousEpisode ||
      DesktopPlayerShortcutAction.nextEpisode ||
      DesktopPlayerShortcutAction.toggleAiChat ||
      DesktopPlayerShortcutAction.openSubtitleLibrary ||
      DesktopPlayerShortcutAction.openSettings ||
      DesktopPlayerShortcutAction.openSleepTimer => true,
      _ => false,
    };
    final isSupportedKey =
        key == LogicalKeyboardKey.space ||
        (supportsSystemEscapeShortcut && key == LogicalKeyboardKey.escape) ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        (supportsWindowFullScreenShortcut && key == LogicalKeyboardKey.keyF) ||
        key == LogicalKeyboardKey.keyM ||
        isPageAction;

    if (!isSupportedKey) return KeyEventResult.ignored;

    final selectionActive =
        _lyricSelectionActive ||
        (_lyricRegionKey.currentState?.isSelectionActive ?? false);
    if (selectionActive) {
      if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
        _lyricRegionKey.currentState?.handleEscape();
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent || event is KeyUpEvent) {
        return KeyEventResult.handled;
      }
      // Letters, space and arrows belong to the text selection while it is
      // open. Playback stays on the visible buttons and system media keys.
      return KeyEventResult.ignored;
    }

    if (_isTextInputFocused() || hasBlockingModifier) {
      return KeyEventResult.ignored;
    }

    if (Platform.isAndroid &&
        !_androidKeyDeduplicator.shouldDispatch(
          event,
          fromNativeBridge: fromAndroidNativeBridge,
        )) {
      return KeyEventResult.handled;
    }

    // Match the video player: one action per physical press, with OS key
    // repeats and the matching key-up consumed instead of leaking downstream.
    if (event is KeyRepeatEvent || event is KeyUpEvent) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    final mediaService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final settings = Provider.of<SettingsService>(context, listen: false);

    if (isPageAction) {
      // New page commands wait for source adoption; text selection, editing,
      // route ownership and Android duplicate delivery were checked above.
      if (widget.isLoading) return KeyEventResult.handled;
      switch (action) {
        case DesktopPlayerShortcutAction.toggleEpisodePicker:
          final playlist = context.read<PlaylistManager?>();
          if (widget.followCurrentSession &&
              playlist?.playlist.isNotEmpty == true) {
            unawaited(_openEpisodes());
          }
        case DesktopPlayerShortcutAction.previousEpisode:
          final previous = _previousAction;
          if (previous != null) {
            _onUserInteraction();
            previous();
          }
        case DesktopPlayerShortcutAction.nextEpisode:
          final next = _nextAction;
          if (next != null) {
            _onUserInteraction();
            next();
          }
        case DesktopPlayerShortcutAction.toggleAiChat:
          unawaited(_openAiChat());
        case DesktopPlayerShortcutAction.openSubtitleLibrary:
          if (widget.followCurrentSession && mediaService.currentItem != null) {
            _onUserInteraction();
            unawaited(
              showMusicSubtitleManagementDialog(context, artist: widget.artist),
            );
          }
        case DesktopPlayerShortcutAction.openSettings:
          _togglePageSettings();
        case DesktopPlayerShortcutAction.openSleepTimer:
          _onUserInteraction();
          unawaited(showSleepTimerDialog(context));
        default:
          break;
      }
      return KeyEventResult.handled;
    }

    // While this panel is open, horizontal arrows fine-tune volume instead
    // of seeking the track behind the focused slider.
    if (_showVolumePanel &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _volumeController.setVolume(
        _volumeController.volume +
            (key == LogicalKeyboardKey.arrowRight ? 0.01 : -0.01),
      );
      return KeyEventResult.handled;
    }

    // 空格键：播放/暂停
    if (key == LogicalKeyboardKey.space) {
      if (mediaService.isSourceMissing) return KeyEventResult.handled;
      if (widget.onPlayPause != null) {
        widget.onPlayPause!.call();
      } else if (mediaService.desiredPlaying) {
        unawaited(mediaService.pause());
      } else {
        unawaited(mediaService.resume());
      }
      return KeyEventResult.handled;
    }

    // ESC键：退出
    if (key == LogicalKeyboardKey.escape) {
      unawaited(_handleBackRequest());
      return KeyEventResult.handled;
    }

    // 左箭头：后退几秒
    if (key == LogicalKeyboardKey.arrowLeft) {
      final seekSeconds = settings.doubleTapSeekSeconds;
      final newPosition =
          mediaService.position - Duration(seconds: seekSeconds);
      _handleSeekTo(newPosition.isNegative ? Duration.zero : newPosition);
      return KeyEventResult.handled;
    }

    // 右箭头：前进几秒
    if (key == LogicalKeyboardKey.arrowRight) {
      final seekSeconds = settings.doubleTapSeekSeconds;
      final newPosition =
          mediaService.position + Duration(seconds: seekSeconds);
      final maxPosition = mediaService.duration;
      _handleSeekTo(newPosition > maxPosition ? maxPosition : newPosition);
      return KeyEventResult.handled;
    }

    // 上箭头：增加音量
    if (key == LogicalKeyboardKey.arrowUp) {
      final newVolume = PlayerVolumeKeyboard.applyShortPress(
        _volumeController.volume,
        1,
      );
      _volumeController.setVolume(newVolume);
      return KeyEventResult.handled;
    }

    // 下箭头：减少音量
    if (key == LogicalKeyboardKey.arrowDown) {
      final newVolume = PlayerVolumeKeyboard.applyShortPress(
        _volumeController.volume,
        -1,
      );
      _volumeController.setVolume(newVolume);
      return KeyEventResult.handled;
    }

    // F键：进入/退出全屏。复用桌面播放器的统一快捷键配置，
    // 避免界面提示与实际按键处理再次出现不一致。
    if (DesktopPlayerShortcuts.matchAction(key) ==
        DesktopPlayerShortcutAction.toggleFullScreen) {
      unawaited(_toggleFullScreen(settings));
      return KeyEventResult.handled;
    }

    // M键：静音/取消静音
    if (key == LogicalKeyboardKey.keyM) {
      unawaited(mediaService.toggleMute());
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// 处理歌词视图的滚动方向变化（Apple Music 手机端控件显隐逻辑）
  ///
  /// 方向定义（与 music_lyric_view.dart 一致）：
  /// - direction > 0: 用户向上滑歌词（内容向下移/往前翻）→ 立即显示底部播放控件
  /// - direction < 0: 用户向下滑歌词（内容向上移/往后翻）→ 延迟隐藏底部播放控件
  /// - null: 恢复自动跟随模式 → 不影响控件显示/隐藏状态（保持当前状态）
  void _handleLyricScrollDirection(double? direction) {
    if (!_portraitControlsAutoHide || _showFontSizeSlider || _showVolumePanel) {
      return;
    }
    if (_lyricSelectionActive || _lyricPointerHolding) return;
    if (direction == null) {
      // 恢复自动跟随模式 → 不影响控件显示/隐藏状态
      _hideControlsTimer?.cancel();
      return;
    }

    // direction > 0: 用户向上滑歌词（往前翻）→ 立即显示控件
    // direction < 0: 用户向下滑歌词（往后翻）→ 延迟隐藏控件
    if (direction < 0) {
      // 用户向下滑歌词（往后翻/查看后续）→ 延迟隐藏控件（50ms 足够避免误触，同时提升响应速度）
      if (_verticalControlsVisible) {
        _hideControlsTimer?.cancel();
        _hideControlsTimer = Timer(const Duration(milliseconds: 50), () {
          if (mounted) {
            _setControlsVisible(false);
            // 控件隐藏后取消自动隐藏定时器
            _cancelAutoHideTimer();
          }
        });
      }
    } else {
      // 用户向上滑歌词（往前翻/回到当前行）→ 立即显示控件 + 取消待执行的隐藏 + 重置自动隐藏定时器
      _hideControlsTimer?.cancel();
      _setControlsVisible(true);
      if (!_isLyricScrollActive) _startAutoHideTimer();
    }
  }

  void _handleLyricScrollActivity(bool active) {
    if (_lyricSelectionActive || _lyricPointerHolding) return;
    _isLyricScrollActive = active;
    if (active) {
      _cancelAutoHideTimer();
    } else if (_verticalControlsVisible) {
      _startAutoHideTimer();
    }
  }

  /// 启动自动隐藏控件定时器（Apple Music 核心逻辑）
  ///
  /// 控件显示后，若用户在 _autoHideDelay 时间内没有交互，则自动隐藏。
  /// 每次用户交互（点击、滚动等）时都应调用此方法重置定时器。
  void _startAutoHideTimer() {
    _cancelAutoHideTimer();
    if (!_portraitControlsAutoHide ||
        _showFontSizeSlider ||
        _showVolumePanel ||
        !_hasTimedSubtitles ||
        widget.isLoading ||
        _lyricSelectionActive ||
        _lyricPointerHolding) {
      return;
    }
    if (_verticalControlsVisible && mounted) {
      _autoHideControlsTimer = Timer(_autoHideDelay, () {
        _setControlsVisible(false);
        _hideControlsTimer?.cancel();
      });
    }
  }

  /// 取消自动隐藏控件定时器
  void _cancelAutoHideTimer() {
    _autoHideControlsTimer?.cancel();
    _autoHideControlsTimer = null;
  }

  /// 用户与屏幕交互时调用：显示控件并重置自动隐藏定时器
  void _onUserInteraction() {
    _setControlsVisible(true);
    _startAutoHideTimer();
  }

  void _handlePortraitBackgroundTap() {
    // Raw lyric pointer listeners and the background tap recognizer can finish
    // in either order. Let the entire pointer event finish before deciding
    // whether this tap was a request for controls or a subtitle seek.
    scheduleMicrotask(() {
      if (!mounted || _lyricSelectionActive) return;
      if (_suppressNextBackgroundTap) {
        _suppressNextBackgroundTap = false;
        return;
      }
      _onUserInteraction();
    });
  }

  void _handleDirectLyricTap() {
    _suppressNextBackgroundTap = true;
    // A semantics action has no enclosing pointer tap. Bound suppression to
    // the current event/frame so it cannot consume a later background tap.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _suppressNextBackgroundTap = false;
    });
  }

  bool _isConfirmedAlacItem(VideoItem? item) {
    if (item == null || item.type != MediaType.audio) return false;
    final declaredCodec = item.codec?.trim().toLowerCase();
    if (declaredCodec == 'alac') return true;
    final cachedCodec = AudioPlaybackCompatibilityService.cachedAudioCodec(
      item.path,
    );
    if (cachedCodec != null) return cachedCodec.toLowerCase() == 'alac';

    final extension = item.path.toLowerCase();
    if (extension.endsWith('.alac')) return true;
    if (!extension.endsWith('.m4a') && !extension.endsWith('.m4b')) {
      return false;
    }
    _scheduleAudioCodecProbe(item);
    return false;
  }

  void _scheduleAudioCodecProbe(VideoItem item) {
    if (_audioCodecProbePath == item.path) return;
    _audioCodecProbePath = item.path;
    final generation = ++_audioCodecProbeGeneration;
    unawaited(
      AudioPlaybackCompatibilityService.probeAudioCodec(item.path).then((_) {
        if (!mounted || generation != _audioCodecProbeGeneration) return;
        if (_mediaService.currentItem?.path != item.path) return;
        setState(() {});
      }),
    );
  }

  void _handleSeekTo(Duration position) {
    if (_mediaService.isSourceMissing) return;
    final onSeek = widget.onSeek;
    if (onSeek != null) {
      onSeek(position);
    } else {
      unawaited(_mediaService.seekTo(position, source: 'music-player'));
    }
  }

  void _handleProgressChange(double value) {
    setState(() => _dragProgress = value);
    // 拖动时立即更新 _displayPosition，让进度条跟随手指
    if (_isDragging) {
      final totalMs = _mediaService.duration.inMilliseconds;
      if (totalMs > 0) {
        _displayPosition.value = Duration(
          milliseconds: (value * totalMs).round(),
        );
      }
    }
  }

  void _handleProgressChangeStart(double value) {
    // 用户开始拖拽进度条 → 显示控件并重置自动隐藏定时器
    _onUserInteraction();
    _cancelAutoHideTimer();
    setState(() {
      _isDragging = true;
      _dragProgress = value;
    });
    _displayPosition.value = Duration(
      milliseconds: (value * _mediaService.duration.inMilliseconds).round(),
    );
  }

  void _handleProgressChangeEnd(double value) {
    // 用户结束拖拽进度条 → 重置自动隐藏定时器
    _onUserInteraction();
    setState(() {
      _isDragging = false;
      _seekTargetProgress = value; // 记录 seek 目标位置
    });
    final seekPos = Duration(
      milliseconds: (value * _mediaService.duration.inMilliseconds).round(),
    );
    // 立即更新显示位置到目标位置，避免闪烁
    _displayPosition.value = seekPos;
    _lyricPositionController.locate(seekPos);
    _lyricPosition.value = seekPos;
    _handleSeekTo(seekPos);
  }

  double _getEffectiveProgress() {
    if (_isDragging) return _dragProgress;
    final duration = _mediaService.duration;
    if (duration.inMilliseconds == 0) return 0.0;
    return (_mediaService.position.inMilliseconds / duration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  void _onLyricSelectionPhase(MusicLyricSelectionPhase phase) {
    final active = phase != MusicLyricSelectionPhase.normal;
    if (_lyricSelectionActive == active) {
      if (mounted) setState(() {});
      return;
    }
    setState(() {
      _lyricSelectionActive = active;
      if (active) _showFontSizeSlider = false;
      if (active) _showVolumePanel = false;
    });
    if (active) {
      _cancelAutoHideTimer();
      _hideControlsTimer?.cancel();
      _setControlsVisible(true);
    } else {
      _setControlsVisible(true);
      _startAutoHideTimer();
      _scheduleKeyboardFocusRestore();
    }
  }

  void _onLyricPointerHold(bool holding) {
    _lyricPointerHolding = holding;
    if (holding) {
      _cancelAutoHideTimer();
      _hideControlsTimer?.cancel();
    } else if (!_lyricSelectionActive && _verticalControlsVisible) {
      _startAutoHideTimer();
    }
  }

  Widget _lyricRegion({
    required String itemId,
    required List<SubtitleItem> subtitles,
    required List<SubtitleItem> secondarySubtitles,
    required bool splitSubtitleByLine,
    required MusicLyricTrackDisplayMode preference,
    required double fontScale,
    required double anchorFraction,
    required double horizontalPaddingFraction,
    required bool applyEdgeFade,
    required MediaPlaybackService mediaService,
    required bool portraitScroll,
    EdgeInsets? focusInsets,
    String? trackTitle,
    bool mergeTitle = false,
  }) {
    return Selector<
      MediaPlaybackService,
      ({List<SubtitleItem> primary, List<SubtitleItem> secondary})
    >(
      selector: (context, service) => (
        primary: widget.followCurrentSession ? service.subtitles : subtitles,
        secondary: widget.followCurrentSession
            ? service.secondarySubtitles
            : secondarySubtitles,
      ),
      builder: (context, source, _) {
        final subtitles = source.primary;
        final secondarySubtitles = source.secondary;
        final hasText =
            subtitles.any(_cueHasContent) ||
            secondarySubtitles.any(_cueHasContent);
        if (!hasText && widget.transcriptFallback != null) {
          return widget.transcriptFallback!;
        }
        return MusicLyricRegion(
          key: _lyricRegionKey,
          mediaId: itemId,
          subtitles: subtitles,
          secondarySubtitles: secondarySubtitles,
          splitSubtitleByLine: splitSubtitleByLine,
          preference: preference,
          onPreferenceChanged: (mode) {
            Provider.of<SettingsService>(
              context,
              listen: false,
            ).updateMusicLyricTrackDisplayMode(mode.storageValue);
          },
          sourceMissing: mediaService.isSourceMissing,
          trackTitle: trackTitle,
          mergeTitle: mergeTitle,
          onPhaseChanged: _onLyricSelectionPhase,
          onSeek: _handleSeekTo,
          positionListenable: _lyricPosition,
          positionController: _lyricPositionController,
          onScrollDirectionChanged: portraitScroll
              ? _handleLyricScrollDirection
              : null,
          onManualScrollActivityChanged: portraitScroll
              ? _handleLyricScrollActivity
              : null,
          onDirectLyricTap: portraitScroll ? _handleDirectLyricTap : null,
          onPointerHoldChanged: _onLyricPointerHold,
          stabilizeAlacDirectSeek: _isConfirmedAlacItem(
            mediaService.currentItem,
          ),
          isPlaying: mediaService.isPlaying,
          lyricFontSizeScale: fontScale,
          lyricSpacingScale: _currentLyricSpacingScale,
          wordByWordEnabled: _lyricWordByWordEnabled,
          lyricBlurEnabled: _lyricBlurEnabled,
          anchorFraction: anchorFraction,
          showAnchorGuide: _showFontSizeSlider && _showLyricAnchorGuide,
          onAnchorGuidePositionChanged: _onLyricAnchorGuidePositionChanged,
          focusInsets: focusInsets,
          horizontalPaddingFraction: horizontalPaddingFraction,
          applyEdgeFade: applyEdgeFade,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 响应式读取"识别第一行为主字幕"设置，变化时自动重建
    final splitSubtitleByLine = context.select<SettingsService, bool>(
      (s) => s.splitSubtitleByLine,
    );
    final lyricDisplayMode = musicLyricTrackDisplayModeFromStorage(
      context.select<SettingsService, String>(
        (s) => s.musicLyricTrackDisplayMode,
      ),
    );
    // 性能优化：用 Selector 精准订阅低频字段，避免每 300ms position notify 触发全屏重建。
    // 快照不含 position（position 由 positionNotifier 逐帧驱动，无需 build 刷新），
    // 故 300ms 定时器的 notifyListeners 不会触发 builder；仅字幕/时长/播放态等
    // 真正变化时才重建子树。mediaService 引用以 listen:false 获取（用于回调与实时读取）。
    // 音量由控制器单独驱动按钮和弹层，连续拖动不重建歌词与封面。
    return _MusicPlayerViewport(
      child: Selector<MediaPlaybackService, _PlayerSnapshot>(
        selector: (context, s) => _PlayerSnapshot(
          itemId: widget.followCurrentSession
              ? s.currentItem?.id ?? 'null'
              : 'pending',
          cover: widget.followCurrentSession
              ? s.currentItem?.thumbnailPath
              : widget.coverImagePath,
          title: widget.followCurrentSession
              ? s.currentItem?.title ?? widget.title
              : widget.title,
          duration: widget.followCurrentSession
              ? s.duration
              : widget.totalDuration,
          subtitles: widget.followCurrentSession ? s.subtitles : const [],
          secondarySubtitles: widget.followCurrentSession
              ? s.secondarySubtitles
              : const [],
          isPlaying: widget.followCurrentSession && s.isPlaying,
          isSourceMissing: widget.followCurrentSession && s.isSourceMissing,
          hasLyricText:
              widget.followCurrentSession &&
              (s.subtitles.any(_cueHasContent) ||
                  s.secondarySubtitles.any(_cueHasContent)),
        ),
        builder: (context, snapshot, child) {
          final mediaService = Provider.of<MediaPlaybackService>(
            context,
            listen: false,
          );

          // 使用实时数据（来自快照，builder 仅在低频字段变化时执行，故数据新鲜）
          final effectiveCover = snapshot.cover ?? widget.coverImagePath;
          final effectiveTitle = snapshot.title;
          // VideoItem 没有 artist 字段，使用 widget.artist（如果有传入）或留空
          final effectiveArtist = widget.artist;
          final effectiveTotalDuration = snapshot.duration > Duration.zero
              ? snapshot.duration
              : widget.totalDuration;
          final effectiveSubtitles = snapshot.subtitles;
          final effectiveSecondarySubtitles = snapshot.secondarySubtitles;

          return PopScope(
            canPop:
                !_lyricSelectionActive &&
                !_showFontSizeSlider &&
                !_showVolumePanel &&
                !_windowFullScreen,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              unawaited(_handleBackRequest());
            },
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              backgroundColor: Colors.black,
              body: Focus(
                focusNode: _focusNode,
                autofocus: true,
                onKeyEvent: _handleKeyEvent,
                child: Stack(
                  key: _pageOverlayKey,
                  children: [
                    // Block 1: 背景层（封面高斯模糊 + 半透明黑色遮罩）
                    _buildBackgroundLayer(effectiveCover),

                    // 页面骨架在切集时保持原位。仅封面背景与歌词内容自行过渡，
                    // 避免标题、进度条和控制按钮随整页缩放或闪动。
                    SafeArea(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final viewport = Size(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          );
                          _layoutViewport = viewport;
                          final portrait = musicPlayerUsesVerticalLayout(
                            viewport,
                          );
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              if (portrait)
                                _buildVerticalLayout(
                                  mediaService,
                                  snapshot.itemId,
                                  effectiveTitle,
                                  effectiveArtist,
                                  effectiveSubtitles,
                                  effectiveSecondarySubtitles,
                                  splitSubtitleByLine,
                                  lyricDisplayMode,
                                  viewport,
                                )
                              else
                                _buildHorizontalLayout(
                                  mediaService,
                                  snapshot.itemId,
                                  effectiveTotalDuration,
                                  effectiveTitle,
                                  effectiveArtist,
                                  effectiveSubtitles,
                                  effectiveSecondarySubtitles,
                                  splitSubtitleByLine,
                                  lyricDisplayMode,
                                ),
                              if (snapshot.isSourceMissing &&
                                  !_lyricSelectionActive)
                                Positioned.fill(
                                  child: MissingLocalSourcePanel(
                                    item: mediaService.currentItem,
                                    fontSize: 18,
                                  ),
                                ),
                              if (!portrait) _buildLandscapeTools(),
                            ],
                          );
                        },
                      ),
                    ),

                    // 字号调节滑块（出现在字号调节按钮附近）。
                    // 打开后铺一层透明遮罩：点滑块以外任意位置即可收起，不必再点一次按钮。
                    if (_showFontSizeSlider)
                      Positioned.fill(
                        child: Stack(
                          children: [
                            GestureDetector(
                              key: const ValueKey(
                                'music-font-size-dismiss-barrier',
                              ),
                              behavior: HitTestBehavior.opaque,
                              onTap: _dismissFontSizeSlider,
                              child: const SizedBox.expand(),
                            ),
                            _buildFontSizeSliderPositioned(),
                          ],
                        ),
                      ),
                    _buildLyricAnchorGuideOverlay(),
                    Positioned.fill(
                      child: IgnorePointer(
                        ignoring: !_showVolumePanel,
                        child: AnimatedSwitcher(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 200),
                          reverseDuration:
                              MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 140),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: !_showVolumePanel
                              ? const SizedBox.shrink()
                              : Stack(
                                  key: const ValueKey('music-volume-overlay'),
                                  children: [
                                    GestureDetector(
                                      key: const ValueKey(
                                        'music-volume-dismiss-barrier',
                                      ),
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _dismissVolumePanel,
                                      child: const SizedBox.expand(),
                                    ),
                                    _buildVolumePanelPositioned(),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 当前是否为竖屏（窄屏）布局：与 build 中 LayoutBuilder 的断点保持一致（<768px）
  bool get _isPortraitLayout => musicPlayerUsesVerticalLayout(
    _layoutViewport ?? MediaQuery.sizeOf(context),
  );

  /// 当前布局下应使用的歌词字号缩放比例（竖屏 / 横屏分别记忆）
  double get _currentLyricFontSizeScale => _isPortraitLayout
      ? _lyricFontSizeScalePortrait
      : _lyricFontSizeScaleLandscape;

  double get _currentLyricSpacingScale => _isPortraitLayout
      ? _lyricSpacingScalePortrait
      : _lyricSpacingScaleLandscape;

  double get _currentLyricAnchor =>
      _isPortraitLayout ? _lyricAnchorPortrait : _lyricAnchorLandscape;

  double get _defaultLyricAnchor => _isPortraitLayout
      ? MusicLyricAnchor.portraitDefault
      : MusicLyricAnchor.landscapeDefault;

  double get _effectiveLyricAnchor =>
      _currentLyricAnchor == MusicLyricAnchor.automatic
      ? _defaultLyricAnchor
      : _currentLyricAnchor;

  void _onLyricAnchorGuidePositionChanged(Offset globalPosition) {
    if (!mounted || !_showFontSizeSlider || !_showLyricAnchorGuide) return;
    final overlay = _pageOverlayKey.currentContext?.findRenderObject();
    if (overlay is RenderBox && overlay.hasSize) {
      _lyricAnchorGuideY.value = overlay.globalToLocal(globalPosition).dy;
    }
  }

  Widget _buildLyricAnchorGuideOverlay() => Positioned.fill(
    child: IgnorePointer(
      child: ValueListenableBuilder<double?>(
        valueListenable: _lyricAnchorGuideY,
        builder: (context, y, _) => Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: y ?? 0,
              child: MusicLyricAnchorGuide(
                key: const ValueKey('music-lyric-anchor-guide'),
                visible:
                    y != null && _showFontSizeSlider && _showLyricAnchorGuide,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  void _clearLyricAnchorPreview() {
    _lyricAnchorGuideTimer?.cancel();
    _isAdjustingLyricAnchor = false;
    _showLyricAnchorGuide = false;
  }

  void _startLyricAnchorPreview(double _) {
    _lyricAnchorGuideTimer?.cancel();
    _onUserInteraction();
    setState(() {
      _isAdjustingLyricAnchor = true;
      _showLyricAnchorGuide = true;
    });
  }

  void _onLyricAnchorChanged(double value) {
    value = MusicLyricAnchor.normalize(value);
    _lyricAnchorGuideTimer?.cancel();
    _onUserInteraction();
    setState(() {
      if (_isPortraitLayout) {
        _lyricAnchorPortrait = value;
      } else {
        _lyricAnchorLandscape = value;
      }
      _isAdjustingLyricAnchor = true;
      _showLyricAnchorGuide = true;
      _lyricTypographyDirty = true;
    });
  }

  void _endLyricAnchorPreview(double _) {
    _persistLyricTypography();
    if (!mounted) return;
    setState(() => _isAdjustingLyricAnchor = false);
    _lyricAnchorGuideTimer?.cancel();
    _lyricAnchorGuideTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _showLyricAnchorGuide = false);
    });
  }

  void _resetLyricAnchor() {
    _onLyricAnchorChanged(MusicLyricAnchor.automatic);
    _endLyricAnchorPreview(0);
  }

  /// 收起字号调节滑块。点按钮以外的区域时调用。
  /// 这次点击被遮罩吃掉了，补一次交互，避免竖屏控件因此少了一次重置自动隐藏。
  void _dismissFontSizeSlider() {
    if (!mounted || !_showFontSizeSlider) return;
    _persistLyricTypography();
    setState(() {
      _showFontSizeSlider = false;
      _clearLyricAnchorPreview();
    });
    _onUserInteraction();
  }

  void _togglePageSettings() {
    if (_showFontSizeSlider) _persistLyricTypography();
    setState(() {
      _clearLyricAnchorPreview();
      _showVolumePanel = false;
      _showFontSizeSlider = !_showFontSizeSlider;
    });
    _hideControlsTimer?.cancel();
    _onUserInteraction();
  }

  void _dismissVolumePanel() {
    if (!mounted || !_showVolumePanel) return;
    setState(() => _showVolumePanel = false);
    _volumeController.endDrag();
    _onUserInteraction();
    _scheduleKeyboardFocusRestore();
  }

  void _toggleVolumePanel() {
    if (_showFontSizeSlider) _persistLyricTypography();
    setState(() {
      _clearLyricAnchorPreview();
      _showFontSizeSlider = false;
      _showVolumePanel = !_showVolumePanel;
    });
    _hideControlsTimer?.cancel();
    _onUserInteraction();
    if (_showVolumePanel) unawaited(_volumeController.refresh());
  }

  Widget _buildVolumePanelPositioned() {
    return LayoutBuilder(
      builder: (overlayContext, constraints) {
        final padding = MediaQuery.paddingOf(overlayContext);
        final screen = constraints.biggest;
        final width = 296.0.clamp(0.0, screen.width - padding.horizontal - 24);
        final overlayBox = overlayContext.findRenderObject() as RenderBox;
        final buttonBox =
            _volumeButtonKey.currentContext?.findRenderObject() as RenderBox?;
        final position = buttonBox == null
            ? null
            : overlayBox.globalToLocal(buttonBox.localToGlobal(Offset.zero));
        final left = (position?.dx ?? padding.left + 12).clamp(
          padding.left + 12,
          screen.width - padding.right - width - 12,
        );
        final safeTop = padding.top + 8;
        final bottom =
            (screen.height - (position?.dy ?? screen.height - 100) + 8).clamp(
              padding.bottom + 8,
              screen.height - safeTop - 52,
            );
        return Stack(
          children: [
            Positioned(
              key: const ValueKey('music-volume-panel'),
              left: left,
              bottom: bottom,
              width: width,
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => Opacity(
                  opacity: value,
                  child: Transform.translate(
                    offset: Offset(0, 6 * (1 - value)),
                    child: child,
                  ),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: screen.height - bottom - safeTop,
                  ),
                  child: SingleChildScrollView(
                    child: MusicVolumePanel(
                      controller: _volumeController,
                      onClose: _dismissVolumePanel,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _onPortraitControlsAutoHideChanged(bool value) {
    if (_portraitControlsAutoHide == value) return;
    setState(() => _portraitControlsAutoHide = value);
    _hideControlsTimer?.cancel();
    _onUserInteraction();
    unawaited(
      context.read<SettingsService>().updateMusicPortraitControlsAutoHide(
        value,
      ),
    );
  }

  /// 拖动时只刷新预览，松手再保存，避免每个指针事件都写偏好。
  void _onFontSizeChanged(double value) {
    value = MusicLyricTypography.normalizeFontSizeScale(value);
    if (_currentLyricFontSizeScale == value) return;
    _onUserInteraction();
    setState(() {
      if (_isPortraitLayout) {
        _lyricFontSizeScalePortrait = value;
      } else {
        _lyricFontSizeScaleLandscape = value;
      }
      _lyricTypographyDirty = true;
    });
  }

  void _onLyricSpacingChanged(double value) {
    value = MusicLyricTypography.normalizeSpacingScale(value);
    if (_currentLyricSpacingScale == value) return;
    _onUserInteraction();
    setState(() {
      if (_isPortraitLayout) {
        _lyricSpacingScalePortrait = value;
      } else {
        _lyricSpacingScaleLandscape = value;
      }
      _lyricTypographyDirty = true;
    });
  }

  void _persistLyricTypography() {
    if (!_lyricTypographyDirty) return;
    _lyricTypographyDirty = false;
    final settings = _lyricTypographySettings;
    if (settings.musicLyricAnchorPortrait != _lyricAnchorPortrait) {
      unawaited(settings.updateMusicLyricAnchorPortrait(_lyricAnchorPortrait));
    }
    if (settings.musicLyricAnchorLandscape != _lyricAnchorLandscape) {
      unawaited(
        settings.updateMusicLyricAnchorLandscape(_lyricAnchorLandscape),
      );
    }
    if (settings.musicLyricFontSizeScalePortrait !=
        _lyricFontSizeScalePortrait) {
      unawaited(
        settings.updateMusicLyricFontSizeScalePortrait(
          _lyricFontSizeScalePortrait,
        ),
      );
    }
    if (settings.musicLyricFontSizeScaleLandscape !=
        _lyricFontSizeScaleLandscape) {
      unawaited(
        settings.updateMusicLyricFontSizeScaleLandscape(
          _lyricFontSizeScaleLandscape,
        ),
      );
    }
    if (settings.musicLyricSpacingScalePortrait != _lyricSpacingScalePortrait) {
      unawaited(
        settings.updateMusicLyricSpacingScalePortrait(
          _lyricSpacingScalePortrait,
        ),
      );
    }
    if (settings.musicLyricSpacingScaleLandscape !=
        _lyricSpacingScaleLandscape) {
      unawaited(
        settings.updateMusicLyricSpacingScaleLandscape(
          _lyricSpacingScaleLandscape,
        ),
      );
    }
  }

  /// 逐词开关当帧改歌词，同时写入偏好。点开关不会收起弹层。
  /// 卡片和开关可能在同一次点击里各回调一次，值没变就直接返回。
  void _onWordByWordChanged(bool value) {
    if (_lyricWordByWordEnabled == value) return;
    _onUserInteraction();
    setState(() => _lyricWordByWordEnabled = value);
    unawaited(
      Provider.of<SettingsService>(
        context,
        listen: false,
      ).updateMusicLyricWordByWordEnabled(value),
    );
  }

  /// 模糊开关当帧改歌词景深，同时写入偏好。点开关不会收起弹层。
  void _onLyricBlurChanged(bool value) {
    if (_lyricBlurEnabled == value) return;
    _onUserInteraction();
    setState(() => _lyricBlurEnabled = value);
    unawaited(
      Provider.of<SettingsService>(
        context,
        listen: false,
      ).updateMusicLyricBlurEnabled(value),
    );
  }

  /// 横竖屏共用的页面设置卡片；竖屏额外提供播放控件的自动隐藏选项。
  Widget _buildFontSizeSlider() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: _isAdjustingLyricAnchor ? 2 : 20,
          sigmaY: _isAdjustingLyricAnchor ? 2 : 20,
        ),
        child: AnimatedContainer(
          key: const ValueKey('music-page-settings-surface'),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: _isAdjustingLyricAnchor
                ? const Color(0x3329292E)
                : const Color(0xED29292E),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0x24FFFFFF)),
          ),
          child: Material(
            color: Colors.transparent,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 10, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '页面设置',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          key: const ValueKey('music-page-settings-close'),
                          tooltip: '关闭页面设置',
                          onPressed: _dismissFontSizeSlider,
                          icon: const Icon(Icons.close_rounded, size: 18),
                          style: IconButton.styleFrom(
                            foregroundColor: Colors.white70,
                            backgroundColor: const Color(0x0FFFFFFF),
                            minimumSize: const Size.square(36),
                            padding: const EdgeInsets.all(8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: const CircleBorder(),
                            side: BorderSide.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildLyricStyleSlider(
                    sliderKey: const ValueKey('music-font-size-slider'),
                    resetKey: const ValueKey('music-font-size-reset'),
                    label: '歌词字号',
                    resetTooltip: '恢复默认字号',
                    value: _currentLyricFontSizeScale,
                    min: MusicLyricTypography.minFontSizeScale,
                    max: MusicLyricTypography.maxFontSizeScale,
                    defaultValue: MusicLyricTypography.defaultFontSizeScale,
                    onChanged: _onFontSizeChanged,
                  ),
                  const SizedBox(height: 4),
                  _buildLyricStyleSlider(
                    sliderKey: const ValueKey('music-lyric-spacing-slider'),
                    resetKey: const ValueKey('music-lyric-spacing-reset'),
                    label: '歌词间距',
                    resetTooltip: '恢复默认间距',
                    value: _currentLyricSpacingScale,
                    min: MusicLyricTypography.minSpacingScale,
                    max: MusicLyricTypography.maxSpacingScale,
                    defaultValue: MusicLyricTypography.defaultSpacingScale,
                    onChanged: _onLyricSpacingChanged,
                  ),
                  const SizedBox(height: 4),
                  _buildLyricStyleSlider(
                    sliderKey: const ValueKey('music-lyric-anchor-slider'),
                    resetKey: const ValueKey('music-lyric-anchor-reset'),
                    label: '歌词定位高度',
                    resetTooltip: '恢复默认定位高度',
                    value: _effectiveLyricAnchor,
                    min: MusicLyricAnchor.min,
                    max: MusicLyricAnchor.max,
                    defaultValue: _defaultLyricAnchor,
                    valueText: _currentLyricAnchor == MusicLyricAnchor.automatic
                        ? '自动 · ${(_defaultLyricAnchor * 100).round()}%'
                        : '${(_effectiveLyricAnchor * 100).toStringAsFixed(1)}%',
                    canReset: _currentLyricAnchor != MusicLyricAnchor.automatic,
                    onReset: _resetLyricAnchor,
                    onChanged: _onLyricAnchorChanged,
                    onChangeStart: _startLyricAnchorPreview,
                    onChangeEnd: _endLyricAnchorPreview,
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '靠上',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                        Text(
                          '靠下',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '当前歌词顶部的位置 · 横竖屏分别记忆',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 9, color: Color(0x1FFFFFFF)),
                  _buildLyricStyleSwitch(
                    key: const ValueKey('music-word-by-word-switch'),
                    label: '逐词显示',
                    icon: Icons.lyrics_outlined,
                    value: _lyricWordByWordEnabled,
                    onChanged: _onWordByWordChanged,
                  ),
                  _buildLyricStyleSwitch(
                    key: const ValueKey('music-lyric-blur-switch'),
                    label: '歌词模糊',
                    icon: Icons.blur_on_rounded,
                    value: _lyricBlurEnabled,
                    onChanged: _onLyricBlurChanged,
                  ),
                  if (_isPortraitLayout) ...[
                    const Divider(height: 9, color: Color(0x1FFFFFFF)),
                    _buildLyricStyleSwitch(
                      key: const ValueKey('music-portrait-auto-hide-switch'),
                      label: '自动隐藏播放控件',
                      subtitle: '仅竖屏 · 闲置 5 秒或滚动歌词时隐藏',
                      icon: Icons.auto_awesome_motion_outlined,
                      value: _portraitControlsAutoHide,
                      onChanged: _onPortraitControlsAutoHideChanged,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLyricStyleSlider({
    required Key sliderKey,
    required Key resetKey,
    required String label,
    required String resetTooltip,
    required double value,
    required double min,
    required double max,
    required double defaultValue,
    required ValueChanged<double> onChanged,
    String? valueText,
    bool? canReset,
    VoidCallback? onReset,
    ValueChanged<double>? onChangeStart,
    ValueChanged<double>? onChangeEnd,
  }) {
    String percent(double scale) => '${(scale * 100).toStringAsFixed(1)}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            SizedBox(
              width: MediaQuery.textScalerOf(
                context,
              ).scale(valueText == null ? 54 : 76),
              child: Text(
                valueText ?? percent(value),
                textAlign: TextAlign.end,
                maxLines: 1,
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            // Always occupies the same space, including at the default value.
            DesktopButtonClickRegion(
              child: IconButton(
                key: resetKey,
                tooltip: resetTooltip,
                onPressed: !(canReset ?? value != defaultValue)
                    ? null
                    : onReset ??
                          () {
                            onChanged(defaultValue);
                            _persistLyricTypography();
                          },
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                style: IconButton.styleFrom(
                  foregroundColor: Colors.white70,
                  disabledForegroundColor: Colors.white24,
                  minimumSize: const Size.square(36),
                  padding: const EdgeInsets.all(8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: const CircleBorder(),
                  side: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            showValueIndicator: ShowValueIndicator.onDrag,
            valueIndicatorColor: Colors.white,
            valueIndicatorTextStyle: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: const Color(0xFF29292E), fontSize: 12),
          ),
          child: Slider(
            key: sliderKey,
            value: value,
            min: min,
            max: max,
            label: percent(value),
            semanticFormatterCallback: (value) => '$label ${percent(value)}',
            onChanged: onChanged,
            onChangeStart: onChangeStart,
            onChangeEnd: onChangeEnd ?? (_) => _persistLyricTypography(),
            activeColor: Colors.white,
            inactiveColor: Colors.white24,
            thumbColor: Colors.white,
          ),
        ),
      ],
    );
  }

  /// 保留开关的自然比例，整行都可以点击，并合并辅助功能标签。
  Widget _buildLyricStyleSwitch({
    required Key key,
    required String label,
    required IconData icon,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(icon, color: Colors.white60, size: 19),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                CupertinoSwitch(
                  key: key,
                  value: value,
                  onChanged: onChanged,
                  activeTrackColor: const Color(0xFF34C759),
                  inactiveTrackColor: const Color(0xFF55555C),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 用浮层实际尺寸定位，兼容窗口缩放及与 MediaQuery 不同的布局约束。
  Widget _buildFontSizeSliderPositioned() {
    return LayoutBuilder(
      builder: (overlayContext, constraints) {
        final padding = MediaQuery.paddingOf(overlayContext);
        final screen = constraints.biggest;
        final safeTop = padding.top + 8;
        final safeBottom = padding.bottom + 8;
        final width = _stylePanelWidth.clamp(0.0, screen.width - 24);
        final overlayBox = overlayContext.findRenderObject() as RenderBox;
        final buttonBox =
            _fontSizeButtonKey.currentContext?.findRenderObject() as RenderBox?;
        final buttonPosition = buttonBox == null
            ? null
            : overlayBox.globalToLocal(buttonBox.localToGlobal(Offset.zero));
        final left =
            ((buttonPosition?.dx ?? screen.width) +
                    (buttonBox?.size.width ?? 0) -
                    width)
                .clamp(12.0, screen.width - width - 12);
        final bottom =
            (screen.height - (buttonPosition?.dy ?? screen.height - 100) + 8)
                .clamp(safeBottom, screen.height - safeTop - 96);
        return Stack(
          children: [
            Positioned(
              key: const ValueKey('music-page-settings-panel'),
              left: left,
              bottom: bottom,
              width: width,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: screen.height - bottom - safeTop,
                ),
                child: _buildFontSizeSlider(),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 构建背景层（优化性能：使用缓存的模糊效果）
  Widget _buildBackgroundLayer(String? coverPath) {
    _currentBackdropPath = coverPath;
    return Positioned.fill(
      // Retain the artwork, contrast gradients and vignette together between
      // cover transitions while lyrics animate at the display refresh rate.
      child: MusicBackdropSurface(
        contentKey: coverPath ?? '',
        ready: coverPath != null && coverPath.isNotEmpty
            ? _backdropReady
            : null,
        child: ClipRect(
          key: const ValueKey('music-player-background'),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF343338), Color(0xFF111113)],
                  ),
                ),
              ),

              // 本地封面在后台 isolate 中预先缩小并强模糊。进入页面后这里只
              // 拉伸一张缓存位图，不再对全屏纹理执行实时高斯模糊。
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 520),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: coverPath != null && coverPath.isNotEmpty
                    ? RepaintBoundary(
                        key: ValueKey<String>('music-backdrop-$coverPath'),
                        child: _MusicBackdropArtwork(
                          coverPath: coverPath,
                          onImageReady: () {
                            if (mounted && _currentBackdropPath == coverPath) {
                              _backdropReady.value = coverPath;
                            }
                          },
                        ),
                      )
                    : const SizedBox.expand(
                        key: ValueKey<String>('music-backdrop-fallback'),
                      ),
              ),

              // 保留封面色相，同时稳定白色歌词的对比度和上下层次。
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x5C000000),
                      Color(0x2E000000),
                      Color(0x52000000),
                      Color(0x8A000000),
                    ],
                    stops: [0.0, 0.30, 0.68, 1.0],
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0.45, -0.35),
                    radius: 1.25,
                    colors: [Color(0x00FFFFFF), Color(0x59000000)],
                    stops: [0.36, 1.0],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Keep the toolbar at the upper-left, independent of playback controls.
  Widget _buildLandscapeTools() {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final balanceCorner =
        mobile && MediaQuery.sizeOf(context).shortestSide >= 600;
    final safeInsets = MediaQuery.viewPaddingOf(context);
    final cornerInset = balanceCorner
        ? (safeInsets.top > safeInsets.left ? safeInsets.top : safeInsets.left)
        : 0.0;
    final tools = <Widget>[
      ?widget.detailsAction,
      _buildEpisodePickerButton(),
      const _MusicSleepTimerButton(),
      _buildAiChatButton(),
      ?widget.headerAction,
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
        Consumer<SettingsService>(
          builder: (context, settings, _) => DesktopButtonClickRegion(
            child: IconButton(
              tooltip: DesktopPlayerShortcuts.buildTooltip(
                settings.isFullScreen ? '退出全屏' : '全屏',
                DesktopPlayerShortcutAction.toggleFullScreen,
                context: context,
              ),
              onPressed: () => unawaited(_toggleFullScreen(settings)),
              icon: Icon(
                settings.isFullScreen
                    ? Icons.fullscreen_exit
                    : Icons.fullscreen,
                size: 20,
                color: Colors.white70,
              ),
            ),
          ),
        ),
      DesktopButtonClickRegion(
        child: IconButton(
          key: const ValueKey('music-toolbar-close'),
          tooltip: '关闭',
          onPressed: _handleExit,
          icon: const Icon(
            Icons.close_rounded,
            size: 20,
            color: Colors.white70,
          ),
        ),
      ),
    ];
    return Positioned(
      top:
          _phoneLandscapeSpacing?.toolbarTop ??
          16 + (balanceCorner ? cornerInset - safeInsets.top : 0),
      left: 16 + (balanceCorner ? cornerInset - safeInsets.left : 0),
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: Colors.white70,
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            side: BorderSide.none,
            padding: const EdgeInsets.all(12),
            minimumSize: const Size.square(44),
            maximumSize: const Size.square(44),
            overlayColor: Colors.transparent,
          ),
        ),
        child: KeyedSubtree(
          key: widget.landscapeToolbarKey,
          child: Row(
            key: const ValueKey('music-landscape-toolbar'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (final tool in tools.reversed)
                SizedBox.square(dimension: 44, child: tool),
            ],
          ),
        ),
      ),
    );
  }

  /// 宽屏左右布局（>= 768px）
  ///
  /// 桌面端：左侧面板 50% —— 大 CD 封面 + 歌曲信息 + 控制栏（垂直居中）
  /// 手机横屏：左侧面板 45% —— 紧凑封面 + 铺满面板的控制栏 + 更宽的歌词面板
  /// 右侧面板：同步歌词（当前行锚定在 30% 屏幕高度处）
  ///
  /// 响应式适配：使用 LayoutBuilder 获取实际可用高度，
  /// 确保 CD + 信息 + 控制栏的总高度不超过可用空间。
  /// 在横屏手机（高度小）上自动缩小 CD 尺寸，让控制栏横向铺满，
  /// 消除黑边/空旷感，并让视觉重心回到屏幕中心。
  Widget _buildHorizontalLayout(
    MediaPlaybackService mediaService,
    String itemId,
    Duration effectiveTotalDuration,
    String effectiveTitle,
    String effectiveArtist,
    List<SubtitleItem> effectiveSubtitles,
    List<SubtitleItem> effectiveSecondarySubtitles,
    bool splitSubtitleByLine,
    MusicLyricTrackDisplayMode lyricDisplayMode,
  ) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final screenWidth = MediaQuery.sizeOf(context).width;

    final effectiveCover = widget.followCurrentSession
        ? mediaService.currentItem?.thumbnailPath ?? widget.coverImagePath
        : widget.coverImagePath;

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final phoneSpacing = _phoneLandscapeSpacing;
        final layout = _MusicLandscapeLayout(
          Size(availableWidth, constraints.maxHeight),
          screenHeight,
          MediaQuery.textScalerOf(context),
          phoneSpacing: phoneSpacing,
        );
        final isMobileLandscape = layout.compact;
        final toolsTopInset = layout.topInset;
        final availableHeight = layout.availableHeight;
        final leftFlex = layout.leftFlex;
        final leftPanelPadding = layout.leftPadding;
        final leftPanelInnerWidth =
            layout.leftPanelWidth - leftPanelPadding * 2;
        final cdSize = layout.coverSize;
        final controlsWidth = layout.controlsWidth;

        // 歌曲信息宽度：手机横屏与面板基本同宽，避免文字拥挤在封面下方
        final infoWidth = leftPanelInnerWidth - (isMobileLandscape ? 0 : 48);

        // 歌曲信息到进度条间距
        final infoToControlsGap = isMobileLandscape
            ? (availableHeight * 0.018).clamp(5.0, 8.0)
            : (screenHeight * 0.025).clamp(6.0, 24.0);

        final selectionPlan = _lyricSelectionActive
            ? planMusicLyricSelectionColumns(
                vertical: false,
                width: availableWidth,
                height: constraints.maxHeight,
                gap: 16,
                toolsTop: toolsTopInset,
                horizontalMargin: 16,
              )
            : null;
        if (selectionPlan?.degraded == true) {
          return Padding(
            padding: EdgeInsets.fromLTRB(12, toolsTopInset, 12, 8),
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          effectiveTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      CapsulePopupMenuButton<String>(
                        tooltip: '更多',
                        onSelected: (value) {
                          if (value == 'previous') _previousAction?.call();
                          if (value == 'next') _nextAction?.call();
                        },
                        itemBuilder: (context) => [
                          if (_previousAction != null)
                            PopupMenuItem(
                              value: 'previous',
                              child: Text(widget.previousLabel),
                            ),
                          if (_nextAction != null)
                            PopupMenuItem(
                              value: 'next',
                              child: Text(widget.nextLabel),
                            ),
                        ],
                        child: const SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(Icons.more_horiz, color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _buildEpisodeLyricTransition(
                    itemId: itemId,
                    child: _lyricRegion(
                      itemId: itemId,
                      subtitles: effectiveSubtitles,
                      secondarySubtitles: effectiveSecondarySubtitles,
                      splitSubtitleByLine: splitSubtitleByLine,
                      preference: lyricDisplayMode,
                      fontScale: _lyricFontSizeScaleLandscape,
                      anchorFraction:
                          _lyricAnchorLandscape == MusicLyricAnchor.automatic
                          ? 0.24
                          : _lyricAnchorLandscape,
                      focusInsets:
                          _lyricAnchorLandscape == MusicLyricAnchor.automatic
                          ? null
                          : const EdgeInsets.symmetric(vertical: 12),
                      horizontalPaddingFraction: 0.04,
                      applyEdgeFade: false,
                      mediaService: mediaService,
                      portraitScroll: false,
                      trackTitle: effectiveTitle,
                      mergeTitle: constraints.maxHeight < 320,
                    ),
                  ),
                ),
                SizedBox(
                  height: 72,
                  child: MusicPlaybackControls(
                    compactLandscape: true,
                    showSkipControls: false,
                    showFontSizeControl: false,
                    volumeController: _volumeController,
                    volumeButtonKey: _volumeButtonKey,
                    onVolumePressed: _toggleVolumePanel,
                    temporarySpeedLabel: _coverSpeedLabel,
                    positionListenable: _displayPosition,
                    progress: _getEffectiveProgress(),
                    totalDuration: effectiveTotalDuration,
                    isPlaying: _isPlaying,
                    isLoading: widget.isLoading,
                    onProgressChanged: widget.followCurrentSession
                        ? _handleProgressChange
                        : null,
                    onProgressChangeStart: widget.followCurrentSession
                        ? _handleProgressChangeStart
                        : null,
                    onProgressChangeEnd: widget.followCurrentSession
                        ? _handleProgressChangeEnd
                        : null,
                    onPlayPause:
                        widget.onPlayPause ??
                        () {
                          if (mediaService.isSourceMissing) return;
                          if (mediaService.isPlaying) {
                            mediaService.pause();
                          } else {
                            mediaService.resume();
                          }
                        },
                  ),
                ),
              ],
            ),
          );
        }
        final selectionLeftFlex = selectionPlan?.leftWidth == null
            ? leftFlex
            : ((selectionPlan!.leftWidth! / availableWidth) * 100)
                  .round()
                  .clamp(1, 90);

        Widget buildCover({double? maxHeight}) => MusicAlbumCover(
          coverImagePath: effectiveCover,
          videoId: mediaService.currentItem?.id,
          title: effectiveTitle,
          artist: effectiveArtist,
          album: widget.album,
          onExitTrigger: _handleExit,
          isAudio: mediaService.currentItem?.type == MediaType.audio,
          isVideo: _coverIsVideo(mediaService),
          videoGestureEnabled:
              _coverIsVideo(mediaService) &&
              musicPlayerUsesCoverVideoGesture(
                Size(availableWidth, constraints.maxHeight),
              ),
          videoController: _coverIsVideo(mediaService)
              ? mediaService.controller
              : null,
          maxVideoWidth: leftPanelInnerWidth,
          debugVideoFramesReady: widget.debugVideoFramesReady,
          debugVideoAspectRatio: widget.debugVideoAspectRatio,
          onTemporarySpeedChanged: _setCoverSpeedLabel,
          coverSize: cdSize,
          maxHeight: maxHeight,
          compactSpacing: isMobileLandscape,
          infoWidth: infoWidth,
        );

        final controls = SizedBox(
          width: controlsWidth,
          child: MusicPlaybackControls(
            compactLandscape: isMobileLandscape,
            bottomIconInset: phoneSpacing?.bottomIconInset,
            temporarySpeedLabel: _coverSpeedLabel,
            positionListenable: _displayPosition,
            progress: _getEffectiveProgress(),
            totalDuration: effectiveTotalDuration,
            isPlaying: _isPlaying,
            isLoading: widget.isLoading,
            onProgressChanged: widget.followCurrentSession
                ? _handleProgressChange
                : null,
            onProgressChangeStart: widget.followCurrentSession
                ? _handleProgressChangeStart
                : null,
            onProgressChangeEnd: widget.followCurrentSession
                ? _handleProgressChangeEnd
                : null,
            onPlayPause:
                widget.onPlayPause ??
                () {
                  if (mediaService.isSourceMissing) {
                    return;
                  }
                  if (mediaService.isPlaying) {
                    mediaService.pause();
                  } else {
                    mediaService.resume();
                  }
                },
            onPrevious: _previousAction,
            onNext: _nextAction,
            previousLabel: widget.previousLabel,
            nextLabel: widget.nextLabel,
            onFontSizeAdjust: _lyricSelectionActive
                ? null
                : _togglePageSettings,
            showFontSizeControl: !_lyricSelectionActive,
            fontSizeButtonKey: _fontSizeButtonKey,
            volumeController: _volumeController,
            volumeButtonKey: _volumeButtonKey,
            onVolumePressed: _toggleVolumePanel,
            onSubtitleManagement:
                !widget.followCurrentSession || mediaService.currentItem == null
                ? null
                : () => showMusicSubtitleManagementDialog(
                    context,
                    artist: effectiveArtist,
                  ),
          ),
        );

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Keep phone transport controls docked; only the artwork/metadata
            // use the remaining height and the short-screen scroll fallback.
            Expanded(
              flex: selectionLeftFlex,
              child: Column(
                key: const ValueKey('music-landscape-left-panel'),
                children: [
                  SizedBox(height: toolsTopInset),
                  Expanded(
                    child: ClipRect(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: leftPanelPadding,
                        ),
                        child: phoneSpacing != null
                            ? Column(
                                children: [
                                  Expanded(
                                    child: LayoutBuilder(
                                      builder: (context, artworkConstraints) =>
                                          Center(
                                            child: SingleChildScrollView(
                                              physics:
                                                  const ClampingScrollPhysics(),
                                              child: buildCover(
                                                maxHeight: artworkConstraints
                                                    .maxHeight,
                                              ),
                                            ),
                                          ),
                                    ),
                                  ),
                                  SizedBox(height: infoToControlsGap),
                                  controls,
                                ],
                              )
                            : Center(
                                child: SingleChildScrollView(
                                  physics: const ClampingScrollPhysics(),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      buildCover(),
                                      SizedBox(height: infoToControlsGap),
                                      controls,
                                    ],
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // === 右侧面板（歌词）：手机横屏稍宽，让歌词更舒展 ===
            Expanded(
              flex: 100 - selectionLeftFlex,
              child: Padding(
                key: const ValueKey('music-landscape-lyric-panel'),
                padding: EdgeInsets.only(
                  left: isMobileLandscape
                      ? (availableWidth * 0.018).clamp(10.0, 16.0)
                      : screenWidth * 0.03,
                  right: _musicLandscapeEdgeInset(
                    Size(availableWidth, constraints.maxHeight),
                  ),
                ),
                child: _buildEpisodeLyricTransition(
                  itemId: itemId,
                  child: _lyricRegion(
                    itemId: itemId,
                    subtitles: effectiveSubtitles,
                    secondarySubtitles: effectiveSecondarySubtitles,
                    splitSubtitleByLine: splitSubtitleByLine,
                    preference: lyricDisplayMode,
                    fontScale: _lyricFontSizeScaleLandscape,
                    anchorFraction:
                        _lyricAnchorLandscape == MusicLyricAnchor.automatic
                        ? MusicLyricAnchor.landscapeDefault
                        : _lyricAnchorLandscape,
                    focusInsets:
                        _lyricAnchorLandscape == MusicLyricAnchor.automatic
                        ? null
                        : const EdgeInsets.symmetric(vertical: 12),
                    horizontalPaddingFraction: 0.05,
                    applyEdgeFade: true,
                    mediaService: mediaService,
                    portraitScroll: false,
                    trackTitle: effectiveTitle,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Only the transcript surface participates in an episode transition.
  /// Keeping the layout builder outside this switcher guarantees that the
  /// cover, metadata, progress bar, and playback buttons never move.
  Widget _buildEpisodeLyricTransition({
    required String itemId,
    required Widget child,
  }) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        // The region owns one selection GlobalKey. Keep only the incoming
        // surface mounted so a track change cannot mount that key twice.
        children: <Widget>[?currentChild],
      ),
      transitionBuilder: (transitionChild, animation) =>
          FadeTransition(opacity: animation, child: transitionChild),
      child: KeyedSubtree(
        key: ValueKey<String>('music-lyric-episode-$itemId'),
        child: child,
      ),
    );
  }

  /// 窄屏竖向布局（< 768px）— Apple Music 手机端风格
  ///
  /// 布局结构（参考竖屏设计文档 .codebuddy/竖屏.md）：
  /// - Header（~11vh）: 专辑缩略图 + 歌曲标题/歌手（紧凑横向排列）+ 关闭按钮
  /// - 中间区域：全高同步歌词 — 与横屏共用同一个 MusicLyricView 组件
  /// - 底部（SafeArea）: 进度条 + 播放控制按钮
  ///
  /// 字体统一使用 Noto Sans SC（中文）/ Inter（英文），符合设计文档要求
  Widget _buildVerticalLayout(
    MediaPlaybackService mediaService,
    String itemId,
    String effectiveTitle,
    String effectiveArtist,
    List<SubtitleItem> effectiveSubtitles,
    List<SubtitleItem> effectiveSecondarySubtitles,
    bool splitSubtitleByLine,
    MusicLyricTrackDisplayMode lyricDisplayMode,
    Size viewport,
  ) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final screenWidth = MediaQuery.sizeOf(context).width;

    final effectiveCover = widget.followCurrentSession
        ? mediaService.currentItem?.thumbnailPath ?? widget.coverImagePath
        : widget.coverImagePath;
    final effectiveTotalDuration =
        widget.followCurrentSession && mediaService.duration > Duration.zero
        ? mediaService.duration
        : widget.totalDuration;

    // Keep artwork, metadata and the lyric boundary stable across track changes.
    final thumbSize =
        (screenWidth * 0.155).clamp(50.0, 64.0) *
        (MediaQuery.textScalerOf(context).scale(17) / 17).clamp(
          1.0,
          double.infinity,
        );
    final metadataHeight = thumbSize;
    const toolbarHeight = 48.0;
    const metadataGap = 8.0;
    // The enclosing SafeArea already reserves the device's top inset.
    const headerTop = 4.0;
    final headerHeight = toolbarHeight + metadataGap + metadataHeight;
    final lyricTop = headerTop + headerHeight + 6;
    final topFeatherEnd = lyricTop + (screenHeight * 0.035).clamp(20.0, 32.0);
    final timeFontSize = (screenHeight * 0.032).clamp(10.0, 13.0);
    final progressBlockHeight =
        25.0 + MediaQuery.textScalerOf(context).scale(timeFontSize) * 1.35;
    final controlsGap = (screenHeight * 0.022).clamp(14.0, 22.0);
    const controlRowHeight = 95.0;
    final controlsBottomPadding = (screenHeight * 0.035).clamp(20.0, 34.0);
    final bottomHiddenStart =
        (viewport.height -
                controlsBottomPadding -
                progressBlockHeight -
                controlsGap -
                controlRowHeight)
            .clamp(topFeatherEnd, viewport.height);
    final bottomFeatherStart =
        (bottomHiddenStart - (screenHeight * 0.10).clamp(70.0, 96.0)).clamp(
          topFeatherEnd,
          bottomHiddenStart,
        );
    // Locate within the fully readable area, using the actual SafeArea height
    // and the scaled metadata height. Keep this anchor stable when controls
    // fade away, so seeking never moves the focus back under the header.
    final focusTop =
        topFeatherEnd +
        (bottomFeatherStart - topFeatherEnd) *
            (_lyricAnchorPortrait == MusicLyricAnchor.automatic
                ? MusicLyricAnchor.portraitDefault
                : _lyricAnchorPortrait);
    final lyricHeight = (viewport.height - lyricTop).clamp(
      1.0,
      double.infinity,
    );
    final focusAnchor = ((focusTop - lyricTop) / lyricHeight).clamp(0.0, 1.0);
    final hasTimedSubtitles =
        effectiveSubtitles.any(_cueHasContent) ||
        effectiveSecondarySubtitles.any(_cueHasContent);

    // 封面解码分辨率需乘设备像素比，否则在 Retina/高分屏上会被放大而模糊
    final int coverCacheSize =
        (thumbSize * MediaQuery.devicePixelRatioOf(context)).toInt();

    // Subtitle taps preserve controls; only a background tap wakes them.
    final lyricView = _buildEpisodeLyricTransition(
      itemId: itemId,
      child: _lyricRegion(
        itemId: itemId,
        subtitles: effectiveSubtitles,
        secondarySubtitles: effectiveSecondarySubtitles,
        splitSubtitleByLine: splitSubtitleByLine,
        preference: lyricDisplayMode,
        fontScale: _lyricFontSizeScalePortrait,
        anchorFraction:
            _lyricAnchorPortrait == MusicLyricAnchor.automatic &&
                (_lyricSelectionActive || widget.detailsPanel != null)
            ? 0.215
            : focusAnchor,
        focusInsets:
            _lyricAnchorPortrait == MusicLyricAnchor.automatic &&
                (_lyricSelectionActive || widget.detailsPanel != null)
            ? null
            : EdgeInsets.only(
                top: topFeatherEnd - lyricTop + 6,
                bottom: viewport.height - bottomFeatherStart + 6,
              ),
        horizontalPaddingFraction: 0.082,
        applyEdgeFade: false,
        mediaService: mediaService,
        portraitScroll: true,
        trackTitle: effectiveTitle,
        mergeTitle: _lyricSelectionActive && screenHeight < 420,
      ),
    );
    final readingPane = widget.detailsPanel == null || _lyricSelectionActive
        ? null
        : Padding(
            padding: EdgeInsets.only(
              left: screenWidth * 0.06,
              right: screenWidth * 0.06,
              top: headerTop + headerHeight + 20,
              bottom: (screenHeight * 0.29).clamp(220.0, 330.0) + 40,
            ),
            child: Column(
              children: [
                Flexible(
                  flex: effectiveSubtitles.isNotEmpty ? 2 : 1,
                  child: widget.detailsPanel!,
                ),
                if (effectiveSubtitles.isNotEmpty)
                  Expanded(flex: 3, child: lyricView),
              ],
            ),
          );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _handlePortraitBackgroundTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 只裁切歌词层：背景、封面、标题与播放控件完全不参与遮罩。
          // 顶部在标题栏下方才羽化显现；底部在进度条上方开始羽化消失，
          // 到达进度条时已经完全透明，并随控件显隐动画恢复。
          if (_lyricSelectionActive)
            Padding(
              padding: EdgeInsets.only(top: headerTop + headerHeight),
              child: Column(
                children: [
                  // Give the selection every pixel above the actual controls,
                  // including space reserved by the normal lyric fade.
                  Expanded(child: lyricView),
                  _buildVerticalControls(
                    mediaService,
                    effectiveTotalDuration,
                    overlay: false,
                  ),
                ],
              ),
            )
          else if (readingPane != null)
            readingPane
          else if (!hasTimedSubtitles && widget.transcriptFallback != null)
            Positioned.fill(
              top: screenHeight * 0.014 + headerHeight + 16,
              bottom: (screenHeight * 0.29).clamp(220.0, 330.0) + 40,
              child: widget.transcriptFallback!,
            )
          else
            AnimatedBuilder(
              key: const ValueKey('music-portrait-lyric-mask'),
              animation: _controlsAnimationController,
              child: Padding(
                padding: EdgeInsets.only(top: lyricTop),
                child: RepaintBoundary(child: lyricView),
              ),
              builder: (context, child) {
                final controlsMaskProgress = musicControlsLyricMaskProgress(
                  _controlsAnimationController.value,
                );
                return ShaderMask(
                  key: const ValueKey('music-portrait-lyric-visibility-mask'),
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) {
                    final height = bounds.height;
                    final bottomAlpha = ((1.0 - controlsMaskProgress) * 255)
                        .round();

                    double stop(double value) =>
                        (value / height).clamp(0.0, 1.0);

                    return LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        const Color(0x00FFFFFF),
                        const Color(0x00FFFFFF),
                        const Color(0xFFFFFFFF),
                        const Color(0xFFFFFFFF),
                        Color.fromARGB(bottomAlpha, 255, 255, 255),
                        Color.fromARGB(bottomAlpha, 255, 255, 255),
                      ],
                      stops: [
                        0.0,
                        stop(lyricTop),
                        stop(topFeatherEnd),
                        stop(bottomFeatherStart),
                        stop(bottomHiddenStart),
                        1.0,
                      ],
                    ).createShader(bounds);
                  },
                  child: child,
                );
              },
            ),

          // 顶部元数据保持原有背景；经过其后的歌词由上面的 alpha mask 隐藏。
          Positioned(
            left: screenWidth * 0.06,
            right: screenWidth * 0.06,
            top: headerTop,
            child: SizedBox(
              key: const ValueKey('music-portrait-header'),
              height: headerHeight,
              child: Column(
                children: [
                  IconButtonTheme(
                    data: IconButtonThemeData(
                      style: IconButton.styleFrom(
                        foregroundColor: const Color(0xD9FFFFFF),
                        backgroundColor: Colors.transparent,
                        side: BorderSide.none,
                        shape: const CircleBorder(),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const Size.square(44),
                        maximumSize: const Size.square(44),
                        padding: const EdgeInsets.all(12),
                      ),
                    ),
                    child: SizedBox(
                      height: toolbarHeight,
                      child: Row(
                        key: widget.landscapeToolbarKey,
                        children: [
                          _MusicPortraitToolGroup(
                            inset: 0,
                            children: [
                              DesktopButtonClickRegion(
                                child: IconButton(
                                  key: const ValueKey('music-toolbar-close'),
                                  tooltip: '关闭',
                                  onPressed: _handleExit,
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          _MusicPortraitToolGroup(
                            key: const ValueKey('music-portrait-tools'),
                            children: [
                              ?widget.detailsAction,
                              _buildEpisodePickerButton(),
                              const _MusicSleepTimerButton(),
                              _buildAiChatButton(),
                              widget.headerAction ?? _buildPortraitMoreButton(),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: metadataGap),
                  SizedBox(
                    key: const ValueKey('music-portrait-metadata'),
                    height: metadataHeight,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(14),
                          child: SizedBox.square(
                            dimension: thumbSize,
                            child:
                                effectiveCover != null &&
                                    effectiveCover.isNotEmpty
                                ? CachedThumbnailWidget(
                                    videoId: mediaService.currentItem?.id ?? '',
                                    thumbnailPath: effectiveCover,
                                    fit: BoxFit.cover,
                                    cacheWidth: coverCacheSize,
                                    cacheHeight: coverCacheSize,
                                  )
                                : ColoredBox(
                                    color: Colors.white12,
                                    child: Icon(
                                      widget.detailsAction != null
                                          ? Icons.podcasts_rounded
                                          : Icons.music_note_rounded,
                                      size: 24,
                                      color: Colors.white38,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _MusicPortraitMetadata(
                            title: effectiveTitle,
                            artist: effectiveArtist,
                            extent: thumbSize,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 底部控件浮层只承载控件，不再修改背景。
          if (!_lyricSelectionActive)
            _buildVerticalControls(mediaService, effectiveTotalDuration),
        ],
      ),
    );
  }

  /// Portrait controls keep their bottom alignment in both lyric modes.
  ///
  /// Normal lyrics run behind the overlay. Selection uses the controls' natural
  /// height in a column so text can extend to the progress bar without overlap.
  Widget _buildVerticalControls(
    MediaPlaybackService mediaService,
    Duration effectiveTotalDuration, {
    bool overlay = true,
  }) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final screenWidth = MediaQuery.sizeOf(context).width;

    // 只覆盖进度条与按钮所需的播放区；底部对齐不变，因此不会移动控件。
    final overlayHeight = (screenHeight * 0.29).clamp(220.0, 330.0) + 40;
    final controlsBottomPadding = (screenHeight * 0.035).clamp(20.0, 34.0);

    final controls = IgnorePointer(
      ignoring: !_verticalControlsVisible,
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: _controlsAnimationController,
          curve: const Interval(0.18, 1.0, curve: Curves.easeOutCubic),
        ),
        child: SlideTransition(
          position: _controlsSlideAnimation,
          child: Padding(
            padding: EdgeInsets.only(
              left: screenWidth * 0.082,
              right: screenWidth * 0.082,
              bottom: controlsBottomPadding,
            ),
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: 1,
              child: RepaintBoundary(
                child: MusicPlaybackControls(
                  temporarySpeedLabel: _coverSpeedLabel,
                  subtitleManagementKey: const ValueKey(
                    'music-portrait-subtitle-management',
                  ),
                  onSubtitleManagement:
                      !widget.followCurrentSession ||
                          mediaService.currentItem == null
                      ? null
                      : () {
                          _onUserInteraction();
                          showMusicSubtitleManagementDialog(
                            context,
                            artist: widget.artist,
                          );
                        },
                  positionListenable: _displayPosition,
                  progress: _getEffectiveProgress(),
                  totalDuration: effectiveTotalDuration,
                  isPlaying: _isPlaying,
                  isLoading: widget.isLoading,
                  previousLabel: widget.previousLabel,
                  nextLabel: widget.nextLabel,
                  onProgressChanged: widget.followCurrentSession
                      ? _handleProgressChange
                      : null,
                  onProgressChangeStart: widget.followCurrentSession
                      ? _handleProgressChangeStart
                      : null,
                  onProgressChangeEnd: widget.followCurrentSession
                      ? _handleProgressChangeEnd
                      : null,
                  onPlayPause: () {
                    _onUserInteraction();
                    if (widget.followCurrentSession &&
                        mediaService.isSourceMissing) {
                      return;
                    }
                    if (widget.onPlayPause != null) {
                      widget.onPlayPause!.call();
                    } else {
                      if (mediaService.isPlaying) {
                        mediaService.pause();
                      } else {
                        mediaService.resume();
                      }
                    }
                  },
                  onPrevious: _previousAction == null
                      ? null
                      : () {
                          _onUserInteraction();
                          _previousAction?.call();
                        },
                  onNext: _nextAction == null
                      ? null
                      : () {
                          _onUserInteraction();
                          _nextAction?.call();
                        },
                  onFontSizeAdjust: _lyricSelectionActive
                      ? null
                      : _togglePageSettings,
                  showFontSizeControl: !_lyricSelectionActive,
                  fontSizeButtonKey: _fontSizeButtonKey,
                  volumeController: _volumeController,
                  volumeButtonKey: _volumeButtonKey,
                  onVolumePressed: _toggleVolumePanel,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!overlay) return controls;
    return Positioned(
      key: const ValueKey('music-portrait-controls-overlay'),
      left: 0,
      right: 0,
      bottom: 0,
      height: overlayHeight,
      child: controls,
    );
  }
}

/// Align visible glyphs, rather than the padded typographic line boxes.
/// The optical envelope is calibrated for the bundled Noto Sans SC font.
class _MusicPortraitMetadata extends StatelessWidget {
  const _MusicPortraitMetadata({
    required this.title,
    required this.artist,
    required this.extent,
  });

  final String title;
  final String artist;
  final double extent;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        TextPainter measure(String text, TextStyle style, int lines) =>
            TextPainter(
              text: TextSpan(text: text, style: style),
              textScaler: scaler,
              textDirection: direction,
              maxLines: lines,
              ellipsis: '…',
            )..layout(maxWidth: constraints.maxWidth);

        final titleFontSize = artist.isEmpty ? 24.0 : 17.0;
        var titleStyle = TextStyle(
          fontFamily: 'Noto Sans SC',
          leadingDistribution: TextLeadingDistribution.even,
          fontWeight: FontWeight.w600,
          fontSize: titleFontSize,
          height: 1.4,
          color: Colors.white,
        );
        const artistStyle = TextStyle(
          fontFamily: 'Noto Sans SC',
          leadingDistribution: TextLeadingDistribution.even,
          fontWeight: FontWeight.w500,
          fontSize: 13,
          height: 1.4,
          color: Colors.white60,
        );
        var titlePainter = measure(title, titleStyle, 2);
        var lines = titlePainter.computeLineMetrics();
        final titleInkHeight = scaler.scale(titleFontSize) * 0.90;
        if (artist.isEmpty && lines.length > 1) {
          // Spread the two baselines so the first/last visible edges meet the
          // fixed artwork. A single line keeps the same optical top edge.
          titleStyle = titleStyle.copyWith(
            height: (extent - titleInkHeight) / scaler.scale(titleFontSize),
          );
          titlePainter.dispose();
          titlePainter = measure(title, titleStyle, 2);
          lines = titlePainter.computeLineMetrics();
        }
        final titleTop =
            scaler.scale(titleFontSize) * 0.82 - lines.first.baseline;
        titlePainter.dispose();
        double artistTop = 0;
        if (artist.isNotEmpty) {
          final painter = measure(artist, artistStyle, 1);
          artistTop =
              extent -
              painter.computeLineMetrics().first.baseline -
              scaler.scale(13) * 0.08;
          painter.dispose();
        }
        return SizedBox(
          height: extent,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: titleTop,
                child: Text(
                  title,
                  key: const ValueKey('music-portrait-title'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              if (artist.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  top: artistTop,
                  child: Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: artistStyle,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Separate surfaces keep each action at its full touch target size.
class _MusicPortraitToolGroup extends StatelessWidget {
  const _MusicPortraitToolGroup({
    super.key,
    required this.children,
    this.inset = 2,
  });

  final List<Widget> children;
  final double inset;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0x0FFFFFFF),
    shape: const StadiumBorder(side: BorderSide(color: Color(0x12FFFFFF))),
    clipBehavior: Clip.antiAlias,
    child: Padding(
      padding: EdgeInsets.all(inset),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final child in children)
            SizedBox.square(dimension: 44, child: child),
        ],
      ),
    ),
  );
}

class _MusicSleepTimerButton extends StatelessWidget {
  const _MusicSleepTimerButton();

  @override
  Widget build(BuildContext context) {
    final playback = context.read<MediaPlaybackService>();
    return AnimatedBuilder(
      animation: playback.sleepTimer,
      builder: (context, _) {
        final timer = playback.sleepTimer;
        final tooltip = DesktopPlayerShortcuts.buildTooltip(
          timer.isActive ? timer.statusText : '定时关闭',
          DesktopPlayerShortcutAction.openSleepTimer,
          context: context,
        );
        return DesktopButtonClickRegion(
          child: IconButton(
            tooltip: tooltip,
            onPressed: () => unawaited(showSleepTimerDialog(context)),
            icon: Icon(
              timer.isActive ? Icons.alarm_on_rounded : Icons.schedule_rounded,
              size: 20,
              color: timer.isActive ? Colors.blueAccent : null,
            ),
            iconSize: 20,
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          ),
        );
      },
    );
  }
}

class _MusicBackdropArtwork extends StatefulWidget {
  final String coverPath;
  final VoidCallback? onImageReady;

  const _MusicBackdropArtwork({required this.coverPath, this.onImageReady});

  @override
  State<_MusicBackdropArtwork> createState() => _MusicBackdropArtworkState();
}

class _MusicBackdropArtworkState extends State<_MusicBackdropArtwork> {
  Uint8List? _blurredBytes;
  int _requestId = 0;
  bool _readyReported = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _MusicBackdropArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverPath != widget.coverPath) _load();
  }

  void _load() {
    _readyReported = false;
    final requestId = ++_requestId;
    final cached = MusicArtworkBackdropCache.instance.peek(widget.coverPath);
    if (cached != null) {
      _blurredBytes = cached;
      return;
    }
    _blurredBytes = null;
    MusicArtworkBackdropCache.instance.warm(widget.coverPath).then((bytes) {
      if (!mounted || requestId != _requestId || bytes == null) return;
      setState(() => _blurredBytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _blurredBytes;
    return SizedBox.expand(
      child: Transform.scale(
        scale: 1.28,
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            1.14,
            -0.05,
            -0.05,
            0,
            0,
            -0.05,
            1.12,
            -0.05,
            0,
            0,
            -0.05,
            -0.05,
            1.14,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 360),
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[...previousChildren, ?currentChild],
              );
            },
            child: bytes != null
                ? Image.memory(
                    bytes,
                    frameBuilder: (context, child, frame, synchronous) {
                      if (frame != null && !_readyReported) {
                        _readyReported = true;
                        final requestId = _requestId;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && requestId == _requestId) {
                            widget.onImageReady?.call();
                          }
                        });
                      }
                      return synchronous
                          ? child
                          : AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : const Duration(milliseconds: 360),
                              child: child,
                            );
                    },
                    key: ValueKey<String>(
                      'music-backdrop-memory-${widget.coverPath}',
                    ),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.low,
                  )
                : SizedBox.expand(
                    key: ValueKey<String>(
                      'music-backdrop-fallback-${widget.coverPath}',
                    ),
                    // Keep the base gradient while the isolate prepares the
                    // blurred bitmap. A live full-screen blur here defeats
                    // that cache and stalls cold page transitions.
                  ),
          ),
        ),
      ),
    );
  }
}

/// 低频数据快照 — Selector 选中值，仅当这些字段变化时才重建 MusicPlayerScreen。
///
/// 关键：快照**不含 position**。position 由 positionNotifier 逐帧驱动（经
/// _displayPosition → 进度条 ValueListenableBuilder），无需 build 刷新。
/// 因此 300ms 定时器的 notifyListeners（仅 position 变化）不会触发 builder，
/// 从根本上消除每 300ms 的全屏重建。
///
/// Ordinary tracks use immutable list identity. Streaming snapshots share a
/// generation identity: appending refreshes the nested lyric selector, while
/// first text, track replacement and metadata changes refresh the page layout.
class _PlayerSnapshot {
  final String itemId;
  final String? cover;
  final String title;
  final Duration duration;
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles;
  final bool isPlaying;
  final bool isSourceMissing;
  final bool hasLyricText;

  const _PlayerSnapshot({
    required this.itemId,
    required this.cover,
    required this.title,
    required this.duration,
    required this.subtitles,
    required this.secondarySubtitles,
    required this.isPlaying,
    required this.isSourceMissing,
    required this.hasLyricText,
  });

  static Object _layoutSource(List<SubtitleItem> cues) => cues.isEmpty
      ? const <SubtitleItem>[]
      : cues is SubtitleCueSnapshot
      ? cues.sourceIdentity
      : cues;

  static bool _sameLayoutSource(List<SubtitleItem> a, List<SubtitleItem> b) =>
      identical(_layoutSource(a), _layoutSource(b)) && a.isEmpty == b.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _PlayerSnapshot &&
          itemId == other.itemId &&
          cover == other.cover &&
          title == other.title &&
          duration == other.duration &&
          _sameLayoutSource(subtitles, other.subtitles) &&
          _sameLayoutSource(secondarySubtitles, other.secondarySubtitles) &&
          hasLyricText == other.hasLyricText &&
          isPlaying == other.isPlaying &&
          isSourceMissing == other.isSourceMissing;

  @override
  int get hashCode => Object.hash(
    itemId,
    cover,
    title,
    duration,
    _layoutSource(subtitles),
    subtitles.isEmpty,
    _layoutSource(secondarySubtitles),
    secondarySubtitles.isEmpty,
    hasLyricText,
    isPlaying,
    isSourceMissing,
  );
}
