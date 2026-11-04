import 'dart:async';
import 'dart:ui' show lerpDouble;
import 'package:flutter/material.dart';
import '../services/thumbnail_cache_service.dart';
import 'media_card_preparation.dart';

/// Covers that have already played their entrance. Scrolling back should
/// not run the cascade again.
final Set<String> _revealedCoverKeys = <String>{};

/// Test hook. The set is process-wide so cases do not leak into each other.
@visibleForTesting
void resetMediaCoverRevealMemory() => _revealedCoverKeys.clear();

/// How long a cover waits before its fade, so a grid washes in by row
/// instead of popping as one block.
///
/// Only the first five rows wait. Anything further down was scrolled into
/// view and should fade as soon as it decodes.
Duration mediaCoverRevealDelay({
  required int index,
  required int crossAxisCount,
}) {
  if (index < 0) return Duration.zero;
  final columns = crossAxisCount < 1 ? 1 : crossAxisCount;
  final row = index ~/ columns;
  if (row >= 5) return Duration.zero;
  final column = index % columns;
  // Row gap is long enough to read as a wave; the column gap is a lighter
  // left-to-right trickle inside that row.
  return Duration(milliseconds: row * 72 + column * 36);
}

/// Marks one grid cell so [CachedThumbnailWidget] can join that cascade.
class MediaCoverRevealStamp extends InheritedWidget {
  const MediaCoverRevealStamp({
    super.key,
    required this.index,
    required this.crossAxisCount,
    required super.child,
  });

  final int index;
  final int crossAxisCount;

  static MediaCoverRevealStamp? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<MediaCoverRevealStamp>();
  }

  @override
  bool updateShouldNotify(MediaCoverRevealStamp oldWidget) {
    return index != oldWidget.index ||
        crossAxisCount != oldWidget.crossAxisCount;
  }
}

/// 缓存缩略图组件
///
/// 提供带占位符、淡入动画和错误处理的缩略图显示功能。
/// 使用 ThumbnailCacheService 进行缓存管理，优化内存使用。
class CachedThumbnailWidget extends StatefulWidget {
  /// 视频的唯一标识符
  final String videoId;

  /// 缩略图文件路径，可为null
  final String? thumbnailPath;

  /// 图片填充方式
  final BoxFit fit;

  /// 加载时显示的占位符组件
  final Widget? placeholder;

  /// 加载失败时显示的错误组件
  final Widget? errorWidget;

  /// 缩略图目标宽度（用于ResizeImage优化内存）
  final int? cacheWidth;

  /// 缩略图目标高度（用于ResizeImage优化内存）
  final int? cacheHeight;

  /// 淡入动画持续时间
  final Duration fadeInDuration;

  /// 淡入动画曲线
  final Curve fadeInCurve;

  const CachedThumbnailWidget({
    super.key,
    required this.videoId,
    this.thumbnailPath,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.cacheWidth,
    this.cacheHeight,
    this.fadeInDuration = const Duration(milliseconds: 300),
    this.fadeInCurve = Curves.easeIn,
  });

  @override
  State<CachedThumbnailWidget> createState() => _CachedThumbnailWidgetState();
}

