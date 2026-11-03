import 'dart:async';
import '../models/subtitle_stream.dart';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../controllers/music_lyric_pointer_transaction.dart';
import '../controllers/music_lyric_selection_controller.dart';
import '../debug/music_lyric_frame_probe.dart';
import '../models/music_lyric_display_mode.dart';
import '../models/music_lyric_typography.dart';
import '../models/subtitle_model.dart';
import '../services/music_lyric_content_resolver.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import 'music_text_optical_alignment.dart';
import 'music_timed_lyric_text.dart';
import 'music_lyric_frame_coordinator.dart';
import '../services/subtitle_timeline_resolver.dart';

@visibleForTesting
int musicLyricTapScrollDurationMs(int lineDistance) {
  return (580 + lineDistance.abs() * 42).clamp(580, 820);
}

@visibleForTesting
const Curve musicLyricTapScrollCurve = Cubic(0.32, 0.0, 0.18, 1.0);

BoxDecoration _lyricPressDecoration(double fontSize) => BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Colors.white.withValues(alpha: 0.26),
      Colors.white.withValues(alpha: 0.14),
    ],
  ),
  borderRadius: BorderRadius.circular((fontSize * 0.50).clamp(10.0, 20.0)),
  border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.14),
      blurRadius: (fontSize * 0.45).clamp(10.0, 18.0),
      offset: Offset(0, (fontSize * 0.175).clamp(4.0, 7.0)),
    ),
  ],
);

bool _pressShadersWarmed = false;

Future<void> _warmPressShaders(double fontSize, double pixelRatio) async {
  // Compile the actual gradient, rounded border and soft-shadow pipelines
  // before the first press. This small offscreen image never enters the UI.
  final painter = _lyricPressDecoration(fontSize).createBoxPainter();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(pixelRatio);
  const size = Size(320, 100);
  painter.paint(
    canvas,
    const Offset(32, 32),
    const ImageConfiguration(size: size, textDirection: TextDirection.ltr),
  );
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(
      (384 * pixelRatio).ceil(),
      (164 * pixelRatio).ceil(),
    );
    image.dispose();
  } catch (error) {
    // Warming is optional; normal decoration painting remains authoritative.
    debugPrint('Lyric press shader warmup failed: $error');
  } finally {
    picture.dispose();
    painter.dispose();
  }
}

/// Sends explicit, repeatable lyric-location commands. Unlike a
/// `ValueNotifier<Duration>`, equal positions are not deduplicated: every scrub
/// release is a real request and a newer request may interrupt the old one.
class MusicLyricPositionController extends ChangeNotifier {
  Duration _position = Duration.zero;

  Duration get position => _position;

  void locate(Duration position) {
    _position = position;
    notifyListeners();
  }
}

/// Apple Music 风格歌词列表视图（响应式 vh 单位）
///
/// 自实现版本（不再依赖 flutter_lyric），修复以下问题：
/// - 鼠标滚轮无法控制歌词上下滚动（原版用 CustomPaint+GestureDetector，无 Scrollable）
/// - 点击某行无法迅速、准确跳转到该行（原版点击后需等待 progress 回流才滚动）
///
/// 核心机制：
/// - Windows 使用固定视口的惰性列表；其他平台沿用按索引定位的惰性列表
/// - 当前行锚定在视口 30% 处（Apple Music 风格）
/// - 进度变化时自动平滑滚动到当前行
/// - 用户滚动（鼠标滚轮/拖拽）后 3 秒自动恢复跟随当前行
/// - 点击某行立即跳转 seek 并滚动到该行
/// - 顶部/底部渐变遮罩
///
/// === 性能优化 ===
/// 通过 positionListenable（`ValueListenable<Duration>`）驱动进度更新，
/// 只有歌词行在进度变化时重绘，整棵歌词控件不因进度变化重建。
///
/// === 双语歌词排版规范（对标 Apple Music 手机端 UI）===
/// - 主字幕（原文）：大字号 ~4.5vh，英文 800 (ExtraBold)，中文 600 (SemiBold)，纯白高亮
/// - 副字幕（翻译）：小字号 ~2.2vh（约主字幕的 0.48 倍），字重与主字幕完全一致，半透明辅助
/// - 中文字体：Noto Sans SC（思源黑体，SemiBold），英文字体：Inter（ExtraBold）
class MusicLyricView extends StatefulWidget {
  final List<SubtitleItem> subtitles;
  final List<SubtitleItem> secondarySubtitles;

  /// Reuses the region's immutable projection without parsing the source twice.
  final MusicLyricProjection? projection;
  final Widget? footer;
  final ValueChanged<Duration>? onSeek;

  /// 进度通知器 — 每帧由 MediaPlaybackService.positionNotifier 更新，
  /// 歌词视图通过监听此通知器来高亮当前行，无需父组件重建。
  final ValueListenable<Duration>? positionListenable;

  /// Explicit positioning commands, primarily from progress-bar drag end.
  final MusicLyricPositionController? positionController;

  /// 用户滚动方向变化回调。
  ///
  /// Apple Music 手机端交互：用户向下滚动歌词时隐藏底部播放控件，
  /// 向上滚动时重新显示。正值表示向上滚（内容向下移），负值表示向下滚（内容向下移）。
  /// null 表示恢复自动跟随模式（控件应重新显示）。
  final void Function(double? direction)? onScrollDirectionChanged;

  /// Reports the actual manual scroll gesture lifetime. Unlike
  /// [onScrollDirectionChanged], this ends as soon as scrolling stops rather
  /// than when the delayed auto-follow mode resumes.
  final ValueChanged<bool>? onManualScrollActivityChanged;

  /// Called when a lyric row commits a direct tap. This is separate from
  /// [onSeek] so a parent background-tap recognizer can suppress only the same
  /// pointer interaction without treating the seek as a generic page tap.
  final VoidCallback? onDirectLyricTap;

  /// Keeps a directly tapped lyric logically selected across the small native
  /// seek undershoot/overshoot produced by ALAC packet boundaries. Callers must
  /// opt in only after confirming the source codec is ALAC.
  final bool stabilizeAlacDirectSeek;

  /// Whether the shared playback clock is currently advancing.
  final bool isPlaying;

  /// 在随屏幕适配的默认字号上连续缩放。
  final double lyricFontSizeScale;

  /// 相对于字号的歌词留白倍率，同时调整歌词组及原文/翻译间距。
  final double lyricSpacingScale;

  /// 词级时间轴是否逐词点亮。关闭后整行一起显示，行级跟随不变。
  final bool wordByWordEnabled;

  /// 非当前行是否使用景深模糊。关闭后远处歌词保持清晰。
  final bool lyricBlurEnabled;

  /// 是否将第一行识别为主字幕、其余行作为副字幕（与 video_player_screen 一致）。
  /// 仅当没有独立副字幕轨道（secondarySubtitles 为空）时生效。
  final bool splitSubtitleByLine;

  /// Which lyric role is visible. The animated list and the selection
  /// document both come from the same projection.
  final MusicLyricTrackDisplayMode displayMode;

  /// Long-press, context menu and the semantic "select text" action.
  final ValueChanged<MusicLyricSelectionRequest>? onRequestTextSelection;

  /// True from pointer-down on a lyric until that transaction ends, so the
  /// page can pause auto-follow and control hiding before the press commits.
  final ValueChanged<bool>? onPointerHoldChanged;

  /// 当前行在歌词视口内的纵向锚点。横屏默认沿用原来的 30%，
  /// 竖屏可传入更靠上的值以匹配 Apple Music 手机布局。
  final double anchorFraction;

  /// Preview the resolved anchor, including paragraph safety adjustments.
  final bool showAnchorGuide;

  /// Reports global coordinates after layout so the page can span its guide
  /// across both the artwork and lyrics, outside this viewport's edge fades.
  final ValueChanged<Offset>? onAnchorGuidePositionChanged;

  /// Unobscured reading bounds inside this viewport. Long paragraphs move
  /// above the preferred anchor when that lets their complete text fit.
  final EdgeInsets? focusInsets;

  /// 歌词左右留白占屏幕宽度的比例。
  final double horizontalPaddingFraction;

  /// 是否在组件内部绘制固定的上下渐隐。竖屏由父层根据控制栏动画
  /// 动态绘制遮罩，因此会关闭这里的固定遮罩。
  final bool applyEdgeFade;

  const MusicLyricView({
    super.key,
    required this.subtitles,
    this.secondarySubtitles = const [],
    this.projection,
    this.footer,
    this.onSeek,
    this.positionListenable,
    this.positionController,
    this.onScrollDirectionChanged,
    this.onManualScrollActivityChanged,
    this.onDirectLyricTap,
    this.stabilizeAlacDirectSeek = false,
    this.isPlaying = true,
    this.lyricFontSizeScale = 1.0,
    this.lyricSpacingScale = MusicLyricTypography.defaultSpacingScale,
    this.wordByWordEnabled = true,
    this.lyricBlurEnabled = true,
    this.splitSubtitleByLine = false,
    this.displayMode = MusicLyricTrackDisplayMode.both,
    this.onRequestTextSelection,
    this.onPointerHoldChanged,
    this.anchorFraction = 0.30,
    this.showAnchorGuide = false,
    this.onAnchorGuidePositionChanged,
    this.focusInsets,
    this.horizontalPaddingFraction = 0.05,
    this.applyEdgeFade = true,
  });

  @override
  State<MusicLyricView> createState() => MusicLyricViewState();
}

