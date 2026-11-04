import 'package:flutter/widgets.dart';

import '../models/media_library_view_mode.dart';
import 'media_library_layout_profile.dart';

/// Responsive defaults and slider ranges for the row-based browsing styles.
///
/// Unlike the card grid (which scales everything from the cell width), rows
/// and tables are sized in logical pixels: a row should look the same on a
/// phone and a monitor, only more of them fit. Defaults are chosen per size
/// class and orientation; a user override is stored per orientation.
class MediaLibraryViewDefaults {
  const MediaLibraryViewDefaults._();

  // ---------------------------------------------------------------- rows

  static const int minRowsColumns = 1;
  static const int maxRowsColumns = 6;
  static const double minRowsExtent = 44;
  static const double maxRowsExtent = 220;
  static const double minTitleSize = 10;
  static const double maxTitleSize = 24;
  static const int minTitleLines = 1;
  static const int maxTitleLines = 3;
  static const double minSpacing = 0;
  static const double maxSpacing = 40;
  static const double minOuterPadding = 0;
  static const double maxOuterPadding = 64;

  /// Phones read best as one column; wide panes split into two so a 1600px
  /// monitor does not stretch titles across the whole screen.
  static int rowsColumns(Size size) {
    final landscape = MediaLibraryLayoutDefaults.isLandscape(size);
    return switch (MediaLibraryLayoutDefaults.sizeClassFor(size)) {
      MediaLibrarySizeClass.phone => landscape ? 2 : 1,
      MediaLibrarySizeClass.compactTablet => landscape ? 2 : 1,
      MediaLibrarySizeClass.tablet => 2,
      MediaLibrarySizeClass.largeTablet => 2,
      MediaLibrarySizeClass.desktop => 2,
    };
  }

  /// Row height; the 16:9 thumbnail fills it minus [rowsThumbnailInset], so
  /// 104px gives a 160×90 cover on desktop and 84px a 128×72 one on phones.
  static double rowsExtent(Size size) =>
      switch (MediaLibraryLayoutDefaults.sizeClassFor(size)) {
        MediaLibrarySizeClass.phone => 84,
        MediaLibrarySizeClass.compactTablet => 92,
        MediaLibrarySizeClass.tablet => 96,
        MediaLibrarySizeClass.largeTablet => 100,
        MediaLibrarySizeClass.desktop => 104,
      };

  static double rowsTitleSize(Size size) =>
      switch (MediaLibraryLayoutDefaults.sizeClassFor(size)) {
        MediaLibrarySizeClass.phone => 14.5,
        MediaLibrarySizeClass.compactTablet => 14.5,
        MediaLibrarySizeClass.tablet => 14.5,
        MediaLibrarySizeClass.largeTablet => 14,
        MediaLibrarySizeClass.desktop => 14,
      };

  static const int rowsTitleLines = 2;

  static double rowsCrossSpacing(Size size) =>
      MediaLibraryLayoutDefaults.sizeClassFor(size) ==
          MediaLibrarySizeClass.phone
      ? 8
      : 20;

  /// Rows are flat, so the hover surface itself separates them; a small gap
  /// keeps neighbouring highlights from touching.
  static double rowsMainSpacing(Size size) => 2;

  static double rowsOuterPadding(Size size) =>
      switch (MediaLibraryLayoutDefaults.sizeClassFor(size)) {
        MediaLibrarySizeClass.phone => 4,
        MediaLibrarySizeClass.compactTablet => 8,
        MediaLibrarySizeClass.tablet => 10,
        MediaLibrarySizeClass.largeTablet => 12,
        MediaLibrarySizeClass.desktop => 12,
      };

  // --------------------------------------------------------------- table

  static const double minTableExtent = 28;
  static const double maxTableExtent = 96;

