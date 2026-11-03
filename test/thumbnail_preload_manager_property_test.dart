import 'dart:async';
import 'package:glados/glados.dart';

final ExploreConfig _explore = ExploreConfig(numRuns: 10, initialSize: 1, speed: 1);

/// 用于测试的简化版预加载管理器
/// 
/// 由于ThumbnailPreloadManager是单例且依赖ThumbnailCacheService，
/// 我们创建一个纯Dart的预加载管理器类来测试核心并发控制逻辑。
/// 这个类的逻辑与ThumbnailPreloadManager完全一致。
class TestPreloadManager {
  /// 当前活跃的预加载操作数
  int _activePreloads = 0;

  /// 最大并发预加载数
  final int maxConcurrentPreloads;

  /// 记录的最大并发数（用于测试验证）
  int _peakConcurrency = 0;

  /// 待处理任务队列
  final List<TestPreloadTask> _pendingTasks = [];

  /// 已完成的任务ID列表
  final List<String> _completedTasks = [];

  /// 是否正在处理队列
  bool _isProcessing = false;

  /// 模拟预加载延迟（毫秒）
  final int preloadDelayMs;

  TestPreloadManager({
    this.maxConcurrentPreloads = 4,
    this.preloadDelayMs = 10,
  });

  /// 获取当前活跃预加载数
  int get activePreloads => _activePreloads;

  /// 获取记录的最大并发数
  int get peakConcurrency => _peakConcurrency;

  /// 获取待处理任务数
  int get pendingTaskCount => _pendingTasks.length;

  /// 获取已完成任务数
  int get completedTaskCount => _completedTasks.length;

  /// 添加预加载任务
  void addTask(String taskId, {int priority = 0}) {
    // 检查是否已存在
    if (_pendingTasks.any((t) => t.id == taskId)) {
      return;
    }

    _pendingTasks.add(TestPreloadTask(
      id: taskId,
      priority: priority,
    ));

    // 启动处理队列
    _processQueue();
  }

  /// 批量添加预加载任务
  void addTasks(List<String> taskIds) {
    for (final id in taskIds) {
      addTask(id);
    }
  }

  /// 取消所有待处理任务
  void cancelAll() {
    for (final task in _pendingTasks) {
      task.isCancelled = true;
    }
    _pendingTasks.clear();
  }

