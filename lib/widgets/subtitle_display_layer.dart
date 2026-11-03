import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/subtitle_display_state.dart';
import '../models/subtitle_style.dart';
import '../services/subtitle_position_controller.dart';
import 'subtitle_overlay.dart';

/// 独立字幕显示层 — 内部通过 [ValueListenableBuilder] 监听
/// [SubtitleDisplayState] 的变化，仅重建 [SubtitleOverlayGroup] 子树，
/// 避免字幕每帧更新触发整页 setState。
///
/// 将三处 [SubtitleOverlayGroup] 渲染路径（视频绑定覆盖层、自由定位覆盖层、
/// Ghost 模式覆盖层）统一替换为此 Widget，实现字幕更新的局部隔离。
class SubtitleDisplayLayer extends StatelessWidget {
  final ValueListenable<SubtitleDisplayState> notifier;

  final Alignment alignment;
  final SubtitleStyle style;
  final double? referenceHeight;

  /// Complete page size before sidebar allocation and keyboard avoidance.
  final Size? fullPageSize;
  final bool isGhostMode;
  final bool isDragging;
  final bool isGestureOnly;
  final bool isVisualOnly;
  final bool animateAlignment;
  final Duration alignmentDuration;
  final Curve alignmentCurve;
  final double itemGap;
  final ValueListenable<bool>? playbackControlsVisibility;
  final double? playbackControlsTop;
  final List<Rect> Function()? playbackControlRects;
  final bool avoidPlaybackControls;
  final SubtitlePositionController? positionController;
  final bool positionInteractive;
  final bool showPositionFrame;
  final bool presetPositionOverride;
  final void Function(int pointer)? onPositionPointerClaimed;

  const SubtitleDisplayLayer({
    super.key,
    required this.notifier,
    required this.alignment,
    required this.style,
    this.referenceHeight,
    this.fullPageSize,
    this.isGhostMode = false,
    this.isDragging = false,
    this.isGestureOnly = false,
    this.isVisualOnly = false,
    this.animateAlignment = false,
    this.alignmentDuration = const Duration(milliseconds: 300),
    this.alignmentCurve = Curves.easeOutCubic,
    this.itemGap = 6.0,
    this.playbackControlsVisibility,
    this.playbackControlsTop,
    this.playbackControlRects,
    this.avoidPlaybackControls = false,
    this.positionController,
    this.positionInteractive = false,
    this.showPositionFrame = false,
    this.presetPositionOverride = false,
    this.onPositionPointerClaimed,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SubtitleDisplayState>(
      valueListenable: notifier,
      builder: (context, state, _) {
        return SubtitleOverlayGroup(
          entries: state.entries,
          alignment: alignment,
          style: style,
          referenceHeight: referenceHeight,
          fullPageSize: fullPageSize,
          isGhostMode: isGhostMode,
          isDragging: isDragging,
          isGestureOnly: isGestureOnly,
          isVisualOnly: isVisualOnly,
          animateAlignment: animateAlignment,
          alignmentDuration: alignmentDuration,
          alignmentCurve: alignmentCurve,
          itemGap: itemGap,
          playbackControlsVisibility: playbackControlsVisibility,
          playbackControlsTop: playbackControlsTop,
          playbackControlRects: playbackControlRects,
          avoidPlaybackControls: avoidPlaybackControls,
          positionController: positionController,
          positionInteractive: positionInteractive,
          showPositionFrame: showPositionFrame,
          presetPositionOverride: presetPositionOverride,
          onPositionPointerClaimed: onPositionPointerClaimed,
        );
      },
    );
  }
}
