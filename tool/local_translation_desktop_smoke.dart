// Run with the real desktop runner and AOT Release libraries, not flutter_tester:
// flutter build windows --release -t tool/local_translation_desktop_smoke.dart
//   --dart-define=TRANSLATION_SMOKE_ROOT=<absolute model directory>
//   --dart-define=TRANSLATION_SMOKE_OUTPUT=<absolute report filename>
//   --dart-define=TRANSLATION_SMOKE_VIDEO=<optional local video>
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_subtitle_translator.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/translation_inference.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'package:video_player_app/services/app_storage_service.dart';

// Only weights are external. Settings, leases, checkpoints and the scheduler
// exercise production implementations, without touching the user's app data.
class _ReadOnlyWeightsCenter extends ModelCenterService {
  _ReadOnlyWeightsCenter(this.weights, {required super.storage});
  final String weights;

  @override
  Future<Directory> modelDirectory(ModelArtifact model) async =>
      Directory(p.join(weights, model.id));
}

class _ExitingWorker implements TranslationInference {
  _ExitingWorker(this.worker);
  final ProcessTranslationInference worker;
  var calls = 0;
  @override
  String get backend => worker.backend;
  @override
  int get gpuLayers => worker.gpuLayers;
  @override
  Future<TranslationGeneration> generate(
    String prompt, {
    String? grammar,
    bool structured = false,
    bool reusePromptPrefix = true,
    void Function(String)? onDelta,
  }) {
    // Terminate a real native process between batches, after valid subtitles
    // have already been saved. The player must retain them and finish on CPU.
    if (calls++ == 1) worker.cancel();
    return worker.generate(
      prompt,
      grammar: grammar,
      structured: structured,
      reusePromptPrefix: reusePromptPrefix,
      onDelta: onDelta,
    );
  }

  @override
  void cancel() => worker.cancel();
  @override
  Future<void> dispose() => worker.dispose();
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

List<String> _windowsGpuModules() {
  if (!Platform.isWindows) return const [];
  final getModule = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf16>),
        Pointer<Void> Function(Pointer<Utf16>)
      >('GetModuleHandleW');
  final loaded = <String>[];
  for (final name in ['ggml-vulkan.dll', 'igvk64.dll']) {
    final wide = name.toNativeUtf16();
    try {
      if (getModule(wide) != nullptr) loaded.add(name);
    } finally {
      calloc.free(wide);
    }
  }
  return loaded;
}

