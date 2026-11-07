import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

/// Identical cache keys for predecode and display, including the resize policy.
ImageProvider libraryThumbnailProvider(
  ImageProvider provider, {
  int? width,
  int? height,
}) {
  if (provider is ResizeImage) provider = provider.imageProvider;
  int? bucket(int? pixels) => pixels == null
      ? null
      : (((pixels.clamp(1, 4096) + 63) ~/ 64) * 64).clamp(1, 4096);
  if (width == null && height == null) return provider;
  return ResizeImage(
    provider,
    width: bucket(width),
    height: bucket(height),
    policy: ResizeImagePolicy.fit,
    allowUpscaling: false,
  );
}

class ThumbnailLoadRequest {
  ThumbnailLoadRequest(this.image, this._release);
  final Future<ImageProvider?> image;
  final VoidCallback _release;
  bool _disposed = false;
  void dispose() {
    if (!_disposed) {
      _disposed = true;
      _release();
    }
  }
}

class _ThumbnailLoad {
  _ThumbnailLoad(this.key, this.videoId, this.path, this.prefetch);

  final String key;
  final String videoId;
  final String? path;
  final result = Completer<ImageProvider?>();
  int owners = 0;
  bool prefetch;
  bool started = false;
  bool waitingForRepair = false;
  bool repairStarted = false;
}

/// 缩略图缓存服务
///
/// 使用LRU（最近最少使用）策略管理内存缓存，提供高效的缩略图加载和缓存功能。
/// 单例模式确保全局唯一实例。
///
/// 这里缓存的是本地 ImageProvider 和路径，解码后的图片由 Flutter ImageCache
/// 管理。远程封面的原始字节、去重和
/// 磁盘文件在 MediaArtworkRepository，不要把一次 cacheWidth 当成省下了下载。
class ThumbnailCacheService {
  // 单例实例
  static final ThumbnailCacheService _instance =
      ThumbnailCacheService._internal();

  /// 获取单例实例
  factory ThumbnailCacheService() => _instance;

  ThumbnailCacheService._internal();

  /// LRU内存缓存：videoId -> ImageProvider
  /// 使用LinkedHashMap实现LRU，accessOrder=true确保访问顺序
  final LinkedHashMap<String, ImageProvider> _memoryCache =
      LinkedHashMap<String, ImageProvider>();

  final Map<String, String?> _thumbnailPathById = {};
  final Map<String, _ThumbnailLoad> _inFlight = {};
  final Queue<_ThumbnailLoad> _visibleLoads = Queue();
  final Queue<_ThumbnailLoad> _prefetchLoads = Queue();
  final Queue<_ThumbnailLoad> _visibleRepairs = Queue();
  final Queue<_ThumbnailLoad> _prefetchRepairs = Queue();
  int _activeLoads = 0;
  int _activePrefetchLoads = 0;
  int _activeRepairs = 0;
  int _activePrefetchRepairs = 0;

  void _pumpLoads() {
    while (_activeLoads < 4) {
      final _ThumbnailLoad load;
      if (_visibleLoads.isNotEmpty) {
        load = _visibleLoads.removeFirst();
      } else if (_activePrefetchLoads < 2 && _prefetchLoads.isNotEmpty) {
        load = _prefetchLoads.removeFirst();
      } else {
        return;
      }
      load.started = true;
      final wasPrefetch = load.prefetch;
      _activeLoads++;
      if (wasPrefetch) _activePrefetchLoads++;
      unawaited(
        _performLoad(load).whenComplete(() {
          _activeLoads--;
          if (wasPrefetch) _activePrefetchLoads--;
          _pumpLoads();
        }),
      );
    }
  }

