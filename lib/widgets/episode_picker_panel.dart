import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../models/video_item.dart';
import '../models/playback_mode.dart';
import '../features/podcasts/podcast_queue_artwork.dart';
import '../services/bilibili/bilibili_watch_playlist.dart';
import 'playlist_bottom_sheet.dart';
import 'playback_mode_button.dart';
import '../services/media_playback_service.dart';
import '../services/playlist_manager.dart';
import '../services/playback_queue_actions.dart';
import 'bilibili_queue_thumbnail.dart';
import 'cached_thumbnail_widget.dart';
import 'cloud_drive_queue_preview.dart';
import 'playback_queue_remove_button.dart';
import 'playback_queue_sort_controls.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

class EpisodePickerPanel extends StatefulWidget {
  final double panelWidth;
  final double panelHeight;
  final VoidCallback onClose;
  final bool isPortrait;

  const EpisodePickerPanel({
    super.key,
    required this.panelWidth,
    required this.panelHeight,
    required this.onClose,
    this.isPortrait = false,
  });

  @override
  State<EpisodePickerPanel> createState() => _EpisodePickerPanelState();
}

class _EpisodePickerPanelState extends State<EpisodePickerPanel> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _listViewKey = GlobalKey();
  final GlobalKey _currentItemKey = GlobalKey();
  bool _userMoved = false;
  double? _rowExtent;
  List<VideoItem>? _dragPlaylist;

  @override
  void initState() {
    super.initState();
    // 弹窗打开时，定位到当前播放视频
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentItem();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCurrentItem() {
    if (!mounted || _userMoved) return;
    final playlistManager = Provider.of<PlaylistManager>(
      context,
      listen: false,
    );
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final currentItemId = playbackService.currentItem?.id;
    if (currentItemId == null || playlistManager.playlist.isEmpty) return;

    final int index = playlistManager.playbackQueue.indexWhere(
      (item) => item.id == currentItemId,
    );
    if (index >= 0) {
      final totalCount = playlistManager.playlist.length;
      _jumpToRoughOffset(index, totalCount);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _alignCurrentItemPrecisely(index, totalCount, 0);
      });
    }
  }

  void _jumpToRoughOffset(int index, int totalCount) {
    if (!_scrollController.hasClients || _userMoved) return;
    if (totalCount <= 1) {
      _scrollController.jumpTo(0);
      return;
    }
    final extent = _rowExtent ?? 72;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final roughOffset = index * extent;
    _scrollController.jumpTo(roughOffset.clamp(0.0, maxExtent));
  }

  void _alignCurrentItemPrecisely(int index, int totalCount, int retryCount) {
    if (!mounted || _userMoved) return;
    if (!_scrollController.hasClients) {
      if (retryCount < 6) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _alignCurrentItemPrecisely(index, totalCount, retryCount + 1);
        });
      }
      return;
    }
    final itemContext = _currentItemKey.currentContext;
    final listContext = _listViewKey.currentContext;
    if (itemContext == null || listContext == null) {
      if (retryCount < 6) {
        _jumpToRoughOffset(index, totalCount);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _alignCurrentItemPrecisely(index, totalCount, retryCount + 1);
        });
      }
      return;
    }

    final itemBox = itemContext.findRenderObject() as RenderBox?;
    final listBox = listContext.findRenderObject() as RenderBox?;
    if (itemBox == null || listBox == null) return;

    final itemTop = itemBox.localToGlobal(Offset.zero, ancestor: listBox).dy;
    final itemHeight = itemBox.size.height;
    if (itemHeight > 0) _rowExtent = itemHeight;
    final viewportHeight = listBox.size.height;
    final targetItemCenterY = viewportHeight * 0.35;
    final currentItemCenterY = itemTop + itemHeight / 2;
    final delta = currentItemCenterY - targetItemCenterY;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final targetOffset = (_scrollController.offset + delta).clamp(
      0.0,
      maxExtent,
    );
    _scrollController.jumpTo(targetOffset);
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }

  Widget _buildEpisodeThumbnail({
    required VideoItem item,
    required double width,
    required double height,
    required double iconSize,
  }) {
    if (item.sourceRef?.podcast != null) {
      return SizedBox(
        width: width,
        height: height,
        child: PodcastQueueArtwork(
          item: item,
          size: width,
          placeholder: _buildEpisodeThumbnailPlaceholder(
            width,
            height,
            iconSize,
          ),
        ),
      );
    }
    if (item.type == MediaType.audio) {
      if (item.thumbnailPath?.isNotEmpty == true) {
        return SizedBox(
          width: width,
          height: height,
          child: CachedThumbnailWidget(
            videoId: item.id,
            thumbnailPath: item.thumbnailPath!,
            fit: BoxFit.cover,
            cacheWidth: 200,
            placeholder: const ColoredBox(
              color: Color(0xFF1E1E1E),
              child: Center(
                child: Icon(Icons.music_note, color: Colors.white54),
              ),
            ),
            errorWidget: const ColoredBox(
              color: Color(0xFF1E1E1E),
              child: Center(
                child: Icon(Icons.music_note, color: Colors.white54),
              ),
            ),
          ),
        );
      }
      return Container(
        width: width,
        height: height,
        color: const Color(0xFF1E1E1E),
        alignment: Alignment.center,
        child: Icon(Icons.music_note, size: iconSize, color: Colors.blueAccent),
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: BilibiliQueueThumbnail(
        item: item,
        cacheWidth: 108,
        cacheHeight: 80,
        placeholder: _buildEpisodeThumbnailPlaceholder(width, height, iconSize),
      ),
    );
  }

  Widget _buildEpisodeThumbnailPlaceholder(
    double width,
    double height,
    double iconSize,
  ) {
    return Container(
      width: width,
      height: height,
      color: const Color(0xFF1E1E1E),
      alignment: Alignment.center,
      child: Icon(
        Icons.video_library,
        size: iconSize * 0.8,
        color: Colors.white54,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final chrome = context
        .select<
          MediaPlaybackService,
          ({
            String? currentId,
            String? pendingId,
            bool playing,
            PlaybackState state,
            bool hasPrevious,
            bool hasNext,
            String? nextId,
            PlaybackMode mode,
            bool automatic,
          })
        >(
          (service) => (
            currentId: service.currentItem?.id,
            pendingId: service.pendingSwitchItem?.id,
            playing: service.isPlaying,
            state: service.state,
            hasPrevious: service.hasPlayablePrevious,
            hasNext: service.hasPlayableNext,
            nextId: service.nextPlayableItem?.id,
            mode: service.playbackMode,
            automatic: service.automaticQueueContinuation,
          ),
        );
    final playlist = context.select<PlaylistManager, List<VideoItem>>(
      (manager) => manager.playbackQueue,
    );
    final currentItemId = chrome.currentId;
    final pendingId = chrome.pendingId;
    final playlistManager = context.read<PlaylistManager>();
    final bilibiliList = BilibiliWatchPlaylistSession.instance;

    final double panelWidth = widget.panelWidth;
    final double panelHeight = widget.panelHeight;
    final double panelRadius = (panelWidth * 0.03).clamp(12.0, 24.0);
    final double headerHorizontalPadding = (panelWidth * 0.04).clamp(
      14.0,
      24.0,
    );
    final double headerVerticalPadding = (panelHeight * 0.03).clamp(10.0, 16.0);
    final double rowHorizontalPadding = (panelWidth * 0.04).clamp(12.0, 24.0);
    final double rowVerticalPadding = (panelHeight * 0.02).clamp(7.0, 12.0);

    // 增加字号限制，不至于太大，但更清晰
    final double titleFontSize = (panelWidth * 0.033).clamp(13.0, 15.0);
    final double subFontSize = (panelWidth * 0.026).clamp(10.5, 12.0);
    final double currentTagFontSize = (panelWidth * 0.023).clamp(9.5, 11.0);

    final double headerIconSize = (panelWidth * 0.043).clamp(18.0, 24.0);
    final double thumbWidth = (panelWidth * 0.13).clamp(
      panelWidth < 360 ? 48.0 : 56.0,
      100.0,
    );
    final double thumbHeight = thumbWidth * 0.65;
    final double itemGap = (panelWidth * 0.018).clamp(8.0, 16.0);
    final double actionIconSize = (panelWidth * 0.038).clamp(18.0, 24.0);

    return GestureDetector(
      onTap: () {}, // 阻止点击穿透
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: panelWidth,
          height: panelHeight,
          decoration: widget.isPortrait
              ? const BoxDecoration(color: Color(0xFF1E1E1E))
              : BoxDecoration(
                  color: const Color(0xEB1E1E1E), // 苹果风格的深色半透明
                  borderRadius: BorderRadius.circular(panelRadius),
                  border: Border.all(color: Colors.white12, width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 30.0,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
          child: ClipRRect(
            borderRadius: widget.isPortrait
                ? BorderRadius.zero
                : BorderRadius.circular(panelRadius),
            child: Column(
              children: [
                // Header
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: headerHorizontalPadding,
                    vertical: headerVerticalPadding,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Colors.white10, width: 0.5),
                    ),
                    color: Colors.transparent,
                  ),
                  child: PlaybackQueueHeader(
                    title: '播放列表 (${playlist.length})',
                    titleStyle: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: titleFontSize,
                      letterSpacing: 0.3,
                    ),
                    leading: widget.isPortrait
                        ? DesktopButtonClickRegion(
                            child: IconButton(
                              icon: Icon(
                                Icons.arrow_back_ios_new,
                                color: Colors.white,
                                size: headerIconSize * 0.8,
                              ),
                              tooltip: '返回',
                              padding: EdgeInsets.zero,
                              visualDensity: VisualDensity.compact,
                              constraints: BoxConstraints.tightFor(
                                width: actionIconSize * 1.8,
                                height: actionIconSize * 1.8,
                              ),
                              onPressed: widget.onClose,
                            ),
                          )
                        : Icon(
                            Icons.playlist_play,
                            color: Colors.white,
                            size: headerIconSize,
                          ),
                    canReverse: playlist.length > 1,
                    canReset: playlistManager.hasCustomOrder,
                    onReverse: () => reversePlaybackQueue(playlistManager),
                    onReset: () => resetPlaybackQueueOrder(playlistManager),
                    separateSecondaryActions: bilibiliList?.isActive ?? false,
                    secondaryActions: [
                      if (bilibiliList != null && bilibiliList.isActive)
                        BilibiliPlaylistClearButton(
                          session: bilibiliList,
                          fontSize: subFontSize,
                        ),
                      if (!widget.isPortrait)
                        PlaybackModeButton(
                          key: const ValueKey('episode-picker-playback-mode'),
                          size: Size.square(
                            (actionIconSize * 1.8).clamp(36.0, 44.0),
                          ),
                          iconSize: actionIconSize,
                        ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          icon: Icon(
                            Icons.skip_previous,
                            color: chrome.hasPrevious
                                ? Colors.white
                                : Colors.white38,
                            size: actionIconSize,
                          ),
                          tooltip: "上一集",
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints.tightFor(
                            width: actionIconSize * 1.8,
                            height: actionIconSize * 1.8,
                          ),
                          onPressed: chrome.hasPrevious
                              ? () {
                                  playbackService.playPrevious();
                                }
                              : null,
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          icon: Icon(
                            chrome.playing ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                            size: actionIconSize * 1.2,
                          ),
                          tooltip: chrome.playing ? "暂停" : "播放",
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints.tightFor(
                            width: actionIconSize * 1.8,
                            height: actionIconSize * 1.8,
                          ),
                          onPressed: () {
                            if (chrome.playing) {
                              playbackService.pause();
                            } else {
                              playbackService.resume();
                            }
                          },
                        ),
                      ),
                      DesktopButtonClickRegion(
                        child: IconButton(
                          icon: Icon(
                            Icons.skip_next,
                            color: chrome.hasNext
                                ? Colors.white
                                : Colors.white38,
                            size: actionIconSize,
                          ),
                          tooltip: "下一集",
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: BoxConstraints.tightFor(
                            width: actionIconSize * 1.8,
                            height: actionIconSize * 1.8,
                          ),
                          onPressed: chrome.hasNext
                              ? () {
                                  playbackService.playNext();
                                }
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                if (playlist.isEmpty)
                  Expanded(
                    child: Center(
                      child: Text(
                        "播放列表为空",
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: titleFontSize,
                        ),
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification is ScrollStartNotification &&
                            notification.dragDetails != null) {
                          _userMoved = true;
                        }
                        if (notification is ScrollUpdateNotification &&
                            notification.dragDetails != null) {
                          _userMoved = true;
                        }
                        return false;
                      },
                      child: PlaybackQueueListView(
                        key: _listViewKey,
                        controller: _scrollController,
                        itemCount: playlist.length,
                        onReorderStart: (_) {
                          _userMoved = true;
                          _dragPlaylist = List.of(playlist);
                        },
                        onReorder: (oldIndex, newIndex) {
                          reorderPlaybackQueue(
                            playlistManager,
                            reorderedQueueItemIds(
                              _dragPlaylist ?? playlist,
                              oldIndex,
                              newIndex,
                            ),
                          );
                          _dragPlaylist = null;
                        },
                        findChildIndexCallback: (key) {
                          if (key is! ValueKey<String>) return null;
                          final index = playlist.indexWhere(
                            (entry) => entry.id == key.value,
                          );
                          return index < 0 ? null : index;
                        },
                        padding: EdgeInsets.symmetric(
                          vertical: (panelHeight * 0.02).clamp(8.0, 16.0),
                        ),
                        itemBuilder: (context, index) {
                          final item = playlist[index];
                          final isCurrent = item.id == currentItemId;
                          final isPending =
                              item.id == pendingId &&
                              (pendingId != currentItemId ||
                                  chrome.state == PlaybackState.loading);
                          return CloudDriveQueuePreview(
                            key: ValueKey(item.id),
                            item: item,
                            builder: (context) => Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: () {
                                  if (!isCurrent || isPending) {
                                    unawaited(
                                      AppHaptics.selectionClick(
                                        SettingsService(),
                                      ),
                                    );
                                    playbackService.playPlaylistItem(item);
                                  }
                                  // 保持弹窗开启
                                },
                                child: Container(
                                  key: isCurrent ? _currentItemKey : null,
                                  padding: EdgeInsets.symmetric(
                                    horizontal: rowHorizontalPadding,
                                    vertical: rowVerticalPadding,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isCurrent
                                        ? Colors.white.withValues(alpha: 0.08)
                                        : Colors.transparent,
                                  ),
                                  child: Row(
                                    children: [
                                      PlaybackQueueDragHandle(
                                        key: ValueKey('queue-drag-${item.id}'),
                                        index: index,
                                        isCurrent: isCurrent,
                                        title:
                                            BilibiliWatchPlaylistSession.titleOf(
                                              item,
                                            ),
                                        enabled: playlist.length > 1,
                                        onMoveUp: index > 0
                                            ? () => reorderPlaybackQueue(
                                                playlistManager,
                                                reorderedQueueItemIds(
                                                  playlist,
                                                  index,
                                                  index - 1,
                                                ),
                                              )
                                            : null,
                                        onMoveDown: index < playlist.length - 1
                                            ? () => reorderPlaybackQueue(
                                                playlistManager,
                                                reorderedQueueItemIds(
                                                  playlist,
                                                  index,
                                                  index + 1,
                                                ),
                                              )
                                            : null,
                                      ),
                                      const SizedBox(width: 4),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          (panelRadius * 0.4).clamp(4.0, 8.0),
                                        ),
                                        child: Stack(
                                          children: [
                                            _buildEpisodeThumbnail(
                                              item: item,
                                              width: thumbWidth,
                                              height: thumbHeight,
                                              iconSize: actionIconSize,
                                            ),
                                            if (item.durationMs > 0)
                                              Positioned(
                                                left: 0,
                                                right: 0,
                                                bottom: 0,
                                                child: SizedBox(
                                                  height: 2.5,
                                                  child: isCurrent
                                                      ? ValueListenableBuilder<
                                                          Duration
                                                        >(
                                                          valueListenable:
                                                              playbackService
                                                                  .coarsePositionNotifier,
                                                          builder:
                                                              (
                                                                _,
                                                                position,
                                                                _,
                                                              ) => LinearProgressIndicator(
                                                                value:
                                                                    (position.inMilliseconds /
                                                                            item.durationMs)
                                                                        .clamp(
                                                                          0.0,
                                                                          1.0,
                                                                        ),
                                                                backgroundColor:
                                                                    Colors
                                                                        .white24,
                                                                color: Colors
                                                                    .redAccent,
                                                              ),
                                                        )
                                                      : item.lastPositionMs > 0
                                                      ? LinearProgressIndicator(
                                                          value:
                                                              (item.lastPositionMs /
                                                                      item.durationMs)
                                                                  .clamp(
                                                                    0.0,
                                                                    1.0,
                                                                  ),
                                                          backgroundColor:
                                                              Colors.white24,
                                                          color:
                                                              Colors.redAccent,
                                                        )
                                                      : const SizedBox.shrink(),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      SizedBox(width: itemGap * 1.2),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              BilibiliWatchPlaylistSession.titleOf(
                                                item,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: isCurrent
                                                    ? Colors.white
                                                    : Colors.white70,
                                                fontWeight: isCurrent
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                                fontSize: titleFontSize,
                                                height: 1.3,
                                              ),
                                            ),
                                            SizedBox(
                                              height: (panelHeight * 0.008)
                                                  .clamp(2.0, 6.0),
                                            ),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 4,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: [
                                                Text(
                                                  item.sourceRef?.cloudDrive !=
                                                              null &&
                                                          item.durationMs <= 0
                                                      ? '时长未知'
                                                      : _formatDuration(
                                                          Duration(
                                                            milliseconds:
                                                                item.durationMs,
                                                          ),
                                                        ),
                                                  style: TextStyle(
                                                    color: Colors.white38,
                                                    fontSize: subFontSize,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                if (isCurrent ||
                                                    isPending ||
                                                    item.id == chrome.nextId)
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 3,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: Colors.white
                                                          .withValues(
                                                            alpha: 0.15,
                                                          ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      isPending
                                                          ? '准备中'
                                                          : playbackService
                                                                    .queueItemStatus(
                                                                      item.id,
                                                                    ) ??
                                                                '播放中',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize:
                                                            currentTagFontSize,
                                                      ),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      PlaybackQueueRemoveButton(
                                        key: ValueKey(
                                          'queue-remove-${item.id}',
                                        ),
                                        title:
                                            BilibiliWatchPlaylistSession.titleOf(
                                              item,
                                            ),
                                        onPressed: () =>
                                            removePlaybackQueueItem(
                                              context.read<PlaylistManager>(),
                                              item,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
