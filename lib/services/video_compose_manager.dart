import 'subtitle_font_service.dart';
import '../models/subtitle_debug_preset.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/subtitle_position.dart';
import '../models/subtitle_style.dart';
import '../models/video_compose_models.dart';
import '../models/media_source_ref.dart';
import 'video_compose/video_compose_artifact_cleaner.dart';
import 'video_compose/video_compose_ass_renderer.dart';
import 'video_compose/video_compose_executor.dart';
import 'video_compose/video_compose_font_service.dart';
import 'video_compose/video_compose_orchestrator.dart';
import 'video_compose/video_compose_output_path_service.dart';
import 'video_compose/video_compose_probe_service.dart';
import 'video_compose/video_compose_precise_renderer.dart';
import 'video_compose/video_compose_subtitle_service.dart';
import 'video_compose/video_compose_task_store.dart';
import 'library_service.dart';
import 'media_materialization_service.dart';

class VideoComposeDeletionResult {
  final List<String> deletedTaskIds;
  final List<String> failedTaskIds;

  VideoComposeDeletionResult({
    required Iterable<String> deletedTaskIds,
    required Iterable<String> failedTaskIds,
  }) : deletedTaskIds = List.unmodifiable(deletedTaskIds),
       failedTaskIds = List.unmodifiable(failedTaskIds);
}

class VideoComposeManager extends ChangeNotifier {
  final List<String> _queueTaskIds = <String>[];
  final Map<String, VideoComposeTaskState> _taskMap =
      <String, VideoComposeTaskState>{};
  final VideoComposeTaskStore _taskStore;
  final VideoComposeArtifactCleaner _artifactCleaner;
  final VideoComposeOutputPathService _outputPathService;
  final VideoComposeOrchestrator _orchestrator;
  final LibraryService _library;
  final Map<String, Completer<void>> _materializationCancellations = {};
  final Map<String, MediaMaterializationProgress> _materializationProgress = {};

  String? _runningTaskId;
  bool _isProcessing = false;
  bool _storageMaintenance = false;
  final Completer<void> _loadRequested = Completer<void>();
  late final Future<void> _loaded;
  Future<void> _deletionTail = Future<void>.value();
  int _taskDeletionHolds = 0;
  Completer<void>? _runningTaskCompletion;
  int _runGeneration = 0;
  int _systemInterruptionHolds = 0;
  Future<void>? _systemInterruption;

  Future<void> get ready => _loaded;

  /// Deferred startup calls this after storage has selected its metadata root.
  Future<void> initialize() {
    if (!_loadRequested.isCompleted) _loadRequested.complete();
    return _loaded;
  }

  /// A foreground-service refusal, expiry or notification pause belongs to
  /// the whole current queue. Keep its history for explicit user retries.
  Future<void> interruptForSystem() {
    final pending = _systemInterruption;
    if (pending != null) return pending;
    final runningId = _runningTaskId;
    final ids = {..._queueTaskIds, ?runningId};
    if (ids.isEmpty) return Future<void>.value();

    final done = Completer<void>();
    _systemInterruption = done.future;
    _systemInterruptionHolds++;
    _runGeneration++;
    final runningCompletion = _runningTaskCompletion?.future;
    _queueTaskIds.clear();
    for (final id in ids) {
      final cancellation = _materializationCancellations[id];
      if (cancellation != null && !cancellation.isCompleted) {
        cancellation.complete();
      }
      _setTask(
        id,
        stage: VideoComposeStage.failed,
        message: '后台处理已中断，可重试',
        error: '系统已停止本轮后台合成，请回到前台后重试',
      );
    }
    unawaited(_finishSystemInterruption(done, runningId, runningCompletion));
    return done.future;
  }

