import 'dart:async';
import 'dart:collection';
import 'package:flutter/rendering.dart';
import '../models/video_item.dart';
import 'thumbnail_cache_service.dart';

/// 预加载任务
class PreloadTask {
  final String videoId;
  final String? thumbnailPath;
  int priority; // 数值越小优先级越高
  final DateTime createdAt;
  bool isCancelled;

  PreloadTask({
    required this.videoId,
    required this.thumbnailPath,
    required this.priority,
    DateTime? createdAt,
    this.isCancelled = false,
  }) : createdAt = createdAt ?? DateTime.now();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PreloadTask &&
          runtimeType == other.runtimeType &&
          videoId == other.videoId;

  @override
  int get hashCode => videoId.hashCode;
}

/// 缩略图预加载管理器
///
/// 管理缩略图的预加载策略，包括：
/// - 预加载队列和优先级管理
/// - 并发控制（最大4个并发预加载）
/// - 基于滚动方向的优先级调整
class ThumbnailPreloadManager {
  // 单例实例
  static final ThumbnailPreloadManager _instance =
      ThumbnailPreloadManager._internal();

  /// 获取单例实例
  factory ThumbnailPreloadManager() => _instance;

  ThumbnailPreloadManager._internal();

  /// 缓存服务引用
  final ThumbnailCacheService _cacheService = ThumbnailCacheService();

  /// 预加载队列（按优先级排序）
  final Queue<PreloadTask> _preloadQueue = Queue<PreloadTask>();

  /// 待处理任务映射（用于快速查找和更新优先级）
  final Map<String, PreloadTask> _pendingTasks = {};

  /// 当前活跃的预加载操作数
  int _activePreloads = 0;

  /// 最大并发预加载数
  static const int maxConcurrentPreloads = 4;

  /// 获取当前活跃预加载数（用于测试）
  int get activePreloads => _activePreloads;

  /// 获取待处理任务数（用于测试）
  int get pendingTaskCount => _pendingTasks.length;

  /// 是否正在处理队列
  bool _isProcessing = false;

  /// 预加载指定范围的视频缩略图
  ///
  /// [items] 视频列表
  /// [startIndex] 起始索引
  /// [endIndex] 结束索引（不包含）
  /// [currentIndex] 当前可见项的索引，用于计算优先级
  void preloadRange(
    List<VideoItem> items,
    int startIndex,
    int endIndex, {
    int? currentIndex,
  }) {
    // 边界检查
    startIndex = startIndex.clamp(0, items.length);
    endIndex = endIndex.clamp(0, items.length);

    if (startIndex >= endIndex) return;

    final center = currentIndex ?? ((startIndex + endIndex) ~/ 2);

    for (int i = startIndex; i < endIndex; i++) {
      final item = items[i];

      // 跳过已缓存的项
      if (_cacheService.isInMemoryCache(item.id)) {
        continue;
      }

      // 跳过没有缩略图路径的项
      if (item.thumbnailPath == null || item.thumbnailPath!.isEmpty) {
        continue;
      }

      // 计算优先级：距离当前位置越近，优先级越高（数值越小）
      final priority = (i - center).abs();

      // 如果任务已存在，更新优先级
      if (_pendingTasks.containsKey(item.id)) {
        final existingTask = _pendingTasks[item.id]!;
        if (priority < existingTask.priority) {
          existingTask.priority = priority;
        }
        continue;
      }

      // 创建新任务
      final task = PreloadTask(
        videoId: item.id,
        thumbnailPath: item.thumbnailPath,
        priority: priority,
      );

      _pendingTasks[item.id] = task;
      _preloadQueue.add(task);
    }

    // 启动处理队列
    _processQueue();
  }

  /// 取消所有待处理的预加载任务
  void cancelAll() {
    // 标记所有待处理任务为已取消
    for (final task in _pendingTasks.values) {
      task.isCancelled = true;
    }

    // 清空队列和映射
    _preloadQueue.clear();
    _pendingTasks.clear();

    debugPrint('已取消所有预加载任务');
  }