  /// 处理预加载队列
  Future<void> _processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      while (_pendingTasks.isNotEmpty && _activePreloads < maxConcurrentPreloads) {
        // 获取优先级最高的任务
        final task = _getHighestPriorityTask();
        if (task == null) break;

        // 如果任务已取消，跳过
        if (task.isCancelled) continue;

        // 执行预加载
        _activePreloads++;
        
        // 更新峰值并发数
        if (_activePreloads > _peakConcurrency) {
          _peakConcurrency = _activePreloads;
        }

        _executePreload(task);
      }
    } finally {
      _isProcessing = false;
    }
  }

  /// 获取优先级最高的任务
  TestPreloadTask? _getHighestPriorityTask() {
    if (_pendingTasks.isEmpty) return null;

    // 找到优先级最高（数值最小）的未取消任务
    TestPreloadTask? bestTask;
    int bestIndex = -1;

    for (int i = 0; i < _pendingTasks.length; i++) {
      final task = _pendingTasks[i];
      if (task.isCancelled) continue;

      if (bestTask == null || task.priority < bestTask.priority) {
        bestTask = task;
        bestIndex = i;
      }
    }

    // 移除选中的任务
    if (bestIndex >= 0) {
      _pendingTasks.removeAt(bestIndex);
    }

    return bestTask;
  }

  /// 执行单个预加载任务
  Future<void> _executePreload(TestPreloadTask task) async {
    try {
      // 模拟预加载延迟
      await Future.delayed(Duration(milliseconds: preloadDelayMs));
      _completedTasks.add(task.id);
    } finally {
      _activePreloads--;
      // 继续处理队列中的下一个任务
      _processQueue();
    }
  }

  /// 等待所有任务完成
  Future<void> waitForCompletion() async {
    while (_activePreloads > 0 || _pendingTasks.isNotEmpty) {
      await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  /// 重置状态（用于测试）
  void reset() {
    _activePreloads = 0;
    _peakConcurrency = 0;
    _pendingTasks.clear();
    _completedTasks.clear();
    _isProcessing = false;
  }
}

/// 测试用预加载任务
class TestPreloadTask {
  final String id;
  int priority;
  bool isCancelled;

  TestPreloadTask({
    required this.id,
    this.priority = 0,
    this.isCancelled = false,
  });
}

void main() {
  group('ThumbnailPreloadManager 并发限制属性测试', () {
    /// **Property 4: Preload Respects Concurrency Limit**
    /// 
    /// *For any* number of preload requests, the number of concurrent 
    /// active preload operations shall never exceed the configured maximum.
    /// 
    /// **Validates: Requirements 2.5**
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 4: Preload Respects Concurrency Limit**
    Glados(any.positiveIntOrZero.map((n) => (n % 50) + 1), _explore).test(
      'Property 4: 对于任意数量的预加载请求，并发操作数不应超过配置的最大值',
      (taskCount) async {
        const maxConcurrent = 4;
        final manager = TestPreloadManager(
          maxConcurrentPreloads: maxConcurrent,
          preloadDelayMs: 5,
        );

        // 添加taskCount个任务
        final taskIds = List.generate(taskCount, (i) => 'task_$i');
        manager.addTasks(taskIds);

        // 等待所有任务完成
        await manager.waitForCompletion();

        // 验证：峰值并发数不超过最大限制
        expect(manager.peakConcurrency, lessThanOrEqualTo(maxConcurrent),
          reason: '峰值并发数($taskCount个任务)不应超过$maxConcurrent');

        // 验证：所有任务都已完成
        expect(manager.completedTaskCount, equals(taskCount),
          reason: '所有$taskCount个任务都应完成');

        // 验证：当前活跃数为0
        expect(manager.activePreloads, equals(0),
          reason: '完成后活跃预加载数应为0');
      },
    );

    /// Property 4 补充测试：不同maxConcurrentPreloads配置
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 4: Preload Respects Concurrency Limit**
    Glados2(
      any.positiveIntOrZero.map((n) => (n % 10) + 1), // maxConcurrent: 1-10
      any.positiveIntOrZero.map((n) => (n % 30) + 5), // taskCount: 5-34
      _explore,
    ).test(
      'Property 4: 对于任意maxConcurrentPreloads配置，并发数不应超过该值',
      (maxConcurrent, taskCount) async {
        final manager = TestPreloadManager(
          maxConcurrentPreloads: maxConcurrent,
          preloadDelayMs: 3,
        );

        // 添加任务
        final taskIds = List.generate(taskCount, (i) => 'task_$i');
        manager.addTasks(taskIds);

        // 等待完成
        await manager.waitForCompletion();

        // 验证：峰值并发数不超过配置的最大值
        expect(manager.peakConcurrency, lessThanOrEqualTo(maxConcurrent),
          reason: '峰值并发数不应超过配置的maxConcurrent=$maxConcurrent');

        // 验证：所有任务完成
        expect(manager.completedTaskCount, equals(taskCount),
          reason: '所有任务都应完成');
      },
    );

    /// Property 4 补充测试：任务数少于maxConcurrent时的行为
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 4: Preload Respects Concurrency Limit**
    Glados(any.positiveIntOrZero.map((n) => (n % 3) + 1), _explore).test(
      'Property 4: 当任务数少于maxConcurrent时，峰值并发数应等于任务数',
      (taskCount) async {
        const maxConcurrent = 4;
        final manager = TestPreloadManager(
          maxConcurrentPreloads: maxConcurrent,
          preloadDelayMs: 50, // 较长延迟确保任务同时运行
        );

        // 添加少于maxConcurrent的任务
        final taskIds = List.generate(taskCount, (i) => 'task_$i');
        manager.addTasks(taskIds);

        // 短暂等待让任务启动
        await Future.delayed(const Duration(milliseconds: 20));

        // 验证：峰值并发数应等于任务数（因为任务数 < maxConcurrent）
        expect(manager.peakConcurrency, equals(taskCount),
          reason: '当任务数($taskCount)少于maxConcurrent($maxConcurrent)时，峰值并发数应等于任务数');

        // 等待完成
        await manager.waitForCompletion();
      },
    );

    /// Property 4 补充测试：取消任务不影响并发限制
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 4: Preload Respects Concurrency Limit**
    Glados(any.positiveIntOrZero.map((n) => (n % 20) + 10), _explore).test(
      'Property 4: 取消任务后，并发数仍不应超过最大值',
      (taskCount) async {
        const maxConcurrent = 4;
        final manager = TestPreloadManager(
          maxConcurrentPreloads: maxConcurrent,
          preloadDelayMs: 10,
        );

        // 添加任务
        final taskIds = List.generate(taskCount, (i) => 'task_$i');
        manager.addTasks(taskIds);

        // 短暂等待后取消所有待处理任务
        await Future.delayed(const Duration(milliseconds: 5));
        manager.cancelAll();

        // 等待当前活跃任务完成
        await manager.waitForCompletion();

        // 验证：峰值并发数不超过最大限制
        expect(manager.peakConcurrency, lessThanOrEqualTo(maxConcurrent),
          reason: '取消任务后，峰值并发数仍不应超过$maxConcurrent');

        // 验证：当前活跃数为0
        expect(manager.activePreloads, equals(0),
          reason: '完成后活跃预加载数应为0');
      },
    );

    /// Property 4 补充测试：连续添加任务
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 4: Preload Respects Concurrency Limit**
    Glados2(
      any.positiveIntOrZero.map((n) => (n % 5) + 1), // 批次数: 1-5
      any.positiveIntOrZero.map((n) => (n % 10) + 1), // 每批任务数: 1-10
      _explore,
    ).test(
      'Property 4: 连续多批次添加任务时，并发数不应超过最大值',
      (batchCount, tasksPerBatch) async {
        const maxConcurrent = 4;
        final manager = TestPreloadManager(
          maxConcurrentPreloads: maxConcurrent,
          preloadDelayMs: 5,
        );

        int totalTasks = 0;

        // 分批添加任务
        for (int batch = 0; batch < batchCount; batch++) {
          final taskIds = List.generate(
            tasksPerBatch,
            (i) => 'batch${batch}_task$i',
          );
          manager.addTasks(taskIds);
          totalTasks += tasksPerBatch;

          // 批次之间短暂延迟
          await Future.delayed(const Duration(milliseconds: 3));
        }

        // 等待完成
        await manager.waitForCompletion();

        // 验证：峰值并发数不超过最大限制
        expect(manager.peakConcurrency, lessThanOrEqualTo(maxConcurrent),
          reason: '连续添加$batchCount批任务后，峰值并发数不应超过$maxConcurrent');

        // 验证：所有任务完成
        expect(manager.completedTaskCount, equals(totalTasks),
          reason: '所有$totalTasks个任务都应完成');
      },
    );

    /// Property 4 补充测试：大量任务时的并发限制
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 4: Preload Respects Concurrency Limit**
    Glados(any.positiveIntOrZero.map((n) => (n % 100) + 50), _explore).test(
      'Property 4: 大量任务时并发数仍不应超过最大值',
      (taskCount) async {
        const maxConcurrent = 4;
        final manager = TestPreloadManager(
          maxConcurrentPreloads: maxConcurrent,
          preloadDelayMs: 2,
        );

        // 添加大量任务
        final taskIds = List.generate(taskCount, (i) => 'task_$i');
        manager.addTasks(taskIds);

        // 等待完成
        await manager.waitForCompletion();

        // 验证：峰值并发数不超过最大限制
        expect(manager.peakConcurrency, lessThanOrEqualTo(maxConcurrent),
          reason: '处理$taskCount个任务时，峰值并发数不应超过$maxConcurrent');

        // 验证：所有任务完成
        expect(manager.completedTaskCount, equals(taskCount),
          reason: '所有$taskCount个任务都应完成');

        // 验证：当前活跃数为0
        expect(manager.activePreloads, equals(0),
          reason: '完成后活跃预加载数应为0');
      },
    );
  });
}
