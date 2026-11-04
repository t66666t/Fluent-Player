import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'cached_thumbnail_widget.dart';
import 'music_cover_video_stage.dart';
import 'music_text_optical_alignment.dart';
import 'music_overflow_text.dart';

/// Apple Music 风格专辑封面卡片组件（响应式 vh 单位）
///
/// 视觉层次（从外到内）：
/// 1. 圆角封面容器（显示实际封面图片 或 音符占位符）
/// 2. 封面下方：歌曲信息（歌名 + 艺术家—专辑）
///
/// 替代原 CD 碟片设计，严格对齐 Apple Music 全屏播放页面截图布局。
/// 所有尺寸基于屏幕高度 (vh) 计算。
/// 交互：横屏下双击视频封面，封面原地翻成正在播放的画面。
class MusicAlbumCover extends StatefulWidget {
  final String? coverImagePath;
  final String title;
  final String artist;
  final String album;

  /// 是否为音频媒体（音频媒体无封面时显示音符占位符）
  final bool isAudio;

  /// 当前条目是视频。切到纯音频时封面会翻回去。
  final bool isVideo;

  /// 横屏且当前是视频时才接收双击。竖屏和纯音频保持静止封面。
  final bool videoGestureEnabled;

  /// 左栏内容宽度。视频只会在这个宽度内变宽，封面高度不变。
  final double? maxVideoWidth;

  /// 媒体唯一标识符（用于通过 ThumbnailCacheService 加载本地封面文件）
  final String? videoId;

  /// 视频控制器。与播放服务共用，画面和进度是同一次播放。
  final VideoPlayerController? videoController;

  /// Test stand-in so the flip can run without a decoded texture.
  final bool debugVideoFramesReady;
  final double? debugVideoAspectRatio;

  /// `2×` while a long-press boost is held, otherwise null.
  final ValueChanged<String?>? onTemporarySpeedChanged;

  /// 封面卡片尺寸（可选）。若不传则基于屏幕高度自动计算。
  /// 由父组件传入可确保在横屏小屏上不超出可用空间。
  final double? coverSize;

  /// Height left after a docked footer has been laid out. Metadata keeps its
  /// readable size; only the artwork yields space. Very short viewports can
  /// scroll the cover and metadata without moving the playback controls.
  final double? maxHeight;

  /// 歌曲信息文本区域宽度（可选）。手机横屏下可大于封面宽度，避免文字拥挤。
  final double? infoWidth;

  /// 是否显示歌曲信息（标题/艺术家）。默认 true。
  /// 设为 false 时仅显示封面图片，不显示下方歌曲信息，
  /// 用于横屏布局中歌曲信息独立显示的场景。
  final bool showSongInfo;

  /// Reclaim vertical whitespace for the artwork on short landscape screens.
  final bool compactSpacing;

  const MusicAlbumCover({
    super.key,
    this.coverImagePath,
    required this.title,
    this.artist = '',
    this.album = '',
    this.isAudio = false,
    this.isVideo = false,
    this.videoGestureEnabled = false,
    this.maxVideoWidth,
    this.videoId,
    this.coverSize,
    this.maxHeight,
    this.infoWidth,
    this.videoController,
    this.debugVideoFramesReady = false,
    this.debugVideoAspectRatio,
    this.onTemporarySpeedChanged,
    this.showSongInfo = true,
    this.compactSpacing = false,
    required void Function() onExitTrigger,
  });

  @override
  State<MusicAlbumCover> createState() => _MusicAlbumCoverState();
}

