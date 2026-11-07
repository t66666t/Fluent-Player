import '../theme/app_settings_theme.dart';
import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Compact measurements for the subtitle-preset sidebar.
///
/// Phone landscape sidebars are often ~248–320px; default 48px icon buttons
/// and SwitchListTiles waste a full row and force titles into ellipses.
class SubtitlePresetChrome {
  const SubtitlePresetChrome({
    required this.width,
    required this.isPhone,
    required this.isNarrow,
    required this.pad,
    required this.rowHeight,
    required this.iconSize,
    required this.iconButton,
    required this.titleSize,
    required this.bodySize,
    required this.captionSize,
    required this.actionSize,
    required this.cardExtent,
    required this.columns,
  });

  factory SubtitlePresetChrome.of(BoxConstraints constraints) {
    final width = constraints.maxWidth;
    final isPhone = width < 360;
    final isNarrow = width < 330;
    final columns = (width / (isPhone ? 150 : 176)).floor().clamp(1, 6);
    return SubtitlePresetChrome(
      width: width,
      isPhone: isPhone,
      isNarrow: isNarrow,
      pad: isNarrow ? 6 : (isPhone ? 8 : 10),
      rowHeight: isPhone ? 26 : 30,
      iconSize: isPhone ? 15 : 16,
      iconButton: isPhone ? 26 : 28,
      titleSize: isPhone ? 13 : 14,
      bodySize: isPhone ? 11 : 12,
      captionSize: isPhone ? 9.5 : 10.5,
      actionSize: isPhone ? 11 : 12,
      cardExtent: (isPhone ? 92.0 : 104.0),
      columns: columns,
    );
  }

  final double width;
  final bool isPhone;
  final bool isNarrow;
  final double pad;
  final double rowHeight;
  final double iconSize;
  final double iconButton;
  final double titleSize;
  final double bodySize;
  final double captionSize;
  final double actionSize;
  final double cardExtent;
  final int columns;

  /// Hollow / filled mark instead of a Material switch.
  String get ghostLabel => isNarrow ? '幽灵' : '幽灵模式';
}

/// Dense icon control that does not inherit the 48px Material tap target.
class SubtitlePresetIconButton extends StatelessWidget {
  const SubtitlePresetIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.iconSize,
    this.onPressed,
    this.color = Colors.white70,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final double iconSize;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DesktopButtonClickRegion(
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, size: iconSize, color: color),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: Size(size, size),
          padding: EdgeInsets.zero,
          foregroundColor: color,
        ),
      ),
    );
  }
}

/// Text action that shrinks instead of ellipsizing in a narrow sidebar.
class SubtitlePresetTextAction extends StatelessWidget {
  const SubtitlePresetTextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    required this.fontSize,
    required this.height,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double fontSize;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      height: height,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: fontSize + 3,
                    color: enabled ? AppSettingsTheme.accent : Colors.white24,
                  ),
                  const SizedBox(width: 3),
                ],
                Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: fontSize,
                    height: 1.1,
                    color: enabled ? AppSettingsTheme.accent : Colors.white38,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact ghost-mode control: hollow circle off, filled circle on.
class SubtitleGhostModeToggle extends StatelessWidget {
  static const ValueKey<String> toggleKey = ValueKey(
    'subtitle-ghost-mode-toggle',
  );

  const SubtitleGhostModeToggle({
    super.key,
    required this.enabled,
    required this.onChanged,
    required this.label,
    required this.fontSize,
    required this.markSize,
    this.onHelp,
    this.helpIconSize = 14,
    this.helpButtonSize = 22,
  });

  final bool enabled;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onHelp;
  final String label;
  final double fontSize;
  final double markSize;
  final double helpIconSize;
  final double helpButtonSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          key: toggleKey,
          button: true,
          checked: enabled,
          label: '幽灵模式',
          child: InkWell(
            onTap: () => onChanged(!enabled),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CustomPaint(
                    size: Size.square(markSize),
                    painter: _GhostMarkPainter(enabled: enabled),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: fontSize,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (onHelp != null)
          SubtitlePresetIconButton(
            tooltip: '幽灵模式说明',
            icon: Icons.help_outline,
            size: helpButtonSize,
            iconSize: helpIconSize,
            onPressed: onHelp,
          ),
      ],
    );
  }
}

class _GhostMarkPainter extends CustomPainter {
  _GhostMarkPainter({required this.enabled});

  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.width * 0.08;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - inset * 2,
      size.height - inset * 2,
    );
    final stroke = Paint()
      ..color = enabled ? const Color(0xFF64FFDA) : Colors.white54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawOval(rect, stroke);
    if (enabled) {
      canvas.drawOval(
        rect.deflate(2.2),
        Paint()..color = const Color(0xFF64FFDA),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GhostMarkPainter oldDelegate) =>
      oldDelegate.enabled != enabled;
}
