import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../theme/app_tokens.dart';
import 'media_library_layout_profile.dart';
import 'media_library_view_defaults.dart';
import 'media_list_layout_metrics.dart';

/// Resolved geometry for the media-row branch of [MediaLibraryListTile].
///
/// Layout follows the familiar "video list" pattern (YouTube watch-later,
/// Bilibili favourites): a 16:9 cover filling the row height on the left,
/// a top-aligned text column on the right, and a quiet overflow button in the
/// top-right corner. Everything derives from the row extent so one slider
/// scales the whole row consistently.
class MediaRowTileMetrics {
  const MediaRowTileMetrics._({
    required this.rowHeight,
    required this.cellWidth,
    required this.inset,
    required this.gap,
    required this.radius,
    required this.thumbnailWidth,
    required this.thumbnailHeight,
    required this.thumbnailRadius,
    required this.iconExtent,
    required this.titleSize,
    required this.metadataSize,
    required this.textGap,
    required this.indexWidth,
    required this.indexFontSize,
    required this.trailingSize,
    required this.chipSize,
    required this.progressThickness,
    required this.badgeFontSize,
    required this.showMeta,
    required this.showProgress,
    required this.maxTitleLines,
    required this.layoutPlan,
  });

  final double rowHeight;
  final double cellWidth;

  /// Padding between the hover surface and its content.
  final double inset;

  /// Space between the cover and the text column.
  final double gap;

  /// Corner radius of the hover / selection surface.
  final double radius;
  final double thumbnailWidth;
  final double thumbnailHeight;
  final double thumbnailRadius;

  /// Square used instead of the cover when thumbnails are turned off.
  final double iconExtent;
  final double titleSize;
  final double metadataSize;
  final double textGap;
  final double indexWidth;
  final double indexFontSize;

  /// Selection circle size.
  final double trailingSize;

  /// Square hit target of each action-dock button.
  final double chipSize;
  final double progressThickness;
  final double badgeFontSize;
  final bool showMeta;
  final bool showProgress;
  final int maxTitleLines;
  final MediaRowTextLayoutPlan layoutPlan;

  static const double titleLineHeight = 1.3;
  static const double metaLineHeight = 1.3;

  static MediaRowTileMetrics resolve({
    required MediaListStyleSettings style,
    required double screenShortestSide,
    required double cellWidth,
    required double rowHeight,
    required double titleScaleFallback,
    required bool styleShowMeta,
    required bool styleShowProgress,
  }) {
    // Legacy proportional styles have no pixel extent; the painted row height
    // then stands in for it so old fixtures still render sensibly.
    final paintRow = math.max(
      1.0,
      math.min(style.rowExtent ?? rowHeight, rowHeight),
    );
    final titleSize =
        style.titleSize ??
        MediaListLayoutMetrics.forTile(
          screenShortestSide: screenShortestSide,
          cellWidth: cellWidth,
          rowHeight: rowHeight,
          titleSetting: titleScaleFallback,
        ).titleSize;
    final inset = MediaLibraryViewDefaults.rowsThumbnailInset(paintRow);
    final thumb = MediaLibraryViewDefaults.rowsThumbnailSize(
      paintRow,
      cellWidth,
    );
    final metadataSize = (titleSize * 0.82).clamp(9.0, 14.0);
    final textGap = (paintRow * 0.035).clamp(1.5, 5.0);
    final maxTitleLines = style.titleLines.clamp(1, 3);
    final available = math.max(0.0, paintRow - inset * 2);

    return MediaRowTileMetrics._(
      rowHeight: paintRow,
      cellWidth: cellWidth,
      inset: inset,
      gap: (cellWidth * 0.025).clamp(6.0, 14.0),
      radius: (paintRow * 0.1).clamp(6.0, 10.0),
      thumbnailWidth: thumb.width,
      thumbnailHeight: thumb.height,
      thumbnailRadius: (thumb.height * 0.09).clamp(3.0, 8.0),
      iconExtent: math.min(available, (titleSize * 2.9).clamp(24.0, 44.0)),
      titleSize: titleSize,
      metadataSize: metadataSize,
      textGap: textGap,
      indexWidth: (titleSize * 2).clamp(20.0, 34.0),
      indexFontSize: metadataSize,
      trailingSize: (paintRow * 0.26).clamp(16.0, 24.0),
      chipSize: (paintRow * 0.34).clamp(20.0, 32.0),
      progressThickness: (thumb.height * 0.035).clamp(2.0, 3.5),
      badgeFontSize: (thumb.height * 0.13).clamp(8.5, 11.5),
      showMeta: styleShowMeta,
      showProgress: styleShowProgress,
      maxTitleLines: maxTitleLines,
      layoutPlan: MediaRowTextLayoutPlan.fit(
        available: available,
        titleSize: titleSize,
        maxTitleLines: maxTitleLines,
        metadataSize: metadataSize,
        textGap: textGap,
        wantMeta: styleShowMeta,
        wantProgress: styleShowProgress,
      ),
    );
  }