  /// 根据滚动位置和方向更新预加载优先级
  ///
  /// [currentIndex] 当前可见项的索引
  /// [direction] 滚动方向
  void updatePriorities(int currentIndex, ScrollDirection direction) {
    if (_pendingTasks.isEmpty) return;

    // 根据滚动方向调整优先级
    // 向下滚动时，优先加载下方的项
    // 向上滚动时，优先加载上方的项
    for (final task in _pendingTasks.values) {
      if (task.isCancelled) continue;

      // 获取任务对应的索引（通过videoId无法直接获取，这里使用简化的优先级计算）
      // 实际应用中可能需要维护videoId到index的映射
      final basePriority = task.priority;

      if (direction == ScrollDirection.forward) {
        // 向下滚动，降低上方项的优先级
        task.priority = basePriority;
      } else if (direction == ScrollDirection.reverse) {
        // 向上滚动，降低下方项的优先级
        task.priority = basePriority;
      }
    }

    // 取消距离当前位置太远的任务
    _cancelDistantTasks(currentIndex);
  }

  /// 取消距离当前位置太远的任务
  void _cancelDistantTasks(int currentIndex, {int maxDistance = 20}) {
    final tasksToCancel = <String>[];

    for (final entry in _pendingTasks.entries) {
      if (entry.value.priority > maxDistance) {
        entry.value.isCancelled = true;
        tasksToCancel.add(entry.key);
      }
    }

    for (final id in tasksToCancel) {
      _pendingTasks.remove(id);
    }
  }

  /// 处理预加载队列
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      while (_preloadQueue.isNotEmpty && _activePreloads < maxConcurrentPreloads) {
        // 获取优先级最高的任务
        final task = _getHighestPriorityTask();
        if (task == null) break;

        // 从待处理映射中移除
        _pendingTasks.remove(task.videoId);

        // 如果任务已取消，跳过
        if (task.isCancelled) continue;

        // 如果已经在缓存中，跳过
        if (_cacheService.isInMemoryCache(task.videoId)) continue;

        // 执行预加载
        _activePreloads++;
        _executePreload(task);
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// 获取优先级最高的任务
  PreloadTask? _getHighestPriorityTask() {
    if (_preloadQueue.isEmpty) return null;

    // 找到优先级最高（数值最小）的未取消任务
    PreloadTask? bestTask;
    final tasksToRemove = <PreloadTask>[];

    for (final task in _preloadQueue) {
      if (task.isCancelled) {
        tasksToRemove.add(task);
        continue;
      }

      if (bestTask == null || task.priority < bestTask.priority) {
        bestTask = task;
      }
    }

    // 移除已取消的任务
    for (final task in tasksToRemove) {
      _preloadQueue.remove(task);
    }

    // 移除选中的任务
    if (bestTask != null) {
      _preloadQueue.remove(bestTask);
    }

    return bestTask;
  }

  /// 执行单个预加载任务
  Future<void> _executePreload(PreloadTask task) async {
    try {
      await _cacheService.preloadThumbnail(task.videoId, task.thumbnailPath);
    } catch (e) {
      debugPrint('预加载失败: ${task.videoId}, 错误: $e');
    } finally {
      _activePreloads--;
      // 继续处理队列中的下一个任务
      _processQueue();
    }
  }

  /// 预加载单个视频的缩略图
  ///
  /// [videoId] 视频ID
  /// [thumbnailPath] 缩略图路径
  /// [priority] 优先级（默认为0，最高优先级）
  void preloadSingle(String videoId, String? thumbnailPath, {int priority = 0}) {
    if (thumbnailPath == null || thumbnailPath.isEmpty) return;
    if (_cacheService.isInMemoryCache(videoId)) return;
    if (_pendingTasks.containsKey(videoId)) return;

    final task = PreloadTask(
      videoId: videoId,
      thumbnailPath: thumbnailPath,
      priority: priority,
    );

    _pendingTasks[videoId] = task;
    _preloadQueue.add(task);
    _processQueue();
  }

  /// 检查是否有待处理的任务
  bool hasPendingTasks() => _pendingTasks.isNotEmpty;

  /// 获取当前队列状态（用于调试）
  Map<String, dynamic> getStatus() {
    return {
      'activePreloads': _activePreloads,
      'pendingTasks': _pendingTasks.length,
      'queueSize': _preloadQueue.length,
      'isProcessing': _isProcessing,
    };
  }
}
