import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_library_view_mode.dart';
import '../models/video_item.dart';
import '../services/app_haptics.dart';
import '../services/media_playback_service.dart';
import '../services/settings_service.dart';
import '../theme/app_tokens.dart';
import 'cached_thumbnail_widget.dart';
import 'folder_placeholder_cover.dart';
import 'media_library_action_dock.dart';
import 'media_library_activity_menu.dart';
import 'media_library_folder_sync_button.dart';
import 'media_library_gestures.dart';
import 'media_library_layout_profile.dart';
import 'media_library_list_tile.dart';
import 'media_library_list_tile_rows.dart';
import 'media_library_locate_button.dart';
import 'media_library_view_defaults.dart';

/// Column geometry shared by [MediaLibraryTableRow] and the table header so
/// every cell lines up with its label.
///
/// Modelled on Finder / Explorer details view: a flexible name column, fixed
/// data columns to its right, and a trailing slot for the row actions. When
/// the pane is too narrow the least important columns drop out instead of
/// squeezing every column into unreadable slivers.
class MediaTableColumnLayout {
  MediaTableColumnLayout._({
    required this.contentWidth,
    required this.style,
    required this.isCompact,
    required this.horizontalPadding,
    required this.leadingWidth,
    required this.indexWidth,
    required this.thumbnailSize,
    required this.titleWidth,
    required this.trailingWidth,
    required this.columnWidths,
    required this.bodyFontSize,
    required this.metaFontSize,
    required this.chipSize,
  });

  /// Width of one row (the grid cell), outer padding already removed.
  final double contentWidth;
  final MediaListStyleSettings style;

  /// Narrow panes render each row as title + metadata instead of columns.
  final bool isCompact;

  /// Padding inside the row before the first and after the last cell.
  final double horizontalPadding;

  /// Index + thumbnail/icon + gap before the title text.
  final double leadingWidth;
  final double indexWidth;
  final Size thumbnailSize;
  final double titleWidth;

  /// Reserved for the overflow / locate buttons or the selection circle.
  final double trailingWidth;
  final Map<MediaTableColumn, double> columnWidths;
  final double bodyFontSize;
  final double metaFontSize;
  final double chipSize;

  static const String titleColumnLabel = '名称';

  /// Space before every data column.
  static const double columnGap = 16;

  /// Gap between the thumbnail and the title text.
  static const double leadingGap = 10;

  static const double _minTitleWidth = 180;

  /// Dropped first when space runs out.
  static const _dropOrder = [
    MediaTableColumn.location,
    MediaTableColumn.type,
    MediaTableColumn.subtitles,
    MediaTableColumn.updated,
    MediaTableColumn.progress,
    MediaTableColumn.duration,
  ];

  Iterable<MediaTableColumn> get visibleColumns =>
      MediaTableColumn.values.where(columnWidths.containsKey);

  double widthFor(MediaTableColumn column) => columnWidths[column] ?? 0;