  /// Keeps the painted thumbnail inside the row when selection chrome eats width.
  MediaRowTileMetrics clampThumbnailToRowWidth({
    required double rowWidth,
    required double trailingReserve,
    double minTextWidth = 36,
  }) {
    final maxWidth = math.max(
      1.0,
      rowWidth - inset * 2 - gap - trailingReserve - minTextWidth,
    );
    if (thumbnailWidth <= maxWidth) return this;
    return _copyWith(
      thumbnailWidth: maxWidth,
      thumbnailHeight: maxWidth * 9 / 16,
    );
  }

  MediaRowTileMetrics _copyWith({
    double? thumbnailWidth,
    double? thumbnailHeight,
  }) {
    return MediaRowTileMetrics._(
      rowHeight: rowHeight,
      cellWidth: cellWidth,
      inset: inset,
      gap: gap,
      radius: radius,
      thumbnailWidth: thumbnailWidth ?? this.thumbnailWidth,
      thumbnailHeight: thumbnailHeight ?? this.thumbnailHeight,
      thumbnailRadius: thumbnailRadius,
      iconExtent: iconExtent,
      titleSize: titleSize,
      metadataSize: metadataSize,
      textGap: textGap,
      indexWidth: indexWidth,
      indexFontSize: indexFontSize,
      trailingSize: trailingSize,
      chipSize: chipSize,
      progressThickness: progressThickness,
      badgeFontSize: badgeFontSize,
      showMeta: showMeta,
      showProgress: showProgress,
      maxTitleLines: maxTitleLines,
      layoutPlan: layoutPlan,
    );
  }
}

/// Decides which text lines fit the row without vertical overflow.
///
/// Degrades in the order a reader would least miss: the progress line first
/// merges into the metadata line, then the title loses lines, then the
/// metadata line disappears.
class MediaRowTextLayoutPlan {
  const MediaRowTextLayoutPlan({
    required this.titleLines,
    required this.showMetaLine,
    required this.showProgressLine,
    required this.progressInMetaLine,
  });

  final int titleLines;
  final bool showMetaLine;

  /// Watch progress on its own third line.
  final bool showProgressLine;

  /// Watch progress appended to the metadata line instead.
  final bool progressInMetaLine;

  static MediaRowTextLayoutPlan fit({
    required double available,
    required double titleSize,
    required int maxTitleLines,
    required double metadataSize,
    required double textGap,
    required bool wantMeta,
    required bool wantProgress,
  }) {
    final titleLine = titleSize * MediaRowTileMetrics.titleLineHeight;
    final metaLine =
        textGap + metadataSize * MediaRowTileMetrics.metaLineHeight;
    double need(int lines, int extraLines) =>
        titleLine * lines + metaLine * extraLines;

    final wantsAnyMeta = wantMeta || wantProgress;
    if (!wantsAnyMeta) {
      var lines = maxTitleLines;
      while (lines > 1 && need(lines, 0) > available) {
        lines--;
      }
      return MediaRowTextLayoutPlan(
        titleLines: lines,
        showMetaLine: false,
        showProgressLine: false,
        progressInMetaLine: false,
      );
    }

    // Both lines wanted: try them separately before merging.
    if (wantMeta && wantProgress && need(maxTitleLines, 2) <= available) {
      return MediaRowTextLayoutPlan(
        titleLines: maxTitleLines,
        showMetaLine: true,
        showProgressLine: true,
        progressInMetaLine: false,
      );
    }
    for (var lines = maxTitleLines; lines >= 1; lines--) {
      if (need(lines, 1) <= available) {
        return MediaRowTextLayoutPlan(
          titleLines: lines,
          showMetaLine: true,
          showProgressLine: false,
          progressInMetaLine: wantProgress,
        );
      }
    }
    var lines = maxTitleLines;
    while (lines > 1 && need(lines, 0) > available) {
      lines--;
    }
    return MediaRowTextLayoutPlan(
      titleLines: lines,
      showMetaLine: false,
      showProgressLine: false,
      progressInMetaLine: false,
    );
  }
}

