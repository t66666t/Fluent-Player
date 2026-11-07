import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/music_volume_controller.dart';
import '../services/drag_haptic_session.dart';
import '../services/settings_service.dart';
import '../utils/desktop_player_shortcuts.dart';
import 'music_play_pause_button.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Apple Music 风格播放控制栏（严格对齐 Apple Music 全屏播放页面截图）
///
/// 布局结构（垂直排列，宽度由父组件约束）：
///   1. 进度条行：Slider，其下为当前时间 + 总时长。点右侧时间可改成剩余时间（-mm:ss）
///      横竖屏都可在时间行放一颗「字幕管理」胶囊，水平中心对齐进度条
///   2. 控制按钮行：[音量] [页面设置]  ...  [◀◀] [▶/⏸] [▶▶]  ...  [更多]
///
/// 所有尺寸基于屏幕短边计算，适配不同分辨率和横竖屏。
///
/// 性能优化：进度条区域用 ValueListenableBuilder 监听 positionListenable，
/// 只有进度条叶子节点每帧重绘，整棵控件树不因进度变化而重建。
class MusicPlaybackControls extends StatefulWidget {
  final Duration totalDuration;
  final bool isPlaying;
  final bool isLoading;
  final ValueListenable<Duration>? positionListenable;
  final ValueChanged<double>? onProgressChanged;
  final ValueChanged<double>? onProgressChangeStart;
  final ValueChanged<double>? onProgressChangeEnd;
  final VoidCallback? onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  // 字号调节回调
  final VoidCallback? onFontSizeAdjust;

  /// Hidden while lyric text selection is open. The reading size is separate
  /// from the selection document's type size.
  final bool showFontSizeControl;

  /// Previous and next stay available from the menu when the player is
  /// collapsed to the mini transport.
  final bool showSkipControls;
  // 字号调节按钮的 GlobalKey，用于定位字号调节滑块
  final GlobalKey? fontSizeButtonKey;
  // 当前播放位置（当 positionListenable 未提供时的备用）
  final Duration currentPosition;
  // 进度值 0.0~1.0（当 positionListenable 未提供时的备用）
  final double progress;
  // 音量相关参数
  final double volume;
  final bool isMuted;
  final MusicVolumeController? volumeController;
  final VoidCallback? onVolumePressed;
  final GlobalKey? volumeButtonKey;
  final bool compactLandscape;

  /// Distance from the controls' bottom to the largest transport icon's box.
  /// Used by docked phone layouts; null preserves the natural controls layout.
  final double? bottomIconInset;
  final String previousLabel, nextLabel;

  /// 横竖屏共用入口，位于进度条与播放键之间，并与进度条水平居中对齐。
  final VoidCallback? onSubtitleManagement;
  final Key? subtitleManagementKey;

  /// Overlaid directly under the elapsed time without resizing the controls.
  final String? temporarySpeedLabel;

  const MusicPlaybackControls({
    super.key,
    required this.totalDuration,
    this.isPlaying = false,
    this.isLoading = false,
    this.positionListenable,
    this.currentPosition = Duration.zero,
    this.progress = 0.0,
    this.onProgressChanged,
    this.onProgressChangeStart,
    this.onProgressChangeEnd,
    this.onPlayPause,
    this.onPrevious,
    this.onNext,
    this.onFontSizeAdjust,
    this.showFontSizeControl = true,
    this.showSkipControls = true,
    this.fontSizeButtonKey,
    this.volume = 1.0,
    this.isMuted = false,
    this.volumeController,
    this.onVolumePressed,
    this.volumeButtonKey,
    this.compactLandscape = false,
    this.bottomIconInset,
    this.previousLabel = '上一曲',
    this.nextLabel = '下一曲',
    this.onSubtitleManagement,
    this.subtitleManagementKey,
    this.temporarySpeedLabel,
  });

  @override
  State<MusicPlaybackControls> createState() => _MusicPlaybackControlsState();
}

class _MusicPlaybackControlsState extends State<MusicPlaybackControls> {
  bool _isScrubbing = false;
  final _progressHaptics = DragHapticSession();

  /// 控件单测没有设置服务时，只在这一棵控件里记住。正式播放页走 SettingsService。
  bool _showRemainingWithoutSettings = false;

