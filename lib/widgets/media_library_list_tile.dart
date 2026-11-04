import 'card_context_menu.dart';
import 'library_card_rebuild.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';
import 'package:provider/provider.dart';

import '../models/video_collection.dart';
import '../models/video_item.dart';
import '../services/media_playback_service.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import 'cached_thumbnail_widget.dart';
import 'media_card_preparation.dart';
import 'folder_placeholder_cover.dart';
import 'media_library_layout_profile.dart';
import 'media_library_table_row.dart';
import 'media_library_list_tile_rows.dart';
import 'media_library_locate_button.dart';
import 'media_library_activity_menu.dart';
import 'media_library_action_dock.dart';
import 'media_library_folder_sync_button.dart';
import 'media_library_gestures.dart';

/// Shared, information-dense row used by both media-library screens.
class MediaLibraryListTile extends StatelessWidget {
  const MediaLibraryListTile.video({
    super.key,
    required VideoItem item,
    required this.index,
    required this.showIndex,
    required this.showThumbnail,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    this.onLongPress,
    required this.titleScale,
    this.onSecondaryTap,
    this.onSelectionTap,
    this.onSelectionPanStart,
    this.onSelectionPanUpdate,
    this.onSelectionPanEnd,
    this.onSelectionLongPressStart,
    this.onSelectionLongPressMoveUpdate,
    this.onSelectionLongPressEnd,
    this.onShowInParentFolder,
    this.onMoveToParent,
    this.showActivityMenu = false,
    this.moreActions,
    this.allowHide = false,
    this.allowDismissFromRecent = false,
    this.allowHidePodcastFromFolders = false,
    this.relativePath,
    this.style,
  }) : _video = item,
       _collection = null;

  const MediaLibraryListTile.collection({
    super.key,
    required VideoCollection collection,
    required this.index,
    required this.showIndex,
    required this.showThumbnail,
    required this.isSelected,
    required this.isSelectionMode,
    required this.onTap,
    this.onLongPress,
    required this.titleScale,
    this.onSecondaryTap,
    this.onSelectionTap,
    this.onSelectionPanStart,
    this.onSelectionPanUpdate,
    this.onSelectionPanEnd,
    this.onSelectionLongPressStart,
    this.onSelectionLongPressMoveUpdate,
    this.onSelectionLongPressEnd,
    this.onShowInParentFolder,
    this.onMoveToParent,
    this.showActivityMenu = false,
    this.moreActions,
    this.allowHide = false,
    this.allowDismissFromRecent = false,
    this.allowHidePodcastFromFolders = false,
    this.relativePath,
    this.style,
  }) : _collection = collection,
       _video = null;

  final VideoItem? _video;
  final VideoCollection? _collection;
  final int index;
  final bool showIndex;
  final bool showThumbnail;
  final bool isSelected;
  final bool isSelectionMode;
  final VoidCallback onTap;

  /// 未进入选择模式时，长按整行进入选择。选择模式下由勾选手柄接管。
  final VoidCallback? onLongPress;

  /// Fallback secondary action when no overflow menu is visible.
  final VoidCallback? onSecondaryTap;
  final double titleScale;
  final GestureTapCallback? onSelectionTap;
  final GestureDragStartCallback? onSelectionPanStart;
  final GestureDragUpdateCallback? onSelectionPanUpdate;
  final GestureDragEndCallback? onSelectionPanEnd;
  final GestureLongPressStartCallback? onSelectionLongPressStart;
  final GestureLongPressMoveUpdateCallback? onSelectionLongPressMoveUpdate;
  final GestureLongPressEndCallback? onSelectionLongPressEnd;
  final VoidCallback? onShowInParentFolder;
  final VoidCallback? onMoveToParent;
  final bool showActivityMenu;
  final Widget? moreActions;
  final bool allowHide;

  /// 最近添加 card menu. Folders can use this; [allowHide] cannot.
  final bool allowDismissFromRecent;
  final bool allowHidePodcastFromFolders;
  final String? relativePath;

  /// Resolved rows/table style. Null falls back to the active settings style.
  final MediaListStyleSettings? style;