  /// [width] is the row (cell) width. The header passes the full pane width
  /// minus the grid's outer padding so both sides agree.
  factory MediaTableColumnLayout.forWidth({
    required double width,
    required MediaListStyleSettings style,
  }) {
    final rowExtent = style.rowExtent ?? 40;
    final contentWidth = math.max(0.0, width);
    final isCompact =
        contentWidth < MediaLibraryViewDefaults.tableCompactBreakpoint;
    final bodyFontSize = (style.titleSize ?? 13.5).clamp(10.0, 20.0);
    final metaFontSize = (bodyFontSize * 0.86).clamp(9.0, 15.0);
    final horizontalPadding = isCompact ? 12.0 : 10.0;
    final chipSize = (rowExtent * 0.72).clamp(20.0, 30.0);

    final indexWidth = style.showIndex
        ? (bodyFontSize * 2.1).clamp(22.0, 36.0)
        : 0.0;
    final Size thumbnailSize;
    if (style.showThumbnail) {
      final height = isCompact
          ? (rowExtent - 16).clamp(16.0, 64.0)
          : MediaLibraryViewDefaults.tableThumbnailSize(rowExtent).height;
      thumbnailSize = Size(height * 16 / 9, height);
    } else {
      final icon = (rowExtent * 0.5).clamp(16.0, 28.0);
      thumbnailSize = Size(icon, icon);
    }
    final leadingWidth = indexWidth + thumbnailSize.width + leadingGap;
    // Room for "more" plus one extra action (locate or sync).
    final trailingWidth = chipSize * 2;

    final columnWidths = <MediaTableColumn, double>{};
    if (!isCompact) {
      for (final column in MediaTableColumn.values) {
        if (style.tableColumns.contains(column)) {
          columnWidths[column] = _columnWidth(column, bodyFontSize);
        }
      }
      double fixed() =>
          columnWidths.values.fold<double>(0, (sum, w) => sum + w + columnGap);
      final budget =
          contentWidth - horizontalPadding * 2 - leadingWidth - trailingWidth;
      for (final column in _dropOrder) {
        if (budget - fixed() >= _minTitleWidth) break;
        columnWidths.remove(column);
      }
    }
    final usedByColumns = columnWidths.values.fold<double>(
      0,
      (sum, w) => sum + w + columnGap,
    );
    final titleWidth = math.max(
      24.0,
      contentWidth -
          horizontalPadding * 2 -
          leadingWidth -
          trailingWidth -
          usedByColumns,
    );

    return MediaTableColumnLayout._(
      contentWidth: contentWidth,
      style: style,
      isCompact: isCompact,
      horizontalPadding: horizontalPadding,
      leadingWidth: leadingWidth,
      indexWidth: indexWidth,
      thumbnailSize: thumbnailSize,
      titleWidth: titleWidth,
      trailingWidth: trailingWidth,
      columnWidths: columnWidths,
      bodyFontSize: bodyFontSize,
      metaFontSize: metaFontSize,
      chipSize: chipSize,
    );
  }

  /// Widths sized for their content at the body font size.
  static double _columnWidth(MediaTableColumn column, double fontSize) {
    final scale = (fontSize / 13.5).clamp(0.85, 1.4);
    return switch (column) {
          MediaTableColumn.type => 52.0,
          MediaTableColumn.duration => 64.0,
          MediaTableColumn.progress => 128.0,
          MediaTableColumn.subtitles => 44.0,
          MediaTableColumn.updated => 92.0,
          MediaTableColumn.location => 180.0,
        } *
        scale;
  }

  static Alignment alignmentFor(MediaTableColumn column) => switch (column) {
    MediaTableColumn.duration => Alignment.centerRight,
    MediaTableColumn.subtitles => Alignment.center,
    _ => Alignment.centerLeft,
  };
}

/// One row of the details table: wide column layout or compact two-line row.
class MediaLibraryTableRow extends StatefulWidget {
  const MediaLibraryTableRow({
    super.key,
    required this.tile,
    required this.style,
    required this.openMenu,
  });

  final MediaLibraryListTile tile;
  final MediaListStyleSettings style;
  final VoidCallback openMenu;

  @override
  State<MediaLibraryTableRow> createState() => _MediaLibraryTableRowState();
}

class _MediaLibraryTableRowState extends State<MediaLibraryTableRow> {
  bool _hovered = false;