  Future<void> _performLoad(_ThumbnailLoad load) async {
    try {
      final path = _normalizeLocalThumbnailPath(load.path);
      if (path != null && !_requiresWindowsThumbnailRepair(path)) {
        final file = File(path);
        if (await file.exists()) {
          if (load.owners == 0) {
            _finishLoad(load, null);
          } else {
            final provider = FileImage(file);
            _addToCache(load.videoId, provider, thumbnailPath: path);
            _finishLoad(load, provider);
          }
          return;
        }
      }
      if (load.owners == 0) {
        _finishLoad(load, null);
        return;
      }
      // Missing-cover generation can take much longer than a file check.
      // Keep it in its own bounded queue so existing covers stay responsive.
      load.waitingForRepair = true;
      (load.prefetch ? _prefetchRepairs : _visibleRepairs).add(load);
      _pumpRepairs();
    } catch (error, stack) {
      _finishLoad(load, null, error: error, stack: stack);
    }
  }

  void _pumpRepairs() {
    while (_activeRepairs < 4) {
      final _ThumbnailLoad load;
      if (_visibleRepairs.isNotEmpty) {
        load = _visibleRepairs.removeFirst();
      } else if (_activePrefetchRepairs < 2 && _prefetchRepairs.isNotEmpty) {
        load = _prefetchRepairs.removeFirst();
      } else {
        return;
      }
      load.waitingForRepair = false;
      load.repairStarted = true;
      final wasPrefetch = load.prefetch;
      _activeRepairs++;
      if (wasPrefetch) _activePrefetchRepairs++;
      unawaited(
        _repair(load).whenComplete(() {
          _activeRepairs--;
          if (wasPrefetch) _activePrefetchRepairs--;
          _pumpRepairs();
        }),
      );
    }
  }

  Future<void> _repair(_ThumbnailLoad load) async {
    try {
      _finishLoad(load, await _repairThumbnail(load.videoId, load.path));
    } catch (error, stack) {
      _finishLoad(load, null, error: error, stack: stack);
    }
  }

  void _finishLoad(
    _ThumbnailLoad load,
    ImageProvider? image, {
    Object? error,
    StackTrace? stack,
  }) {
    if (!load.result.isCompleted) {
      if (error == null) {
        load.result.complete(image);
      } else {
        load.result.completeError(error, stack);
      }
    }
    if (identical(_inFlight[load.key], load)) _inFlight.remove(load.key);
  }

  Future<String?> Function(String videoId)? _missingThumbnailResolver;

  /// 最大缓存条目数，默认100项
  int _maxCacheSize = 100;

  /// 获取当前最大缓存大小
  int get maxCacheSize => _maxCacheSize;

  /// 获取当前缓存条目数
  int get cacheSize => _memoryCache.length;

  /// 设置最大缓存大小
  ///
  /// 如果新的大小小于当前缓存条目数，会自动驱逐多余的条目
  void setMaxCacheSize(int size) {
    if (size <= 0) {
      throw ArgumentError('缓存大小必须大于0');
    }
    _maxCacheSize = size;
    _evictIfNeeded();
  }

  void setMissingThumbnailResolver(
    Future<String?> Function(String videoId)? resolver,
  ) {
    _missingThumbnailResolver = resolver;
  }

  /// 获取缩略图
  ///
  /// 首先检查内存缓存，如果命中则直接返回（并更新LRU顺序）。
  /// 如果未命中且thumbnailPath有效，则从磁盘加载并缓存。
  ///
  /// [videoId] 视频的唯一标识符
  /// [thumbnailPath] 缩略图文件路径，可为null
  ///
  /// 返回ImageProvider，如果无法加载则返回null
  Future<ImageProvider?> getThumbnail(
    String videoId,
    String? thumbnailPath,
  ) async {
    final request = requestThumbnail(videoId, thumbnailPath);
    try {
      return await request.image;
    } finally {
      request.dispose();
    }
  }

