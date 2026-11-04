import 'transcript_scroll_selection_delegate.dart';
import '../models/subtitle_stream.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/media_playback_service.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'transcript_cue_window.dart';
import 'package:video_player/video_player.dart';
import '../services/app_haptics.dart';
import '../theme/app_tokens.dart';
import '../services/settings_service.dart';
import '../services/subtitle_timeline_resolver.dart';
import '../models/subtitle_copy_format.dart';
import '../models/subtitle_model.dart';
import '../utils/subtitle_copy_formatter.dart';
import '../utils/subtitle_display_resolver.dart';
import '../utils/desktop_player_shortcuts.dart';
import '../utils/page_shortcut_keys.dart';
import '../utils/ui_interaction_budget.dart';
import 'subtitle_copy_format_popover.dart';
import 'subtitle_toolbar.dart';
import 'subtitle_generation_footer.dart';
import 'transcript_viewport_motion.dart';
import 'transcript_scroll_motion.dart';
import 'transcript_text_cache.dart';
import 'subtitle_active_range_builder.dart';
import 'panel_swipe_region.dart';
import '../features/subtitle_article/article_document.dart';
import '../features/subtitle_article/article_layout_engine.dart';
import '../features/subtitle_article/article_layout_model.dart';
import '../features/subtitle_article/continuous_article_view.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class SubtitleSidebar extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles; // New
  /// The player is intentionally optional: subtitle text and settings remain
  /// usable while the native media backend is still creating its controller.
  final VideoPlayerController? controller;

  /// A controller-independent playback clock. Playback pages pass the global
  /// media clock so the sidebar can keep its position across controller swaps.
  final ValueListenable<Duration>? positionListenable;
  final ValueChanged<Duration>? onItemTap;
  final ValueChanged<bool>? onViewportReadyChanged;
  final VoidCallback? onClose;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onLoadSubtitle;
  final VoidCallback? onOpenSubtitleStyle;
  final VoidCallback? onOpenSubtitleManager;
  final VoidCallback? onClearSelection;
  final VoidCallback? onOpenEpisodePicker;
  final VoidCallback? onOpenVideoCompose;
  final VoidCallback? onOpenOcrSubtitle;
  final String? ocrUnavailableReason;
  final VoidCallback? onOpenAiChat;
  final VoidCallback? onOpenSubtitleEditor;
  final bool isCompact;
  final bool isPortrait;

  /// 与画面字幕一致：音频/视频各自使用独立的「连续字幕」设置。
  final bool isAudio;
  final FocusNode? focusNode; // New
  final bool isVisible;

  /// Shared subtitle/chat navigation keeps the reading location when automatic
  /// following is off. When following is on, return to the current subtitle.
  final bool preserveReadingPositionWhenNotFollowing;
  final bool showEmbeddedLoadingMessage;

  const SubtitleSidebar({
    super.key,
    required this.subtitles,
    this.secondarySubtitles = const [], // Default empty
    this.controller,
    this.positionListenable,
    this.onItemTap,
    this.onViewportReadyChanged,
    this.onClose,
    this.onOpenSettings,
    this.onLoadSubtitle,
    this.onOpenSubtitleStyle,
    this.onOpenSubtitleManager,
    this.onClearSelection,
    this.onOpenEpisodePicker,
    this.onOpenVideoCompose,
    this.onOpenOcrSubtitle,
    this.ocrUnavailableReason,
    this.onOpenAiChat,
    this.onOpenSubtitleEditor,
    this.isCompact = false,
    this.isPortrait = false,
    this.isAudio = false,
    this.focusNode,
    this.isVisible = true,
    this.preserveReadingPositionWhenNotFollowing = false,
    this.showEmbeddedLoadingMessage = false,
  });

  @override
  State<SubtitleSidebar> createState() => SubtitleSidebarState();
}

class SubtitleSidebarState extends State<SubtitleSidebar> {
  bool _isArticleMode = false; // 默认为列表模式
  int _lineFilterMode = 0; // 0: 全部, 1: 第一行, 2: 第二行
  // bool _isAutoScroll = false; // Moved to SettingsService
  double _fontSizeScale = 1.0; // 字体缩放比例
  bool _showFontSettings = false; // 是否显示字体设置
  bool _showTimestamps = true;
  double _timeColumnRatio = 0.18;
  int _locatePositionPercent = 30;
  bool? _listFitsViewport;
  bool? _paragraphFitsViewport;
  Object? _paragraphFitKey;
  bool? _paragraphFitResult;
  int _paragraphFitCount = 0;
  double _generationFooterHeight = 0;

  /// 最近一次「点击字幕后滚到该句」的目标索引；关闭自动跟随时为 null。
  @visibleForTesting
  int? lastTappedLocateScrollIndex;

  // 滚动控制器
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  ItemPosition? _savedReadingPosition;
  final ScrollOffsetController _listScrollOffsetController =
      ScrollOffsetController();
  final ScrollOffsetController _articleScrollOffsetController =
      ScrollOffsetController();
  final GlobalKey<SelectionAreaState> _textSelectionKey =
      GlobalKey<SelectionAreaState>();
  final FocusNode _textSelectionFocusNode = FocusNode(
    debugLabel: 'SubtitleSidebarTextSelection',
  );
  bool _hasTextSelection = false;
  bool _pendingTrackAlignmentRefresh = false;
  ({int index, int textOffset, double alignment, int request})?
  _translationAnchor;
  String _selectedTranscriptText = '';

  /// True after Ctrl/Cmd+A or the menu's Select all. Flutter's selectAll only
  /// covers currently mounted virtualized rows; copy/format then uses the
  /// canonical cache instead of that partial `plainText`.
  bool _fullTranscriptSelected = false;
  Timer? _touchSelectionEdgeScrollTimer;
  int? _touchSelectionEdgePointer;
  bool _selectionViewportCorrectionInFlight = false;
  ScrollableState? _selectionScrollable;
  OverlayEntry? _persistentSelectionToolbarEntry;
  bool _persistentSelectionToolbarInsertScheduled = false;
  bool _usesPersistentTouchSelectionToolbar = false;
  Offset? _persistentSelectionToolbarAnchor;
  TextSelectionToolbarAnchors? _persistentSelectionToolbarAnchors;
  OverlayEntry? _desktopSelectionToolbarEntry;
  Offset? _desktopSelectionToolbarAnchor;
  OverlayEntry? _copyFormatPopoverEntry;
  Offset? _selectionShieldTapDownPosition;
  Drag? _selectionPreservingPanDrag;

  // Flutter's tap recognizer intentionally allows normal finger jitter. That
  // tolerance is too generous for a destructive "dismiss selection" action:
  // the first few pixels of an intended scroll could otherwise count as a
  // tap. Keep dismissal much stricter than kTouchSlop.
  static const double _selectionDismissTapSlop = 3;

  /// Signed pixel delta for edge auto-scroll: negative toward the start.
  double _touchSelectionEdgeScrollPixels = 0;
  int _touchSelectionEdgeTickCount = 0;

  /// Pointer currently extending the selection, either the initial long-press
  /// or a later gesture that has been confirmed by the selection-status scope.
  final _scrollSelectionDelegate = TranscriptScrollSelectionDelegate();
  int? _selectionGesturePointer;
  bool _selectionGestureUsesHandle = false;
  int? _latestDownTouchPointer;
  final Set<int> _downTouchPointers = <int>{};
  final Map<int, Offset> _downTouchPointerPositions = <int, Offset>{};
  bool _selectionHandleBindCheckScheduled = false;
  SelectableRegionSelectionStatus _selectionRegionStatus =
      SelectableRegionSelectionStatus.finalized;

  /// Enter/exit hysteresis keeps a jittering finger from flipping between
  /// "hold still" and "edge scroll" on every move.
  // Start before the finger reaches the physical screen edge. On gesture-nav
  // Android devices the last few pixels may belong to the system, so requiring
  // the handle to cross the viewport boundary makes downward scrolling either
  // very slow or impossible.
  static const double _touchSelectionEdgeEnterZone = 56;

  // Hysteresis is deliberately wider than the entry band: once scrolling has
  // started, small finger movements must not repeatedly stop/restart it.
  static const double _touchSelectionEdgeExitZone = 72;
  static const Duration _touchSelectionEdgeScrollInterval = Duration(
    milliseconds: 16,
  );
  static const double _touchSelectionMinPixelsPerTick = 2;
  static const double _touchSelectionMaxPixelsPerTick = 6.5;
  static const int _touchSelectionAccelerationDelayTicks = 8;
  static const int _touchSelectionAccelerationTicks = 64;

  // 自动滚动相关
  // 定位索引在字幕空档仍有落点；句间高亮保留到下一句开始。
  final ValueNotifier<int> _activeIndexNotifier = ValueNotifier<int>(-1);
  final ValueNotifier<List<int>> _activeIndicesNotifier =
      ValueNotifier<List<int>>(<int>[]);
  SubtitleTimelineResolver? _timelineResolver;
  final _readingCueWindow = TranscriptCueWindow();
  List<SubtitleItem> _timelineResolverSubtitles = const <SubtitleItem>[];
  Timer? _autoScrollTimer;
  int _activePointerCount = 0;
  bool _pointerSessionStartedWithTextSelection = false;
  bool _didScrollWhilePointerSession = false;
  int? _pointerDownStartIndex;
  int? _pointerDownSubtitleIndex;

  // ===== 拖拽会话中的「副指针双击跳转」=====
  // 背景：手指按住不放时自动跟随被抑制，用户可以一边按住一边翻阅上下文。
  // 本机制允许在这个状态下用另一根手指在某句字幕上快速点两下，立刻把媒体
  // seek 到该句，但不滚动文稿；文稿的定位统一推迟到所有手指抬起之后。
  //
  // 误判防线（缺一不可，详见 [_evaluateDragDoubleTap]）：
  //   1. 只认触摸设备，鼠标/触控笔走各自既有交互；
  //   2. 只认落在字幕列表区的指针，顶部工具栏按钮不参与，也不能充当锚点；
  //   3. 按下瞬间列表区必须已有其他手指按住，单指点击一律走原有逻辑；
  //   4. 两次轻点必须共享同一根「一直没抬起」的锚定手指，杜绝「全松手后
  //      换手再点」被误拼成双击；
  //   5. 两次轻点必须都是干净轻点（位移 < slop 且时长 < 300ms）、命中同一行、
  //      落点接近、间隔 <= 300ms。
  /// 当前按在侧边栏内的每根手指的按下快照，key 为 pointer id。
  final Map<int, _SidebarPointerRecord> _pointerRecords =
      <int, _SidebarPointerRecord>{};

  /// 落点位于字幕列表区（而非顶部工具栏）的指针 id。
  final Set<int> _listAreaPointerIds = <int>{};

  /// 列表区 [Listener] 在指针按下瞬间解析出的「pointer id → 字幕行号」。
  ///
  /// 行号只能靠几何反查，不能依赖列表内部的任何回调：
  ///   - onTapDown 不行。列表已经在滚动时，Scrollable 的 [DragGestureRecognizer]
  ///     会在新手指按下的瞬间直接赢下该指针的手势竞技场，行上的
  ///     TapGestureRecognizer 被判负，onTapDown 根本不会触发。
  ///   - 行级 Listener 也不行。拖拽期间 Scrollable 会把整个视口包进
  ///     `IgnorePointer`（`DragScrollActivity.shouldIgnorePointer == true`），
  ///     视口内部收不到任何指针事件。
  /// 而「拖着不松手」恰恰就是这两种屏蔽同时生效的状态，所以只能在视口外面，
  /// 用 [ItemPositionsListener] 的几何信息自己算落点落在哪一行。
  final Map<int, int> _pendingRowIndexByPointer = <int, int>{};

  /// 指向当前挂载的 [ScrollablePositionedList]，用于把全局坐标换算成视口比例。
  final GlobalKey _listViewportKey = GlobalKey();

  /// 文章模式下每个段落的 key，用于把落点进一步定位到段落内的具体某一句。
  final Map<int, GlobalKey<State<SubtitleArticleChunk>>> _articleChunkKeys =
      <int, GlobalKey<State<SubtitleArticleChunk>>>{};
  final GlobalKey<ContinuousArticleViewState> _continuousArticleViewKey =
      GlobalKey<ContinuousArticleViewState>();
  final _viewportMotionKey = GlobalKey<TranscriptViewportMotionState>();
  int _readingMotionRequestId = 0;
  ScrollPosition? _animatedReadingPosition;
  _TranscriptScrollActivity? _readingScrollActivity;
  int? _animatedReadingItem;
  double? _animatedReadingAlignment;
  bool _readingViewportReady = true;
  int _readingRevealRequestId = 0;
  bool _readingRevealScheduled = false;
  MediaQueryData? _lastVisibleReadingEnvironment;
  bool _viewportReadyNotificationScheduled = false;
  bool? _publishedViewportReady;
  VoidCallback? _releaseReadingInteraction;
  bool _distantReadingMotionActive = false;
  bool _readingDisposed = false;
  ScrollPosition? _readingInteractionPosition;

  void _updateReadingInteraction() {
    if (!_readingDisposed) {
      final position = _selectionScrollable?.position;
      if (!identical(position, _readingInteractionPosition)) {
        _readingInteractionPosition?.isScrollingNotifier.removeListener(
          _updateReadingInteraction,
        );
        _readingInteractionPosition = position;
        position?.isScrollingNotifier.addListener(_updateReadingInteraction);
      }
    }
    final active =
        !_readingDisposed &&
        mounted &&
        widget.isVisible &&
        _isSubtitleSidebarRouteCurrent &&
        (_hasAnyActivePointer ||
            (_selectionScrollable?.position.isScrollingNotifier.value ??
                false) ||
            _distantReadingMotionActive);
    if (active) {
      _releaseReadingInteraction ??= UiInteractionBudget.instance.acquire();
    } else {
      _releaseReadingInteraction?.call();
      _releaseReadingInteraction = null;
    }
  }

  void _handleDistantMotionActivity(bool active) {
    _distantReadingMotionActive = active;
    _updateReadingInteraction();
  }

  /// 等待凑成双击的候选轻点；超时/换会话即作废。
  _SidebarTapRecord? _pendingDragDoubleTap;

  /// 最近一根抬起的副指针记录，只存活到下一个指针事件为止。
  ///
  /// 快速轻点时手势竞技场要等抬起事件派发完才裁决，也就是说 onTap
  /// 会晚于 [_onPointerUpOrCancel]；留着这条记录，才能在那一刻认出
  /// 「这次点击已经被双击识别器接管了」。
  _SidebarPointerRecord? _recentlyLiftedSecondaryTap;

  /// 最近一次指针抬起的快照，供 [_isConfirmedSubtitleClick] 在 onTap
  /// 里核对「这是不是一次短单击」。
  ///
  /// Listener 先于手势竞技场收到 PointerUp，所以 onTap 触发时这里一定
  /// 已经写好。下一根手指按下时清空，避免串到下一次点击。
  _SidebarPointerRecord? _lastLiftedPointer;
  int _lastLiftedHeldMs = 0;

  /// 已被双击识别接管、因而必须屏蔽常规 onTap 落地的字幕行号。
  int? _suppressedRowTapIndex;

  /// 本次按压会话内是否发生过双击 seek；决定松手后是否强制补一次定位。
  bool _didDoubleTapSeekWhilePointerSession = false;

  /// 单次轻点允许的最长按住时长；超过即视为长按/拖拽，不参与双击。
  static const int _dragTapMaxDurationMs = 300;

  /// 常规「点某一句就跳转」允许的最长按住时长。
  ///
  /// 对齐 [kLongPressTimeout]：超过它就应当进入选字/长按语义，而不是单击。
  /// 比 [_dragTapMaxDurationMs] 更宽，避免把略慢的单击误杀掉。
  static const int _rowTapMaxDurationMs = 500;

  /// 两次轻点之间允许的最大间隔（第一次抬起 → 第二次按下），对齐
  /// Flutter 的 [kDoubleTapTimeout]。
  static const int _dragDoubleTapIntervalMs = 300;

  /// 单次轻点允许的最大位移，超过即认为手指在滑动而不是点击。
  static const double _dragTapMaxTravel = kDoubleTapTouchSlop;

  /// 两次轻点落点之间允许的最大距离，用于确认「是同一根手指点的」。
  /// 比 [kDoubleTapSlop] 更严，配合「同一行」判定进一步压低误判率。
  static const double _dragDoubleTapSlop = 72.0;
  int? _pendingLocateIndex;
  bool _lastKnownIsPlaying = false;
  int _lastSubtitleOffsetMs = 0;
  int? _suppressAutoScrollTargetIndex;
  int _suppressAutoScrollUntilMs = 0;
  int? _manualLocateLockIndex;
  List<int> _manualLocateActiveIndices = const <int>[];
  int _manualLocateLockUntilMs = 0;
  int _autoScrollRequestId = 0;
  int _manualLocateAutoFollowCooldownUntilMs = 0;
  Timer? _manualLocateAutoFollowCooldownTimer;
  bool _autoFollowDeferred = false;
  int? _manualAnimationFreezeIndex;
  int _manualAnimationFreezeUntilMs = 0;
  Size? _lastScrollableViewportSize;
  bool _viewportAlignmentRestoreScheduled = false;

  // 统一定位流水线。
  // 「切页后的修复定位」与「自动跟随」是两套独立触发源：过去它们各自投递
  // post-frame 任务、各自重试，于是出现两类竞争：
  //   1. 后发起的修复请求会被更早发起、但仍在重试中的旧请求覆盖落点；
  //   2. 自动跟随的动画（含远距离两段式滚动）晚于修复跳转落地，把文稿又拖
  //      回旧位置；被横屏页覆盖时动画还会被静音挂起，回到前台集中补帧。
  // 下面用单调递增的请求号把它们串成一条流水线：只有最新请求能落地，旧请求
  // 的延迟回调全部作废；修复请求必须等列表真正有布局才会执行，失败会保留
  // 请求并由视口变化/回到前台重新驱动，落地后还会校验一次列表是否真的可见。
  int _locateRequestId = 0;
  int _locateAttempts = 0;
  bool _locateAnimated = false;
  bool _locateIsRepair = false;
  bool _repairRequestPending = false;
  bool _locateVerificationScheduled = false;
  int _locateVerificationRounds = 0;

  // 侧边栏所在路由是否位于前台。被横屏播放页/音乐播放页覆盖时，列表既不
  // 布局也不走帧，此期间启动的滚动动画会和切页修复定位抢同一个落点。
  bool _isHostRouteCurrent = true;
  bool _visualTicksEnabled = true;
  bool _routeRestorePending = false;

  static const int _maxLocateAttempts = 30;
  static const int _maxLocateVerificationRounds = 3;
  static const double _collapsedViewportHeight = 4.0;

  VideoPlayerValue? get _controllerValue => widget.controller?.value;

  /// 与悬浮字幕和音乐页使用同一帧播放位置，避免等到下一次 native 上报
  /// 才切换高亮。只接受当前 controller 对应的 service 时钟；独立预览或
  /// 其他来源的 positionListenable 不能覆盖播放器位置。
  Duration get _subtitleTimingPosition {
    final controller = widget.controller;
    if (controller != null && controller.value.isInitialized) {
      final service = Provider.of<MediaPlaybackService?>(
        context,
        listen: false,
      );
      if (service != null &&
          identical(service.controller, controller) &&
          identical(service.positionNotifier, widget.positionListenable)) {
        return service.positionForSubtitleOverlay(controller.value.position);
      }
      return controller.value.position;
    }
    return widget.positionListenable?.value ?? Duration.zero;
  }

  /// 字幕延迟（subtitleOffset）：正值表示字幕整体延后出现。
  int get _subtitleOffsetMs => SettingsService().subtitleOffset.inMilliseconds;

  /// 画面字幕用「播放位置 - subtitleOffset」判定当前句，侧边栏的高亮与
  /// 定位必须换算到同一条字幕时间轴，否则调整「字幕同步」后两侧会整体
  /// 错开（offset > 0 时高亮比画面字幕提前）。
  int get _subtitleTimelinePositionMs =>
      _subtitleTimingPosition.inMilliseconds - _subtitleOffsetMs;

  bool get _playbackIsPlaying => _controllerValue?.isPlaying ?? false;

  void _attachPlaybackListeners() {
    widget.controller?.addListener(_updateIndex);
    widget.positionListenable?.addListener(_updateIndex);
  }

  void _detachPlaybackListeners(SubtitleSidebar source) {
    source.controller?.removeListener(_updateIndex);
    source.positionListenable?.removeListener(_updateIndex);
  }

  bool get _hasAnyActivePointer => _activePointerCount > 0;