  MediaLibraryListTile get tile => widget.tile;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowHeight = constraints.maxHeight;
        final layout = MediaTableColumnLayout.forWidth(
          width: constraints.maxWidth,
          style: widget.style,
        );
        final motion = MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 140);

        final Color fill;
        if (tile.isSelected) {
          fill = AppTokens.accent.withValues(alpha: 0.16);
        } else if (_hovered) {
          fill = const Color(0x0FFFFFFF);
        } else if (widget.style.striped && tile.index.isOdd) {
          fill = const Color(0x06FFFFFF);
        } else {
          fill = const Color(0x00FFFFFF);
        }

        final body = layout.isCompact
            ? _CompactRowBody(tile: tile, layout: layout, rowHeight: rowHeight)
            : _WideRowBody(tile: tile, layout: layout, rowHeight: rowHeight);

        return MediaLibrarySelectionLongPress(
          onLongPress: tile.isSelectionMode ? null : tile.onLongPress,
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Hairline divider, inset like Finder so it never touches
                // the pane edge.
                Positioned(
                  left: layout.horizontalPadding,
                  right: layout.horizontalPadding,
                  bottom: 0,
                  height: 1,
                  child: const ColoredBox(color: AppTokens.lineSubtle),
                ),
                AnimatedContainer(
                  duration: motion,
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    color: fill,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      unawaited(AppHaptics.cardTap(SettingsService()));
                      tile.onTap();
                    },
                    onSecondaryTap: widget.openMenu,
                    hoverColor: Colors.transparent,
                    highlightColor: Colors.white.withValues(alpha: 0.03),
                    splashColor: AppTokens.accent.withValues(alpha: 0.10),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: layout.horizontalPadding,
                      ),
                      child: Row(
                        children: [
                          Expanded(child: body),
                          _Trailing(tile: tile, layout: layout),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _WideRowBody extends StatelessWidget {
  const _WideRowBody({
    required this.tile,
    required this.layout,
    required this.rowHeight,
  });

  final MediaLibraryListTile tile;
  final MediaTableColumnLayout layout;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Leading(tile: tile, layout: layout, rowHeight: rowHeight),
        Expanded(
          child: _TitleText(tile: tile, layout: layout, maxLines: 1),
        ),
        for (final column in layout.visibleColumns)
          Padding(
            padding: const EdgeInsets.only(
              left: MediaTableColumnLayout.columnGap,
            ),
            child: SizedBox(
              width: layout.widthFor(column),
              child: Align(
                alignment: MediaTableColumnLayout.alignmentFor(column),
                child: _Cell(tile: tile, column: column, layout: layout),
              ),
            ),
          ),
      ],
    );
  }
}

class _CompactRowBody extends StatelessWidget {
  const _CompactRowBody({
    required this.tile,
    required this.layout,
    required this.rowHeight,
  });

  final MediaLibraryListTile tile;
  final MediaTableColumnLayout layout;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final titleLine = layout.bodyFontSize * 1.3;
    final metaLine = layout.metaFontSize * 1.3;
    final twoLines = rowHeight - 8 >= titleLine + metaLine + 2;
    final trailingLabel = tile.isCollection
        ? '${tile.collection!.childrenIds.length} 项'
        : formatMediaDuration(tile.video!.durationMs);

