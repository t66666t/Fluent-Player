// Build this entry point only in the isolated validation project. The shipped
// player continues to use lib/main.dart. No window is shown before a frame.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as im;
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/services/ocr_inference_engine.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_processing_worker.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('OCR_VALIDATION_ROOT');
  final report = File('$root/windows-aot-smoke.json');
  final results = <String, Object?>{};
  try {
    if (root.isEmpty) throw StateError('OCR_VALIDATION_ROOT is required');
    final model = (await loadOcrPresets()).firstWhere(
      (p) => p.id == 'ppocr-v6-small',
    );
    final files = OcrModelFiles(
      detection: '$root/models/${model.detection}/inference.onnx',
      detectionConfig: '$root/models/${model.detection}/inference.yml',
      recognition: '$root/models/${model.recognition}/inference.onnx',
      dictionary: '$root/models/${model.recognition}/inference.yml',
      legacy: false,
      identity: model.id,
    );
    final image = im.decodePng(
      await File('$root/fixture/chinese.png').readAsBytes(),
    )!;
    final release = await InferenceScheduler.instance.acquire();
    try {
      results['runtime'] = OcrInferenceEngine.runtimeVersion;
      results['availableBackends'] = OcrInferenceEngine.availableBackends();
      for (final provider in ['CPU', 'DirectML']) {
        final engine = OcrInferenceEngine(
          files,
          provider: provider,
          cpuThreads: 2,
          batchLimit: 4,
        );
        final watch = Stopwatch()..start();
        try {
          await engine.initialize();
          final startup = watch.elapsedMilliseconds;
          final readings = <Map<String, Object>>[];
          for (var i = 0; i < 3; i++) {
            final started = watch.elapsedMicroseconds;
            final result = await engine.recognizeImage(image);
            if (result.text != '简体中文字幕识别测试') {
              throw StateError('Unexpected OCR output: ${result.text}');
            }
            readings.add({
              'text': result.text,
              'confidence': result.confidence,
              'microseconds': watch.elapsedMicroseconds - started,
            });
          }
          results[provider] = {
            'backend': engine.activeBackend,
            'startupMs': startup,
            'readings': readings,
          };
        } finally {
          await engine.dispose();
        }
      }
      final worker = await OcrProcessingWorker.start(files);
      try {
        await worker.analyzeFrame('$root/fixture/chinese.png', 1000);
        final result = await worker.analyzeFrame(
          '$root/fixture/chinese.png',
          1100,
        );
        if (!result.candidate ||
            result.text != '简体中文字幕识别测试' ||
            result.boundaryMs != 1000) {
          throw StateError('AOT worker confirmation failed');
        }
        results['worker'] = {
          'text': result.text,
          'boundaryMs': result.boundaryMs,
          'backend': result.backend,
        };
      } finally {
        await worker.close();
      }
    } finally {
      release();
    }
    results['success'] = true;
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(results),
      flush: true,
    );
    exit(0);
  } catch (error, stack) {
    results.addAll({'success': false, 'error': '$error', 'stack': '$stack'});
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(results),
      flush: true,
    );
    exit(1);
  }
}