const _texts = [
  'Good morning, everyone.',
  'Today we are going to explore how this machine works.',
  'First, make sure the power is turned off.',
  'Do not touch the red wire.',
  'Can you pass me the small screwdriver?',
  'There should be three screws on the back.',
  'Be careful. This part is very fragile.',
  'I think we found the problem.',
  'The connection was loose the whole time.',
  'Let us try it again.',
  'It works! I cannot believe it.',
  'Thank you for your help.',
  'How long will the battery last?',
  'About six hours under normal conditions.',
  'You can change the brightness in the settings.',
  'The next train leaves at half past seven.',
  'We need to leave now if we want to catch it.',
  'Wait, I forgot my keys.',
  'They are on the table next to the window.',
  'Would you like some tea before we go?',
  'No, thanks. I have already had two cups.',
  'All right, see you tomorrow.',
  'Take care and have a safe journey.',
  'Good night.',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Present the runner's first frame before media_kit waits for video output.
  // The Windows runner only shows its window after Flutter draws that frame.
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            LinearProgressIndicator(),
            Text('Initializing translation smoke test'),
          ],
        ),
      ),
    ),
  );
  await WidgetsBinding.instance.endOfFrame;
  const weights = String.fromEnvironment('TRANSLATION_SMOKE_ROOT');
  const output = String.fromEnvironment('TRANSLATION_SMOKE_OUTPUT');
  const videoPath = String.fromEnvironment('TRANSLATION_SMOKE_VIDEO');
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'executable': Platform.resolvedExecutable,
    'startedAt': DateTime.now().toIso8601String(),
    'runs': <Map<String, Object?>>[],
  };
  final runs = report['runs']! as List<Map<String, Object?>>;
  final activity = ValueNotifier('Loading desktop translation smoke test');
  VideoPlayerController? video;
  Directory? temporary;
  var success = false;
  try {
    _require(
      p.isAbsolute(weights) && p.isAbsolute(output),
      'Provide absolute model and report paths',
    );
    _require(
      !Platform.environment.containsKey('LLAMADART_NATIVE_LIB_DIR'),
      'Test packaged native libraries without an environment override',
    );
    report['phase'] = 'initialize';
    await File(output).writeAsString(jsonEncode(report));
    // Keep this standalone test host from reading the user's preferences.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    temporary = await Directory.systemTemp.createTemp('desktop-translation-');
    final storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.linux,
        support: Directory(p.join(temporary!.path, 'support')),
        documents: Directory(p.join(temporary.path, 'documents')),
        defaultData: Directory(p.join(temporary.path, 'data')),
        executable: Directory(p.join(temporary.path, 'executable')),
      ),
    );
    await storage.initialize();
    final center = _ReadOnlyWeightsCenter(weights, storage: storage);
    await center.initialize();
    NativeVideoPlayerMediaKit.ensureInitialized();
    if (videoPath.isNotEmpty) {
      report['phase'] = 'video';
      await File(output).writeAsString(jsonEncode(report));
      video = VideoPlayerController.file(File(videoPath));
      await video.initialize().timeout(const Duration(seconds: 30));
      await video.setVolume(0);
      await video.setLooping(true);
      await video.play();
    }
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              if (video != null)
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: video.value.aspectRatio,
                      child: VideoPlayer(video),
                    ),
                  ),
                ),
              const LinearProgressIndicator(),
              ValueListenableBuilder<String>(
                valueListenable: activity,
                builder: (context, value, child) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    await LlamaLogging.configure(level: LlamaLogLevel.warn);
    final worker = ProcessTranslationInference.bundledExecutable();
    _require(
      worker != null,
      'Desktop bundle is missing the translation worker',
    );
    report['worker'] = worker;
    final scheduler = InferenceScheduler();
    final translator = LocalSubtitleTranslator(
      center: center,
      scheduler: scheduler,
    );
    for (final id in ['hy-mt2-1.8b-q4', 'qwen3-4b-q4']) {
      final model = center.artifact(id)!;
      final modelFile = File(p.join(weights, id, model.files.first.name));
      _require(
        await modelFile.length() == model.files.first.bytes,
        'Model weight length mismatch: $id',
      );
      center.downloads[id] = ModelDownload(
        artifactId: id,
        phase: ModelDownloadPhase.installed,
        received: model.bytes,
      );
      await center.settingsChanged();
      ModelJobSpec specification(TranslationAcceleration acceleration) =>
          ModelJobSpec(
            profile: ModelServiceProfile(
              id: 'desktop-check',
              name: model.name,
              kind: TranscriptionServiceKind.local,
              model: id,
            ),
            artifactIdentity: model.identity,
            translation: LocalTranslationOptions(acceleration: acceleration),
          );
      // The second automatic run must reuse the measured choice without probing.
      for (final mode in [
        ...TranslationAcceleration.values,
        TranslationAcceleration.auto,
      ]) {
        final cached =
            mode == TranslationAcceleration.auto &&
            runs.any((run) => run['model'] == id && run['mode'] == 'auto');
        report['phase'] = '$id / ${mode.name}';
        await File(output).writeAsString(jsonEncode(report));
        final progress = <double>[];
        LocalTranslationMetrics? metrics;
        final result = await translator.translate(
          texts: _texts,
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '简体中文',
          specification: specification(mode),
          resume: false,
          onProgress: progress.add,
          onActivity: (value) => activity.value = '$id / ${mode.name}: $value',
          onMetrics: (value) => metrics = value,
        );
        _require(result.length == _texts.length, 'Subtitle count changed');
        for (var i = 0; i < result.length; i++) {
          validateLocalTranslation(
            _texts[i],
            result[i],
            targetLanguage: 'zh-CN',
          );
          _require(
            RegExp(r'[\u4e00-\u9fff]').hasMatch(result[i]),
            'Empty translation',
          );
        }
        _require(
          progress.last == 1 && !scheduler.busy && !center.hasModelLeases,
          'Progress or native resources did not finish',
        );
        final gpuModules = _windowsGpuModules();
        if (Platform.isWindows) {
          _require(
            gpuModules.isEmpty,
            'The player loaded a GPU driver instead of isolating it: $gpuModules',
          );
        }
        if (mode == TranslationAcceleration.cpu) {
          _require(metrics!.gpuLayers == 0, 'Explicit CPU was ignored');
        }
        if (cached) {
          _require(metrics!.calibrationMs == 0, 'Repeated GPU calibration');
        }
        runs.add({
          'model': id,
          'mode': mode.name,
          'cached': cached,
          'cues': result.length,
          'metrics': metrics!.toJson(),
          'gpuModules': gpuModules,
          'translations': result,
        });
        await File(
          output,
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      }
      final faultProgress = <double>[];
      LocalTranslationMetrics? faultMetrics;
      final afterWorkerExit =
          await LocalSubtitleTranslator(
            center: center,
            scheduler: scheduler,
            loadInference: (path, params, gpu, cancel) async => gpu
                ? _ExitingWorker(
                    await ProcessTranslationInference.load(
                      executable: worker!,
                      modelPath: path,
                      threads: params.numberOfThreads,
                      cancelSignal: cancel,
                    ),
                  )
                : NativeTranslationInference.load(path, params),
          ).translate(
            texts: _texts,
            sourceLanguage: 'en',
            targetLanguage: 'zh-CN',
            targetLabel: '简体中文',
            specification: specification(TranslationAcceleration.gpu),
            resume: false,
            checkpointScope: 'worker-exit',
            onProgress: faultProgress.add,
            onMetrics: (value) => faultMetrics = value,
            onActivity: (value) => activity.value = '$id / worker exit: $value',
          );
      for (var i = 0; i < afterWorkerExit.length; i++) {
        validateLocalTranslation(
          _texts[i],
          afterWorkerExit[i],
          targetLanguage: 'zh-CN',
        );
      }
      _require(
        afterWorkerExit.length == _texts.length &&
            faultProgress.last == 1 &&
            faultMetrics!.backend == 'CPU' &&
            !scheduler.busy &&
            !center.hasModelLeases,
        'Worker exit did not finish on CPU',
      );
      _require(
        _windowsGpuModules().isEmpty,
        'Worker exit leaked GPU into the player',
      );
      runs.add({
        'model': id,
        'mode': 'worker-exit',
        'metrics': faultMetrics!.toJson(),
        'cues': afterWorkerExit.length,
        'progress': faultProgress,
      });
      final cancel = Completer<void>();
      final stopping = Stopwatch();
      var cancelled = false;
      try {
        await translator.translate(
          texts: _texts,
          sourceLanguage: 'en',
          targetLanguage: 'zh-CN',
          targetLabel: '简体中文',
          specification: specification(TranslationAcceleration.gpu),
          resume: false,
          cancelSignal: cancel.future,
          onProgress: (_) {},
          onActivity: (value) {
            if (value != null &&
                value.contains('本批已生成') &&
                !cancel.isCompleted) {
              stopping.start();
              cancel.complete();
            }
          },
        );
      } on StateError catch (error) {
        cancelled = error.message == '字幕翻译已取消';
      }
      _require(
        cancelled &&
            cancel.isCompleted &&
            !scheduler.busy &&
            !center.hasModelLeases,
        'Native cancellation did not release the model',
      );
      _require(
        stopping.elapsed < const Duration(seconds: 10),
        'Cancellation is too slow',
      );
      runs.add({'model': id, 'cancelMs': stopping.elapsedMilliseconds});
      // Cancellation must not poison the next native model load.
      final resumed = await translator.translate(
        texts: const ['Thank you for your help.'],
        sourceLanguage: 'en',
        targetLanguage: 'zh-CN',
        targetLabel: '简体中文',
        specification: specification(TranslationAcceleration.auto),
        resume: false,
        onProgress: (_) {},
      );
      validateLocalTranslation(
        'Thank you for your help.',
        resumed.single,
        targetLanguage: 'zh-CN',
      );
    }
    if (video != null) {
      _require(
        video.value.isPlaying && !video.value.hasError,
        'Video playback failed while translating',
      );
      report['videoPlaying'] = video.value.isPlaying;
      report['videoPositionMs'] = video.value.position.inMilliseconds;
    }
    success = true;
  } catch (error, stack) {
    report['error'] = '$error';
    report['stack'] = '$stack';
  } finally {
    await video?.dispose();
    report['success'] = success;
    report['finishedAt'] = DateTime.now().toIso8601String();
    if (p.isAbsolute(output)) {
      await File(
        output,
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    }
    if (temporary != null) await temporary.delete(recursive: true);
  }
  exit(success ? 0 : 1);
}
