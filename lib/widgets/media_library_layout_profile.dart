import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Size bucket used only to pick **defaults**. User overrides are stored by
/// orientation, not by device class, so a 10" tablet keeps one landscape
/// profile and one portrait profile.
enum MediaLibrarySizeClass {
  phone,
  compactTablet,
  tablet,
  largeTablet,
  desktop,
}

enum MediaLibraryOrientationSlot { portrait, landscape }

/// Callers still pass home vs collection, but both scopes persist and read
/// the same home card-style keys so every media-library page stays in sync.
enum MediaLibraryCardStyleScope { home, collection }

/// Card-grid style the UI actually renders.
class MediaCardStyleSettings {
  const MediaCardStyleSettings({
    required this.crossAxisCount,
    required this.titleScale,
    required this.heightScale,
    required this.crossSpacingScale,
    required this.mainSpacingScale,
    this.usesDefaultColumns = false,
    this.reserveTwoTitleLines = false,
  });

  final int crossAxisCount;
  final double titleScale;
  final double heightScale;
  final double crossSpacingScale;
  final double mainSpacingScale;
  final bool usesDefaultColumns;
  final bool reserveTwoTitleLines;

  double get aspectRatio => 1.0 / math.max(0.1, heightScale);
}

/// List-mode style the UI actually renders.
class MediaListStyleSettings {
  const MediaListStyleSettings({
    required this.crossAxisCount,
    required this.titleScale,
    required this.heightScale,
    required this.crossSpacingScale,
    required this.mainSpacingScale,
    required this.showThumbnail,
    required this.showIndex,
  });

  final int crossAxisCount;
  final double titleScale;
  final double heightScale;
  final double crossSpacingScale;
  final double mainSpacingScale;
  final bool showThumbnail;
  final bool showIndex;
}

class MediaLibraryWidthDistribution {
  const MediaLibraryWidthDistribution({
    required this.cellWidth,
    required this.crossSpacing,
    required this.outerPadding,
  });

  final double cellWidth;
  final double crossSpacing;
  final double outerPadding;
}

class MediaLibraryCardGridMetrics {
  const MediaLibraryCardGridMetrics({
    required this.crossAxisCount,
    required this.cellWidth,
    required this.cellHeight,
    required this.crossSpacing,
    required this.mainSpacing,
    required this.outerPadding,
    required this.aspectRatio,
    required this.titleScale,
  });

  final int crossAxisCount;
  final double cellWidth;
  final double cellHeight;
  final double crossSpacing;
  final double mainSpacing;
  final double outerPadding;
  final double aspectRatio;
  final double titleScale;

  /// Width / height of the cover on a normal media or folder card.
  static const double standardCoverAspectRatio = 16 / 9;

  double get topPadding => mainSpacing;

  /// Cell height when the cover uses [coverAspectRatio] (width / height).
  ///
  /// The title block stays the same pixel height as a 16:9 media card, so a
  /// square podcast cover only changes the picture, not the type or padding.
  double cellHeightForCoverAspect(double coverAspectRatio) {
    final info = math.max(
      0.0,
      cellHeight - cellWidth / standardCoverAspectRatio,
    );
    final cover = cellWidth / math.max(coverAspectRatio, 0.01);
    return cover + info;
  }
}

/// Vertical rhythm for 最近添加 and 继续学习.
///
/// Every step is a multiple of the active style's 纵向间距 (`row`, the same
/// pixel value as a card or list grid's `mainSpacing`). Horizontal insets use
/// the grid's outer padding so titles line up with the cards.
///
/// * [leading] — under the app bar, same as the folder grid's first-row inset.
/// * [attached] — a label to the content it introduces. The filter pill uses
///   the same step before the first title under it.
/// * [block] — peer groups inside one section.
/// * [section] — later peer regions (置顶 / 最近在看 / 之前未看完, history days, import batches).
class MediaLibraryFlowSpacing {
  const MediaLibraryFlowSpacing({required this.row, required this.outer});

  final double row;
  final double outer;

  double get leading => row;

  double get attached => row * 0.5;

  double get block => row * 1.5;

  double get section => row * 2;

  Widget? gap(double extent) {
    if (extent <= 0) return null;
    return SliverToBoxAdapter(child: SizedBox(height: extent));
  }

  void addGap(List<Widget> slivers, double extent) {
    final gap = this.gap(extent);
    if (gap != null) slivers.add(gap);
  }
}

/// Two-sided log map: the slider's midpoint is [pivot], so the comfortable
/// band can be tuned finely while min/max still remain reachable.
class LogMappedRange {
  const LogMappedRange({
    required this.min,
    required this.max,
    required this.pivot,
  });

  final double min;
  final double max;
  final double pivot;

  double toSlider(double value) {
    final v = value.clamp(min, max);
    if (v <= pivot) {
      return 0.5 * _logT(min, pivot, v);
    }
    return 0.5 + 0.5 * _logT(pivot, max, v);
  }