  @override
  void didUpdateWidget(MusicPlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionListenable != widget.positionListenable ||
        widget.onProgressChanged == null ||
        widget.isLoading) {
      _progressHaptics.reset();
    }
  }

  @override
  void dispose() {
    _progressHaptics.reset();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}:${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
    }
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  /// 右侧时间。false 显示总时长；true 显示带负号的剩余时间。
  SettingsService? _settingsOrNull(BuildContext context, {bool listen = true}) {
    try {
      return Provider.of<SettingsService>(context, listen: listen);
    } on ProviderNotFoundException {
      // 控件单测没有套设置服务，改用这一棵控件自己的状态。
      return null;
    }
  }

  bool _showsRemaining(BuildContext context) {
    final settings = _settingsOrNull(context);
    if (settings == null) return _showRemainingWithoutSettings;
    return settings.musicProgressShowsRemaining;
  }

  void _toggleEndTime() {
    final settings = _settingsOrNull(context, listen: false);
    if (settings == null) {
      setState(() {
        _showRemainingWithoutSettings = !_showRemainingWithoutSettings;
      });
      return;
    }
    // 内存先换字，磁盘随后写完。下次打开播放页仍是这一次的选择。
    settings.updateMusicProgressShowsRemaining(
      !settings.musicProgressShowsRemaining,
    );
  }

  String _endTimeLabel(Duration total, Duration remaining, bool showRemaining) {
    if (showRemaining) return '-${_formatDuration(remaining)}';
    return _formatDuration(total);
  }

  /// 非静音时固定使用完整的扬声器图标，不随音量档位变化。
  IconData _getVolumeIcon() {
    final volume = widget.volumeController?.volume ?? widget.volume;
    if ((widget.volumeController?.isMuted ?? widget.isMuted) || volume <= 0) {
      return Icons.volume_off_outlined;
    }
    return Icons.volume_up_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final orientation = MediaQuery.orientationOf(context);

    // 基准尺寸：竖屏时使用高度（较长边），横屏时使用宽度（较长边）
    // 这样可以避免细长手机上按钮过小的问题
    final baseDimension = widget.compactLandscape
        ? screenHeight
        : orientation == Orientation.portrait
        ? screenHeight // 竖屏：使用高度（较长边）
        : screenWidth; // 横屏：使用宽度（较长边）

    // 手机判断：基于最短边（适配横竖屏）
    final shortestSide = MediaQuery.sizeOf(context).shortestSide;
    final isMobile = shortestSide < 600;
    final rowHeight = _buttonMinimumSize(screenHeight, isMobile) * 1.25;
    final bottomPadding = widget.bottomIconInset == null
        ? 0.0
        : (widget.bottomIconInset! -
                  (rowHeight -
                          _playIconSize(
                            baseDimension,
                            screenHeight,
                            isMobile,
                          )) /
                      2)
              .clamp(0.0, double.infinity);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The position clock advances at the display rate. Keep its paint
        // damage inside the progress area instead of repainting the artwork
        // and the full-screen backdrop with every slider update.
        RepaintBoundary(
          key: const ValueKey('music-playback-progress'),
          child: _buildProgressBar(baseDimension, isMobile),
        ),
        SizedBox(
          height: widget.compactLandscape
              ? (screenHeight * 0.035).clamp(10.0, 16.0)
              : orientation == Orientation.portrait && screenWidth < 768
              ? (screenHeight * 0.022).clamp(14.0, 22.0)
              : (screenHeight * 0.05).clamp(34.0, 54.0),
        ),
        if (widget.bottomIconInset != null)
          SizedBox(
            height: rowHeight,
            child: _buildControlButtons(baseDimension, screenHeight, isMobile),
          )
        else
          _buildControlButtons(baseDimension, screenHeight, isMobile),
        if (bottomPadding > 0) SizedBox(height: bottomPadding),
      ],
    );
  }

  /// 进度条行：左侧当前时间 | 滑块 | 右侧总时长或剩余时间
  ///
  /// 用 ValueListenableBuilder 监听 positionListenable，只有进度条叶子节点
  /// 每帧重绘，整棵 MusicPlaybackControls 不因进度变化而重建。
  /// 如果没有提供 positionListenable，则直接使用 currentPosition 和 progress。
  Widget _buildProgressBar(double baseDim, bool isMobile) {
    // 时间文字字号：手机 ~3.2% clamp(10,13)；桌面 ~3.8% clamp(11,16)
    final timeFontSize = widget.compactLandscape
        ? (baseDim * 0.03).clamp(9.0, 11.0)
        : isMobile
        ? (baseDim * 0.032).clamp(10.0, 13.0)
        : (baseDim * 0.038).clamp(11.0, 16.0);
    // 进度条轨道高度：手机 ~0.5% clamp(3,6)；桌面 ~0.6% clamp(4,8)
    final trackH = widget.compactLandscape
        ? (baseDim * 0.009).clamp(2.5, 3.5)
        : isMobile
        ? (baseDim * 0.005).clamp(3.0, 6.0)
        : (baseDim * 0.006).clamp(4.0, 8.0);
    // 静止状态不显示拇指；拖动时才淡入接近 Apple Music 的小圆点。
    final thumbR = (trackH * 1.6).clamp(4.0, 9.0);
    final timeColor = Colors.white.withValues(alpha: 0.7);
    // 在进度条这一层读取，时间标签每秒重建时不会重复订阅设置。
    final showRemaining = _showsRemaining(context);

    // 如果没有提供 positionListenable，直接使用 currentPosition 和 progress
    if (widget.positionListenable == null) {
      return _buildProgressContent(
        widget.currentPosition,
        widget.totalDuration,
        widget.progress,
        baseDim,
        isMobile,
        timeFontSize,
        trackH,
        thumbR,
        timeColor,
        showRemaining,
      );
    }

    // position 和滑块必须来自同一个逐帧状态源。否则 seek 后父组件尚未重建时，
    // 时间文字已经到了新位置，Slider 却仍会短暂使用旧 progress。
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.positionListenable!,
      child: _MusicPlaybackTimeLabels(
        position: widget.positionListenable!,
        totalDuration: widget.totalDuration,
        builder: (current, remaining) => _buildTimestampRow(
          currentLabel: _formatDuration(current),
          endLabel: _endTimeLabel(
            widget.totalDuration,
            remaining,
            showRemaining,
          ),
          timeFontSize: timeFontSize,
          timeColor: timeColor,
          baseDim: baseDim,
          isMobile: isMobile,
        ),
      ),
      builder: (context, position, timestamps) => _buildProgressContent(
        position,
        widget.totalDuration,
        widget.totalDuration.inMilliseconds > 0
            ? position.inMilliseconds / widget.totalDuration.inMilliseconds
            : 0.0,
        baseDim,
        isMobile,
        timeFontSize,
        trackH,
        thumbR,
        timeColor,
        showRemaining,
        timestampRow: timestamps,
      ),
    );
  }

  /// 进度条具体内容（抽取出来，供 ValueListenableBuilder 的 builder 调用）
  ///
  /// 进度值（progress）由父组件传入，确保滑块位置与显示时间同步，
  /// 尤其在拖动进度条时能实时跟随手指位置。
  Widget _buildProgressContent(
    Duration currentPosition,
    Duration totalDuration,
    double progress,
    double baseDim,
    bool isMobile,
    double timeFontSize,
    double trackH,
    double thumbR,
    Color timeColor,
    bool showRemaining, {
    Widget? timestampRow,
  }) {
    final rawRemaining = totalDuration - currentPosition;
    final remaining = rawRemaining.isNegative ? Duration.zero : rawRemaining;
    // 使用父组件传入的 progress，确保滑块位置与显示时间一致
    final effectiveProgress = totalDuration.inMilliseconds > 0
        ? progress.clamp(0.0, 1.0)
        : 0.0;

    final effectiveTrackHeight = _isScrubbing ? trackH * 1.45 : trackH;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: widget.compactLandscape ? 18 : 24,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: effectiveTrackHeight,
              thumbShape: _isScrubbing
                  ? RoundSliderThumbShape(enabledThumbRadius: thumbR)
                  : SliderComponentShape.noThumb,
              overlayShape: _isScrubbing
                  ? RoundSliderOverlayShape(overlayRadius: thumbR * 2.4)
                  : SliderComponentShape.noOverlay,
              activeTrackColor: Colors.white.withValues(alpha: 0.62),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.24),
              thumbColor: Colors.white.withValues(alpha: 0.92),
              overlayColor: Colors.white.withValues(alpha: 0.10),
              trackShape: AppleMusicSliderTrackShape(),
            ),
            child: Listener(
              onPointerDown: _progressHaptics.pointerDown,
              onPointerMove: _progressHaptics.pointerMove,
              onPointerCancel: (_) => _progressHaptics.reset(),
              child: Slider(
                key: const ValueKey('music-progress-slider'),
                value: effectiveProgress,
                padding: EdgeInsets.zero,
                onChanged: widget.onProgressChanged == null
                    ? null
                    : (value) {
                        _progressHaptics.update(value);
                        widget.onProgressChanged!(value);
                      },
                onChangeStart: widget.onProgressChangeStart == null
                    ? null
                    : (value) {
                        if (totalDuration > Duration.zero) {
                          _progressHaptics.begin(value);
                        }
                        setState(() => _isScrubbing = true);
                        widget.onProgressChangeStart?.call(value);
                      },
                onChangeEnd: widget.onProgressChangeEnd == null
                    ? null
                    : (value) {
                        _progressHaptics.end();
                        setState(() => _isScrubbing = false);
                        widget.onProgressChangeEnd?.call(value);
                      },
              ),
            ),
          ),
        ),
        const SizedBox(height: 1),
        timestampRow ??
            _buildTimestampRow(
              currentLabel: _formatDuration(currentPosition),
              endLabel: _endTimeLabel(totalDuration, remaining, showRemaining),
              timeFontSize: timeFontSize,
              timeColor: timeColor,
              baseDim: baseDim,
              isMobile: isMobile,
            ),
      ],
    );
  }

  /// 时间行。字幕入口在横竖屏中保持相同的位置和样式。
  ///
  /// 胶囊叠在整行正中，跟进度条共用同一条水平中线。两侧时间仍贴在
  /// 轨道两端；剩余时间多一个负号、或某一侧出现小时位时，不能再按
  /// 两条文字之间的空隙居中，否则胶囊会跟着文字宽度左右偏移。
  Widget _buildTimestampRow({
    required String currentLabel,
    required String endLabel,
    required double timeFontSize,
    required Color timeColor,
    required double baseDim,
    required bool isMobile,
  }) {
    final timeStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: timeFontSize,
      fontWeight: FontWeight.w500,
      color: timeColor,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final currentTime = Text(
      currentLabel,
      key: const ValueKey('music-current-time'),
      maxLines: 1,
      softWrap: false,
      style: timeStyle,
    );
    final speedLabel = widget.temporarySpeedLabel;
    final current = Stack(
      clipBehavior: Clip.none,
      children: [
        currentTime,
        if (speedLabel != null)
          Positioned(
            bottom: 0,
            left: 0,
            child: FractionalTranslation(
              // Place the hint below the time without contributing to the
              // row's layout size or moving the transport controls.
              translation: const Offset(0, 1),
              child: IgnorePointer(
                child: Text(
                  speedLabel,
                  key: const ValueKey('music-temporary-speed-label'),
                  maxLines: 1,
                  softWrap: false,
                  style: timeStyle,
                ),
              ),
            ),
          ),
      ],
    );
    // 负号会让文字变宽，但行仍是两端对齐，所以右缘一直贴着进度条右端。
    final remaining = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleEndTime,
        child: Text(
          endLabel,
          key: const ValueKey('music-remaining-time'),
          textAlign: TextAlign.end,
          maxLines: 1,
          softWrap: false,
          style: timeStyle,
        ),
      ),
    );
    final chip = _buildSubtitleManagementChip(baseDim, isMobile);
    final times = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [current, remaining],
    );
    if (chip == null) return times;
    return Stack(alignment: Alignment.center, children: [times, chip]);
  }

  /// 播放键图标边长。胶囊按它同比缩放，横竖屏切换时比例保持不变。
  double _playIconSize(double baseDim, double screenHeight, bool isMobile) {
    final mainIconSize = widget.compactLandscape
        ? (screenHeight * 0.072).clamp(22.0, 28.0)
        : isMobile
        ? (baseDim * 0.055).clamp(30.0, 42.0)
        : (baseDim * 0.065).clamp(20.0, 34.0);
    return mainIconSize * 1.22;
  }

  /// 对照参考图里的音质胶囊。
  ///
  /// 原图实测：播放图标 105px 时，胶囊约 148×59，内部「图标 + 无损」墨迹约 107×27。
  /// 「字幕管理」四字的宽度接近那组图标加两个字，所以外框继续按播放图标的
  /// 1.41 倍宽、0.56 倍高来定，字号再略抬高一点，避免缩得看不清。
  Widget? _buildSubtitleManagementChip(double baseDim, bool isMobile) {
    final onPressed = widget.onSubtitleManagement;
    if (onPressed == null) return null;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final playIconSize = _playIconSize(baseDim, screenHeight, isMobile);
    const referencePlay = 105.0;
    final fontSize = (playIconSize * 27 / referencePlay).clamp(10.0, 12.0);
    const lineHeightFactor = 1.05;
    final targetHeight = playIconSize * 59 / referencePlay;
    final targetWidth = playIconSize * 148 / referencePlay;
    final verticalPadding = ((targetHeight - fontSize * lineHeightFactor) / 2)
        .clamp(2.0, 8.0);
    // 四字按方块字估算占位；左右留白不够时仍保持胶囊，不把外框撑成大按钮。
    final horizontalPadding = ((targetWidth - fontSize * 4) / 2).clamp(
      6.0,
      10.0,
    );
    return Tooltip(
      message: DesktopPlayerShortcuts.buildTooltip(
        '字幕管理',
        DesktopPlayerShortcutAction.openSubtitleLibrary,
        context: context,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key:
              widget.subtitleManagementKey ??
              const ValueKey('music-landscape-subtitle-management'),
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: horizontalPadding,
                vertical: verticalPadding,
              ),
              child: Text(
                '字幕管理',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontFamily: 'Noto Sans SC',
                  fontSize: fontSize,
                  fontWeight: FontWeight.w500,
                  height: lineHeightFactor,
                  color: Colors.white.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _buttonMinimumSize(double screenHeight, bool isMobile) =>
      widget.compactLandscape
      ? (screenHeight * 0.11).clamp(36.0, 42.0)
      : isMobile
      ? 44.0
      : 48.0;

  /// 控制按钮行 — 统一设计风格，适配手机和桌面
  /// 布局：[音量]  ...  [◀◀] [▶/⏸] [▶▶]  ...  [页面设置]
  Widget _buildControlButtons(
    double baseDim,
    double screenHeight,
    bool isMobile,
  ) {
    // 主控图标（上一曲/播放/下一曲）：
    // 手机 ~5.5% clamp(16,24)；桌面 ~6.5% clamp(20,34)
    final mainIconSize = _playIconSize(baseDim, screenHeight, isMobile) / 1.22;
    // 次要图标（音量/页面设置）：
    // 手机 ~3.5% clamp(12,18)；桌面 ~4.2% clamp(14,24)
    final secondaryIconSize = widget.compactLandscape
        ? (screenHeight * 0.045).clamp(14.0, 17.0)
        : isMobile
        ? (baseDim * 0.035).clamp(12.0, 18.0)
        : (baseDim * 0.042).clamp(14.0, 24.0);
    final playIconSize = mainIconSize * 1.22;
    // 统一按钮颜色
    final secondaryColor = Colors.white.withValues(alpha: 0.7);
    // 统一按钮触控区域
    final buttonMinSize = _buttonMinimumSize(screenHeight, isMobile);

    Widget volumeButton() => DesktopButtonClickRegion(
      child: IconButton(
        key: widget.volumeButtonKey,
        icon: Icon(
          _getVolumeIcon(),
          size: secondaryIconSize,
          color: secondaryColor,
        ),
        onPressed: widget.onVolumePressed,
        tooltip: '音量',
        iconSize: secondaryIconSize,
        padding: const EdgeInsets.all(8),
        constraints: BoxConstraints(
          minWidth: buttonMinSize,
          minHeight: buttonMinSize,
        ),
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ===== 左侧组：音量按钮（Expanded 占等宽空间，靠左对齐）=====
        SizedBox(
          width: buttonMinSize,
          child: widget.volumeController == null
              ? volumeButton()
              : ListenableBuilder(
                  listenable: widget.volumeController!,
                  builder: (_, _) => volumeButton(),
                ),
        ),

        // ===== 中央组：在剩余宽度内均匀分布，窄屏也不会挤压两侧按钮 =====
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (widget.showSkipControls)
                DesktopButtonClickRegion(
                  child: IconButton(
                    icon: const Icon(
                      CupertinoIcons.backward_fill,
                      color: Colors.white,
                    ),
                    onPressed: widget.onPrevious,
                    tooltip: DesktopPlayerShortcuts.buildTooltip(
                      widget.previousLabel,
                      DesktopPlayerShortcutAction.previousEpisode,
                      context: context,
                    ),
                    iconSize: mainIconSize,
                    padding: const EdgeInsets.all(4),
                    constraints: BoxConstraints(
                      minWidth: buttonMinSize,
                      minHeight: buttonMinSize,
                    ),
                  ),
                ),
              MusicPlayPauseButton(
                onPressed: widget.onPlayPause,
                isPlaying: widget.isPlaying,
                isLoading: widget.isLoading,
                iconSize: playIconSize,
                minimumSize: buttonMinSize * 1.25,
              ),
              if (widget.showSkipControls)
                DesktopButtonClickRegion(
                  child: IconButton(
                    icon: const Icon(
                      CupertinoIcons.forward_fill,
                      color: Colors.white,
                    ),
                    onPressed: widget.onNext,
                    tooltip: DesktopPlayerShortcuts.buildTooltip(
                      widget.nextLabel,
                      DesktopPlayerShortcutAction.nextEpisode,
                      context: context,
                    ),
                    iconSize: mainIconSize,
                    padding: const EdgeInsets.all(4),
                    constraints: BoxConstraints(
                      minWidth: buttonMinSize,
                      minHeight: buttonMinSize,
                    ),
                  ),
                ),
            ],
          ),
        ),

        SizedBox(
          width: buttonMinSize,
          child: widget.showFontSizeControl
              ? DesktopButtonClickRegion(
                  child: IconButton(
                    key: widget.fontSizeButtonKey,
                    icon: Icon(
                      Icons.format_size,
                      size: secondaryIconSize,
                      color: secondaryColor,
                    ),
                    onPressed: widget.onFontSizeAdjust,
                    tooltip: DesktopPlayerShortcuts.buildTooltip(
                      '页面设置',
                      DesktopPlayerShortcutAction.openSettings,
                      context: context,
                    ),
                    iconSize: secondaryIconSize,
                    padding: const EdgeInsets.all(8),
                    constraints: BoxConstraints(
                      minWidth: buttonMinSize,
                      minHeight: buttonMinSize,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// Only the slider needs sub-second updates. Its labels (and the subtitle
/// button between them) retain their elements while the displayed seconds
/// stay equal, including the independent boundary of the remaining time.
class _MusicPlaybackTimeLabels extends StatefulWidget {
  const _MusicPlaybackTimeLabels({
    required this.position,
    required this.totalDuration,
    required this.builder,
  });

  final ValueListenable<Duration> position;
  final Duration totalDuration;
  final Widget Function(Duration current, Duration remaining) builder;

  @override
  State<_MusicPlaybackTimeLabels> createState() =>
      _MusicPlaybackTimeLabelsState();
}

class _MusicPlaybackTimeLabelsState extends State<_MusicPlaybackTimeLabels> {
  late (int, int) _seconds;

  (int, int) _readSeconds() {
    final position = widget.position.value;
    final remaining = widget.totalDuration - position;
    return (position.inSeconds, remaining.isNegative ? 0 : remaining.inSeconds);
  }

  @override
  void initState() {
    super.initState();
    _seconds = _readSeconds();
    widget.position.addListener(_onPosition);
  }

  @override
  void didUpdateWidget(_MusicPlaybackTimeLabels oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_onPosition);
      widget.position.addListener(_onPosition);
    }
    _seconds = _readSeconds();
  }

  void _onPosition() {
    final next = _readSeconds();
    if (next == _seconds) return;
    setState(() => _seconds = next);
  }

  @override
  void dispose() {
    widget.position.removeListener(_onPosition);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    Duration(seconds: _seconds.$1),
    Duration(seconds: _seconds.$2),
  );
}

/// 自定义圆角轨道形状
class AppleMusicSliderTrackShape extends RoundedRectSliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 4;
    // 轨道无论是否正在拖动都保持同一宽度，避免拇指出现时两端跳动。
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}
