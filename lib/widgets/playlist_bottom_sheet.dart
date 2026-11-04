import 'dart:async';

import 'package:flutter/material.dart';
import '../models/video_item.dart';
import '../features/podcasts/podcast_queue_artwork.dart';
import '../services/bilibili/bilibili_watch_playlist.dart';
import 'cached_thumbnail_widget.dart';
import 'bilibili_queue_thumbnail.dart';
import 'cloud_drive_queue_preview.dart';
import 'playback_queue_remove_button.dart';
import 'playback_queue_sort_controls.dart';
import 'playback_mode_button.dart';
import '../services/playback_queue_actions.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// 播放列表底部弹窗组件
class PlaylistBottomSheet extends StatefulWidget {
  /// 播放列表
  final List<VideoItem> playlist;

  /// 当前播放项ID
  final String? currentItemId;

  /// 点击列表项回调
  final Function(VideoItem) onItemTap;

  final ValueChanged<VideoItem>? onItemRemove;
  final ValueChanged<List<String>>? onOrderChanged;
  final VoidCallback? onReverse, onResetOrder;
  final bool hasCustomOrder, isShuffle;
  final bool showPlaybackModeButton;

  /// 滚动控制器（用于 DraggableScrollableSheet）
  final ScrollController? scrollController;
  final Map<String, String> itemStatuses;

  /// Retained for existing callers; visible numbering always follows [playlist].
  final Map<String, int> originalPositions;

  const PlaylistBottomSheet({
    super.key,
    required this.playlist,
    this.currentItemId,
    required this.onItemTap,
    this.onItemRemove,
    this.onOrderChanged,
    this.onReverse,
    this.onResetOrder,
    this.hasCustomOrder = false,
    this.isShuffle = false,
    this.showPlaybackModeButton = false,
    this.scrollController,
    this.itemStatuses = const {},
    this.originalPositions = const {},
  });

  @override
  State<PlaylistBottomSheet> createState() => _PlaylistBottomSheetState();
}

class _PlaylistBottomSheetState extends State<PlaylistBottomSheet> {
  /// 当前行中心落在列表视口的这个高度上。比正中略靠上，下面还能看到接下来要播的几条。
  /// 列表头尾几条滚不到这里时，就停在滚动范围的边界上，不再硬凑这个位置。
  static const double _currentItemViewportFraction = 0.30;

  final GlobalKey _listViewKey = GlobalKey();
  final GlobalKey _currentItemKey = GlobalKey();

  /// 弹窗外面没传入控制器时自己持有一个，这样打开时才能把当前项滚进视口。
  ScrollController? _ownedController;

  bool _userScrolled = false;
  bool _applyingScroll = false;
  bool _alignScheduled = false;
  List<VideoItem>? _dragPlaylist;

