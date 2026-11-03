import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Phones prefer two compact columns; larger screens use the available height.
/// The width budget keeps the actions from covering too much of the library.
class VideoActionRailLayout {
  const VideoActionRailLayout._({
    required this.columns,
    required this.buttonSize,
    required this.labelFontSize,
    required this.labelGap,
    required this.rowGap,
    required this.cellWidth,
    required this.cellHeight,
    required this.maxHeight,
    required this.actionCount,
  });

  static const double columnGap = 4;
  static const double labelHorizontalPadding = 3;
  static const double labelVerticalPadding = 0.5;
  static const double labelLineHeight = 1.2;

  final int columns;
  final double buttonSize;
  final double labelFontSize;
  final double labelGap;
  final double rowGap;
  final double cellWidth;
  final double cellHeight;
  final double maxHeight;
  final int actionCount;

  int get rows => (actionCount / columns).ceil();
  double get width => cellWidth * columns + columnGap * (columns - 1);
  double get listHeight => rows * (cellHeight + rowGap);
  double get expandedHeight => listHeight + cellHeight;
  bool get needsScroll => expandedHeight > maxHeight + 0.5;

  factory VideoActionRailLayout.resolve({
    required Size screenSize,
    required double availableWidth,
    required double availableHeight,
    required TextScaler textScaler,
    required bool showLabels,
    int actionCount = 8,
  }) {
    final height = math.max(0.0, availableHeight);
    // Keep touch controls comfortable on phones/tablets; wide desktop windows
    // can use the original, slightly smaller discs.
    final baseSize = screenSize.width >= 1100 ? 40.0 : 44.0;
    final twoColumnBudget = math.min(
      availableWidth,
      math.min(144.0, screenSize.width * 0.40),
    );

    VideoActionRailLayout make({int columns = 1, bool compact = false}) {
      final size = baseSize - (compact ? 4 : 0);
      final fontSize = compact ? 10.5 : 11.0;
      final gap = compact ? 2.0 : 3.0;
      final scaledFont = textScaler.scale(fontSize);
      // Some fallback fonts round line metrics up to a logical pixel. Reserve
      // that fraction before cells receive tight layout constraints.
      final captionHeight =
          (scaledFont * labelLineHeight).ceilToDouble() +
          labelVerticalPadding * 2;
      return VideoActionRailLayout._(
        columns: columns,
        buttonSize: size,
        labelFontSize: fontSize,
        labelGap: gap,
        rowGap: compact ? 4 : 6,
        cellWidth: showLabels
            ? math.max(size + 8, scaledFont * 4 + labelHorizontalPadding * 2)
            : size,
        cellHeight: size + (showLabels ? gap + captionHeight : 0),
        maxHeight: height,
        actionCount: actionCount,
      );
    }

    final single = make();
    final preferTwoColumns = screenSize.shortestSide < 600;
    if (!preferTwoColumns && !single.needsScroll) return single;

    final doubleColumn = make(columns: 2);
    if (doubleColumn.width <= twoColumnBudget && !doubleColumn.needsScroll) {
      return doubleColumn;
    }

    // Short split-screen windows get a small size reduction. Very large system
    // text stays in one column if two would cover too much horizontal space.
    final compactDouble = make(columns: 2, compact: true);
    if (compactDouble.width <= twoColumnBudget) return compactDouble;
    if (!single.needsScroll) return single;
    return make(compact: true);
  }
}