    return Row(
      children: [
        _Leading(tile: tile, layout: layout, rowHeight: rowHeight),
        Expanded(
          child: twoLines
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TitleText(tile: tile, layout: layout, maxLines: 1),
                    const SizedBox(height: 2),
                    _CompactMeta(tile: tile, layout: layout),
                  ],
                )
              : _TitleText(tile: tile, layout: layout, maxLines: 1),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Text(
            trailingLabel,
            maxLines: 1,
            style: TextStyle(
              color: AppTokens.text2,
              fontSize: layout.metaFontSize,
              height: 1.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// Index, thumbnail (or type icon) and the gap before the title.
class _Leading extends StatelessWidget {
  const _Leading({
    required this.tile,
    required this.layout,
    required this.rowHeight,
  });

  final MediaLibraryListTile tile;
  final MediaTableColumnLayout layout;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final maxHeight = math.max(8.0, rowHeight - 6);
    final size = layout.thumbnailSize;
    final height = math.min(size.height, maxHeight);
    final width = layout.style.showThumbnail ? height * 16 / 9 : size.width;
    return SizedBox(
      width: layout.leadingWidth,
      child: Row(
        children: [
          if (layout.indexWidth > 0)
            SizedBox(
              width: layout.indexWidth,
              child: Text(
                '${tile.index + 1}'.padLeft(2, '0'),
                style: TextStyle(
                  color: AppTokens.text3,
                  fontSize: layout.metaFontSize,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          SizedBox(
            width: width,
            height: height,
            child: layout.style.showThumbnail
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(
                      (height * 0.14).clamp(3.0, 6.0),
                    ),
                    child: _Thumbnail(tile: tile, iconSize: height * 0.5),
                  )
                : _TypeIcon(tile: tile, size: width),
          ),
        ],
      ),
    );
  }
}

class _TypeIcon extends StatelessWidget {
  const _TypeIcon({required this.tile, required this.size});

  final MediaLibraryListTile tile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    if (tile.isCollection) {
      icon = Icons.folder_rounded;
      color = AppTokens.accent;
    } else if (tile.video!.type == MediaType.audio) {
      icon = Icons.music_note_rounded;
      color = AppTokens.text2;
    } else {
      icon = Icons.movie_outlined;
      color = AppTokens.text2;
    }
    return Icon(icon, size: size, color: color);
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.tile, required this.iconSize});

  final MediaLibraryListTile tile;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final collection = tile.collection;
    final video = tile.video;
    final path = collection?.thumbnailPath ?? video?.thumbnailPath;
    final id = collection?.id ?? video!.id;
    final Widget fallback = collection != null
        ? FolderPlaceholderCover(
            folderId: collection.id,
            folderName: collection.name,
            coverLabel: collection.coverLabel,
          )
        : Center(
            child: Icon(
              video!.type == MediaType.audio
                  ? Icons.music_note_rounded
                  : Icons.movie_outlined,
              color: AppTokens.text3,
              size: iconSize,
            ),
          );
    return ColoredBox(
      color: const Color(0xFF1B1C1F),
      child: path != null && path.isNotEmpty
          ? CachedThumbnailWidget(
              videoId: id,
              thumbnailPath: path,
              fit: BoxFit.cover,
              placeholder: fallback,
              errorWidget: fallback,
            )
          : fallback,
    );
  }
}

class _TitleText extends StatelessWidget {
  const _TitleText({
    required this.tile,
    required this.layout,
    required this.maxLines,
  });

  final MediaLibraryListTile tile;
  final MediaTableColumnLayout layout;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final title = tile.isCollection ? tile.collection!.name : tile.video!.title;
    return Text(
      title,
      key: const ValueKey('media-table-title'),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: AppTokens.text1,
        fontSize: layout.bodyFontSize,
        height: 1.3,
        fontWeight: tile.isCollection || layout.isCompact
            ? FontWeight.w500
            : FontWeight.w400,
      ),
    );
  }
}

/// Second line of a compact row: location / type and watch progress.
class _CompactMeta extends StatelessWidget {
  const _CompactMeta({required this.tile, required this.layout});

  final MediaLibraryListTile tile;
  final MediaTableColumnLayout layout;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      color: AppTokens.text3,
      fontSize: layout.metaFontSize,
      height: 1.3,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final path = tile.relativePath;
    final hasPath = path != null && path.isNotEmpty;
    if (tile.isCollection) {
      return Text(
        hasPath ? '$path · 文件夹' : '文件夹',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    final video = tile.video!;
    final type = video.type == MediaType.audio ? '音频' : '视频';
    return _LivePosition(
      video: video,
      builder: (position, duration) {
        final inProgress = mediaRowIsInProgress(position, duration);
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: hasPath ? '$path · ' : '$type · '),
              TextSpan(
                text: mediaRowProgressLabel(position, duration),
                style: inProgress
                    ? base.copyWith(
                        color: AppTokens.accent,
                        fontWeight: FontWeight.w600,
                      )
                    : null,
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: base,
        );
      },
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.tile, required this.column, required this.layout});