  Future<void> _finishSystemInterruption(
    Completer<void> done,
    String? runningId,
    Future<void>? runningCompletion,
  ) async {
    try {
      if (runningId != null) {
        try {
          await _orchestrator.cancelRunningCompose();
        } catch (error) {
          debugPrint('停止后台合成失败：$error');
        }
        // Join materialization, renderer, executor and lease cleanup. A new
        // explicit request must not reuse any of the old owner's resources.
        await runningCompletion;
      }
      await _saveTasks();
    } catch (error) {
      // Keep the in-memory failure and retained records even if the journal
      // is temporarily unavailable; startup already recovers incomplete jobs.
      debugPrint('保存后台合成中断状态失败：$error');
    } finally {
      _systemInterruptionHolds--;
      _systemInterruption = null;
      done.complete();
      notifyListeners();
    }
  }

  Future<void> prepareStorageMigration() async {
    if (runningTask != null) throw StateError('请等待合成任务完成后再迁移目录');
    if (_taskDeletionHolds > 0) throw StateError('请等待合成任务删除完成后再迁移目录');
    _storageMaintenance = true;
    await _saveTasks();
  }

  factory VideoComposeManager({
    LibraryService? library,
    bool deferTaskLoading = false,
    VideoComposeTaskStore? taskStore,
    VideoComposeArtifactCleaner? artifactCleaner,
    VideoComposeOutputPathService? outputPathService,
    VideoComposeProbeService? probeService,
    VideoComposeSubtitleService? subtitleService,
    VideoComposeFontService? fontService,
    VideoComposeExecutor? executor,
    VideoComposeOrchestrator? orchestrator,
  }) {
    final VideoComposeFontService resolvedFontService =
        fontService ?? VideoComposeFontService();
    return VideoComposeManager._internal(
      library: library ?? LibraryService(),
      deferTaskLoading: deferTaskLoading,
      taskStore: taskStore ?? const VideoComposeTaskStore(),
      artifactCleaner: artifactCleaner ?? VideoComposeArtifactCleaner(),
      outputPathService:
          outputPathService ?? const VideoComposeOutputPathService(),
      orchestrator:
          orchestrator ??
          VideoComposeOrchestrator(
            probeService: probeService ?? const VideoComposeProbeService(),
            subtitleService:
                subtitleService ?? const VideoComposeSubtitleService(),
            assRenderer: VideoComposeAssRenderer(resolvedFontService),
            preciseRenderer: VideoComposePreciseRenderer(),
            fontService: resolvedFontService,
            executor: executor ?? VideoComposeExecutor(),
            outputPathService:
                outputPathService ?? const VideoComposeOutputPathService(),
          ),
    );
  }

  VideoComposeManager._internal({
    required LibraryService library,
    required bool deferTaskLoading,
    required VideoComposeTaskStore taskStore,
    required VideoComposeArtifactCleaner artifactCleaner,
    required VideoComposeOutputPathService outputPathService,
    required VideoComposeOrchestrator orchestrator,
  }) : _library = library,
       _taskStore = taskStore,
       _artifactCleaner = artifactCleaner,
       _outputPathService = outputPathService,
       _orchestrator = orchestrator {
    _loaded = _loadRequested.future.then((_) => _loadTasks());
    if (!deferTaskLoading) _loadRequested.complete();
  }

  Future<void> _loadTasks() async {
    final List<VideoComposeTaskState> storedTasks = await _taskStore
        .loadTasks();
    for (final VideoComposeTaskState state in storedTasks) {
      if (_isIncompleteStage(state.stage)) {
        _taskMap[state.taskId] = state.copyWith(
          stage: VideoComposeStage.failed,
          message: '应用重启，任务已中断',
          completedAt: DateTime.now(),
        );
      } else {
        _taskMap[state.taskId] = state;
      }
    }
    notifyListeners();
  }

  bool _isIncompleteStage(VideoComposeStage stage) {
    return stage == VideoComposeStage.queued ||
        stage == VideoComposeStage.materializing ||
        stage == VideoComposeStage.preparing ||
        stage == VideoComposeStage.rendering ||
        stage == VideoComposeStage.finalizing;
  }

  Future<void> _saveTasks() async {
    await ready;
    await _taskStore.saveTasks(_taskMap.values);
  }

  Future<bool> deleteTaskAndFile(
    String taskId, {
    bool deleteOutput = true,
  }) async {
    final result = await deleteTasksAndFiles([
      taskId,
    ], deleteOutput: deleteOutput);
    return result.failedTaskIds.isEmpty;
  }