class _CachedThumbnailWidgetState extends State<CachedThumbnailWidget>
    with SingleTickerProviderStateMixin {
  /// 缓存服务实例
  final ThumbnailCacheService _cacheService = ThumbnailCacheService();

  /// 当前加载的ImageProvider
  ImageProvider? _imageProvider;

  /// 加载状态
  _LoadingState _loadingState = _LoadingState.loading;

  /// 是否已dispose
  bool _isDisposed = false;
  MediaCardPreparation? _preparation;
  VoidCallback? _releasePreparation;
  Timer? _prepareDeadline;
  bool _prepareExpired = false;

  void _beginPreparation() {
    if (_preparation == null || _releasePreparation != null) return;
    _releasePreparation = _preparation!.hold();
    _prepareDeadline?.cancel();
    _prepareDeadline = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _prepareExpired = true);
      _finishPreparation();
    });
  }

  void _finishPreparation() {
    _prepareDeadline?.cancel();
    _prepareDeadline = null;
    _releasePreparation?.call();
    _releasePreparation = null;
  }

  /// 当前加载任务的Completer，用于取消操作
  Completer<void>? _loadCompleter;
  ThumbnailLoadRequest? _thumbnailRequest;

  /// 行级出场。没有 [MediaCoverRevealStamp] 的调用方保持原来的即时显示。
  late final AnimationController _reveal;
  MediaCoverRevealStamp? _stamp;

  /// Identity of the cascade already started, so a parent rebuild does not
  /// restart it, and a recycled cell with a new index does.
  String? _clockKey;
  Duration _stagedDelay = Duration.zero;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(vsync: this, duration: widget.fadeInDuration);
    _reveal.addStatusListener(_onRevealStatus);
    final cachedProvider = _cacheService.getThumbnailFromMemory(
      widget.videoId,
      widget.thumbnailPath,
    );
    if (cachedProvider != null) {
      _imageProvider = _applyResizeOptimization(cachedProvider);
      _loadingState = _LoadingState.loaded;
      return;
    }
    _loadThumbnail();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final preparation = MediaCardPreparationHost.maybeOf(context);
    if (!identical(preparation, _preparation)) {
      _finishPreparation();
      _preparation = preparation;
      if (_loadingState != _LoadingState.error) _beginPreparation();
    }
    _stamp = preparation == null
        ? MediaCoverRevealStamp.maybeOf(context)
        : null;
    _kickStagedReveal();
  }

  @override
  void didUpdateWidget(CachedThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 如果videoId或thumbnailPath变化，重新加载
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.thumbnailPath != widget.thumbnailPath) {
      _finishPreparation();
      _beginPreparation();
      _prepareExpired = false;
      _clockKey = null;
      _reveal.stop();
      _reveal.value = 0;
      _cancelPendingLoad();
      final cachedProvider = _cacheService.getThumbnailFromMemory(
        widget.videoId,
        widget.thumbnailPath,
      );
      if (cachedProvider != null) {
        setState(() {
          _imageProvider = _applyResizeOptimization(cachedProvider);
          _loadingState = _LoadingState.loaded;
        });
        _kickStagedReveal();
        return;
      }
      _loadThumbnail();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _finishPreparation();
    _cancelPendingLoad();
    _reveal.removeStatusListener(_onRevealStatus);
    _reveal.dispose();
    super.dispose();
  }

  String get _revealMemoryKey =>
      '${widget.videoId}\u0000${widget.thumbnailPath ?? ''}';

  bool get _staged => _stamp != null;

  void _onRevealStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_staged) return;
    _revealedCoverKeys.add(_revealMemoryKey);
  }

  /// Starts the hold-then-fade once the pixels exist. The controller is
  /// muted while the page is hidden, so a prewarmed grid does not burn the
  /// cascade before the user actually lands on it.
  void _kickStagedReveal() {
    if (!_staged || _loadingState != _LoadingState.loaded) return;
    if (_imageProvider == null) return;
    final key = '$_revealMemoryKey#${_stamp!.index}/${_stamp!.crossAxisCount}';
    if (_revealedCoverKeys.contains(_revealMemoryKey)) {
      _clockKey = key;
      if (_reveal.value != 1) {
        if (_reveal.isAnimating) _reveal.stop();
        _reveal.value = 1;
      }
      return;
    }
    if (_clockKey == key && (_reveal.isAnimating || _reveal.value > 0)) {
      return;
    }
    if (_reveal.isAnimating) _reveal.stop();
    _clockKey = key;
    final delay = mediaCoverRevealDelay(
      index: _stamp!.index,
      crossAxisCount: _stamp!.crossAxisCount,
    );
    final fade = widget.fadeInDuration;
    final total = delay + fade;
    _stagedDelay = delay;
    _reveal.duration = total <= Duration.zero
        ? const Duration(milliseconds: 1)
        : total;
    _reveal.forward(from: 0);
  }

  /// 0 until this cell's row slot, then ease-out across the fade.
  double get _stagedOpacity {
    final totalUs = _reveal.duration?.inMicroseconds ?? 0;
    if (totalUs <= 0) return _reveal.value;
    final elapsed = _reveal.value * totalUs;
    final delayUs = _stagedDelay.inMicroseconds;
    if (elapsed <= delayUs) return 0;
    final fadeUs = widget.fadeInDuration.inMicroseconds;
    if (fadeUs <= 0) return 1;
    final raw = ((elapsed - delayUs) / fadeUs).clamp(0.0, 1.0);
    return Curves.easeOutCubic.transform(raw);
  }

  /// 取消正在进行的加载操作
  void _cancelPendingLoad() {
    _thumbnailRequest?.dispose();
    _thumbnailRequest = null;
    _loadCompleter?.complete();
    _loadCompleter = null;
  }

  /// 加载缩略图
  Future<void> _loadThumbnail() async {
    if (_isDisposed) return;

    // 创建新的Completer用于跟踪此次加载
    _loadCompleter = Completer<void>();
    final currentCompleter = _loadCompleter;

    setState(() {
      _loadingState = _LoadingState.loading;
      _imageProvider = null;
    });

    try {
      final cachedProvider = _cacheService.getThumbnailFromMemory(
        widget.videoId,
        widget.thumbnailPath,
      );
      if (cachedProvider != null) {
        if (_isDisposed || currentCompleter != _loadCompleter) {
          return;
        }
        final optimizedProvider = _applyResizeOptimization(cachedProvider);
        setState(() {
          _imageProvider = optimizedProvider;
          _loadingState = _LoadingState.loaded;
        });
        _kickStagedReveal();
        return;
      }

      // 从缓存服务获取缩略图
      final request = _cacheService.requestThumbnail(
        widget.videoId,
        widget.thumbnailPath,
      );
      _thumbnailRequest = request;
      final ImageProvider? provider;
      try {
        provider = await request.image;
      } finally {
        request.dispose();
      }

      // 检查是否已被取消或dispose
      if (_isDisposed || currentCompleter != _loadCompleter) {
        return;
      }

      if (provider != null) {
        // 应用ResizeImage优化内存
        final optimizedProvider = _applyResizeOptimization(provider);

        setState(() {
          _imageProvider = optimizedProvider;
          _loadingState = _LoadingState.loaded;
        });
        _kickStagedReveal();
      } else {
        setState(() {
          _loadingState = _LoadingState.error;
        });
      }
    } catch (e) {
      // 检查是否已被取消或dispose
      if (_isDisposed || currentCompleter != _loadCompleter) {
        return;
      }

      debugPrint('CachedThumbnailWidget 加载失败: $e');
      setState(() {
        _loadingState = _LoadingState.error;
      });
    }
  }

  /// 应用ResizeImage优化内存使用
  ImageProvider _applyResizeOptimization(ImageProvider provider) {
    return libraryThumbnailProvider(
      provider,
      width: widget.cacheWidth,
      height: widget.cacheHeight,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_prepareExpired && _loadingState != _LoadingState.loaded) {
      return _buildErrorWidget();
    }
    return _buildContent();
  }

  /// 根据加载状态构建内容
  Widget _buildContent() {
    switch (_loadingState) {
      case _LoadingState.loading:
        return _buildPlaceholder();
      case _LoadingState.loaded:
        return _buildImage();
      case _LoadingState.error:
        return _buildErrorWidget();
    }
  }

  /// 构建占位符
  Widget _buildPlaceholder() {
    return widget.placeholder ??
        Container(
          key: const ValueKey('placeholder'),
          color: Colors.grey[800],
          child: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white54),
              ),
            ),
          ),
        );
  }

  /// 构建图片
  Widget _buildImage() => LayoutBuilder(
    builder: (context, constraints) => _buildSizedImage(context, constraints),
  );

  Widget _buildSizedImage(BuildContext context, BoxConstraints constraints) {
    if (_imageProvider == null) {
      return _buildErrorWidget();
    }

    // Keep the underlay a solid dark fill. Grid cards used to stack a 50px
    // translucent movie icon behind the image; after a rotation the new
    // ResizeImage often has no frame yet, so that icon flashed through as a
    // rounded white square on the now-tiny thumbnail.
    final image = Image(
      key: ValueKey('image_${widget.videoId}'),
      image: libraryThumbnailProvider(
        _imageProvider!,
        width:
            widget.cacheWidth ??
            (constraints.maxWidth.isFinite
                ? (constraints.maxWidth *
                          MediaQuery.devicePixelRatioOf(context))
                      .round()
                : 512),
        height:
            widget.cacheHeight ??
            (constraints.maxHeight.isFinite
                ? (constraints.maxHeight *
                          MediaQuery.devicePixelRatioOf(context))
                      .round()
                : null),
      ),
      fit: widget.fit,
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (_preparation != null) {
          if (wasSynchronouslyLoaded || frame != null) _finishPreparation();
          return child;
        }
        if (_staged) {
          // The cascade below owns the fade, including memory-cache hits.
          // Those used to return the child immediately, so a whole screen
          // of covers popped in on one frame.
          if (wasSynchronouslyLoaded || frame != null) return child;
          return const SizedBox.expand();
        }
        if (wasSynchronouslyLoaded) {
          return child;
        }
        return ColoredBox(
          color: const Color(0xFF121212),
          child: AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: widget.fadeInDuration,
            curve: widget.fadeInCurve,
            child: child,
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        debugPrint('图片渲染错误: $error');
        return _buildErrorWidget();
      },
    );
    if (!_staged) return image;
    return AnimatedBuilder(
      animation: _reveal,
      builder: (context, child) {
        final t = _stagedOpacity;
        final scale = t >= 1 ? 1.0 : lerpDouble(1.035, 1, t)!;
        return ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (t < 1) _buildPlaceholder(),
              Opacity(
                opacity: t,
                child: Transform.scale(
                  scale: scale,
                  filterQuality: t >= 1
                      ? FilterQuality.none
                      : FilterQuality.low,
                  child: child,
                ),
              ),
            ],
          ),
        );
      },
      child: image,
    );
  }

  /// 构建错误显示组件
  Widget _buildErrorWidget() {
    _finishPreparation();
    final fallback = widget.errorWidget;
    if (fallback != null) {
      return fallback;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final iconSize = !side.isFinite || side <= 0
            ? 18.0
            : (side * 0.42).clamp(10.0, 32.0);
        return ColoredBox(
          key: const ValueKey('error'),
          color: const Color(0xFF121212),
          child: Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.white38,
              size: iconSize,
            ),
          ),
        );
      },
    );
  }
}

/// 加载状态枚举
enum _LoadingState { loading, loaded, error }
