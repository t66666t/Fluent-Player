import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// A small floating affordance with a larger, transparent touch target.
/// Its alignment and size follow the reading viewport, including keyboard
/// resizes, narrow sidebars and short landscape windows.
class AiScrollToLatestButton extends StatelessWidget {
  const AiScrollToLatestButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final rail = constraints.maxWidth >= 160 && constraints.maxHeight >= 44
          ? 44.0
          : 0.0;
      final inset = math.min(4.0, constraints.maxHeight / 8);
      final target = math.min(
        44.0,
        math.max(
          0.0,
          math.min(constraints.maxWidth - rail, constraints.maxHeight - inset),
        ),
      );
      final diameter = math.min(30.0, target);
      return Padding(
        padding: EdgeInsets.only(right: rail, bottom: inset),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Material(
            type: MaterialType.transparency,
            child: DesktopButtonClickRegion(child: IconButton(
              key: const ValueKey('ai-scroll-to-latest'),
              onPressed: onPressed,
              tooltip: '回到最新',
              style: IconButton.styleFrom(
                foregroundColor: colors.onSurface.withValues(alpha: .9),
                padding: EdgeInsets.zero,
                fixedSize: Size.square(target),
                minimumSize: Size.square(target),
                maximumSize: Size.square(target),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: const CircleBorder(),
                visualDensity: VisualDensity.standard,
              ),
              icon: Ink(
                key: const ValueKey('ai-scroll-to-latest-surface'),
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.surfaceContainerHigh.withValues(alpha: .74),
                  border: Border.all(
                    color: colors.onSurface.withValues(alpha: .16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow.withValues(alpha: .14),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.arrow_downward_rounded,
                  size: math.min(18.0, diameter),
                ),
              ),
            )),
          ),
        ),
      );
    },
  );
}
