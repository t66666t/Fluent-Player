import 'package:flutter/material.dart';
import 'player_sidebar_motion.dart';

/// Shared responsive measurements for the functional sidebars mounted by the
/// landscape video player. Values are intentionally derived from both axes:
/// landscape phones are height constrained, while desktop sidebars are width
/// constrained even when the host window is very large.
@immutable
class LandscapeSidebarLayout {
  const LandscapeSidebarLayout._({
    required this.isCompactHeight,
    required this.isNarrow,
    required this.horizontalPadding,
    required this.verticalPadding,
    required this.sectionGap,
    required this.headerHeight,
    required this.titleSize,
    required this.bodySize,
    required this.captionSize,
    required this.controlHeight,
    required this.iconSize,
  });

  factory LandscapeSidebarLayout.fromSize(Size viewport) {
    final compactHeight = viewport.height < 430;
    final shortHeight = viewport.height < 600;
    final narrow = viewport.width < 330;

    return LandscapeSidebarLayout._(
      isCompactHeight: compactHeight,
      isNarrow: narrow,
      horizontalPadding: narrow ? 8 : (viewport.width < 390 ? 10 : 14),
      verticalPadding: compactHeight ? 6 : (shortHeight ? 8 : 10),
      sectionGap: compactHeight ? 8 : (shortHeight ? 10 : 14),
      headerHeight: compactHeight ? 38 : (shortHeight ? 44 : 50),
      titleSize: compactHeight ? 14 : (shortHeight ? 15 : 16),
      bodySize: narrow || compactHeight ? 11 : 12,
      captionSize: narrow || compactHeight ? 9.5 : 10.5,
      controlHeight: compactHeight ? 30 : (shortHeight ? 34 : 38),
      iconSize: compactHeight ? 18 : 20,
    );
  }

  /// Width used by non-content sidebars (settings, tools and task panels).
  static double functionalWidthFor(Size screen) {
    final double desired;
    if (screen.width < 700) {
      desired = screen.width * 0.46;
    } else if (screen.width < 1000) {
      desired = screen.width * 0.38;
    } else if (screen.width < 1440) {
      desired = screen.width * 0.32;
    } else {
      desired = screen.width * 0.25;
    }

    final heightCap = screen.height < 430
        ? 310.0
        : screen.height < 600
        ? 350.0
        : screen.height < 850
        ? 410.0
        : 460.0;
    final playerPreservingCap = screen.width * 0.48;
    return desired
        .clamp(248.0, heightCap)
        .clamp(0.0, playerPreservingCap)
        .toDouble();
  }

  final bool isCompactHeight;
  final bool isNarrow;
  final double horizontalPadding;
  final double verticalPadding;
  final double sectionGap;
  final double headerHeight;
  final double titleSize;
  final double bodySize;
  final double captionSize;
  final double controlHeight;
  final double iconSize;
}

/// Applies compact Material defaults only inside a landscape functional
/// sidebar. Explicit feature state and callbacks remain untouched.
class LandscapeSidebarTheme extends StatelessWidget {
  const LandscapeSidebarTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenSize = MediaQuery.sizeOf(context);
        final size = Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : screenSize.width,
          constraints.hasBoundedHeight
              ? constraints.maxHeight
              : screenSize.height,
        );
        final layout = LandscapeSidebarLayout.fromSize(size);
        final base = Theme.of(context);
        final feedback = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : PlayerSidebarMotion.feedbackDuration;
        final expansion = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : PlayerSidebarMotion.controlDuration;
        return Theme(
          data: base.copyWith(
            textButtonTheme: TextButtonThemeData(
              style: (base.textButtonTheme.style ?? const ButtonStyle())
                  .copyWith(animationDuration: feedback),
            ),
            outlinedButtonTheme: OutlinedButtonThemeData(
              style: (base.outlinedButtonTheme.style ?? const ButtonStyle())
                  .copyWith(animationDuration: feedback),
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: (base.elevatedButtonTheme.style ?? const ButtonStyle())
                  .copyWith(animationDuration: feedback),
            ),
            iconButtonTheme: IconButtonThemeData(
              style: (base.iconButtonTheme.style ?? const ButtonStyle())
                  .copyWith(animationDuration: feedback),
            ),
            expansionTileTheme: base.expansionTileTheme.copyWith(
              expansionAnimationStyle: AnimationStyle(
                duration: expansion,
                reverseDuration: expansion,
                curve: Curves.easeOutCubic,
              ),
            ),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: layout.isCompactHeight
                ? const VisualDensity(horizontal: -2, vertical: -3)
                : const VisualDensity(horizontal: -1, vertical: -2),
            listTileTheme: base.listTileTheme.copyWith(
              dense: true,
              minVerticalPadding: layout.isCompactHeight ? 2 : 4,
              contentPadding: EdgeInsets.symmetric(
                horizontal: layout.horizontalPadding,
              ),
              titleTextStyle: TextStyle(
                color: Colors.white70,
                fontSize: layout.bodySize,
              ),
              subtitleTextStyle: TextStyle(
                color: Colors.white38,
                fontSize: layout.captionSize,
                height: 1.25,
              ),
            ),
            inputDecorationTheme: base.inputDecorationTheme.copyWith(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: layout.horizontalPadding,
                vertical: layout.verticalPadding,
              ),
            ),
          ),
          child: child,
        );
      },
    );
  }
}