/// Watch-state copy shared by rows and the details table.
String mediaRowProgressLabel(int positionMs, int durationMs) {
  if (durationMs <= 0 || positionMs <= 0) return '未观看';
  final ratio = (positionMs / durationMs).clamp(0.0, 1.0);
  if (ratio >= 0.97) return '已看完';
  final percent = (ratio * 100).round().clamp(1, 99);
  return '已看 $percent%';
}

/// Whether [positionMs] counts as "started but not finished".
bool mediaRowIsInProgress(int positionMs, int durationMs) =>
    durationMs > 0 && positionMs > 0 && positionMs < durationMs * 0.97;

/// Duration / item-count badge on the cover's bottom-right corner.
class MediaRowThumbnailBadge extends StatelessWidget {
  const MediaRowThumbnailBadge({
    super.key,
    required this.label,
    required this.fontSize,
  });

  final String label;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(fontSize * 0.36),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: fontSize * 0.42,
          vertical: fontSize * 0.16,
        ),
        child: Text(
          label,
          maxLines: 1,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.94),
            fontSize: fontSize,
            height: 1.15,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// Hover / selection surface of a media row.
///
/// Flat by default: rows only light up under the pointer, like a file list.
/// [cardSurface] restores a filled card for users who prefer separated rows.
class MediaRowTileShell extends StatefulWidget {
  const MediaRowTileShell({
    super.key,
    required this.radius,
    required this.cardSurface,
    required this.isSelected,
    required this.child,
  });

  final double radius;
  final bool cardSurface;
  final bool isSelected;
  final Widget child;

  @override
  State<MediaRowTileShell> createState() => _MediaRowTileShellState();
}

class _MediaRowTileShellState extends State<MediaRowTileShell> {
  bool _hovered = false;

  static const _hoverFlat = Color(0x0DFFFFFF);
  static const _cardHover = Color(0xFF323232);

  @override
  Widget build(BuildContext context) {
    final motion = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 160);
    final Color fill;
    if (widget.isSelected) {
      fill = AppTokens.accent.withValues(alpha: 0.14);
    } else if (widget.cardSurface) {
      fill = _hovered ? _cardHover : AppTokens.bgCard;
    } else {
      fill = _hovered ? _hoverFlat : const Color(0x00FFFFFF);
    }
    final Color border;
    if (widget.isSelected) {
      border = AppTokens.accent.withValues(alpha: 0.55);
    } else if (widget.cardSurface) {
      border = AppTokens.lineSubtle;
    } else {
      border = const Color(0x00FFFFFF);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: motion,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        // Painted on top so the border never insets the row content.
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: widget.child,
      ),
    );
  }
}

/// Bottom-edge watch progress drawn over a cover.
class MediaRowCoverProgress extends StatelessWidget {
  const MediaRowCoverProgress({
    super.key,
    required this.fraction,
    required this.thickness,
  });

  final double fraction;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        height: thickness,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0x73000000)),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: fraction.clamp(0.0, 1.0),
              child: const ColoredBox(color: AppTokens.accent),
            ),
          ],
        ),
      ),
    );
  }
}

String mediaRowFolderBadgeLabel(VideoCollection collection) {
  return '${collection.childrenIds.length} 项';
}

String mediaRowVideoBadgeLabel(VideoItem video) {
  return formatMediaDuration(video.durationMs);
}

/// Type and duration, e.g. "视频 · 3:59".
String mediaRowMetaLineForVideo(VideoItem video, int durationMs) {
  final type = video.type == MediaType.audio ? '音频' : '视频';
  return '$type · ${formatMediaDuration(durationMs)}';
}

/// Clock-style duration; hours only when needed.
String formatMediaDuration(int durationMs) {
  if (durationMs <= 0) return '--:--';
  final totalSeconds = durationMs ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Whether any subtitle source is attached to [video].
bool mediaVideoHasSubtitles(VideoItem video) {
  bool nonEmpty(String? path) => path != null && path.trim().isNotEmpty;
  if (nonEmpty(video.subtitlePath) || nonEmpty(video.secondarySubtitlePath)) {
    return true;
  }
  if (video.localSubtitles != null && video.localSubtitles!.isNotEmpty) {
    return true;
  }
  return video.localSubtitleGroups.isNotEmpty ||
      video.managedSubtitleAssets.isNotEmpty ||
      video.downloadAssociatedSubtitles.isNotEmpty;
}
