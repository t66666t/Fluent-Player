import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'video_action_caption.dart';
import 'video_action_rail_layout.dart';
import 'video_action_rail_motion.dart';
import 'desktop_button_click_region.dart';
import 'media_library_tooltip.dart';

/// A circle-only action with an inert caption. Only the toggle's surface fades.
class VideoActionRailButton extends StatelessWidget {
  const VideoActionRailButton({
    super.key,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.layout,
    required this.showLabel,
    this.color = AppTokens.text1,
    this.isToggle = false,
    this.isCollapsed = false,
    this.expansion,
  });

  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final VideoActionRailLayout layout;
  final bool showLabel;
  final Color color;
  final bool isToggle;
  final bool isCollapsed;
  final Animation<double>? expansion;

  @override
  Widget build(BuildContext context) {
    if (isToggle && expansion == null) {
      return VideoActionRailMotionBuilder(
        collapsed: isCollapsed,
        builder: (context, progress, _) => _buildButton(context, progress),
      );
    }
    return _buildButton(context, expansion);
  }

  Widget _buildButton(BuildContext context, Animation<double>? progress) {
    final identity = isToggle ? 'toggle' : label;
    final glyph = Icon(
      icon,
      size: 20,
      color: color,
      shadows: isToggle
          ? const [
              Shadow(
                color: Color(0x99000000),
                offset: Offset(0, 0.5),
                blurRadius: 1.5,
              ),
            ]
          : null,
    );
    // Keep the input widget and icon subtree stable throughout every frame.
    final touch = DesktopButtonClickRegion(
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        splashFactory: isToggle ? NoSplash.splashFactory : null,
        hoverColor: const Color(0x1AFFFFFF),
        splashColor: const Color(0x24FFFFFF),
        highlightColor: Colors.transparent,
        child: SizedBox(
          width: layout.buttonSize,
          height: layout.buttonSize,
          child: isToggle
              ? RotationTransition(
                  turns: progress!.drive(Tween<double>(begin: 0, end: 0.5)),
                  child: RepaintBoundary(child: glyph),
                )
              : glyph,
        ),
      ),
    );
    Widget surface(double value, Widget child) => Material(
      key: ValueKey('action-button-disc-$identity'),
      animationDuration: Duration.zero,
      color: const Color(0xFF4A4A48).withValues(alpha: 0.30 + 0.70 * value),
      shape: CircleBorder(
        side: BorderSide(
          color: const Color(
            0x38FFFFFF,
          ).withValues(alpha: (0x38 / 255) * (1 - 0.35 * (1 - value))),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    return SizedBox(
      key: ValueKey('action-button-cell-$identity'),
      width: layout.cellWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MediaLibraryTooltip(
            message: tooltip,
            waitDuration: const Duration(milliseconds: 400),
            child: isToggle
                ? AnimatedBuilder(
                    animation: progress!,
                    child: touch,
                    builder: (context, child) =>
                        surface(progress.value, child!),
                  )
                : surface(1, touch),
          ),
          if (showLabel) ...[
            SizedBox(height: layout.labelGap),
            ExcludeSemantics(
              child: AbsorbPointer(
                child: isToggle
                    ? _ToggleCaption(
                        progress: progress!,
                        fontSize: layout.labelFontSize,
                      )
                    : VideoActionCaption(
                        label: label,
                        fontSize: layout.labelFontSize,
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ToggleCaption extends StatelessWidget {
  const _ToggleCaption({required this.progress, required this.fontSize});

  final Animation<double> progress;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final closed = RepaintBoundary(
      child: VideoActionCaption(label: '展开', fontSize: fontSize),
    );
    final open = RepaintBoundary(
      child: VideoActionCaption(label: '收起', fontSize: fontSize),
    );
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final value = progress.value;
        if (value == 0) return closed;
        if (value == 1) return open;
        // Exchange the two names without stacking outgoing labels on retaps.
        // The first name fades out before the second becomes visible.
        return Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: 1 - Curves.easeInOut.transform((value * 2).clamp(0, 1)),
              child: closed,
            ),
            Opacity(
              opacity: Curves.easeInOut.transform((value * 2 - 1).clamp(0, 1)),
              child: open,
            ),
          ],
        );
      },
    );
  }
}
