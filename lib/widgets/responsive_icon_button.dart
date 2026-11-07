import 'package:flutter/material.dart';

import '../services/app_haptics.dart';

class ResponsiveIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;
  final Color? color;

  const ResponsiveIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.onLongPress,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;

    // Calculate relative sizes based on screen width
    final double buttonSize = (screenWidth * 0.032).clamp(32.0, 40.0);
    final double iconSize = (buttonSize * 0.58).clamp(20.0, 24.0);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(buttonSize / 2),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: AppHaptics.wrap(onPressed, light: true),
          onLongPress: AppHaptics.wrap(onLongPress, light: true),
          child: Container(
            width: buttonSize,
            height: buttonSize,
            alignment: Alignment.center,
            child: Icon(icon, size: iconSize, color: color ?? Colors.white),
          ),
        ),
      ),
    );
  }
}

class ResponsiveActionButtons extends StatelessWidget {
  final List<Widget> buttons;
  final double? spacing;

  const ResponsiveActionButtons({
    super.key,
    required this.buttons,
    this.spacing,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    // Relative spacing
    final double resolvedSpacing =
        spacing ?? (screenWidth * 0.005).clamp(2.0, 8.0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < buttons.length; i++) ...[
          buttons[i],
          if (i < buttons.length - 1) SizedBox(width: resolvedSpacing),
        ],
        SizedBox(width: resolvedSpacing), // Padding at the end of AppBar
      ],
    );
  }
}