  final MediaLibraryListTile tile;
  final MediaTableColumn column;
  final MediaTableColumnLayout layout;

  TextStyle get _textStyle => TextStyle(
    color: AppTokens.text2,
    fontSize: layout.metaFontSize,
    height: 1.2,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  Widget _text(String value, {Color? color}) => Text(
    value,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: color == null ? _textStyle : _textStyle.copyWith(color: color),
  );

  Widget get _empty => _text('—', color: AppTokens.text4);

  @override
  Widget build(BuildContext context) {
    final video = tile.video;
    switch (column) {
      case MediaTableColumn.type:
        return _text(
          tile.isCollection
              ? '文件夹'
              : video!.type == MediaType.audio
              ? '音频'
              : '视频',
          color: AppTokens.text3,
        );
      case MediaTableColumn.duration:
        return _text(
          tile.isCollection
              ? '${tile.collection!.childrenIds.length} 项'
              : formatMediaDuration(video!.durationMs),
        );
      case MediaTableColumn.progress:
        if (video == null) return _empty;
        return _LivePosition(
          video: video,
          builder: (position, duration) => _ProgressCell(
            position: position,
            duration: duration,
            layout: layout,
          ),
        );
      case MediaTableColumn.subtitles:
        if (video == null || !mediaVideoHasSubtitles(video)) return _empty;
        return Icon(
          Icons.subtitles_outlined,
          size: layout.metaFontSize * 1.25,
          color: AppTokens.text2,
        );
      case MediaTableColumn.updated:
        final ms = tile.isCollection
            ? tile.collection!.createTime
            : video!.lastUpdated;
        if (ms <= 0) return _empty;
        return _text(
          formatMediaTableUpdated(DateTime.fromMillisecondsSinceEpoch(ms)),
          color: AppTokens.text3,
        );
      case MediaTableColumn.location:
        final path = tile.relativePath;
        if (path == null || path.isEmpty) return _empty;
        return _text(path, color: AppTokens.text3);
    }
  }
}

class _ProgressCell extends StatelessWidget {
  const _ProgressCell({
    required this.position,
    required this.duration,
    required this.layout,
  });

  final int position;
  final int duration;
  final MediaTableColumnLayout layout;

