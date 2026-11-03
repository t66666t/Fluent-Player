import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Decorative only: the player's existing overlay owns the resize gestures.
class PlayerSidebarResizeIndicator extends StatelessWidget {
  const PlayerSidebarResizeIndicator({
    super.key,
    required this.hovered,
    required this.resizing,
    required this.backgroundColor,
    this.alignment = Alignment.center,
  });

  final ValueListenable<bool> hovered;
  final bool resizing;
  final Color backgroundColor;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).height < 600;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 140);

    return IgnorePointer(
      child: ColoredBox(
        color: backgroundColor,
        child: Align(
          alignment: alignment,
          child: ValueListenableBuilder<bool>(
            valueListenable: hovered,
            builder: (context, isHovered, child) {
              final active = isHovered || resizing;
              return AnimatedContainer(
                duration: duration,
                curve: Curves.easeOutCubic,
                width: 3,
                height: compact ? (active ? 38 : 32) : (active ? 48 : 40),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: Colors.white.withValues(
                    alpha: compact
                        ? (active ? 0.59 : 0.38)
                        : (active ? 0.53 : 0.31),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