  ThumbnailLoadRequest requestThumbnail(
    String videoId,
    String? thumbnailPath, {
    bool prefetch = false,
  }) {
    final cached = getThumbnailFromMemory(videoId, thumbnailPath);
    if (cached != null) {
      return ThumbnailLoadRequest(Future.value(cached), () {});
    }
    final key = '$videoId\u0000${thumbnailPath ?? ''}';
    var load = _inFlight[key];
    if (load == null) {
      final created = load = _ThumbnailLoad(
        key,
        videoId,
        thumbnailPath,
        prefetch,
      );
      _inFlight[key] = created;
      (prefetch ? _prefetchLoads : _visibleLoads).add(created);
    } else if (!prefetch && load.prefetch && !load.repairStarted) {
      // A visible card can take over its own queued prefetch immediately,
      // whether it is waiting for a file check or for cover generation.
      if (!load.started) {
        _prefetchLoads.remove(load);
        _visibleLoads.add(load);
      } else if (load.waitingForRepair) {
        _prefetchRepairs.remove(load);
        _visibleRepairs.add(load);
      }
      load.prefetch = false;
    }
    final owned = load;
    owned.owners++;
    _pumpLoads();
    _pumpRepairs();
    return ThumbnailLoadRequest(owned.result.future, () {
      owned.owners--;
      if (owned.owners == 0 && (!owned.started || owned.waitingForRepair)) {
        _visibleLoads.remove(owned);
        _prefetchLoads.remove(owned);
        _visibleRepairs.remove(owned);
        _prefetchRepairs.remove(owned);
        owned.waitingForRepair = false;
        _finishLoad(owned, null);
        _pumpLoads();
        _pumpRepairs();
      }
    });
  }

  Future<ImageProvider?> _repairThumbnail(
    String videoId,
    String? thumbnailPath,
  ) async {
    final resolvedThumbnailPath = await _resolveMissingThumbnailPath(
      videoId,
      _normalizeLocalThumbnailPath(thumbnailPath),
    );
    if (resolvedThumbnailPath == null || resolvedThumbnailPath.isEmpty) {
      debugPrint('缩略图不存在且无法补建: $videoId');
      return null;
    }
    final file = File(resolvedThumbnailPath);
    if (!await file.exists()) {
      debugPrint('缩略图文件不存在: $resolvedThumbnailPath');
      return null;
    }

    // 3. 从磁盘加载并缓存
    try {
      final provider = FileImage(file);
      _addToCache(videoId, provider, thumbnailPath: resolvedThumbnailPath);
      return provider;
    } catch (e) {
      debugPrint('加载缩略图失败: $e');
      return null;
    }
  }

  ImageProvider? getThumbnailFromMemory(String videoId, String? thumbnailPath) {
    final normalizedThumbnailPath = _normalizeLocalThumbnailPath(thumbnailPath);
    final provider = _memoryCache[videoId];
    if (provider == null) return null;

    final cachedPath = _thumbnailPathById[videoId];
    if (normalizedThumbnailPath != null &&
        normalizedThumbnailPath.isNotEmpty &&
        cachedPath != null &&
        cachedPath.isNotEmpty &&
        cachedPath != normalizedThumbnailPath) {
      _memoryCache.remove(videoId);
      _thumbnailPathById.remove(videoId);
      return null;
    }

    _memoryCache.remove(videoId);
    _memoryCache[videoId] = provider;
    return provider;
  }

  /// 预加载缩略图到内存缓存
  ///
  /// 用于后台预加载即将显示的缩略图，不阻塞UI。
  ///
  /// [videoId] 视频的唯一标识符
  /// [thumbnailPath] 缩略图文件路径
  Future<void> preloadThumbnail(String videoId, String? thumbnailPath) async {
    final request = requestThumbnail(videoId, thumbnailPath, prefetch: true);
    try {
      await request.image;
    } finally {
      request.dispose();
    }
  }

  Future<String?> _resolveMissingThumbnailPath(
    String videoId,
    String? currentPath,
  ) async {
    final resolver = _missingThumbnailResolver;
    if (resolver == null) {
      return currentPath;
    }
    try {
      return await resolver(videoId);
    } catch (e) {
      debugPrint('补全缩略图失败: $e');
      return currentPath;
    }
  }

