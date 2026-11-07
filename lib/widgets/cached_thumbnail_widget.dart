import 'dart:async';
import 'dart:collection';
import 'package:flutter/material.dart';
import '../services/thumbnail_cache_service.dart';
import '../services/thumbnail_decode_scheduler.dart';
import 'media_card_preparation.dart';
import 'media_cover_reveal.dart';

export 'media_cover_reveal.dart'
    show MediaCoverRevealStamp, mediaCoverRevealDelay;

/// Covers that have already played their entrance. Scrolling back should
/// not run the cascade again.
final LinkedHashSet<String> _revealedCoverKeys = LinkedHashSet<String>();

/// Test hook. The set is process-wide so cases do not leak into each other.
@visibleForTesting
void resetMediaCoverRevealMemory() => _revealedCoverKeys.clear();

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
  MediaCoverRevealCoordinator? _coordinator;
  MediaCoverRevealTicket? _ticket;
  String? _clockKey;
  ThumbnailDecodeRequest? _decodeRequest;
  ImageProvider? _requestedProvider;
  ImageProvider? _decodedProvider;

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
    final stamp = MediaCoverRevealStamp.maybeOf(context);
    if (!identical(preparation, _preparation) ||
        (_stamp == null) != (stamp == null)) {
      _finishPreparation();
      _preparation = preparation;
      _prepareExpired = false;
      if (stamp == null && _loadingState != _LoadingState.error) {
        _beginPreparation();
      }
    }
    final coordinator = stamp == null
        ? null
        : mediaCoverRevealCoordinatorOf(context);
    if (_stamp?.index != stamp?.index ||
        _stamp?.crossAxisCount != stamp?.crossAxisCount ||
        !identical(_coordinator, coordinator)) {
      _ticket?.dispose();
      _ticket = null;
      _coordinator = coordinator;
      _stamp = stamp;
      _registerReveal();
    } else {
      _stamp = stamp;
    }
    _kickStagedReveal();
  }

  @override
  void didUpdateWidget(CachedThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 如果videoId或thumbnailPath变化，重新加载
    if (oldWidget.videoId != widget.videoId ||
        oldWidget.thumbnailPath != widget.thumbnailPath) {
      _finishPreparation();
      if (!_staged) _beginPreparation();
      _prepareExpired = false;
      _clockKey = null;
      _reveal.stop();
      _reveal.value = 0;
      _cancelPendingLoad();
      _ticket?.dispose();
      _ticket = null;
      _registerReveal();
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
    _ticket?.dispose();
    _reveal.removeStatusListener(_onRevealStatus);
    _reveal.dispose();
    super.dispose();
  }

  String get _revealMemoryKey =>
      '${widget.videoId}\u0000${widget.thumbnailPath ?? ''}';

  bool get _staged => _stamp != null;

  void _onRevealStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_staged) return;
    _revealedCoverKeys.remove(_revealMemoryKey);
    _revealedCoverKeys.add(_revealMemoryKey);
    while (_revealedCoverKeys.length > 512) {
      _revealedCoverKeys.remove(_revealedCoverKeys.first);
    }
  }

  void _registerReveal() {
    final stamp = _stamp;
    final coordinator = _coordinator;
    if (stamp == null ||
        coordinator == null ||
        stamp.index < 0 ||
        stamp.index >=
            5 * (stamp.crossAxisCount < 1 ? 1 : stamp.crossAxisCount)) {
      return;
    }
    _ticket = coordinator.register(stamp.index, _startReveal);
  }

  void _startReveal() {
    if (!mounted || !_staged || _decodedProvider == null) return;
    if (MediaQuery.disableAnimationsOf(context) ||
        widget.fadeInDuration <= Duration.zero ||
        _revealedCoverKeys.contains(_revealMemoryKey)) {
      _reveal.value = 1;
      return;
    }
    _reveal.duration = widget.fadeInDuration;
    _reveal.forward(from: 0);
  }

  /// Do not start the fade when a FileImage is created: it has no pixels yet.
  void _kickStagedReveal() {
    if (!_staged || _loadingState != _LoadingState.loaded) return;
    if (_decodedProvider == null) return;
    final key = '$_revealMemoryKey#${_stamp!.index}/${_stamp!.crossAxisCount}';
    if (_clockKey == key || _reveal.isAnimating || _reveal.value > 0) return;
    _clockKey = key;
    if (_revealedCoverKeys.contains(_revealMemoryKey) ||
        MediaQuery.disableAnimationsOf(context)) {
      _ticket?.dispose();
      _ticket = null;
      _startReveal();
    } else if (_ticket != null) {
      _ticket!.ready();
    } else {
      _startReveal();
    }
  }

  double get _stagedOpacity => Curves.easeOutCubic.transform(_reveal.value);

  /// 取消正在进行的加载操作
  void _cancelPendingLoad() {
    _thumbnailRequest?.dispose();
    _thumbnailRequest = null;
    _decodeRequest?.dispose();
    _decodeRequest = null;
    _requestedProvider = null;
    _decodedProvider = null;
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
        _ticket?.dispose();
        _ticket = null;
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
      _ticket?.dispose();
      _ticket = null;
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
    if (!_staged && _prepareExpired && _loadingState != _LoadingState.loaded) {
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
    if (_staged && widget.placeholder == null) {
      return const ColoredBox(color: Color(0xFF121212));
    }
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

  void _ensureDecoded(ImageProvider provider) {
    if (_requestedProvider == provider) return;
    _decodeRequest?.dispose();
    _requestedProvider = provider;
    final request = ThumbnailDecodeScheduler.instance.request(
      provider,
      createLocalImageConfiguration(context),
      priority: (_stamp?.index ?? 0).clamp(0, 1 << 29),
      shouldDefer: () =>
          mounted && Scrollable.recommendDeferredLoadingForContext(context),
    );
    _decodeRequest = request;
    request.ready.then((success) {
      request.dispose();
      if (!mounted || !identical(_decodeRequest, request)) return;
      _decodeRequest = null;
      if (!success && _decodedProvider == null) {
        _ticket?.dispose();
        _ticket = null;
        _finishPreparation();
        setState(() => _loadingState = _LoadingState.error);
        return;
      }
      if (success) {
        setState(() => _decodedProvider = provider);
        _finishPreparation();
        _kickStagedReveal();
      }
    });
  }

  Widget _buildSizedImage(BuildContext context, BoxConstraints constraints) {
    if (_imageProvider == null) {
      return _buildErrorWidget();
    }

    final targetProvider = libraryThumbnailProvider(
      _imageProvider!,
      width:
          widget.cacheWidth ??
          (constraints.maxWidth.isFinite
              ? (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                    .round()
              : 512),
      height:
          widget.cacheHeight ??
          (constraints.maxHeight.isFinite
              ? (constraints.maxHeight * MediaQuery.devicePixelRatioOf(context))
                    .round()
              : null),
    );
    if (_staged) {
      _ensureDecoded(targetProvider);
      if (_decodedProvider == null) return _buildPlaceholder();
    }

    // Keep the underlay a solid dark fill. Grid cards used to stack a 50px
    // translucent movie icon behind the image; after a rotation the new
    // ResizeImage often has no frame yet, so that icon flashed through as a
    // rounded white square on the now-tiny thumbnail.
    final image = Image(
      key: ValueKey('image_${widget.videoId}'),
      image: _staged ? _decodedProvider! : targetProvider,
      fit: widget.fit,
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (_staged) {
          if (wasSynchronouslyLoaded || frame != null) return child;
          return const SizedBox.expand();
        }
        if (_preparation != null) {
          if (wasSynchronouslyLoaded || frame != null) _finishPreparation();
          return child;
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
        return Stack(
          fit: StackFit.expand,
          children: [
            if (t < 1) _buildPlaceholder(),
            Opacity(
              key: ValueKey('media-cover-opacity-${widget.videoId}'),
              opacity: t,
              child: child,
            ),
          ],
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
