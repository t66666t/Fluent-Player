import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/services/ocr_inference_engine.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_processing_worker.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

void main() {
  if (Platform.isWindows) {
    DynamicLibrary.open(File('windows/runtime/onnxruntime.dll').absolute.path);
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('OCR_RUNTIME_ROOT');
  final records = <Map<String, Object?>>[];
  OcrModelFiles files(OcrModelPreset preset) => OcrModelFiles(
    detection: '$root/${preset.detection}/inference.onnx',
    recognition: '$root/${preset.recognition}/inference.onnx',
    dictionary: '$root/${preset.recognition}/inference.yml',
    detectionConfig: '$root/${preset.detection}/inference.yml',
    legacy: false,
    identity: preset.id,
  );
  im.Image sample({int lines = 1, bool long = false}) {
    final image = im.Image(
      width: long ? 1280 : 640,
      height: lines == 1 ? 128 : 200,
    );
    im.fill(image, color: im.ColorRgb8(28, 32, 40));
    im.drawString(
      image,
      long ? 'Long subtitle OCR testing 123456789' : 'OCR subtitle 123',
      font: im.arial48,
      x: 20,
      y: 30,
      color: im.ColorRgb8(255, 255, 255),
    );
    if (lines > 1) {
      im.drawString(
        image,
        'Second subtitle 456',
        font: im.arial48,
        x: 20,
        y: 112,
        color: im.ColorRgb8(255, 255, 255),
      );
    }
    return image;
  }

  test(
    'all downloadable OCR presets execute real detection and CTC on the packaged runtime',
    () async {
      for (final preset in (await loadOcrPresets()).where((m) => !m.legacy)) {
        final engine = OcrInferenceEngine(
          files(preset),
          cpuThreads: 2,
          batchLimit: 4,
        );
        final watch = Stopwatch()..start();
        try {
          await engine.initialize();
          final startup = watch.elapsedMilliseconds;
          final single = await engine.recognizeImage(sample());
          final two = await engine.recognizeImage(sample(lines: 2));
          final wide = await engine.recognizeImage(sample(long: true));
          expect(
            single.text,
            contains('123'),
            reason: '${preset.id}: ${single.text}',
          );
          expect(
            two.text,
            contains('456'),
            reason: '${preset.id}: ${two.text}',
          );
          expect(
            wide.text,
            contains('123456789'),
            reason: '${preset.id}: ${wide.text}',
          );
          records.add({
            'preset': preset.id,
            'runtime': OrtEnv.version,
            'startupMs': startup,
            'totalMs': watch.elapsedMilliseconds,
            'single': single.text,
            'two': two.text,
            'wide': wide.text,
            'backend': engine.activeBackend,
          });
        } finally {
          await engine.dispose();
        }
      }
      final output = File('.artifacts/ocr-upgrade/native-models.json');
      await output.parent.create(recursive: true);
      await output.writeAsString(
        const JsonEncoder.withIndent('  ').convert(records),
      );
    },
    skip: root.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'raw worker keeps region histories independent and confirms unchanged frames from cache',
    () async {
      final preset = (await loadOcrPresets()).firstWhere(
        (m) => m.id == 'ppocr-v6-small',
      );
      final directory = await Directory.systemTemp.createTemp(
        'ocr-raw-native-',
      );
      OcrProcessingWorker? worker;
      try {
        final image = sample();
        final raw = File('${directory.path}/frames.rgb');
        await raw.writeAsBytes(image.getBytes(order: im.ChannelOrder.rgb));
        worker = await OcrProcessingWorker.start(
          files(preset),
          tracks: {1: files(preset), 2: files(preset)},
          batchLimit: 4,
        );
        Future<OcrFrameAnalysis> run(int track, int at) =>
            worker!.analyzeRawFrame(
              path: raw.path,
              offset: 0,
              width: image.width,
              height: image.height,
              atMs: at,
              track: track,
              threads: 2,
              batchLimit: 4,
            );
        expect((await run(1, 1000)).candidate, isFalse);
        expect((await run(2, 5000)).candidate, isFalse);
        final first = await run(1, 1100), second = await run(2, 5100);
        expect(first.candidate, isTrue);
        expect(first.boundaryMs, 1000);
        expect(second.candidate, isTrue);
        expect(second.boundaryMs, 5000);
        expect(first.text, contains('123'));
        expect(second.text, first.text);
        await worker.resetFrameHistory();
        final tuned = await worker.analyzeRawFrame(
          path: raw.path,
          offset: 0,
          width: image.width,
          height: image.height,
          atMs: 1000,
          track: 1,
          threads: 4,
          batchLimit: 4,
          probeCreditMs: 2000,
          remainingMediaMs: 120000,
        );
        expect(tuned.tuning?['testedThreads'], containsAll([2, 4]));
        expect(tuned.tuning?['valid'], isTrue);
      } finally {
        await worker?.close();
        await directory.delete(recursive: true);
      }
    },
    skip: root.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'worker checks each new session and reuses sessions when only the line batch changes',
    () async {
      final preset = (await loadOcrPresets()).firstWhere(
        (m) => m.id == 'ppocr-v6-small',
      );
      final directory = await Directory.systemTemp.createTemp('ocr-admission-');
      OcrProcessingWorker? worker;
      try {
        await expectLater(
          OcrProcessingWorker.start(
            files(preset),
            checkAllocation: (_) async => throw StateError('内存不足：测试拒绝加载'),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('测试拒绝加载'),
            ),
          ),
        );
        var allocations = 0;
        worker = await OcrProcessingWorker.start(
          files(preset),
          batchLimit: 4,
          checkAllocation: (bytes) async {
            expect(bytes, greaterThan(64 * 1024 * 1024));
            allocations++;
          },
        );
        final image = sample();
        final frame = File('${directory.path}/frame.rgb');
        await frame.writeAsBytes(image.getBytes(order: im.ChannelOrder.rgb));
        for (final batch in [4, 2, 1, 4]) {
          await worker.resetFrameHistory();
          final result = await worker.analyzeRawFrame(
            path: frame.path,
            offset: 0,
            width: image.width,
            height: image.height,
            atMs: 1000,
            track: 0,
            threads: 2,
            batchLimit: batch,
            residentModels: 1,
          );
          expect(result.backend, startsWith('CPU'));
        }
        expect(allocations, 1);
        await worker.releaseIdleModels();
        await worker.resetFrameHistory();
        await worker.analyzeRawFrame(
          path: frame.path,
          offset: 0,
          width: image.width,
          height: image.height,
          atMs: 1000,
          track: 0,
          threads: 2,
          batchLimit: 1,
        );
        expect(allocations, 2);
      } finally {
        await worker?.close();
        await directory.delete(recursive: true);
      }
    },
    skip: root.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an unavailable accelerator falls back to CPU with the same model',
    () async {
      final preset = (await loadOcrPresets()).firstWhere(
        (m) => m.id == 'ppocr-v6-small',
      );
      final engine = OcrInferenceEngine(files(preset), provider: 'NNAPI');
      try {
        final reading = await engine.recognizeImage(sample());
        expect(reading.text, contains('123'));
        expect(engine.activeBackend, startsWith('CPU'));
      } finally {
        await engine.dispose();
      }
    },
    skip: root.isEmpty || !Platform.isWindows,
  );

  test(
    'native models read Chinese Japanese Korean Latin and English reference frames',
    () async {
      final models = await loadOcrPresets();
      final multilingual = <String, Object?>{};
      for (final entry in {
        'chinese': 'ppocr-v6-small',
        'japanese': 'ppocr-v6-small',
        'korean': 'ppocr-v5-korean',
        'latin': 'ppocr-v5-latin',
        'english': 'ppocr-v5-en',
      }.entries) {
        final preset = models.firstWhere((m) => m.id == entry.value);
        final image = im.decodePng(
          await File(
            '.artifacts/ocr-upgrade/fixture/${entry.key}.png',
          ).readAsBytes(),
        )!;
        final engine = OcrInferenceEngine(
          files(preset),
          cpuThreads: 2,
          batchLimit: 4,
        );
        try {
          final result = await engine.recognizeImage(image);
          expect(result.text, isNotEmpty, reason: entry.key);
          expect(
            result.confidence,
            greaterThan(.55),
            reason: '${entry.key}: ${result.text}',
          );
          multilingual[entry.key] = {
            'text': result.text,
            'confidence': result.confidence,
          };
        } finally {
          await engine.dispose();
        }
      }
      await File(
        '.artifacts/ocr-upgrade/multilingual.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(multilingual));
    },
    skip: root.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Chinese and English regions keep independent content in a complete native video task',
    () async {
      SharedPreferences.setMockInitialValues({});
      final previousStorage = AppStorageService.instance;
      final directory = await Directory.systemTemp.createTemp('ocr-bilingual-');
      addTearDown(() async {
        AppStorageService.instance = previousStorage;
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory('${directory.path}/support'),
          documents: Directory('${directory.path}/documents'),
          defaultData: Directory('${directory.path}/data'),
          executable: Directory('${directory.path}/bin'),
        ),
      );
      AppStorageService.instance = storage;
      await storage.initialize();
      final center = ModelCenterService(storage: storage);
      final models = OcrModelManager(center: center);
      final frame = im.Image(width: 1280, height: 720);
      im.fill(frame, color: im.ColorRgb8(28, 32, 40));
      for (final entry in {'chinese': 128, 'english': 400}.entries) {
        final reference = im.decodePng(
          await File(
            '.artifacts/ocr-upgrade/fixture/${entry.key}.png',
          ).readAsBytes(),
        )!;
        im.compositeImage(
          frame,
          im.copyResize(reference, width: 640, height: 128),
          dstX: 320,
          dstY: entry.value,
        );
      }
      final imagePath = '${directory.path}/bilingual.png';
      final videoPath = '${directory.path}/bilingual.mp4';
      await File(imagePath).writeAsBytes(im.encodePng(frame));
      final encoded = await Process.run(await FFmpegUtils.ffmpegPath, [
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-loop',
        '1',
        '-framerate',
        '10',
        '-i',
        imagePath,
        '-t',
        '32',
        '-c:v',
        'libx264',
        '-threads',
        '1',
        '-pix_fmt',
        'yuv420p',
        videoPath,
      ]);
      expect(encoded.exitCode, 0, reason: '${encoded.stderr}');
      final library = _OcrLibrary(directory, videoPath);
      final manager = OcrSubtitleManager(
        library: library,
        modelManager: models,
      );
      final recognitionUpdates = <OcrSubtitleJob>[];
      manager.addListener(() {
        final job = manager.job;
        if (job?.status == OcrSubtitleJobStatus.recognizing) {
          recognitionUpdates.add(job!);
        }
      });
      try {
        await models.initialize();
        for (final id in ['ocr-v6-small-det', 'ocr-v6-small-rec']) {
          await center.importFiles(id, Directory('$root/$id'));
        }
        await manager.start(
          OcrSubtitleJob(
            videoId: 'bilingual',
            videoPath: videoPath,
            start: Duration.zero,
            end: const Duration(seconds: 32),
            tracks: [
              for (final entry in {
                OcrSubtitleLanguage.chinese: 128,
                OcrSubtitleLanguage.english: 400,
              }.entries)
                OcrSubtitleTrack(
                  number: entry.key == OcrSubtitleLanguage.chinese ? 1 : 2,
                  modelId: 'ppocr-v6-small',
                  language: entry.key,
                  region: NormalizedOcrRegion(
                    left: .25,
                    right: .75,
                    top: entry.value / 720,
                    bottom: (entry.value + 128) / 720,
                  ),
                ),
            ],
          ),
        );
        expect(
          manager.job!.status,
          OcrSubtitleJobStatus.completed,
          reason: manager.job!.error,
        );
        final outputs = await Future.wait(
          manager.job!.outputPaths.map((path) => File(path).readAsString()),
        );
        expect(outputs, hasLength(2));
        expect(outputs[0], contains('简体中文字幕识别测试'));
        expect(outputs[0], isNot(contains('English')));
        expect(outputs[1], contains('English subtitle test'));
        expect(outputs[1], isNot(contains('简体')));
        expect(manager.lastPerformance['workers'], inInclusiveRange(1, 2));
        expect(recognitionUpdates.first.progress, 0);
        final completed = <int, int>{1: 0, 2: 0};
        for (final update in recognitionUpdates) {
          final state = update.recognitionProgress!;
          var workMs = 0;
          for (final entry in state.completedByTrack.entries) {
            expect(
              entry.value.inMilliseconds,
              greaterThanOrEqualTo(completed[entry.key]!),
            );
            completed[entry.key] = entry.value.inMilliseconds;
            workMs += entry.value.inMilliseconds;
          }
          expect(
            update.progress,
            closeTo(
              (workMs / (state.total.inMilliseconds * 2)).clamp(0, .99),
              1e-9,
            ),
          );
        }
        expect(
          manager.job!.recognitionProgress!.completedByTrack.values,
          everyElement(const Duration(seconds: 32)),
        );
        expect(InferenceScheduler.instance.busy, isFalse);
        expect(center.hasModelLeases, isFalse);
        await File(
          '.artifacts/ocr-optimization-20261026/bilingual-native.json',
        ).writeAsString(
          const JsonEncoder.withIndent(
            '  ',
          ).convert({...manager.lastPerformance, 'outputs': outputs}),
        );
      } finally {
        manager.dispose();
        library.dispose();
        await center.shutdown();
        AppStorageService.instance = previousStorage;
        await directory.delete(recursive: true);
      }
    },
    skip: root.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'full raw video workflow automatically downloads models, writes distinct tracks and can restart after cancellation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final previousStorage = AppStorageService.instance;
      final directory = await Directory.systemTemp.createTemp('ocr-complete-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory('${directory.path}/support'),
          documents: Directory('${directory.path}/documents'),
          defaultData: Directory('${directory.path}/data'),
          executable: Directory('${directory.path}/bin'),
        ),
      );
      AppStorageService.instance = storage;
      await storage.initialize();
      final catalog = await loadModelCatalog();
      final transfer = _FixtureModelTransfer({
        for (final model in catalog.where((model) => model.engine == 'ppocr'))
          for (final file in model.files)
            for (final url in file.sources.values)
              Uri.parse(url).toString(): File('$root/${model.id}/${file.name}'),
      });
      final center = ModelCenterService(
        storage: storage,
        createDio: () => Dio()..httpClientAdapter = transfer,
      );
      final models = OcrModelManager(
        rootOverride: Directory('${directory.path}/data'),
        center: center,
      );
      final library = _OcrLibrary(
        directory,
        File('.artifacts/ocr-upgrade/fixture/subtitles.mp4').absolute.path,
      );
      final manager = OcrSubtitleManager(
        library: library,
        modelManager: models,
      );
      try {
        await models.initialize();
        final preset = await models.preset('ppocr-v6-small');
        expect(models.ready(preset), isFalse);
        final tracks = List.generate(
          2,
          (i) => OcrSubtitleTrack(
            number: i + 1,
            region: const NormalizedOcrRegion.subtitleDefault(),
            language: OcrSubtitleLanguage.chinese,
            modelId: preset.id,
          ),
        );
        OcrSubtitleJob request() => OcrSubtitleJob(
          videoId: 'native-video',
          videoPath: library.videoPath,
          tracks: tracks,
          start: const Duration(seconds: 1),
          // Player duration can include microseconds and outlast the video track.
          end: const Duration(seconds: 12, microseconds: 178567),
        );
        final progress = <double>[];
        void record() {
          if (manager.job != null) progress.add(manager.job!.progress);
        }

        manager.addListener(record);
        await manager.start(request());
        manager.removeListener(record);
        expect(
          manager.job!.status,
          OcrSubtitleJobStatus.completed,
          reason: manager.job!.error,
        );
        expect(manager.job!.outputPaths.toSet(), hasLength(2));
        expect(models.ready(preset), isTrue);
        expect(transfer.downloads, 4);
        expect(
          transfer.probes,
          center.artifact(preset.detection)!.files.first.sources.length,
        );
        final contents = await Future.wait(
          manager.job!.outputPaths.map((path) => File(path).readAsString()),
        );
        for (final text in contents) {
          expect(text, contains('字幕识别速度测试'));
          expect(text, contains('最后一条字幕'));
          expect(text, contains('00:00:01,'));
        }
        expect(library.registered, hasLength(2));
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
        }
        expect(InferenceScheduler.instance.busy, isFalse);
        expect(center.hasModelLeases, isFalse);
        expect(
          await Directory(
            '${directory.path}/data/ocr_temp/native-video',
          ).exists(),
          isFalse,
        );
        await File('.artifacts/ocr-upgrade/video-workflow.json').writeAsString(
          const JsonEncoder.withIndent(
            '  ',
          ).convert({...manager.lastPerformance, 'outputs': contents}),
        );
        final mirrored = OcrSubtitleJob(
          videoId: 'native-video',
          tracks: tracks,
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 11),
          videoPath: File(
            '.artifacts/ocr-upgrade/fixture/mirrored.mp4',
          ).absolute.path,
          mirrorHorizontal: true,
          mirrorVertical: true,
        );
        await manager.start(mirrored);
        expect(
          manager.job!.status,
          OcrSubtitleJobStatus.completed,
          reason: manager.job!.error,
        );
        expect(
          await File(manager.job!.outputPaths.first).readAsString(),
          contains('字幕识别速度测试'),
        );
        var cancelling = false;
        void cancel() {
          if (!cancelling &&
              manager.job?.status == OcrSubtitleJobStatus.recognizing) {
            cancelling = true;
            manager.cancel();
          }
        }

        manager.addListener(cancel);
        await manager.start(request());
        manager.removeListener(cancel);
        expect(manager.job!.status, OcrSubtitleJobStatus.cancelled);
        expect(InferenceScheduler.instance.busy, isFalse);
        expect(center.hasModelLeases, isFalse);
        await manager.start(request());
        expect(
          manager.job!.status,
          OcrSubtitleJobStatus.completed,
          reason: manager.job!.error,
        );
        final owner = await InferenceScheduler.instance.acquire();
        final queued = manager.start(request());
        for (
          var i = 0;
          i < 200 && manager.job?.statusMessage != '等待本地推理资源';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await manager.cancel();
        await queued;
        expect(manager.job!.status, OcrSubtitleJobStatus.cancelled);
        expect(InferenceScheduler.instance.busy, isTrue);
        owner();
        await manager.start(
          request().copyWith(videoPath: '${directory.path}/missing.mp4'),
        );
        expect(manager.job!.status, OcrSubtitleJobStatus.failed);
        expect(InferenceScheduler.instance.busy, isFalse);
        await manager.start(request());
        expect(
          manager.job!.status,
          OcrSubtitleJobStatus.completed,
          reason: manager.job!.error,
        );
        final english = await models.preset('ppocr-v5-en'),
            korean = await models.preset('ppocr-v5-korean');
        await models.importFiles(english, Directory(root));
        await models.importFiles(korean, Directory(root));
        center.downloads[korean.recognition]!.phase = ModelDownloadPhase.paused;
        await models.remove(english);
        expect(center.installed(korean.detection), isTrue);
        center.downloads[korean.recognition]!.phase =
            ModelDownloadPhase.installed;
        expect(models.ready(korean), isTrue);
        final comparisons = <Map<String, Object?>>[];
        for (final id in [
          'ppocr-v6-small',
          'ppocr-v6-medium',
          'ppocr-v5-mobile',
        ]) {
          final model = await models.preset(id);
          await models.importFiles(model, Directory(root));
          final selected = tracks.first.copyWith(
            modelId: id,
            modelIdentity: '',
          );
          final ocrRequest = OcrSubtitleJob(
            videoId: 'native-video',
            videoPath: library.videoPath,
            tracks: [selected],
            start: Duration.zero,
            end: const Duration(seconds: 12),
          );
          final watch = Stopwatch()..start();
          await manager.start(ocrRequest);
          expect(
            manager.job!.status,
            OcrSubtitleJobStatus.completed,
            reason: manager.job!.error,
          );
          final srt = await File(
            manager.job!.outputPaths.single,
          ).readAsString();
          expect(srt, isNotEmpty);
          final firstWallMs = watch.elapsedMilliseconds;
          final firstPhases = manager.lastPerformance;
          final preflight = await manager.estimateDuration(
            videoId: 'native-video',
            mediaDuration: const Duration(seconds: 12),
            start: Duration.zero,
            end: const Duration(seconds: 12),
            tracks: [selected],
          );
          expect(
            manager.hasDurationMeasurements('native-video', [selected]),
            isTrue,
          );
          watch.reset();
          await manager.start(ocrRequest);
          expect(
            manager.job!.status,
            OcrSubtitleJobStatus.completed,
            reason: manager.job!.error,
          );
          comparisons.add({
            'modelId': id,
            'wallMs': firstWallMs,
            'preflightMs': preflight.inMilliseconds,
            'repeatWallMs': watch.elapsedMilliseconds,
            'srt': srt,
            'phases': firstPhases,
          });
        }
        await File(
          '.artifacts/ocr-upgrade/model-video-comparison.json',
        ).writeAsString(
          const JsonEncoder.withIndent('  ').convert(comparisons),
        );
      } finally {
        manager.dispose();
        library.dispose();
        await center.shutdown();
        AppStorageService.instance = previousStorage;
        await directory.delete(recursive: true);
      }
    },
    skip: root.isEmpty || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

