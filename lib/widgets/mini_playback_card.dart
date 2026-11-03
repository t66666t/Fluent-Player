import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/video_item.dart';
import '../services/media_playback_service.dart';
import '../services/drag_haptic_session.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../services/playlist_manager.dart';
import 'playback_card_layout.dart';
import 'playback_mode_button.dart';
import 'playlist_bottom_sheet.dart';
import '../services/playback_queue_actions.dart';
import '../models/playback_mode.dart';
import 'cached_thumbnail_widget.dart';
import 'bilibili_queue_thumbnail.dart';
import '../utils/app_toast.dart';
import '../theme/app_tokens.dart';

/// 底部播放卡片组件
class MiniPlaybackCard extends StatefulWidget {
  /// 是否显示卡片
  final bool isVisible;

  /// 点击卡片回调（用于进入全屏播放）
  final VoidCallback? onTap;

  const MiniPlaybackCard({super.key, required this.isVisible, this.onTap});

  @override
  State<MiniPlaybackCard> createState() => _MiniPlaybackCardState();
}

class _MiniPlaybackCardState extends State<MiniPlaybackCard>
    with TickerProviderStateMixin, RouteAware {
  late AnimationController _slideController;
  late Animation<Offset> _slideAnimation;
  late AnimationController _scrollController;
  late Animation<double> _scrollAnimation;
  bool _titleOverflows = false;
  bool _titleTickersEnabled = true;
  (String, String)? _scrollTitle;

  // 进度条拖动状态
  bool _isDraggingProgress = false;
  bool _isProgressDragCanceling = false;
  bool _progressDragWasCancelled = false;
  final _progressHaptics = DragHapticSession();
  double _dragProgressValue = 0.0;
  PageRoute<dynamic>? _observedRoute;
  bool _routeIsCurrent = true;
  Widget? _lastVisibleCard;
  Widget? _lastVisibleProgress;

  static const Duration _tooltipWaitDuration = Duration(milliseconds: 450);

  /// 点按高亮会跟着路由 ticker 走。播放页盖住媒体库后 ticker 停住，
  /// 返回时才把没播完的高亮淡掉，卡片就会从亮闪回暗色。
  static const WidgetStateProperty<Color?> _noTapOverlay =
      WidgetStatePropertyAll<Color?>(Colors.transparent);

  @override
  void initState() {
    super.initState();

    // 初始化滑入/滑出动画控制器
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _slideAnimation =
        Tween<Offset>(
          begin: const Offset(0, 1), // 从底部开始
          end: Offset.zero, // 滑到正常位置
        ).animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeInOut),
        );

    // 初始化标题滚动动画控制器
    _scrollController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );

    _scrollAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(_scrollController);

    // 根据初始可见性状态设置动画：
    // 挂载时已可见则从底部播放滑入动画，而不是直接跳到最终位置，
    // 保证退出播放页返回媒体库、或卡片因状态更新重新出现时平滑过渡。
    if (widget.isVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isVisible) {
          _slideController.forward();
        }
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _titleTickersEnabled = TickerMode.valuesOf(context).enabled;
    _syncTitleTicker();
    final route = ModalRoute.of(context);
    if (route != _observedRoute) {
      AppToast.routeObserver.unsubscribe(this);
      _observedRoute = route is PageRoute<dynamic> ? route : null;
      if (_observedRoute != null) {
        AppToast.routeObserver.subscribe(this, _observedRoute!);
      }
    }
    // RouteObserver does not report every remove/replace operation. Reading
    // the route dependency on every change also recovers from rapid navigation.
    _setRouteCurrent(route?.isCurrent ?? true);
    _syncMiniPlaybackVisibility();
  }

  void _syncTitleTicker() {
    if (widget.isVisible && _titleOverflows && _titleTickersEnabled) {
      if (!_scrollController.isAnimating) _scrollController.repeat();
    } else if (_scrollController.isAnimating) {
      // Muting a ticker still lets time elapse. Stop the simulation as well so
      // revealing the card resumes at the last painted title position.
      _scrollController.stop();
    }
  }

  void _setRouteCurrent(bool current) {
    if (_routeIsCurrent == current) return;
    if (!current) _progressHaptics.reset();
    setState(() => _routeIsCurrent = current);
    // Covered tickers can be paused halfway through an entrance. The route
    // transition already animates the card, so return with its slide settled.
    _slideController.value = widget.isVisible ? 1.0 : 0.0;
  }

  void _syncMiniPlaybackVisibility() {
    MediaPlaybackService().setMiniPlaybackCardVisible(
      this,
      widget.isVisible && _routeIsCurrent,
    );
  }

  @override
  void didUpdateWidget(MiniPlaybackCard oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 隐藏时直接归零，不能依赖滑出动画：底部安全区、间距和向上的
    // 阴影会让只移动一个卡片高度的内容仍然露边，路由盖住时 ticker
    // 也可能停在半路。开启时仍保留滑入动画。
    if (widget.isVisible != oldWidget.isVisible) {
      _syncMiniPlaybackVisibility();
      if (!widget.isVisible) {
        _slideController.value = 0.0;
        _titleOverflows = false;
        _scrollController.reset();
        _isDraggingProgress = false;
        _isProgressDragCanceling = false;
        _progressHaptics.reset();
      } else if (!_routeIsCurrent) {
        _slideController.value = 1.0;
      } else {
        _slideController.forward();
      }
    }
  }

  @override
  void dispose() {
    _progressHaptics.reset();
    MediaPlaybackService().setMiniPlaybackCardVisible(this, false);
    if (_observedRoute != null) {
      AppToast.routeObserver.unsubscribe(this);
    }
    _slideController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didPush() {
    _setRouteCurrent(true);
    _syncMiniPlaybackVisibility();
  }

  @override
  void didPopNext() {
    _setRouteCurrent(true);
    _syncMiniPlaybackVisibility();
  }

  @override
  void didPushNext() {
    _setRouteCurrent(false);
    _syncMiniPlaybackVisibility();
  }

  @override
  void didPop() {
    _setRouteCurrent(false);
    _syncMiniPlaybackVisibility();
  }

  /// 判断拖动是否处于取消区域
  bool _isInCancelArea(Offset globalPosition) {
    if (!mounted) return false;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return false;
    final localOffset = box.globalToLocal(globalPosition);
    // 向上滑动超出卡片顶部 30 像素时视为取消
    return localOffset.dy < -30.0;
  }

  @override
  Widget build(BuildContext context) {
    // 关闭后不布局、绘制或命中卡片（包括阴影），与设备安全区无关。
    if (!widget.isVisible) {
      _lastVisibleCard = null;
      _lastVisibleProgress = null;
      return const SizedBox.shrink();
    }

    return RepaintBoundary(
      child: SlideTransition(
        position: _slideAnimation,
        child: Consumer<MediaPlaybackService>(
          builder: (context, playbackService, child) {
            // Keep the outgoing page's card stable while the new page zooms
            // over it. Refresh from the live session as soon as it is revealed.
            if (!_routeIsCurrent) {
              return _lastVisibleCard ?? const SizedBox.shrink();
            }
            final currentItem = playbackService.queuedPreviewItem;

            // 如果没有当前播放项，返回空容器
            if (currentItem == null) {
              return const SizedBox.shrink();
            }

            // 获取响应式布局尺寸
            final dimensions = PlaybackCardLayout.calculate(context);

            return _lastVisibleCard = Container(
              constraints: BoxConstraints(maxHeight: dimensions.height),
              decoration: BoxDecoration(
                color: AppTokens.bgCard,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16.0),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12.0,
                    offset: const Offset(0, -4),
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: widget.onTap == null
                      ? null
                      : () {
                          unawaited(AppHaptics.cardTap(SettingsService()));
                          widget.onTap!();
                        },
                  splashFactory: NoSplash.splashFactory,
                  overlayColor: _noTapOverlay,
                  splashColor: Colors.transparent,
                  highlightColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  focusColor: Colors.transparent,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16.0),
                  ),
                  child: Stack(
                    children: [
                      Container(
                        height: dimensions.height,
                        padding: EdgeInsets.fromLTRB(
                          dimensions.padding +
                              MediaQuery.paddingOf(context).left,
                          dimensions.padding,
                          dimensions.padding +
                              MediaQuery.paddingOf(context).right,
                          dimensions.padding,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            // 第一行：缩略图、标题、列表展开按钮
                            SizedBox(
                              height: PlaybackCardLayout.titleRowHeight(
                                context,
                                dimensions,
                              ),
                              child: _buildFirstRow(
                                context,
                                currentItem,
                                dimensions,
                                playbackService,
                              ),
                            ),

                            SizedBox(height: dimensions.padding / 3),

                            // 新增：字幕显示行
                            _buildSubtitleRow(
                              context,
                              dimensions,
                              playbackService,
                            ),

                            SizedBox(height: dimensions.padding / 3),

                            // 第二行：进度条、控制按钮
                            SizedBox(
                              height: PlaybackCardLayout.transportRowHeight(
                                context,
                                dimensions,
                              ),
                              child: _buildSecondRow(
                                context,
                                dimensions,
                                playbackService,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 取消拖动提示遮罩层
                      if (_isDraggingProgress && _isProgressDragCanceling)
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.75),
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(16.0),
                              ),
                            ),
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.undo,
                                    color: Colors.white,
                                    size: 36,
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    "松手取消跳转",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 构建第一行：缩略图、标题、播放模式、列表展开按钮
  Widget _buildFirstRow(
    BuildContext context,
    VideoItem currentItem,
    PlaybackCardDimensions dimensions,
    MediaPlaybackService playbackService,
  ) {
    return Row(
      children: [
        // 缩略图
        _buildThumbnail(currentItem, dimensions),

        SizedBox(width: dimensions.padding),

        // 标题（带滚动动画）
        Expanded(child: _buildScrollingTitle(currentItem, dimensions)),

        SizedBox(width: dimensions.padding),

        PlaybackModeButton(
          key: const ValueKey('mini-playback-mode'),
          size: Size.square(_resolveButtonSize(dimensions)),
          iconSize: dimensions.iconSize,
          backgroundColor: Colors.white.withValues(alpha: 0.04),
          foregroundColor: Colors.white,
        ),
        SizedBox(width: dimensions.padding / 3),

        // 列表展开按钮
        _buildPlaylistButton(context, dimensions),
      ],
    );
  }

  /// 构建缩略图
  Widget _buildThumbnail(VideoItem item, PlaybackCardDimensions dimensions) {
    final thumbnail = Container(
      width: dimensions.thumbnailSize,
      height: dimensions.thumbnailSize,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 4.0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12.0),
        child: item.type == MediaType.audio
            ? _buildAudioThumbnail(item, dimensions)
            : _buildVideoThumbnail(item, dimensions),
      ),
    );
    // Online Bilibili buffering chrome is retired. Download/cache
    // progress lives on the download screen, not Mini.
    return thumbnail;
  }

  /// 构建音频缩略图（优先显示封面图，无封面则显示占位图标）
  Widget _buildAudioThumbnail(
    VideoItem item,
    PlaybackCardDimensions dimensions,
  ) {
    if (item.thumbnailPath != null && item.thumbnailPath!.isNotEmpty) {
      return CachedThumbnailWidget(
        videoId: item.id,
        thumbnailPath: item.thumbnailPath,
        fit: BoxFit.cover,
        cacheWidth: (dimensions.thumbnailSize * 2).toInt(),
        cacheHeight: (dimensions.thumbnailSize * 2).toInt(),
        placeholder: _buildAudioThumbnailPlaceholder(dimensions),
        errorWidget: _buildAudioThumbnailPlaceholder(dimensions),
      );
    }
    return _buildAudioThumbnailPlaceholder(dimensions);
  }

  Widget _buildAudioThumbnailPlaceholder(PlaybackCardDimensions dimensions) {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Icon(
        Icons.music_note,
        size: dimensions.thumbnailSize * 0.5,
        color: Colors.blue,
      ),
    );
  }

  /// 构建视频缩略图
  Widget _buildVideoThumbnail(
    VideoItem item,
    PlaybackCardDimensions dimensions,
  ) {
    return BilibiliQueueThumbnail(
      item: item,
      cacheWidth: (dimensions.thumbnailSize * 2).toInt(),
      cacheHeight: (dimensions.thumbnailSize * 2).toInt(),
      placeholder: _buildThumbnailPlaceholder(dimensions),
    );
  }

  /// 构建缩略图占位符
  Widget _buildThumbnailPlaceholder(PlaybackCardDimensions dimensions) {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Icon(
        Icons.video_library,
        size: dimensions.thumbnailSize * 0.5,
        color: Colors.white54,
      ),
    );
  }

  /// 构建滚动标题
  Widget _buildScrollingTitle(
    VideoItem item,
    PlaybackCardDimensions dimensions,
  ) {
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Measure with exactly the style, scaling and locale Text paints.
          // Otherwise the two copies do not meet at the same point each loop.
          final style = DefaultTextStyle.of(context).style.merge(
            TextStyle(fontSize: dimensions.titleFontSize, color: Colors.white),
          );
          final textDirection = Directionality.of(context);
          final textScaler = MediaQuery.textScalerOf(context);
          final locale = Localizations.maybeLocaleOf(context);
          final textPainter = TextPainter(
            text: TextSpan(text: item.title, style: style),
            maxLines: 1,
            textDirection: textDirection,
            textScaler: textScaler,
            locale: locale,
          )..layout();

          final textWidth = textPainter.width;
          textPainter.dispose();
          final containerWidth = constraints.maxWidth;
          final title = (item.id, item.title);
          if (_scrollTitle != title) {
            _scrollTitle = title;
            _scrollController.reset();
          }
          _titleOverflows = textWidth > containerWidth;
          _syncTitleTicker();

          // 如果文本宽度超过容器宽度，启用滚动
          if (_titleOverflows) {
            final text = Text(
              item.title,
              style: style,
              textDirection: textDirection,
              textScaler: textScaler,
              locale: locale,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
            );
            return ClipRect(
              child: OverflowBox(
                alignment: Alignment.centerLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                child: AnimatedBuilder(
                  animation: _scrollAnimation,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    textDirection: TextDirection.ltr,
                    children: [
                      text,
                      const SizedBox(width: 50),
                      ExcludeSemantics(child: text),
                    ],
                  ),
                  builder: (context, child) {
                    final offset = _scrollAnimation.value * (textWidth + 50);
                    return Transform.translate(
                      offset: Offset(-offset, 0),
                      transformHitTests: false,
                      child: child,
                    );
                  },
                ),
              ),
            );
          } else {
            // 文本宽度未超过容器，停止滚动动画
            if (_scrollController.value != 0) {
              _scrollController.reset();
            }

            return Text(
              item.title,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          }
        },
      ),
    );
  }

  /// 构建播放列表按钮
  Widget _buildPlaylistButton(
    BuildContext context,
    PlaybackCardDimensions dimensions,
  ) {
    return _buildActionButton(
      icon: Icons.queue_music,
      tooltip: '播放列表',
      onPressed: () {
        _showPlaylistBottomSheet(context);
      },
      iconSize: dimensions.iconSize,
      buttonSize: _resolveButtonSize(dimensions),
    );
  }

  /// 显示播放列表弹窗
  void _showPlaylistBottomSheet(BuildContext context) {
    final playbackService = Provider.of<MediaPlaybackService>(
      context,
      listen: false,
    );
    final playlistManager = Provider.of<PlaylistManager>(
      context,
      listen: false,
    );

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            // Follows the queue while open (the Bilibili list's 「清空」).
            return ListenableBuilder(
              listenable: Listenable.merge([playlistManager, playbackService]),
              builder: (context, _) => PlaylistBottomSheet(
                showPlaybackModeButton: true,
                playlist: playlistManager.playbackQueue,
                currentItemId: playbackService.currentItem?.id,
                itemStatuses: playbackService.queueItemStatuses,
                originalPositions: {
                  for (
                    var index = 0;
                    index < playlistManager.playlist.length;
                    index++
                  )
                    playlistManager.playlist[index].id: index,
                },
                scrollController: scrollController,
                onItemRemove: (item) =>
                    removePlaybackQueueItem(playlistManager, item),
                onOrderChanged: (ids) =>
                    reorderPlaybackQueue(playlistManager, ids),
                onReverse: () => reversePlaybackQueue(playlistManager),
                onResetOrder: () => resetPlaybackQueueOrder(playlistManager),
                hasCustomOrder: playlistManager.hasCustomOrder,
                isShuffle: playlistManager.playbackMode == PlaybackMode.shuffle,
                onItemTap: (item) {
                  Navigator.pop(context);
                  playbackService.playPlaylistItem(item);
                },
              ),
            );
          },
        );
      },
    );
  }

  /// 构建第二行：进度条、控制按钮
  Widget _buildSecondRow(
    BuildContext context,
    PlaybackCardDimensions dimensions,
    MediaPlaybackService playbackService,
  ) {
    // Consume taps in the whole control strip. This prevents the card's
    // navigation InkWell from winning when a finger lands in a small gap
    // between the transport buttons.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: () {},
      child: Row(
        children: [
          // 进度条
          Expanded(
            child: ValueListenableBuilder<Duration>(
              valueListenable: playbackService.coarsePositionNotifier,
              builder: (_, position, _) {
                if (!_routeIsCurrent) {
                  return _lastVisibleProgress ?? const SizedBox.shrink();
                }
                return _lastVisibleProgress = _buildProgressBar(
                  playbackService,
                  position,
                );
              },
            ),
          ),

          SizedBox(width: dimensions.padding / 2),

          // 控制按钮
          _buildControlButtons(context, dimensions, playbackService),
        ],
      ),
    );
  }

  /// 构建进度条
  Widget _buildProgressBar(
    MediaPlaybackService playbackService,
    Duration position,
  ) {
    final duration = playbackService.duration;

    // 如果正在拖动，使用拖动的进度
    final currentProgress = _isDraggingProgress
        ? _dragProgressValue
        : (duration.inMilliseconds > 0
              ? position.inMilliseconds / duration.inMilliseconds
              : 0.0);

    final displayPosition = _isDraggingProgress
        ? Duration(
            milliseconds: (_dragProgressValue * duration.inMilliseconds)
                .round(),
          )
        : position;

    return RepaintBoundary(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 进度条
          SizedBox(
            height: 27.0,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _progressHaptics.pointerDown,
              onPointerMove: (event) {
                _progressHaptics.pointerMove(event);
                if (!_isDraggingProgress) return;
                final isInCancelArea = _isInCancelArea(event.position);
                if (isInCancelArea != _isProgressDragCanceling) {
                  _progressHaptics.setCanceling(isInCancelArea);
                  setState(() {
                    _isProgressDragCanceling = isInCancelArea;
                  });
                }
              },
              onPointerCancel: (event) {
                _progressHaptics.reset();
                _progressDragWasCancelled = true;
                if (!_isDraggingProgress) return;
                setState(() {
                  _isDraggingProgress = false;
                  _isProgressDragCanceling = false;
                });
              },
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 2.0,
                  trackShape: const RoundedRectSliderTrackShape(),
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 4.0,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 10.0,
                  ),
                  activeTrackColor: _isProgressDragCanceling
                      ? Colors.grey
                      : Colors.blue,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: _isProgressDragCanceling
                      ? Colors.grey
                      : Colors.blue,
                  overlayColor: _isProgressDragCanceling
                      ? Colors.grey.withValues(alpha: 0.2)
                      : Colors.blue.withValues(alpha: 0.2),
                ),
                child: Slider(
                  // Preserve the current compact thumb until its replacement
                  // has matching geometry in the mini-player layout.
                  // ignore: deprecated_member_use
                  year2023: true,
                  padding: EdgeInsets.zero,
                  value: currentProgress.clamp(0.0, 1.0),
                  onChangeStart: (value) {
                    _progressDragWasCancelled = false;
                    if (duration > Duration.zero) _progressHaptics.begin(value);
                    setState(() {
                      _isDraggingProgress = true;
                      _isProgressDragCanceling = false;
                      _dragProgressValue = value;
                    });
                  },
                  onChanged: (value) {
                    _progressHaptics.update(value);
                    setState(() {
                      _isDraggingProgress = true;
                      _dragProgressValue = value;
                    });
                  },
                  onChangeEnd: (value) {
                    final commit =
                        !_isProgressDragCanceling && !_progressDragWasCancelled;
                    _progressHaptics.end(committed: commit);
                    if (commit) {
                      final newPosition = Duration(
                        milliseconds: (value * duration.inMilliseconds).round(),
                      );
                      playbackService.seekTo(newPosition);
                    }
                    setState(() {
                      _isDraggingProgress = false;
                      _isProgressDragCanceling = false;
                    });
                  },
                ),
              ),
            ),
          ),

          // 进度文字说明
          Padding(
            padding: const EdgeInsets.only(left: 8.0, right: 8.0),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${_formatDuration(displayPosition)} / ${_formatDuration(duration)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 9.0,
                  height: 1.0,
                ),
              ),
            ),
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

  /// 构建控制按钮
  Widget _buildControlButtons(
    BuildContext context,
    PlaybackCardDimensions dimensions,
    MediaPlaybackService playbackService,
  ) {
    final buttonSize = _resolveControlButtonSize(dimensions);
    final primaryButtonSize = _resolvePrimaryControlButtonSize(dimensions);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 上一集按钮
        _buildActionButton(
          icon: Icons.skip_previous,
          tooltip: '上一项',
          onPressed: playbackService.hasPlayablePrevious
              ? () => playbackService.playPrevious()
              : null,
          iconSize: dimensions.iconSize * 0.9,
          buttonSize: buttonSize,
        ),

        SizedBox(width: dimensions.padding / 4), // 减小间距
        // 播放/暂停按钮
        _buildActionButton(
          icon: playbackService.isTransportPlaying
              ? Icons.pause
              : Icons.play_arrow,
          tooltip: playbackService.isTransportPlaying ? '暂停' : '播放',
          onPressed: () {
            if (playbackService.isTransportPlaying) {
              playbackService.pause();
            } else {
              playbackService.resume();
            }
          },
          iconSize: dimensions.iconSize * 1.1,
          buttonSize: primaryButtonSize,
        ),

        SizedBox(width: dimensions.padding / 4), // 减小间距
        // 下一集按钮
        _buildActionButton(
          icon: Icons.skip_next,
          tooltip: '下一项',
          onPressed: playbackService.hasPlayableNext
              ? () => playbackService.playNext()
              : null,
          iconSize: dimensions.iconSize * 0.9,
          buttonSize: buttonSize,
        ),

        SizedBox(width: dimensions.padding / 4), // 减小间距
        // 静音按钮
        _buildActionButton(
          icon: playbackService.isMuted ? Icons.volume_off : Icons.volume_up,
          tooltip: playbackService.isMuted ? '取消静音' : '静音',
          onPressed: () => playbackService.toggleMute(),
          iconSize: dimensions.iconSize * 0.9,
          buttonSize: _resolveButtonSize(dimensions),
        ),
      ],
    );
  }

  /// 构建字幕显示行
  Widget _buildSubtitleRow(
    BuildContext context,
    PlaybackCardDimensions dimensions,
    MediaPlaybackService playbackService,
  ) {
    final currentSubtitle = playbackService.currentSubtitle;
    final hasSubtitles = playbackService.subtitles.isNotEmpty;
    final bool isImageSubtitle =
        currentSubtitle != null &&
        currentSubtitle.text.isEmpty &&
        currentSubtitle.imageLoader != null;
    final String subtitleLabel = currentSubtitle != null
        ? (currentSubtitle.text.isNotEmpty
              ? currentSubtitle.text
              : (isImageSubtitle ? '[图片字幕]' : '当前时刻无字幕'))
        : (hasSubtitles ? '当前时刻无字幕' : '无字幕');
    final bool usePlaceholderStyle =
        currentSubtitle == null || currentSubtitle.text.isEmpty;

    return Container(
      height: _resolveSubtitleRowHeight(dimensions),
      padding: EdgeInsets.symmetric(horizontal: dimensions.padding),
      child: Row(
        children: [
          // 字幕文本（支持横向滚动）
          Expanded(
            child: subtitleLabel.isNotEmpty
                ? SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      subtitleLabel,
                      style: TextStyle(
                        fontSize: dimensions.subtitleFontSize,
                        color: usePlaceholderStyle
                            ? Colors.white38
                            : Colors.white70,
                        height: 1.3,
                        fontStyle: FontStyle.normal,
                      ),
                      maxLines: 1,
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // 字幕导航按钮（仅在有字幕时显示）
          if (hasSubtitles) ...[
            SizedBox(width: dimensions.padding / 3),

            // 上一句字幕按钮 - 使用圆形背景和不同图标
            _buildActionButton(
              icon: Icons.keyboard_arrow_left_rounded,
              tooltip: '上一句字幕',
              onPressed: () => playbackService.seekToPreviousSubtitle(),
              iconSize: dimensions.iconSize * 0.95,
              buttonSize: _resolveSubtitleButtonSize(dimensions),
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),

            SizedBox(width: dimensions.padding / 4),

            // 下一句字幕按钮 - 使用圆形背景和不同图标
            _buildActionButton(
              icon: Icons.keyboard_arrow_right_rounded,
              tooltip: '下一句字幕',
              onPressed: () => playbackService.seekToNextSubtitle(),
              iconSize: dimensions.iconSize * 0.95,
              buttonSize: _resolveSubtitleButtonSize(dimensions),
              backgroundColor: Colors.white.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
          ],
        ],
      ),
    );
  }

  double _resolveButtonSize(PlaybackCardDimensions dimensions) {
    return (dimensions.iconSize + 12.0).clamp(34.0, 38.0);
  }

  double _resolveControlButtonSize(PlaybackCardDimensions dimensions) {
    return (dimensions.iconSize + 16.0).clamp(38.0, 42.0);
  }

  double _resolvePrimaryControlButtonSize(PlaybackCardDimensions dimensions) {
    return (_resolveControlButtonSize(dimensions) + 4.0).clamp(42.0, 46.0);
  }

  double _resolveSubtitleRowHeight(PlaybackCardDimensions dimensions) {
    return PlaybackCardLayout.subtitleRowHeight(context, dimensions);
  }

  double _resolveSubtitleButtonSize(PlaybackCardDimensions dimensions) {
    return dimensions.iconSize >= 26.0 ? 28.0 : 24.0;
  }

  Widget _buildActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    required double iconSize,
    required double buttonSize,
    Color? backgroundColor,
    BoxShape shape = BoxShape.circle,
  }) {
    final bool enabled = onPressed != null;
    final Color resolvedBackgroundColor =
        backgroundColor ??
        (enabled
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.white.withValues(alpha: 0.02));
    final Color iconColor = enabled ? Colors.white : Colors.white38;

    return Tooltip(
      message: tooltip,
      waitDuration: _tooltipWaitDuration,
      child: SizedBox(
        width: buttonSize,
        height: buttonSize,
        child: Material(
          color: resolvedBackgroundColor,
          shape: shape == BoxShape.circle
              ? const CircleBorder()
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(buttonSize * 0.28),
                ),
          clipBehavior: Clip.antiAlias,
          child: InkResponse(
            onTap: onPressed,
            containedInkWell: true,
            highlightShape: shape == BoxShape.circle
                ? BoxShape.circle
                : BoxShape.rectangle,
            radius: buttonSize / 2,
            child: Center(
              child: Icon(icon, size: iconSize, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}
