import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'media_library_layout_profile.dart';

/// Shared proportional layout calculations for the media-library list view.
///
/// Screen size establishes the desired scale. The actual cell dimensions then
/// constrain that scale so dense multi-column layouts cannot overflow.
class MediaListLayoutMetrics {
  const MediaListLayoutMetrics._({
    required this.unit,
    required this.rowHeight,
    required this.cellWidth,
    required this.titleSize,
  });

  static const double referenceShortestSide = 390.0;
  static const double minHeightSetting = 0.001;
  static const double maxHeightSetting = 0.15;
  static const double minTitleSetting = 0.001;
  static const double maxTitleSetting = 0.065;
  static const double minSpacingSetting = 0.0;
  static const double maxSpacingSetting = 0.45;

  final double unit;
  final double rowHeight;
  final double cellWidth;
  final double titleSize;

  double get metadataSize => titleSize * 0.72;
  double get horizontalPadding => math.min(unit * 0.14, cellWidth * 0.04);
  double get verticalPadding => rowHeight * 0.08;
  double get informationGap => metadataSize * 0.32;
  double get thumbnailInset => math.min(unit * 0.09, cellWidth * 0.025);
  double get indexWidth => math.min(unit * 0.40, cellWidth * 0.12);
  double get indexFontSize => titleSize * 0.64;
  double get trailingSize => math.min(unit * 0.28, cellWidth * 0.08);
  double get trailingPadding => math.min(unit * 0.10, cellWidth * 0.03);
  double get visualShortSide => math.min(unit, rowHeight);
  double get radius => visualShortSide * 0.18;
  double get borderWidth => visualShortSide * 0.012;
  double get selectedBorderWidth => visualShortSide * 0.018;
  double get metadataIconSize => metadataSize * 0.96;
  double get metadataIconGap => metadataSize * 0.46;
  double get progressThickness => visualShortSide * 0.025;

  double thumbnailExtent(double cellWidth) {
    return math.min(unit * 0.68, cellWidth * 0.14);
  }

  factory MediaListLayoutMetrics.forTile({
    required double screenShortestSide,
    required double cellWidth,
    required double rowHeight,
    required double titleSetting,
  }) {
    final requestedUnit =
        referenceDesignUnit(titleSetting) * screenScale(screenShortestSide);
    final unit = math.max(
      0.001,
      math.min(requestedUnit, math.min(cellWidth, rowHeight / 0.53)),
    );

    return MediaListLayoutMetrics._(
      unit: unit,
      rowHeight: rowHeight,
      cellWidth: cellWidth,
      titleSize: unit * 0.23,
    );
  }

  static MediaListGridMetrics forGrid({
    required double screenShortestSide,
    required double availableWidth,
    required int crossAxisCount,
    required double heightSetting,
    required double titleSetting,
    required double mainSpacingSetting,
    required double crossSpacingSetting,
  }) {
    final columns = MediaLibraryLayoutDefaults.clampColumns(crossAxisCount);
    final scale = screenScale(screenShortestSide);
    final distribution = MediaLibraryLayoutDefaults.distributeWidth(
      availableWidth: availableWidth,
      columns: columns,
      spacingScale: crossSpacingSetting,
    );
    final desiredRowHeight =
        referenceRowHeight(titleSetting, heightSetting) * scale;

    return MediaListGridMetrics(
      rowHeight: math.max(
        0.001,
        math.min(desiredRowHeight, distribution.cellWidth),
      ),
      cellWidth: distribution.cellWidth,
      outerPadding: distribution.outerPadding,
      mainSpacing:
          distribution.cellWidth *
          MediaLibraryLayoutDefaults.clampSpacing(mainSpacingSetting),
      crossSpacing: distribution.crossSpacing,
    );
  }

