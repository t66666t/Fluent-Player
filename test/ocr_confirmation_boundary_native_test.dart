import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:video_player_app/models/ocr_model_files.dart';
import 'package:video_player_app/services/ocr_processing_worker.dart';

// This is an explicit, prepared-weights test. Ordinary host runs neither load
// native runtimes nor download weights; the Android task is verified separately.
void main() {
  const root = String.fromEnvironment('OCR_RUNTIME_ROOT');
  final enabled = root.isNotEmpty && Platform.isWindows;
  Directory? directory;
  OcrProcessingWorker? worker;
  late File frame;
  const width = 640, height = 128;

  setUp(() async {
    if (!enabled) return;
    DynamicLibrary.open(File('windows/runtime/onnxruntime.dll').absolute.path);
    directory = await Directory.systemTemp.createTemp('ocr-confirm-boundary-');
    frame = File('${directory!.path}/frame.rgb');
    const files = OcrModelFiles(
      detection: '$root/ocr-v6-small-det/inference.onnx',
      recognition: '$root/ocr-v6-small-rec/inference.onnx',
      dictionary: '$root/ocr-v6-small-rec/inference.yml',
      detectionConfig: '$root/ocr-v6-small-det/inference.yml',
      identity: 'ppocr-v6-small',
      legacy: false,
    );
    worker = await OcrProcessingWorker.start(
      files,
      tracks: {1: files},
      cpuThreads: 2,
      batchLimit: 1,
    );
  });

  tearDown(() async {
    await worker?.close();
    worker = null;
    await directory?.delete(recursive: true);
    directory = null;
  });

  Future<void> writeFrame({bool blank = false}) async {
    final image = im.Image(width: width, height: height);
    im.fill(image, color: im.ColorRgb8(28, 32, 40));
    if (!blank) {
      im.drawString(
        image,
        'New subtitle 456',
        font: im.arial48,
        x: 20,
        y: 30,
        color: im.ColorRgb8(255, 255, 255),
      );
    }
    await frame.writeAsBytes(image.getBytes(order: im.ChannelOrder.rgb));
  }

  Future<void> restorePrevious({required double confidence}) =>
      worker!.restoreFrameHistory({
        1: {
          'width': width,
          'height': height,
          'lastForcedMs': 4000,
          'lastCandidateMs': 5900,
          'lastChangeMs': 5700,
          'pending': {
            'text': 'Previous subtitle 123',
            'confidence': confidence,
            'boundaryMs': 5700,
          },
        },
      });

  Future<OcrFrameAnalysis> analyze(int at) => worker!.analyzeRawFrame(
    path: frame.path,
    offset: 0,
    width: width,
    height: height,
    atMs: at,
    track: 1,
    threads: 2,
    batchLimit: 1,
    allowedProviders: const ['CPU'],
  );

  test(
    'a stronger old confirmation cannot suppress the next complete subtitle',
    () async {
      await writeFrame();
      await restorePrevious(confidence: 1);
      final crossed = await analyze(6000);
      expect(crossed.text, 'Previous subtitle 123');
      expect(crossed.checkpoint?['pending'], isNotNull);
      // The same pending observation must survive a worker checkpoint restore.
      await worker!.restoreFrameHistory({1: crossed.checkpoint!});
      final confirmed = await analyze(6100);
      expect(confirmed.candidate, isTrue);
      expect(confirmed.text, contains('456'));
      expect(confirmed.boundaryMs, 6000);
      expect(confirmed.checkpoint?['pending'], isNull);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a stronger new observation uses its own timestamp rather than the old text',
    () async {
      await writeFrame();
      await restorePrevious(confidence: 0);
      final crossed = await analyze(6000);
      expect(crossed.candidate, isTrue);
      expect(crossed.text, contains('456'));
      expect(crossed.boundaryMs, 6000);
      final confirmed = await analyze(6100);
      expect(confirmed.text, crossed.text);
      expect(confirmed.boundaryMs, 6000);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a blank after a stronger old observation is still confirmed promptly',
    () async {
      await writeFrame(blank: true);
      await restorePrevious(confidence: 1);
      final crossed = await analyze(6000);
      expect(crossed.text, 'Previous subtitle 123');
      final blank = await analyze(6100);
      expect(blank.candidate, isTrue);
      expect(blank.text, isEmpty);
      expect(blank.boundaryMs, 6000);
      expect(blank.checkpoint?['pending'], isNull);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