  Future<VideoComposeDeletionResult> clearTasksAndFiles({
    bool deleteOutput = true,
  }) async {
    await ready;
    return deleteTasksAndFiles(
      _taskMap.keys.toList(),
      deleteOutput: deleteOutput,
    );
  }

  Future<VideoComposeDeletionResult> deleteTasksAndFiles(
    Iterable<String> taskIds, {
    bool deleteOutput = true,
  }) {
    final ids = taskIds.toSet();
    // Reserve the entire selection before the first await. Cancelling the
    // active task must never start the next task that is also being deleted.
    _taskDeletionHolds++;
    _queueTaskIds.removeWhere(ids.contains);
    notifyListeners();
    final operation = _deletionTail.then((_) async {
      final deleted = <String>[], failed = <String>[];
      try {
        await ready;
        for (final id in ids) {
          try {
            if (await _deleteTask(id, deleteOutput: deleteOutput)) {
              deleted.add(id);
              continue;
            }
          } catch (error) {
            debugPrint('删除合成任务失败（$id）：$error');
          }
          failed.add(id);
          final task = _taskMap[id];
          if (task != null && _isIncompleteStage(task.stage)) {
            _taskMap[id] = task.copyWith(
              stage: VideoComposeStage.failed,
              message: '删除失败，任务已保留',
              error: '无法删除输出文件，请关闭占用或授权后重试',
              completedAt: DateTime.now(),
            );
          }
        }
        await _saveTasks();
        return VideoComposeDeletionResult(
          deletedTaskIds: deleted,
          failedTaskIds: failed,
        );
      } finally {
        _taskDeletionHolds--;
        notifyListeners();
        if (_taskDeletionHolds == 0 &&
            !_isProcessing &&
            _queueTaskIds.isNotEmpty) {
          unawaited(_processQueue());
        }
      }
    });
    _deletionTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<bool> _deleteTask(String taskId, {required bool deleteOutput}) async {
    final VideoComposeTaskState? task = _taskMap[taskId];
    if (task == null) return true;
    final bool isRunningTask = _runningTaskId == taskId;
    if (isRunningTask) {
      final completion = _runningTaskCompletion?.future;
      final cancellation = _materializationCancellations[taskId];
      if (cancellation != null && !cancellation.isCompleted) {
        cancellation.complete();
      }
      await _orchestrator.cancelRunningCompose();
      // Preparation, rendering and materialization may still be unwinding
      // after the FFmpeg session exits. Wait for their handles/leases too.
      await completion;
    }
    final bool outputDeleted = await _artifactCleaner.cleanupTaskArtifacts(
      taskId,
      deleteOutput: deleteOutput,
      outputPath: task.request.outputPath,
    );
    if (!outputDeleted) {
      return false;
    }
    _taskMap.remove(taskId);
    return outputDeleted;
  }

  List<VideoComposeTaskState> get allTasks {
    final List<VideoComposeTaskState> list = _taskMap.values.toList()
      ..sort(
        (VideoComposeTaskState a, VideoComposeTaskState b) =>
            b.createdAt.compareTo(a.createdAt),
      );
    return List.unmodifiable(list);
  }

  List<VideoComposeTaskState> get queuedTasks {
    final List<VideoComposeTaskState> list = _queueTaskIds
        .map((String id) => _taskMap[id])
        .whereType<VideoComposeTaskState>()
        .toList();
    return List.unmodifiable(list);
  }

  VideoComposeTaskState? get runningTask {
    if (_runningTaskId == null) return null;
    return _taskMap[_runningTaskId!];
  }

  Set<String> get storageArtifactPathsInUse => _runningTaskId == null
      ? const <String>{}
      : _artifactCleaner.taskArtifactPaths(_runningTaskId!);

  MediaMaterializationProgress? materializationProgressForTask(String taskId) =>
      _materializationProgress[taskId];

  int get pendingCount =>
      _queueTaskIds.length + (_runningTaskId == null ? 0 : 1);

  VideoComposeTaskState? latestTaskForVideo(String videoId) {
    VideoComposeTaskState? hit;
    for (final task in _taskMap.values) {
      if (task.request.videoId != videoId) continue;
      if (hit == null || task.createdAt.isAfter(hit.createdAt)) {
        hit = task;
      }
    }
    return hit;
  }

  Future<String?> getSourceResolutionLabel(String videoPath) async {
    return _orchestrator.getSourceResolutionLabel(videoPath);
  }

  Future<VideoComposeTaskState> enqueue({
    required String videoId,
    required String videoPath,
    required String title,
    required String? primarySubtitlePath,
    required String? secondarySubtitlePath,
    String? primaryFontLanguage,
    String? secondaryFontLanguage,
    required bool renderSecondarySubtitle,
    required bool continuousSubtitle,
    required bool embedSoftSubtitles,
    required bool softSubtitleOnly,
    required bool softSubtitleUseSourceQuality,
    required List<VideoComposeSoftSubtitleTrack> softSubtitleTracks,
    required VideoComposeResolution resolution,
    required VideoComposeRenderMode renderMode,
    required SubtitleStyle subtitleStyle,
    required SubtitleStyle subtitleStylePortrait,
    SubtitleDebugPreset? subtitlePreset,
    required Alignment subtitleAlignment,
    SubtitlePlacementSnapshot? subtitlePlacement,
    required bool splitSubtitleByLine,
    String? customOutputPath,
  }) async {
    await ready;
    await _systemInterruption;
    final String outputPath;
    if (customOutputPath != null && customOutputPath.isNotEmpty) {
      final String fileName = _outputPathService.buildOutputFileName(title);
      outputPath = p.join(customOutputPath, fileName);
    } else {
      outputPath = await _outputPathService.buildOutputPath(title);
    }
    final VideoComposeRequest request = VideoComposeRequest(
      videoId: videoId,
      videoPath: videoPath,
      title: title,
      primarySubtitlePath: primarySubtitlePath,
      secondarySubtitlePath: secondarySubtitlePath,
      primaryFontLanguage:
          primaryFontLanguage ??
          SubtitleFontService.instance.languageForSource(primarySubtitlePath),
      secondaryFontLanguage:
          secondaryFontLanguage ??
          SubtitleFontService.instance.languageForSource(
            SubtitleFontService.instance.secondarySource(
              primarySubtitlePath,
              secondarySubtitlePath,
            ),
          ),
      renderSecondarySubtitle: renderSecondarySubtitle,
      continuousSubtitle: continuousSubtitle,
      embedSoftSubtitles: embedSoftSubtitles,
      softSubtitleOnly: softSubtitleOnly,
      softSubtitleUseSourceQuality: softSubtitleUseSourceQuality,
      softSubtitleTracks: softSubtitleTracks,
      resolution: resolution,
      renderMode: renderMode,
      subtitleStyle: subtitleStyle,
      subtitlePreset: subtitlePreset,
      subtitleStylePortrait: subtitleStylePortrait,
      subtitleAlignment: subtitleAlignment,
      subtitlePlacement: subtitlePlacement,
      splitSubtitleByLine: splitSubtitleByLine,
      outputPath: outputPath,
    );
    return _enqueueRequest(request: request);
  }

  Future<VideoComposeTaskState> retryFailedTask({
    required String taskId,
    required SubtitleStyle subtitleStyle,
    required Alignment subtitleAlignment,
  }) async {
    await ready;
    await _systemInterruption;
    final VideoComposeTaskState? old = _taskMap[taskId];
    if (old == null) {
      throw StateError('任务不存在');
    }
    final String newOutput = await _outputPathService.buildOutputPath(
      old.request.title,
    );
    final VideoComposeRequest request = VideoComposeRequest(
      videoId: old.request.videoId,
      videoPath: old.request.videoPath,
      title: old.request.title,
      primarySubtitlePath: old.request.primarySubtitlePath,
      secondarySubtitlePath: old.request.secondarySubtitlePath,
      primaryFontLanguage: old.request.primaryFontLanguage,
      secondaryFontLanguage: old.request.secondaryFontLanguage,
      renderSecondarySubtitle: old.request.renderSecondarySubtitle,
      continuousSubtitle: old.request.continuousSubtitle,
      embedSoftSubtitles: old.request.embedSoftSubtitles,
      softSubtitleOnly: old.request.softSubtitleOnly,
      softSubtitleUseSourceQuality: old.request.softSubtitleUseSourceQuality,
      softSubtitleTracks: old.request.softSubtitleTracks,
      resolution: old.request.resolution,
      renderMode: old.request.renderMode,
      subtitleStyle: subtitleStyle,
      subtitleStylePortrait: old.request.subtitleStylePortrait,
      subtitlePreset: old.request.subtitlePreset,
      subtitleAlignment: old.request.subtitlePlacement != null
          ? old.request.subtitleAlignment
          : subtitleAlignment,
      subtitlePlacement: old.request.subtitlePlacement,
      splitSubtitleByLine: old.request.splitSubtitleByLine,
      subtitleItemGap: old.request.subtitleItemGap,
      subtitleRendererVersion: old.request.subtitleRendererVersion,
      outputPath: newOutput,
    );
    return _enqueueRequest(request: request);
  }

  Future<VideoComposeTaskState> _enqueueRequest({
    required VideoComposeRequest request,
  }) async {
    // Resolving the output path can outlive the initial interruption check.
    // Recheck immediately before insertion, without an intervening await.
    while (_systemInterruption != null) {
      await _systemInterruption;
    }
    final String taskId =
        '${request.videoId}_${DateTime.now().millisecondsSinceEpoch}';
    const String stageMessage = '排队中';
    final VideoComposeTaskState state = VideoComposeTaskState(
      taskId: taskId,
      request: request,
      createdAt: DateTime.now(),
      stage: VideoComposeStage.queued,
      progress: 0,
      message: stageMessage,
    );
    _taskMap[taskId] = state;
    _queueTaskIds.add(taskId);
    notifyListeners();
    _saveTasks();
    unawaited(_processQueue());
    return state;
  }

  Future<void> _processQueue() async {
    if (_isProcessing ||
        _storageMaintenance ||
        _taskDeletionHolds > 0 ||
        _systemInterruptionHolds > 0) {
      return;
    }
    _isProcessing = true;
    try {
      while (_queueTaskIds.isNotEmpty &&
          _taskDeletionHolds == 0 &&
          _systemInterruptionHolds == 0) {
        final String taskId = _queueTaskIds.removeAt(0);
        final VideoComposeTaskState? task = _taskMap[taskId];
        if (task == null) {
          continue;
        }
        _runningTaskId = taskId;
        final generation = ++_runGeneration;
        bool canPublish() =>
            _runningTaskId == taskId && generation == _runGeneration;
        final completion = _runningTaskCompletion = Completer<void>();
        _setTask(
          taskId,
          stage: VideoComposeStage.preparing,
          progress: 0.02,
          message: '准备中',
        );
        try {
          await _runTask(
            taskId: taskId,
            request: task.request,
            canPublish: canPublish,
          );
          if (canPublish()) {
            _setTask(
              taskId,
              stage: VideoComposeStage.completed,
              progress: 1,
              message: '已完成',
              error: null,
            );
          }
        } catch (e) {
          if (canPublish()) {
            _setTask(
              taskId,
              stage: VideoComposeStage.failed,
              progress: 0,
              message: '处理失败',
              error: e.toString(),
            );
          }
        } finally {
          _runningTaskId = null;
          _runningTaskCompletion = null;
          completion.complete();
          notifyListeners();
        }
      }
    } finally {
      _isProcessing = false;
      notifyListeners();
    }
  }

  void _setTask(
    String taskId, {
    VideoComposeStage? stage,
    double? progress,
    String? message,
    String? error,
  }) {
    final VideoComposeTaskState? old = _taskMap[taskId];
    if (old == null) return;

    DateTime? completedAt = old.completedAt;
    if (stage != null &&
        (stage == VideoComposeStage.completed ||
            stage == VideoComposeStage.failed)) {
      completedAt = DateTime.now();
    }

    _taskMap[taskId] = old.copyWith(
      stage: stage,
      progress: progress,
      message: message,
      error: error,
      completedAt: completedAt,
    );
    notifyListeners();

    if (stage != null && stage != old.stage) {
      unawaited(_saveTasks());
    }
  }

  Future<void> _runTask({
    required String taskId,
    required VideoComposeRequest request,
    required bool Function() canPublish,
  }) async {
    if (!canPublish()) throw StateError('视频合成已中断');
    MaterializedMediaLease? lease;
    final cancellation = Completer<void>();
    _materializationCancellations[taskId] = cancellation;
    try {
      var effectiveRequest = request;
      final item = _library.getVideo(request.videoId);
      final online =
          item != null &&
          itemNeedsOnlineMaterialization(
            source: item.sourceRef,
            path: item.path,
          );
      if (online) {
        final cloud = isCloudDriveMedia(
          source: item.sourceRef,
          path: item.path,
        );
        final label = item.sourceRef?.podcast != null
            ? '正在准备播客音视频素材'
            : cloud
            ? '正在准备网盘视频素材'
            : '正在准备 Bilibili 音视频素材';
        _materializationProgress[taskId] = MediaMaterializationProgress(
          stage: MediaMaterializationStage.resolving,
          progress: 0,
          message: label,
        );
        _setTask(
          taskId,
          stage: VideoComposeStage.materializing,
          progress: 0.01,
          message: '正在准备本地视频素材',
        );
        lease = await _library.acquireMaterializedMedia(
          request.videoId,
          MediaMaterializationRequirement.completeMedia,
          targetHeight: cloud ? null : _targetHeight(request.resolution),
          cancelSignal: cancellation.future,
          onProgress: (value) {
            if (!canPublish()) return;
            _materializationProgress[taskId] = value;
            _setTask(
              taskId,
              stage: VideoComposeStage.materializing,
              progress: value.progress * 0.18,
              message: '${value.message}${_materializationDetails(value)}',
            );
          },
        );
        effectiveRequest = request.copyWith(videoPath: lease.requiredVideoPath);
        _materializationProgress.remove(taskId);
      }
      if (cancellation.isCompleted || !canPublish()) {
        throw StateError('视频合成已取消');
      }
      await _orchestrator.run(
        taskId: taskId,
        request: effectiveRequest,
        onArtifact: (String filePath) {
          _artifactCleaner.trackTaskArtifact(taskId, filePath);
        },
        onStatus:
            ({
              VideoComposeStage? stage,
              double? progress,
              String? message,
              String? error,
            }) {
              if (!canPublish()) return;
              _setTask(
                taskId,
                stage: stage,
                progress: progress == null
                    ? null
                    : lease == null
                    ? progress
                    : 0.18 + progress * 0.82,
                message: message,
                error: error,
              );
            },
      );
    } finally {
      _materializationCancellations.remove(taskId);
      _materializationProgress.remove(taskId);
      await lease?.release();
      await _artifactCleaner.cleanupTaskArtifacts(taskId);
    }
  }

  int? _targetHeight(VideoComposeResolution resolution) => switch (resolution) {
    VideoComposeResolution.source => null,
    VideoComposeResolution.p360 => 360,
    VideoComposeResolution.p480 => 480,
    VideoComposeResolution.p720 => 720,
    VideoComposeResolution.p1080 => 1080,
    VideoComposeResolution.p1440 => 1440,
    VideoComposeResolution.p2160 => 2160,
  };

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }

  String _materializationDetails(MediaMaterializationProgress value) {
    if (value.stage != MediaMaterializationStage.downloadingVideo &&
        value.stage != MediaMaterializationStage.downloadingAudio) {
      return '';
    }
    final total = value.totalBytes == null
        ? _formatBytes(value.receivedBytes)
        : '${_formatBytes(value.receivedBytes)} / '
              '${_formatBytes(value.totalBytes!)}';
    final speed = value.bytesPerSecond > 0
        ? ' · ${_formatBytes(value.bytesPerSecond.round())}/s'
        : '';
    final eta = value.remaining == null
        ? ''
        : ' · 剩余约 ${value.remaining!.inSeconds}s';
    return ' · $total$speed$eta';
  }
}