  /// Geometry for a resolved row style. Pixel styles (rows/table) use their
  /// explicit extent and spacings; legacy proportional styles fall back to
  /// [forGrid] so old fixtures keep their measurements.
  static MediaListGridMetrics forStyle({
    required MediaListStyleSettings style,
    required double screenShortestSide,
    required double availableWidth,
  }) {
    final extent = style.rowExtent;
    if (extent == null) {
      return forGrid(
        screenShortestSide: screenShortestSide,
        availableWidth: availableWidth,
        crossAxisCount: style.crossAxisCount,
        heightSetting: style.heightScale,
        titleSetting: style.titleScale,
        mainSpacingSetting: style.mainSpacingScale,
        crossSpacingSetting: style.crossSpacingScale,
      );
    }
    final columns = style.isTable
        ? 1
        : MediaLibraryLayoutDefaults.clampColumns(style.crossAxisCount);
    final width = math.max(0.001, availableWidth);
    // Padding can never eat more than a quarter of the pane on each side.
    final padding = (style.outerPadding ?? 0).clamp(0.0, width / 4);
    final cross = columns == 1 ? 0.0 : (style.crossSpacing ?? 0);
    final cellWidth = math.max(
      0.001,
      (width - padding * 2 - cross * (columns - 1)) / columns,
    );
    return MediaListGridMetrics(
      rowHeight: math.max(1.0, extent),
      cellWidth: cellWidth,
      outerPadding: padding,
      mainSpacing: style.isTable ? 0 : (style.mainSpacing ?? 0),
      crossSpacing: cross,
    );
  }

  static double screenScale(double shortestSide) {
    return math.max(0.001, shortestSide / referenceShortestSide);
  }

  static double referenceRowHeight(double titleSetting, double heightSetting) {
    return referenceDesignUnit(titleSetting) * heightAdjustment(heightSetting);
  }

  static double referenceTitleSize(double setting) {
    final normalized = _normalize(setting, minTitleSetting, maxTitleSetting);
    return 4.0 + normalized * 14.0;
  }

  static double referenceDesignUnit(double titleSetting) {
    return referenceTitleSize(titleSetting) / 0.23;
  }

  static double heightAdjustment(double setting) {
    final clamped = setting.clamp(minHeightSetting, maxHeightSetting);
    if (clamped <= 0.10) {
      return 0.45 +
          ((clamped - minHeightSetting) / (0.10 - minHeightSetting)) * 0.55;
    }
    return 1.0 + ((clamped - 0.10) / (maxHeightSetting - 0.10)) * 0.60;
  }

  static double referenceMainSpacing(double setting) {
    return (setting / 0.04).clamp(0.0, 1.0) * 16.0;
  }

  static double referenceCrossSpacing(double setting) {
    return (setting / 0.05).clamp(0.0, 1.0) * 16.0;
  }

  static double gridSelectionIconSize(double cardWidth) => cardWidth * 0.17;

  static double gridSelectionHitPadding(double cardWidth) => cardWidth * 0.11;

  /// Title block padding scales with the card so portrait cells do not keep
  /// the 10×6 offsets that were designed for ~170px-wide landscape cards.
  static EdgeInsets cardGridContentPadding(double cardWidth) {
    return EdgeInsets.symmetric(
      horizontal: (cardWidth * 0.059).clamp(3.0, 10.0),
      vertical: (cardWidth * 0.035).clamp(2.0, 6.0),
    );
  }

  static double cardGridThumbnailIconSize(double extent) {
    return (extent * 0.42).clamp(10.0, 50.0);
  }

  static double _normalize(double value, double min, double max) {
    return ((value - min) / (max - min)).clamp(0.0, 1.0);
  }
}

class MediaListGridMetrics {
  const MediaListGridMetrics({
    required this.rowHeight,
    required this.cellWidth,
    required this.outerPadding,
    required this.mainSpacing,
    required this.crossSpacing,
  });

  final double rowHeight;
  final double cellWidth;
  final double outerPadding;
  final double mainSpacing;
  final double crossSpacing;

  /// The first row follows the same vertical rhythm as every subsequent row.
  double get topPadding => mainSpacing;
}

/// Resolves [MediaLibraryFlowSpacing] from whichever style is on screen.
MediaLibraryFlowSpacing mediaLibraryFlowSpacingFor({
  required Size screenSize,
  required bool useList,
  required MediaCardStyleSettings cardStyle,
  required MediaListStyleSettings listStyle,
}) {
  if (useList) {
    final metrics = MediaListLayoutMetrics.forStyle(
      style: listStyle,
      screenShortestSide: screenSize.shortestSide,
      availableWidth: screenSize.width,
    );
    // Tables have no gap between rows; section rhythm still needs one.
    final row = listStyle.isTable
        ? math.max(6.0, listStyle.rowExtent! * 0.2)
        : metrics.mainSpacing;
    return MediaLibraryFlowSpacing(row: row, outer: metrics.outerPadding);
  }
  final metrics = MediaLibraryLayoutDefaults.cardGrid(
    screenSize: screenSize,
    style: cardStyle,
  );
  return MediaLibraryFlowSpacing(
    row: metrics.mainSpacing,
    outer: metrics.outerPadding,
  );
}

