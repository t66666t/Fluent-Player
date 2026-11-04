import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_processing_worker.dart';
import 'package:video_player_app/services/ocr_process_worker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('OCR_RUNTIME_ROOT');
  const executable = String.fromEnvironment('OCR_WORKER_EXECUTABLE');
  final enabled =
      Platform.isWindows && root.isNotEmpty && executable.isNotEmpty;
  OcrModelFiles files(OcrModelPreset p) => OcrModelFiles(
    detection: '$root/${p.detection}/inference.onnx',
    recognition: '$root/${p.recognition}/inference.onnx',
    dictionary: '$root/${p.recognition}/inference.yml',
    detectionConfig: '$root/${p.detection}/inference.yml',
    legacy: false,
    identity: p.id,
  );

  test(
    'isolated OCR validates DirectML against CPU on every downloadable preset',
    () async {
      final caps = await ProcessOcrWorker.probe(executable);
      final devices = caps.accelerators.where((d) => d.provider == 'DirectML');
      expect(devices, isNotEmpty);
      final records = <Map<String, Object?>>[];
      final temporary = await Directory.systemTemp.createTemp(
        'ocr-gpu-native-',
      );
      try {
        for (final preset in (await loadOcrPresets()).where((p) => !p.legacy)) {
          final model = files(preset);
          final worker = await ProcessOcrWorker.start(
            model,
            executable: executable,
            tracks: {1: model, 2: model},
            cpuThreads: 4,
            batchLimit: 4,
            deviceKey: devices.first.key,
          );
          final record = <String, Object?>{
            'model': preset.id,
            'runtime': worker.runtimeVersion,
          };
          try {
            for (final language in {'english', ...preset.groups}) {
              final source = File(
                '.artifacts/ocr-upgrade/fixture/$language.png',
              );
              final image = im.decodePng(await source.readAsBytes())!;
              final raw = File('${temporary.path}/$language.rgb');
              await raw.writeAsBytes(
                image.getBytes(order: im.ChannelOrder.rgb),
              );
              Future<OcrFrameAnalysis> run(
                int track,
                int at,
                String provider,
              ) => worker.analyzeRawFrame(
                path: raw.path,
                offset: 0,
                width: image.width,
                height: image.height,
                atMs: at,
                track: track,
                threads: 4,
                batchLimit: 4,
                provider: provider,
                deviceId: devices.first.id,
                allowedProviders: const ['CPU', 'DirectML'],
                validateAcceleration: true,
              );
              final cpuWatch = Stopwatch()..start();
              await run(1, 0, 'CPU');
              final cpu = await run(1, 100, 'CPU');
              cpuWatch.stop();
              final gpuWatch = Stopwatch()..start();
              final first = await run(2, 0, 'DirectML');
              final gpu = await run(2, 100, 'DirectML');
              gpuWatch.stop();
              expect(cpu.candidate, isTrue);
              expect(gpu.candidate, isTrue);
              expect(cpu.text, isNotEmpty, reason: '${preset.id}/$language');
              expect(gpu.text, cpu.text, reason: '${preset.id}/$language');
              final warm = Stopwatch()..start();
              // New history forces genuine inference, avoiding exact-frame cache.
              await worker.resetFrameHistory();
              await run(2, 0, gpu.backend);
              warm.stop();
              final steadyCpu = <double>[], steadyGpu = <double>[];
              for (var repeat = 0; repeat < 3; repeat++) {
                for (final provider in [
                  'CPU',
                  gpu.backend == 'DirectML' ? 'DirectML' : 'CPU',
                ]) {
                  await worker.resetFrameHistory();
                  final timer = Stopwatch()..start();
                  await run(provider == 'CPU' ? 1 : 2, 0, provider);
                  timer.stop();
                  (provider == 'CPU' ? steadyCpu : steadyGpu).add(
                    timer.elapsedMicroseconds / 1000,
                  );
                }
              }
              steadyCpu.sort();
              steadyGpu.sort();
              record[language] = {
                'cpuMs': cpuWatch.elapsedMilliseconds,
                'gpuColdMs': gpuWatch.elapsedMilliseconds,
                'gpuWarmMs': warm.elapsedMilliseconds,
                'cpuWarmMedianMs': steadyCpu[steadyCpu.length ~/ 2],
                'gpuWarmMedianMs': steadyGpu.isEmpty
                    ? null
                    : steadyGpu[steadyGpu.length ~/ 2],
                'backend': gpu.backend,
                'fallback': first.tuning?['failedProvider'],
                'text': gpu.text,
              };
              await worker.resetFrameHistory();
            }
            records.add(record);
          } finally {
            await worker.close();
          }
        }
        final output = File('.artifacts/ocr-gpu-20261026/native-directml.json');
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(records),
        );
        expect(
          (records.firstWhere((r) => r['model'] == 'ppocr-v6-small')['english']
              as Map)['backend'],
          'DirectML',
        );
      } finally {
        await temporary.delete(recursive: true);
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 8)),
  );

  test(
    'process restart preserves pending region confirmations without frame buffers',
    () async {
      final preset = (await loadOcrPresets()).firstWhere(
        (p) => p.id == 'ppocr-v6-small',
      );
      final model = files(preset);
      final temp = await Directory.systemTemp.createTemp('ocr-checkpoint-');
      final image = im.decodePng(
        await File('.artifacts/ocr-upgrade/fixture/english.png').readAsBytes(),
      )!;
      final raw = File('${temp.path}/frame.rgb');
      await raw.writeAsBytes(image.getBytes(order: im.ChannelOrder.rgb));
      OcrWorker? worker;
      try {
        worker = await ProcessOcrWorker.start(
          model,
          executable: executable,
          tracks: {1: model, 2: model},
        );
        Future<OcrFrameAnalysis> run(OcrWorker w, int track, int at) =>
            w.analyzeRawFrame(
              path: raw.path,
              offset: 0,
              width: image.width,
              height: image.height,
              atMs: at,
              track: track,
              threads: 2,
              batchLimit: 1,
            );
        expect((await run(worker, 1, 200)).candidate, isFalse);
        expect((await run(worker, 2, 400)).candidate, isFalse);
        final states = Map<int, Map<String, dynamic>>.from(worker.checkpoints);
        expect(
          jsonEncode(states.map((k, v) => MapEntry('$k', v))).length,
          lessThan(20000),
        );
        for (final state in states.values) {
          expect(state.containsKey('pixels'), isFalse);
        }
        (worker as ProcessOcrWorker).cancel();
        await worker.close();
        worker = await ProcessOcrWorker.start(
          model,
          executable: executable,
          tracks: {1: model, 2: model},
        );
        await worker.restoreFrameHistory(states);
        final first = await run(worker, 1, 300),
            second = await run(worker, 2, 500);
        expect(first.candidate, isTrue);
        expect(second.candidate, isTrue);
        expect(first.boundaryMs, 200);
        expect(second.boundaryMs, 400);
        expect(first.text, second.text);
        expect(first.text, isNotEmpty);
      } finally {
        await worker?.close();
        await temp.delete(recursive: true);
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'cancellation during isolated model startup exits without loading into the player',
    () async {
      final preset = (await loadOcrPresets()).firstWhere(
        (p) => p.id == 'ppocr-v6-small',
      );
      final cancelled = Completer<void>()..complete();
      await expectLater(
        ProcessOcrWorker.start(
          files(preset),
          executable: executable,
          cancelSignal: cancelled.future,
        ),
        throwsA(isA<OcrWorkerProcessFailure>()),
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