class _MusicAlbumCoverState extends State<MusicAlbumCover>
    with TickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _scaleController,
      curve: Curves.easeOutBack,
    );
    _scaleController.forward();
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  /// 判断文本是否包含中文（与字幕逻辑一致）
  bool _isChineseText(String text) {
    return RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    // 封面尺寸：优先使用父组件传入的值，否则基于 48vh 自动计算
    var size = widget.coverSize ?? (screenHeight * 0.48).clamp(120.0, 380.0);
    // 封面到歌曲信息间距：~4vh
    final infoGap = widget.compactSpacing
        ? 8.0
        : (screenHeight * 0.04).clamp(12.0, 32.0);
    // 歌曲名字号：~2.5vh
    final titleSize = (screenHeight * 0.025).clamp(13.0, 22.0);
    // 艺术家字号：~2vh
    final artistSize = (screenHeight * 0.02).clamp(11.0, 18.0);
    if (widget.maxHeight case final maxHeight?) {
      final metrics = _songInfoMetrics(titleSize, artistSize);
      final infoHeight = widget.showSongInfo
          ? infoGap +
                metrics.titleHeight +
                metrics.lineGap +
                metrics.artistHeight
          : 0.0;
      size = size.clamp(
        0.0,
        (maxHeight - infoHeight).clamp(48.0, double.infinity),
      );
    }
    // 圆角半径 ~2%
    final borderRadius = size * 0.02;

    return ScaleTransition(
      scale: _scaleAnimation,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildCoverImage(size, borderRadius),
          if (widget.showSongInfo) ...[
            SizedBox(height: infoGap),
            _buildSongInfo(size, titleSize, artistSize),
          ],
        ],
      ),
    );
  }

  /// 封面槽高度固定为 [size]。横屏视频只在槽内翻转、变宽。
  Widget _buildCoverImage(double size, double borderRadius) {
    return MusicCoverVideoStage(
      coverSize: size,
      maxFrameWidth: widget.maxVideoWidth ?? size,
      borderRadius: borderRadius,
      itemId: widget.videoId ?? '',
      isVideo: widget.isVideo,
      gestureEnabled: widget.videoGestureEnabled,
      controller: widget.videoController,
      debugFramesReady: widget.debugVideoFramesReady,
      debugAspectRatio: widget.debugVideoAspectRatio,
      onTemporarySpeedChanged: widget.onTemporarySpeedChanged,
      cover: _buildCoverContent(size),
    );
  }

  /// 封面内容：有 videoId→CachedThumbnailWidget 加载本地封面；
  /// 无路径且音频→音符占位符；否则空白
  Widget _buildCoverContent(double size) {
    final path = widget.coverImagePath;
    final videoId = widget.videoId;

    // 有 videoId 和缩略图路径：使用 CachedThumbnailWidget 加载本地文件封面
    if (videoId != null &&
        videoId.isNotEmpty &&
        path != null &&
        path.isNotEmpty) {
      return CachedThumbnailWidget(
        videoId: videoId,
        thumbnailPath: path,
        fit: BoxFit.cover,
        placeholder: _buildMusicNotePlaceholder(size),
        errorWidget: _buildMusicNotePlaceholder(size),
      );
    }
    // 无封面路径但为音频媒体：显示音符占位符
    if (widget.isAudio) {
      return _buildMusicNotePlaceholder(size);
    }
    // 无封面路径且非音频：显示音符占位符作为通用占位
    return _buildMusicNotePlaceholder(size);
  }

  /// 音频媒体的音符占位符（与媒体管理页面的网格视图风格一致）
  Widget _buildMusicNotePlaceholder(double size) {
    final noteSize = size * 0.22; // 网格视图中50px/200px ≈ 25%
    return Container(
      width: size,
      height: size,
      color: Colors.black,
      child: Icon(
        Icons.music_note,
        size: noteSize.clamp(30.0, 70.0),
        color: Colors.white.withValues(alpha: 0.24),
      ),
    );
  }

  ({double titleHeight, double artistHeight, double lineGap}) _songInfoMetrics(
    double titleSize,
    double artistSize,
  ) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    // 歌曲名到艺术家间距：~0.8vh
    final lineGap = widget.compactSpacing
        ? 4.0
        : (screenHeight * 0.008).clamp(4.0, 10.0);
    final scaler = MediaQuery.textScalerOf(context);
    final titleHeight = scaler.scale(titleSize) * 1.3 * 2;
    final artistHeight = (scaler.scale(artistSize) * 1.4).clamp(
      widget.compactSpacing ? 0.0 : 32.0,
      double.infinity,
    );
    return (
      titleHeight: titleHeight,
      artistHeight: artistHeight,
      lineGap: lineGap,
    );
  }

  /// 2 行歌曲信息（Apple Music 截图风格）
  /// 第1行：歌曲名 — 白色, 居中
  /// 第2行：艺术家 — 专辑名 — 半透明白色, 居中
  Widget _buildSongInfo(double size, double titleSize, double artistSize) {
    final (:titleHeight, :artistHeight, :lineGap) = _songInfoMetrics(
      titleSize,
      artistSize,
    );
    final artistText = [
      widget.artist,
      widget.album,
    ].where((s) => s.isNotEmpty).join(' \u2014 ');
    final displayTitle = widget.title.isNotEmpty ? widget.title : '未知曲目';
    return SizedBox(
      width: widget.infoWidth ?? size,
      height: titleHeight + lineGap + artistHeight,
      child: Column(
        children: [
          SizedBox(
            height: titleHeight,
            child: Center(
              child: MusicTextOpticalAlignment(
                applyCjkRaise: musicTextContainsCjk(displayTitle),
                fontSize: titleSize,
                child: MusicOverflowText(
                  text: displayTitle,
                  style: TextStyle(
                    fontFamily: _isChineseText(displayTitle)
                        ? 'Noto Sans SC'
                        : 'Inter',
                    fontSize: titleSize,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    height: 1.3,
                    letterSpacing: 0.05,
                  ),
                  maxLines: 2,
                ),
              ),
            ),
          ),
          SizedBox(height: lineGap),
          SizedBox(
            height: artistHeight,
            child: Center(
              child: MusicTextOpticalAlignment(
                applyCjkRaise: musicTextContainsCjk(artistText),
                fontSize: artistSize,
                child: MusicOverflowText(
                  text: artistText,
                  style: TextStyle(
                    fontFamily: _isChineseText(artistText)
                        ? 'Noto Sans SC'
                        : 'Inter',
                    fontSize: artistSize,
                    fontWeight: FontWeight.w400,
                    color: Colors.white.withValues(alpha: 0.7),
                    height: 1.4,
                    letterSpacing: 0.03,
                  ),
                  maxLines: 1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