  bool get _isCollection => _collection != null;

  VideoItem? get video => _video;
  VideoCollection? get collection => _collection;
  bool get isCollection => _isCollection;
  String get itemId => _video?.id ?? _collection!.id;

  MediaListStyleSettings resolveStyle(BuildContext context) =>
      style ?? SettingsService().listStyleFor(MediaQuery.sizeOf(context));

  @override
  Widget build(BuildContext context) {
    final resolved = resolveStyle(context);
    return LibraryCardRebuild(
      itemId: itemId,
      builder: (context) => CardContextMenu(
        onFallback: onSecondaryTap,
        builder: (context, openMenu) => MediaCardPreparationHost(
          child: resolved.isTable
              ? MediaLibraryTableRow(
                  tile: this,
                  style: resolved,
                  openMenu: openMenu,
                )
              : _buildTile(context, openMenu, resolved),
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context,
    VoidCallback openMenu,
    MediaListStyleSettings resolved,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showLocateButton =
            onShowInParentFolder != null && !isSelectionMode;
        final showMenu =
            (showActivityMenu || moreActions != null) && !isSelectionMode;
        final showSync =
            showMenu &&
            _isCollection &&
            mediaLibraryFolderIsSynced(context, _collection!.id);

        var metrics = MediaRowTileMetrics.resolve(
          style: resolved,
          screenShortestSide: MediaQuery.sizeOf(context).shortestSide,
          cellWidth: constraints.maxWidth,
          rowHeight: constraints.maxHeight,
          titleScaleFallback: titleScale,
          styleShowMeta: resolved.showMeta,
          styleShowProgress: resolved.showProgress,
        );
        final dockWidth = MediaLibraryActionDockMetrics.dockWidth(
          chipSize: metrics.chipSize,
          showMore: showMenu,
          showLocate: showLocateButton,
          showSync: showSync,
        );
        final trailingWidth = isSelectionMode
            ? metrics.trailingSize + 4
            : dockWidth;
        metrics = metrics.clampThumbnailToRowWidth(
          rowWidth: constraints.maxWidth,
          trailingReserve: trailingWidth,
        );
        final indexLabel = showIndex ? '${index + 1}'.padLeft(2, '0') : null;
        final contentHeight = math.max(
          0.0,
          metrics.rowHeight - metrics.inset * 2,
        );

        final Widget leading = showThumbnail
            ? SizedBox(
                key: const ValueKey('media-list-thumbnail'),
                width: metrics.thumbnailWidth,
                height: metrics.thumbnailHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(metrics.thumbnailRadius),
                  child: _buildCover(metrics, indexLabel: indexLabel),
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (indexLabel != null)
                    SizedBox(
                      width: metrics.indexWidth,
                      child: Text(
                        indexLabel,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppTokens.text3,
                          fontSize: metrics.indexFontSize,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  _buildIconSquare(metrics),
                ],
              );

        Widget? trailing;
        if (isSelectionMode) {
          trailing = SizedBox(
            width: trailingWidth,
            height: showThumbnail ? metrics.thumbnailHeight : contentHeight,
            child: Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                key: const ValueKey('media-list-selection-handle'),
                behavior: HitTestBehavior.opaque,
                onTap: onSelectionTap,
                onPanStart: onSelectionPanStart,
                onPanUpdate: onSelectionPanUpdate,
                onPanEnd: onSelectionPanEnd,
                onLongPressStart: onSelectionLongPressStart,
                onLongPressMoveUpdate: onSelectionLongPressMoveUpdate,
                onLongPressEnd: onSelectionLongPressEnd,
                child: AnimatedSwitcher(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, animation) =>
                      ScaleTransition(scale: animation, child: child),
                  child: Icon(
                    isSelected
                        ? Icons.check_circle_rounded
                        : Icons.radio_button_unchecked_rounded,
                    key: ValueKey(isSelected),
                    color: isSelected ? AppTokens.accent : AppTokens.text3,
                    size: metrics.trailingSize,
                  ),
                ),
              ),
            ),
          );
        }
        Widget? dock;
        if (!isSelectionMode && dockWidth > 0) {
          // Same corner dock as the grid cards: flush with the card's
          // bottom-right edge, so text only reserves its width.
          trailing = SizedBox(width: math.max(0.0, dockWidth - metrics.inset));
          dock = MediaLibraryActionDock(
            chipSize: metrics.chipSize,
            sync: showSync
                ? MediaLibraryFolderSyncButton(
                    collectionId: _collection.id,
                    fillSlot: true,
                  )
                : null,
            more: showMenu
                ? moreActions ??
                      MediaLibraryActivityMenuButton(
                        targetId: itemId,
                        isCollection: _isCollection,
                        allowHide: allowHide && !_isCollection,
                        allowDismissFromRecent: allowDismissFromRecent,
                        allowHidePodcastFromFolders:
                            allowHidePodcastFromFolders,
                        onLocate: onShowInParentFolder,
                        onMoveToParent: onMoveToParent,
                        fillSlot: true,
                      )
                : null,
            locate: showLocateButton
                ? MediaLibraryLocateButton(onPressed: onShowInParentFolder!)
                : null,
          );
        }

        return MediaLibrarySelectionLongPress(
          onLongPress: isSelectionMode ? null : onLongPress,
          child: MediaRowTileShell(
            radius: metrics.radius,
            cardSurface: resolved.cardSurface,
            isSelected: isSelected,
            child: Material(
              key: const ValueKey('media-list-card'),
              type: MaterialType.transparency,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  InkWell(
                    onTap: () {
                      unawaited(AppHaptics.cardTap(SettingsService()));
                      onTap();
                    },
                    onSecondaryTap: openMenu,
                    hoverColor: Colors.transparent,
                    highlightColor: Colors.white.withValues(alpha: 0.03),
                    splashColor: AppTokens.accent.withValues(alpha: 0.10),
                    child: Padding(
                      padding: EdgeInsets.all(metrics.inset),
                      child: Row(
                        crossAxisAlignment: showThumbnail
                            ? CrossAxisAlignment.start
                            : CrossAxisAlignment.center,
                        children: [
                          leading,
                          SizedBox(width: metrics.gap),
                          Expanded(
                            child: _buildInformation(
                              metrics,
                              height: contentHeight,
                              alignTop: showThumbnail,
                            ),
                          ),
                          if (trailing != null) ...[
                            const SizedBox(width: 4),
                            trailing,
                          ],
                        ],
                      ),
                    ),
                  ),
                  ?dock,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIconSquare(MediaRowTileMetrics metrics) {
    final collection = _collection;
    final video = _video;
    final icon = collection != null
        ? Icons.folder_rounded
        : video!.type == MediaType.audio
        ? Icons.music_note_rounded
        : Icons.play_arrow_rounded;
    return Container(
      width: metrics.iconExtent,
      height: metrics.iconExtent,
      decoration: BoxDecoration(
        color: AppTokens.bgCard,
        borderRadius: BorderRadius.circular(metrics.iconExtent * 0.24),
      ),
      child: Icon(
        icon,
        color: collection != null ? AppTokens.accent : AppTokens.text2,
        size: metrics.iconExtent * 0.52,
      ),
    );
  }

  Widget _buildCover(MediaRowTileMetrics metrics, {String? indexLabel}) {
    final collection = _collection;
    final video = _video;
    final path = collection != null
        ? collection.thumbnailPath
        : video!.thumbnailPath;
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
                  : Icons.movie_rounded,
              color: AppTokens.text3,
              size: metrics.thumbnailHeight * 0.38,
            ),
          );
    final badgeLabel = collection != null
        ? mediaRowFolderBadgeLabel(collection)
        : mediaRowVideoBadgeLabel(video!);
    // Badges only read once the cover is tall enough to hold them.
    final showBadge = metrics.thumbnailHeight >= 30;
    final edge = (metrics.thumbnailHeight * 0.06).clamp(2.0, 6.0);
    final indexSize = (metrics.thumbnailHeight * 0.16).clamp(7.0, 11.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
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
        ),
        if (video != null && metrics.showProgress)
          _MediaRowPlayback(
            video: video,
            builder: (position, duration) {
              if (duration <= 0 || position <= 0) {
                return const SizedBox.shrink();
              }
              return MediaRowCoverProgress(
                fraction: position / duration,
                thickness: metrics.progressThickness,
              );
            },
          ),
        if (showBadge)
          Positioned(
            right: edge,
            bottom: edge + (video != null ? metrics.progressThickness : 0),
            child: MediaRowThumbnailBadge(
              label: badgeLabel,
              fontSize: metrics.badgeFontSize,
            ),
          ),
        if (indexLabel != null)
          Positioned(
            left: edge,
            top: edge,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.62),
                borderRadius: BorderRadius.circular(indexSize * 0.36),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: indexSize * 0.4,
                  vertical: indexSize * 0.12,
                ),
                child: Text(
                  indexLabel,
                  key: const ValueKey('media-list-thumbnail-index'),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontSize: indexSize,
                    height: 1.15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildInformation(
    MediaRowTileMetrics metrics, {
    required double height,
    required bool alignTop,
  }) {
    final plan = metrics.layoutPlan;
    final title = _isCollection ? _collection!.name : _video!.title;
    final metaStyle = TextStyle(
      color: AppTokens.text3,
      fontSize: metrics.metadataSize,
      height: MediaRowTileMetrics.metaLineHeight,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final path = relativePath;
    final hasPath = path != null && path.isNotEmpty;

    final children = <Widget>[
      Text(
        title,
        key: const ValueKey('media-list-title'),
        maxLines: plan.titleLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppTokens.text1,
          fontSize: metrics.titleSize,
          height: MediaRowTileMetrics.titleLineHeight,
          fontWeight: _isCollection ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    ];

    if (plan.showMetaLine) {
      children.add(SizedBox(height: metrics.textGap));
      if (_isCollection) {
        children.add(
          Text(
            [
              if (hasPath) path,
              '${_collection!.childrenIds.length} 个项目',
            ].join(' · '),
            key: const ValueKey('media-list-metadata'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: metaStyle,
          ),
        );
      } else {
        final video = _video!;
        children.add(
          _MediaRowPlayback(
            video: video,
            builder: (position, duration) => Text.rich(
              TextSpan(
                // Merged progress leads so ellipsis trims the path instead.
                children: [
                  if (plan.progressInMetaLine) ...[
                    _progressSpan(position, duration, metaStyle),
                    const TextSpan(text: ' · '),
                  ],
                  if (hasPath) TextSpan(text: '$path · '),
                  TextSpan(text: mediaRowMetaLineForVideo(video, duration)),
                ],
              ),
              key: const ValueKey('media-list-metadata'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: metaStyle,
            ),
          ),
        );
      }
    }

    if (plan.showProgressLine && !_isCollection) {
      final video = _video!;
      final hasSubtitles = mediaVideoHasSubtitles(video);
      children.add(SizedBox(height: metrics.textGap));
      children.add(
        _MediaRowPlayback(
          video: video,
          builder: (position, duration) => Text.rich(
            TextSpan(
              children: [
                _progressSpan(position, duration, metaStyle),
                if (hasSubtitles) const TextSpan(text: '  ·  字幕'),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: metaStyle,
          ),
        ),
      );
    }

    // The plan already sizes text to the row; clipping guards against font
    // metrics that run a pixel taller than predicted.
    return SizedBox(
      height: height,
      child: ClipRect(
        child: OverflowBox(
          alignment: alignTop ? Alignment.topLeft : Alignment.centerLeft,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }

  TextSpan _progressSpan(int position, int duration, TextStyle base) {
    final label = mediaRowProgressLabel(position, duration);
    if (mediaRowIsInProgress(position, duration)) {
      return TextSpan(
        text: label,
        style: base.copyWith(
          color: AppTokens.accent,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return TextSpan(
      text: label,
      style: label == '已看完' ? base.copyWith(color: AppTokens.text2) : base,
    );
  }
}

/// Rebuilds with the live position only while [video] is the playing item,
/// so a full library page does not rebuild on every playback tick.
class _MediaRowPlayback extends StatelessWidget {
  const _MediaRowPlayback({required this.video, required this.builder});

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