/// Public State class for MusicLyricView.
///
/// This allows external widgets (e.g., MusicPlayerScreen) to call
/// public methods like [scrollToCurrentIndex] via a [GlobalKey].
// ignore_for_file: library_private_classes
class MusicLyricViewState extends State<MusicLyricView>
    with SingleTickerProviderStateMixin {
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  late final MusicLyricFrameCoordinator _frames;
  final ScrollController _windowsScrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  double? _resolvedFocusAnchor;
  double? _firstRowAnchor;
  bool _anchorGuideReportScheduled = false;
  double get _focusAnchor => _resolvedFocusAnchor ?? widget.anchorFraction;
  final MusicLyricFollowMotion _followMotion = MusicLyricFollowMotion();
  Object? _windowsMetricsKey;
  List<double> _windowsRowExtents = const [];
  List<double> _windowsRowOffsets = const [];
  double _windowsTopPadding = 0;
  final Set<_LyricHitRegionState> _lyricHitRegions = <_LyricHitRegionState>{};
  bool _pressWarmupScheduled = false;
  final MusicLyricFrameProbe? _frameProbe = MusicLyricFrameProbe.enabled
      ? MusicLyricFrameProbe()
      : null;

  /// Visible rows from the shared lyric projection. Default bilingual songs
  /// keep one row per primary cue, so existing seek indexes stay stable.
  List<MusicLyricDisplayRow> _rows = const [];
  // Presentation-only entries keep interludes out of lyric hit regions and
  // selection/seek indexes, while giving them their own scroll destination.
  List<_MusicLyricListEntry> _listEntries = [];
  List<int> _lyricListIndexes = [];
  Map<int, int> _interludeListIndexes = {};
  MusicLyricProjection? _projection;
  var _streamFollowCues = SubtitleCueBuffer();
  late SubtitleTimelineResolver _lyricTimeline;
  int? _preciseWindowStartMs;
  int? _preciseWindowEndMs;
  Set<int> _preciseWindowLines = const {};
  Set<int> _activePreciseLines = <int>{};
  bool _hasPreciseLines = false;
  List<Duration> _lyricCoverageEnds = const [];
  List<Duration> _followCoverageEnds = const [];
  String? _firstLyricAgent;

  /// 当前行索引（基于播放进度计算）
  /// -1 means playback is still before the first timed lyric.
  int _activeIndex = -1;
  // Positioning can move to the next line during silence without advancing
  // the singing/highlight timeline or seeking the media.
  int _followIndex = -1;
  bool _followingInterlude = false;

  int get _focusListIndex {
    if (_lyricListIndexes.isEmpty) return 0;
    final index = _followIndex.clamp(0, _lyricListIndexes.length - 1);
    return (_followingInterlude ? _interludeListIndexes[index] : null) ??
        _lyricListIndexes[index];
  }

  /// 当前播放位置（由 positionListenable 驱动，每帧更新）
  Duration _currentPosition = Duration.zero;

  /// Lyrics remain hidden until the target line has been laid out and located.
  /// This prevents a new episode from flashing at line zero before jumping.
  late AnimationController _contentAnimationController;
  late CurvedAnimation _contentOpacity;

  /// 用户点击高亮的行索引（点击后到进度追上之前高亮显示）
  int _tappedIndex = -1;
  int? _alacLatchedTapIndex;

  // A forward lyric seek must not finish singing the rows it skips while
  // their row opacity is still fading. Keep the reset until a row plays again.
  // Group IDs stay stable when streamed secondary rows change list indexes.
  final Map<String, Duration> _pendingWordHighlightClears = {};
  final Set<String> _clearedWordHighlightRows = {};

  static const int _alacSeekBoundaryToleranceMs = 450;

  /// 手指按下时的短暂背景反馈，与 seek 完成前的文字高亮分离。
  int _pressedIndex = -1;
  Timer? _pressedFeedbackTimer;

  /// 是否已完成过「进入页面时的初始定位」。
  /// 用于保证即使当前索引与初始值相同（例如暂停在 0 秒、当前就是第 0 行），
  /// 也能把该行滚动到锚点位置，而不是停留在自然滚动位置（顶部）。
  bool _initialLocateDone = false;

  /// 鼠标悬停的行索引（-1 表示没有悬停）
  int _hoveredIndex = -1;

  /// 用户是否正在手动滚动（触摸拖拽 / 鼠标拖拽）
  bool _isUserScrolling = false;

  /// 是否正在执行程序化滚动（用于区分用户滚动与自动滚动）
  bool _isProgrammaticScroll = false;

  /// 记录最后一次手动滚动方向的符号（>0 向下滚隐藏控件，<0 向上滚显示控件）
  double? _lastManualScrollDirection;

  Timer? _resumeTimer;
  Timer? _programmaticScrollResetTimer;
  Timer? _jumpOpacityResetTimer;
  Timer? _tapGuardResetTimer;
  Timer? _seekDispatchTimer;
  bool _disposed = false;
  int _locateRevealRequestId = 0;
  int _layoutRelocateRequestId = 0;

  /// Only the newest scroll request may reset the shared interaction guards.
  /// ItemScrollController cancels its previous transition when scrollTo is
  /// called again; this id prevents the canceled Future from cleaning up the
  /// replacement request.
  int _scrollRequestId = 0;

  /// Raw-pointer tap and long-press tracking remains owned by this stable
  /// parent State. The positioned-list package can dispose a row between
  /// pointer-down and pointer-up, so the transaction cannot live on the row.
  _LyricPointerTransaction? _pointerTransaction;
  Timer? _longPressTimer;
  bool _pointerHoldFreezesFollow = false;
  BuildContext? _scrollNotificationContext;
  final Set<int> _downPointers = <int>{};

  /// Native players should not receive an unbounded burst of seeks. Visual
  /// feedback and scrolling stay immediate while rapid seeks are latest-wins.
  DateTime? _lastSeekDispatchedAt;
  Duration? _lastSeekDispatchedPosition;
  Duration? _pendingSeekPosition;
  static const Duration _minimumSeekInterval = Duration(milliseconds: 120);

  /// While a direct tap owns the scroll, the position notification produced by
  /// that seek may update highlighting but must not start a competing scroll.
  int? _directTapScrollTarget;
  int _directTapRequestId = 0;
  bool _tapScrollCompleted = false;
  bool _tapSeekAcknowledged = false;
  Timer? _tapTransactionTimeout;

  int? _explicitLocateActiveIndex;
  int _explicitLocateRequestId = 0;

  /// 用于 NotificationListener 判断是否为用户拖拽滚动
  bool _isDragScrolling = false;

  /// 是否正在执行点击跳转（用于避免点击跳转时的滚动被误判为用户手动滚动）
  bool _isTappingLine = false;

  /// 用户滚动后恢复自动跟随的延时
  static const Duration _autoResumeDelay = Duration(seconds: 3);

  // ========== Apple Music 风格动画参数 ==========

  /// 正常播放时透明度变化动画时长（ms）— Apple Music 风格：流畅但不过慢
  static const int _normalOpacityDuration = 400;

  /// 大幅度跳转时透明度变化动画时长（ms）— 更快的响应
  static const int _jumpOpacityDuration = 250;

  /// 正常播放时滚动动画时长（ms）
  static const int _normalScrollDuration = 800;

  /// 大幅度跳转时滚动动画时长（ms）— 快速定位
  static const int _jumpScrollDuration = 250;

  /// 判断是否为大幅度跳转的行数阈值
  static const int _largeJumpThreshold = 5;

  // ========== 字体规范（参考竖屏设计文档）==========

  /// Latin lyrics use the bundled Inter family (SIL OFL 1.1).
  static const String _fontFamilyEng = 'Inter';

  /// Chinese lyrics use Noto Sans CJK (SIL OFL 1.1).
  /// The UI's MiSans family has its own Xiaomi license; see font notices.
  static const String _fontFamilyZh = 'Noto Sans SC';

  /// 检测文本是否包含中文字符（CJK 统一表意文字 U+4E00~U+9FFF）
  /// 用于自动判断原文/翻译应该用哪个字体显示
  static bool _isChineseText(String text) {
    for (final rune in text.runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _frames = MusicLyricFrameCoordinator(widget.positionListenable);
    _itemPositionsListener.itemPositions.addListener(_onVisibleRowsChanged);
    _precomputeSecondaryTexts();

    _contentAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _contentOpacity = CurvedAnimation(
      parent: _contentAnimationController,
      curve: Curves.easeOutCubic,
    );

    // 监听 positionListenable 以更新歌词高亮
    widget.positionListenable?.addListener(_onPositionChanged);
    widget.positionController?.addListener(_onExplicitLocateRequested);
    _currentPosition = widget.positionListenable?.value ?? Duration.zero;
    _activeIndex = _findActiveIndex(_currentPosition);
    _followIndex = _scrollTargetForActiveIndex(_activeIndex);
    _followingInterlude = _isInterludeBefore(_followIndex, _currentPosition);
    _activePreciseLines = _preciseLinesAt(_currentPosition);

    // 首帧布局完成后做一次无动画定位
    _scheduleLocateAndReveal();
  }

  /// 当 positionListenable 变化时更新 _currentPosition 并刷新歌词高亮
  ///
  /// 优化：直接调用 _updateActiveIndex，确保定位响应及时
  /// - 移除 Timer(Duration.zero) 节流，避免不必要的延迟
  /// - _updateActiveIndex 内部会检查索引是否变化，避免不必要的重建
  void _onPositionChanged() {
    if (!mounted) return;

    _currentPosition = widget.positionListenable?.value ?? Duration.zero;
    final precise = _preciseLinesAt(_currentPosition);
    final preciseChanged = !setEquals(precise, _activePreciseLines);
    if (preciseChanged) {
      for (final index in precise) {
        _clearedWordHighlightRows.remove(_rows[index].groupId);
      }
    }
    var wordHighlightCleared = false;
    final singingGroups = _pendingWordHighlightClears.isEmpty
        ? const <String>{}
        : {for (final index in precise) _rows[index].groupId};
    _pendingWordHighlightClears.removeWhere((group, target) {
      if (singingGroups.contains(group)) return false;
      if (_currentPosition >= target) {
        wordHighlightCleared |= _clearedWordHighlightRows.add(group);
      }
      // If playback finished this row before reaching the seek target, it
      // completed naturally. Retain that ordinary completion and fade.
      return true;
    });
    _activePreciseLines = precise;

    // 直接调用 _updateActiveIndex，该方法内部会检查索引是否变化
    // 这种方式比 Timer(Duration.zero) 更及时，避免定位延迟
    _updateActiveIndex();
    if (preciseChanged || wordHighlightCleared) setState(() {});
    _frames.publishPosition();
  }

  void _onVisibleRowsChanged() {
    if (!mounted || _disposed) return;
    int? first;
    int? last;
    for (final row in _itemPositionsListener.itemPositions.value) {
      if (row.index >= _listEntries.length) continue;
      if (row.itemLeadingEdge >= 1 || row.itemTrailingEdge <= 0) continue;
      final index = _listEntries[row.index].lyricIndex;
      if (first == null || index < first) first = index;
      if (last == null || index > last) last = index;
    }
    // The positioned list can briefly have no positions during a distant jump.
    // Wait for its committed layout rather than waking the entire cache.
    if (first != null) _frames.setVisibleRange(first, last);
    _frameProbe
      ?..mountedRows = _frames.mountedRows
      ..activeRows = _frames.activeRows;
  }

  /// Rebuilds the visible rows from the shared projection. Playback position
  /// never reaches this method.
  void _precomputeSecondaryTexts({bool append = false}) {
    _preciseWindowStartMs = null;
    _preciseWindowEndMs = null;
    _preciseWindowLines = const {};
    if (!append) {
      _windowsMetricsKey = null;
      _frames.setVisibleRange(null, null);
    } else {
      _frameProbe?.markAppend();
    }
    final oldCount = append ? _rows.length : 0;
    final projection =
        widget.projection ??
        resolveMusicLyricProjection(
          mediaId: 'lyric-view',
          primary: widget.subtitles,
          secondary: widget.secondarySubtitles,
          splitSubtitleByLine: widget.splitSubtitleByLine,
          mode: widget.displayMode,
          previous: append ? _projection : null,
        );
    _projection = projection;
    _rows = projection.rows;
    if (append) {
      final added = _rows.skip(oldCount).toList();
      _streamFollowCues.addAll(added.map((row) => row.followCue));
      _lyricTimeline.append(_streamFollowCues.snapshot);
      var coverage = _lyricCoverageEnds.isEmpty
          ? Duration.zero
          : _lyricCoverageEnds.last;
      var follow = _followCoverageEnds.isEmpty
          ? Duration.zero
          : _followCoverageEnds.last;
      for (final row in added) {
        _hasPreciseLines |=
            row.followCue.isStructuredLyric ||
            row.followCue.timedSpans.isNotEmpty;
        coverage = row.end > coverage ? row.end : coverage;
        final end = _endForAutoFollow(row.followCue);
        follow = end > follow ? end : follow;
        _lyricCoverageEnds.add(coverage);
        _followCoverageEnds.add(follow);
      }
      _buildListEntries(start: oldCount);
      _activePreciseLines = _preciseLinesAt(_currentPosition);
      return;
    }
    final followCues = [for (final row in _rows) row.followCue];
    _hasPreciseLines = followCues.any(
      (cue) => cue.isStructuredLyric || cue.timedSpans.isNotEmpty,
    );
    // Start a fresh append owner whenever the selected track is replaced.
    _streamFollowCues = SubtitleCueBuffer();
    _streamFollowCues.addAll(followCues);
    _lyricTimeline = SubtitleTimelineResolver(followCues);
    var coverageEnd = Duration.zero;
    _lyricCoverageEnds = [
      for (final row in _rows)
        coverageEnd = row.end > coverageEnd ? row.end : coverageEnd,
    ];
    var followEnd = Duration.zero;
    _followCoverageEnds = [
      for (final end in followCues.map(_endForAutoFollow))
        followEnd = end > followEnd ? end : followEnd,
    ];
    _buildListEntries();
    _firstLyricAgent = widget.subtitles
        .where((cue) => cue.isStructuredLyric && cue.lyricAgent != null)
        .firstOrNull
        ?.lyricAgent;
    _activePreciseLines = _preciseLinesAt(_currentPosition);
  }

  void _buildListEntries({int start = 0}) {
    if (start == 0) {
      _listEntries = [];
      _lyricListIndexes = [];
      _interludeListIndexes = {};
    }
    for (var index = start; index < _rows.length; index++) {
      if (index > 0 &&
          _rows[index].start - _lyricCoverageEnds[index - 1] >=
              const Duration(seconds: 5)) {
        _interludeListIndexes[index] = _listEntries.length;
        _listEntries.add(
          _MusicLyricListEntry(index, _lyricCoverageEnds[index - 1]),
        );
      }
      _lyricListIndexes.add(_listEntries.length);
      _listEntries.add(_MusicLyricListEntry(index));
    }
  }

  bool _isInterludeBefore(int index, Duration position) =>
      _interludeListIndexes.containsKey(index) &&
      position >= _lyricCoverageEnds[index - 1] &&
      position < _rows[index].start;

  int _listIndexForLyric(int index, {Duration? playbackPosition}) =>
      playbackPosition != null && _isInterludeBefore(index, playbackPosition)
      ? _interludeListIndexes[index]!
      : _lyricListIndexes[index];

  Set<int> _preciseLinesAt(Duration position) {
    if (!_hasPreciseLines) return const <int>{};
    final ms = position.inMilliseconds;
    final windowStart = _preciseWindowStartMs;
    if (windowStart != null &&
        ms >= windowStart &&
        (_preciseWindowEndMs == null || ms < _preciseWindowEndMs!)) {
      return _preciseWindowLines;
    }
    // Within an interval containing no cue start or active cue end, the
    // singing set is constant. Word ink still samples every display frame;
    // the line timeline need not allocate and search again at 120/144 Hz.
    final next = _lyricTimeline.firstStartAfterMs(ms);
    int? until = next < _rows.length ? _rows[next].start.inMilliseconds : null;
    final precise = <int>{};
    for (final index in _lyricTimeline.activeIndicesAtMs(ms)) {
      if (index < 0 || index >= _rows.length) continue;
      final cue = _rows[index].followCue;
      if (cue.isStructuredLyric || cue.timedSpans.isNotEmpty) {
        precise.add(index);
        final end = cue.endTime.inMilliseconds;
        if (until == null || end < until) until = end;
      }
    }
    _preciseWindowStartMs = ms;
    _preciseWindowEndMs = until;
    return _preciseWindowLines = precise;
  }

  @override
  void didUpdateWidget(covariant MusicLyricView oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 检查 subtitles 是否真正变化（不仅比较引用，还比较内容）
    // 避免调节字号等操作时，因引用变化导致误重置用户滚动状态
    if (oldWidget.subtitles != widget.subtitles ||
        oldWidget.secondarySubtitles != widget.secondarySubtitles) {
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
      if (append || secondaryAppend) {
        // A completed cloud primary has no new rows. Its existing rows gain
        // translations, so rebuild the projection while retaining scroll state.
        _precomputeSecondaryTexts(append: !secondaryAppend);
        // Keep a user's reading/drag/selection and any in-flight scroll intact.
        _currentPosition = widget.positionListenable?.value ?? _currentPosition;
        if (!_isUserScrolling && !_isProgrammaticScroll) {
          _updateActiveIndex(animate: false);
        }
      }
      final contentChanged =
          !append &&
          !secondaryAppend &&
          (_isSubtitlesContentChanged(oldWidget.subtitles, widget.subtitles) ||
              _isSubtitlesContentChanged(
                oldWidget.secondarySubtitles,
                widget.secondarySubtitles,
              ));

      if (contentChanged) {
        _seekDispatchTimer?.cancel();
        _pendingSeekPosition = null;
        _lastSeekDispatchedPosition = null;
        _lastSeekDispatchedAt = null;
        _pendingWordHighlightClears.clear();
        _clearedWordHighlightRows.clear();
        _contentAnimationController.value = 0;
        _precomputeSecondaryTexts();
        _currentPosition = widget.positionListenable?.value ?? _currentPosition;
        _activeIndex = _findActiveIndex(_currentPosition);
        _followIndex = _scrollTargetForActiveIndex(_activeIndex);
        _followingInterlude = _isInterludeBefore(
          _followIndex,
          _currentPosition,
        );
        _activePreciseLines = _preciseLinesAt(_currentPosition);
        _tappedIndex = -1;
        _alacLatchedTapIndex = null;
        _pressedIndex = -1;
        _isUserScrolling = false;
        _resumeTimer?.cancel();
        _tapTransactionTimeout?.cancel();
        _tapTransactionTimeout = null;
        _tapScrollCompleted = false;
        _tapSeekAcknowledged = false;
        _directTapScrollTarget = null;
        _directTapRequestId++;
        _cancelPendingLinePointer();
        // 字幕数据集变化（含从空到非空、异步加载完成），需要重新做一次初始定位
        _initialLocateDone = false;
        _scheduleLocateAndReveal();
      }
      // 如果内容没变，只是引用变化，则不重置用户滚动状态
    }

    // 处理 positionListenable 变化（父组件传入不同的 listenable 时）
    if (oldWidget.positionListenable != widget.positionListenable) {
      oldWidget.positionListenable?.removeListener(_onPositionChanged);
      widget.positionListenable?.addListener(_onPositionChanged);
      _pendingWordHighlightClears.clear();
      _clearedWordHighlightRows.clear();
      _frames.source = widget.positionListenable;
      _currentPosition = widget.positionListenable?.value ?? Duration.zero;
      _updateActiveIndex(animate: false);
    }
    if (oldWidget.positionController != widget.positionController) {
      oldWidget.positionController?.removeListener(_onExplicitLocateRequested);
      widget.positionController?.addListener(_onExplicitLocateRequested);
    }
    if (oldWidget.stabilizeAlacDirectSeek != widget.stabilizeAlacDirectSeek ||
        oldWidget.isPlaying != widget.isPlaying) {
      if (!widget.stabilizeAlacDirectSeek) _alacLatchedTapIndex = null;
      _updateActiveIndex(animate: false);
    }

    if (oldWidget.splitSubtitleByLine != widget.splitSubtitleByLine ||
        oldWidget.displayMode != widget.displayMode) {
      _pendingWordHighlightClears.clear();
      _clearedWordHighlightRows.clear();
      final anchor =
          _isUserScrolling && _followIndex >= 0 && _followIndex < _rows.length
          ? _rows[_followIndex].start
          : null;
      _precomputeSecondaryTexts();
      _windowsMetricsKey = null;
      if (anchor != null) {
        final index = _nearestRow(anchor);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _disposed) return;
          _scrollToIndex(index, animate: false);
        });
      } else {
        _scheduleLayoutRelocate();
      }
    }

    // Font and viewport/header changes can move the readable anchor even
    // without a new cue. Relocate after the new layout has been committed.
    if (oldWidget.lyricFontSizeScale != widget.lyricFontSizeScale ||
        oldWidget.lyricSpacingScale != widget.lyricSpacingScale ||
        oldWidget.anchorFraction != widget.anchorFraction ||
        oldWidget.focusInsets != widget.focusInsets ||
        (!oldWidget.showAnchorGuide && widget.showAnchorGuide)) {
      _scheduleLayoutRelocate();
    }
  }

  void _scheduleLayoutRelocate() {
    final requestId = ++_layoutRelocateRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed ||
          !mounted ||
          requestId != _layoutRelocateRequestId ||
          _rows.isEmpty) {
        return;
      }

      _currentPosition = widget.positionListenable?.value ?? _currentPosition;
      _resumeTimer?.cancel();
      _isUserScrolling = false;
      _updateActiveIndex(animate: false);
      scrollToCurrentIndex(animate: false);
    });
  }

  void _scheduleAnchorGuideReport() {
    if (_anchorGuideReportScheduled ||
        !widget.showAnchorGuide ||
        widget.onAnchorGuidePositionChanged == null ||
        _rows.isEmpty) {
      return;
    }
    _anchorGuideReportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorGuideReportScheduled = false;
      if (!mounted || _disposed || !widget.showAnchorGuide) return;
      final viewport = _viewportKey.currentContext?.findRenderObject();
      if (viewport is RenderBox && viewport.hasSize) {
        widget.onAnchorGuidePositionChanged?.call(
          viewport.localToGlobal(
            Offset(0, viewport.size.height * _focusAnchor),
          ),
        );
      }
    });
  }

  /// 检查字幕列表内容是否真正变化
  bool _isSubtitlesContentChanged(
    List<SubtitleItem> oldSubs,
    List<SubtitleItem> newSubs,
  ) {
    if (oldSubs.length != newSubs.length) return true;
    for (int i = 0; i < oldSubs.length; i++) {
      if (oldSubs[i].startTime != newSubs[i].startTime ||
          oldSubs[i].endTime != newSubs[i].endTime ||
          oldSubs[i].text != newSubs[i].text ||
          !listEquals(oldSubs[i].timedSpans, newSubs[i].timedSpans) ||
          oldSubs[i].lyricTranslation != newSubs[i].lyricTranslation ||
          oldSubs[i].lyricRomanization != newSubs[i].lyricRomanization ||
          !listEquals(
            oldSubs[i].lyricTranslationSpans,
            newSubs[i].lyricTranslationSpans,
          ) ||
          !listEquals(
            oldSubs[i].lyricRomanizationSpans,
            newSubs[i].lyricRomanizationSpans,
          ) ||
          oldSubs[i].lyricAgent != newSubs[i].lyricAgent ||
          oldSubs[i].isBackgroundLyric != newSubs[i].isBackgroundLyric) {
        return true;
      }
    }
    return false;
  }

  void _scheduleLocateAndReveal() {
    final requestId = ++_locateRevealRequestId;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_disposed ||
          !mounted ||
          requestId != _locateRevealRequestId ||
          _rows.isEmpty) {
        return;
      }

      // Read the clock again after the subtitle list has committed. During an
      // episode hand-off it may have changed between widget construction and
      // the first laid-out frame.
      _currentPosition = widget.positionListenable?.value ?? _currentPosition;
      _updateActiveIndex(animate: false);
      await _performInitialLocate();
      if (_disposed || !mounted || requestId != _locateRevealRequestId) return;
      // A jump commits its viewport on the next layout. Do not reveal the
      // preceding viewport, or let a clock tick animate from that old offset.
      await WidgetsBinding.instance.endOfFrame;
      if (_disposed || !mounted || requestId != _locateRevealRequestId) return;
      _currentPosition = widget.positionListenable?.value ?? _currentPosition;
      _updateActiveIndex(animate: false);
      _contentAnimationController.forward(from: 0);
    });
  }

  /// 二分查找当前进度对应的歌词行索引
  int _findActiveIndex(Duration position) {
    final subs = _rows;
    if (subs.isEmpty || position < subs.first.start) return -1;
    int left = 0;
    int right = subs.length - 1;
    int result = -1;
    while (left <= right) {
      final mid = left + ((right - left) >> 1);
      if (position < subs[mid].start) {
        right = mid - 1;
      } else {
        result = mid;
        left = mid + 1;
      }
    }
    return result;
  }

  int _findDisplayActiveIndex(Duration position) {
    final normalIndex = _findActiveIndex(position);
    final latchedIndex = _alacLatchedTapIndex;
    if (!widget.stabilizeAlacDirectSeek ||
        latchedIndex == null ||
        latchedIndex < 0 ||
        latchedIndex >= _rows.length) {
      return normalIndex;
    }

    final targetMs = _rows[latchedIndex].start.inMilliseconds;
    final positionMs = position.inMilliseconds;
    final deltaMs = positionMs - targetMs;
    if (deltaMs.abs() > _alacSeekBoundaryToleranceMs) {
      _alacLatchedTapIndex = null;
      return normalIndex;
    }

    // While paused, the row the user chose remains authoritative throughout
    // the same tolerance that the playback service accepts for native ALAC
    // seek verification. Once playback advances across the requested boundary,
    // the ordinary timeline owns highlighting again.
    if (!widget.isPlaying || deltaMs < 0) return latchedIndex;
    _alacLatchedTapIndex = null;
    return normalIndex;
  }

  void _updateActiveIndex({bool animate = true}) {
    if (!mounted || _rows.isEmpty) return;

    final newIndex = _findDisplayActiveIndex(_currentPosition);
    final followIndex = _scrollTargetForActiveIndex(newIndex);
    final followingInterlude = _isInterludeBefore(
      followIndex,
      _currentPosition,
    );
    final followChanged =
        followIndex != _followIndex ||
        followingInterlude != _followingInterlude;
    final directTapOwnsScroll = _directTapScrollTarget != null;
    if (directTapOwnsScroll && newIndex == _directTapScrollTarget) {
      _tapSeekAcknowledged = true;
    }
    if (newIndex != _activeIndex || followChanged) {
      // 判断是否为大幅度跳转
      final jumpDistance = (newIndex - _activeIndex).abs();
      final isLargeJump = jumpDistance > _largeJumpThreshold;

      // setState 触发所有行重新计算透明度（Apple Music 淡入淡出效果）
      setState(() {
        _activeIndex = newIndex;
        _followIndex = followIndex;
        _followingInterlude = followingInterlude;
        // 当播放进度追上点击行时，清除点击高亮
        if (_tappedIndex >= 0 && newIndex >= _tappedIndex) {
          _tappedIndex = -1;
        }
        // 记录跳转类型，供 AnimatedOpacity 使用
        _isLargeJump = isLargeJump;
      });
      final explicitLocateOwnsScroll = _explicitLocateActiveIndex == newIndex;
      if (followChanged &&
          _initialLocateDone &&
          !_isUserScrolling &&
          !_pointerHoldFreezesFollow &&
          !directTapOwnsScroll &&
          !explicitLocateOwnsScroll) {
        _scrollToIndex(
          followIndex,
          playbackPosition: _currentPosition,
          animate:
              animate &&
              !isLargeJump &&
              _contentAnimationController.isCompleted,
          isLargeJump: isLargeJump,
        );
      }

      // 动画完成后重置 _isLargeJump 标志
      // 使用动画时长 + 缓冲时间
      _jumpOpacityResetTimer?.cancel();
      if (isLargeJump) {
        _jumpOpacityResetTimer = Timer(
          const Duration(milliseconds: _jumpOpacityDuration + 50),
          () {
            if (mounted && _isLargeJump) {
              setState(() => _isLargeJump = false);
            }
          },
        );
      }
    } else {
      // 索引没变，但可能需要更新 _tappedIndex 和 _isLargeJump
      // 优化：只在需要时才 setState
      bool needUpdate = false;

      if (_tappedIndex >= 0 && newIndex >= _tappedIndex) {
        _tappedIndex = -1;
        needUpdate = true;
      }

      if (_isLargeJump) {
        _isLargeJump = false;
        needUpdate = true;
      }

      if (needUpdate && mounted) {
        setState(() {});
      }
    }
    if (directTapOwnsScroll) {
      _completeTapTransactionIfReady(_directTapRequestId);
    }
  }

  /// 是否为大幅度跳转（用于控制动画速度）
  bool _isLargeJump = false;

  /// 将指定行滚动到锚点位置（视口 30%）
  ///
  /// Apple Music 风格：优雅的滚动动画，支持正常播放和大幅度跳转两种模式
  Future<void> _scrollToIndex(
    int index, {
    Duration? playbackPosition,
    bool animate = true,
    bool isLargeJump = false,
    bool isDirectTap = false,
    int? directTapDistance,
  }) async {
    if (!mounted || index < 0 || index >= _rows.length) return;
    final requestId = ++_scrollRequestId;
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;
    final controllerIsReady = isWindows
        ? _windowsScrollController.hasClients && _windowsRowOffsets.isNotEmpty
        : _itemScrollController.isAttached;
    if (!controllerIsReady) {
      final attachedCompleter = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!_disposed && mounted && requestId == _scrollRequestId) {
          await _scrollToIndex(
            index,
            playbackPosition: playbackPosition,
            animate: animate,
            isLargeJump: isLargeJump,
            isDirectTap: isDirectTap,
            directTapDistance: directTapDistance,
          );
        }
        if (!attachedCompleter.isCompleted) attachedCompleter.complete();
      });
      return attachedCompleter.future;
    }

    _isProgrammaticScroll = true;
    _frameProbe?.markPhase(
      animate
          ? isDirectTap
                ? MusicLyricFramePhase.tap
                : MusicLyricFramePhase.autoFollow
          : MusicLyricFramePhase.idle,
    );
    _programmaticScrollResetTimer?.cancel();
    final tapDistance = directTapDistance ?? (index - _activeIndex).abs();
    final tapDurationMs = musicLyricTapScrollDurationMs(tapDistance);
    animate = animate && !MediaQuery.disableAnimationsOf(context);
    // A distant positioned-list transition paints two viewports. Its public
    // positions describe only the primary one until the crossfade completes.
    _frames.setLocating(
      animate && !isWindows && !_frames.isInVisibleWindow(index),
    );
    _followMotion.enabled = animate && !isDirectTap && !isLargeJump;
    final duration = !animate
        ? Duration.zero
        : isDirectTap
        ? Duration(milliseconds: tapDurationMs)
        : isLargeJump
        ? const Duration(milliseconds: _jumpScrollDuration)
        : const Duration(milliseconds: _normalScrollDuration);
    final curve = isDirectTap
        ? musicLyricTapScrollCurve
        : isLargeJump
        ? Curves.easeInOutCubic
        : const MusicLyricSpringCurve();
    final listIndex = _listIndexForLyric(
      index,
      playbackPosition: playbackPosition,
    );
    final alignment = _alignmentForIndex(
      index,
      interlude: _listEntries[listIndex].isInterlude,
    );
    final firstRowPaddingChanged =
        widget.focusInsets != null &&
        index == 0 &&
        (_firstRowAnchor ?? widget.anchorFraction) != alignment;
    if (_focusAnchor != alignment ||
        (widget.focusInsets != null &&
            index == 0 &&
            _firstRowAnchor != alignment)) {
      setState(() {
        _resolvedFocusAnchor = alignment;
        if (widget.focusInsets != null && index == 0) {
          _firstRowAnchor = alignment;
        }
      });
    }
    if (firstRowPaddingChanged) {
      // The first item cannot move above the list's leading padding. Commit
      // that padding before asking either scroll implementation to locate it.
      await WidgetsBinding.instance.endOfFrame;
      if (_disposed || !mounted || requestId != _scrollRequestId) return;
    }
    try {
      if (isWindows) {
        // Windows deliberately uses one ordinary viewport. The same render
        // object supplies both the animated destination and the settled
        // layout, so completing an animation cannot swap in a second list
        // with a slightly different measured offset.
        await _scrollWindowsLineToAnchor(
          index: listIndex,
          alignment: alignment,
          duration: duration,
          curve: curve,
        );
      } else if (animate) {
        await _itemScrollController.scrollTo(
          index: listIndex,
          alignment: _positionedListAlignment(index, listIndex, alignment),
          duration: duration,
          curve: curve,
        );
      } else {
        // At index zero the indexed list puts its leading padding inside the
        // target sliver. That padding already places the text at the anchor;
        // applying the alignment again displaces short, wrapped transcripts.
        _itemScrollController.jumpTo(
          index: listIndex,
          alignment: listIndex == 0 ? 0 : alignment,
        );
      }
    } catch (_) {
      // A replacement scroll intentionally cancels the previous transition.
    } finally {
      if (requestId == _scrollRequestId && !_disposed && mounted) {
        _frames.setLocating(false);
        _frameProbe?.markPhase(MusicLyricFramePhase.idle);
        // 延迟重置标志位，确保滚动动画完全结束，避免 NotificationListener 误判
        // 延迟时间略长于滚动动画，确保所有可能的 ScrollNotification 都已处理完毕
        final resetDelay = animate ? 120 : 50;
        _programmaticScrollResetTimer?.cancel();
        _programmaticScrollResetTimer = Timer(
          Duration(milliseconds: resetDelay),
          () {
            if (mounted && !_disposed) {
              _isProgrammaticScroll = false;
            }
          },
        );
      }
    }
  }

  double _positionedListAlignment(int index, int listIndex, double alignment) {
    // Positioned-list rounds its published leading edges to whole logical
    // pixels before computing animated destinations. Relative spacing can
    // place a row between pixels; compensate using its untransformed layout
    // box so that rounding cannot accumulate into the lyric's focus position.
    if (!_itemPositionsListener.itemPositions.value.any(
      (position) => position.index == listIndex,
    )) {
      return listIndex == 0 ? 0 : alignment;
    }
    for (final region in _lyricHitRegions) {
      if (region.index != index || !region.mounted) continue;
      final row = region.context
          .findAncestorRenderObjectOfType<RenderIndexedSemantics>();
      if (row == null || !row.hasSize) continue;
      final viewport = RenderAbstractViewport.maybeOf(row);
      final viewportBox = viewport is RenderBox ? viewport as RenderBox : null;
      if (viewportBox == null ||
          !viewportBox.hasSize ||
          viewportBox.size.height <= 0) {
        continue;
      }
      var leading = row.localToGlobal(Offset.zero, ancestor: viewportBox).dy;
      if (_listEntries[listIndex].isInterlude) {
        leading -= _typography.interludeSize + _typography.stanzaGap;
      }
      return (alignment +
              (leading.roundToDouble() - leading) / viewportBox.size.height)
          .clamp(0.0, 1.0);
    }
    return alignment;
  }

  Future<void> _scrollWindowsLineToAnchor({
    required int index,
    required double alignment,
    required Duration duration,
    required Curve curve,
  }) async {
    final position = _windowsScrollController.position;
    // The lazy viewport and the scroll destination share these exact text
    // extents. Distant rows need no mounted widget or guessed average height.
    final leadingOffset = _windowsTopPadding + _windowsRowOffsets[index];
    final destination = (leadingOffset - position.viewportDimension * alignment)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((destination - position.pixels).abs() <= 0.01) return;
    if (duration == Duration.zero) {
      position.jumpTo(destination);
      return;
    }
    await position.animateTo(destination, duration: duration, curve: curve);
  }

  /// 点击某行：立即 seek + 立即滚动到该行
  void _handleTapLine(int index, {bool afterPointerUp = false}) {
    if (index < 0 || index >= _rows.length) return;
    final sub = _rows[index].followCue;
    final tapDistance = (index - _activeIndex).abs();
    widget.onDirectLyricTap?.call();
    if (_isUserScrolling) widget.onManualScrollActivityChanged?.call(false);
    _isDragScrolling = false;
    _lastManualScrollDirection = null;
    setState(() {
      _tappedIndex = index;
      _alacLatchedTapIndex = widget.stabilizeAlacDirectSeek ? index : null;
      _isUserScrolling = false;
      _isTappingLine = true; // ✅ 标记正在执行点击跳转
    });
    _resumeTimer?.cancel();
    _tapGuardResetTimer?.cancel();
    _directTapScrollTarget = index;
    final tapRequestId = ++_directTapRequestId;
    _tapScrollCompleted = false;
    _tapSeekAcknowledged =
        widget.positionListenable == null || _activeIndex == index;
    _tapTransactionTimeout?.cancel();
    _tapTransactionTimeout = Timer(const Duration(seconds: 3), () {
      if (_disposed || !mounted || tapRequestId != _directTapRequestId) {
        return;
      }
      _finishTapTransaction(tapRequestId);
    });
    // ✅ 点击歌词时不再通知父组件显示控件，避免干扰原有的显隐状态
    // widget.onScrollDirectionChanged?.call(-1);
    _dispatchSeek(sub.startTime);

    void startScroll() {
      if (_disposed || !mounted || tapRequestId != _directTapRequestId) return;

      final scrollFuture = _scrollToIndex(
        index,
        animate: true,
        isDirectTap: true,
        directTapDistance: tapDistance,
      );
      scrollFuture.then((_) {
        if (_disposed || !mounted || tapRequestId != _directTapRequestId) {
          return;
        }
        _tapScrollCompleted = true;
        _completeTapTransactionIfReady(tapRequestId);
        // 滚动完成后延迟重置标志位，确保所有滚动通知都已处理
      });
    }

    if (afterPointerUp) {
      // Descendant scroll recognizers must finish releasing this pointer before
      // the replacement animation starts. The seek still commits on release.
      WidgetsBinding.instance.addPostFrameCallback((_) => startScroll());
    } else {
      startScroll();
    }
  }

  void _completeTapTransactionIfReady(int requestId) {
    if (requestId != _directTapRequestId ||
        !_tapScrollCompleted ||
        !_tapSeekAcknowledged) {
      return;
    }
    _finishTapTransaction(requestId);
  }

  void _finishTapTransaction(int requestId) {
    if (requestId != _directTapRequestId) return;
    _tapTransactionTimeout?.cancel();
    _tapTransactionTimeout = null;
    _tapScrollCompleted = false;
    _tapSeekAcknowledged = false;
    _directTapScrollTarget = null;
    _scheduleTapGuardRelease(requestId);
  }

  void _scheduleTapGuardRelease(int requestId) {
    _tapGuardResetTimer?.cancel();
    _tapGuardResetTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted && !_disposed && requestId == _directTapRequestId) {
        _isTappingLine = false;
      }
    });
  }

  void _prepareWordHighlightSeek(Duration target) {
    _pendingWordHighlightClears.clear();
    if (target <= _currentPosition) return;
    final stillSinging = _preciseLinesAt(target);
    for (final index in _activePreciseLines) {
      if (!stillSinging.contains(index)) {
        _pendingWordHighlightClears[_rows[index].groupId] = target;
      }
    }
  }

  void _dispatchSeek(Duration position) {
    final callback = widget.onSeek;
    if (callback == null) return;

    final now = DateTime.now();
    final last = _lastSeekDispatchedAt;
    // Repeated taps still animate the line, but an already dispatched target
    // need not seek the native player again during the same tap burst.
    if (position == _lastSeekDispatchedPosition &&
        last != null &&
        now.difference(last) < const Duration(milliseconds: 500)) {
      _seekDispatchTimer?.cancel();
      _pendingSeekPosition = null;
      return;
    }
    if (last == null || now.difference(last) >= _minimumSeekInterval) {
      _seekDispatchTimer?.cancel();
      _pendingSeekPosition = null;
      _lastSeekDispatchedAt = now;
      _lastSeekDispatchedPosition = position;
      _prepareWordHighlightSeek(position);
      callback(position);
      return;
    }

    _pendingSeekPosition = position;
    _seekDispatchTimer?.cancel();
    final remaining = _minimumSeekInterval - now.difference(last);
    _seekDispatchTimer = Timer(remaining, () {
      if (_disposed || !mounted) return;
      final target = _pendingSeekPosition;
      _pendingSeekPosition = null;
      if (target == null) return;
      _lastSeekDispatchedAt = DateTime.now();
      _lastSeekDispatchedPosition = target;
      _prepareWordHighlightSeek(target);
      widget.onSeek?.call(target);
    });
  }

  void _onExplicitLocateRequested() {
    if (_disposed || !mounted || _rows.isEmpty) return;
    final controller = widget.positionController;
    if (controller == null) return;
    _alacLatchedTapIndex = null;

    final activeIndex = _findActiveIndex(controller.position);
    final targetIndex = _scrollTargetForActiveIndex(
      activeIndex,
      position: controller.position,
    );
    final requestId = ++_explicitLocateRequestId;
    _explicitLocateActiveIndex = activeIndex;
    _resumeTimer?.cancel();
    _isUserScrolling = false;

    final distance = (targetIndex - _activeIndex).abs();
    _scrollToIndex(
      targetIndex,
      playbackPosition: controller.position,
      animate: true,
      isLargeJump: distance > _largeJumpThreshold,
    ).whenComplete(() {
      if (_disposed || !mounted || requestId != _explicitLocateRequestId) {
        return;
      }
      _explicitLocateActiveIndex = null;
    });
  }

  void _beginLinePointer(PointerDownEvent event, int index) {
    if (_downPointers.length > 1 || event.buttons != kPrimaryButton) return;
    if (_pointerTransaction != null) return;
    if (index < 0 || index >= _rows.length) return;
    final transaction = _LyricPointerTransaction(
      pointerId: event.pointer,
      index: index,
      groupId: _rows[index].groupId,
      origin: event.position,
      startedAt: event.timeStamp,
      slop: event.kind == PointerDeviceKind.mouse
          ? kPrecisePointerHitSlop
          : 8.0,
      generation: ++_pointerGeneration,
      kind: event.kind,
    );
    _pointerTransaction = transaction;
    _pointerHoldFreezesFollow = true;
    _resumeTimer?.cancel();
    _freezeScrollAtCurrentOffset();
    widget.onPointerHoldChanged?.call(true);
    _longPressTimer?.cancel();
    final generation = transaction.generation;
    _longPressTimer = Timer(kLongPressTimeout, () {
      final current = _pointerTransaction;
      if (current == null ||
          current.generation != generation ||
          current.consumed ||
          current.movedBeyondSlop) {
        return;
      }
      _commitLongPress(current);
    });
    _handleTapDown(index);
  }

  int _pointerGeneration = 0;

  void _freezeScrollAtCurrentOffset() {
    _frames.setLocating(false);
    _frameProbe?.markPhase(MusicLyricFramePhase.idle);
    _scrollRequestId++;
    final scrollContext = _scrollNotificationContext;
    if (scrollContext != null && scrollContext.mounted) {
      final position = Scrollable.maybeOf(scrollContext)?.position;
      if (position != null && position.hasPixels) {
        position.jumpTo(position.pixels);
        return;
      }
    }
    if (_windowsScrollController.hasClients) {
      _windowsScrollController.jumpTo(_windowsScrollController.offset);
    }
  }

  void _commitLongPress(_LyricPointerTransaction transaction) {
    if (transaction.consumed) return;
    transaction.consumed = true;
    transaction.committed = MusicLyricPointerCommit.longPress;
    _longPressTimer?.cancel();
    _releasePressedLine(transaction.index);
    final kind = transaction.kind;
    if (kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus) {
      unawaited(AppHaptics.selectionClick(SettingsService()));
    }
    final row = _rowForTransaction(transaction);
    if (row == null || !row.hasVisibleText) {
      _endPointerHold();
      return;
    }
    widget.onRequestTextSelection?.call(
      MusicLyricSelectionRequest(
        displayIndex: _rows.indexOf(row),
        groupId: row.groupId,
        time: _currentPosition,
        awaitingPointer: true,
      ),
    );
  }

  MusicLyricDisplayRow? _rowForTransaction(
    _LyricPointerTransaction transaction,
  ) {
    if (transaction.index >= 0 &&
        transaction.index < _rows.length &&
        _rows[transaction.index].groupId == transaction.groupId) {
      return _rows[transaction.index];
    }
    for (final row in _rows) {
      if (row.groupId == transaction.groupId) return row;
    }
    return null;
  }

  void _endPointerHold() {
    if (!_pointerHoldFreezesFollow) return;
    _pointerHoldFreezesFollow = false;
    widget.onPointerHoldChanged?.call(false);
  }

  int _nearestRow(Duration time) {
    if (_rows.isEmpty) return -1;
    var best = 0;
    var bestDistance = (_rows.first.start - time).inMicroseconds.abs();
    for (var index = 1; index < _rows.length; index++) {
      final distance = (_rows[index].start - time).inMicroseconds.abs();
      if (distance < bestDistance) {
        best = index;
        bestDistance = distance;
      }
    }
    return best;
  }

  void _handleRootPointerDown(PointerDownEvent event) {
    _downPointers.add(event.pointer);
    if (event.buttons == kSecondaryMouseButton) {
      // A right click must not seek. Selection opens only from a long press.
      return;
    }
    if (_downPointers.length > 1) {
      _cancelPendingLinePointer(permanent: true);
      return;
    }
    final index = _hitTestLyricIndex(event.position);
    if (index == null) return;

    // Remember the hit row in this stable parent even if the positioned-list
    // transition disposes it on pointer-down. Never seek until release confirms
    // that this interaction was a tap rather than a drag or a long-press.
    _beginLinePointer(event, index);
  }

  int? _hitTestLyricIndex(Offset globalPosition) {
    final candidates = <int>[];
    for (final region in _lyricHitRegions.toList(growable: false)) {
      final box = region.renderBox;
      if (box == null || !box.attached || !box.hasSize) continue;
      final local = box.globalToLocal(globalPosition);
      final rect = Offset.zero & box.size;
      if (rect.contains(local)) {
        candidates.add(region.index);
      }
    }
    if (candidates.isEmpty) return null;

    // Long-distance positioned-list transitions temporarily render two lists.
    // Prefer the row belonging to the list nearest the latest visual target.
    final reference =
        _directTapScrollTarget ??
        (_tappedIndex >= 0 ? _tappedIndex : _activeIndex);
    candidates.sort(
      (a, b) => (a - reference).abs().compareTo((b - reference).abs()),
    );
    return candidates.first;
  }

  void _handleRootPointerMove(PointerMoveEvent event) {
    final transaction = _pointerTransaction;
    if (transaction == null || event.pointer != transaction.pointerId) return;
    final distance = (event.position - transaction.origin).distance;
    if (distance > transaction.maxDistance) {
      transaction.maxDistance = distance;
    }
    if (transaction.maxDistance > transaction.slop) {
      transaction.movedBeyondSlop = true;
      _cancelPendingLinePointer(permanent: true);
    }
  }

  void _handleRootPointerUp(PointerUpEvent event) {
    _downPointers.remove(event.pointer);
    final transaction = _pointerTransaction;
    if (transaction == null || event.pointer != transaction.pointerId) return;
    final held = event.timeStamp - transaction.startedAt;
    final commit = resolveMusicLyricPointerRelease(
      consumed: transaction.consumed,
      movedBeyondSlop: transaction.movedBeyondSlop,
      held: held,
    );
    final index = transaction.index;
    if (commit == MusicLyricPointerCommit.longPress) {
      _commitLongPress(transaction);
    }
    _pointerTransaction = null;
    _longPressTimer?.cancel();
    _endPointerHold();
    if (commit == MusicLyricPointerCommit.tap) {
      _releasePressedLine(index);
      _handleTapLine(index, afterPointerUp: true);
    }
  }

  void _handleRootPointerCancel(PointerCancelEvent event) {
    _downPointers.remove(event.pointer);
    if (_pointerTransaction?.pointerId == event.pointer) {
      _cancelPendingLinePointer(permanent: true);
    }
  }

  void _cancelPendingLinePointer({bool permanent = true}) {
    final transaction = _pointerTransaction;
    _longPressTimer?.cancel();
    if (transaction != null && permanent) {
      transaction.consumed = true;
      transaction.movedBeyondSlop = transaction.movedBeyondSlop || permanent;
    }
    final index = transaction?.index;
    _pointerTransaction = null;
    if (index != null) _releasePressedLine(index);
    _endPointerHold();
  }

  void _handleTapDown(int index) {
    _pressedFeedbackTimer?.cancel();
    if (!mounted || _pressedIndex == index) return;
    setState(() => _pressedIndex = index);
  }

  void _releasePressedLine(int index) {
    _pressedFeedbackTimer?.cancel();
    _pressedFeedbackTimer = Timer(const Duration(milliseconds: 90), () {
      if (!mounted || _disposed || _pressedIndex != index) return;
      setState(() => _pressedIndex = -1);
    });
  }

  Widget _wrapTapInteraction(int index, Widget child) {
    return Semantics(
      button: true,
      onTap: () => _handleTapLine(index),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => _beginLinePointer(event, index),
        child: child,
      ),
    );
  }

  /// Apple Music 歌词透明度算法（包含点击和悬停效果）
  ///
  /// - 当前行 (offset=0)：完全不透明
  /// - 已播放 (offset<0)：比后续歌词更快融入背景
  /// - 后续行 (offset>0)：保留阅读线索，但远处不与当前行争夺注意力
  /// - 鼠标悬停：该行透明度稍微增加（变亮）
  double _opacityForOffset(int offset, bool isTapped, bool isHovered) {
    // 点击状态：完全不透明
    if (isTapped) return 1.0;

    // 当前行：完全不透明
    if (offset == 0) return 1.0;

    // 计算基础透明度
    double opacity;

    if (offset < 0) {
      // 已播放歌词更快淡出，尤其是 Header 后方的旧歌词。
      final distance = -offset; // 距离当前行的行数
      if (distance == 1) {
        opacity = 0.30;
      } else if (distance == 2) {
        opacity = 0.18;
      } else {
        opacity = 0.10;
      }
    } else {
      // 后续歌词稍亮于已播放歌词，仍可提前浏览。
      if (offset == 1) {
        opacity = 0.34;
      } else if (offset == 2) {
        opacity = 0.23;
      } else {
        opacity = 0.14;
      }
    }

    // 鼠标悬停效果：透明度稍微增加（变亮）
    // Apple Music 效果：悬停时透明度增加 0.15（微妙的变化）
    if (isHovered) {
      opacity = (opacity + 0.15).clamp(0.0, 1.0);
    }

    return opacity;
  }

  @override
  void dispose() {
    _disposed = true;
    _frameProbe?.dispose();
    if (_pointerHoldFreezesFollow) {
      widget.onPointerHoldChanged?.call(false);
    }
    _resumeTimer?.cancel();
    _longPressTimer?.cancel();
    _programmaticScrollResetTimer?.cancel();
    _jumpOpacityResetTimer?.cancel();
    _tapGuardResetTimer?.cancel();
    _tapTransactionTimeout?.cancel();
    _seekDispatchTimer?.cancel();
    _pressedFeedbackTimer?.cancel();
    widget.positionListenable?.removeListener(_onPositionChanged);
    widget.positionController?.removeListener(_onExplicitLocateRequested);
    _itemPositionsListener.itemPositions.removeListener(_onVisibleRowsChanged);
    _windowsScrollController.dispose();
    _contentOpacity.dispose();
    _contentAnimationController.dispose();
    _followMotion.dispose();
    super.dispose();
  }

  /// 暴露给外部的滚动方法：滚动到当前播放位置的字幕
  ///
  /// 用于全屏切换后自动定位到当前字幕，
  /// 也可以在其他需要刷新定位的场景下调用。
  /// [animate] 控制是否有动画，默认有动画。
  void scrollToCurrentIndex({bool animate = true}) {
    if (!mounted || _rows.isEmpty) return;
    final currentIndex = _findActiveIndex(_currentPosition);
    _scrollToIndex(
      _scrollTargetForActiveIndex(currentIndex),
      playbackPosition: _currentPosition,
      animate: animate,
      isLargeJump: true,
    );
  }

  // Use word completion only if the timings cover all meaningful cue text.
  // Partial/missing words retain the explicit sentence end. Background and
  // overlapping lines contribute to the coverage prefix below as well.
  static Duration _endForAutoFollow(SubtitleItem cue) {
    if (cue.timedSpans.isEmpty) return cue.endTime;
    final spans = cue.timedSpans.toList()
      ..sort((a, b) => a.textStart.compareTo(b.textStart));
    final meaningful = RegExp(r'[\p{L}\p{N}\p{M}\p{S}]', unicode: true);
    var cursor = 0;
    var end = cue.startTime;
    for (final span in spans) {
      if (span.textStart > cursor &&
          meaningful.hasMatch(cue.text.substring(cursor, span.textStart))) {
        return cue.endTime;
      }
      if (span.textEnd > cursor) cursor = span.textEnd;
      if (span.endTime > end) end = span.endTime;
    }
    return meaningful.hasMatch(cue.text.substring(cursor)) ? cue.endTime : end;
  }

  int _scrollTargetForActiveIndex(int activeIndex, {Duration? position}) {
    if (_rows.isEmpty) return -1;
    if (activeIndex < 0) return 0;
    final now = position ?? _currentPosition;
    if (activeIndex + 1 < _rows.length &&
        activeIndex < _followCoverageEnds.length &&
        now >= _followCoverageEnds[activeIndex] &&
        now < _rows[activeIndex + 1].start) {
      // A long gap has its own destination. Keep the departing sentence in
      // place until that interval begins instead of visiting the next lyric
      // first when complete word timings end before the explicit cue does.
      if (_interludeListIndexes.containsKey(activeIndex + 1) &&
          now < _lyricCoverageEnds[activeIndex]) {
        return activeIndex;
      }
      return activeIndex + 1;
    }
    return activeIndex;
  }

  /// 进入页面（或字幕首次就绪）时，把歌词滚动到当前播放位置对应的行。
  ///
  /// 与 [scrollToCurrentIndex] 的区别：本方法会忽略「索引是否变化」的判断，
  /// 即使当前行就是初始的第 0 行（例如视频一直暂停在 0 秒）也会强制把该行
  /// 滚动到锚点（视口约 30%）位置，而不是停留在自然滚动位置（顶部）。
  /// 同时保证在「视频从未播放」的场景下也能完成一次自动定位。
  /// 仅在尚未完成过初始定位时执行一次，避免干扰用户后续的手动滚动。
  Future<void> _performInitialLocate() async {
    if (!mounted || _rows.isEmpty) return;
    if (_initialLocateDone) return;
    final requestId = _locateRevealRequestId;
    _currentPosition = widget.positionListenable?.value ?? _currentPosition;
    final index = _findActiveIndex(_currentPosition);
    await _scrollToIndex(
      _scrollTargetForActiveIndex(index),
      playbackPosition: _currentPosition,
      animate: false,
      isLargeJump: true,
    );
    if (mounted && !_disposed && requestId == _locateRevealRequestId) {
      _initialLocateDone = true;
    }
  }

  @override
  Widget build(BuildContext context) => _build(context);

  MusicLyricTypography get _typography => MusicLyricTypography.resolve(
    viewport: MediaQuery.sizeOf(context),
    textScaler: MediaQuery.textScalerOf(context),
    fontSizeScale: widget.lyricFontSizeScale,
    spacingScale: widget.lyricSpacingScale,
  );

  Widget _build(BuildContext context) {
    _frameProbe?.attach(
      View.of(context),
      TickerMode.getValuesNotifier(context),
    );
    final screenWidth = MediaQuery.sizeOf(context).width;
    final typography = _typography;
    final engFontSize = typography.primaryFontSize;
    final zhFontSize = typography.secondaryFontSize;
    final stanzaGap = typography.stanzaGap;
    final engZhGap = typography.supportGap;
    if (!kDebugMode &&
        !_pressShadersWarmed &&
        !_pressWarmupScheduled &&
        _rows.isNotEmpty) {
      _pressWarmupScheduled = true;
      final ratio = MediaQuery.devicePixelRatioOf(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _disposed || _pressShadersWarmed) return;
        _pressShadersWarmed = true;
        unawaited(_warmPressShaders(engFontSize, ratio));
      });
    }

    return LayoutBuilder(
      key: _viewportKey,
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        _scheduleAnchorGuideReport();
        // 顶/底内边距：让首/末行也能滚动到锚点位置
        final topPadding =
            viewportHeight *
            (widget.focusInsets == null
                ? widget.anchorFraction
                : _firstRowAnchor ?? widget.anchorFraction);
        final bottomPadding = viewportHeight * (1.0 - widget.anchorFraction);
        final preludeSpace = (viewportHeight * _focusAnchor - engZhGap).clamp(
          0.0,
          double.infinity,
        );
        final preludeSize = typography.interludeSize.clamp(0.0, preludeSpace);

        final scrollContent = _buildScrollContent(
          screenWidth: screenWidth,
          viewportWidth: constraints.maxWidth,
          engFontSize: engFontSize,
          zhFontSize: zhFontSize,
          stanzaGap: stanzaGap,
          engZhGap: engZhGap,
          interludeSize: typography.interludeSize,
          topPadding: topPadding,
          bottomPadding: bottomPadding,
        );

        final revealedContent = FadeTransition(
          opacity: _contentOpacity,
          child: Stack(
            children: [
              scrollContent,
              if (!_isUserScrolling &&
                  widget.positionListenable != null &&
                  _rows.isNotEmpty &&
                  _rows.first.start >= const Duration(seconds: 5) &&
                  _currentPosition < _rows.first.start)
                Positioned(
                  left: screenWidth * widget.horizontalPaddingFraction,
                  // The first lyric is already aligned to topPadding. Use
                  // the leading padding above it for the prelude indicator.
                  top: preludeSpace - preludeSize,
                  child: MusicLyricInterlude(
                    key: const ValueKey('music-lyric-prelude'),
                    start: Duration.zero,
                    end: _rows.first.start,
                    clock: widget.positionListenable,
                    em: preludeSize,
                  ),
                ),
            ],
          ),
        );

        if (!widget.applyEdgeFade) return revealedContent;

        return ShaderMask(
          shaderCallback: (Rect bounds) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x00FFFFFF),
                Color(0xFFFFFFFF),
                Color(0xFFFFFFFF),
                Color(0x00FFFFFF),
              ],
              stops: [0.0, 0.15, 0.85, 1.0],
            ).createShader(bounds);
          },
          blendMode: BlendMode.dstIn,
          child: revealedContent,
        );
      },
    );
  }

  /// 处理 ScrollNotification，精准区分用户手动滚动与程序化滚动
  ///
  /// 核心逻辑：
  /// - 点击跳转时（_isTappingLine == true）完全忽略通知，避免误触发控件显隐
  /// - 程序化滚动（_isProgrammaticScroll == true）时完全忽略通知，避免自动跟随动画干扰控件显隐
  /// - 用户拖拽（dragDetails != null）或鼠标滚轮时记录方向并通知父组件
  /// - 滚动停止后延时恢复自动跟随
  bool _handleScrollNotification(ScrollNotification notification) {
    _scrollNotificationContext = notification.context;
    // Initial indexed layout can emit offset corrections before our first
    // jump. They must not be mistaken for a wheel gesture that pauses follow.
    if (!_initialLocateDone || !_contentAnimationController.isCompleted) {
      return false;
    }
    if (_pointerHoldFreezesFollow) return false;
    if (notification.depth == 0 && notification is ScrollUpdateNotification) {
      _followMotion.advance(notification.scrollDelta ?? 0);
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _frameProbe?.markPhase(MusicLyricFramePhase.drag);
      _followMotion.enabled = false;
      // The scrollable can accept a drag on pointer-down even before it moves
      // (our raw tap listener is deliberately outside the gesture arena).
      // Movement, cancellation and hold duration decide whether it is a tap.
      _scrollRequestId++;
      _directTapRequestId++;
      _tapTransactionTimeout?.cancel();
      _tapGuardResetTimer?.cancel();
      _programmaticScrollResetTimer?.cancel();
      _directTapScrollTarget = null;
      _isTappingLine = false;
      _isProgrammaticScroll = false;
    }
    // ✅ 点击跳转时忽略所有通知（避免点击跳转被误判为用户手动滚动）
    if (_isTappingLine) return false;

    // 程序化滚动时忽略所有通知（自动跟随动画不应触发控件显隐）
    if (_isProgrammaticScroll) return false;

    if (notification is ScrollStartNotification) {
      // dragDetails != null 表示用户通过触摸/鼠标拖拽发起的滚动（非程序化）
      if (notification.dragDetails != null) {
        _isDragScrolling = true;
        if (!_isUserScrolling) setState(() => _isUserScrolling = true);
        _resumeTimer?.cancel();
        widget.onManualScrollActivityChanged?.call(true);
      }
    }

    if (notification is ScrollUpdateNotification) {
      final scrollDelta = notification.scrollDelta ?? 0.0;
      // 仅处理用户手动滚动（拖拽或鼠标滚轮）
      if (_isUserScrolling && scrollDelta.abs() > 1.0) {
        final delta = -scrollDelta;
        // ✅ 修正方向逻辑（对标 Apple Music）：
        // delta > 0: 内容向下移动（用户向上滑/往前翻字幕）→ 显示控件（direction = 1.0）
        // delta < 0: 内容向上移动（用户向下滑/往后翻字幕）→ 隐藏控件（direction = -1.0）
        final direction = delta > 0 ? 1.0 : -1.0;
        // 仅当方向变化时才通知，避免重复回调
        if (_lastManualScrollDirection == null ||
            (direction > 0 && _lastManualScrollDirection! < 0) ||
            (direction < 0 && _lastManualScrollDirection! > 0)) {
          _lastManualScrollDirection = direction;
          widget.onScrollDirectionChanged?.call(direction);
        }
      }

      // 鼠标滚轮检测：无 dragDetails 但 offset 发生了变化（鼠标滚轮不会设置 dragDetails）
      if (!_isDragScrolling &&
          !_isProgrammaticScroll &&
          scrollDelta.abs() > 1.0) {
        _followMotion.enabled = false;
        if (!_isUserScrolling) {
          widget.onManualScrollActivityChanged?.call(true);
        }
        if (!_isUserScrolling) setState(() => _isUserScrolling = true);
        _resumeTimer?.cancel();
        final delta = -scrollDelta;
        // ✅ 修正方向逻辑
        final direction = delta > 0 ? 1.0 : -1.0;
        _lastManualScrollDirection = direction;
        widget.onScrollDirectionChanged?.call(direction);
      }
    }

    if (notification is ScrollEndNotification) {
      _frameProbe?.markPhase(MusicLyricFramePhase.idle);
      if (_isUserScrolling && !_isProgrammaticScroll) {
        widget.onManualScrollActivityChanged?.call(false);
        _scheduleResumeAutoFollow();
      }
      _isDragScrolling = false;
    }

    return false; // 不阻止通知冒泡
  }

  /// 用户停止滚动后延时恢复自动跟随
  void _scheduleResumeAutoFollow() {
    if (_pointerHoldFreezesFollow) return;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_autoResumeDelay, () {
      if (_disposed || !mounted) return;
      setState(() => _isUserScrolling = false);
      _lastManualScrollDirection = null;
      _isDragScrolling = false;
      // 通知父组件恢复自动跟随（显示控件）
      widget.onScrollDirectionChanged?.call(null);
      _scrollToIndex(
        _scrollTargetForActiveIndex(_activeIndex),
        playbackPosition: _currentPosition,
        animate: true,
      );
    });
  }

  Widget _buildScrollContent({
    required double screenWidth, // ✅ 屏幕宽度用于计算左右边距
    required double viewportWidth,
    required double engFontSize,
    required double zhFontSize,
    required double stanzaGap,
    required double engZhGap,
    required double interludeSize,
    required double topPadding,
    required double bottomPadding,
  }) {
    final rows = _rows;
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final padding = EdgeInsets.only(
      top: topPadding,
      bottom: bottomPadding,
      left: screenWidth * widget.horizontalPaddingFraction,
      right: screenWidth * widget.horizontalPaddingFraction,
    );
    const physics = BouncingScrollPhysics(
      parent: RangeMaintainingScrollPhysics(),
    );
    final isWindows = Theme.of(context).platform == TargetPlatform.windows;

    final Widget scrollView;
    if (isWindows) {
      _ensureWindowsMetrics(
        width: viewportWidth - padding.horizontal,
        engFontSize: engFontSize,
        zhFontSize: zhFontSize,
        stanzaGap: stanzaGap,
        engZhGap: engZhGap,
        interludeSize: interludeSize,
      );
      _windowsTopPadding = topPadding;
      scrollView = CustomScrollView(
        key: const ValueKey<String>('music-lyric-windows-single-scroll'),
        controller: _windowsScrollController,
        physics: physics,
        scrollCacheExtent: const ScrollCacheExtent.pixels(200),
        slivers: [
          SliverPadding(
            padding: widget.footer == null
                ? padding
                : padding.copyWith(bottom: 0),
            sliver: SliverVariedExtentList(
              itemExtentBuilder: (index, dimensions) =>
                  _windowsRowExtents[index],
              delegate: _MusicLyricSliverDelegate(
                (context, i) => _buildListEntry(
                  listIndex: i,
                  engFontSize: engFontSize,
                  zhFontSize: zhFontSize,
                  stanzaGap: stanzaGap,
                  engZhGap: engZhGap,
                  interludeSize: interludeSize,
                ),
                childCount: _listEntries.length,
                totalExtent: _windowsRowOffsets.last,
              ),
            ),
          ),
          if (widget.footer != null) ...[
            SliverPadding(
              padding: EdgeInsets.only(
                left: padding.left,
                right: padding.right,
              ),
              sliver: SliverToBoxAdapter(child: widget.footer),
            ),
            SliverToBoxAdapter(child: SizedBox(height: padding.bottom)),
          ],
        ],
      );
    } else {
      final initialLyricIndex = _scrollTargetForActiveIndex(
        _findActiveIndex(_currentPosition),
      ).clamp(0, rows.length - 1);
      final initialIndex = _listIndexForLyric(
        initialLyricIndex,
        playbackPosition: _currentPosition,
      );
      scrollView = ScrollablePositionedList.builder(
        key: const ValueKey<String>('music-lyric-positioned-list'),
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        padding: padding,
        physics: physics,
        itemCount: _listEntries.length + (widget.footer == null ? 0 : 1),
        initialScrollIndex: initialIndex,
        initialAlignment: initialIndex == 0 ? 0 : widget.anchorFraction,
        itemBuilder: (context, i) => i == _listEntries.length
            ? widget.footer!
            : _buildListEntry(
                listIndex: i,
                engFontSize: engFontSize,
                zhFontSize: zhFontSize,
                stanzaGap: stanzaGap,
                engZhGap: engZhGap,
                interludeSize: interludeSize,
              ),
      );
    }

    // The positioned list stores ItemPosition, unlike ordinary scrollables
    // and text fields which store a double. Keep its storage namespace local.
    final isolatedScrollView = KeyedSubtree(
      key: PageStorageKey(
        isWindows ? 'music-lyric-pixel-scroll' : 'music-lyric-item-scroll',
      ),
      child: scrollView,
    );

    // 用 NotificationListener 包裹，精准区分用户手动滚动与程序化滚动
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleRootPointerDown,
      onPointerMove: _handleRootPointerMove,
      onPointerUp: _handleRootPointerUp,
      onPointerCancel: _handleRootPointerCancel,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: isolatedScrollView,
      ),
    );
  }

  ({
    SubtitleItem main,
    List<SubtitleItem> background,
    String translation,
    List<SubtitleTimedSpan> translationSpans,
    String romanization,
    List<SubtitleTimedSpan> romanizationSpans,
  })
  _contentForRow(int index) {
    final row = _rows[index];
    return (
      main: row.main,
      background: row.background,
      translation: row.translation,
      translationSpans: row.translationSpans,
      romanization: row.romanization,
      romanizationSpans: row.romanizationSpans,
    );
  }

  TextStyle _mainStyle(SubtitleItem sub, String text, double size) {
    final chinese = _isChineseText(text);
    return TextStyle(
      fontFamily: chinese ? _fontFamilyZh : _fontFamilyEng,
      fontSize: sub.isBackgroundLyric ? size * 0.7 : size,
      fontWeight: chinese ? FontWeight.w600 : FontWeight.w800,
      color: Colors.white,
      height: 1.3,
      letterSpacing: -0.5,
      leadingDistribution: chinese ? TextLeadingDistribution.even : null,
    );
  }

  TextStyle _backgroundStyle(String mainText, double size) => TextStyle(
    fontFamily: _isChineseText(mainText) ? _fontFamilyZh : _fontFamilyEng,
    fontSize: size * 0.7,
    fontWeight: FontWeight.w600,
    color: Colors.white.withValues(alpha: 0.7),
    height: 1.3,
  );

  TextStyle _translationStyle(String text, double size, bool highlight) {
    final chinese = _isChineseText(text);
    return TextStyle(
      fontFamily: _fontFamilyZh,
      fontSize: size,
      fontWeight: chinese ? FontWeight.w600 : FontWeight.w800,
      color: Colors.white.withValues(alpha: highlight ? 0.70 : 0.50),
      height: 1.5,
      leadingDistribution: chinese ? TextLeadingDistribution.even : null,
    );
  }

  TextStyle _romanizationStyle(double size) => TextStyle(
    fontFamily: _fontFamilyEng,
    fontSize: size,
    color: Colors.white.withValues(alpha: 0.55),
    height: 1.5,
  );

  double Function(String, TextStyle) _textHeightMeasurer(double width) {
    final defaults = DefaultTextStyle.of(context);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final heightBehavior = DefaultTextHeightBehavior.maybeOf(context);
    final measured = <(String, TextStyle), double>{};
    return (text, style) {
      final key = (text, style);
      final cached = measured[key];
      if (cached != null) return cached;
      final painter = TextPainter(
        text: TextSpan(text: text, style: defaults.style.merge(style)),
        textDirection: direction,
        textScaler: scaler,
        locale: locale,
        textHeightBehavior: heightBehavior,
      )..layout(maxWidth: width.clamp(0.0, double.infinity));
      final result = painter.height;
      painter.dispose();
      return measured[key] = result;
    };
  }

  double _rowTextHeight(
    int index, {
    required double engFontSize,
    required double zhFontSize,
    required double engZhGap,
    required double Function(String, TextStyle) height,
  }) {
    final content = _contentForRow(index);
    final mainText = content.main.text;
    var extent = height(
      mainText,
      _mainStyle(_rows[index].followCue, mainText, engFontSize),
    );
    for (final background in content.background) {
      extent +=
          engZhGap +
          height(background.text, _backgroundStyle(mainText, engFontSize));
    }
    if (content.translation.isNotEmpty) {
      extent +=
          engZhGap +
          height(
            content.translation,
            _translationStyle(content.translation, zhFontSize, false),
          );
    }
    if (content.romanization.isNotEmpty) {
      extent +=
          engZhGap +
          height(content.romanization, _romanizationStyle(zhFontSize));
    }
    return extent;
  }

  double _alignmentForIndex(int index, {bool interlude = false}) {
    final insets = widget.focusInsets;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (insets == null ||
        viewport is! RenderBox ||
        !viewport.hasSize ||
        viewport.size.height <= 0) {
      return widget.anchorFraction;
    }
    final screen = MediaQuery.sizeOf(context);
    final typography = _typography;
    // Measure only the destination paragraph on mobile, preserving lazy list
    // construction even for hour-long podcast transcripts.
    final textHeight = interlude
        ? typography.interludeSize
        : _rowTextHeight(
            index,
            engFontSize: typography.primaryFontSize,
            zhFontSize: typography.secondaryFontSize,
            engZhGap: typography.supportGap,
            height: _textHeightMeasurer(
              viewport.size.width -
                  screen.width * widget.horizontalPaddingFraction * 2,
            ),
          );
    final minAnchor = (insets.top / viewport.size.height).clamp(0.0, 1.0);
    final maxAnchor =
        ((viewport.size.height - insets.bottom - textHeight) /
                viewport.size.height)
            .clamp(minAnchor, 1.0);
    // If a paragraph is taller than the reading area, start at its safe top
    // so the beginning remains visible and the rest can be scrolled normally.
    return widget.anchorFraction.clamp(minAnchor, maxAnchor);
  }

  void _ensureWindowsMetrics({
    required double width,
    required double engFontSize,
    required double zhFontSize,
    required double stanzaGap,
    required double engZhGap,
    required double interludeSize,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final defaults = DefaultTextStyle.of(context);
    final heightBehavior = DefaultTextHeightBehavior.maybeOf(context);
    final locale = Localizations.maybeLocaleOf(context);
    final key = (
      width,
      engFontSize,
      zhFontSize,
      stanzaGap,
      engZhGap,
      interludeSize,
      scaler,
      direction,
      defaults.style,
      heightBehavior,
      locale,
    );
    final sameLayout = key == _windowsMetricsKey;
    if (sameLayout && _windowsRowExtents.length == _listEntries.length) return;
    final height = _textHeightMeasurer(width);

    final start = sameLayout
        ? (_windowsRowExtents.length - 1).clamp(0, _listEntries.length)
        : 0;
    if (sameLayout) {
      _windowsRowOffsets.removeRange(start + 1, _windowsRowOffsets.length);
      _windowsRowExtents.removeRange(start, _windowsRowExtents.length);
    } else {
      _windowsRowOffsets = [0];
      _windowsRowExtents = [];
    }
    for (var index = start; index < _listEntries.length; index++) {
      final entry = _listEntries[index];
      final extent =
          stanzaGap +
          (entry.isInterlude
              ? interludeSize
              : _rowTextHeight(
                  entry.lyricIndex,
                  engFontSize: engFontSize,
                  zhFontSize: zhFontSize,
                  engZhGap: engZhGap,
                  height: height,
                ));
      _windowsRowOffsets.add(_windowsRowOffsets.last + extent);
      _windowsRowExtents.add(extent);
    }
    _windowsMetricsKey = key;
  }

  Widget _buildListEntry({
    required int listIndex,
    required double engFontSize,
    required double zhFontSize,
    required double stanzaGap,
    required double engZhGap,
    required double interludeSize,
  }) {
    final entry = _listEntries[listIndex];
    final index = entry.lyricIndex;
    if (!entry.isInterlude) {
      return _buildLyricGroup(
        index: index,
        sub: _rows[index].followCue,
        engFontSize: engFontSize,
        zhFontSize: zhFontSize,
        stanzaGap: stanzaGap,
        engZhGap: engZhGap,
      );
    }
    // Its own frame/depth and no lyric pointer wrapper: breathing dots must
    // stay clear during silence and never seek/select the departing sentence.
    return MusicLyricRowFrame(
      key: ValueKey('music-lyric-interlude-row-$index'),
      coordinator: _frames,
      index: index,
      child: MusicLyricFollow(
        motion: _followMotion,
        distance: listIndex - _focusListIndex,
        child: RepaintBoundary(
          child: MusicLyricDepth(
            viewportKey: _viewportKey,
            anchorFraction: _focusAnchor,
            motion: _followMotion,
            rasterFocus: true,
            blurEnabled: widget.lyricBlurEnabled,
            active: _followingInterlude && index == _followIndex,
            distance: listIndex - _focusListIndex,
            browsing: _isUserScrolling,
            child: Padding(
              padding: EdgeInsets.only(bottom: stanzaGap),
              child: Align(
                alignment: Alignment.topLeft,
                child: MusicLyricInterlude(
                  key: ValueKey('music-lyric-interlude-$index'),
                  start: entry.interludeStart!,
                  end: _rows[index].start,
                  clock: _followingInterlude && index == _followIndex
                      ? widget.positionListenable
                      : null,
                  em: interludeSize,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 构建双语歌词组（主字幕 + 副字幕）
  ///
  /// Layout stays fixed; paint transforms provide emphasis without rewrapping.
  /// 优化：使用 RepaintBoundary 减少重绘
  Widget _buildLyricGroup({
    required int index,
    required SubtitleItem sub,
    required double engFontSize,
    required double zhFontSize,
    required double stanzaGap,
    required double engZhGap,
  }) {
    final preciseLine = sub.isStructuredLyric || sub.timedSpans.isNotEmpty;
    final isActive = preciseLine
        ? _activePreciseLines.contains(index)
        : index == _activeIndex && !_followingInterlude;
    final isTapped = index == _tappedIndex;
    final isPressed = index == _pressedIndex;
    final isHovered = index == _hoveredIndex;
    final offset = index - _activeIndex;
    final opacityOffset = _followingInterlude
        ? _lyricListIndexes[index] - _focusListIndex
        : offset;
    // Apple Music 透明度：基于与当前行的距离 + 悬停效果
    final opacity = preciseLine && opacityOffset == 0 && !isActive && !isTapped
        ? 0.45
        : _opacityForOffset(
            opacityOffset,
            isActive || isTapped || isPressed,
            isHovered,
          );
    final highlight = isActive || isTapped;
    final suppressWordHighlight = _clearedWordHighlightRows.contains(
      _rows[index].groupId,
    );
    final waitingAtAnchor =
        !_followingInterlude &&
        index == _followIndex &&
        _followIndex > _activeIndex &&
        _activeIndex >= 0;

    final content = _contentForRow(index);
    final mainText = content.main.text;
    final translatedText = content.translation;
    final visual = content;
    // 关掉逐词后只拿掉词级着色，行级透明度仍由上面的 offset 决定。
    List<SubtitleTimedSpan> displaySpans(List<SubtitleTimedSpan> spans) =>
        widget.wordByWordEnabled ? spans : const [];
    final duetRight =
        sub.isStructuredLyric &&
        sub.lyricAgent != null &&
        sub.lyricAgent != _firstLyricAgent;

    final mainIsChinese = _isChineseText(mainText);
    final translationIsChinese = _isChineseText(translatedText);

    // Keep timed text attached throughout the visible list. Its filtered
    // paint clock already sleeps outside real word progress; substituting
    // plain text for distant cues introduced a fully-lit frame on entry.

    // Scale the press plate with the primary lyric size. A fixed 20px radius
    // matches tablet type (~40px) but reads as a capsule next to phone lyrics.
    final pressInsetH = (engFontSize * 0.30).clamp(7.0, 12.0);
    final pressInsetV = (engFontSize * 0.20).clamp(5.0, 8.0);

    // 构建歌词内容（复用）
    Widget lyricContent = Container(
      width: double.infinity,
      padding: EdgeInsets.only(bottom: stanzaGap),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -pressInsetH,
            right: -pressInsetH,
            top: -pressInsetV,
            bottom: -pressInsetV,
            child: IgnorePointer(
              child: AnimatedScale(
                scale: isPressed ? 1.0 : 0.985,
                duration: Duration(milliseconds: isPressed ? 105 : 720),
                curve: isPressed ? Curves.easeOutCubic : Curves.easeOutBack,
                child: AnimatedOpacity(
                  key: ValueKey<String>('music-lyric-press-$index'),
                  opacity: isPressed ? 1.0 : 0.0,
                  duration: Duration(milliseconds: isPressed ? 90 : 780),
                  curve: isPressed
                      ? Curves.easeOutCubic
                      : const Cubic(0.16, 1.0, 0.30, 1.0),
                  child: DecoratedBox(
                    decoration: _lyricPressDecoration(engFontSize),
                  ),
                ),
              ),
            ),
          ),
          // Keep Apple Music lyric fonts even when a global video subtitle
          // preset is active; that mode must not restyle this screen.
          Column(
            crossAxisAlignment: duetRight
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // === 原文（自动检测语言，中文用思源黑体，其他用 Inter）— 主导视觉 ===
              MusicTextOpticalAlignment(
                applyCjkRaise: mainIsChinese,
                fontSize: engFontSize,
                child: MusicTimedLyricText(
                  text: mainText,
                  spans: displaySpans(visual.main.timedSpans),
                  position: widget.positionListenable,
                  fallbackPosition: _currentPosition,
                  dimUnplayed: isActive,
                  suppressWordHighlight: suppressWordHighlight,
                  reduceMotion: MediaQuery.disableAnimationsOf(context),
                  textAlign: duetRight ? TextAlign.right : TextAlign.left,
                  style: _mainStyle(sub, mainText, engFontSize),
                ),
              ),
              for (final background in visual.background)
                Padding(
                  padding: EdgeInsets.only(top: engZhGap),
                  child: MusicTimedLyricText(
                    text: background.text,
                    spans: displaySpans(background.timedSpans),
                    position: widget.positionListenable,
                    fallbackPosition: _currentPosition,
                    dimUnplayed: isActive,
                    suppressWordHighlight: suppressWordHighlight,
                    reduceMotion: MediaQuery.disableAnimationsOf(context),
                    textAlign: duetRight ? TextAlign.right : TextAlign.left,
                    style: _backgroundStyle(mainText, engFontSize),
                  ),
                ),

              if (translatedText.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: engZhGap),
                  child: MusicTextOpticalAlignment(
                    applyCjkRaise: translationIsChinese,
                    fontSize: zhFontSize,
                    child: MusicTimedLyricText(
                      text: translatedText,
                      spans: displaySpans(content.translationSpans),
                      position: widget.positionListenable,
                      fallbackPosition: _currentPosition,
                      dimUnplayed: isActive,
                      suppressWordHighlight: suppressWordHighlight,
                      reduceMotion: MediaQuery.disableAnimationsOf(context),
                      textAlign: TextAlign.left,
                      style: _translationStyle(
                        translatedText,
                        zhFontSize,
                        highlight,
                      ),
                    ),
                  ),
                ),
              if (content.romanization.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: engZhGap),
                  child: MusicTimedLyricText(
                    text: content.romanization,
                    spans: displaySpans(content.romanizationSpans),
                    position: widget.positionListenable,
                    fallbackPosition: _currentPosition,
                    dimUnplayed: isActive,
                    suppressWordHighlight: suppressWordHighlight,
                    reduceMotion: MediaQuery.disableAnimationsOf(context),
                    style: _romanizationStyle(zhFontSize),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    // Keep one element tree as a row crosses the dynamic window. Swapping
    // Opacity/AnimatedOpacity or inserting boundaries used to reset animation
    // and hover state halfway through an automatic scroll.
    final repaintWrapper = RepaintBoundary(
      child: MusicLyricRowOpacity(
        key: ValueKey<String>('music-lyric-row-opacity-$index'),
        opacity: opacity,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Duration(
                milliseconds: _isLargeJump
                    ? _jumpOpacityDuration
                    : _normalOpacityDuration,
              ),
        curve: const Cubic(0.25, 0.8, 0.25, 1),
        child: lyricContent,
      ),
    );

    final feedbackWrapper = AnimatedScale(
      key: ValueKey<String>('music-lyric-row-scale-$index'),
      // Keep Windows glyphs at a stable geometry while locating. Scaling a
      // wrapped row around its centre moves its leading edge as the feedback
      // rebounds, even after the scroll has reached its destination.
      scale: isPressed && Theme.of(context).platform != TargetPlatform.windows
          ? 0.982
          : 1.0,
      duration: Duration(milliseconds: isPressed ? 105 : 680),
      curve: isPressed ? Curves.easeOutCubic : Curves.easeOutBack,
      alignment: Alignment.centerLeft,
      child: repaintWrapper,
    );

    final interactiveRow = MouseRegion(
      onEnter: (_) {
        if (mounted && _hoveredIndex != index) {
          setState(() => _hoveredIndex = index);
        }
      },
      onExit: (_) {
        if (mounted && _hoveredIndex == index) {
          setState(() => _hoveredIndex = -1);
        }
      },
      child: _wrapTapInteraction(index, feedbackWrapper),
    );

    return MusicLyricRowFrame(
      coordinator: _frames,
      index: index,
      child: MusicLyricFollow(
        motion: _followMotion,
        distance: offset,
        child: RepaintBoundary(
          child: MusicLyricDepth(
            viewportKey: _viewportKey,
            anchorFraction: _focusAnchor,
            motion: _followMotion,
            rasterFocus: true,
            blurEnabled: widget.lyricBlurEnabled,
            preserveActiveClarity:
                preciseLine && isActive && index != _followIndex,
            active:
                isTapped ||
                waitingAtAnchor ||
                (isActive && (preciseLine || index == _followIndex)),
            // The focus moves during a real gap as well. Using the singing
            // index here delayed the departing line's blur until the next cue.
            distance: _lyricListIndexes[index] - _focusListIndex,
            browsing: _isUserScrolling,
            alignment: duetRight ? Alignment.topRight : Alignment.topLeft,
            child: _LyricHitRegion(
              index: index,
              onAttach: _lyricHitRegions.add,
              onDetach: _lyricHitRegions.remove,
              child: interactiveRow,
            ),
          ),
        ),
      ),
    );
  }
}

class _MusicLyricListEntry {
  const _MusicLyricListEntry(this.lyricIndex, [this.interludeStart]);

  final int lyricIndex;
  final Duration? interludeStart;

  bool get isInterlude => interludeStart != null;
}

class _LyricPointerTransaction {
  final int pointerId;
  final int index;
  final String groupId;
  final Offset origin;
  final Duration startedAt;
  final double slop;
  final int generation;
  final PointerDeviceKind kind;
  double maxDistance = 0;
  bool movedBeyondSlop = false;
  bool consumed = false;
  MusicLyricPointerCommit? committed;

  _LyricPointerTransaction({
    required this.pointerId,
    required this.index,
    required this.groupId,
    required this.origin,
    required this.startedAt,
    required this.slop,
    required this.generation,
    required this.kind,
  });
}

class _LyricHitRegion extends StatefulWidget {
  final int index;
  final ValueChanged<_LyricHitRegionState> onAttach;
  final ValueChanged<_LyricHitRegionState> onDetach;
  final Widget child;

  const _LyricHitRegion({
    required this.index,
    required this.onAttach,
    required this.onDetach,
    required this.child,
  });

  @override
  State<_LyricHitRegion> createState() => _LyricHitRegionState();
}

class _LyricHitRegionState extends State<_LyricHitRegion> {
  int get index => widget.index;

  RenderBox? get renderBox {
    final renderObject = context.findRenderObject();
    return renderObject is RenderBox ? renderObject : null;
  }

  @override
  void initState() {
    super.initState();
    widget.onAttach(this);
  }

  @override
  void didUpdateWidget(covariant _LyricHitRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onAttach != widget.onAttach ||
        oldWidget.onDetach != widget.onDetach) {
      oldWidget.onDetach(this);
      widget.onAttach(this);
    }
  }

  @override
  void dispose() {
    widget.onDetach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Keeps the lazy viewport's scroll range exact for variable-height lyrics.
class _MusicLyricSliverDelegate extends SliverChildBuilderDelegate {
  final double totalExtent;
  _MusicLyricSliverDelegate(
    super.builder, {
    required super.childCount,
    required this.totalExtent,
  }) : super(addAutomaticKeepAlives: false);
  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => totalExtent;
}
