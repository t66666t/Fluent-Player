import 'dart:math' as math;
import 'dart:ui';

/// How the music player arranges the selection workspace in the space it
/// actually has. Device names and orientation alone do not pick a variant.
enum MusicLyricWorkspaceVariant {
  vertical,
  standardColumns,
  compactColumns,
  degraded,
}

class MusicLyricColumnPlan {
  final MusicLyricWorkspaceVariant variant;
  final double? leftWidth;

  const MusicLyricColumnPlan(this.variant, [this.leftWidth]);

  bool get degraded => variant == MusicLyricWorkspaceVariant.degraded;
  bool get compactColumns =>
      variant == MusicLyricWorkspaceVariant.compactColumns;
}

/// Minimum readable selection body. Below this the page leaves the two-column
/// player and uses the compact track bar instead of squeezing the text.
const double musicLyricSelectionMinBodyHeight = 160;
const double musicLyricSelectionMinColumnWidth = 320;

/// Selects a column plan for an active selection session. [gap] is the space
/// between the two panels, already excluding outer margins.
MusicLyricColumnPlan planMusicLyricSelectionColumns({
  required bool vertical,
  required double width,
  required double height,
  required double gap,
  required double toolsTop,
  double horizontalMargin = 16,
}) {
  if (vertical) {
    return const MusicLyricColumnPlan(MusicLyricWorkspaceVariant.vertical);
  }
  final available = math.max(0.0, width - gap - horizontalMargin * 2);
  final bodyHeight = height - toolsTop;
  final shortSide = math.min(width, height);
  if (shortSide < 600) {
    if (available < 220 + musicLyricSelectionMinColumnWidth) {
      return const MusicLyricColumnPlan(MusicLyricWorkspaceVariant.degraded);
    }
    final left = (available * 0.32).clamp(220.0, 320.0);
    final right = available - left;
    if (right < musicLyricSelectionMinColumnWidth ||
        bodyHeight < musicLyricSelectionMinBodyHeight) {
      return const MusicLyricColumnPlan(MusicLyricWorkspaceVariant.degraded);
    }
    return MusicLyricColumnPlan(
      MusicLyricWorkspaceVariant.compactColumns,
      left,
    );
  }
  final right = available * 0.5;
  if (right < musicLyricSelectionMinColumnWidth ||
      bodyHeight < musicLyricSelectionMinBodyHeight) {
    return const MusicLyricColumnPlan(MusicLyricWorkspaceVariant.degraded);
  }
  return const MusicLyricColumnPlan(MusicLyricWorkspaceVariant.standardColumns);
}

enum MusicLyricSelectionChromeTier { wide, stacked, menu }

/// Width tiers for the selection toolbar. [textScale] participates so a
/// 200% system font can drop a tier before the labels overflow.
MusicLyricSelectionChromeTier musicLyricSelectionChromeTier({
  required double innerWidth,
  required double textScale,
}) {
  final scale = textScale <= 0 ? 1.0 : textScale;
  final comparable = innerWidth / scale;
  if (comparable >= 420) return MusicLyricSelectionChromeTier.wide;
  if (comparable >= 300) return MusicLyricSelectionChromeTier.stacked;
  return MusicLyricSelectionChromeTier.menu;
}

/// Panel metrics that follow the selection visual spec.
class MusicLyricSelectionMetrics {
  final double radius;
  final double margin;
  final double titleSize;
  final double toolbarHeight;
  final double textHorizontalPadding;
  final double textVerticalPadding;
  final double primarySize;
  final double secondarySize;
  final bool compact;

  const MusicLyricSelectionMetrics({
    required this.radius,
    required this.margin,
    required this.titleSize,
    required this.toolbarHeight,
    required this.textHorizontalPadding,
    required this.textVerticalPadding,
    required this.primarySize,
    required this.secondarySize,
    required this.compact,
  });

  static MusicLyricSelectionMetrics forConstraints(Size size) {
    final compact = size.shortestSide < 600 || size.height < 420;
    if (compact) {
      return const MusicLyricSelectionMetrics(
        radius: 18,
        margin: 10,
        titleSize: 16,
        toolbarHeight: 44,
        textHorizontalPadding: 6,
        textVerticalPadding: 6,
        primarySize: 16,
        secondarySize: 14,
        compact: true,
      );
    }
    return const MusicLyricSelectionMetrics(
      radius: 22,
      margin: 16,
      titleSize: 17,
      toolbarHeight: 48,
      textHorizontalPadding: 20,
      textVerticalPadding: 16,
      primarySize: 18,
      secondarySize: 16,
      compact: false,
    );
  }
}