  double fromSlider(double t) {
    final x = t.clamp(0.0, 1.0);
    if (x <= 0.5) {
      return _logLerp(min, pivot, x * 2);
    }
    return _logLerp(pivot, max, (x - 0.5) * 2);
  }

  static double _logT(double a, double b, double v) {
    if ((b - a).abs() < 1e-9) return 1;
    final la = _log(a);
    final lb = _log(b);
    final lv = _log(v.clamp(math.min(a, b), math.max(a, b)));
    if ((lb - la).abs() < 1e-9) return 1;
    return ((lv - la) / (lb - la)).clamp(0.0, 1.0);
  }

  static double _logLerp(double a, double b, double t) {
    final x = t.clamp(0.0, 1.0);
    return _exp(_log(a) + (_log(b) - _log(a)) * x);
  }

  /// Spacing may be 0, so the log is shifted by a small epsilon.
  static double _log(double value) => math.log(value + _epsilon);

  static double _exp(double value) => math.max(0.0, math.exp(value) - _epsilon);

  static const double _epsilon = 0.0008;
}

/// Defaults and closed-form geometry for media-library grids.
class MediaLibraryLayoutDefaults {
  const MediaLibraryLayoutDefaults._();

  static const int minCrossAxisCount = 1;
  static const int maxCrossAxisCount = 20;

  static const double minTitleScale = 0.045;
  static const double maxTitleScale = 0.22;
  static const double defaultTitleScale = 0.104;
  static const double titleScaleReferenceWidth = 170.0;

  static const double minHeightScale = 0.70;
  static const double maxHeightScale = 2.40;
  static const double defaultHeightScale = 1.08;
  static const double proportionalCardWidth = 150;
  static const double proportionalCardTitleSize = 12.5;
  static const double proportionalCardTitleScale =
      proportionalCardTitleSize / proportionalCardWidth;
  static const double readableHeightScale = 1.08;

  /// Device/orientation presets. Pane width only sizes the chosen columns;
  /// opening a sidebar must not silently change their number.
  static int readableCardCrossAxisCount(
    Size size, {
    required bool mobile,
    required bool phone,
  }) {
    final landscape = isLandscape(size);
    if (phone) return landscape ? 6 : 3;
    if (mobile) return landscape ? 9 : 6;
    return landscape ? 12 : 8;
  }

