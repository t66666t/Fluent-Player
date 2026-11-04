import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

import '../models/video_item.dart';
import 'cached_thumbnail_widget.dart';
import 'media_library_browse_grid_cards.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Group chrome for virtual library rows (import batches, continue folders,
/// history days). Covers are decorative; [onToggle] owns expand, not playback.
class MediaLibraryGroupHeader extends StatelessWidget {
  const MediaLibraryGroupHeader({
    super.key,
    required this.title,
    required this.coverItems,
    required this.expanded,
    this.subtitle,
    this.remainderCount = 0,
    this.showChevron = true,
    this.onToggle,
    this.onOpenFolder,
    this.progress,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 8, 8),
  });

  final String title;
  final String? subtitle;
  final List<VideoItem> coverItems;
  final bool expanded;
  final int remainderCount;
  final bool showChevron;
  final VoidCallback? onToggle;
  final VoidCallback? onOpenFolder;

  /// 0–1 watch progress of the featured item, if any.
  final double? progress;

  /// Horizontal inset should match the grid's outer padding. Vertical inset
  /// stays 0 when the parent inserts the flow-spacing gaps.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final canToggle = showChevron && onToggle != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: canToggle ? onToggle : null,
        child: Padding(
          padding: padding,
          child: Row(
            children: [
              MediaLibraryStackedCovers(items: coverItems),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    if (progress != null && progress! > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress!.clamp(0.0, 1.0),
                            minHeight: 3,
                            backgroundColor: Colors.white12,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (onOpenFolder != null)
                DesktopButtonClickRegion(child: IconButton(
                  tooltip: '打开此目录',
                  onPressed: onOpenFolder,
                  icon: const Icon(
                    Icons.folder_outlined,
                    color: Colors.white70,
                  ),
                )),
              if (canToggle) ...[
                if (!expanded && remainderCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      '其余$remainderCount',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: const Icon(
                    Icons.expand_more,
                    color: AppTokens.text3,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Overlapping 16:9 thumbs so a collapsed batch still reads as a stack.
class MediaLibraryStackedCovers extends StatelessWidget {
  const MediaLibraryStackedCovers({super.key, required this.items});

  final List<VideoItem> items;

  static const double _tileW = 40;
  static const double _tileH = 28;
  static const double _overlap = 12;

  @override
  Widget build(BuildContext context) {
    final shown = items.take(4).toList(growable: false);
    if (shown.isEmpty) {
      return SizedBox(
        width: _tileW,
        height: _tileH,
        child: const DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.all(Radius.circular(4)),
          ),
        ),
      );
    }
    final width = _tileW + (shown.length - 1) * _overlap;
    return SizedBox(
      width: width,
      height: _tileH,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * _overlap,
              child: _CoverTile(item: shown[i]),
            ),
        ],
      ),
    );
  }
}

class _CoverTile extends StatelessWidget {
  const _CoverTile({required this.item});

  final VideoItem item;

  @override
  Widget build(BuildContext context) {
    final fallback = MediaLibraryMediaGridCard.scaledThumbnailIcon(
      extent: MediaLibraryStackedCovers._tileH,
      icon: item.type == MediaType.audio ? Icons.music_note : Icons.movie,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: MediaLibraryStackedCovers._tileW,
        height: MediaLibraryStackedCovers._tileH,
        child: CachedThumbnailWidget(
          videoId: item.id,
          thumbnailPath: item.thumbnailPath,
          fit: BoxFit.cover,
          cacheWidth: 80,
          cacheHeight: 56,
          placeholder: fallback,
          errorWidget: fallback,
        ),
      ),
    );
  }
}