  ScrollController get _scrollController =>
      widget.scrollController ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.scrollController == null) {
      _ownedController = ScrollController();
    }
    // 打开播放列表时定位一次。之后用户自己滑动，或列表在弹窗里刷新，都不再抢滚动位置。
    _scheduleAlign(0);
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  void _scheduleAlign(int attempt) {
    if (_alignScheduled || _userScrolled) return;
    _alignScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _alignScheduled = false;
      _alignCurrentItem(attempt);
    });
  }

  int? _currentIndex() {
    final id = widget.currentItemId;
    if (id == null) return null;
    final index = widget.playlist.indexWhere((item) => item.id == id);
    return index >= 0 ? index : null;
  }

  /// 懒加载列表还没把当前行建出来时，先按序号比例跳到附近，下一帧再细调。
  void _jumpToRoughOffset(int index, int totalCount) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions || totalCount <= 1) return;
    final maxExtent = position.maxScrollExtent;
    final roughOffset = (index / (totalCount - 1)) * maxExtent;
    _jumpTo(roughOffset.clamp(0.0, maxExtent).toDouble());
  }

  void _jumpTo(double offset) {
    if (!_scrollController.hasClients) return;
    if ((_scrollController.offset - offset).abs() <= 0.5) return;
    _applyingScroll = true;
    _scrollController.jumpTo(offset);
    _applyingScroll = false;
  }

  void _alignCurrentItem(int attempt) {
    if (!mounted || _userScrolled || attempt > 12) return;
    final index = _currentIndex();
    final totalCount = widget.playlist.length;
    if (index == null || totalCount == 0) return;
    if (!_scrollController.hasClients ||
        !_scrollController.position.hasContentDimensions) {
      _scheduleAlign(attempt + 1);
      return;
    }

    final itemContext = _currentItemKey.currentContext;
    final listContext = _listViewKey.currentContext;
    if (itemContext == null || listContext == null) {
      _jumpToRoughOffset(index, totalCount);
      _scheduleAlign(attempt + 1);
      return;
    }

    final itemBox = itemContext.findRenderObject() as RenderBox?;
    final listBox = listContext.findRenderObject() as RenderBox?;
    if (itemBox == null ||
        !itemBox.hasSize ||
        listBox == null ||
        !listBox.hasSize ||
        listBox.size.height <= 0) {
      _scheduleAlign(attempt + 1);
      return;
    }

    // 用列表视口而不是整张弹窗：标题栏不参与滚动，当前视频要对齐的是用户正在看的那一段列表。
    final itemTop = itemBox.localToGlobal(Offset.zero, ancestor: listBox).dy;
    final targetCenterY = listBox.size.height * _currentItemViewportFraction;
    final currentCenterY = itemTop + itemBox.size.height / 2;
    final maxExtent = _scrollController.position.maxScrollExtent;
    final targetOffset =
        (_scrollController.offset + currentCenterY - targetCenterY)
            .clamp(0.0, maxExtent)
            .toDouble();
    final moved = (targetOffset - _scrollController.offset).abs() > 0.5;
    if (moved) {
      _jumpTo(targetOffset);
    }
    // 弹窗高度还在变、或跳转要等下一帧才反映到布局上时，再量一次。偏移已经对上就停。
    if (moved && attempt < 12) {
      _scheduleAlign(attempt + 1);
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (_applyingScroll) return false;
    // 只有手指拖动才算用户接管。定位用的 jumpTo 没有 dragDetails，不会把自己取消掉。
    final drag = switch (notification) {
      ScrollStartNotification(:final dragDetails) => dragDetails,
      ScrollUpdateNotification(:final dragDetails) => dragDetails,
      _ => null,
    };
    if (drag != null) {
      _userScrolled = true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C2C),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16.0)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 16.0,
            offset: const Offset(0, -4),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部拖动指示器
          _buildDragHandle(),

          // 标题栏
          _buildHeader(),

          // 播放列表
          _buildPlaylist(context),
        ],
      ),
    );
  }

  /// 构建拖动指示器
  Widget _buildDragHandle() {
    return Container(
      margin: const EdgeInsets.only(top: 12.0),
      width: 40.0,
      height: 4.0,
      decoration: BoxDecoration(
        color: Colors.white24,
        borderRadius: BorderRadius.circular(2.0),
      ),
    );
  }

  /// 构建标题栏
  Widget _buildHeader() {
    final bilibiliList = BilibiliWatchPlaylistSession.instance;
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: PlaybackQueueHeader(
        title: '播放列表 (${widget.playlist.length})',
        compactTitle: widget.showPlaybackModeButton
            ? '队列 (${widget.playlist.length})'
            : null,
        titleStyle: const TextStyle(
          fontSize: 18,
          height: 1.2,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
        leading: const Icon(Icons.queue_music, color: Colors.white, size: 24),
        canReverse: widget.onReverse != null && widget.playlist.length > 1,
        canReset: widget.hasCustomOrder && widget.onResetOrder != null,
        onReverse: widget.onReverse ?? () {},
        onReset: widget.onResetOrder ?? () {},
        beforeSort: widget.showPlaybackModeButton
            ? const PlaybackModeButton(
                key: ValueKey('mini-playlist-playback-mode'),
                size: Size.square(48),
                iconSize: 20,
              )
            : null,
        separateSecondaryActions: bilibiliList?.isActive ?? false,
        secondaryActions: [
          if (bilibiliList != null && bilibiliList.isActive)
            BilibiliPlaylistClearButton(session: bilibiliList),
        ],
      ),
    );
  }

  /// 构建播放列表
  Widget _buildPlaylist(BuildContext context) {
    if (widget.playlist.isEmpty) {
      return _buildEmptyState();
    }

    return Flexible(
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: PlaybackQueueListView(
          key: _listViewKey,
          controller: _scrollController,
          shrinkWrap: true,
          itemCount: widget.playlist.length,
          onReorderStart: (_) {
            _userScrolled = true;
            _dragPlaylist = List.of(widget.playlist);
          },
          onReorder: widget.onOrderChanged == null
              ? null
              : (oldIndex, newIndex) {
                  widget.onOrderChanged!(
                    reorderedQueueItemIds(
                      _dragPlaylist ?? widget.playlist,
                      oldIndex,
                      newIndex,
                    ),
                  );
                  _dragPlaylist = null;
                },
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = widget.playlist.indexWhere(
              (item) => item.id == key.value,
            );
            return index < 0 ? null : index;
          },
          padding: const EdgeInsets.only(bottom: 16.0),
          itemBuilder: (context, index) {
            final item = widget.playlist[index];
            final isCurrent = item.id == widget.currentItemId;

            return CloudDriveQueuePreview(
              key: ValueKey(item.id),
              item: item,
              builder: (context) =>
                  _buildPlaylistItem(context, item, isCurrent, index),
            );
          },
        ),
      ),
    );
  }

  /// 构建播放列表项
  Widget _buildPlaylistItem(
    BuildContext context,
    VideoItem item,
    bool isCurrent,
    int displayIndex,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          widget.onItemTap(item);
        },
        child: Container(
          key: isCurrent ? _currentItemKey : null,
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          decoration: BoxDecoration(
            color: isCurrent
                ? Colors.blue.withValues(alpha: 0.1)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: isCurrent ? Colors.blue : Colors.transparent,
                width: 4.0,
              ),
            ),
          ),
          child: Row(
            children: [
              // 序号或播放图标
              if (widget.onOrderChanged == null)
                _buildLeadingIcon(isCurrent, displayIndex)
              else
                PlaybackQueueDragHandle(
                  key: ValueKey('queue-drag-${item.id}'),
                  index: displayIndex,
                  isCurrent: isCurrent,
                  title: BilibiliWatchPlaylistSession.titleOf(item),
                  enabled: widget.playlist.length > 1,
                  onMoveUp: displayIndex > 0
                      ? () => widget.onOrderChanged!(
                          reorderedQueueItemIds(
                            widget.playlist,
                            displayIndex,
                            displayIndex - 1,
                          ),
                        )
                      : null,
                  onMoveDown: displayIndex < widget.playlist.length - 1
                      ? () => widget.onOrderChanged!(
                          reorderedQueueItemIds(
                            widget.playlist,
                            displayIndex,
                            displayIndex + 1,
                          ),
                        )
                      : null,
                ),

              SizedBox(width: widget.onOrderChanged == null ? 12 : 4),

              // 缩略图
              _buildThumbnail(item),

              const SizedBox(width: 12.0),

              // 标题和时长信息
              Expanded(child: _buildItemInfo(item, isCurrent)),

              if (widget.onItemRemove != null) ...[
                const SizedBox(width: 8),
                PlaybackQueueRemoveButton(
                  key: ValueKey('queue-remove-${item.id}'),
                  title: BilibiliWatchPlaylistSession.titleOf(item),
                  onPressed: () => widget.onItemRemove!(item),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 构建前导图标
  Widget _buildLeadingIcon(bool isCurrent, int index) {
    return SizedBox(
      width: 32.0,
      height: 32.0,
      child: Center(
        child: Text(
          '${index + 1}',
          key: const ValueKey('queue-position'),
          style: TextStyle(
            color: isCurrent ? Colors.blue : Colors.white54,
            fontSize: 14.0,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 构建缩略图
  Widget _buildThumbnail(VideoItem item) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12.0),
      child: Container(
        width: 60.0,
        height: 45.0,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 4.0,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: item.sourceRef?.podcast != null
            ? PodcastQueueArtwork(
                item: item,
                size: 60,
                placeholder: _buildAudioThumbnailPlaceholder(),
              )
            : item.type == MediaType.audio
            ? _buildAudioThumbnail(item)
            : _buildVideoThumbnail(item),
      ),
    );
  }

  /// 构建音频缩略图（优先显示封面图，无封面则显示占位图标）
  Widget _buildAudioThumbnail(VideoItem item) {
    if (item.thumbnailPath != null && item.thumbnailPath!.isNotEmpty) {
      return CachedThumbnailWidget(
        videoId: item.id,
        thumbnailPath: item.thumbnailPath,
        fit: BoxFit.cover,
        cacheWidth: 120,
        cacheHeight: 90,
        placeholder: _buildAudioThumbnailPlaceholder(),
        errorWidget: _buildAudioThumbnailPlaceholder(),
      );
    }
    return _buildAudioThumbnailPlaceholder();
  }

  Widget _buildAudioThumbnailPlaceholder() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: const Icon(Icons.music_note, size: 24.0, color: Colors.blue),
    );
  }

  /// 构建视频缩略图
  Widget _buildVideoThumbnail(VideoItem item) {
    return BilibiliQueueThumbnail(
      item: item,
      cacheWidth: 120,
      cacheHeight: 90,
      placeholder: _buildThumbnailPlaceholder(),
    );
  }

  /// 构建缩略图占位符
  Widget _buildThumbnailPlaceholder() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: const Icon(Icons.video_library, size: 24.0, color: Colors.white54),
    );
  }

  /// 构建项目信息
  Widget _buildItemInfo(VideoItem item, bool isCurrent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题
        Text(
          BilibiliWatchPlaylistSession.titleOf(item),
          style: TextStyle(
            color: isCurrent ? Colors.blue : Colors.white,
            fontSize: 14.0,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),

        const SizedBox(height: 4.0),

        // 时长信息
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              item.sourceRef?.cloudDrive != null && item.durationMs <= 0
                  ? '时长未知'
                  : _formatDuration(Duration(milliseconds: item.durationMs)),
              style: const TextStyle(color: Colors.white54, fontSize: 12.0),
            ),
            if (isCurrent || widget.itemStatuses.containsKey(item.id))
              _buildCurrentIndicator(
                widget.itemStatuses[item.id] ?? '播放中',
                isCurrent: isCurrent,
              ),
          ],
        ),
      ],
    );
  }

  /// 构建当前播放指示器
  Widget _buildCurrentIndicator(String label, {required bool isCurrent}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      decoration: BoxDecoration(
        color: isCurrent ? Colors.blue : Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12.0),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10.0,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// 构建空状态
  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(32.0),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.queue_music, size: 64.0, color: Colors.white24),
          SizedBox(height: 16.0),
          Text(
            '播放列表为空',
            style: TextStyle(color: Colors.white54, fontSize: 16.0),
          ),
        ],
      ),
    );
  }

  /// 格式化时长
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
}

/// 「清空」 and, for a few seconds after, the inline 「撤销」.
class BilibiliPlaylistClearButton extends StatelessWidget {
  const BilibiliPlaylistClearButton({
    super.key,
    required this.session,
    this.fontSize,
  });

  final BilibiliWatchPlaylistSession session;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: session.undoOffered,
      builder: (context, offered, _) {
        if (!offered) {
          return DesktopButtonClickRegion(
            child: TextButton(
              key: const ValueKey('bilibili-playlist-clear'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white70,
                visualDensity: VisualDensity.compact,
                splashFactory: NoSplash.splashFactory,
              ),
              onPressed: () => unawaited(clearBilibiliWatchPlaylist(session)),
              child: Text('清空', style: TextStyle(fontSize: fontSize)),
            ),
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '已清空播放列表',
              style: TextStyle(color: Colors.white70, fontSize: fontSize ?? 12),
            ),
            DesktopButtonClickRegion(
              child: TextButton(
                key: const ValueKey('bilibili-playlist-undo'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                  splashFactory: NoSplash.splashFactory,
                ),
                onPressed: () => unawaited(session.undoClear()),
                child: Text('撤销', style: TextStyle(fontSize: fontSize)),
              ),
            ),
          ],
        );
      },
    );
  }
}