/// Geometry shared by hit testing, box selection and drag selection.
class MediaLibraryGridGeometry {
  const MediaLibraryGridGeometry({
    required this.crossAxisCount,
    required this.itemWidth,
    required this.itemHeight,
    required this.horizontalSpacing,
    required this.verticalSpacing,
    required this.horizontalPadding,
    required this.topPadding,
  });

  final int crossAxisCount;
  final double itemWidth;
  final double itemHeight;
  final double horizontalSpacing;
  final double verticalSpacing;
  final double horizontalPadding;
  final double topPadding;

  Rect rectForIndex(int index) {
    final row = index ~/ crossAxisCount;
    final column = index % crossAxisCount;
    return Rect.fromLTWH(
      horizontalPadding + column * (itemWidth + horizontalSpacing),
      topPadding + row * (itemHeight + verticalSpacing),
      itemWidth,
      itemHeight,
    );
  }

  int? indexAt(Offset offset, int itemCount) {
    if (itemCount <= 0 ||
        offset.dx < horizontalPadding ||
        offset.dy < topPadding) {
      return null;
    }

    final relativeX = offset.dx - horizontalPadding;
    final relativeY = offset.dy - topPadding;
    final strideX = itemWidth + horizontalSpacing;
    final strideY = itemHeight + verticalSpacing;
    final column = (relativeX / strideX).floor();
    final row = (relativeY / strideY).floor();

    if (column < 0 || column >= crossAxisCount) return null;
    if (relativeX % strideX > itemWidth || relativeY % strideY > itemHeight) {
      return null;
    }

    final index = row * crossAxisCount + column;
    return index >= 0 && index < itemCount ? index : null;
  }

  /// Indices whose cell rect intersects [contentRect], in reading order.
  List<int> indicesOverlapping(Rect contentRect, int itemCount) {
    if (itemCount <= 0) return const <int>[];
    final strideX = itemWidth + horizontalSpacing;
    final strideY = itemHeight + verticalSpacing;
    if (strideX <= 0 || strideY <= 0) return const <int>[];

    var minRow = ((contentRect.top - topPadding) / strideY).floor();
    var maxRow = ((contentRect.bottom - topPadding) / strideY).floor();
    var minCol = ((contentRect.left - horizontalPadding) / strideX).floor();
    var maxCol = ((contentRect.right - horizontalPadding) / strideX).floor();
    if (minRow < 0) minRow = 0;
    if (minCol < 0) minCol = 0;
    if (maxCol >= crossAxisCount) maxCol = crossAxisCount - 1;
    // A pointer past the list used to leave maxRow unbounded. The loop then
    // walked every integer row up to that coordinate and the UI locked up
    // while every cell was tested.
    final lastRow = (itemCount - 1) ~/ crossAxisCount;
    if (maxRow > lastRow) maxRow = lastRow;
    if (minRow > maxRow || minCol > maxCol) return const <int>[];

    final indices = <int>[];
    for (var row = minRow; row <= maxRow; row++) {
      for (var col = minCol; col <= maxCol; col++) {
        final index = row * crossAxisCount + col;
        if (index < 0 || index >= itemCount) continue;
        if (rectForIndex(index).overlaps(contentRect)) {
          indices.add(index);
        }
      }
    }
    return indices;
  }

  /// Maps a content-space point onto a grid cell for album-style range drag.
  ///
  /// Gaps count as the neighboring cell; points outside the grid clamp to the
  /// nearest edge item so a finger can leave a card without dropping the range.
  int? indexForDragSelection(Offset offset, int itemCount) {
    if (itemCount <= 0) return null;
    final strideX = itemWidth + horizontalSpacing;
    final strideY = itemHeight + verticalSpacing;
    if (strideX <= 0 || strideY <= 0) return null;

    var column = ((offset.dx - horizontalPadding) / strideX).floor();
    var row = ((offset.dy - topPadding) / strideY).floor();
    column = column.clamp(0, crossAxisCount - 1);
    final lastRow = (itemCount - 1) ~/ crossAxisCount;
    row = row.clamp(0, lastRow);
    final index = row * crossAxisCount + column;
    if (index < 0) return 0;
    if (index >= itemCount) return itemCount - 1;
    return index;
  }
}