  bool _shouldSuppressAutoScrollForIndex(int index) {
    if (_suppressAutoScrollTargetIndex == null) return false;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs > _suppressAutoScrollUntilMs) {
      _suppressAutoScrollTargetIndex = null;
      _suppressAutoScrollUntilMs = 0;
      return false;
    }
    return _suppressAutoScrollTargetIndex == index;
  }

  void _markAutoScrollSuppressedForIndex(int index) {
    _suppressAutoScrollTargetIndex = index;
    _suppressAutoScrollUntilMs = DateTime.now().millisecondsSinceEpoch + 900;
  }

  void _clearAutoScrollSuppression() {
    _suppressAutoScrollTargetIndex = null;
    _suppressAutoScrollUntilMs = 0;
  }

  bool _hasManualLocateLock(int nowMs) {
    final int? index = _manualLocateLockIndex;
    if (index == null) return false;
    if (nowMs > _manualLocateLockUntilMs) {
      _manualLocateLockIndex = null;
      _manualLocateLockUntilMs = 0;
      return false;
    }
    return true;
  }

  void _markManualLocateLock(int index, {List<int>? activeIndices}) {
    _manualLocateLockIndex = index;
    _manualLocateActiveIndices = activeIndices ?? <int>[index];
    _manualLocateLockUntilMs = DateTime.now().millisecondsSinceEpoch + 1200;
  }

  void _clearManualLocateLock() {
    _manualLocateLockIndex = null;
    _manualLocateLockUntilMs = 0;
  }

  void _cancelPendingAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoFollowDeferred = false;
    _autoScrollRequestId++;
  }

  /// Cancel the actual driven scroll as well as the distant opacity transition.
  /// Muting a ticker offstage only pauses it: without stopping its activity it
  /// catches up to its old target as soon as the document becomes visible.
  void _cancelReadingMotion({bool cancelDissolve = true}) {
    _readingMotionRequestId++;
    final position = _animatedReadingPosition;
    _animatedReadingPosition = null;
    _readingScrollActivity = null;
    _animatedReadingItem = null;
    _animatedReadingAlignment = null;
    if (cancelDissolve) _viewportMotionKey.currentState?.cancel();
    if (position == null || !position.hasPixels) return;
    try {
      position.jumpTo(position.pixels);
    } catch (_) {
      // The old list can already be detached during a view/controller change.
    }
  }

  _ReadingScrollMomentum? _captureReadingMomentum() {
    final position = _animatedReadingPosition;
    final activity = _readingScrollActivity;
    if (position == null || activity == null) return null;
    final velocity = activity.readingVelocity;
    if (!velocity.isFinite || velocity.abs() < 1) return null;
    return _ReadingScrollMomentum(position, velocity);
  }

  /// Do not paint a retained reading location for a frame and then replace it
  /// with the playback location. Keep layout active and reveal only after the
  /// requested item has published its new geometry.
  void _prepareReadingReveal({int? itemIndex, double? alignment}) {
    if (_hasTextSelection || _displaySubtitles.isEmpty) return;
    if (itemIndex == null) {
      final time = _subtitleTimelinePositionMs;
      final index = _locateIndexAtMs(time, _activeIndicesAtMs(time));
      if (index < 0) return;
      itemIndex = _isArticleMode ? _articleItemIndexForSubtitle(index) : index;
    }
    final requested = alignment ?? _locateAlignment;
    final reachable = _resolveReachableAlignment(
      targetIndex: itemIndex,
      isArticleMode: _isArticleMode,
      requestedAlignment: requested,
    );
    if (_lastVisibleReadingEnvironment == MediaQuery.of(context) &&
        _isScrollableViewportUsable() &&
        _currentItemPositions().any(
          (item) =>
              item.index == itemIndex &&
              (item.itemLeadingEdge - reachable).abs() < .002,
        )) {
      return;
    }
    _readingRevealRequestId++;
    _readingRevealScheduled = false;
    _readingViewportReady = false;
  }

  void _cancelReadingReveal() {
    _readingRevealRequestId++;
    _readingRevealScheduled = false;
    if (_readingViewportReady) return;
    _readingViewportReady = true;
    if (mounted) setState(() {});
  }

  void _queueReadingReveal(int itemIndex, {int attempt = 0}) {
    if (_readingViewportReady || _readingRevealScheduled) return;
    final request = _readingRevealRequestId;
    _readingRevealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _readingRevealRequestId) return;
      _readingRevealScheduled = false;
      if (!widget.isVisible || !_isSubtitleSidebarRouteCurrent) return;
      final hasTarget =
          _isScrollableViewportUsable() &&
          _currentItemPositions().any((item) => item.index == itemIndex);
      if (hasTarget || attempt >= _maxLocateAttempts) {
        setState(() => _readingViewportReady = true);
      } else {
        _queueReadingReveal(itemIndex, attempt: attempt + 1);
      }
    });
    _ensureFrameScheduled();
  }

  void _publishViewportReadyAfterPaint() {
    if (widget.onViewportReadyChanged == null ||
        _viewportReadyNotificationScheduled) {
      return;
    }
    _viewportReadyNotificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportReadyNotificationScheduled = false;
      if (!mounted) return;
      final ready =
          widget.isVisible &&
          _isSubtitleSidebarRouteCurrent &&
          (_displaySubtitles.isEmpty || _readingViewportReady);
      if (_publishedViewportReady == ready) return;
      _publishedViewportReady = ready;
      widget.onViewportReadyChanged?.call(ready);
    });
  }

  void _markManualLocateAutoFollowCooldown() {
    _manualLocateAutoFollowCooldownUntilMs =
        DateTime.now().millisecondsSinceEpoch + 700;
    _manualLocateAutoFollowCooldownTimer?.cancel();
    _manualLocateAutoFollowCooldownTimer = Timer(
      const Duration(milliseconds: 700),
      () {
        _manualLocateAutoFollowCooldownTimer = null;
        _manualLocateAutoFollowCooldownUntilMs = 0;
        if (mounted && _autoFollowDeferred) _updateIndex();
      },
    );
  }

  bool _isInManualLocateAutoFollowCooldown(int nowMs) {
    return nowMs <= _manualLocateAutoFollowCooldownUntilMs;
  }

  void _markManualAnimationFreeze(int index, {required bool animated}) {
    if (!animated) {
      _manualAnimationFreezeIndex = null;
      _manualAnimationFreezeUntilMs = 0;
      return;
    }
    _manualAnimationFreezeIndex = index;
    _manualAnimationFreezeUntilMs = DateTime.now().millisecondsSinceEpoch + 280;
  }

  bool _hasManualAnimationFreeze(int nowMs) {
    final int? index = _manualAnimationFreezeIndex;
    if (index == null) return false;
    if (nowMs > _manualAnimationFreezeUntilMs) {
      _manualAnimationFreezeIndex = null;
      _manualAnimationFreezeUntilMs = 0;
      return false;
    }
    return true;
  }

  // Article Mode Scroll Controller
  static const int _minArticleChunkSize = 1;
  static const int _maxArticleChunkSize = 99;
  int _articleChunkSize = 4;
  bool _articleParagraphModeEnabled = true;
  final ItemScrollController _articleItemScrollController =
      ItemScrollController();
  final ItemPositionsListener _articleItemPositionsListener =
      ItemPositionsListener.create();

  // Cached matches to avoid O(N^2) or repeated searches
  // Key: Primary Index, Value: Secondary Text
  final Map<int, String> _secondaryTextCache = {};
  bool _matchesUseSharedTimeline = false;
  late TranscriptTextCache<String> _selectionTextCache;
  late TranscriptTextCache<SubtitleCueCopyParts> _cueCopyPartsCache;
  int _readingTextRevision = 0;
  int? _lastSelectableTextIndex;
  bool _isBilingualMode = false;
  int _articleDocumentGeneration = 0;
  ArticleDocument? _continuousArticleDocument;
  bool _continuousArticleDocumentDirty = true;
  bool _continuousArticleDocumentAppendPending = false;
  int _continuousArticleDocumentRequestId = 0;
  Future<void>? _continuousArticleDocumentFuture;
  ArticleDocument? _translationPreviousDocument;
  ArticleLayout? _translationPreviousLayout;
  bool _continuousArticleIsAppend = false;
  ArticleLayout? _continuousArticleLayout;
  ArticleLayoutKey? _continuousArticleLayoutKey;
  final List<ArticleLayout> _continuousArticleLayoutCache = <ArticleLayout>[];
  Future<ArticleLayout?>? _continuousArticleLayoutFuture;
  ArticleLayoutKey? _continuousArticlePendingKey;
  int _continuousArticleLayoutRequestId = 0;
  ArticleLayoutKey? _continuousArticleDeferredKey;
  bool _continuousArticleLayoutDeferScheduled = false;
  bool _continuousArticleLayoutRetryScheduled = false;
  int _continuousArticleLayoutRetryCount = 0;
  static const int _maxContinuousArticleLayoutCache = 4;

  bool get _isContinuousArticleMode =>
      _isArticleMode && !_articleParagraphModeEnabled;

  /// 页面在前台、文稿区可见、并且仍是连续文章时，才允许排版任务继续。
  bool get _continuousArticleLayoutAllowed =>
      widget.isVisible && _isHostRouteCurrent && _isContinuousArticleMode;

  bool _canStartContinuousArticleLayout(double contentWidth) {
    return _continuousArticleLayoutAllowed &&
        contentWidth.isFinite &&
        contentWidth > 1;
  }

  /// 丢掉进行中的排版，但留下已经排好的结果。
  ///
  /// 隐藏面板、离开连续文章、或宽度只是瞬时变化时调用。清掉结果会让下一次
  /// 显示先闪「正在准备文章」。
  void _pauseContinuousArticleLayout() {
    _continuousArticleLayoutRequestId++;
    _continuousArticleLayoutFuture = null;
    _continuousArticlePendingKey = null;
  }

  /// 正文变了，旧行记录对不上新文本，必须整份丢掉。
  void _invalidateContinuousArticleLayout() {
    _continuousArticleIsAppend = false;
    _pauseContinuousArticleLayout();
    _continuousArticleLayout = null;
    _continuousArticleLayoutKey = null;
    _continuousArticleLayoutCache.clear();
    _continuousArticleDeferredKey = null;
    _continuousArticleLayoutRetryCount = 0;
  }

  void _rememberContinuousArticleLayout(ArticleLayout layout) {
    _continuousArticleLayoutCache.removeWhere((item) => item.key == layout.key);
    _continuousArticleLayoutCache.add(layout);
    while (_continuousArticleLayoutCache.length >
        _maxContinuousArticleLayoutCache) {
      _continuousArticleLayoutCache.removeAt(0);
    }
    _continuousArticleLayout = layout;
    _continuousArticleLayoutKey = layout.key;
    _continuousArticleLayoutRetryCount = 0;
  }

  ArticleLayout? _cachedContinuousArticleLayout(ArticleLayoutKey key) {
    for (var i = _continuousArticleLayoutCache.length - 1; i >= 0; i--) {
      final ArticleLayout layout = _continuousArticleLayoutCache[i];
      if (layout.key == key) return layout;
    }
    return null;
  }

  /// 同一份正文上最近一次排好的文章。宽度或字号变了也可以先拿来顶上。
  ArticleLayout? _fallbackContinuousArticleLayout(ArticleDocument document) {
    final ArticleLayout? layout = _continuousArticleLayout;
    if (layout == null) return _translationPreviousLayout;
    if (layout.key.documentGeneration != document.generation &&
        !_continuousArticleIsAppend) {
      return _translationPreviousLayout;
    }
    return layout;
  }

  void _cancelMismatchedContinuousArticleLayout(ArticleLayoutKey? allowed) {
    final ArticleLayoutKey? pending = _continuousArticlePendingKey;
    if (pending == null) return;
    if (allowed != null && pending == allowed) return;
    _pauseContinuousArticleLayout();
  }

  /// 宽度连续变化时先不要排。等下一帧宽度还没变，再排那一个稳定值。
  void _deferContinuousArticleLayout(ArticleLayoutKey key) {
    _continuousArticleDeferredKey = key;
    if (_continuousArticleLayoutDeferScheduled) return;
    _continuousArticleLayoutDeferScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _continuousArticleLayoutDeferScheduled = false;
      if (!mounted) return;
      setState(() {});
    });
  }

  bool _isContinuousArticleLayoutDeferredStable(ArticleLayoutKey key) {
    return _continuousArticleDeferredKey == key &&
        !_continuousArticleLayoutDeferScheduled;
  }

  void _ensureContinuousArticleLayout(
    ArticleDocument document,
    ArticleLayoutKey layoutKey,
  ) {
    if (_continuousArticleIsAppend &&
        _continuousArticleLayoutFuture != null &&
        _continuousArticlePendingKey != null &&
        _sameArticleGeometry(_continuousArticlePendingKey!, layoutKey)) {
      // Let an in-flight prefix finish. Repeated appends must not continually
      // cancel cold layout and leave a long transcript in its loading state.
      return;
    }
    if (_continuousArticleLayoutFuture != null &&
        _continuousArticlePendingKey == layoutKey) {
      return;
    }
    final int requestId = ++_continuousArticleLayoutRequestId;
    _continuousArticlePendingKey = layoutKey;
    _continuousArticleLayoutFuture =
        const ArticleLayoutEngine(windowCodeUnits: 512).layoutIncrementally(
          document: document,
          key: layoutKey,
          appendTo: _continuousArticleIsAppend
              ? _continuousArticleLayout
              : null,
          isCancelled: () =>
              !mounted ||
              requestId != _continuousArticleLayoutRequestId ||
              !_continuousArticleLayoutAllowed,
          isInteracting: () => UiInteractionBudget.instance.isActive,
        );
  }

  void _retryContinuousArticleLayoutAfterRejectedFuture() {
    _continuousArticleLayoutFuture = null;
    _continuousArticlePendingKey = null;
    if (_continuousArticleLayoutRetryScheduled) return;
    if (!_continuousArticleLayoutAllowed) return;
    // 取消和重新排版只补有限次，避免一次失败变成每帧重试。
    if (_continuousArticleLayoutRetryCount >= 2) return;
    _continuousArticleLayoutRetryCount++;
    _continuousArticleLayoutRetryScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _continuousArticleLayoutRetryScheduled = false;
      if (!mounted) return;
      setState(() {});
    });
  }

  void _retargetContinuousArticleLayouts(int generation) {
    for (var i = 0; i < _continuousArticleLayoutCache.length; i++) {
      _continuousArticleLayoutCache[i] = _continuousArticleLayoutCache[i]
          .withDocumentGeneration(generation);
    }
    final ArticleLayout? current = _continuousArticleLayout;
    if (current != null) {
      _continuousArticleLayout = current.withDocumentGeneration(generation);
      _continuousArticleLayoutKey = _continuousArticleLayout!.key;
    }
    _continuousArticleDeferredKey = null;
    // 进行中的那次仍挂着旧 generation，结果对不上新文档，取消后用缓存顶上。
    _pauseContinuousArticleLayout();
  }

  void _displayContinuousArticleLayout(ArticleLayout layout) {
    final refreshingTranslation = _translationPreviousDocument != null;
    final previous = _continuousArticleLayoutKey;
    final preserve =
        _continuousArticleIsAppend &&
        previous != null &&
        _sameArticleGeometry(previous, layout.key);
    final bool switched = _continuousArticleLayoutKey != layout.key;
    _rememberContinuousArticleLayout(layout);
    _translationPreviousDocument = null;
    _translationPreviousLayout = null;
    if (_continuousArticlePendingKey == layout.key) {
      _continuousArticleLayoutFuture = null;
      _continuousArticlePendingKey = null;
    }
    if (_translationAnchor != null && _isContinuousArticleMode) {
      _restoreTranslationAnchor(layout: layout);
      return;
    }
    if (refreshingTranslation) return;
    if (preserve ||
        !switched ||
        !widget.isVisible ||
        !_isContinuousArticleMode) {
      return;
    }
    final locateRequestId = _locateRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          locateRequestId != _locateRequestId ||
          !_isContinuousArticleMode ||
          !widget.isVisible) {
        return;
      }
      _triggerLocateButtonAfterModeSwitch();
    });
  }

  bool _sameArticleGeometry(ArticleLayoutKey a, ArticleLayoutKey b) =>
      (a.width - b.width).abs() < .01 &&
      a.style == b.style &&
      a.textDirection == b.textDirection &&
      a.textScaler == b.textScaler;

  // Cached display subtitles to avoid repeated computation
  late List<SubtitleItem> _cachedDisplaySubtitles;

  void _invalidateDisplaySubtitlesCache() {
    _cachedDisplaySubtitles = resolveSubtitleDisplaySelection(
      lineFilterMode: _lineFilterMode,
      primarySubtitles: widget.subtitles,
      secondarySubtitles: widget.secondarySubtitles,
    ).subtitles;
  }

  List<SubtitleItem> get _displaySubtitles => _cachedDisplaySubtitles;

  bool get _usesSecondaryTrackForDisplay =>
      _lineFilterMode == 2 && widget.secondarySubtitles.isNotEmpty;

  double _clampFontSizeScale(double value) {
    return value.clamp(0.5, 3.0).toDouble();
  }

  double _clampTimeColumnRatio(double value) {
    return value.clamp(0.05, 0.30).toDouble();
  }

  int _clampLocatePositionPercent(int value) {
    return value.clamp(0, 100);
  }

  double get _locateAlignment => _locatePositionPercent / 100.0;

  void _loadOrientationDisplaySettings() {
    final settings = SettingsService();
    if (widget.isPortrait) {
      _fontSizeScale = _clampFontSizeScale(
        settings.portraitSidebarFontSizeScale,
      );
      _showTimestamps = settings.portraitSidebarShowTimestamps;
      _timeColumnRatio = _clampTimeColumnRatio(
        settings.portraitSidebarTimeColumnRatio,
      );
      _locatePositionPercent = _clampLocatePositionPercent(
        settings.portraitSidebarLocatePositionPercent,
      );
    } else {
      _fontSizeScale = _clampFontSizeScale(
        settings.landscapeSidebarFontSizeScale,
      );
      _showTimestamps = settings.landscapeSidebarShowTimestamps;
      _timeColumnRatio = _clampTimeColumnRatio(
        settings.landscapeSidebarTimeColumnRatio,
      );
      _locatePositionPercent = _clampLocatePositionPercent(
        settings.landscapeSidebarLocatePositionPercent,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(
      _handleTranscriptFontsChanged,
    );
    // Load persisted settings
    final settings = SettingsService();
    _isArticleMode = settings.subtitleViewMode == 1;
    _articleChunkSize = settings.subtitleArticleSentencesPerParagraph.clamp(
      _minArticleChunkSize,
      _maxArticleChunkSize,
    );
    _articleParagraphModeEnabled = settings.subtitleArticleParagraphModeEnabled;
    _loadOrientationDisplaySettings();
    _lastKnownIsPlaying = _playbackIsPlaying;
    _lastSubtitleOffsetMs = settings.subtitleOffset.inMilliseconds;
    settings.addListener(_handleSubtitleOffsetChanged);
    _attachPlaybackListeners();
    GestureBinding.instance.pointerRouter.addGlobalRoute(
      _handleGlobalSelectionPointerEvent,
    );
    // Sidebar-owned Ctrl/Cmd chords, including a hardware keyboard on a phone.
    // SelectionArea's own Actions only cover currently mounted virtualized rows.
    _textSelectionFocusNode.onKeyEvent = (FocusNode node, KeyEvent event) {
      return handleTranscriptShortcut(event);
    };
    _invalidateDisplaySubtitlesCache();
    _checkBilingualSync();
    _rebuildTimelineResolver();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visualTicksEnabled = TickerMode.valuesOf(context).enabled;
    // A paused controller may never emit another sample after this sidebar
    // mounts. Seed its highlight from the current playback clock as well.
    _updateIndex();
    // ModalRoute.of 会建立对路由状态的依赖：isCurrent 变化（被横屏播放页/
    // 音乐播放页/弹窗覆盖，或重新回到前台）时会重新进入本方法。
    _handleRouteVisibilityChanged(ModalRoute.of(context)?.isCurrent ?? true);
  }

  /// 路由从「被覆盖」回到前台时，列表恢复布局，被静音挂起的自动跟随动画会
  /// 集中补帧。这里主动补一次修复定位，避免文稿停在切页时的旧位置或空白状态。
  /// 反过来，被覆盖时立刻取消待执行的自动跟随，避免它与修复定位抢落点。
  void _handleRouteVisibilityChanged(bool isCurrent) {
    if (isCurrent == _isHostRouteCurrent) return;
    _isHostRouteCurrent = isCurrent;
    _updateReadingInteraction();
    if (!isCurrent) {
      _cancelPendingAutoScroll();
      _cancelReadingMotion();
      _cancelReadingReveal();
      _routeRestorePending = true;
      return;
    }
    if (!_routeRestorePending && !_repairRequestPending) return;
    _routeRestorePending = false;
    if (!mounted || !widget.isVisible || _displaySubtitles.isEmpty) return;
    // 自动跟随打开时，回到前台主动补一次定位；自动跟随关闭时只在页面之前
    // 显式请求过的修复仍悬空时才补，避免把用户手动滚动的位置强行拉回。
    if (!_repairRequestPending && !SettingsService().autoScrollSubtitles) {
      return;
    }
    _prepareReadingReveal();
    locateToCurrentSubtitle(ignorePointer: true);
  }

  bool get _isSubtitleSidebarRouteCurrent => _isHostRouteCurrent;

  @override
  void didUpdateWidget(SubtitleSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isVisible && !widget.isVisible) {
      if (widget.preserveReadingPositionWhenNotFollowing) {
        final visible =
            _currentItemPositions()
                .where((p) => p.itemLeadingEdge >= 0 && p.itemLeadingEdge < 1)
                .toList()
              ..sort((a, b) => a.index.compareTo(b.index));
        _savedReadingPosition = visible.isEmpty ? null : visible.first;
      }
      _cancelPendingAutoScroll();
      _invalidateLocateRequests();
      // 切到别的面板时只停掉还在排的任务。已经显示过的文章留着，
      // 再切回来时直接画，不必先闪「正在准备文章」。
      _pauseContinuousArticleLayout();
      _updateReadingInteraction();
    }
    final bool playbackSourceChanged =
        widget.controller != oldWidget.controller ||
        widget.positionListenable != oldWidget.positionListenable;
    final bool subtitleContentBecameAvailable =
        oldWidget.subtitles.isEmpty &&
        oldWidget.secondarySubtitles.isEmpty &&
        (widget.subtitles.isNotEmpty || widget.secondarySubtitles.isNotEmpty);
    if (widget.isPortrait != oldWidget.isPortrait) {
      _loadOrientationDisplaySettings();
    }
    if (playbackSourceChanged) {
      _invalidateLocateRequests();
      _cancelPendingAutoScroll();
      _detachPlaybackListeners(oldWidget);
      _attachPlaybackListeners();
      _lastKnownIsPlaying = _playbackIsPlaying;
    }
    if (widget.subtitles != oldWidget.subtitles ||
        widget.secondarySubtitles != oldWidget.secondarySubtitles) {
      final append =
          isSubtitleAppend(oldWidget.subtitles, widget.subtitles) &&
          (identical(oldWidget.secondarySubtitles, widget.secondarySubtitles) ||
              isSubtitleAppend(
                oldWidget.secondarySubtitles,
                widget.secondarySubtitles,
              ));
      final secondaryAppend =
          isSubtitleAppend(oldWidget.subtitles, widget.subtitles) &&
          oldWidget.subtitles.length == widget.subtitles.length;
      if (secondaryAppend ||
          (append && !_canAppendOnSharedTimeline(oldWidget))) {
        if (_hasTextSelection) {
          // Keep both the selected text and its geometry frozen. Refresh the
          // accumulated tracks as soon as the user leaves selection.
          _pendingTrackAlignmentRefresh = true;
        } else {
          _refreshStreamedTracks();
        }
      } else if (append) {
        final count = _displaySubtitles.length;
        _invalidateDisplaySubtitlesCache();
        // Use positional appends only after both the retained prefix and new
        // pairs have identical time ranges. Independently segmented OCR tracks
        // instead use the same interval matcher as a freshly opened sidebar.
        for (
          var i = oldWidget.subtitles.length;
          i < widget.subtitles.length;
          i++
        ) {
          if (i < widget.secondarySubtitles.length) {
            _secondaryTextCache[i] = _normalizeTranscriptText(
              widget.secondarySubtitles[i].text,
            );
          }
        }
        _matchesUseSharedTimeline =
            widget.subtitles.length == widget.secondarySubtitles.length;
        _isBilingualMode = _secondaryTextCache.isNotEmpty;
        _timelineResolverSubtitles = _displaySubtitles;
        _readingCueWindow.clear();
        if (_timelineResolver == null) {
          _timelineResolver = SubtitleTimelineResolver(_displaySubtitles);
        } else {
          _timelineResolver!.append(_displaySubtitles);
        }
        _cueCopyPartsCache.extendTo(_displaySubtitles.length);
        _selectionTextCache.extendTo(_displaySubtitles.length);
        _lastSelectableTextIndex = null;
        final previous = _continuousArticleDocument;
        final addedCount = _displaySubtitles.length - count;
        if (previous != null &&
            !_continuousArticleDocumentDirty &&
            addedCount > 0 &&
            addedCount <= 128) {
          _continuousArticleDocument = previous.appendDisplayTexts(
            generation: ++_articleDocumentGeneration,
            displayTexts: _selectionTextCache.sublist(count),
          );
          _continuousArticleIsAppend = true;
        } else if (addedCount > 0) {
          // Finish an in-flight prefix while streaming continues; cancelling
          // every incoming cue could leave a long article preparing forever.
          if (_continuousArticleDocumentFuture == null &&
              (previous == null ||
                  !_continuousArticleDocumentDirty ||
                  _continuousArticleDocumentAppendPending)) {
            _continuousArticleDocumentDirty = true;
            _continuousArticleDocumentAppendPending = true;
          }
        }
      } else {
        _pendingTrackAlignmentRefresh = false;
        _translationAnchor = null;
        _translationPreviousDocument = null;
        _translationPreviousLayout = null;
        _invalidateLocateRequests();
        _cancelPendingAutoScroll();
        _savedReadingPosition = null;
        _clearTextSelection(resumeAutoFollow: false);
        _invalidateDisplaySubtitlesCache();
        _checkBilingualSync();
        _rebuildTimelineResolver();
      }
    }
    if (playbackSourceChanged ||
        widget.subtitles != oldWidget.subtitles ||
        widget.secondarySubtitles != oldWidget.secondarySubtitles) {
      _updateIndex();
    }
    if (playbackSourceChanged || subtitleContentBecameAvailable) {
      _scheduleLocateAfterMediaOrSubtitleChange();
    }
    if (!oldWidget.isVisible && widget.isVisible) {
      if (SettingsService().autoScrollSubtitles) {
        _prepareReadingReveal();
      } else if (widget.preserveReadingPositionWhenNotFollowing &&
          _savedReadingPosition != null) {
        _prepareReadingReveal(
          itemIndex: _savedReadingPosition!.index,
          alignment: _savedReadingPosition!.itemLeadingEdge,
        );
      }
      final locateRequestId = _locateRequestId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            locateRequestId != _locateRequestId ||
            !widget.isVisible) {
          return;
        }
        // Read the switch when the returned viewport is ready, including
        // changes made while chat was visible. A paused video still needs to
        // locate after seeking; ordinary playback auto-follow skips pauses.
        if (SettingsService().autoScrollSubtitles) {
          _savedReadingPosition = null;
          locateToCurrentSubtitle(ignorePointer: true);
        } else if (widget.preserveReadingPositionWhenNotFollowing) {
          _restoreReadingPosition();
        }
      });
      _ensureFrameScheduled();
    }
  }

  void _refreshStreamedTracks() {
    final visible =
        _currentItemPositions()
            .where((p) => p.itemLeadingEdge >= 0 && p.itemLeadingEdge < 1)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (_translationAnchor == null &&
        visible.isNotEmpty &&
        !_hasAnyActivePointer) {
      final first = visible.first;
      var index = first.index;
      var textOffset = 0;
      final layout = _translationPreviousLayout ?? _continuousArticleLayout;
      final document =
          _translationPreviousDocument ?? _continuousArticleDocument;
      if (_isContinuousArticleMode &&
          layout != null &&
          index < layout.lines.length) {
        final line = layout.lines[index];
        index =
            document?.displayIndexAtOffset(line.paintStart) ??
            line.sentenceIndices.firstOrNull ??
            0;
        textOffset =
            line.paintStart -
            (document?.sentences[index].start ?? line.paintStart);
      }
      _translationAnchor = (
        index: index,
        textOffset: textOffset,
        alignment: first.itemLeadingEdge,
        request: _locateRequestId,
      );
    }
    // New secondary cues may belong to earlier primary rows, and a new primary
    // row may need a secondary cue published in an earlier batch.
    _checkBilingualSync();
    if (_isContinuousArticleMode && _translationPreviousDocument == null) {
      _translationPreviousDocument = _continuousArticleDocument;
      _translationPreviousLayout = _continuousArticleLayout;
    }
    _invalidateDisplaySubtitlesCache();
    _rebuildTimelineResolver();
    if (!_isContinuousArticleMode) _restoreTranslationAnchor();
  }

  void _restoreTranslationAnchor({ArticleLayout? layout}) {
    final anchor = _translationAnchor;
    if (anchor == null) return;
    _translationAnchor = null;
    var target = anchor.index;
    if (layout != null) {
      final offset =
          (_continuousArticleDocument?.sentences[anchor.index].start ?? 0) +
          anchor.textOffset;
      var low = 0, high = layout.lines.length - 1;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (layout.lines[middle].end <= offset) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      target = low;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.isVisible ||
          anchor.request != _locateRequestId ||
          _hasTextSelection) {
        return;
      }
      final scroll = _isArticleMode
          ? _articleItemScrollController
          : _itemScrollController;
      if (scroll.isAttached && _hasTranscriptScrollRange) {
        scroll.jumpTo(index: target, alignment: anchor.alignment);
      }
    });
    _ensureFrameScheduled();
  }

  void _flushPendingStreamedTracks() {
    final pending = _pendingTrackAlignmentRefresh;
    _pendingTrackAlignmentRefresh = false;
    if (pending) _refreshStreamedTracks();
  }

  void _restoreReadingPosition({int attempt = 0, int? motionRequestId}) {
    final requestId = motionRequestId ?? _readingMotionRequestId;
    final saved = _savedReadingPosition;
    if (saved == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          requestId != _readingMotionRequestId ||
          !widget.isVisible ||
          !identical(saved, _savedReadingPosition)) {
        return;
      }
      final scroll = _isArticleMode
          ? _articleItemScrollController
          : _itemScrollController;
      if (!scroll.isAttached) {
        if (attempt < 10) {
          _restoreReadingPosition(
            attempt: attempt + 1,
            motionRequestId: requestId,
          );
        }
        return;
      }
      if (_hasTranscriptScrollRange) {
        scroll.jumpTo(index: saved.index, alignment: saved.itemLeadingEdge);
        _settleReadingJump();
      }
      _queueReadingReveal(saved.index);
      _savedReadingPosition = null;
    });
    _ensureFrameScheduled();
  }

  void _scheduleLocateAfterMediaOrSubtitleChange() {
    final locateRequestId = _locateRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          locateRequestId != _locateRequestId ||
          !widget.isVisible ||
          _displaySubtitles.isEmpty) {
        return;
      }
      locateToCurrentSubtitle(ignorePointer: true);
    });
    _ensureFrameScheduled();
  }

  void _handleScrollableViewportLayout(BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return;
    final Size nextSize = Size(constraints.maxWidth, constraints.maxHeight);
    final Size? previousSize = _lastScrollableViewportSize;
    _lastScrollableViewportSize = nextSize;
    if (widget.preserveReadingPositionWhenNotFollowing &&
        !_repairRequestPending) {
      return;
    }
    if (previousSize == null ||
        ((previousSize.width - nextSize.width).abs() < 0.5 &&
            (previousSize.height - nextSize.height).abs() < 0.5) ||
        _viewportAlignmentRestoreScheduled) {
      return;
    }

    _viewportAlignmentRestoreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportAlignmentRestoreScheduled = false;
      if (!mounted || !widget.isVisible || _displaySubtitles.isEmpty) return;
      // ScrollablePositionedList preserves the old pixel offset when its
      // viewport is resized. Re-apply the percentage alignment after the new
      // geometry has been painted so entering the portrait player cannot
      // leave the current subtitle visibly lower than the configured target.
      // 只要还有未落地的修复请求（例如切页时视口被压缩、位置又发生变化），
      // 这里也必须重新驱动，否则该请求会一直悬空、文稿停留在空白状态。
      final bool autoFollowRepair =
          _playbackIsPlaying && SettingsService().autoScrollSubtitles;
      if (!autoFollowRepair && !_repairRequestPending) return;
      if (_hasTextSelection) return;
      // 被不透明路由覆盖时列表没有布局，定位会被丢弃，等回到前台重新驱动。
      if (!_isSubtitleSidebarRouteCurrent) return;
      _beginLocateRequest(animated: false, repair: true);
    });
  }

  bool _samePairTimeline(int from) {
    for (var i = from; i < widget.subtitles.length; i++) {
      if (widget.subtitles[i].endTime <= widget.subtitles[i].startTime ||
          widget.subtitles[i].startTime !=
              widget.secondarySubtitles[i].startTime ||
          widget.subtitles[i].endTime != widget.secondarySubtitles[i].endTime) {
        return false;
      }
    }
    return true;
  }

  bool _canAppendOnSharedTimeline(SubtitleSidebar oldWidget) {
    if (_pendingTrackAlignmentRefresh) return false;
    if (oldWidget.secondarySubtitles.isEmpty &&
        widget.secondarySubtitles.isEmpty) {
      return true;
    }
    return _matchesUseSharedTimeline &&
        widget.subtitles.length == widget.secondarySubtitles.length &&
        _samePairTimeline(oldWidget.subtitles.length);
  }

  void _checkBilingualSync() {
    _secondaryTextCache.clear();
    _isBilingualMode = false;
    _matchesUseSharedTimeline =
        widget.subtitles.length == widget.secondarySubtitles.length &&
        _samePairTimeline(0);

    if (widget.secondarySubtitles.isEmpty) return;
    if (widget.subtitles.isEmpty) return;

    final matchResult = matchSubtitleTracks(
      primarySubtitles: widget.subtitles,
      secondarySubtitles: widget.secondarySubtitles,
    );

    for (final index in matchResult.primaryToSecondaryIndices.keys) {
      _secondaryTextCache[index] = _normalizeTranscriptText(
        matchResult.secondaryTextForPrimary(index, widget.secondarySubtitles),
      );
    }

    // A partially translated track should still show every valid translation.
    _isBilingualMode = matchResult.hasMatches;
  }

  @override
  void dispose() {
    _readingDisposed = true;
    _manualLocateAutoFollowCooldownTimer?.cancel();
    PaintingBinding.instance.systemFonts.removeListener(
      _handleTranscriptFontsChanged,
    );
    _readingInteractionPosition?.isScrollingNotifier.removeListener(
      _updateReadingInteraction,
    );
    _releaseReadingInteraction?.call();
    _releaseReadingInteraction = null;
    _cancelReadingMotion(cancelDissolve: false);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handleGlobalSelectionPointerEvent,
    );
    _stopTouchSelectionEdgeScroll();
    _clearSelectionGesture();
    _cancelSelectionPreservingPan();
    _removePersistentSelectionToolbar();
    _removeDesktopSelectionToolbar();
    _removeCopyFormatPopover();
    _continuousArticleLayoutRequestId++;
    _detachPlaybackListeners(widget);
    SettingsService().removeListener(_handleSubtitleOffsetChanged);
    _activeIndexNotifier.dispose();
    _activeIndicesNotifier.dispose();
    _textSelectionFocusNode.dispose();
    _scrollSelectionDelegate.dispose();
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  void _rebuildTimelineResolver() {
    _readingCueWindow.clear();
    final subtitles = _displaySubtitles;
    _timelineResolverSubtitles = subtitles;
    _timelineResolver = subtitles.isEmpty
        ? null
        : SubtitleTimelineResolver(subtitles);
    _rebuildSelectionTextCache();
    _rebuildContinuousArticleDocument();
    if (_pendingLocateIndex != null &&
        (_pendingLocateIndex! < 0 ||
            _pendingLocateIndex! >= subtitles.length)) {
      _pendingLocateIndex = null;
    }
  }

  String _normalizeTranscriptText(String text) {
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  void _handleTranscriptFontsChanged() {
    if (!mounted || _readingDisposed) return;
    // A font may finish loading without changing its family name. Cached fit
    // checks and natural line breaks then need fresh metrics, but the retained
    // document and selection must remain available while reflow is prepared.
    setState(() {
      _paragraphFitKey = null;
      _continuousArticleIsAppend = false;
      _pauseContinuousArticleLayout();
      _continuousArticleLayoutCache.clear();
      _continuousArticleLayoutKey = null;
      _continuousArticleDeferredKey = null;
    });
  }

  void _rebuildSelectionTextCache() {
    _readingTextRevision++;
    final parts = TranscriptTextCache<SubtitleCueCopyParts>(
      length: _displaySubtitles.length,
      resolve: _computeCueCopyPartsForIndex,
    );
    _cueCopyPartsCache = parts;
    _selectionTextCache = TranscriptTextCache<String>(
      length: parts.length,
      resolve: (index) => SubtitleCopyFormatter.displayText(parts[index]),
    );
    _lastSelectableTextIndex = null;
  }

  bool _hasSelectableTextAfter(int index) {
    final last = _lastSelectableTextIndex ??= _selectionTextCache
        .lastIndexWhere((text) => text.isNotEmpty);
    return index < last;
  }

  bool get _selectionBlocksAutoFollow =>
      _hasAnyActivePointer || _hasTextSelection;

  void _handleTextSelectionChanged(SelectedContent? content) {
    final String nextText = content?.plainText ?? '';
    final bool hasSelection = nextText.isNotEmpty;

    if (_fullTranscriptSelected) {
      // Handle drags are a real user edit of the range. Everything else is
      // Flutter reporting a virtualized subset or an empty selectAll result.
      if (_selectionGestureUsesHandle && hasSelection) {
        _fullTranscriptSelected = false;
      } else {
        _selectedTranscriptText = _canonicalTranscriptText;
        if (!_hasTextSelection) {
          setState(() => _hasTextSelection = true);
        }
        _persistentSelectionToolbarEntry?.markNeedsBuild();
        _desktopSelectionToolbarEntry?.markNeedsBuild();
        _copyFormatPopoverEntry?.markNeedsBuild();
        return;
      }
    }

    final bool textChanged = nextText != _selectedTranscriptText;
    _selectedTranscriptText = nextText;

    if (hasSelection && !_hasTextSelection) {
      _fullTranscriptSelected = false;
      final int? touchPointer = _activeTouchPointerForSelection();
      if (touchPointer != null) {
        _usesPersistentTouchSelectionToolbar = true;
        _persistentSelectionToolbarAnchor =
            _downTouchPointerPositions[touchPointer];
      } else if (_isMobileSelectionPlatform) {
        // iOS/Android can confirm a selection after the pointer tracking
        // window; still take ownership so Flutter never attaches a geometry
        // menu that later dies off-screen.
        _usesPersistentTouchSelectionToolbar = true;
      }
      setState(() => _hasTextSelection = true);
      _hideNativeSelectionToolbars();
      if (_usesPersistentTouchSelectionToolbar) {
        _schedulePersistentSelectionToolbar();
      }
      _cancelPendingAutoScroll();
      _invalidateLocateRequests();
      // The long-press pointer is already down; bind the gesture to it.
      if (_selectionGesturePointer == null) {
        _selectionGesturePointer = _activeTouchPointerForSelection();
        _selectionGestureUsesHandle = false;
      }
      return;
    }

    if (hasSelection && textChanged) {
      _hideNativeSelectionToolbars();
      _persistentSelectionToolbarEntry?.markNeedsBuild();
      _desktopSelectionToolbarEntry?.markNeedsBuild();
      _copyFormatPopoverEntry?.markNeedsBuild();
      _tryBindCurrentSelectionHandlePointer();
      // Keep the existing pointer; the helper only rebinds when Flutter has
      // confirmed an active selection-changing gesture.
      return;
    }

    if (hasSelection == _hasTextSelection) return;
    setState(() => _hasTextSelection = hasSelection);
    if (!hasSelection) _flushPendingStreamedTracks();
    _removePersistentSelectionToolbar();
    _removeDesktopSelectionToolbar();
    _removeCopyFormatPopover();
    _stopTouchSelectionEdgeScroll();
    _clearSelectionGesture();
    _resumeAutoFollowAfterSelection();
  }

  void _resumeAutoFollowAfterSelection() {
    final locateRequestId = _locateRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          locateRequestId != _locateRequestId ||
          _hasTextSelection) {
        return;
      }
      triggerLocateForAutoFollow(animated: true);
    });
    _ensureFrameScheduled();
  }

  void _clearTextSelection({bool resumeAutoFollow = true}) {
    final bool wasSelected = _hasTextSelection;
    if (_hasTextSelection && mounted) {
      setState(() => _hasTextSelection = false);
    } else {
      _hasTextSelection = false;
    }
    _selectedTranscriptText = '';
    _fullTranscriptSelected = false;
    _cancelSelectionPreservingPan();
    _removePersistentSelectionToolbar();
    _removeDesktopSelectionToolbar();
    _removeCopyFormatPopover();
    _stopTouchSelectionEdgeScroll();
    _clearSelectionGesture();
    _textSelectionKey.currentState?.selectableRegion.clearSelection();
    _textSelectionFocusNode.unfocus();
    _flushPendingStreamedTracks();
    if (wasSelected && resumeAutoFollow) {
      _resumeAutoFollowAfterSelection();
    }
  }

  /// Clears the sidebar's independent transcript selection region.
  ///
  /// Playback pages call this when the user taps outside the sidebar so a
  /// selection cannot remain stranded after the page-level selection clears.
  void clearTextSelection() => _clearTextSelection();

  @visibleForTesting
  String get selectedTranscriptText => _selectedTranscriptText;

  @visibleForTesting
  bool get isFullTranscriptSelected => _fullTranscriptSelected;

  String get _canonicalTranscriptText =>
      SubtitleCopyFormatter.joinedDisplayText(_cueCopyPartsCache);

  /// Navigation gestures must yield while the transcript has selected text.
  bool get hasTextSelection => _hasTextSelection;

  @visibleForTesting
  bool get isTouchSelectionEdgeScrolling =>
      _touchSelectionEdgeScrollTimer != null;

  @visibleForTesting
  bool get isSelectionGestureActive => _selectionGesturePointer != null;

  @visibleForTesting
  bool get hasOwnedSelectionToolbar =>
      _persistentSelectionToolbarEntry != null ||
      _desktopSelectionToolbarEntry != null;

  /// Touch selection follows a text-editor model:
  ///   1. While the extending pointer stays inside the document, leave the
  ///      viewport entirely to Flutter's selection gesture.
  ///   2. When that pointer reaches the top or bottom edge, pixel-scroll in
  ///      that direction through the list's public relative-offset API.
  ///   3. After lift, stop the fallback so the user can pan the transcript.
  ///
  /// Listen globally because selection handles live in the overlay rather than
  /// this sidebar's render subtree. Mouse is unchanged.
  void _handleGlobalSelectionPointerEvent(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    if (event is PointerDownEvent) {
      _downTouchPointers.add(event.pointer);
      _downTouchPointerPositions[event.pointer] = event.position;
      _latestDownTouchPointer = event.pointer;
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _downTouchPointers.remove(event.pointer);
      _downTouchPointerPositions.remove(event.pointer);
      if (_latestDownTouchPointer == event.pointer) {
        _latestDownTouchPointer = _downTouchPointers.isEmpty
            ? null
            : _downTouchPointers.last;
      }
      if (_selectionGesturePointer == event.pointer) {
        _stopTouchSelectionEdgeScroll();
        _clearSelectionGesture();
      } else if (_touchSelectionEdgePointer == event.pointer) {
        _stopTouchSelectionEdgeScroll();
      }
      return;
    }
    if (event is! PointerMoveEvent || !_hasTextSelection) return;
    _downTouchPointerPositions[event.pointer] = event.position;

    // A real mobile handle drag is a second gesture: long-press, lift, then
    // press one of the handles.  The original long-press pointer has already
    // been cleared by that point.  Bind the new pointer only after Flutter's
    // selection overlay confirms that it is dragging a handle, so an ordinary
    // one-finger transcript pan remains a normal scroll gesture.
    if (_selectionGesturePointer == null && _isSelectionChangeGestureActive) {
      _selectionGesturePointer = event.pointer;
      _selectionGestureUsesHandle = true;
    }
    if (_selectionGesturePointer == null) {
      _scheduleSelectionHandlePointerBindCheck();
    }
    if (event.pointer != _selectionGesturePointer) {
      return;
    }

    _updateTouchSelectionEdgeForPointer(event.pointer, event.position);
  }

  void _scheduleSelectionHandlePointerBindCheck() {
    if (_selectionHandleBindCheckScheduled) return;
    _selectionHandleBindCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionHandleBindCheckScheduled = false;
      if (!mounted) return;
      _tryBindCurrentSelectionHandlePointer();
    });
    _ensureFrameScheduled();
  }

  void _tryBindCurrentSelectionHandlePointer() {
    if (!_hasTextSelection ||
        _selectionGesturePointer != null ||
        !_isSelectionChangeGestureActive) {
      return;
    }
    final int? pointer = _latestDownTouchPointer;
    if (pointer == null || !_downTouchPointers.contains(pointer)) return;
    final Offset? position = _downTouchPointerPositions[pointer];
    if (position == null) return;
    _selectionGesturePointer = pointer;
    _selectionGestureUsesHandle = true;
    _updateTouchSelectionEdgeForPointer(pointer, position);
  }

  void _updateTouchSelectionEdgeForPointer(int pointer, Offset position) {
    if (pointer != _selectionGesturePointer) return;

    final RenderObject? object = _listViewportKey.currentContext
        ?.findRenderObject();
    if (object is! RenderBox || !object.hasSize || object.size.height <= 0) {
      return;
    }
    final Offset local = object.globalToLocal(position);
    final bool wasEdgeScrolling = _touchSelectionEdgePointer == pointer;
    final double edgeZone = wasEdgeScrolling
        ? _touchSelectionEdgeExitZone
        : _touchSelectionEdgeEnterZone;
    final bool horizontallyNearViewport =
        local.dx >= -_touchSelectionEdgeEnterZone &&
        local.dx <= object.size.width + _touchSelectionEdgeEnterZone;
    final double topPenetration = edgeZone - local.dy;
    final double bottomPenetration = local.dy - (object.size.height - edgeZone);

    double? signedPixels;
    if (horizontallyNearViewport &&
        bottomPenetration > 0 &&
        local.dy > _touchSelectionEdgeEnterZone) {
      signedPixels = _edgeScrollPixelsForPenetration(
        local.dy - (object.size.height - _touchSelectionEdgeEnterZone),
      );
    } else if (horizontallyNearViewport &&
        topPenetration > 0 &&
        local.dy < object.size.height - _touchSelectionEdgeEnterZone) {
      signedPixels = -_edgeScrollPixelsForPenetration(
        _touchSelectionEdgeEnterZone - local.dy,
      );
    }

    if (signedPixels == null) {
      if (wasEdgeScrolling) {
        _stopTouchSelectionEdgeScroll();
      }
      return;
    }

    final int previousDirection = _touchSelectionEdgeScrollPixels.sign.toInt();
    final int nextDirection = signedPixels.sign.toInt();
    if (!wasEdgeScrolling || previousDirection != nextDirection) {
      _touchSelectionEdgeTickCount = 0;
    }
    _touchSelectionEdgePointer = pointer;
    _touchSelectionEdgeScrollPixels = signedPixels;
    final bool startedTimer = _touchSelectionEdgeScrollTimer == null;
    _touchSelectionEdgeScrollTimer ??= Timer.periodic(
      _touchSelectionEdgeScrollInterval,
      (_) => _tickTouchSelectionEdgeScroll(),
    );
    if (startedTimer) {
      _tickTouchSelectionEdgeScroll();
    }
  }

  bool get _isSelectionChangeGestureActive =>
      _selectionRegionStatus == SelectableRegionSelectionStatus.changing;

  void _handleSelectionRegionStatusChanged(
    SelectableRegionSelectionStatus status,
  ) {
    _selectionRegionStatus = status;
    if (status == SelectableRegionSelectionStatus.changing) {
      _tryBindCurrentSelectionHandlePointer();
    }
  }

  double _edgeScrollPixelsForPenetration(double penetration) {
    final double strength = (penetration / _touchSelectionEdgeEnterZone).clamp(
      0.0,
      1.0,
    );
    return (_touchSelectionMinPixelsPerTick + 1.5 * strength).clamp(
      _touchSelectionMinPixelsPerTick,
      _touchSelectionMaxPixelsPerTick,
    );
  }

  double get _acceleratedTouchSelectionPixelsPerTick {
    final double progress =
        ((_touchSelectionEdgeTickCount -
                    _touchSelectionAccelerationDelayTicks) /
                _touchSelectionAccelerationTicks)
            .clamp(0.0, 1.0);
    // Smoothstep gives a gentle start and reaches full speed without requiring
    // any additional travel beyond the phone's physical bottom edge.
    final double eased = progress * progress * (3 - 2 * progress);
    final double dwellSpeed =
        _touchSelectionMinPixelsPerTick +
        (_touchSelectionMaxPixelsPerTick - _touchSelectionMinPixelsPerTick) *
            eased;
    final double requestedSpeed = _touchSelectionEdgeScrollPixels.abs();
    return requestedSpeed > dwellSpeed ? requestedSpeed : dwellSpeed;
  }

  void _tickTouchSelectionEdgeScroll() {
    if (!mounted ||
        !_hasTextSelection ||
        _touchSelectionEdgePointer == null ||
        _selectionGesturePointer == null) {
      return;
    }
    final ScrollableState? scrollable = _selectionScrollable;
    if (scrollable == null || !scrollable.mounted) return;
    try {
      final position = scrollable.position;
      _touchSelectionEdgeTickCount++;
      final double direction = _touchSelectionEdgeScrollPixels.sign;
      final double delta = direction * _acceleratedTouchSelectionPixelsPerTick;
      final double target = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((target - position.pixels).abs() < precisionErrorTolerance) {
        _stopTouchSelectionEdgeScroll();
        return;
      }
      // Mature document editors keep one stable scroll position and apply
      // small, velocity-limited deltas every frame. Never re-anchor the list:
      // doing so makes the viewport race and disposes selection endpoints.
      position.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _touchSelectionEdgePointer == null) return;
        _scrollSelectionDelegate.followScroll();
        _handleTextSelectionChanged(
          _scrollSelectionDelegate.getSelectedContent(),
        );
      });
    } catch (_) {
      // The scrollable may detach while switching mode or media.
    }
  }

  void _handleSelectionScrollableChanged(ScrollableState scrollable) {
    if (!mounted) return;
    _selectionScrollable = scrollable;
    _updateReadingInteraction();
  }

  Widget _keepSelectionNodeAlive(Widget child) {
    return _SelectionKeepAlive(
      keepAlive: _hasTextSelection,
      child: _TranscriptScrollableObserver(
        onScrollableChanged: _handleSelectionScrollableChanged,
        child: child,
      ),
    );
  }

  void _clearSelectionGesture() {
    _selectionGesturePointer = null;
    _selectionGestureUsesHandle = false;
  }

  void _stopTouchSelectionEdgeScroll() {
    _touchSelectionEdgeScrollTimer?.cancel();
    _touchSelectionEdgeScrollTimer = null;
    _touchSelectionEdgePointer = null;
    _touchSelectionEdgeScrollPixels = 0;
    _touchSelectionEdgeTickCount = 0;
  }

  bool get _isMobileSelectionPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return true;
      default:
        return false;
    }
  }

  Widget _buildTextSelectionContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    // The sidebar owns every visible transcript menu. Flutter's geometry-
    // anchored toolbar is what turned into ErrorWidget once virtualized
    // glyphs scrolled off-screen; empty right-click would also open a second
    // "Select all" menu from the ancestor SelectionArea.
    return const SizedBox.shrink();
  }

  void _schedulePersistentSelectionToolbar() {
    if (_persistentSelectionToolbarEntry != null ||
        _persistentSelectionToolbarInsertScheduled) {
      _persistentSelectionToolbarEntry?.markNeedsBuild();
      return;
    }
    _persistentSelectionToolbarInsertScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _persistentSelectionToolbarInsertScheduled = false;
      if (!mounted ||
          !_hasTextSelection ||
          !_usesPersistentTouchSelectionToolbar ||
          _persistentSelectionToolbarEntry != null) {
        return;
      }
      final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) return;
      final entry = OverlayEntry(builder: _buildPersistentSelectionToolbar);
      _persistentSelectionToolbarEntry = entry;
      overlay.insert(entry);
    });
    _ensureFrameScheduled();
  }

  Widget _buildPersistentSelectionToolbar(BuildContext context) {
    if (!mounted ||
        !_hasTextSelection ||
        !_usesPersistentTouchSelectionToolbar) {
      return const SizedBox.shrink();
    }
    final SelectionAreaState? selectionArea = _textSelectionKey.currentState;
    final RenderObject? viewportObject = _listViewportKey.currentContext
        ?.findRenderObject();
    if (selectionArea == null ||
        viewportObject is! RenderBox ||
        !viewportObject.hasSize) {
      return const SizedBox.shrink();
    }

    final Offset topLeft = viewportObject.localToGlobal(Offset.zero);
    final Rect viewport = topLeft & viewportObject.size;
    final TextSelectionToolbarAnchors stableAnchors =
        _persistentSelectionToolbarAnchors ??=
            _resolvePersistentTouchToolbarAnchors(selectionArea, viewport);
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: stableAnchors,
      buttonItems: _buildReliableSelectionToolbarItems(forTouch: true),
    );
  }

  TextSelectionToolbarAnchors _resolvePersistentTouchToolbarAnchors(
    SelectionAreaState selectionArea,
    Rect viewport,
  ) {
    TextSelectionToolbarAnchors? nativeAnchors;
    try {
      final TextSelectionToolbarAnchors candidate =
          selectionArea.selectableRegion.contextMenuAnchors;
      if (_isFiniteOffset(candidate.primaryAnchor) &&
          (candidate.secondaryAnchor == null ||
              _isFiniteOffset(candidate.secondaryAnchor!))) {
        nativeAnchors = candidate;
      }
    } catch (_) {
      // Selection geometry can be between layout passes while virtualized
      // transcript children are mounting. The touch position is a safe
      // one-frame fallback and remains stable afterwards.
    }

    final Offset requested =
        _persistentSelectionToolbarAnchor ?? viewport.center;
    final Offset rawAbove =
        nativeAnchors?.primaryAnchor ?? requested - const Offset(0, 24);
    final Offset rawBelow =
        nativeAnchors?.secondaryAnchor ?? requested + const Offset(0, 24);
    final double horizontalInset = viewport.width < 32 ? 0 : 16;
    double clampX(double dx) => dx
        .clamp(
          viewport.left + horizontalInset,
          viewport.right - horizontalInset,
        )
        .toDouble();

    // Give the toolbar two genuinely different anchors. It is first laid out
    // above the first selected glyph; if that does not fit, it goes below the
    // last selected glyph. Using one anchor for both directions is what made
    // the old toolbar cover the selected word.
    return TextSelectionToolbarAnchors(
      primaryAnchor: Offset(clampX(rawAbove.dx), rawAbove.dy - 6),
      secondaryAnchor: Offset(clampX(rawBelow.dx), rawBelow.dy + 6),
    );
  }

  bool _isFiniteOffset(Offset value) => value.dx.isFinite && value.dy.isFinite;

  List<ContextMenuButtonItem> _buildReliableSelectionToolbarItems({
    required bool forTouch,
  }) {
    final List<ContextMenuButtonItem> items = <ContextMenuButtonItem>[];
    if (_selectedTranscriptText.isNotEmpty) {
      items.add(
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () => _copySelectedTranscript(forTouch: forTouch),
        ),
      );
    }
    items.add(
      ContextMenuButtonItem(
        type: ContextMenuButtonType.selectAll,
        onPressed: () {
          // Native desktop: Select all dismisses the menu, then Ctrl+C copies.
          _selectEntireTranscript(cause: SelectionChangedCause.toolbar);
          if (!forTouch) {
            _removeDesktopSelectionToolbar();
          }
        },
      ),
    );
    // Settings entry, not a copy action — always available on right-click.
    items.add(
      ContextMenuButtonItem(
        type: ContextMenuButtonType.custom,
        label: '格式',
        onPressed: () => _openCopyFormatPopover(forTouch: forTouch),
      ),
    );
    if (_selectedTranscriptText.isNotEmpty &&
        forTouch &&
        defaultTargetPlatform == TargetPlatform.android) {
      items.add(
        ContextMenuButtonItem(
          type: ContextMenuButtonType.share,
          onPressed: () {
            final String text = _formattedSelectedTranscriptText();
            if (text.isEmpty) return;
            unawaited(
              SystemChannels.platform.invokeMethod<void>('Share.invoke', text),
            );
            _removeCopyFormatPopover();
            clearTextSelection();
          },
        ),
      );
    }
    return items;
  }

  String _formattedSelectedTranscriptText() {
    return SubtitleCopyFormatter.format(
      selectedText: _selectedTranscriptText,
      cues: List<SubtitleCueCopyParts>.unmodifiable(_cueCopyPartsCache),
      format: SettingsService().subtitleCopyFormat,
    );
  }

  /// Live preview for the format popover. Uses the current selection when
  /// there is one; otherwise the first few cues so the panel still works as
  /// a settings entry from an empty right-click.
  String _copyFormatPreviewText() {
    if (_selectedTranscriptText.isNotEmpty) {
      return _formattedSelectedTranscriptText();
    }
    final List<SubtitleCueCopyParts> sample = _cueCopyPartsCache
        .take(3)
        .toList(growable: false);
    if (sample.isEmpty) return '';
    return SubtitleCopyFormatter.format(
      selectedText: SubtitleCopyFormatter.joinedDisplayText(sample),
      cues: sample,
      format: SettingsService().subtitleCopyFormat,
    );
  }

  @visibleForTesting
  String get formattedSelectedTranscriptText =>
      _formattedSelectedTranscriptText();

  void _copySelectedTranscript({
    required bool forTouch,
    bool fromShortcut = false,
  }) {
    final String text = _formattedSelectedTranscriptText();
    if (text.isEmpty) return;
    unawaited(
      Clipboard.setData(ClipboardData(text: text)).then((_) {
        if (mounted) unawaited(AppHaptics.lightTap(SettingsService()));
      }),
    );
    if (fromShortcut) return;
    _removeCopyFormatPopover();
    if (forTouch &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.fuchsia)) {
      clearTextSelection();
    } else if (!forTouch) {
      _removeDesktopSelectionToolbar();
    }
  }

  /// Ctrl/Cmd+A and Ctrl/Cmd+C/X, including a hardware keyboard on a phone.
  ///
  /// Player shortcuts ignore modifier chords, so these never reach the
  /// SelectionArea unless the page forwards them here. The SelectionArea's
  /// own select-all also cannot see unmounted virtualized cues.
  KeyEventResult handleTranscriptShortcut(KeyEvent event) {
    if (!mounted || !widget.isVisible) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final bool modifierPressed =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!modifierPressed || HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.keyA) {
      _selectEntireTranscript(cause: SelectionChangedCause.keyboard);
      return KeyEventResult.handled;
    }
    final bool isCopyKey =
        key == LogicalKeyboardKey.keyC ||
        key == LogicalKeyboardKey.keyX ||
        key == LogicalKeyboardKey.insert;
    if (isCopyKey) {
      if (_selectedTranscriptText.isEmpty) return KeyEventResult.ignored;
      _copySelectedTranscript(forTouch: false, fromShortcut: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _selectEntireTranscript({
    SelectionChangedCause cause = SelectionChangedCause.keyboard,
  }) {
    final String full = _canonicalTranscriptText;
    if (full.isEmpty) return;
    _fullTranscriptSelected = true;
    _selectedTranscriptText = full;
    if (_isMobileSelectionPlatform) {
      _usesPersistentTouchSelectionToolbar = true;
    }
    if (!_hasTextSelection) {
      setState(() => _hasTextSelection = true);
    } else {
      setState(() {});
    }
    _hideNativeSelectionToolbars();
    if (_usesPersistentTouchSelectionToolbar) {
      _schedulePersistentSelectionToolbar();
    }
    _cancelPendingAutoScroll();
    _invalidateLocateRequests();
    // Focus first so Flutter's visual selectAll has a primary focus. Defer
    // the visual pass a frame: the copy payload is already the full cache
    // and must not wait on mounted-row geometry.
    if (_textSelectionFocusNode.canRequestFocus) {
      _textSelectionFocusNode.requestFocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_fullTranscriptSelected) return;
      _textSelectionKey.currentState?.selectableRegion.selectAll(cause);
    });
  }

  void _persistCopyFormat(
    SubtitleCopyFormat format, {
    bool forceFeedback = false,
  }) {
    final current = SettingsService().subtitleCopyFormat;
    if (format == current) return;
    // Text input keeps the keyboard's feedback; option changes use a tick.
    if (forceFeedback || format.customSeparator == current.customSeparator) {
      unawaited(AppHaptics.selectionClick(SettingsService()));
    }
    unawaited(
      SettingsService().updateSetting(
        'subtitleCopyFormat',
        format.toJsonString(),
      ),
    );
  }

  Offset _copyFormatPopoverAnchor({required bool forTouch}) {
    if (forTouch) {
      return _persistentSelectionToolbarAnchors?.secondaryAnchor ??
          _persistentSelectionToolbarAnchor ??
          Offset.zero;
    }
    return _desktopSelectionToolbarAnchor ?? Offset.zero;
  }

  void _openCopyFormatPopover({required bool forTouch}) {
    if (_copyFormatPopoverEntry != null) {
      unawaited(AppHaptics.lightTap(SettingsService()));
      _removeCopyFormatPopover();
      return;
    }
    final Offset anchor = _copyFormatPopoverAnchor(forTouch: forTouch);
    if (!forTouch) {
      _removeDesktopSelectionToolbar();
    }
    if (!mounted || _copyFormatPopoverEntry != null) return;
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    unawaited(AppHaptics.lightTap(SettingsService()));
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) {
        if (!mounted) return const SizedBox.shrink();
        final bool canCopy = _selectedTranscriptText.isNotEmpty;
        return SizedBox.expand(
          child: SubtitleCopyFormatPopover(
            anchor: anchor,
            format: SettingsService().subtitleCopyFormat,
            previewText: _copyFormatPreviewText(),
            showBilingualOptions: _cueCopyPartsCache.any(
              (SubtitleCueCopyParts parts) => parts.hasSecondary,
            ),
            onFormatChanged: _persistCopyFormat,
            onCopy: canCopy
                ? () => _copySelectedTranscript(forTouch: forTouch)
                : null,
            onReset: () => _persistCopyFormat(
              SubtitleCopyFormat.defaults,
              forceFeedback: true,
            ),
          ),
        );
      },
    );
    _copyFormatPopoverEntry = entry;
    overlay.insert(entry);
  }

  void _removeCopyFormatPopover() {
    _copyFormatPopoverEntry?.remove();
    _copyFormatPopoverEntry?.dispose();
    _copyFormatPopoverEntry = null;
  }

  void _removePersistentSelectionToolbar() {
    _persistentSelectionToolbarInsertScheduled = false;
    _persistentSelectionToolbarEntry?.remove();
    _persistentSelectionToolbarEntry?.dispose();
    _persistentSelectionToolbarEntry = null;
    _usesPersistentTouchSelectionToolbar = false;
    _persistentSelectionToolbarAnchor = null;
    _persistentSelectionToolbarAnchors = null;
  }

  void _onTranscriptContextMenuPointer(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse &&
        event.kind != PointerDeviceKind.trackpad) {
      return;
    }
    if (event.buttons != kSecondaryMouseButton) return;
    _showDesktopSelectionToolbar(event.position);
  }

  void _showDesktopSelectionToolbar(Offset anchor) {
    if (_usesPersistentTouchSelectionToolbar) return;
    if (!_isFiniteOffset(anchor)) return;
    _removeCopyFormatPopover();
    _desktopSelectionToolbarAnchor = anchor;
    _hideNativeSelectionToolbars();
    if (_desktopSelectionToolbarEntry != null) {
      _desktopSelectionToolbarEntry!.markNeedsBuild();
      _scheduleHideNativeSelectionToolbars();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(
      builder: (BuildContext context) {
        if (!mounted ||
            _usesPersistentTouchSelectionToolbar ||
            _desktopSelectionToolbarAnchor == null) {
          return const SizedBox.shrink();
        }
        final Offset menuAnchor = _desktopSelectionToolbarAnchor!;
        if (!_isFiniteOffset(menuAnchor)) {
          return const SizedBox.shrink();
        }
        // Tap outside dismisses the menu without eating the click, so the
        // selection shield and list still receive it. Flutter's geometry
        // menu is never used — that path becomes ErrorWidget off-screen.
        return TapRegion(
          onTapOutside: (PointerDownEvent event) {
            if (event.buttons == kSecondaryMouseButton) return;
            _removeDesktopSelectionToolbar();
          },
          child: AdaptiveTextSelectionToolbar.buttonItems(
            anchors: TextSelectionToolbarAnchors(primaryAnchor: menuAnchor),
            buttonItems: _buildReliableSelectionToolbarItems(forTouch: false),
          ),
        );
      },
    );
    _desktopSelectionToolbarEntry = entry;
    overlay.insert(entry);
    _scheduleHideNativeSelectionToolbars();
  }

  void _scheduleHideNativeSelectionToolbars() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _desktopSelectionToolbarEntry == null) return;
      _hideNativeSelectionToolbars();
    });
  }

  void _hideNativeSelectionToolbars() {
    // Keep selection handles. The default hideToolbar() also drops handles,
    // which iOS needs in order to extend a selection after long-press.
    ContextMenuController.removeAny();
    _textSelectionKey.currentState?.selectableRegion.hideToolbar(false);
    context.visitAncestorElements((Element element) {
      if (element is StatefulElement) {
        final State<StatefulWidget> state = element.state;
        if (state is SelectableRegionState) {
          state.hideToolbar(false);
        } else if (state is SelectionAreaState) {
          state.selectableRegion.hideToolbar(false);
        }
      }
      return true;
    });
  }

  void _removeDesktopSelectionToolbar() {
    _desktopSelectionToolbarEntry?.remove();
    _desktopSelectionToolbarEntry?.dispose();
    _desktopSelectionToolbarEntry = null;
    _desktopSelectionToolbarAnchor = null;
  }

  void _startSelectionPreservingPan(DragStartDetails details) {
    _stopTouchSelectionEdgeScroll();
    _cancelPendingAutoScroll();
    // Desktop context menus dismiss on scroll. Do not hand the menu back to
    // Flutter's endpoint-anchored toolbar — that is the ErrorWidget path.
    _removeDesktopSelectionToolbar();
    _hideNativeSelectionToolbars();
    _selectionPreservingPanDrag?.cancel();
    final ScrollableState? scrollable = _selectionScrollable;
    if (scrollable == null || !scrollable.mounted) return;
    try {
      _selectionPreservingPanDrag = scrollable.position.drag(details, () {
        _selectionPreservingPanDrag = null;
      });
    } catch (_) {
      _selectionPreservingPanDrag = null;
    }
  }

  void _updateSelectionPreservingPan(DragUpdateDetails details) {
    _selectionPreservingPanDrag?.update(details);
  }

  void _endSelectionPreservingPan(DragEndDetails details) {
    final Drag? drag = _selectionPreservingPanDrag;
    _selectionPreservingPanDrag = null;
    drag?.end(details);
  }

  void _cancelSelectionPreservingPan() {
    final Drag? drag = _selectionPreservingPanDrag;
    _selectionPreservingPanDrag = null;
    drag?.cancel();
  }

  Widget _buildSelectionPreservingScrollShield() {
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerSignal: (PointerSignalEvent event) {
          if (event is! PointerScrollEvent) return;
          final ScrollableState? scrollable = _selectionScrollable;
          if (scrollable == null || !scrollable.mounted) return;
          _removeDesktopSelectionToolbar();
          _hideNativeSelectionToolbars();
          scrollable.position.pointerScroll(event.scrollDelta.dy);
        },
        child: GestureDetector(
          key: const ValueKey('subtitle-selection-scroll-shield'),
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails details) {
            _selectionShieldTapDownPosition = details.globalPosition;
          },
          onTapUp: (TapUpDetails details) {
            final Offset? down = _selectionShieldTapDownPosition;
            _selectionShieldTapDownPosition = null;
            if (down == null ||
                (details.globalPosition - down).distance >
                    _selectionDismissTapSlop) {
              return;
            }
            clearTextSelection();
            widget.onClearSelection?.call();
            widget.focusNode?.requestFocus();
          },
          onTapCancel: () => _selectionShieldTapDownPosition = null,
          onSecondaryTapDown: (TapDownDetails details) {
            _selectionShieldTapDownPosition = null;
            _showDesktopSelectionToolbar(details.globalPosition);
          },
          onVerticalDragStart: _startSelectionPreservingPan,
          onVerticalDragUpdate: _updateSelectionPreservingPan,
          onVerticalDragEnd: _endSelectionPreservingPan,
          onVerticalDragCancel: _cancelSelectionPreservingPan,
        ),
      ),
    );
  }

  void _ensureTimelineResolver() {
    final subtitles = _displaySubtitles;
    if (_timelineResolverSubtitles != subtitles) {
      _rebuildTimelineResolver();
    }
  }

  List<int> _activeIndicesAtMs(int posMs) {
    _ensureTimelineResolver();
    final resolver = _timelineResolver;
    if (resolver == null || resolver.isEmpty) return const <int>[];
    // 文稿高亮是阅读光标：上一句保持点亮直到下一句开始。
    // 画面字幕的「连续显示」开关独立控制悬浮字幕，不影响文稿阅读。
    return _readingCueWindow.activeIndicesAtMs(
      resolver,
      _displaySubtitles,
      posMs,
    );
  }

  /// 空档沿用前一句作为定位落点，首句之前落在首句、末句之后落在末句。
  /// 这个索引只用于滚动；首句前、末句后的落点不代表该句需要高亮。
  int _locateIndexAtMs(int posMs, List<int> activeIndices) {
    _ensureTimelineResolver();
    final resolver = _timelineResolver;
    if (resolver == null || resolver.isEmpty) return -1;
    if (activeIndices.isNotEmpty) return activeIndices.first;
    return (resolver.firstStartAfterMs(posMs) - 1).clamp(
      0,
      resolver.length - 1,
    );
  }

  /// 暂停时播放位置不再变化，调整「字幕同步」不会触发 controller 回调；
  /// 这里主动重算一次高亮，避免侧边栏停留在换算前的索引。
  void _handleSubtitleOffsetChanged() {
    _copyFormatPopoverEntry?.markNeedsBuild();
    final settings = SettingsService();
    final bool nextParagraphMode = settings.subtitleArticleParagraphModeEnabled;
    if (nextParagraphMode != _articleParagraphModeEnabled && mounted) {
      _clearTextSelection(resumeAutoFollow: false);
      setState(() {
        _articleParagraphModeEnabled = nextParagraphMode;
        if (!_isContinuousArticleMode) _pauseContinuousArticleLayout();
      });
      _triggerLocateButtonAfterModeSwitch();
    }
    final int offsetMs = settings.subtitleOffset.inMilliseconds;
    if (offsetMs == _lastSubtitleOffsetMs) return;
    _lastSubtitleOffsetMs = offsetMs;
    if (!mounted) return;
    _updateIndex();
  }

  void _rebuildContinuousArticleDocument() {
    // List/paragraph mode needs only the mounted cues. In particular, opening
    // a 10,000-cue list must not normalize and concatenate the entire article.
    _continuousArticleDocumentDirty = true;
    _continuousArticleDocumentAppendPending = false;
    _continuousArticleDocumentRequestId++;
    _continuousArticleDocumentFuture = null;
    _pauseContinuousArticleLayout();
    if (_continuousArticleDocument != null && _isContinuousArticleMode) {
      // An already presented document needs an immediate body comparison:
      // unchanged text keeps its layout; replaced text cannot paint stale cues.
      // Cold preparation is deferred below, and streamed appends reuse the
      // existing prefix rather than taking this replacement path.
      _acceptContinuousArticleDocument(
        ArticleDocument.fromDisplayTexts(
          generation: ++_articleDocumentGeneration,
          displayTexts: _selectionTextCache,
          sentenceSeparator: ' ',
          imageSubtitleFlags: TranscriptTextCache<bool>(
            length: _displaySubtitles.length,
            resolve: (index) => _displaySubtitles[index].imageLoader != null,
          ),
        ),
      );
    }
  }

  void _ensureContinuousArticleDocument() {
    if (!_continuousArticleDocumentDirty ||
        _continuousArticleDocumentFuture != null ||
        !_continuousArticleLayoutAllowed) {
      return;
    }
    final texts = _selectionTextCache;
    final subtitles = _displaySubtitles;
    final images = TranscriptTextCache<bool>(
      length: subtitles.length,
      resolve: (index) => subtitles[index].imageLoader != null,
    );
    final generation = ++_articleDocumentGeneration;
    final prefix = _continuousArticleDocumentAppendPending
        ? _continuousArticleDocument
        : null;
    if (texts.length <= 128) {
      _acceptContinuousArticleDocument(
        ArticleDocument.fromDisplayTexts(
          generation: generation,
          displayTexts: texts,
          sentenceSeparator: ' ',
          imageSubtitleFlags: images,
        ),
      );
      return;
    }
    final request = ++_continuousArticleDocumentRequestId;
    _continuousArticleDocumentFuture = () async {
      final next = await ArticleDocument.fromDisplayTextsIncrementally(
        generation: generation,
        displayTexts: texts,
        sentenceSeparator: ' ',
        imageSubtitleFlags: images,
        isCancelled: () =>
            !mounted ||
            request != _continuousArticleDocumentRequestId ||
            !_continuousArticleLayoutAllowed,
        isInteracting: () => UiInteractionBudget.instance.isActive,
        appendTo: prefix,
      );
      if (!mounted || request != _continuousArticleDocumentRequestId) return;
      _continuousArticleDocumentFuture = null;
      if (next != null) {
        setState(() {
          _acceptContinuousArticleDocument(next, appended: prefix != null);
          if (_selectionTextCache.length > next.sentences.length) {
            _continuousArticleDocumentDirty = true;
            _continuousArticleDocumentAppendPending = true;
          }
        });
      } else if (_continuousArticleLayoutAllowed) {
        // A hidden-and-reopened panel may have cancelled the previous batch.
        setState(() {});
      }
    }();
  }

  void _acceptContinuousArticleDocument(
    ArticleDocument next, {
    bool appended = false,
  }) {
    final previous = _continuousArticleDocument;
    _continuousArticleDocument = next;
    _continuousArticleDocumentDirty = false;
    _continuousArticleDocumentAppendPending = false;
    if (previous == null) return;
    if (appended) {
      _continuousArticleIsAppend = true;
      return;
    }
    if (previous.hasSameBody(next)) {
      _retargetContinuousArticleLayouts(next.generation);
    } else {
      _invalidateContinuousArticleLayout();
    }
  }

  void _updateIndex() {
    // Offstage playback pages retain their timeline and reading position.
    // Sample the latest clock once when their viewport becomes visible again.
    if (!_visualTicksEnabled) return;
    final subtitles = _displaySubtitles;
    if (!mounted || subtitles.isEmpty) return;

    final bool isPlaying = _playbackIsPlaying;
    final bool playbackStateChanged = isPlaying != _lastKnownIsPlaying;
    _lastKnownIsPlaying = isPlaying;
    final int posMs = _subtitleTimelinePositionMs;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    // 高亮必须跟悬浮字幕用同一帧播放位置切句。按 80ms 节流会跨过句界，
    // 侧栏会比画面晚一拍；解析器查询本身很便宜，不必为省这一点而延迟。
    final List<int> activeIndices = _activeIndicesAtMs(posMs);
    final int timelineIndex = _locateIndexAtMs(posMs, activeIndices);
    final bool hasManualAnimationFreeze = _hasManualAnimationFreeze(nowMs);
    final int? manualAnimationFreezeIndex = _manualAnimationFreezeIndex;
    if (hasManualAnimationFreeze &&
        manualAnimationFreezeIndex != null &&
        manualAnimationFreezeIndex >= 0 &&
        manualAnimationFreezeIndex < subtitles.length) {
      if (_activeIndexNotifier.value != manualAnimationFreezeIndex) {
        _activeIndexNotifier.value = manualAnimationFreezeIndex;
      }
      final List<int> frozenActiveIndices =
          timelineIndex == manualAnimationFreezeIndex ||
              activeIndices.contains(manualAnimationFreezeIndex)
          ? activeIndices
          : _manualLocateActiveIndices;
      if (!_isSameIndices(frozenActiveIndices, _activeIndicesNotifier.value)) {
        _activeIndicesNotifier.value = frozenActiveIndices;
      }
      return;
    }
    final bool hasManualLocateLock = _hasManualLocateLock(nowMs);
    final int? manualLocateLockIndex = _manualLocateLockIndex;
    if (hasManualLocateLock &&
        manualLocateLockIndex != null &&
        !activeIndices.contains(manualLocateLockIndex) &&
        manualLocateLockIndex != timelineIndex) {
      if (_activeIndexNotifier.value != manualLocateLockIndex) {
        _activeIndexNotifier.value = manualLocateLockIndex;
      }
      final List<int> lockedActiveIndices = _manualLocateActiveIndices;
      if (!_isSameIndices(lockedActiveIndices, _activeIndicesNotifier.value)) {
        _activeIndicesNotifier.value = lockedActiveIndices;
      }
      return;
    }
    if (hasManualLocateLock) {
      _clearManualLocateLock();
    }
    int index = timelineIndex;
    final int? pendingIndex = _pendingLocateIndex;
    if (pendingIndex != null && activeIndices.contains(pendingIndex)) {
      index = pendingIndex;
    }
    final bool suppressAutoScrollForIndex =
        index >= 0 && _shouldSuppressAutoScrollForIndex(index);
    if (index >= 0 && index == _pendingLocateIndex) {
      _pendingLocateIndex = null;
    }
    if (suppressAutoScrollForIndex) {
      _clearAutoScrollSuppression();
    }
    final bool activeIndicesChanged = !_isSameIndices(
      activeIndices,
      _activeIndicesNotifier.value,
    );
    if (activeIndicesChanged) {
      _activeIndicesNotifier.value = activeIndices;
    }

    final bool indexChanged = index != _activeIndexNotifier.value;
    if (indexChanged) {
      _activeIndexNotifier.value = index;
    }

    final bool isInManualLocateAutoFollowCooldown =
        _isInManualLocateAutoFollowCooldown(nowMs);
    if ((indexChanged ||
            playbackStateChanged ||
            activeIndicesChanged ||
            _autoFollowDeferred) &&
        isPlaying &&
        widget.isVisible &&
        _isSubtitleSidebarRouteCurrent &&
        SettingsService().autoScrollSubtitles &&
        !suppressAutoScrollForIndex &&
        !_selectionBlocksAutoFollow) {
      // A short cue can finish while the manual locate owns the viewport.
      // Remember that follow was deferred; otherwise no later tick schedules
      // it until another cue changes, even after the cooldown has expired.
      if (isInManualLocateAutoFollowCooldown) {
        _autoFollowDeferred = true;
      } else {
        _autoFollowDeferred = false;
        _scheduleAutoScroll();
      }
    }
  }

  void locateToTime(
    Duration target, {
    int? preferredIndex,
    bool animated = true,
    bool preferSingleStage = true,
  }) {
    if (!mounted) return;
    if (!widget.isVisible) return;
    final subtitles = _displaySubtitles;
    if (subtitles.isEmpty) return;

    // 调用方传入的是视频时间（用于 seek），先换算到字幕时间轴再定位。
    final int posMs = target.inMilliseconds - _subtitleOffsetMs;
    final List<int> activeIndices = _activeIndicesAtMs(posMs);
    int index = _locateIndexAtMs(posMs, activeIndices);
    if (preferredIndex != null &&
        preferredIndex >= 0 &&
        preferredIndex < subtitles.length) {
      index = preferredIndex;
    }
    if (index < 0 || index >= subtitles.length) return;

    final momentum = animated ? _captureReadingMomentum() : null;
    _invalidateLocateRequests(preserveDissolve: animated);
    _cancelPendingAutoScroll();
    _pendingLocateIndex = index;
    _markManualLocateLock(index, activeIndices: activeIndices);
    _markManualLocateAutoFollowCooldown();
    _markManualAnimationFreeze(index, animated: animated);
    _activeIndexNotifier.value = index;
    if (!_isSameIndices(activeIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = activeIndices;
    }
    _markAutoScrollSuppressedForIndex(index);
    if (animated) {
      // Keep preferSingleStage in the public API for existing callers. Every
      // animated locate now uses one live viewport, including distant targets.
      _scrollToIndex(index, isAuto: false, momentum: momentum);
    } else {
      _jumpToActiveIndexWithAlignment(index);
    }
  }

  bool _isSameIndices(List<int> next, List<int> prev) {
    if (next.length != prev.length) return false;
    for (int i = 0; i < next.length; i++) {
      if (next[i] != prev[i]) return false;
    }
    return true;
  }

  void _scheduleAutoScroll() {
    _autoScrollTimer?.cancel();
    final int requestId = ++_autoScrollRequestId;
    _autoScrollTimer = Timer(Duration.zero, () {
      if (!mounted) return;
      if (_selectionBlocksAutoFollow) return;
      if (!_isSubtitleSidebarRouteCurrent) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_selectionBlocksAutoFollow) return;
        if (requestId != _autoScrollRequestId) return;
        if (!_isSubtitleSidebarRouteCurrent) return;
        _scrollToActiveIndex(isAuto: true);
      });
      _ensureFrameScheduled();
    });
  }

  void triggerLocateForAutoFollow({bool animated = false}) {
    if (!mounted) return;
    if (!widget.isVisible || !SettingsService().autoScrollSubtitles) return;
    if (_selectionBlocksAutoFollow) return;
    if (_displaySubtitles.isEmpty) return;
    if (!_playbackIsPlaying) return;
    if (!_isSubtitleSidebarRouteCurrent) return;
    _ensureTimelineResolver();

    _beginLocateRequest(animated: animated, repair: false);
  }

  void _triggerLocateButtonAfterModeSwitch() {
    if (!mounted) return;
    if (!widget.isVisible) return;
    if (_selectionBlocksAutoFollow) return;
    if (_displaySubtitles.isEmpty) return;
    final locateRequestId = _locateRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || locateRequestId != _locateRequestId) return;
      // ItemPositionsListener publishes the geometry from a rebuilt row one
      // frame after the row itself. Waiting for that fresh snapshot prevents
      // a line-height or view-mode change from being positioned with stale
      // pre-switch bounds.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || locateRequestId != _locateRequestId) return;
        _beginLocateRequest(animated: false, repair: true, immediate: true);
      });
      _ensureFrameScheduled();
    });
    _ensureFrameScheduled();
  }

  void _updateArticleChunkSize(int value) {
    final int nextValue = value.clamp(
      _minArticleChunkSize,
      _maxArticleChunkSize,
    );
    if (nextValue == _articleChunkSize) return;
    unawaited(AppHaptics.selectionClick(SettingsService()));

    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    _clearTextSelection(resumeAutoFollow: false);
    setState(() => _articleChunkSize = nextValue);
    SettingsService().updateSetting(
      'subtitleArticleSentencesPerParagraph',
      nextValue,
    );
    _triggerLocateButtonAfterModeSwitch();
  }

  void _updateArticleParagraphMode(bool enabled) {
    if (enabled == _articleParagraphModeEnabled) return;
    unawaited(AppHaptics.selectionClick(SettingsService()));
    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    setState(() {
      _articleParagraphModeEnabled = enabled;
      if (!_isContinuousArticleMode) _pauseContinuousArticleLayout();
    });
    SettingsService().updateSetting(
      'subtitleArticleParagraphModeEnabled',
      enabled,
    );
    _triggerLocateButtonAfterModeSwitch();
  }

  void _updateLocatePositionPercent(int value) {
    final int nextValue = _clampLocatePositionPercent(value);
    if (nextValue == _locatePositionPercent) return;
    unawaited(AppHaptics.selectionClick(SettingsService()));

    setState(() => _locatePositionPercent = nextValue);
    final key = widget.isPortrait
        ? 'portraitSidebarLocatePositionPercent'
        : 'landscapeSidebarLocatePositionPercent';
    SettingsService().updateSetting(key, nextValue);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToActiveIndex();
    });
  }

  /// 暴露给外部页面（如从横屏/音乐播放页切换回视频播放页）的定位方法。
  ///
  /// 与 [triggerLocateForAutoFollow] 不同，本方法不依赖 autoScrollSubtitles
  /// 开关，也不要求当前正在播放，只要字幕文稿区可见即执行定位。
  /// 用于在页面切换完成后将字幕文稿滚动到当前播放位置对应的字幕，
  /// 同时修复切回页面时列表偶发空白（滚动控制器暂未重新挂载）的问题。
  ///
  /// 返回 false 表示本次请求暂时无法受理（面板不可见、无字幕、指针仍按下），
  /// 调用方可以稍后重试；返回 true 表示已受理，列表一旦完成布局就会落地，
  /// 且落地后会自动校验，必要时再补一次跳转。
  bool locateToCurrentSubtitle({
    bool animated = false,
    bool ignorePointer = false,
  }) {
    if (!mounted) return false;
    if (!widget.isVisible) return false;
    // 页面切换完成后的自动定位属于「显式请求」，即便切页瞬间仍有一个活动的指针
    // （例如点击返回键抬起前的那一帧）也应执行定位；此时由调用方传入 ignorePointer=true。
    if (_hasTextSelection) return false;
    if (!ignorePointer && _hasAnyActivePointer) return false;
    if (_displaySubtitles.isEmpty) return false;
    _ensureTimelineResolver();
    // 修复定位必须压过自动跟随：先取消待执行的自动滚动并进入冷却时间，
    // 否则自动跟随的动画会在修复跳转之后落地，把文稿又拖回旧位置。
    _cancelPendingAutoScroll();
    _markManualLocateAutoFollowCooldown();
    _beginLocateRequest(animated: animated, repair: true);
    return true;
  }

  /// 登记一次定位请求。只有最新请求会落地，旧请求的延迟回调会因请求号变化失效。
  ///
  /// [immediate] 用于调用方已经等过一帧（例如视图模式切换）的场景，直接在
  /// 当前回调里尝试落地，避免多引入一帧的位置漂移。
  void _beginLocateRequest({
    required bool animated,
    required bool repair,
    bool keepVerificationBudget = false,
    bool immediate = false,
  }) {
    if (_hasTextSelection) return;
    _cancelReadingMotion(cancelDissolve: !animated);
    final int requestId = ++_locateRequestId;
    _locateAttempts = 0;
    _locateAnimated = animated;
    _locateIsRepair = repair;
    _locateVerificationScheduled = false;
    if (!keepVerificationBudget) {
      _locateVerificationRounds = 0;
    }
    if (repair) {
      _repairRequestPending = true;
    }
    if (immediate) {
      _driveLocateRequest(requestId);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _driveLocateRequest(requestId);
    });
    _ensureFrameScheduled();
  }

  /// post-frame 回调只有在「有帧被调度」时才会执行。播放暂停或界面静止时
  /// （例如横屏退出后停在暂停状态）没有任何东西会调度帧，仅注册回调会让
  /// 修复定位悬空、文稿停留在切页时的空白状态。这里显式确保下一帧会发生。
  void _ensureFrameScheduled() {
    if (!mounted) return;
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// 手动操作（点击字幕、时间轴定位等）会接管定位：作废所有在途请求，
  /// 避免自动补位把用户的选择覆盖掉。
  void _invalidateLocateRequests({bool preserveDissolve = false}) {
    _cancelReadingMotion(cancelDissolve: !preserveDissolve);
    _cancelReadingReveal();
    _locateRequestId++;
    _repairRequestPending = false;
    _locateVerificationScheduled = false;
  }

  Iterable<ItemPosition> _currentItemPositions() {
    final positions = _isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
    final count = _isArticleMode ? _articleItemCount : _displaySubtitles.length;
    return positions.where((position) => position.index < count);
  }

  /// The public indexed-list listener only includes visible items. A recently
  /// hidden cue can still be laid out in its cache, with precise reachable
  /// bounds. Read the requested live box instead of jumping and letting physics
  /// spring an invalid anchor back into range at the start/end of the document.
  Iterable<ItemPosition> _readingMotionPositions(int targetIndex) {
    final positions = <int, ItemPosition>{
      for (final item in _currentItemPositions()) item.index: item,
    };
    final scrollable = _selectionScrollable;
    if (scrollable == null || !scrollable.mounted) return positions.values;
    final position = scrollable.position;
    if (!position.hasPixels || !position.hasViewportDimension) {
      return positions.values;
    }
    final extent = position.viewportDimension;
    if (extent <= _collapsedViewportHeight) return positions.values;
    final wanted = <int>{targetIndex};
    void visit(RenderObject object) {
      if (object is RenderOffstage && object.offstage) return;
      if (object is RenderIndexedSemantics &&
          wanted.contains(object.index) &&
          object.hasSize) {
        final viewport = RenderAbstractViewport.maybeOf(object);
        if (viewport != null) {
          final anchor = viewport is RenderViewport ? viewport.anchor : 0.0;
          final leading =
              viewport.getOffsetToReveal(object, 0).offset -
              position.pixels +
              anchor * extent;
          if (leading.isFinite) {
            positions[object.index] = ItemPosition(
              index: object.index,
              itemLeadingEdge: leading / extent,
              itemTrailingEdge: (leading + object.size.height) / extent,
            );
            wanted.remove(object.index);
          }
        }
        return;
      }
      if (object is! RenderIndexedSemantics && wanted.isNotEmpty) {
        object.visitChildren(visit);
      }
    }

    scrollable.context.findRenderObject()?.visitChildren(visit);
    return positions.values;
  }

  int _articleItemIndexForSubtitle(int subtitleIndex) {
    if (_isContinuousArticleMode) {
      return _continuousArticleLayout?.lineForSentence(subtitleIndex) ?? -1;
    }
    return subtitleIndex ~/ _articleChunkSize;
  }

  int get _articleItemCount {
    if (_isContinuousArticleMode) {
      return _continuousArticleLayout?.lines.length ?? 0;
    }
    return (_displaySubtitles.length / _articleChunkSize).ceil();
  }

  /// 列表是否已经产出可用的几何信息。控制器未挂载或没有任何可见行时，
  /// 任何 jump/scroll 都会被直接丢弃（这正是切页后文稿空白的形态）。
  bool _hasLocateGeometry() {
    final bool attached = _isArticleMode
        ? _articleItemScrollController.isAttached
        : _itemScrollController.isAttached;
    if (!attached) return false;
    return _currentItemPositions().isNotEmpty;
  }

  /// 视口是否具有可用高度（切页瞬间面板可能被压缩为 0，此时无法定位）。
  bool _isScrollableViewportUsable() {
    final Size? size = _lastScrollableViewportSize;
    return size == null || size.height > _collapsedViewportHeight;
  }

  bool get _hasTranscriptScrollRange {
    final scrollable = _selectionScrollable;
    if (scrollable == null || !scrollable.mounted) return true;
    final position = scrollable.position;
    return !position.hasContentDimensions ||
        position.maxScrollExtent - position.minScrollExtent >
            precisionErrorTolerance;
  }

  void _driveLocateRequest(int requestId) {
    if (!mounted || requestId != _locateRequestId) return;
    if (!widget.isVisible || _displaySubtitles.isEmpty) {
      _repairRequestPending = false;
      return;
    }
    // 被不透明路由覆盖时列表不参与布局，滚动会被丢弃；保持请求挂起，
    // 回到前台（didChangeDependencies）或视口变化时会重新驱动。
    if (!_isSubtitleSidebarRouteCurrent) return;
    if (!_locateIsRepair &&
        (!_playbackIsPlaying || !SettingsService().autoScrollSubtitles)) {
      return;
    }

    if (!_hasLocateGeometry() || !_isScrollableViewportUsable()) {
      // 视口被压缩时不再空转重试，交给视口尺寸变化重新驱动。
      if (_isScrollableViewportUsable() &&
          _locateAttempts < _maxLocateAttempts) {
        _locateAttempts++;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _driveLocateRequest(requestId);
        });
        _ensureFrameScheduled();
      }
      return;
    }

    _ensureTimelineResolver();
    _applyLocateRequest();
    if (_locateIsRepair) {
      _repairRequestPending = false;
    }
    _scheduleLocateVerification(requestId);
  }

  void _applyLocateRequest() {
    final int posMs = _subtitleTimelinePositionMs;
    final List<int> activeIndices = _activeIndicesAtMs(posMs);
    final int targetIndex = _locateIndexAtMs(posMs, activeIndices);
    if (targetIndex < 0 || targetIndex >= _displaySubtitles.length) return;
    _pendingLocateIndex = null;
    _clearManualLocateLock();
    _markManualAnimationFreeze(targetIndex, animated: false);
    _clearAutoScrollSuppression();
    if (!_isSameIndices(activeIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = activeIndices;
    }

    _activeIndexNotifier.value = targetIndex;
    if (_locateAnimated) {
      _scrollToActiveIndex();
    } else {
      _jumpToActiveIndexWithAlignment(
        targetIndex,
        forceReanchor: _locateIsRepair,
      );
    }
  }

  /// 落地后校验：列表已挂载、视口高度正常，但一帧后仍然没有任何可见行，
  /// 说明这次定位没有真正生效（例如列表刚刚重建，或修复跳转被挂起的自动
  /// 跟随动画覆盖）。此时再补一次跳转，确保文稿不会停在空白状态。
  void _scheduleLocateVerification(int requestId) {
    if (_locateVerificationScheduled) return;
    if (_locateVerificationRounds >= _maxLocateVerificationRounds) return;
    _locateVerificationScheduled = true;
    final int round = ++_locateVerificationRounds;
    _waitFramesThenVerify(requestId, round == 1 ? 2 : 10);
  }

  void _waitFramesThenVerify(int requestId, int framesLeft) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || requestId != _locateRequestId) return;
      _ensureFrameScheduled();
      if (framesLeft > 1) {
        _waitFramesThenVerify(requestId, framesLeft - 1);
        return;
      }
      _locateVerificationScheduled = false;
      if (!widget.isVisible || _displaySubtitles.isEmpty) return;
      if (!_isSubtitleSidebarRouteCurrent) return;
      if (!_isScrollableViewportUsable()) return;
      if (_currentItemPositions().isNotEmpty) return;
      // 列表仍然没有任何可见行：再补一次修复跳转（沿用本轮校验预算，
      // 避免与持续空白互相触发造成死循环）。
      _beginLocateRequest(
        animated: false,
        repair: true,
        keepVerificationBudget: true,
      );
    });
  }

  /// 字幕列表区（不含顶部工具栏）的指针登记。
  ///
  /// 命中测试结果自内向外派发，本回调一定早于外层的 [_onPointerDown]，
  /// 因此 [_onPointerDown] 建记录时可以直接读到这里写下的结果。
  void _onListAreaPointerDown(PointerDownEvent event) {
    _listAreaPointerIds.add(event.pointer);
    final int? rowIndex = _resolveRowIndexAt(event.position);
    if (rowIndex != null) {
      _pendingRowIndexByPointer[event.pointer] = rowIndex;
    }
  }

  /// 把全局坐标反查成字幕行号；落在行间空隙或列表之外时返回 null。
  ///
  /// [ItemPosition] 的 leading/trailing edge 是相对视口主轴长度的比例，所以
  /// 先把坐标换算进 [_listViewportKey] 对应的视口，再按比例查表。
  int? _resolveRowIndexAt(Offset globalPosition) {
    final RenderObject? object = _listViewportKey.currentContext
        ?.findRenderObject();
    if (object is! RenderBox || !object.hasSize) return null;
    final Size size = object.size;
    if (size.height <= 0) return null;
    final Offset local = object.globalToLocal(globalPosition);
    if (!(Offset.zero & size).contains(local)) return null;

    final double fraction = local.dy / size.height;
    int? targetIndex;
    for (final ItemPosition position in _currentItemPositions()) {
      if (fraction >= position.itemLeadingEdge &&
          fraction < position.itemTrailingEdge) {
        targetIndex = position.index;
        break;
      }
    }
    if (targetIndex == null) return null;

    if (!_isArticleMode) {
      return targetIndex >= 0 && targetIndex < _displaySubtitles.length
          ? targetIndex
          : null;
    }
    if (_isContinuousArticleMode) {
      return _continuousArticleViewKey.currentState
          ?.subtitleIndexAtGlobalPosition(globalPosition, targetIndex);
    }
    // 文章模式一个 item 是一整段，还要再问段落自己命中了段内哪一句。
    final State<SubtitleArticleChunk>? chunkState =
        _articleChunkKeys[targetIndex]?.currentState;
    if (chunkState is! _SubtitleArticleChunkState) return null;
    return chunkState.subtitleIndexAtGlobalPosition(globalPosition);
  }

  void _onPointerDown(PointerDownEvent event) {
    final interruptedFrame =
        !_readingViewportReady ||
        (_viewportMotionKey.currentState?.obscuresLiveText ?? false);
    final momentum = _activePointerCount == 0
        ? _captureReadingMomentum()
        : null;
    _invalidateLocateRequests();
    if (_activePointerCount == 0) {
      _pointerSessionStartedWithTextSelection = _hasTextSelection;
      _didScrollWhilePointerSession = false;
      _didDoubleTapSeekWhilePointerSession = false;
      _pointerDownStartIndex = _activeIndexNotifier.value;
      _pointerDownSubtitleIndex = null;
      _pendingDragDoubleTap = null;
      _suppressedRowTapIndex = null;
    }
    _recentlyLiftedSecondaryTap = null;
    _lastLiftedPointer = null;
    _lastLiftedHeldMs = 0;
    _activePointerCount++;
    _updateReadingInteraction();
    _pointerRecords[event.pointer] = _SidebarPointerRecord(
      downPosition: event.position,
      downTimeMs: event.timeStamp.inMilliseconds,
      kind: event.kind,
      inListArea: _listAreaPointerIds.contains(event.pointer),
      anchorPointerIds: _currentListAreaAnchorIds(event.pointer),
      rowIndex: _pendingRowIndexByPointer.remove(event.pointer),
      interruptedViewportMotion: interruptedFrame,
      readingMomentum: momentum,
    );
    _cancelPendingAutoScroll();
  }

  /// 本指针按下瞬间，列表区内已经按住的其他指针 id。
  /// 非空即表示它是一次「拖拽会话中的副指针」。
  Set<int> _currentListAreaAnchorIds(int selfPointer) {
    return _pointerRecords.keys
        .where(
          (int id) => id != selfPointer && _listAreaPointerIds.contains(id),
        )
        .toSet();
  }

  void _onPointerMove(PointerMoveEvent event) {
    final _SidebarPointerRecord? record = _pointerRecords[event.pointer];
    if (record == null) return;
    // 累计「离落点的最远距离」而不是逐帧位移：来回抖动同样会被正确放大，
    // 避免手指画圈却被当成原地轻点。
    final double travel = (event.position - record.downPosition).distance;
    if (travel > record.maxTravel) record.maxTravel = travel;
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    final _SidebarPointerRecord? record = _pointerRecords.remove(event.pointer);
    _listAreaPointerIds.remove(event.pointer);
    // PointerCancel 表示手势被系统/上层接管（来电浮层、返回手势等），
    // 绝不能当成一次有效轻点。
    _recentlyLiftedSecondaryTap = null;
    _pendingRowIndexByPointer.remove(event.pointer);
    // 先记下这次抬起的位移/时长，再交给随后才会裁决的 onTap 去核对。
    // PointerCancel 不能当单击：手势被系统接管时绝不能 seek。
    if (record != null && event is PointerUpEvent) {
      _lastLiftedPointer = record;
      _lastLiftedHeldMs = event.timeStamp.inMilliseconds - record.downTimeMs;
    } else {
      _lastLiftedPointer = null;
      _lastLiftedHeldMs = 0;
    }
    if (record != null &&
        event is PointerUpEvent &&
        _isDragDoubleTapCandidate(record, event)) {
      // 留给随后才会裁决出的 onTap 认领，见 [_shouldDeferRowTap]。
      _recentlyLiftedSecondaryTap = record;
      _evaluateDragDoubleTap(record, event.timeStamp.inMilliseconds);
    }
    _activePointerCount--;
    if (_activePointerCount < 0) _activePointerCount = 0;
    _updateReadingInteraction();
    if (_activePointerCount == 0) {
      // 兜底清理：极端情况下（如事件在路由切换中丢失）残留的记录会让下一次
      // 单指点击被误判成副指针，这里按会话边界强制归零。
      _pointerRecords.clear();
      _listAreaPointerIds.clear();
      _pendingRowIndexByPointer.clear();
      final bool shouldAnimateRelocate = _didScrollWhilePointerSession;
      final bool didDoubleTapSeek = _didDoubleTapSeekWhilePointerSession;
      final int? pointerDownStartIndex = _pointerDownStartIndex;
      final int? tappedSubtitleIndex = _pointerDownSubtitleIndex;
      final int currentIndex = _activeIndexNotifier.value;
      _didScrollWhilePointerSession = false;
      _didDoubleTapSeekWhilePointerSession = false;
      _pointerDownStartIndex = null;
      _pointerDownSubtitleIndex = null;
      _pendingDragDoubleTap = null;
      _suppressedRowTapIndex = null;
      if (didDoubleTapSeek) {
        // 拖拽期间的双击只做了 seek，定位被刻意推迟到这一刻。
        // 目标是「此刻的当前句」（媒体可能已经从双击那句继续播了过去），
        // 由 locateToCurrentSubtitle 按实时播放位置解析，而不是记住双击行号。
        // 用它而不是 triggerLocateForAutoFollow：双击是显式意图，暂停时也该
        // 对齐，只保留「自动跟随开关」这一层约束。
        if (SettingsService().autoScrollSubtitles) {
          final now = DateTime.now().millisecondsSinceEpoch;
          final target = _manualLocateLockIndex;
          final active = _activeIndicesAtMs(_subtitleTimelinePositionMs);
          final current = _locateIndexAtMs(_subtitleTimelinePositionMs, active);
          if (_hasManualLocateLock(now) &&
              target != null &&
              target >= 0 &&
              target < _displaySubtitles.length &&
              target != current &&
              !active.contains(target)) {
            // Native seek may still be reporting the pre-double-tap clock.
            // Preserve that explicit target until it lands; after the clock
            // catches up the lock is cleared and a later release uses real time.
            locateToTime(
              _displaySubtitles[target].startTime +
                  Duration(milliseconds: _subtitleOffsetMs),
              preferredIndex: target,
            );
          } else {
            locateToCurrentSubtitle(animated: true);
          }
        }
      } else if (shouldAnimateRelocate && tappedSubtitleIndex == null) {
        triggerLocateForAutoFollow(animated: true);
      } else if (tappedSubtitleIndex == null &&
          pointerDownStartIndex != null &&
          pointerDownStartIndex != currentIndex) {
        // Playback can advance while a non-row pointer gesture is held. Keep
        // the regular auto-follow behavior for that case.
        triggerLocateForAutoFollow(animated: true);
      }
    }
  }

  /// 这次抬起是不是「拖拽会话中副指针的一次干净轻点」。
  ///
  ///  - [PointerDeviceKind.touch]：鼠标双击、触控笔在桌面端另有语义；
  ///  - [_SidebarPointerRecord.inListArea]：点在顶部工具栏上不算；
  ///  - `anchorPointerIds` 非空：单指点击必须保持原有的「点一下就跳并定位」；
  ///  - `rowIndex != null`：必须真的命中了某一行字幕；
  ///  - 干净轻点：位移 <= slop 且时长 <= 300ms，滑动与长按都被排除。
  bool _isDragDoubleTapCandidate(
    _SidebarPointerRecord record,
    PointerUpEvent event,
  ) {
    // 关闭自动跟随时，单指点击本来就只 seek 不滚动，没有需要规避的副作用，
    // 保持原有交互即可，不启用本机制。
    if (!SettingsService().autoScrollSubtitles) return false;
    if (record.kind != PointerDeviceKind.touch) return false;
    if (!record.inListArea) return false;
    if (record.rowIndex == null) return false;
    if (record.anchorPointerIds.isEmpty) return false;
    if (record.maxTravel > _dragTapMaxTravel) return false;
    final int heldMs = event.timeStamp.inMilliseconds - record.downTimeMs;
    return heldMs <= _dragTapMaxDurationMs;
  }

  /// 判定刚抬起的这根手指是否凑成了一次「拖拽中的副指针双击」。
  ///
  /// 前置条件已由 [_isDragDoubleTapCandidate] 过滤，这里只补上需要跨两次
  /// 轻点才能判的部分：同一行、落点接近、间隔 <= 300ms，且两次轻点共享至少
  /// 一根「从第一次点之前就按着、到现在仍没抬起」的锚定手指。
  void _evaluateDragDoubleTap(_SidebarPointerRecord record, int upTimeMs) {
    final int rowIndex = record.rowIndex!;
    final _SidebarTapRecord? pending = _pendingDragDoubleTap;
    if (pending != null &&
        pending.rowIndex == rowIndex &&
        (record.downPosition - pending.downPosition).distance <=
            _dragDoubleTapSlop &&
        (record.downTimeMs - pending.upTimeMs) <= _dragDoubleTapIntervalMs &&
        // 这一条同时挡掉了「中途全部松手后重新落指」和「另一处的无关连点」。
        pending.anchorPointerIds.any(
          (int id) =>
              record.anchorPointerIds.contains(id) &&
              _pointerRecords.containsKey(id),
        )) {
      _pendingDragDoubleTap = null;
      _handleDragDoubleTapSeek(rowIndex);
      return;
    }

    _pendingDragDoubleTap = _SidebarTapRecord(
      rowIndex: rowIndex,
      downPosition: record.downPosition,
      upTimeMs: upTimeMs,
      anchorPointerIds: record.anchorPointerIds,
    );
  }

  /// 第 [index] 行的常规点击是否应该让位给「拖拽中双击」识别器。
  ///
  /// 只有在列表尚未进入滚动状态时，行上的 TapGestureRecognizer 才可能赢下
  /// 竞技场并触发 onTap（列表一旦在滚动，新指针会被 Scrollable 的
  /// DragGestureRecognizer 直接判给自己）。所以这里要覆盖两种时序：
  ///   1. 手指仍按着（副指针还在 [_pointerRecords] 里）；
  ///   2. 手指刚抬起（快速轻点，竞技场在抬起事件派发完之后才裁决），对应记录
  ///      暂存在 [_recentlyLiftedSecondaryTap]。
  bool _shouldDeferRowTap(int index) {
    if (!SettingsService().autoScrollSubtitles) return false;
    final _SidebarPointerRecord? lifted = _recentlyLiftedSecondaryTap;
    if (lifted != null && lifted.rowIndex == index) return true;
    for (final _SidebarPointerRecord record in _pointerRecords.values) {
      if (record.kind != PointerDeviceKind.touch) continue;
      if (record.anchorPointerIds.isEmpty) continue;
      if (record.rowIndex != index) continue;
      return true;
    }
    return false;
  }

  /// 拖拽会话中的双击：只把媒体 seek 到该句的时间点，绝不滚动文稿。
  ///
  /// 播放/暂停状态交由播放页的 seek 通路原样保持（seekTo 不会 pause/play），
  /// 因此双击前在播放的，双击后继续播放。
  void _handleDragDoubleTapSeek(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) return;

    final item = subtitles[index];
    widget.onClearSelection?.call();
    // 作废在途的自动/修复定位并进入冷却，否则它们会在 seek 之后落地，
    // 把用户正在浏览的位置拖走——这正是本机制要避免的。
    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    _markManualLocateAutoFollowCooldown();
    // 高亮立刻跟到被双击的那一行；加锁是为了扛住 seek 真正生效前的那几帧
    // 仍在上报旧位置的回调，避免高亮来回闪。
    _markManualLocateLock(index);
    _activeIndexNotifier.value = index;
    final List<int> tappedIndices = <int>[index];
    if (!_isSameIndices(tappedIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = tappedIndices;
    }
    _didDoubleTapSeekWhilePointerSession = true;
    // 与常规点击一致：接收方把参数当作视频时间直接 seek，字幕时间需加上
    // 延迟换算，才能让画面字幕与双击项一致。
    widget.onItemTap?.call(
      item.startTime + Duration(milliseconds: _subtitleOffsetMs),
    );
    // 手指仍压在屏幕上、文稿又刻意不滚动，缺少视觉位移反馈，用轻微震动补上。
    unawaited(AppHaptics.selectionClick(SettingsService()));
  }

  int? _activeTouchPointerForSelection() {
    // Only pointers that are still down. Leftover list-area records would
    // re-bind a later pan as a selection gesture and freeze the viewport.
    if (_latestDownTouchPointer != null) return _latestDownTouchPointer;
    if (_downTouchPointers.isNotEmpty) return _downTouchPointers.first;
    return null;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollEndNotification) {
      _updateReadingInteraction();
    }
    // A long-press drag inside the text can emit a spurious programmatic
    // scroll even before reaching an edge. Correct that narrow case. Never
    // counter-scroll a real selection-handle drag: doing so races the overlay
    // geometry and was the source of the Android full-screen ErrorWidget.
    if (_selectionGesturePointer != null &&
        !_selectionGestureUsesHandle &&
        _touchSelectionEdgePointer == null &&
        !_selectionViewportCorrectionInFlight &&
        notification is ScrollUpdateNotification &&
        notification.dragDetails == null) {
      final double delta = notification.scrollDelta ?? 0;
      if (delta.abs() >= 0.5) {
        unawaited(_correctInitialSelectionViewportOffset(-delta));
      }
    }
    if (_activePointerCount <= 0) return false;
    if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      _didScrollWhilePointerSession = true;
    }
    return false;
  }

  Future<void> _correctInitialSelectionViewportOffset(double offset) async {
    _selectionViewportCorrectionInFlight = true;
    final ScrollOffsetController controller = _isArticleMode
        ? _articleScrollOffsetController
        : _listScrollOffsetController;
    try {
      await controller.animateScroll(
        offset: offset,
        duration: const Duration(milliseconds: 1),
        curve: Curves.linear,
      );
    } catch (_) {
      // The list may detach while switching mode or media.
    } finally {
      _selectionViewportCorrectionInFlight = false;
    }
  }

  String _getFilteredText(String text, int index) {
    if (index >= 0 && index < _selectionTextCache.length) {
      return _selectionTextCache[index];
    }
    return _normalizeTranscriptText(_computeDisplayTextForIndex(index));
  }

  String _computeDisplayTextForIndex(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) return '';
    final String text = _normalizeTranscriptText(subtitles[index].text);
    if (_usesSecondaryTrackForDisplay) {
      return text;
    }
    if (_lineFilterMode == 0) {
      // Dual Mode
      // If we have valid bilingual match, merge them
      if (_isBilingualMode && _secondaryTextCache.containsKey(index)) {
        final String secondary = _secondaryTextCache[index]!;
        if (text.isEmpty) return secondary;
        if (secondary.isEmpty) return text;
        return '$text $secondary';
      }
      return text;
    }

    // Line Split Mode (Legacy or Forced)
    // If we have secondary file but mode is 1 or 2, we might want to toggle files?
    // User logic: "If mode is 1, show Primary. If mode is 2, show Secondary."
    if (widget.secondarySubtitles.isNotEmpty) {
      if (_lineFilterMode == 1) return text;
      if (_lineFilterMode == 2) {
        if (_secondaryTextCache.containsKey(index)) {
          return _secondaryTextCache[index]!;
        }
        return ""; // No match found for this line
      }
    }

    // Fallback to split-by-newline logic (Single File)
    final lines = subtitles[index].text.split(RegExp(r'\r?\n'));
    if (_lineFilterMode == 1) {
      return lines.isNotEmpty ? _normalizeTranscriptText(lines[0]) : '';
    } else if (_lineFilterMode == 2) {
      return lines.length > 1 ? _normalizeTranscriptText(lines[1]) : '';
    }
    return text;
  }

  /// Structured primary/secondary text for copy formatting.
  ///
  /// Mirrors [_computeDisplayTextForIndex] so the joined display string stays
  /// identical to the SelectionArea `plainText`, while still exposing the
  /// bilingual boundary that a flattened copy cannot recover.
  SubtitleCueCopyParts _computeCueCopyPartsForIndex(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) {
      return SubtitleCueCopyParts.empty;
    }
    final SubtitleItem item = subtitles[index];
    final String text = _normalizeTranscriptText(item.text);
    SubtitleCueCopyParts parts;
    if (_usesSecondaryTrackForDisplay) {
      parts = SubtitleCueCopyParts(primary: text, secondary: '');
    } else if (_lineFilterMode == 0) {
      if (_isBilingualMode && _secondaryTextCache.containsKey(index)) {
        parts = SubtitleCueCopyParts(
          primary: text,
          secondary: _secondaryTextCache[index]!,
        );
      } else {
        parts = SubtitleCueCopyParts(primary: text, secondary: '');
      }
    } else if (widget.secondarySubtitles.isNotEmpty) {
      if (_lineFilterMode == 1) {
        parts = SubtitleCueCopyParts(primary: text, secondary: '');
      } else {
        parts = SubtitleCueCopyParts(
          primary: _secondaryTextCache[index] ?? '',
          secondary: '',
        );
      }
    } else {
      final List<String> lines = item.text.split(RegExp(r'\r?\n'));
      if (_lineFilterMode == 1) {
        parts = SubtitleCueCopyParts(
          primary: lines.isNotEmpty ? _normalizeTranscriptText(lines[0]) : '',
          secondary: '',
        );
      } else {
        parts = SubtitleCueCopyParts(
          primary: lines.length > 1 ? _normalizeTranscriptText(lines[1]) : '',
          secondary: '',
        );
      }
    }
    if (parts.isEmpty && item.imageLoader != null) {
      return const SubtitleCueCopyParts(primary: '[图片字幕]', secondary: '');
    }
    return parts;
  }

  /// 这次 onTap 是不是「确认的短单击」，只有这时才允许 seek。
  ///
  /// 过去把 seek 放在 onTapDown：TapGestureRecognizer 按住约 100ms
  /// （[kPressTimeout]）就会触发，于是长按、按住再滑、鼠标拖选用字都会先跳转。
  /// 现在只在手势竞技场确认这是一次 tap 之后，再拿 Listener 记下的时长/位移
  /// 做一次核对：
  ///   - 副指针 / 已交给双击识别器的轻点：不 seek；
  ///   - 按住超过 [_rowTapMaxDurationMs]：长按/选字，不 seek；
  ///   - 位移超过设备对应 slop：滑动浏览或拖选用字，不 seek。
  bool _isConfirmedSubtitleClick(int index) {
    if (_shouldDeferRowTap(index)) return false;
    if (_suppressedRowTapIndex == index) return false;
    final _SidebarPointerRecord? lifted = _lastLiftedPointer;
    if (lifted == null) {
      // Listener 没看到这次抬起时，仍信任手势竞技场判出的 onTap。
      return true;
    }
    if (lifted.interruptedViewportMotion) return false;
    if (lifted.anchorPointerIds.isNotEmpty) return false;
    if (_lastLiftedHeldMs >= _rowTapMaxDurationMs) return false;
    if (lifted.maxTravel > _rowTapMaxTravelFor(lifted.kind)) return false;
    return true;
  }

  /// 鼠标/触控板用更紧的 slop：拖选用字通常只有几个像素，也必须跟单击分开。
  double _rowTapMaxTravelFor(PointerDeviceKind kind) {
    switch (kind) {
      case PointerDeviceKind.mouse:
      case PointerDeviceKind.trackpad:
        return kPrecisePointerHitSlop;
      default:
        return kTouchSlop;
    }
  }

  /// 确认是单击之后才 seek，并（在自动跟随开启时）把文稿滚到那一句。
  void _completeSubtitleTap(int index) {
    if (_hasTextSelection || _pointerSessionStartedWithTextSelection) {
      _pointerSessionStartedWithTextSelection = false;
      clearTextSelection();
      widget.onClearSelection?.call();
      _suppressedRowTapIndex = null;
      return;
    }
    // 拖拽会话中的副指针轻点、长按、滑动选字都不能落地常规 seek。
    if (!_isConfirmedSubtitleClick(index)) {
      _suppressedRowTapIndex = null;
      return;
    }
    _suppressedRowTapIndex = null;
    _commitConfirmedSubtitleTap(index);
  }

  void _commitConfirmedSubtitleTap(int index) {
    final subtitles = _displaySubtitles;
    if (index < 0 || index >= subtitles.length) return;

    if (widget.onItemTap != null) {
      unawaited(AppHaptics.lightTap(SettingsService()));
    }

    final item = subtitles[index];
    widget.onClearSelection?.call();
    // onItemTap 的接收方把参数当作视频时间直接 seek，字幕时间需加上
    // 延迟换算，才能让画面字幕与点击项一致。
    widget.onItemTap?.call(
      item.startTime + Duration(milliseconds: _subtitleOffsetMs),
    );
    Future.microtask(() => widget.focusNode?.requestFocus());
    _pointerDownSubtitleIndex = null;
    _locateTappedSubtitle(index);
  }

  void _locateTappedSubtitle(int index) {
    if (index < 0 || index >= _displaySubtitles.length) return;
    // A short tap can redirect the stopped surface with its previous velocity.
    // A held/dragged pointer must never revive old scrolling momentum.
    final captured = _lastLiftedPointer?.readingMomentum;
    final momentum = _lastLiftedHeldMs <= 120 && captured?.isFresh == true
        ? captured
        : null;
    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    _pendingLocateIndex = index;
    _markManualLocateLock(index);
    _markManualLocateAutoFollowCooldown();
    _markManualAnimationFreeze(index, animated: true);
    _markAutoScrollSuppressedForIndex(index);
    _activeIndexNotifier.value = index;
    final List<int> tappedIndices = <int>[index];
    if (!_isSameIndices(tappedIndices, _activeIndicesNotifier.value)) {
      _activeIndicesNotifier.value = tappedIndices;
    }
    // 关闭自动跟随时，点击只负责 seek，不把文稿滚到当前句，
    // 避免打断用户正在浏览的字幕列表。手动「定位」按钮仍可随时对齐。
    if (!SettingsService().autoScrollSubtitles) return;
    lastTappedLocateScrollIndex = index;
    _scrollToIndex(index, isAuto: false, momentum: momentum);
  }

  void _scrollToActiveIndex({bool isAuto = false}) {
    final index = _activeIndexNotifier.value;
    if (index < 0 || index >= _displaySubtitles.length) return;
    _scrollToIndex(index, isAuto: isAuto);
  }

  void _scrollToIndex(
    int index, {
    bool isAuto = false,
    _ReadingScrollMomentum? momentum,
  }) {
    if (index < 0 || index >= _displaySubtitles.length) return;
    if (!widget.isVisible ||
        !_isSubtitleSidebarRouteCurrent ||
        !_isScrollableViewportUsable()) {
      return;
    }
    if (isAuto &&
        (!SettingsService().autoScrollSubtitles ||
            !_playbackIsPlaying ||
            _selectionBlocksAutoFollow)) {
      return;
    }
    final controller = _isArticleMode
        ? _articleItemScrollController
        : _itemScrollController;
    if (!controller.isAttached) return;
    final targetIndex = _isArticleMode
        ? _articleItemIndexForSubtitle(index)
        : index;
    if (targetIndex < 0) return;
    if (!_hasTranscriptScrollRange) {
      _cancelReadingMotion();
      _queueReadingReveal(targetIndex);
      return;
    }
    final positions = _readingMotionPositions(targetIndex);
    final alignment = _resolveReachableAlignment(
      targetIndex: targetIndex,
      isArticleMode: _isArticleMode,
      requestedAlignment: _locateAlignment,
      positions: positions,
    );
    if (isAuto &&
        _animatedReadingPosition != null &&
        _animatedReadingItem == targetIndex &&
        (_animatedReadingAlignment! - alignment).abs() < .0001) {
      return;
    }

    ItemPosition? targetPosition;
    for (final item in positions) {
      if (item.index == targetIndex) {
        targetPosition = item;
        break;
      }
    }
    final scrollable = _selectionScrollable;
    final position = scrollable != null && scrollable.mounted
        ? scrollable.position
        : null;
    final viewport = position?.hasViewportDimension == true
        ? position!.viewportDimension
        : 0.0;
    final delta = targetPosition == null
        ? null
        : (targetPosition.itemLeadingEdge - alignment) * viewport;
    final visibleTarget =
        targetPosition != null &&
        targetPosition.itemLeadingEdge < 1 &&
        targetPosition.itemTrailingEdge > 0 &&
        delta != null &&
        delta.abs() <= viewport;
    final motion = _viewportMotionKey.currentState;

    momentum ??= _captureReadingMomentum();
    _cancelReadingMotion(cancelDissolve: false);
    if (!_readingViewportReady || MediaQuery.disableAnimationsOf(context)) {
      _jumpToActiveIndexWithAlignment(index);
      return;
    }
    if (delta != null &&
        !(motion?.isTransitioning ?? false) &&
        viewport > _collapsedViewportHeight &&
        delta.abs() < .5) {
      _viewportMotionKey.currentState?.cancel();
      return;
    }
    // Only move real pixels through a bounded part of the viewport. Never use
    // ItemScrollController.scrollTo: a stale geometry snapshot can send even a
    // seemingly local request into that package's unsafe two-list fade path.
    if (delta != null &&
        !(motion?.isTransitioning ?? false) &&
        position != null &&
        position.hasPixels &&
        viewport > _collapsedViewportHeight &&
        (visibleTarget ||
            delta.abs() <= TranscriptScrollMotion.travelLimitFor(viewport))) {
      final request = _readingMotionRequestId;
      _animatedReadingPosition = position;
      _animatedReadingItem = targetIndex;
      _animatedReadingAlignment = alignment;
      final destination = (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      final trajectory = TranscriptScrollMotion(
        from: position.pixels,
        to: destination,
        viewport: viewport,
        initialVelocity: identical(momentum?.position, position)
            ? momentum!.velocity
            : 0,
        isAuto: isAuto,
        visibleTarget: visibleTarget,
      );
      if (!isAuto && _manualAnimationFreezeIndex == index) {
        // Preserve the manual target through the whole movement. Keep the
        // original freeze for short dissolves, and only extend longer moves.
        final until =
            DateTime.now().millisecondsSinceEpoch +
            trajectory.duration.inMilliseconds +
            24;
        if (until > _manualAnimationFreezeUntilMs) {
          _manualAnimationFreezeUntilMs = until;
        }
      }
      unawaited(
        _animateReadingScroll(position, trajectory).whenComplete(() {
          if (request != _readingMotionRequestId) return;
          _animatedReadingPosition = null;
          _readingScrollActivity = null;
          _animatedReadingItem = null;
          _animatedReadingAlignment = null;
        }),
      );
      return;
    }

    if (motion == null || _selectionBlocksAutoFollow) {
      _jumpToActiveIndexWithAlignment(index);
      return;
    }
    final request = _readingMotionRequestId;
    motion.transitionTo(
      isCurrent: () =>
          mounted &&
          request == _readingMotionRequestId &&
          widget.isVisible &&
          _isSubtitleSidebarRouteCurrent &&
          !_selectionBlocksAutoFollow,
      reposition: () => _jumpToActiveIndexWithAlignment(
        index,
        preserveMotion: motion.obscuresLiveText,
      ),
    );
  }

  Future<void> _animateReadingScroll(
    ScrollPosition position,
    TranscriptScrollMotion trajectory,
  ) {
    if (position is! ScrollPositionWithSingleContext) {
      return position.animateTo(
        trajectory.to,
        duration: trajectory.duration,
        curve: trajectory.curve,
      );
    }
    final activity = _TranscriptScrollActivity.simulation(
      position,
      trajectory,
      vsync: position.context.vsync,
    );
    _readingScrollActivity = activity;
    position.beginActivity(activity);
    return activity.done;
  }

  void _jumpToActiveIndexWithAlignment(
    int index, {
    bool preserveMotion = false,
    bool forceReanchor = false,
  }) {
    if (!preserveMotion) _cancelReadingMotion();
    if (index < 0 || index >= _displaySubtitles.length) return;
    final controller = _isArticleMode
        ? _articleItemScrollController
        : _itemScrollController;
    final targetIndex = _isArticleMode
        ? _articleItemIndexForSubtitle(index)
        : index;
    if (targetIndex < 0 || !controller.isAttached) return;
    // A fitting transcript has no scroll destination. Re-anchoring it to the
    // active cue changes the indexed list's origin and invents blank space,
    // because its shrink-wrapped height differs from its layout constraints.
    if (!_hasTranscriptScrollRange) {
      if (forceReanchor) {
        controller.jumpTo(index: 0);
        _settleReadingJump();
      }
      _queueReadingReveal(targetIndex);
      return;
    }
    final positions = _readingMotionPositions(targetIndex);
    final double effectiveAlignment = _resolveReachableAlignment(
      targetIndex: targetIndex,
      isArticleMode: _isArticleMode,
      requestedAlignment: _locateAlignment,
      positions: positions,
    );
    if (!forceReanchor &&
        _shouldSkipScrollAnimation(
          targetIndex: targetIndex,
          isArticleMode: _isArticleMode,
          alignment: effectiveAlignment,
        )) {
      _queueReadingReveal(targetIndex);
      return;
    }
    // A cold destination has no trustworthy end bounds yet. Keep it hidden
    // until its first layout can clamp the new anchor. A distant transition
    // already keeps the reading surface transparent for this layout frame.
    if (!preserveMotion &&
        !positions.any((item) => item.index == targetIndex)) {
      _prepareReadingReveal(
        itemIndex: targetIndex,
        alignment: effectiveAlignment,
      );
      if (!_readingViewportReady) setState(() {});
    }
    controller.jumpTo(index: targetIndex, alignment: effectiveAlignment);
    _settleReadingJump();
    _queueReadingReveal(targetIndex);
  }

  void _settleReadingJump() {
    final request = _readingMotionRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _readingMotionRequestId ||
          !widget.isVisible ||
          !_isSubtitleSidebarRouteCurrent) {
        return;
      }
      final scrollable = _selectionScrollable;
      if (scrollable == null || !scrollable.mounted) return;
      final position = scrollable.position;
      if (!position.hasPixels || !position.hasContentDimensions) return;
      // Re-anchoring changes the pixel origin. Also stop any ballistic activity
      // that jumpTo(0) started against the previous anchor's scroll extents.
      position.jumpTo(
        position.pixels.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
    _ensureFrameScheduled();
  }

  double _resolveReachableAlignment({
    required int targetIndex,
    required bool isArticleMode,
    required double requestedAlignment,
    Iterable<ItemPosition>? positions,
  }) {
    positions ??= isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return targetIndex == 0 ? 0 : requestedAlignment;

    final int itemCount = isArticleMode
        ? _articleItemCount
        : _displaySubtitles.length;
    if (itemCount <= 0) return requestedAlignment;

    ItemPosition? targetPosition;
    ItemPosition? firstPosition;
    ItemPosition? lastPosition;
    for (final position in positions) {
      if (position.index == targetIndex) targetPosition = position;
      if (position.index == 0) firstPosition = position;
      if (position.index == itemCount - 1) lastPosition = position;
    }
    if (targetPosition == null) {
      return targetIndex == 0 ? 0 : requestedAlignment;
    }

    final scrollable = _selectionScrollable;
    if (scrollable != null && scrollable.mounted) {
      final position = scrollable.position;
      if (position.hasPixels &&
          position.hasContentDimensions &&
          position.hasViewportDimension &&
          position.viewportDimension > _collapsedViewportHeight) {
        final extent = position.viewportDimension;
        final destination =
            (position.pixels +
                    (targetPosition.itemLeadingEdge - requestedAlignment) *
                        extent)
                .clamp(position.minScrollExtent, position.maxScrollExtent);
        return targetPosition.itemLeadingEdge -
            (destination - position.pixels) / extent;
      }
    }

    double minimumAlignment = 0.0;
    double maximumAlignment = 1.0;
    if (lastPosition != null) {
      final double extentFromTargetThroughBottom =
          lastPosition.itemTrailingEdge - targetPosition.itemLeadingEdge;
      minimumAlignment = (1.0 - extentFromTargetThroughBottom).clamp(0.0, 1.0);
    }
    if (firstPosition != null) {
      final double extentFromTopThroughTarget =
          targetPosition.itemLeadingEdge - firstPosition.itemLeadingEdge;
      maximumAlignment = extentFromTopThroughTarget.clamp(0.0, 1.0);
    }

    // When the entire document fits in the viewport there is no scrollable
    // range. Its only stable position is the natural top-aligned layout.
    if (minimumAlignment > maximumAlignment) return maximumAlignment;
    return requestedAlignment.clamp(minimumAlignment, maximumAlignment);
  }

  bool _shouldSkipScrollAnimation({
    required int targetIndex,
    required bool isArticleMode,
    required double alignment,
  }) {
    final positions = isArticleMode
        ? _articleItemPositionsListener.itemPositions.value
        : _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return false;

    double? targetLeading;

    for (final pos in positions) {
      if (pos.index == targetIndex) {
        targetLeading = pos.itemLeadingEdge;
        break;
      }
    }

    if (targetLeading == null) return false;

    const double epsilon = 0.0001;
    return (targetLeading - alignment).abs() <= epsilon;
  }

  void jumpToFirstSubtitleTop() {
    if (_displaySubtitles.isEmpty) return;
    _invalidateLocateRequests();
    _cancelPendingAutoScroll();
    _activeIndexNotifier.value = 0;
    _jumpToIndexTopInternal(
      targetIndex: 0,
      attempt: 0,
      requestId: _locateRequestId,
    );
  }

  void _jumpToIndexTopInternal({
    required int targetIndex,
    required int attempt,
    required int requestId,
  }) {
    if (!mounted || requestId != _locateRequestId) return;
    const int maxAttempts = 6;
    if (_isArticleMode) {
      if (!_articleItemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _jumpToIndexTopInternal(
              targetIndex: targetIndex,
              attempt: attempt + 1,
              requestId: requestId,
            );
          });
        }
        return;
      }
      final int chunkIndex = _articleItemIndexForSubtitle(targetIndex);
      if (chunkIndex < 0) return;
      _articleItemScrollController.jumpTo(index: chunkIndex, alignment: 0.0);
    } else {
      if (!_itemScrollController.isAttached) {
        if (attempt < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _jumpToIndexTopInternal(
              targetIndex: targetIndex,
              attempt: attempt + 1,
              requestId: requestId,
            );
          });
        }
        return;
      }
      _itemScrollController.jumpTo(index: targetIndex, alignment: 0.0);
    }
    _settleReadingJump();
  }

  @override
  Widget build(BuildContext context) {
    _publishViewportReadyAfterPaint();
    final bool isSmallScreen = MediaQuery.sizeOf(context).width < 600;
    if (widget.isVisible && _isSubtitleSidebarRouteCurrent) {
      _lastVisibleReadingEnvironment = MediaQuery.of(context);
    }
    final settings = SettingsService();

    return Focus(
      canRequestFocus: false,
      descendantsAreFocusable: true,
      child: Container(
        width: double.infinity,
        color: AppTokens.bgPlayerSidebar, // 深色背景
        child: Material(
          color: Colors.transparent,
          child: GestureDetector(
            onTap: () {
              clearTextSelection();
              widget.onClearSelection?.call();
              widget.focusNode?.requestFocus();
            },
            behavior: HitTestBehavior.translucent,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUpOrCancel,
              onPointerCancel: _onPointerUpOrCancel,
              child: Column(
                children: [
                  // Ink paints on its Material, not the button's boundary.
                  // Keep toolbar feedback out of the surrounding player.
                  RepaintBoundary(
                    child: Material(
                      type: MaterialType.transparency,
                      child: _buildToolbar(settings),
                    ),
                  ),

                  // 2. 内容区。设置面板悬浮在文稿之上，不参与高度分配。
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _displaySubtitles.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      widget.showEmbeddedLoadingMessage
                                          ? "已识别到内嵌字幕，\n正在提取中..."
                                          : (Provider.of<MediaPlaybackService?>(
                                                  context,
                                                )?.cloudDriveSubtitleStatus ??
                                                "暂无字幕"),
                                      style: const TextStyle(
                                        color: Colors.white54,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                    if (widget.onOpenSubtitleManager !=
                                        null) ...[
                                      const SizedBox(height: 16),
                                      InkWell(
                                        canRequestFocus: false,
                                        onTap: widget.onOpenSubtitleManager,
                                        borderRadius: BorderRadius.circular(4),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Colors.purpleAccent
                                                  .withValues(alpha: 0.5),
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            color: Colors.purpleAccent
                                                .withValues(alpha: 0.1),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: const [
                                              Icon(
                                                Icons.subtitles,
                                                size: 18,
                                                color: Colors.purpleAccent,
                                              ),
                                              SizedBox(width: 8),
                                              Text(
                                                "查看字幕管理",
                                                style: TextStyle(
                                                  color: Colors.purpleAccent,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              )
                            // 只给字幕列表区再套一层指针登记：顶部工具栏按钮上的
                            // 手指既不能充当双击的锚点，也不会被当成候选轻点。
                            : Stack(
                                fit: StackFit.expand,
                                children: [
                                  Listener(
                                    behavior: HitTestBehavior.translucent,
                                    onPointerDown:
                                        _onTranscriptContextMenuPointer,
                                    child: SelectionArea(
                                      key: _textSelectionKey,
                                      focusNode: _textSelectionFocusNode,
                                      contextMenuBuilder:
                                          _buildTextSelectionContextMenu,
                                      onSelectionChanged:
                                          _handleTextSelectionChanged,
                                      child: SelectionContainer(
                                        delegate: _scrollSelectionDelegate,
                                        child: _SelectionStatusObserver(
                                          onStatusChanged:
                                              _handleSelectionRegionStatusChanged,
                                          child: PanelSwipeRegion(
                                            child: Listener(
                                              behavior:
                                                  HitTestBehavior.translucent,
                                              onPointerDown:
                                                  _onListAreaPointerDown,
                                              child: Opacity(
                                                opacity: _readingViewportReady
                                                    ? 1
                                                    : 0,
                                                child: TranscriptViewportMotion(
                                                  key: _viewportMotionKey,
                                                  onSettle: _settleReadingJump,
                                                  onActivityChanged:
                                                      _handleDistantMotionActivity,
                                                  enabled:
                                                      widget.isVisible &&
                                                      _isSubtitleSidebarRouteCurrent &&
                                                      _readingViewportReady &&
                                                      !_hasTextSelection,
                                                  child: _isArticleMode
                                                      ? _buildArticleView(
                                                          isSmallScreen,
                                                        )
                                                      : _buildListView(
                                                          isSmallScreen,
                                                        ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (_hasTextSelection)
                                    _buildSelectionPreservingScrollShield(),
                                ],
                              ),
                        if (_showFontSettings)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: _buildFloatingDisplaySettings(),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFloatingDisplaySettings() {
    return Container(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.white.withValues(alpha: 0.05),
          AppTokens.bgPlayerSidebar,
        ),
        border: const Border(bottom: BorderSide(color: Colors.white10)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isVeryNarrow = constraints.maxWidth < 180;
          final labelWidth = isVeryNarrow ? 24.0 : 52.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 28,
                child: Row(
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Text(
                        isVeryNarrow ? "字" : "字体",
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _FontSizeSliderWidget(
                        fontSizeScale: _fontSizeScale,
                        showValue: !isVeryNarrow,
                        onChanged: (nextScale) {
                          setState(() => _fontSizeScale = nextScale);
                        },
                        onCommit: (nextScale) {
                          final key = widget.isPortrait
                              ? 'portraitSidebarFontSizeScale'
                              : 'landscapeSidebarFontSizeScale';
                          SettingsService().updateSetting(key, nextScale);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 28,
                child: Row(
                  children: [
                    SizedBox(
                      width: labelWidth,
                      child: Text(
                        isVeryNarrow ? "定位" : "定位位置",
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    Expanded(
                      child: _LocatePositionInputWidget(
                        key: ValueKey(
                          'subtitle-locate-position-editor-${widget.isPortrait ? 'portrait' : 'landscape'}',
                        ),
                        value: _locatePositionPercent,
                        onChanged: _updateLocatePositionPercent,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isArticleMode)
                SizedBox(
                  height: 32,
                  child: Semantics(
                    toggled: _articleParagraphModeEnabled,
                    button: true,
                    label: '段落模式',
                    hint: '关闭后连续显示全部字幕',
                    onTap: () => _updateArticleParagraphMode(
                      !_articleParagraphModeEnabled,
                    ),
                    child: GestureDetector(
                      key: const ValueKey('subtitle-paragraph-mode-control'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _updateArticleParagraphMode(
                        !_articleParagraphModeEnabled,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: labelWidth,
                            child: Text(
                              isVeryNarrow ? "段" : "段落模式",
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          Tooltip(
                            message: "关闭后连续显示全部字幕",
                            child: SizedBox(
                              width: 44,
                              height: 30,
                              child: FittedBox(
                                fit: BoxFit.contain,
                                child: Switch(
                                  key: const ValueKey(
                                    'subtitle-paragraph-mode-switch',
                                  ),
                                  value: _articleParagraphModeEnabled,
                                  onChanged: _updateArticleParagraphMode,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ),
                          ),
                          if (!isVeryNarrow)
                            const Expanded(
                              child: Text(
                                "关闭后连续显示全部字幕",
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_isArticleMode)
                SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      SizedBox(
                        width: labelWidth,
                        child: Text(
                          isVeryNarrow ? "句" : "每段",
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Expanded(
                        child: IgnorePointer(
                          ignoring: !_articleParagraphModeEnabled,
                          child: Opacity(
                            opacity: _articleParagraphModeEnabled ? 1 : 0.45,
                            child: _SentenceCountInputWidget(
                              value: _articleChunkSize,
                              min: _minArticleChunkSize,
                              max: _maxArticleChunkSize,
                              onChanged: _updateArticleChunkSize,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!_isArticleMode)
                SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      SizedBox(
                        width: labelWidth,
                        child: Text(
                          isVeryNarrow ? "时" : "时间",
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: _showTimestamps ? "隐藏时间" : "显示时间",
                        child: InkWell(
                          key: const ValueKey('subtitle-show-time-switch'),
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            final value = !_showTimestamps;
                            unawaited(
                              AppHaptics.selectionClick(SettingsService()),
                            );
                            setState(() => _showTimestamps = value);
                            final key = widget.isPortrait
                                ? 'portraitSidebarShowTimestamps'
                                : 'landscapeSidebarShowTimestamps';
                            SettingsService().updateSetting(key, value);
                          },
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: Icon(
                              _showTimestamps
                                  ? Icons.circle
                                  : Icons.circle_outlined,
                              size: 12,
                              color: _showTimestamps
                                  ? Colors.blueAccent
                                  : Colors.white38,
                            ),
                          ),
                        ),
                      ),
                      if (_showTimestamps) ...[
                        const SizedBox(width: 4),
                        if (!isVeryNarrow)
                          const SizedBox(
                            width: 36,
                            child: Text(
                              "宽度",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        Expanded(
                          child: _TimeColumnRatioSliderWidget(
                            ratio: _timeColumnRatio,
                            showValue: !isVeryNarrow,
                            onChanged: (nextRatio) {
                              setState(() => _timeColumnRatio = nextRatio);
                            },
                            onCommit: (nextRatio) {
                              final key = widget.isPortrait
                                  ? 'portraitSidebarTimeColumnRatio'
                                  : 'landscapeSidebarTimeColumnRatio';
                              SettingsService().updateSetting(key, nextRatio);
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildToolbar(SettingsService settings) => SubtitleToolbar(
    onOpenSettings: widget.onOpenSettings,
    actions: [
      if (widget.onOpenAiChat != null)
        SubtitleToolbarAction(
          icon: Icons.auto_awesome_outlined,
          tooltip: hoverAwareShortcutTooltip(
            'AI 对话',
            DesktopPlayerShortcuts.primaryBinding(
              DesktopPlayerShortcutAction.toggleAiChat,
            ).logicalKey,
            context: context,
          ),
          onTap: widget.onOpenAiChat,
        ),
      for (var index = 0; index < 2; index++)
        SubtitleToolbarAction(
          icon: index == 0 ? Icons.list : Icons.article,
          group: SubtitleToolbarGroup.view,
          tooltip: index == 0 ? '切换列表/文章视图' : '文章视图',
          selected: _isArticleMode == (index == 1),
          onTap: () {
            final isArticle = index == 1;
            if (_isArticleMode != isArticle) {
              unawaited(AppHaptics.selectionClick(settings));
            }
            _invalidateLocateRequests();
            _cancelPendingAutoScroll();
            _clearTextSelection(resumeAutoFollow: false);
            setState(() {
              _isArticleMode = isArticle;
              if (!_isContinuousArticleMode) _pauseContinuousArticleLayout();
            });
            SettingsService().updateSetting(
              'subtitleViewMode',
              isArticle ? 1 : 0,
            );
            _triggerLocateButtonAfterModeSwitch();
          },
        ),
      for (var index = 0; index < 3; index++)
        SubtitleToolbarAction(
          label: const ['双', '1', '2'][index],
          group: SubtitleToolbarGroup.language,
          tooltip: const ['双语显示', '仅显示第一行', '仅显示第二行'][index],
          selected: _lineFilterMode == index,
          onTap: () {
            if (_lineFilterMode != index) {
              unawaited(AppHaptics.selectionClick(settings));
            }
            _invalidateLocateRequests();
            _cancelPendingAutoScroll();
            _clearTextSelection(resumeAutoFollow: false);
            setState(() {
              _lineFilterMode = index;
              _invalidateDisplaySubtitlesCache();
            });
            _rebuildTimelineResolver();
            _triggerLocateButtonAfterModeSwitch();
          },
        ),
      SubtitleToolbarAction(
        icon: Icons.format_size,
        tooltip: '文稿显示设置',
        selected: _showFontSettings,
        onTap: () {
          unawaited(AppHaptics.lightTap(settings));
          setState(() => _showFontSettings = !_showFontSettings);
        },
      ),
      SubtitleToolbarAction(
        icon: settings.autoScrollSubtitles
            ? Icons.gps_fixed
            : Icons.gps_not_fixed,
        tooltip: '自动跟随字幕',
        selected: settings.autoScrollSubtitles,
        selectedBadge: 'A',
        onTap: () async {
          final newValue = !settings.autoScrollSubtitles;
          unawaited(AppHaptics.selectionClick(settings));
          await settings.updateSetting('autoScrollSubtitles', newValue);
          if (!mounted) return;
          setState(() {});
          if (newValue && settings.autoScrollSubtitles) _scrollToActiveIndex();
        },
      ),
      SubtitleToolbarAction(
        icon: Icons.my_location,
        tooltip: '定位到当前字幕',
        onTap: () {
          unawaited(AppHaptics.lightTap(settings));
          _clearTextSelection(resumeAutoFollow: false);
          _invalidateLocateRequests();
          _cancelPendingAutoScroll();
          _markManualLocateAutoFollowCooldown();
          _scrollToActiveIndex();
        },
      ),
      if (widget.onOpenSubtitleManager != null)
        SubtitleToolbarAction(
          icon: Icons.subtitles_outlined,
          tooltip: '字幕管理 (AI/导入/列表)',
          onTap: widget.onOpenSubtitleManager,
        ),
      if (widget.isPortrait)
        SubtitleToolbarAction(
          icon: Icons.style_outlined,
          tooltip: '字幕样式设置',
          onTap: widget.onOpenSubtitleStyle,
        ),
      if (widget.isPortrait && widget.onOpenSubtitleEditor != null)
        SubtitleToolbarAction(
          icon: Icons.edit_note,
          tooltip: '字幕编辑',
          onTap: widget.onOpenSubtitleEditor,
        ),
      if (widget.isPortrait && widget.onOpenVideoCompose != null)
        SubtitleToolbarAction(
          icon: Icons.movie_creation_outlined,
          tooltip: '合成视频',
          onTap: widget.onOpenVideoCompose,
        ),
      if (widget.isPortrait)
        SubtitleToolbarAction(
          icon: Icons.document_scanner_outlined,
          tooltip: '识别画面字幕（OCR）',
          onTap: widget.onOpenOcrSubtitle ?? _explainOcrUnavailable,
        ),
    ],
  );

  void _explainOcrUnavailable() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('识别画面字幕（OCR）'),
        content: Text(
          widget.ocrUnavailableReason ??
              (widget.isAudio
                  ? '音频没有画面，请使用语音转录生成字幕。'
                  : '当前媒体无法识别画面字幕。请打开支持的视频后再使用此功能。'),
        ),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ),
        ],
      ),
    );
  }

  double _subtitleTextFontSize(bool isSmallScreen) {
    return (isSmallScreen ? 12.0 : 13.0) * _fontSizeScale;
  }

  double _listItemLayoutScale() {
    return _fontSizeScale < 1.0 ? _fontSizeScale : _fontSizeScale * 0.9;
  }

  double _subtitleTextHorizontalInset(bool isSmallScreen) {
    final double outerInset = isSmallScreen ? 2.0 : 6.0;
    const double listItemBorderWidth = 1.0;
    final double innerInset =
        (isSmallScreen ? 6.0 : 8.0) * _listItemLayoutScale();
    return outerInset + listItemBorderWidth + innerInset;
  }

  double _articleVerticalInset(bool isSmallScreen) {
    // The line box already supplies half the leading at each edge. Add the
    // other half so the article edges resemble the space between text lines.
    final textScaler = MediaQuery.textScalerOf(context);
    return textScaler.scale(_subtitleTextFontSize(isSmallScreen)) * .3;
  }

  bool _shouldTopAlignList({
    required double maxHeight,
    required bool isSmallScreen,
    required double innerV,
    required double itemGap,
  }) {
    final displaySubtitles = _displaySubtitles;
    if (displaySubtitles.isEmpty) return true;
    final int lineCount = _lineFilterMode == 0 && _isBilingualMode ? 2 : 1;
    final double fontSize = _subtitleTextFontSize(isSmallScreen);
    final double textHeight = fontSize * 1.6 * lineCount;
    final double estimatedItemHeight =
        textHeight + innerV * 2 + itemGap + (isSmallScreen ? 6 : 8);
    final double estimatedTotalHeight =
        estimatedItemHeight * displaySubtitles.length +
        itemGap * 2 +
        _generationFooterExtent;
    return estimatedTotalHeight <= maxHeight;
  }

  bool _shouldTopAlignArticle({
    required BuildContext context,
    required double maxWidth,
    required double maxHeight,
    required bool isSmallScreen,
    required int chunkCount,
  }) {
    if (chunkCount == 0) return true;

    final double fontSize = _subtitleTextFontSize(isSmallScreen);
    final double horizontalInset = _subtitleTextHorizontalInset(isSmallScreen);
    final double contentWidth = maxWidth - horizontalInset * 2;
    if (contentWidth <= 0) return false;

    final TextStyle defaultTextStyle = DefaultTextStyle.of(context).style;
    final fitKey = (
      _readingTextRevision,
      maxWidth,
      maxHeight,
      isSmallScreen,
      _fontSizeScale,
      _articleChunkSize,
      defaultTextStyle,
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
      Localizations.maybeLocaleOf(context),
      _generationFooterExtent,
    );
    if (_paragraphFitKey == fitKey &&
        _paragraphFitCount <= _displaySubtitles.length &&
        (_paragraphFitResult == false ||
            _paragraphFitCount == _displaySubtitles.length)) {
      return _paragraphFitResult!;
    }
    _paragraphFitKey = fitKey;
    _paragraphFitCount = _displaySubtitles.length;
    final TextStyle articleTextStyle = const TextStyle().copyWith(
      fontSize: fontSize,
      height: 1.6,
      fontWeight: FontWeight.normal,
    );
    final StrutStyle strutStyle = StrutStyle(
      fontSize: fontSize,
      height: 1.6,
      forceStrutHeight: true,
    );
    double laidOutHeight =
        _articleVerticalInset(isSmallScreen) * 2 + _generationFooterExtent;

    for (int chunkIndex = 0; chunkIndex < chunkCount; chunkIndex++) {
      final int startIndex = chunkIndex * _articleChunkSize;
      final int endIndex = (startIndex + _articleChunkSize).clamp(
        0,
        _displaySubtitles.length,
      );
      final List<InlineSpan> spans = <InlineSpan>[];
      for (int index = startIndex; index < endIndex; index++) {
        final SubtitleItem item = _displaySubtitles[index];
        String text = index < _selectionTextCache.length
            ? _selectionTextCache[index]
            : '';
        if (text.isEmpty && item.imageLoader != null) {
          text = '[图片字幕]';
        }
        text = text.replaceAll(RegExp(r'\s+'), ' ');
        if (text.isEmpty) continue;
        if (spans.isNotEmpty) {
          spans.add(const TextSpan(text: ' '));
        }
        spans.add(TextSpan(text: text, style: articleTextStyle));
      }

      final TextPainter painter = TextPainter(
        text: TextSpan(style: defaultTextStyle, children: spans),
        strutStyle: strutStyle,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout(maxWidth: contentWidth);
      laidOutHeight += painter.height;
      painter.dispose();

      if (laidOutHeight + precisionErrorTolerance > maxHeight) {
        _paragraphFitResult = false;
        return false;
      }
    }
    return _paragraphFitResult =
        laidOutHeight + precisionErrorTolerance <= maxHeight;
  }

  // 列表模式视图
  double get _generationFooterExtent =>
      SubtitleGenerationFooter.availableIn(context)
      ? _generationFooterHeight
      : 0;

  void _handleGenerationFooterExtentChanged(double extent) {
    if (!mounted || _generationFooterHeight == extent) return;
    // Re-evaluate whether the article fits only when the hint appears or
    // disappears. Progress ticks continue to rebuild just the footer.
    setState(() => _generationFooterHeight = extent);
  }

  Widget? _generationFooter() => !SubtitleGenerationFooter.availableIn(context)
      ? null
      : SubtitleGenerationFooter(
          key: const ValueKey('subtitle-transcript-generation-footer'),
          primary: widget.subtitles,
          secondary: widget.secondarySubtitles,
          showPrimary: !_usesSecondaryTrackForDisplay,
          showSecondary: _lineFilterMode != 1,
          reserveSpaceWhenHidden: false,
          onExtentChanged: _handleGenerationFooterExtentChanged,
        );

  Widget _buildListView(bool isSmallScreen) {
    final displaySubtitles = _displaySubtitles;
    final footer = _generationFooter();

    // 动态计算间距，随字体大小缩放，使小字体模式更紧凑
    final double scale = _listItemLayoutScale();
    final double innerH = (isSmallScreen ? 6 : 8) * scale; // 内部水平间距
    final double innerV = (isSmallScreen ? 4 : 6) * scale; // 内部垂直间距
    final double itemGap = (isSmallScreen ? 2 : 4) * scale; // 列表项间距
    final double timeGap = (isSmallScreen ? 6 : 8) * scale; // 时间戳和文本的间距

    return LayoutBuilder(
      builder: (context, constraints) {
        _handleScrollableViewportLayout(constraints);
        final bool shouldTopAlign = _shouldTopAlignList(
          maxHeight: constraints.maxHeight,
          isSmallScreen: isSmallScreen,
          innerV: innerV,
          itemGap: itemGap,
        );
        if (shouldTopAlign &&
            _listFitsViewport == false &&
            _itemScrollController.isAttached) {
          _itemScrollController.jumpTo(index: 0);
        }
        _listFitsViewport = shouldTopAlign;
        // 当字幕数量不足时，强制从顶部开始显示，忽略当前索引
        final int currentIndex = _activeIndexNotifier.value;
        final int effectiveInitialIndex = shouldTopAlign
            ? 0
            : (currentIndex >= 0 ? currentIndex : 0);
        final double effectiveInitialAlignment = shouldTopAlign
            ? 0.0
            : _locateAlignment;

        final list = NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          // KeyedSubtree 不产生 RenderObject，findRenderObject 会直接拿到列表
          // 自身的盒子（正好等于视口），供 [_resolveRowIndexAt] 做比例换算。
          child: KeyedSubtree(
            key: _listViewportKey,
            child: ScrollablePositionedList.builder(
              // ItemPosition storage must not share the page's key with
              // TextField scroll offsets (double) or other scrollables.
              key: const PageStorageKey('subtitle-positioned-list'),
              itemScrollController: _itemScrollController,
              itemPositionsListener: _itemPositionsListener,
              scrollOffsetController: _listScrollOffsetController,
              initialScrollIndex: effectiveInitialIndex,
              initialAlignment: effectiveInitialAlignment,
              itemCount: displaySubtitles.length + (footer == null ? 0 : 1),
              shrinkWrap: shouldTopAlign,
              physics: shouldTopAlign
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemBuilder: (context, index) {
                if (index == displaySubtitles.length) return footer!;
                final item = displaySubtitles[index];
                final timeText = _formatDuration(item.startTime);
                final subtitleText =
                    (item.text.isEmpty && item.imageLoader != null)
                    ? "[图片字幕]"
                    : _getFilteredText(item.text, index);
                return _keepSelectionNodeAlive(
                  SubtitleActiveRangeBuilder(
                    valueListenable: _activeIndicesNotifier,
                    startIndex: index,
                    endIndex: index + 1,
                    contentKey: (
                      _readingTextRevision,
                      subtitleText,
                      timeText,
                      isSmallScreen,
                      _fontSizeScale,
                      _showTimestamps,
                      _timeColumnRatio,
                      _hasSelectableTextAfter(index),
                    ),
                    builder: (context, activeIndices, _) {
                      final isCurrent = activeIndices.contains(index);

                      return RepaintBoundary(
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: isSmallScreen ? 2 : 6,
                            right: isSmallScreen ? 2 : 6,
                            bottom: itemGap,
                          ),
                          child: InkWell(
                            // 不能用 onTapDown：按住约 100ms 就会触发，长按/
                            // 滑动浏览/拖选用字都会被误判成单击并 seek。
                            onTap: () => _completeSubtitleTap(index),
                            canRequestFocus: false,
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: innerH,
                                vertical: innerV,
                              ),
                              decoration: BoxDecoration(
                                color: isCurrent
                                    ? Colors.blueAccent.withValues(alpha: 0.15)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: isCurrent
                                      ? Colors.blueAccent.withValues(alpha: 0.3)
                                      : Colors.transparent,
                                ),
                              ),
                              child: LayoutBuilder(
                                builder: (context, itemConstraints) {
                                  final timeColumnWidth =
                                      itemConstraints.maxWidth *
                                      _timeColumnRatio;
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (_showTimestamps)
                                        SelectionContainer.disabled(
                                          child: SizedBox(
                                            key: ValueKey(
                                              'subtitle-time-column-$index',
                                            ),
                                            width: timeColumnWidth,
                                            child: Padding(
                                              padding: EdgeInsets.only(
                                                top: 2 * scale,
                                                right: timeGap,
                                              ),
                                              child: Align(
                                                alignment: Alignment.topLeft,
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  alignment: Alignment.topLeft,
                                                  child: Text(
                                                    timeText,
                                                    key: ValueKey(
                                                      'subtitle-time-$index',
                                                    ),
                                                    maxLines: 1,
                                                    style: TextStyle(
                                                      color: isCurrent
                                                          ? Colors.blueAccent
                                                          : Colors.white30,
                                                      fontSize:
                                                          (isSmallScreen
                                                              ? 10
                                                              : 11) *
                                                          _fontSizeScale,
                                                      fontFamily: 'monospace',
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      Expanded(
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            Text(
                                              subtitleText,
                                              strutStyle: StrutStyle(
                                                fontSize: _subtitleTextFontSize(
                                                  isSmallScreen,
                                                ),
                                                height: 1.3,
                                                forceStrutHeight: true,
                                              ),
                                              style: TextStyle(
                                                color: isCurrent
                                                    ? Colors.white
                                                    : Colors.white70,
                                                fontSize: _subtitleTextFontSize(
                                                  isSmallScreen,
                                                ),
                                                height: 1.3,
                                                fontWeight: FontWeight.normal,
                                              ),
                                            ),
                                            if (_hasSelectableTextAfter(index))
                                              Positioned(
                                                right: 0,
                                                bottom: 0,
                                                child: Text(
                                                  ' ',
                                                  key: ValueKey(
                                                    'subtitle-separator-$index',
                                                  ),
                                                  // This selectable spacer keeps
                                                  // copied cues separated without
                                                  // painting an isolated blue
                                                  // selection bar at the far edge
                                                  // of the row.
                                                  selectionColor:
                                                      Colors.transparent,
                                                  style: TextStyle(
                                                    fontSize:
                                                        _subtitleTextFontSize(
                                                          isSmallScreen,
                                                        ),
                                                    height: 1.3,
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
        return shouldTopAlign
            ? Align(alignment: Alignment.topCenter, child: list)
            : list;
      },
    );
  }

  // 文章模式视图
  Widget _buildArticleView(bool isSmallScreen) {
    if (_isContinuousArticleMode) {
      return _buildContinuousArticleView(isSmallScreen);
    }
    final displaySubtitles = _displaySubtitles;
    final footer = _generationFooter();
    final int chunkCount = (displaySubtitles.length / _articleChunkSize).ceil();
    final double verticalInset = _articleVerticalInset(isSmallScreen);
    final int activeIndex = _activeIndexNotifier.value;
    final int initialChunkIndex = (activeIndex >= 0
        ? (activeIndex ~/ _articleChunkSize)
        : 0);

    return LayoutBuilder(
      builder: (context, constraints) {
        _handleScrollableViewportLayout(constraints);
        final bool shouldTopAlign = _shouldTopAlignArticle(
          context: context,
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          isSmallScreen: isSmallScreen,
          chunkCount: chunkCount,
        );
        if (shouldTopAlign &&
            _paragraphFitsViewport == false &&
            _articleItemScrollController.isAttached) {
          _articleItemScrollController.jumpTo(index: 0);
        }
        _paragraphFitsViewport = shouldTopAlign;
        // 当字幕数量不足时，强制从顶部开始显示，忽略当前索引
        final int effectiveInitialChunkIndex = shouldTopAlign
            ? 0
            : (initialChunkIndex < chunkCount ? initialChunkIndex : 0);
        final double effectiveInitialAlignment = shouldTopAlign
            ? 0.0
            : _locateAlignment;

        final list = NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: KeyedSubtree(
            key: _listViewportKey,
            child: ScrollablePositionedList.builder(
              key: PageStorageKey('subtitle-article-list-$_articleChunkSize'),
              itemScrollController: _articleItemScrollController,
              itemPositionsListener: _articleItemPositionsListener,
              scrollOffsetController: _articleScrollOffsetController,
              initialScrollIndex: effectiveInitialChunkIndex,
              initialAlignment: effectiveInitialAlignment,
              itemCount: chunkCount + (footer == null ? 0 : 1),
              padding: EdgeInsets.symmetric(
                horizontal: _subtitleTextHorizontalInset(isSmallScreen),
              ),
              shrinkWrap: shouldTopAlign,
              physics: shouldTopAlign
                  ? const NeverScrollableScrollPhysics()
                  : null,
              itemBuilder: (context, chunkIndex) {
                if (chunkIndex == chunkCount) return footer!;
                final int startIndex = chunkIndex * _articleChunkSize;
                final int endIndex =
                    (startIndex + _articleChunkSize) > displaySubtitles.length
                    ? displaySubtitles.length
                    : startIndex + _articleChunkSize;

                return _keepSelectionNodeAlive(
                  SubtitleActiveRangeBuilder(
                    valueListenable: _activeIndicesNotifier,
                    startIndex: startIndex,
                    endIndex: endIndex,
                    contentKey: (
                      _readingTextRevision,
                      isSmallScreen,
                      _fontSizeScale,
                      verticalInset,
                      chunkIndex == chunkCount - 1,
                      _hasSelectableTextAfter(endIndex - 1),
                    ),
                    builder: (context, activeIndices, child) {
                      return RepaintBoundary(
                        child: Padding(
                          padding: EdgeInsets.only(
                            top: chunkIndex == 0 ? verticalInset : 0,
                            bottom: chunkIndex == chunkCount - 1
                                ? verticalInset
                                : 0,
                          ),
                          child: SubtitleArticleChunk(
                            key: _articleChunkKeys.putIfAbsent(
                              chunkIndex,
                              () => GlobalKey<State<SubtitleArticleChunk>>(),
                            ),
                            subtitles: displaySubtitles,
                            displayTexts: _selectionTextCache,
                            startIndex: startIndex,
                            endIndex: endIndex,
                            activeIndices: activeIndices.toSet(),
                            fontSizeScale: _fontSizeScale,
                            onSubtitleTap: _completeSubtitleTap,
                            isSmallScreen: isSmallScreen,
                            lineFilterMode: _lineFilterMode,
                            secondaryTextCache: _secondaryTextCache,
                            isBilingualMode: _isBilingualMode,
                            usesSecondaryTrackForDisplay:
                                _usesSecondaryTrackForDisplay,
                            appendTrailingSeparator: _hasSelectableTextAfter(
                              endIndex - 1,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        );
        return shouldTopAlign
            ? Align(alignment: Alignment.topCenter, child: list)
            : list;
      },
    );
  }

  Widget _buildContinuousArticleView(bool isSmallScreen) {
    _ensureContinuousArticleDocument();
    return LayoutBuilder(
      builder: (context, constraints) {
        _handleScrollableViewportLayout(constraints);
        final double horizontalInset = _subtitleTextHorizontalInset(
          isSmallScreen,
        );
        final double contentWidth = constraints.maxWidth - horizontalInset * 2;
        final double fontSize = (isSmallScreen ? 12 : 13) * _fontSizeScale;
        final TextStyle style = DefaultTextStyle.of(context).style.copyWith(
          color: Colors.white70,
          fontSize: fontSize,
          height: 1.6,
          fontWeight: FontWeight.normal,
        );
        final document = _continuousArticleDocument;
        if (document == null) return _continuousArticlePreparing();

        // 宽度还在变、页面被盖住、或文稿区不可见时，不开始新的排版。
        // 屏幕上已经有的文章继续留着，避免整块换成「正在准备文章」。
        if ((_continuousArticleDocumentDirty &&
                !_continuousArticleDocumentAppendPending) ||
            !_canStartContinuousArticleLayout(contentWidth)) {
          _cancelMismatchedContinuousArticleLayout(null);
          final ArticleLayout? fallback = _fallbackContinuousArticleLayout(
            document,
          );
          if (fallback != null) {
            return FutureBuilder<ArticleLayout?>(
              future: null,
              builder: (context, snapshot) => _presentContinuousArticleLayout(
                document: document,
                layout: fallback,
                style: style,
                horizontalInset: horizontalInset,
                isSmallScreen: isSmallScreen,
                clip: true,
              ),
            );
          }
          return _continuousArticlePreparing();
        }

        final layoutKey = ArticleLayoutKey(
          documentGeneration: document.generation,
          width: contentWidth,
          style: style,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        );
        final cached = _cachedContinuousArticleLayout(layoutKey);
        final fallback = cached ?? _fallbackContinuousArticleLayout(document);
        final clip = cached == null;
        Future<ArticleLayout?>? future;
        if (cached != null) {
          _cancelMismatchedContinuousArticleLayout(layoutKey);
          _continuousArticleDeferredKey = null;
          _displayContinuousArticleLayout(cached);
        } else {
          final futureMatches =
              _continuousArticleLayoutFuture != null &&
              _continuousArticlePendingKey == layoutKey;
          if (fallback != null &&
              !futureMatches &&
              !_isContinuousArticleLayoutDeferredStable(layoutKey)) {
            _cancelMismatchedContinuousArticleLayout(layoutKey);
            _deferContinuousArticleLayout(layoutKey);
          } else {
            _continuousArticleDeferredKey = null;
            _ensureContinuousArticleLayout(document, layoutKey);
            future = _continuousArticleLayoutFuture;
          }
        }

        // Keep this shell even for cache hits. Switching between a direct view
        // and FutureBuilder, or inserting/removing ClipRect while appending,
        // reparents the GlobalKey document and dirties every mounted text line.
        return FutureBuilder<ArticleLayout?>(
          future: future,
          builder: (context, snapshot) {
            final layout = snapshot.data;
            var presented = fallback;
            var needsClip = clip;
            if (future != null &&
                snapshot.connectionState == ConnectionState.done &&
                layout != null &&
                (layout.key == layoutKey ||
                    _continuousArticleIsAppend &&
                        _sameArticleGeometry(layout.key, layoutKey))) {
              _displayContinuousArticleLayout(layout);
              presented = layout;
              needsClip = false;
              if (layout.key != layoutKey) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
              }
            } else if (future != null &&
                snapshot.connectionState == ConnectionState.done &&
                !snapshot.hasError &&
                identical(future, _continuousArticleLayoutFuture)) {
              _retryContinuousArticleLayoutAfterRejectedFuture();
            }
            if (presented == null) return _continuousArticlePreparing();
            return _presentContinuousArticleLayout(
              document: document,
              layout: presented,
              style: style,
              horizontalInset: horizontalInset,
              isSmallScreen: isSmallScreen,
              clip: needsClip,
            );
          },
        );
      },
    );
  }

  Widget _continuousArticlePreparing() {
    return const Center(
      child: Text(
        '正在准备文章…',
        key: ValueKey('subtitle-continuous-article-preparing'),
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
  }

  Widget _presentContinuousArticleLayout({
    required ArticleDocument document,
    required ArticleLayout layout,
    required TextStyle style,
    required double horizontalInset,
    required bool isSmallScreen,
    required bool clip,
  }) {
    final previous = _translationPreviousDocument;
    if (previous != null &&
        layout.key.documentGeneration == previous.generation) {
      document = previous;
    }
    final Widget view = _buildResolvedContinuousArticleView(
      document: document,
      layout: layout,
      style: style,
      horizontalInset: horizontalInset,
      isSmallScreen: isSmallScreen,
    );
    // Retain one element path while a streamed suffix or resized layout is
    // being prepared; only clipping changes, never the reading surface itself.
    return ClipRect(
      clipBehavior: clip ? Clip.hardEdge : Clip.none,
      child: view,
    );
  }

  Widget _buildResolvedContinuousArticleView({
    required ArticleDocument document,
    required ArticleLayout layout,
    required TextStyle style,
    required double horizontalInset,
    required bool isSmallScreen,
  }) {
    final activeIndex = _activeIndexNotifier.value;
    final initialIndex = activeIndex >= 0 ? activeIndex : 0;
    final double verticalInset = _articleVerticalInset(isSmallScreen);
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ContinuousArticleView(
        key: _continuousArticleViewKey,
        viewportKey: _listViewportKey,
        document: document,
        layout: layout,
        style: style,
        highlightStyle: style.copyWith(
          color: Colors.blueAccent,
          backgroundColor: Colors.blueAccent.withValues(alpha: 0.1),
        ),
        activeIndices: _activeIndicesNotifier,
        itemScrollController: _articleItemScrollController,
        itemPositionsListener: _articleItemPositionsListener,
        scrollOffsetController: _articleScrollOffsetController,
        keepSelectionAlive: _hasTextSelection,
        onScrollableChanged: _handleSelectionScrollableChanged,
        footer: _generationFooter(),
        footerExtent: _generationFooterExtent,
        onSubtitleTap: _completeSubtitleTap,
        initialSentenceIndex: initialIndex,
        // The first natural line cannot scroll beyond the document's start.
        // A cold indexed viewport anchored at 30% initially has pixels=0 below
        // its positive minimum and starts a spring before any locate repair.
        // That activity steals a first-frame long press on Android.
        initialAlignment: initialIndex == 0 ? 0 : _locateAlignment,
        padding: EdgeInsets.fromLTRB(
          horizontalInset,
          verticalInset,
          horizontalInset,
          verticalInset,
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }
}

class _SelectionKeepAlive extends StatefulWidget {
  const _SelectionKeepAlive({required this.keepAlive, required this.child});

  final bool keepAlive;
  final Widget child;

  @override
  State<_SelectionKeepAlive> createState() => _SelectionKeepAliveState();
}

class _SelectionKeepAliveState extends State<_SelectionKeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(covariant _SelectionKeepAlive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAlive != widget.keepAlive) updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _TranscriptScrollableObserver extends StatefulWidget {
  const _TranscriptScrollableObserver({
    required this.onScrollableChanged,
    required this.child,
  });

  final ValueChanged<ScrollableState> onScrollableChanged;
  final Widget child;

  @override
  State<_TranscriptScrollableObserver> createState() =>
      _TranscriptScrollableObserverState();
}

class _TranscriptScrollableObserverState
    extends State<_TranscriptScrollableObserver> {
  ScrollableState? _scrollable;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context);
    if (next == null || identical(next, _scrollable)) return;
    _scrollable = next;
    widget.onScrollableChanged(next);
  }

  @override
  void didUpdateWidget(covariant _TranscriptScrollableObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onScrollableChanged != widget.onScrollableChanged &&
        _scrollable != null) {
      widget.onScrollableChanged(_scrollable!);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SelectionStatusObserver extends StatefulWidget {
  const _SelectionStatusObserver({
    required this.onStatusChanged,
    required this.child,
  });

  final ValueChanged<SelectableRegionSelectionStatus> onStatusChanged;
  final Widget child;

  @override
  State<_SelectionStatusObserver> createState() =>
      _SelectionStatusObserverState();
}

class _SelectionStatusObserverState extends State<_SelectionStatusObserver> {
  ValueListenable<SelectableRegionSelectionStatus>? _notifier;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = SelectableRegionSelectionStatusScope.maybeOf(context);
    if (identical(next, _notifier)) return;
    _notifier?.removeListener(_notifyParent);
    _notifier = next;
    _notifier?.addListener(_notifyParent);
    _notifyParent();
  }

  void _notifyParent() {
    final status = _notifier?.value;
    if (status != null) widget.onStatusChanged(status);
  }

  @override
  void didUpdateWidget(covariant _SelectionStatusObserver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onStatusChanged != widget.onStatusChanged) {
      _notifyParent();
    }
  }

  @override
  void dispose() {
    _notifier?.removeListener(_notifyParent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Keep hit testing enabled for programmatic reading motion. Flutter's default
/// driven activity ignores its viewport, so its first tap can only stop motion.
/// User drags/flings continue to use the scrollable's ordinary activities.
class _TranscriptScrollActivity extends DrivenScrollActivity {
  _TranscriptScrollActivity.simulation(
    super.delegate,
    super.simulation, {
    required super.vsync,
  }) : super.simulation();

  double? _stoppedVelocity;

  // Scrollable may enter HoldScrollActivity before the outer pointer listener
  // sees the down event. Keep that just-interrupted velocity for the tap record.
  double get readingVelocity => _stoppedVelocity ?? velocity;

  @override
  void dispose() {
    _stoppedVelocity = velocity;
    super.dispose();
  }

  @override
  bool get shouldIgnorePointer => false;
}

class _ReadingScrollMomentum {
  _ReadingScrollMomentum(this.position, this.velocity)
    : _capturedAtMs = DateTime.now().millisecondsSinceEpoch;

  final ScrollPosition position;
  final double velocity;
  final int _capturedAtMs;

  bool get isFresh {
    final elapsed = DateTime.now().millisecondsSinceEpoch - _capturedAtMs;
    return elapsed >= 0 && elapsed <= 150;
  }
}

/// 侧边栏内一根手指按下时的快照，服务于「拖拽中副指针双击」判定。
class _SidebarPointerRecord {
  _SidebarPointerRecord({
    required this.downPosition,
    required this.downTimeMs,
    required this.kind,
    required this.inListArea,
    required this.anchorPointerIds,
    required this.rowIndex,
    this.interruptedViewportMotion = false,
    this.readingMomentum,
  });

  /// 落点（全局坐标），用于位移判定与「两次点是否同一根手指」判定。
  final Offset downPosition;

  /// 取自事件时间戳而非墙上时钟，和后续的抬起事件同源，不受帧调度抖动影响。
  final int downTimeMs;

  final PointerDeviceKind kind;

  /// 落点是否在字幕列表区（而非顶部工具栏）。
  final bool inListArea;

  /// 本指针按下瞬间，列表区内已按住的其他指针 id。非空即表示它是副指针。
  final Set<int> anchorPointerIds;

  /// 落点命中的字幕行号；null 表示没落在任何一行上（行间空隙、空白区等）。
  final int? rowIndex;

  final bool interruptedViewportMotion;
  final _ReadingScrollMomentum? readingMomentum;

  /// 离落点的最远距离；超过 slop 即认为这根手指在滑动而非点击。
  double maxTravel = 0;
}

/// 一次已被接受的候选轻点，等待在 300ms 内被第二次轻点凑成双击。
class _SidebarTapRecord {
  const _SidebarTapRecord({
    required this.rowIndex,
    required this.downPosition,
    required this.upTimeMs,
    required this.anchorPointerIds,
  });

  final int rowIndex;
  final Offset downPosition;
  final int upTimeMs;

  /// 第一次轻点时按住的锚定手指；第二次轻点必须与其中至少一根仍然重合。
  final Set<int> anchorPointerIds;
}

class SubtitleArticleChunk extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final List<String> displayTexts;
  final int startIndex;
  final int endIndex;
  final Set<int> activeIndices;
  final double fontSizeScale;
  final ValueChanged<int>? onSubtitleTap;
  final bool isSmallScreen;
  final int lineFilterMode;
  final Map<int, String> secondaryTextCache;
  final bool isBilingualMode;
  final bool usesSecondaryTrackForDisplay;
  final bool appendTrailingSeparator;

  const SubtitleArticleChunk({
    super.key,
    required this.subtitles,
    required this.displayTexts,
    required this.startIndex,
    required this.endIndex,
    required this.activeIndices,
    required this.fontSizeScale,
    this.onSubtitleTap,
    required this.isSmallScreen,
    required this.lineFilterMode,
    this.secondaryTextCache = const {},
    this.isBilingualMode = false,
    this.usesSecondaryTrackForDisplay = false,
    this.appendTrailingSeparator = false,
  });

  @override
  State<SubtitleArticleChunk> createState() => _SubtitleArticleChunkState();
}

class _SubtitleArticleChunkState extends State<SubtitleArticleChunk> {
  final Map<int, TapGestureRecognizer> _recognizers =
      <int, TapGestureRecognizer>{};

  /// 段落文本的 key，用于把全局坐标换算进 [RenderParagraph]。
  final GlobalKey _paragraphKey = GlobalKey();

  /// 每个 span 对应的字幕行号；[InlineSpan] 用身份相等，可直接做 key。
  final Map<InlineSpan, int> _spanSubtitleIndex = <InlineSpan, int>{};

  /// 把全局坐标定位到本段落内的字幕行号；不在本段落内则返回 null。
  ///
  /// 拖拽期间 Scrollable 会用 IgnorePointer 屏蔽视口内部，span 上的
  /// [TapGestureRecognizer] 收不到事件，只能这样直接问排版结果。
  int? subtitleIndexAtGlobalPosition(Offset globalPosition) {
    final RenderObject? root = _paragraphKey.currentContext?.findRenderObject();
    final RenderParagraph? paragraph = root == null
        ? null
        : _findParagraph(root);
    if (paragraph == null || !paragraph.hasSize) return null;
    final Offset local = paragraph.globalToLocal(globalPosition);
    if (!(Offset.zero & paragraph.size).contains(local)) return null;
    final InlineSpan? span = paragraph.text.getSpanForPosition(
      paragraph.getPositionForOffset(local),
    );
    return span == null ? null : _spanSubtitleIndex[span];
  }

  /// [Text.rich] 外层可能还套着 Semantics 等包装，这里向下找到真正的段落。
  RenderParagraph? _findParagraph(RenderObject object) {
    if (object is RenderParagraph) return object;
    RenderParagraph? found;
    object.visitChildren((RenderObject child) {
      found ??= _findParagraph(child);
    });
    return found;
  }

  @override
  void initState() {
    super.initState();
    _syncRecognizers();
  }

  @override
  void didUpdateWidget(covariant SubtitleArticleChunk oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅在索引范围变化时重建 recognizer，回调引用变化不触发重建
    if (oldWidget.startIndex != widget.startIndex ||
        oldWidget.endIndex != widget.endIndex) {
      _disposeRecognizers();
      _syncRecognizers();
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _syncRecognizers() {
    if (widget.onSubtitleTap == null) {
      return;
    }
    for (int i = widget.startIndex; i < widget.endIndex; i++) {
      // 只认 onTap：onTapDown 会在按住约 100ms 时触发，长按选字会被误 seek。
      _recognizers[i] = TapGestureRecognizer()
        ..onTap = () {
          widget.onSubtitleTap?.call(i);
        };
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final List<InlineSpan> spans = <InlineSpan>[];
    _spanSubtitleIndex.clear();

    for (int i = widget.startIndex; i < widget.endIndex; i++) {
      final item = widget.subtitles[i];
      final isCurrent = widget.activeIndices.contains(i);
      String rawText = i >= 0 && i < widget.displayTexts.length
          ? widget.displayTexts[i]
          : '';
      if (rawText.isEmpty && item.imageLoader != null) {
        rawText = "[图片字幕]";
      }
      final text = rawText.replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty) continue;
      if (spans.isNotEmpty) {
        spans.add(const TextSpan(text: ' '));
      }
      final TextSpan span = TextSpan(
        text: text,
        recognizer: _recognizers[i],
        style: TextStyle(
          color: isCurrent ? Colors.blueAccent : Colors.white70,
          backgroundColor: isCurrent
              ? Colors.blueAccent.withValues(alpha: 0.1)
              : Colors.transparent,
          fontSize: (widget.isSmallScreen ? 12 : 13) * widget.fontSizeScale,
          height: 1.6,
          // Keep weight stable in article mode to avoid paragraph reflow.
          fontWeight: FontWeight.normal,
        ),
      );
      _spanSubtitleIndex[span] = i;
      spans.add(span);
    }

    final TextStyle separatorStyle = TextStyle(
      fontSize: (widget.isSmallScreen ? 12 : 13) * widget.fontSizeScale,
      height: 1.6,
    );
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Text.rich(
          key: _paragraphKey,
          TextSpan(children: spans),
          textAlign: TextAlign.start,
          softWrap: true,
          strutStyle: StrutStyle(
            fontSize: (widget.isSmallScreen ? 12 : 13) * widget.fontSizeScale,
            height: 1.6,
            forceStrutHeight: true,
          ),
        ),
        if (widget.appendTrailingSeparator)
          Positioned(
            right: 0,
            bottom: 0,
            child: Text(
              ' ',
              key: ValueKey('subtitle-article-separator-${widget.startIndex}'),
              selectionColor: Colors.transparent,
              style: separatorStyle,
            ),
          ),
      ],
    );
  }
}

class _LocatePositionInputWidget extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;

  const _LocatePositionInputWidget({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_LocatePositionInputWidget> createState() =>
      _LocatePositionInputWidgetState();
}

class _LocatePositionInputWidgetState
    extends State<_LocatePositionInputWidget> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _LocatePositionInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && widget.value != oldWidget.value) {
      _setText(widget.value);
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      _commitText();
    }
  }

  void _setText(int value) {
    final text = value.toString();
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _handleTextChanged(String text) {
    if (text.isEmpty) return;
    final parsed = int.tryParse(text);
    if (parsed == null) return;
    final value = parsed.clamp(0, 100);
    if (value != parsed) {
      _setText(value);
    }
    widget.onChanged(value);
  }

  void _commitText() {
    final parsed = int.tryParse(_controller.text);
    final value = (parsed ?? widget.value).clamp(0, 100);
    _setText(value);
    widget.onChanged(value);
  }

  void _step(int delta) {
    final parsed = int.tryParse(_controller.text) ?? widget.value;
    final value = (parsed + delta).clamp(0, 100);
    _setText(value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    const borderColor = Colors.white24;
    final input = SizedBox(
      key: const ValueKey('subtitle-locate-position-input'),
      height: 28,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(4),
          color: Colors.black.withValues(alpha: 0.16),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('subtitle-locate-position-text-field'),
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                maxLines: 1,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                cursorColor: Colors.blueAccent,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 4),
                ),
                onChanged: _handleTextChanged,
                onSubmitted: (_) => _commitText(),
              ),
            ),
            const Text(
              '%',
              key: ValueKey('subtitle-locate-position-percent-unit'),
              style: TextStyle(fontSize: 11, color: Colors.white60),
            ),
            const SizedBox(width: 4),
            Container(width: 1, color: borderColor),
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  _buildStepButton(
                    key: const ValueKey('subtitle-locate-position-increment'),
                    icon: Icons.keyboard_arrow_up,
                    onTap: () => _step(10),
                  ),
                  _buildStepButton(
                    key: const ValueKey('subtitle-locate-position-decrement'),
                    icon: Icons.keyboard_arrow_down,
                    onTap: () => _step(-10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return TextFieldTapRegion(child: input);
  }

  Widget _buildStepButton({
    required Key key,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      key: key,
      width: 28,
      height: 14,
      child: InkWell(
        onTap: onTap,
        child: Icon(icon, size: 11, color: Colors.white60),
      ),
    );
  }
}

class _SentenceCountInputWidget extends StatefulWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _SentenceCountInputWidget({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  State<_SentenceCountInputWidget> createState() =>
      _SentenceCountInputWidgetState();
}

class _SentenceCountInputWidgetState extends State<_SentenceCountInputWidget> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode()..addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _SentenceCountInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && widget.value != oldWidget.value) {
      _setText(widget.value);
    }
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_handleFocusChanged)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChanged() {
    if (!_focusNode.hasFocus) {
      _commitText();
    }
  }

  void _setText(int value) {
    final text = value.toString();
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _handleTextChanged(String text) {
    if (text.isEmpty) return;
    final parsed = int.tryParse(text);
    if (parsed == null) return;
    final value = parsed.clamp(widget.min, widget.max);
    if (value != parsed) {
      _setText(value);
    }
    widget.onChanged(value);
  }

  void _commitText() {
    final parsed = int.tryParse(_controller.text);
    final value = (parsed ?? widget.value).clamp(widget.min, widget.max);
    _setText(value);
    widget.onChanged(value);
  }

  void _step(int delta) {
    final parsed = int.tryParse(_controller.text) ?? widget.value;
    final value = (parsed + delta).clamp(widget.min, widget.max);
    _setText(value);
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    const borderColor = Colors.white24;
    final input = SizedBox(
      key: const ValueKey('subtitle-sentences-per-paragraph-input'),
      height: 28,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(4),
          color: Colors.black.withValues(alpha: 0.16),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey(
                  'subtitle-sentences-per-paragraph-text-field',
                ),
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLines: 1,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                cursorColor: Colors.blueAccent,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 4),
                ),
                onChanged: _handleTextChanged,
                onSubmitted: (_) => _commitText(),
              ),
            ),
            Container(width: 1, color: borderColor),
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  _buildStepButton(
                    key: const ValueKey(
                      'subtitle-sentences-per-paragraph-increment',
                    ),
                    icon: Icons.keyboard_arrow_up,
                    onTap: () => _step(1),
                  ),
                  _buildStepButton(
                    key: const ValueKey(
                      'subtitle-sentences-per-paragraph-decrement',
                    ),
                    icon: Icons.keyboard_arrow_down,
                    onTap: () => _step(-1),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return TextFieldTapRegion(child: input);
  }

  Widget _buildStepButton({
    required Key key,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      key: key,
      width: 28,
      height: 14,
      child: InkWell(
        onTap: onTap,
        child: Icon(icon, size: 11, color: Colors.white60),
      ),
    );
  }
}

/// 独立的字体缩放滑块 Widget
///
/// 将 Slider 提取为独立 StatefulWidget，拖动过程中仅自身内部重建，
/// 不触发父级 SubtitleSidebar 的完整 build，降低大列表场景下的帧率抖动。
class _FontSizeSliderWidget extends StatefulWidget {
  /// 当前字体缩放比例（由父级传入，用于外部同步时刷新）
  final double fontSizeScale;

  /// 拖动过程中实时回调
  final ValueChanged<double> onChanged;

  /// 拖动结束后的持久化回调
  final ValueChanged<double> onCommit;
  final bool showValue;

  const _FontSizeSliderWidget({
    required this.fontSizeScale,
    required this.onChanged,
    required this.onCommit,
    this.showValue = true,
  });

  @override
  State<_FontSizeSliderWidget> createState() => _FontSizeSliderWidgetState();
}

class _FontSizeSliderWidgetState extends State<_FontSizeSliderWidget> {
  double? _hapticStartValue;

  /// 拖动中的临时滑块值（仅影响 Slider 显示）
  double? _dragValue;

  // 字体缩放比例与滑块值的转换（与父级保持一致）
  double _fontScaleToSliderValue(double scale) {
    final double clamped = scale.clamp(0.5, 3.0).toDouble();
    if (clamped <= 0.7) {
      return ((clamped - 0.5) / 0.2) * 10.0;
    }
    if (clamped <= 1.0) {
      return 10.0 + ((clamped - 0.7) / 0.3) * 60.0;
    }
    return 70.0 + ((clamped - 1.0) / 2.0) * 30.0;
  }

  double _sliderValueToFontScale(double sliderValue) {
    final double clamped = sliderValue.clamp(0.0, 100.0).toDouble();
    if (clamped <= 10.0) {
      return 0.5 + (clamped / 10.0) * 0.2;
    }
    if (clamped <= 70.0) {
      return 0.7 + ((clamped - 10.0) / 60.0) * 0.3;
    }
    return 1.0 + ((clamped - 70.0) / 30.0) * 2.0;
  }

  @override
  Widget build(BuildContext context) {
    final displayScale = _dragValue != null
        ? _sliderValueToFontScale(_dragValue!)
        : widget.fontSizeScale;

    return SizedBox(
      height: 28,
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(
                key: const ValueKey('subtitle-font-size-slider'),
                value: _fontScaleToSliderValue(displayScale),
                min: 0.0,
                max: 100.0,
                activeColor: Colors.blueAccent,
                inactiveColor: Colors.white24,
                onChangeStart: (value) {
                  _hapticStartValue = value;
                  unawaited(AppHaptics.dragStarted(SettingsService()));
                  setState(() => _dragValue = value);
                },
                onChanged: (value) {
                  setState(() => _dragValue = value);
                  widget.onChanged(_sliderValueToFontScale(value));
                },
                onChangeEnd: (value) {
                  if (_hapticStartValue != null && value != _hapticStartValue) {
                    unawaited(AppHaptics.dragCommitted(SettingsService()));
                  }
                  _hapticStartValue = null;
                  setState(() => _dragValue = null);
                  widget.onCommit(_sliderValueToFontScale(value));
                },
              ),
            ),
          ),
          if (widget.showValue)
            SizedBox(
              width: 34,
              child: Text(
                "${(displayScale * 100).round()}%",
                style: const TextStyle(fontSize: 10, color: Colors.white60),
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  }
}

/// 独立的时间列比例滑块，拖动期间仅重建滑块自身。
class _TimeColumnRatioSliderWidget extends StatefulWidget {
  final double ratio;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final bool showValue;

  const _TimeColumnRatioSliderWidget({
    required this.ratio,
    required this.onChanged,
    required this.onCommit,
    this.showValue = true,
  });

  @override
  State<_TimeColumnRatioSliderWidget> createState() =>
      _TimeColumnRatioSliderWidgetState();
}

class _TimeColumnRatioSliderWidgetState
    extends State<_TimeColumnRatioSliderWidget> {
  double? _dragValue;
  double? _hapticStartValue;

  @override
  Widget build(BuildContext context) {
    final displayRatio = (_dragValue ?? widget.ratio)
        .clamp(0.05, 0.30)
        .toDouble();

    return SizedBox(
      height: 28,
      child: Row(
        children: [
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                showValueIndicator: ShowValueIndicator.never,
              ),
              child: Slider(
                key: const ValueKey('subtitle-time-column-slider'),
                value: displayRatio,
                min: 0.05,
                max: 0.30,
                activeColor: Colors.blueAccent,
                inactiveColor: Colors.white24,
                onChangeStart: (value) {
                  _hapticStartValue = value;
                  unawaited(AppHaptics.dragStarted(SettingsService()));
                  setState(() => _dragValue = value);
                },
                onChanged: (value) {
                  setState(() => _dragValue = value);
                  widget.onChanged(value);
                },
                onChangeEnd: (value) {
                  if (_hapticStartValue != null && value != _hapticStartValue) {
                    unawaited(AppHaptics.dragCommitted(SettingsService()));
                  }
                  _hapticStartValue = null;
                  setState(() => _dragValue = null);
                  widget.onCommit(value);
                },
              ),
            ),
          ),
          if (widget.showValue)
            SizedBox(
              width: 34,
              child: Text(
                "${(displayRatio * 100).round()}%",
                style: const TextStyle(fontSize: 10, color: Colors.white60),
                textAlign: TextAlign.right,
              ),
            ),
        ],
      ),
    );
  }
}
