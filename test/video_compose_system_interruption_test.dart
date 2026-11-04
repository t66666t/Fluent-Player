import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/model_background_tasks.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/models/video_compose_models.dart';
import 'package:video_player_app/services/model_task_interruption.dart';
import 'package:video_player_app/services/video_compose/video_compose_ass_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_executor.dart';
import 'package:video_player_app/services/video_compose/video_compose_font_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_orchestrator.dart';
import 'package:video_player_app/services/video_compose/video_compose_output_path_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_precise_renderer.dart';
import 'package:video_player_app/services/video_compose/video_compose_probe_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_subtitle_service.dart';
import 'package:video_player_app/services/video_compose/video_compose_types.dart';
import 'package:video_player_app/services/video_compose_manager.dart';

import 'support/compose_queue_fakes.dart';

const _tasks = MethodChannel('com.example.video_player_app/model_tasks');
const _paths = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late MemoryComposeStore store;
  late RecordingComposeCleaner cleaner;
  late _ControlledExecutor executor;
  late _OutputPaths outputPaths;
  late InferenceScheduler scheduler;
  late VideoComposeManager manager;
  late List<String> interruptedOwners;
  var rejectNativeStart = false;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('compose-interruption-');
    await File('${directory.path}/source.mp4').writeAsBytes([1, 2, 3, 4]);
    ModelBackgroundTasks.resetForTesting();
    ModelBackgroundTasks.debugNativeTasksSupported = true;
    rejectNativeStart = false;
    messenger.setMockMethodCallHandler(_tasks, (call) async {
      if (rejectNativeStart && (call.arguments as Map)['inference'] == 1) {
        throw PlatformException(code: 'BACKGROUND_START');
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_paths, (_) async => directory.path);
    store = MemoryComposeStore([composeRecord('previously-completed')]);
    cleaner = RecordingComposeCleaner();
    executor = _ControlledExecutor();
    final fonts = VideoComposeFontService();
    scheduler = InferenceScheduler(
      openResources: () async => InferenceResourceSession(
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: 'android',
            processors: 8,
            capturedAt: DateTime.now(),
            memoryBytes: 16 * 1073741824,
            availableMemoryBytes: 8 * 1073741824,
          ),
        ),
      ),
    );
    outputPaths = _OutputPaths(directory);
    final orchestrator = VideoComposeOrchestrator(
      probeService: const VideoComposeProbeService(),
      subtitleService: const VideoComposeSubtitleService(),
      assRenderer: VideoComposeAssRenderer(fonts),
      fontService: fonts,
      preciseRenderer: VideoComposePreciseRenderer(),
      executor: executor,
      outputPathService: outputPaths,
      scheduler: scheduler,
    );
    manager = VideoComposeManager(
      taskStore: store,
      artifactCleaner: cleaner,
      outputPathService: outputPaths,
      orchestrator: orchestrator,
    );
    await manager.ready;
    interruptedOwners = [];
    installModelTaskInterruptionHandler(
      pauseTranscription: () => interruptedOwners.add('asr'),
      cancelTranslation: () => interruptedOwners.add('translation'),
      cancelOcr: () async => interruptedOwners.add('ocr'),
      modelCenterLoaded: () => true,
      pauseModelDownloads: () async => interruptedOwners.add('models'),
      videoComposeManager: manager,
    );
  });

  tearDown(() async {
    for (var i = 0; i < 1000; i++) {
      executor.finishAll();
      if (manager.runningTask == null && manager.queuedTasks.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await ModelBackgroundTasks.settleForTesting();
    ModelBackgroundTasks.resetForTesting();
    manager.dispose();
    messenger.setMockMethodCallHandler(_tasks, null);
    messenger.setMockMethodCallHandler(_paths, null);
    await directory.delete(recursive: true);
  });

  Future<VideoComposeTaskState> enqueue(String id) => manager.enqueue(
    videoId: id,
    videoPath: '${directory.path}/source.mp4',
    title: id,
    primarySubtitlePath: null,
    secondarySubtitlePath: null,
    renderSecondarySubtitle: false,
    continuousSubtitle: false,
    embedSoftSubtitles: false,
    softSubtitleOnly: true,
    softSubtitleUseSourceQuality: true,
    softSubtitleTracks: const [],
    resolution: VideoComposeResolution.source,
    renderMode: VideoComposeRenderMode.approximate,
    subtitleStyle: const SubtitleStyle(),
    subtitleStylePortrait: const SubtitleStyle(),
    subtitleAlignment: Alignment.bottomCenter,
    splitSubtitleByLine: false,
    customOutputPath: directory.path,
  );

  Future<void> waitFor(bool Function() predicate) async {
    for (var i = 0; i < 1500; i++) {
      if (predicate()) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  Future<void> nativeInterrupt() async {
    await ModelBackgroundTasks.settleForTesting();
    final reply = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      _tasks.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('interrupted'),
      ),
      (_) => reply.complete(),
    );
    await reply.future;
    await Future<void>.delayed(Duration.zero);
  }

  VideoComposeTaskState task(String id) =>
      manager.allTasks.singleWhere((task) => task.taskId == id);

  test('ordinary completion keeps queue dispatch and history', () async {
    final first = await enqueue('first');
    final second = await enqueue('second');
    await waitFor(() => executor.runs.length == 1);
    executor.finishAll();
    await waitFor(() => executor.runs.length == 2);
    executor.finishAll();
    await waitFor(() => manager.runningTask == null);
    expect(task(first.taskId).stage, VideoComposeStage.completed);
    expect(task(second.taskId).stage, VideoComposeStage.completed);
    expect(task('previously-completed').stage, VideoComposeStage.completed);
    expect(cleaner.deletions, isEmpty);
  });

  test(
    'native interruption cancels active compose and keeps queued history',
    () async {
      final first = await enqueue('first');
      final second = await enqueue('second');
      await waitFor(() => executor.runs.isNotEmpty);
      await nativeInterrupt();
      await waitFor(() => manager.runningTask == null);
      expect(executor.cancelCalls, 1);
      expect(executor.runs, hasLength(1));
      expect(manager.queuedTasks, isEmpty);
      expect(task(first.taskId).stage, VideoComposeStage.failed);
      expect(task(second.taskId).stage, VideoComposeStage.failed);
      expect(task('previously-completed').stage, VideoComposeStage.completed);
      expect(manager.allTasks, hasLength(3));
      expect(cleaner.deletions, isEmpty);
      expect(interruptedOwners, ['asr', 'translation', 'ocr', 'models']);
    },
  );

  test(
    'late progress and success cannot replace interrupted failure',
    () async {
      final first = await enqueue('first');
      final second = await enqueue('second');
      await waitFor(() => executor.runs.isNotEmpty);
      final previousRun = executor.runs.single;
      await nativeInterrupt();
      previousRun.onProgress(.99);
      executor.finishAll();
      await waitFor(() => manager.runningTask == null);
      expect(task(first.taskId).stage, VideoComposeStage.failed);
      expect(task(first.taskId).message, contains('中断'));
      expect(task(second.taskId).stage, VideoComposeStage.failed);
      expect(executor.runs, hasLength(1));
      expect(cleaner.deletions, isEmpty);
    },
  );

  test(
    'native foreground-start rejection also interrupts compose owner',
    () async {
      rejectNativeStart = true;
      final first = await enqueue('first');
      await ModelBackgroundTasks.settleForTesting();
      await waitFor(() => manager.runningTask == null);
      expect(task(first.taskId).stage, VideoComposeStage.failed);
      expect(manager.queuedTasks, isEmpty);
      expect(cleaner.deletions, isEmpty);
      expect(interruptedOwners, ['asr', 'translation', 'ocr', 'models']);
    },
  );
  test(
    'interruption cancels a waiting compose without releasing another AI owner',
    () async {
      final releaseOtherOwner = await scheduler.acquire();
      try {
        final first = await enqueue('first');
        final second = await enqueue('second');
        await waitFor(() => scheduler.waiting == 2);
        await nativeInterrupt();
        await waitFor(() => manager.runningTask == null);
        expect(executor.runs, isEmpty);
        expect(manager.queuedTasks, isEmpty);
        expect(task(first.taskId).stage, VideoComposeStage.failed);
        expect(task(second.taskId).stage, VideoComposeStage.failed);
        expect(scheduler.busy, isTrue);
        expect(scheduler.waiting, 1);
      } finally {
        releaseOtherOwner();
      }
    },
  );

  test(
    'path lookup crossing interruption waits for old owner before retry dispatch',
    () async {
      final failed = await enqueue('failed');
      await waitFor(() => executor.runs.length == 1);
      executor.runs.single.done.completeError(StateError('controlled failure'));
      await waitFor(() => manager.runningTask == null);
      expect(task(failed.taskId).stage, VideoComposeStage.failed);

      final active = await enqueue('active');
      await waitFor(() => executor.runs.length == 2);
      executor.finishOnCancel = false;
      final oldRun = executor.runs.last;
      final pathGate = outputPaths.pathGate = Completer<void>();
      final pathEntered = outputPaths.pathEntered = Completer<void>();
      var retryDispatched = false;
      final retrying = manager
          .retryFailedTask(
            taskId: failed.taskId,
            subtitleStyle: const SubtitleStyle(),
            subtitleAlignment: Alignment.bottomCenter,
          )
          .then((value) {
            retryDispatched = true;
            return value;
          });
      await pathEntered.future;
      await nativeInterrupt();
      final stopping = manager.interruptForSystem();
      expect(identical(stopping, manager.interruptForSystem()), isTrue);
      pathGate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(retryDispatched, isFalse);
      expect(manager.queuedTasks, isEmpty);
      expect(executor.cancelCalls, 1);

      oldRun.done.complete();
      await stopping;
      final retried = await retrying;
      await waitFor(() => executor.runs.length == 3);
      expect(task(active.taskId).stage, VideoComposeStage.failed);
      expect(task(retried.taskId).stage, VideoComposeStage.rendering);
      final newProgress = task(retried.taskId).progress;
      oldRun.onProgress(.99);
      expect(task(active.taskId).stage, VideoComposeStage.failed);
      expect(task(retried.taskId).progress, newProgress);
      executor.finishAll();
      await waitFor(() => manager.runningTask == null);
      expect(task(retried.taskId).stage, VideoComposeStage.completed);
      expect(task('previously-completed').stage, VideoComposeStage.completed);
      expect(cleaner.deletions, isEmpty);
    },
  );
}

class _Run {
  _Run(this.request, this.onProgress);
  final VideoComposeRequest request;
  final VideoComposeProgressCallback onProgress;
  final done = Completer<void>();
}

/// Intentionally reports normal completion even after cancellation. This
/// exercises the manager's ownership gate rather than relying on backend luck.
class _ControlledExecutor extends VideoComposeExecutor {
  final runs = <_Run>[];
  var cancelCalls = 0;
  bool finishOnCancel = true;

  @override
  Future<void> execute({
    required VideoComposeRequest request,
    required String filter,
    String? preciseSubtitleConcatPath,
    required List<ComposeSubtitleInput> softSubtitleInputs,
    required Duration duration,
    required bool transcodeVideo,
    required VideoComposeProgressCallback onProgress,
    void Function(String encoder)? onEncoderChanged,
    void Function(String path)? onArtifact,
    int outputWidth = 1920,
    int outputHeight = 1080,
    double frameRate = 30,
  }) async {
    final run = _Run(request, onProgress);
    runs.add(run);
    onProgress(.2);
    await run.done.future;
    await File(request.outputPath).writeAsBytes(List.filled(2048, 7));
    onProgress(1);
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (finishOnCancel) finishAll();
  }

  void finishAll() {
    for (final run in runs) {
      if (!run.done.isCompleted) run.done.complete();
    }
  }
}

class _OutputPaths extends VideoComposeOutputPathService {
  _OutputPaths(this.directory);
  final Directory directory;
  Completer<void>? pathGate;
  Completer<void>? pathEntered;

  @override
  Future<String> buildOutputPath(String title) async {
    final gate = pathGate;
    pathGate = null;
    pathEntered?.complete();
    pathEntered = null;
    await gate?.future;
    return '${directory.path}/${buildOutputFileName(title)}';
  }
}