  /// Narrow panes render the table as two-line rows (title + metadata), so
  /// they need more height than a single-line desktop row.
  static double tableExtent(Size size) {
    final landscape = MediaLibraryLayoutDefaults.isLandscape(size);
    return switch (MediaLibraryLayoutDefaults.sizeClassFor(size)) {
      MediaLibrarySizeClass.phone => landscape ? 48 : 60,
      MediaLibrarySizeClass.compactTablet => landscape ? 44 : 56,
      MediaLibrarySizeClass.tablet => 42,
      MediaLibrarySizeClass.largeTablet => 40,
      MediaLibrarySizeClass.desktop => 40,
    };
  }

  static double tableTitleSize(Size size) =>
      switch (MediaLibraryLayoutDefaults.sizeClassFor(size)) {
        MediaLibrarySizeClass.phone => 14.5,
        MediaLibrarySizeClass.compactTablet => 14,
        MediaLibrarySizeClass.tablet => 13.5,
        MediaLibrarySizeClass.largeTablet => 13.5,
        MediaLibrarySizeClass.desktop => 13.5,
      };

  static double tableOuterPadding(Size size) =>
      switch (MediaLibraryLayoutDefaults.sizeClassFor(size)) {
        MediaLibrarySizeClass.phone => 0,
        MediaLibrarySizeClass.compactTablet => 4,
        MediaLibrarySizeClass.tablet => 8,
        MediaLibrarySizeClass.largeTablet => 12,
        MediaLibrarySizeClass.desktop => 16,
      };

  /// More columns as width allows; the title column always stays.
  static Set<MediaTableColumn> tableColumns(Size size) {
    final landscape = MediaLibraryLayoutDefaults.isLandscape(size);
    return switch (MediaLibraryLayoutDefaults.sizeClassFor(size)) {
      MediaLibrarySizeClass.phone => const {
        MediaTableColumn.duration,
        MediaTableColumn.progress,
      },
      MediaLibrarySizeClass.compactTablet => const {
        MediaTableColumn.duration,
        MediaTableColumn.progress,
      },
      MediaLibrarySizeClass.tablet ||
      MediaLibrarySizeClass.largeTablet => landscape
          ? const {
              MediaTableColumn.duration,
              MediaTableColumn.progress,
              MediaTableColumn.subtitles,
              MediaTableColumn.updated,
            }
          : const {MediaTableColumn.duration, MediaTableColumn.progress},
      MediaLibrarySizeClass.desktop => const {
        MediaTableColumn.type,
        MediaTableColumn.duration,
        MediaTableColumn.progress,
        MediaTableColumn.subtitles,
        MediaTableColumn.updated,
      },
    };
  }

  /// Below this cell width a table row collapses to title + metadata line.
  static const double tableCompactBreakpoint = 560;

  // ----------------------------------------------------------- thumbnails

  /// Inset between the row's hover surface and its 16:9 thumbnail.
  static double rowsThumbnailInset(double rowExtent) =>
      (rowExtent * 0.07).clamp(4.0, 8.0);

  /// 16:9 thumbnail of a media row. Shared by the tile and the preloader so
  /// predecoded images match the painted size. The cap keeps narrow cells
  /// from handing the whole row to the cover.
  static Size rowsThumbnailSize(double rowExtent, double cellWidth) {
    final height = rowExtent - rowsThumbnailInset(rowExtent) * 2;
    final width = (height * 16 / 9).clamp(0.0, cellWidth * 0.42);
    return Size(width, width * 9 / 16);
  }

  /// Small 16:9 thumbnail in the table's title cell.
  static Size tableThumbnailSize(double rowExtent) {
    final height = (rowExtent - 14).clamp(16.0, 60.0);
    return Size(height * 16 / 9, height);
  }

  // ---------------------------------------------------------------- tree

  static const double treeSidebarWidth = 264;
  static const double minTreeSidebarWidth = 180;
  static const double maxTreeSidebarWidth = 440;

  /// Below this pane width the folder tree becomes a slide-in drawer.
  static const double treeDockMinWidth = 720;

  /// The tree pane never takes more than this share of the window.
  static const double treeMaxWidthFraction = 0.42;
}