  /// 从缓存中移除指定视频的缩略图
  ///
  /// 当视频被删除时调用，确保缓存与数据同步。
  ///
  /// [videoId] 要移除的视频ID
  void evictFromCache(String videoId) {
    final removed = _memoryCache.remove(videoId);
    _thumbnailPathById.remove(videoId);
    if (removed != null) {
      debugPrint('已从缓存移除缩略图: $videoId');
    }
  }

  /// 清空所有内存缓存
  ///
  /// 在内存紧张或需要完全重置时调用。
  void clearMemoryCache() {
    _memoryCache.clear();
    _thumbnailPathById.clear();
    debugPrint('已清空所有缩略图缓存');
  }

  /// 检查指定视频的缩略图是否在内存缓存中
  ///
  /// [videoId] 视频的唯一标识符
  ///
  /// 返回true表示在缓存中，false表示不在
  bool isInMemoryCache(String videoId) {
    return _memoryCache.containsKey(videoId);
  }

  /// 批量预加载缩略图
  ///
  /// 用于一次性预加载多个缩略图，内部会过滤已缓存的项。
  ///
  /// [items] 包含videoId和thumbnailPath的Map列表
  Future<void> preloadBatch(List<Map<String, String?>> items) async {
    for (final item in items) {
      final videoId = item['videoId'];
      final thumbnailPath = item['thumbnailPath'];
      if (videoId != null) {
        await preloadThumbnail(videoId, thumbnailPath);
      }
    }
  }

  /// 获取所有缓存的视频ID列表（用于调试）
  List<String> getCachedIds() {
    return _memoryCache.keys.toList();
  }

  /// 添加条目到缓存，并在需要时驱逐旧条目
  void _addToCache(
    String videoId,
    ImageProvider provider, {
    String? thumbnailPath,
  }) {
    final normalizedThumbnailPath = _normalizeLocalThumbnailPath(thumbnailPath);
    // 如果已存在，先移除（更新LRU顺序）
    _memoryCache.remove(videoId);
    _thumbnailPathById.remove(videoId);

    // 添加到缓存末尾（最近使用）
    _memoryCache[videoId] = provider;
    _thumbnailPathById[videoId] = normalizedThumbnailPath;

    // 检查是否需要驱逐
    _evictIfNeeded();
  }

  /// 如果缓存超出限制，驱逐最久未使用的条目
  void _evictIfNeeded() {
    while (_memoryCache.length > _maxCacheSize) {
      // LinkedHashMap的第一个元素是最久未使用的
      final oldestKey = _memoryCache.keys.first;
      _memoryCache.remove(oldestKey);
      _thumbnailPathById.remove(oldestKey);
      debugPrint('LRU驱逐缩略图缓存: $oldestKey');
    }
  }

  /// 减少缓存大小（用于低内存情况）
  ///
  /// [targetSize] 目标缓存大小，如果为null则减少到当前大小的一半
  void reduceCache({int? targetSize}) {
    final target = targetSize ?? (_memoryCache.length ~/ 2);
    while (_memoryCache.length > target && _memoryCache.isNotEmpty) {
      final oldestKey = _memoryCache.keys.first;
      _memoryCache.remove(oldestKey);
      _thumbnailPathById.remove(oldestKey);
    }
    debugPrint('缓存已减少到 ${_memoryCache.length} 项');
  }

  String? _normalizeLocalThumbnailPath(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('file://')) {
      try {
        return Uri.parse(trimmed).toFilePath();
      } catch (_) {
        return trimmed.replaceFirst(RegExp(r'^file:/+'), '');
      }
    }
    return trimmed;
  }

  bool _requiresWindowsThumbnailRepair(String path) {
    if (!Platform.isWindows) {
      return false;
    }
    return p.extension(path).toLowerCase() == '.webp';
  }
}