  /// Two title lines plus the worst-case folder path + duration rows. Measure
  /// the active font and accessibility scale instead of guessing a height ratio.
  static double readableCardMinimumHeight({
    required double cardWidth,
    required double titleScale,
    TextScaler textScaler = TextScaler.noScaling,
    TextStyle textStyle = const TextStyle(),
  }) {
    // Measure one design card, including accessibility text scaling, before
    // applying the same width ratio used by MediaLibraryCardScale. Measuring
    // at each final pixel width introduces rounding and breaks proportionality.
    final titleSize = titleFontSize(proportionalCardWidth, titleScale);
    double height(double size, FontWeight weight, int lines) {
      final painter = TextPainter(
        text: TextSpan(
          text: List.filled(lines, '国Ag').join('\n'),
          style: textStyle.copyWith(fontSize: size, fontWeight: weight),
        ),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout();
      final result = painter.height;
      painter.dispose();
      return result;
    }

    final verticalPadding = (proportionalCardWidth * .035) * 2;
    final referenceHeight =
        proportionalCardWidth /
            MediaLibraryCardGridMetrics.standardCoverAspectRatio +
        verticalPadding +
        height(titleSize, FontWeight.w600, 2) +
        height(metaFontSize(titleSize), FontWeight.w400, 2) +
        6;
    return referenceHeight * cardWidth / proportionalCardWidth;
  }

  static const double minSpacingScale = 0.0;
  static const double maxSpacingScale = 0.45;
  static const double defaultSpacingScale = 0.08;

  /// List rows are short, so the unset spacing is tighter than the card grid.
  static const double defaultListSpacingScale = 0.03;

  static const LogMappedRange columnRange = LogMappedRange(
    min: 1,
    max: 20,
    pivot: 8,
  );
  // List grids are usually 1–4 columns, so the midpoint sits near the
  // comfortable band instead of the card-grid pivot of 8.
  static const LogMappedRange listColumnRange = LogMappedRange(
    min: 1,
    max: 20,
    pivot: 2,
  );
  static const LogMappedRange titleRange = LogMappedRange(
    min: minTitleScale,
    max: maxTitleScale,
    pivot: defaultTitleScale,
  );
  static const LogMappedRange heightRange = LogMappedRange(
    min: minHeightScale,
    max: maxHeightScale,
    pivot: defaultHeightScale,
  );
  static const LogMappedRange spacingRange = LogMappedRange(
    min: minSpacingScale,
    max: maxSpacingScale,
    pivot: defaultSpacingScale,
  );

  static MediaLibraryOrientationSlot slotFor(Size size) {
    return size.width + 1.0 >= size.height
        ? MediaLibraryOrientationSlot.landscape
        : MediaLibraryOrientationSlot.portrait;
  }

  static bool isLandscape(Size size) {
    return slotFor(size) == MediaLibraryOrientationSlot.landscape;
  }

  static MediaLibrarySizeClass sizeClassFor(Size size) {
    final shortest = size.shortestSide;
    final longest = size.longestSide;
    if (shortest < 600) return MediaLibrarySizeClass.phone;
    if (shortest < 800) return MediaLibrarySizeClass.compactTablet;
    if (shortest < 1024) return MediaLibrarySizeClass.tablet;
    if (longest >= 1600 || shortest >= 1100) {
      return MediaLibrarySizeClass.desktop;
    }
    return MediaLibrarySizeClass.largeTablet;
  }

  static int defaultCardCrossAxisCount(Size size) {
    final landscape = isLandscape(size);
    switch (sizeClassFor(size)) {
      case MediaLibrarySizeClass.phone:
        return landscape ? 6 : 3;
      case MediaLibrarySizeClass.compactTablet:
        return landscape ? 8 : 5;
      case MediaLibrarySizeClass.tablet:
        return landscape ? 10 : 6;
      case MediaLibrarySizeClass.largeTablet:
        return landscape ? 11 : 7;
      case MediaLibrarySizeClass.desktop:
        return landscape ? 12 : 8;
    }
  }

  static int defaultListCrossAxisCount(Size size) {
    final landscape = isLandscape(size);
    switch (sizeClassFor(size)) {
      case MediaLibrarySizeClass.phone:
        return landscape ? 2 : 1;
      case MediaLibrarySizeClass.compactTablet:
        return landscape ? 2 : 1;
      case MediaLibrarySizeClass.tablet:
        return landscape ? 3 : 2;
      case MediaLibrarySizeClass.largeTablet:
        return landscape ? 3 : 2;
      case MediaLibrarySizeClass.desktop:
        return landscape ? 4 : 2;
    }
  }

  /// Outer corner of a grid card. Does not change the cover image itself.
  static double cardCornerRadius(double cardWidth) {
    return (cardWidth * 0.045).clamp(4.0, 8.0);
  }

  static int clampColumns(int value) {
    return value.clamp(minCrossAxisCount, maxCrossAxisCount);
  }

  static double clampSpacing(double value) {
    return value.clamp(minSpacingScale, maxSpacingScale);
  }

  static double clampHeight(double value) {
    return value.clamp(minHeightScale, maxHeightScale);
  }

  /// Legacy pixel title sizes (e.g. 13.0) were relative to a 170px card.
  static double normalizeTitleScale(double value) {
    if (value <= 1.0) {
      return value.clamp(minTitleScale, maxTitleScale);
    }
    return (value / titleScaleReferenceWidth).clamp(
      minTitleScale,
      maxTitleScale,
    );
  }

  static double titleFontSize(double cardWidth, double titleSetting) {
    return (cardWidth * normalizeTitleScale(titleSetting)).clamp(2.0, 100.0);
  }

  static double metaFontSize(double titleFontSize) {
    return (titleFontSize * 0.82).clamp(2.0, 100.0);
  }

  /// Solve cell width from "spacing and padding are fractions of the cell".
  ///
  /// `n*w + (n-1)*s*w + 2*p*w = availableWidth`.
  static MediaLibraryWidthDistribution distributeWidth({
    required double availableWidth,
    required int columns,
    required double spacingScale,
    double? paddingScale,
  }) {
    final n = clampColumns(columns);
    final s = clampSpacing(spacingScale);
    final p = clampSpacing(paddingScale ?? spacingScale);
    final denom = n + math.max(0, n - 1) * s + 2 * p;
    final cellWidth = math.max(0.001, availableWidth / math.max(0.001, denom));
    return MediaLibraryWidthDistribution(
      cellWidth: cellWidth,
      crossSpacing: n == 1 ? 0.0 : cellWidth * s,
      outerPadding: cellWidth * p,
    );
  }

  static MediaLibraryCardGridMetrics cardGrid({
    required Size screenSize,
    required MediaCardStyleSettings style,
    TextScaler textScaler = TextScaler.noScaling,
    TextStyle textStyle = const TextStyle(),
  }) {
    final columns = clampColumns(style.crossAxisCount);
    final distribution = distributeWidth(
      availableWidth: screenSize.width,
      columns: columns,
      spacingScale: style.crossSpacingScale,
    );
    final heightScale = clampHeight(style.heightScale);
    final cellHeight = style.reserveTwoTitleLines
        ? readableCardMinimumHeight(
            cardWidth: distribution.cellWidth,
            titleScale: style.titleScale,
            textScaler: textScaler,
            textStyle: textStyle,
          )
        : distribution.cellWidth * heightScale;
    return MediaLibraryCardGridMetrics(
      crossAxisCount: columns,
      cellWidth: distribution.cellWidth,
      cellHeight: cellHeight,
      crossSpacing: distribution.crossSpacing,
      mainSpacing:
          distribution.cellWidth * clampSpacing(style.mainSpacingScale),
      outerPadding: distribution.outerPadding,
      aspectRatio: distribution.cellWidth / cellHeight,
      titleScale: normalizeTitleScale(style.titleScale),
    );
  }
}