  @override
  Widget build(BuildContext context) {
    final fraction = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    if (position <= 0 || duration <= 0) {
      return Text(
        '—',
        style: TextStyle(color: AppTokens.text4, fontSize: layout.metaFontSize),
      );
    }
    final finished = fraction >= 0.97;
    final barColor = finished ? AppTokens.text3 : AppTokens.accent;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Color(0x1AFFFFFF)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: fraction,
                    child: ColoredBox(color: barColor),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(
          width: layout.metaFontSize * 3.1,
          child: Text(
            finished ? '完成' : '${(fraction * 100).round()}%',
            textAlign: TextAlign.right,
            maxLines: 1,
            style: TextStyle(
              color: finished ? AppTokens.text3 : AppTokens.text2,
              fontSize: layout.metaFontSize,
              height: 1.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// Selection circle in selection mode, otherwise the action dock.
class _Trailing extends StatelessWidget {
  const _Trailing({required this.tile, required this.layout});

  final MediaLibraryListTile tile;
  final MediaTableColumnLayout layout;

  @override
  Widget build(BuildContext context) {
    final width = layout.isCompact ? null : layout.trailingWidth;
    if (tile.isSelectionMode) {
      final size = (layout.chipSize * 0.8).clamp(16.0, 24.0);
      return SizedBox(
        width: width ?? size + 12,
        child: Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            key: const ValueKey('media-list-selection-handle'),
            behavior: HitTestBehavior.opaque,
            onTap: tile.onSelectionTap,
            onPanStart: tile.onSelectionPanStart,
            onPanUpdate: tile.onSelectionPanUpdate,
            onPanEnd: tile.onSelectionPanEnd,
            onLongPressStart: tile.onSelectionLongPressStart,
            onLongPressMoveUpdate: tile.onSelectionLongPressMoveUpdate,
            onLongPressEnd: tile.onSelectionLongPressEnd,
            child: Icon(
              tile.isSelected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              key: ValueKey(tile.isSelected),
              color: tile.isSelected ? AppTokens.accent : AppTokens.text3,
              size: size,
            ),
          ),
        ),
      );
    }

    final showLocate = tile.onShowInParentFolder != null;
    final showMenu = tile.showActivityMenu || tile.moreActions != null;
    final showSync =
        showMenu &&
        tile.isCollection &&
        mediaLibraryFolderIsSynced(context, tile.collection!.id);
    final dockWidth = MediaLibraryActionDockMetrics.dockWidth(
      chipSize: layout.chipSize,
      showMore: showMenu,
      showLocate: showLocate,
      showSync: showSync,
    );
    if (dockWidth <= 0) return SizedBox(width: width ?? 0);
    return SizedBox(
      width: width ?? dockWidth + 4,
      child: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: dockWidth,
          height: layout.chipSize,
          child: Stack(
            children: [
              MediaLibraryActionDock(
                chipSize: layout.chipSize,
                sync: showSync
                    ? MediaLibraryFolderSyncButton(
                        collectionId: tile.collection!.id,
                        fillSlot: true,
                      )
                    : null,
                more: showMenu
                    ? tile.moreActions ??
                          MediaLibraryActivityMenuButton(
                            targetId: tile.itemId,
                            isCollection: tile.isCollection,
                            allowHide: tile.allowHide && !tile.isCollection,
                            allowDismissFromRecent: tile.allowDismissFromRecent,
                            allowHidePodcastFromFolders:
                                tile.allowHidePodcastFromFolders,
                            onLocate: tile.onShowInParentFolder,
                            onMoveToParent: tile.onMoveToParent,
                            fillSlot: true,
                          )
                    : null,
                locate: showLocate
                    ? MediaLibraryLocateButton(
                        onPressed: tile.onShowInParentFolder!,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rebuilds with the live position only while [video] is playing.
class _LivePosition extends StatelessWidget {
  const _LivePosition({required this.video, required this.builder});

  final VideoItem video;
  final Widget Function(int positionMs, int durationMs) builder;

  @override
  Widget build(BuildContext context) {
    MediaPlaybackService? service;
    try {
      service = Provider.of<MediaPlaybackService>(context, listen: false);
    } on ProviderNotFoundException {
      service = null;
    }
    if (service == null) return builder(video.lastPositionMs, video.durationMs);
    return Selector<MediaPlaybackService, ({bool current, int duration})>(
      selector: (_, service) {
        final current = service.currentItem?.id == video.id;
        return (
          current: current,
          duration: current && service.duration.inMilliseconds > 0
              ? service.duration.inMilliseconds
              : video.durationMs,
        );
      },
      builder: (context, data, _) {
        if (!data.current) return builder(video.lastPositionMs, data.duration);
        return ValueListenableBuilder<Duration>(
          valueListenable: context
              .read<MediaPlaybackService>()
              .coarsePositionNotifier,
          builder: (_, position, _) =>
              builder(position.inMilliseconds, data.duration),
        );
      },
    );
  }
}

String formatMediaTableUpdated(DateTime date, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final day = DateTime(date.year, date.month, date.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  if (day.year == clock.year) return '${day.month}月${day.day}日';
  return '${day.year}/${day.month}/${day.day}';
}

MediaTableSortKey? sortKeyForTableColumn(MediaTableColumn column) {
  return switch (column) {
    MediaTableColumn.type => MediaTableSortKey.type,
    MediaTableColumn.duration => MediaTableSortKey.duration,
    MediaTableColumn.progress => MediaTableSortKey.progress,
    MediaTableColumn.updated => MediaTableSortKey.updated,
    MediaTableColumn.subtitles || MediaTableColumn.location => null,
  };
}