/// Exercise the production download queue using real, previously fetched OCR
/// weights, without depending on live model-host availability in a runtime test.
class _FixtureModelTransfer implements HttpClientAdapter {
  _FixtureModelTransfer(this.files);
  final Map<String, File> files;
  int probes = 0;
  int downloads = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    final file = files[options.uri.toString()]!;
    final total = await file.length();
    final range = RegExp(
      r'^bytes=(\d+)-(\d*)$',
    ).firstMatch('${options.headers['Range'] ?? ''}');
    final start = range == null ? 0 : int.parse(range[1]!);
    final end = range == null || range[2]!.isEmpty
        ? total - 1
        : int.parse(range[2]!);
    if (range != null && range[2]!.isNotEmpty) {
      probes++;
    } else {
      downloads++;
    }
    final input = await file.open();
    try {
      await input.setPosition(start);
      return ResponseBody.fromBytes(
        await input.read(end - start + 1),
        range == null ? 200 : 206,
        headers: {
          'content-length': ['${end - start + 1}'],
          'etag': ['"fixture"'],
          if (range != null) 'content-range': ['bytes $start-$end/$total'],
        },
      );
    } finally {
      await input.close();
    }
  }

  @override
  void close({bool force = false}) {}
}

class _OcrLibrary extends ChangeNotifier implements LibraryService {
  _OcrLibrary(this.root, this.videoPath);
  final Directory root;
  final String videoPath;
  final registered = <String>[];
  @override
  VideoItem? getVideo(String id) => VideoItem(
    id: id,
    path: videoPath,
    title: 'OCR fixture',
    durationMs: 12000,
    lastUpdated: 0,
  );
  @override
  Future<String> allocateSubtitleFile(
    String id,
    String preferredFileName,
  ) async {
    final output = Directory('${root.path}/outputs');
    await output.create(recursive: true);
    return '${output.path}/$preferredFileName';
  }

  @override
  Future<ManagedSubtitleAsset?> registerManagedLocalSubtitle(
    String videoId, {
    required String path,
    required ManagedSubtitleAssetKind kind,
    required String displayName,
    String? language,
    String? wordTimingPath,
    String? sourceAssetId,
    bool shareWithBilibiliPart = true,
  }) async {
    registered.add(path);
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
