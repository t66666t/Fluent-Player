import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:video_player_app/models/ocr_accelerator_contract.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_processing_worker.dart';
import 'package:video_player_app/services/ocr_process_worker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('OCR_RUNTIME_ROOT');
  const executable = String.fromEnvironment('OCR_WORKER_EXECUTABLE');
  const requested = String.fromEnvironment(
    'OCR_NATIVE_PROVIDERS',
    defaultValue: 'Vulkan,OpenCL',
  );
  final enabled =
      Platform.isWindows && root.isNotEmpty && executable.isNotEmpty;
  test(
    'Unicode model paths and a same-frame CPU-to-GPU switch run genuine inference',
    () async {
      final temporary = await Directory.systemTemp.createTemp('OCR 中文 模型-');
      ProcessOcrWorker? worker;
      try {
        for (final id in ['ocr-v6-small-det', 'ocr-v6-small-rec']) {
          final directory = await Directory('${temporary.path}/$id').create();
          for (final name in ['inference.onnx', 'inference.yml']) {
            await File('$root/$id/$name').copy('${directory.path}/$name');
          }
        }
        final model = OcrModelFiles(
          detection: '${temporary.path}/ocr-v6-small-det/inference.onnx',
          detectionConfig: '${temporary.path}/ocr-v6-small-det/inference.yml',
          recognition: '${temporary.path}/ocr-v6-small-rec/inference.onnx',
          dictionary: '${temporary.path}/ocr-v6-small-rec/inference.yml',
          identity: 'unicode-small',
          legacy: false,
          acceleratorContract: ocrAcceleratorContract,
        );
        final image = im.decodePng(
          await File(
            '.artifacts/ocr-upgrade/fixture/english.png',
          ).readAsBytes(),
        )!;
        final frame = File('${temporary.path}/帧.rgb');
        await frame.writeAsBytes(image.getBytes(order: im.ChannelOrder.rgb));
        worker = await ProcessOcrWorker.start(
          model,
          executable: executable,
          tracks: {1: model},
          cpuThreads: 4,
          batchLimit: 4,
        );
        Future<OcrFrameAnalysis> run(String provider, int at) =>
            worker!.analyzeRawFrame(
              path: frame.path,
              offset: 0,
              width: image.width,
              height: image.height,
              atMs: at,
              track: 1,
              threads: 4,
              batchLimit: 4,
              provider: provider,
              allowedProviders: const ['CPU', 'Vulkan'],
              validateAcceleration: true,
            );
        await run('CPU', 0);
        final cpu = await run('CPU', 100);
        final switched = await run('Vulkan', 2000);
        expect(switched.backend, 'Vulkan');
        expect(switched.warmup, isTrue);
        expect(switched.timingsUs['inferenceUs'], greaterThan(0));
        final gpu = await run('Vulkan', 2100);
        expect(gpu.text, cpu.text);
        expect(gpu.text, 'English subtitle test');
      } finally {
        await worker?.close();
        await temporary.delete(recursive: true);
      }
    },
    skip: !enabled || !requested.split(',').contains('Vulkan'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'GPU routes preserve text and recover unsupported model/driver combinations',
    () async {
      final capabilities = await ProcessOcrWorker.probe(executable);
      final routes = capabilities.accelerators
          .where((d) => requested.split(',').contains(d.provider))
          .toList();
      expect(
        routes.map((d) => d.provider).toSet(),
        requested.split(',').toSet(),
      );
      final records = <Map<String, Object?>>[];
      final temporary = await Directory.systemTemp.createTemp(
        'ocr-mobile-backends-',
      );
      try {
        for (final preset in (await loadOcrPresets()).where((p) => !p.legacy)) {
          final model = OcrModelFiles(
            detection: '$root/${preset.detection}/inference.onnx',
            recognition: '$root/${preset.recognition}/inference.onnx',
            dictionary: '$root/${preset.recognition}/inference.yml',
            detectionConfig: '$root/${preset.detection}/inference.yml',
            identity: preset.id,
            legacy: false,
            acceleratorContract: ocrAcceleratorContract,
          );
          Future<ProcessOcrWorker> start() => ProcessOcrWorker.start(
            model,
            executable: executable,
            tracks: {1: model, 2: model},
            cpuThreads: 4,
            batchLimit: 4,
          );
          final cpuWorker = await start();
          final routeWorkers = <String, ProcessOcrWorker>{};
          var worker = cpuWorker;
          final optionalFailures = <String>{};
          try {
            for (final language in {'english', ...preset.groups}) {
              final input = im.decodePng(
                await File(
                  '.artifacts/ocr-upgrade/fixture/$language.png',
                ).readAsBytes(),
              )!;
              // Vary geometry and recognizer batch between invocations, as real
              // subtitle crops do. This exercises resize and native ownership.
              final twoLines = im.Image(
                width: input.width,
                height: input.height * 2,
              );
              im.compositeImage(twoLines, input);
              im.compositeImage(twoLines, input, dstY: input.height);
              for (final source in [
                input,
                im.copyResize(input, width: input.width * 3 ~/ 4),
                if (preset.id == 'ppocr-v6-small' && language == 'english')
                  twoLines,
              ]) {
                final raw = File('${temporary.path}/frame.rgb');
                await raw.writeAsBytes(
                  source.getBytes(order: im.ChannelOrder.rgb),
                );
                Future<OcrFrameAnalysis> run(
                  String provider,
                  int at, {
                  int batch = 1,
                }) => worker.analyzeRawFrame(
                  path: raw.path,
                  offset: 0,
                  width: source.width,
                  height: source.height,
                  atMs: at,
                  track: provider == 'CPU' ? 1 : 2,
                  threads: 4,
                  batchLimit: batch,
                  provider: provider,
                  allowedProviders: ['CPU', provider],
                  validateAcceleration: true,
                );
                worker = cpuWorker;
                await worker.resetFrameHistory();
                await run('CPU', 0);
                final cpu = await run('CPU', 100);
                expect(cpu.text, isNotEmpty, reason: '${preset.id}/$language');
                for (final route in routes) {
                  if (optionalFailures.contains(route.provider)) continue;
                  try {
                    // A task freezes its device choice. Keep the same native
                    // driver context per process instead of interleaving two
                    // different GPU APIs after every individual frame.
                    worker = routeWorkers[route.provider] ??= await start();
                    // Keep a concrete case in diagnostics if a vendor call
                    // stalls before it can return an error to the worker.
                    // ignore: avoid_print
                    print(
                      'Checking ${preset.id}/$language/'
                      '${source.width}x${source.height}/${route.provider}',
                    );
                    await worker.resetFrameHistory();
                    final watch = Stopwatch()..start();
                    final first = await run(route.provider, 0);
                    final gpu = await run(route.provider, 100);
                    watch.stop();
                    if (gpu.backend != route.provider) {
                      expect(route.provider, isNot('Vulkan'));
                      expect(first.tuning?['failedProvider'], route.provider);
                      expect(gpu.text, cpu.text);
                      optionalFailures.add(route.provider);
                      records.add({
                        'model': preset.id,
                        'language': language,
                        'provider': route.provider,
                        'status': 'cpu_fallback',
                        'reason': first.tuning?['failureReason'],
                      });
                      continue;
                    }
                    expect(gpu.backend, route.provider);
                    expect(gpu.candidate, isTrue);
                    expect(
                      gpu.text,
                      cpu.text,
                      reason: '${preset.id}/$language/${route.provider}',
                    );
                    expect(
                      (gpu.confidence - cpu.confidence).abs(),
                      lessThan(.08),
                    );
                    await worker.resetFrameHistory();
                    final batchedFirst = await run(route.provider, 0, batch: 4);
                    final batched = await run(route.provider, 100, batch: 4);
                    expect(
                      batchedFirst.tuning?['failedProvider'],
                      isNull,
                      reason: '${preset.id}/$language/${route.provider}/batch4',
                    );
                    expect(batched.backend, route.provider);
                    expect(batched.text, cpu.text);
                    final cpuTimes = <double>[], gpuTimes = <double>[];
                    if (language == 'english' && identical(source, input)) {
                      for (var repeat = 0; repeat < 3; repeat++) {
                        for (final provider
                            in repeat.isEven
                                ? ['CPU', route.provider]
                                : [route.provider, 'CPU']) {
                          await worker.resetFrameHistory();
                          final timer = Stopwatch()..start();
                          await run(provider, 0, batch: 4);
                          (provider == 'CPU' ? cpuTimes : gpuTimes).add(
                            timer.elapsedMicroseconds / 1000,
                          );
                        }
                      }
                      cpuTimes.sort();
                      gpuTimes.sort();
                    }
                    records.add({
                      'model': preset.id,
                      'language': language,
                      'width': source.width,
                      'provider': route.provider,
                      'status': 'validated_gpu',
                      'text': gpu.text,
                      'coldMs': watch.elapsedMilliseconds,
                      if (cpuTimes.isNotEmpty) 'cpuWarmMedianMs': cpuTimes[1],
                      if (gpuTimes.isNotEmpty) 'gpuWarmMedianMs': gpuTimes[1],
                    });
                  } on OcrWorkerProcessFailure catch (error) {
                    if (route.provider == 'Vulkan') rethrow;
                    optionalFailures.add(route.provider);
                    await worker.close();
                    worker = routeWorkers[route.provider] = await start();
                    await run('CPU', 0);
                    final recovered = await run('CPU', 100);
                    expect(recovered.backend, startsWith('CPU'));
                    expect(recovered.text, cpu.text);
                    records.add({
                      'model': preset.id,
                      'language': language,
                      'provider': route.provider,
                      'status': 'process_recovered_to_cpu',
                      'reason': error.code,
                      'text': recovered.text,
                    });
                  }
                }
              }
            }
          } finally {
            await cpuWorker.close();
            for (final routeWorker in routeWorkers.values) {
              await routeWorker.close();
            }
          }
          // Progress is useful when a driver's first shader compilation is slow.
          // ignore: avoid_print
          print(
            'Validated ${preset.id}; CPU fallback routes: ${optionalFailures.join(', ')}',
          );
        }
      } finally {
        await temporary.delete(recursive: true);
      }
      await File(
        '.artifacts/om26/native-model-results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(records));
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
