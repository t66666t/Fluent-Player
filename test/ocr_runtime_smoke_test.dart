import 'dart:io';
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_inference_engine.dart';
import 'package:video_player_app/services/ocr_processing_worker.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';

void main() {
  if (Platform.isWindows) {
    DynamicLibrary.open(File('windows/runtime/onnxruntime.dll').absolute.path);
  }
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy models run through the shared runtime and keep confirmation boundaries',
    () async {
      final root = await Directory.systemTemp.createTemp('ocr_bundle_test_');
      OcrProcessingWorker? worker;
      try {
        final files = OcrModelFiles(
          detection: File(
            'assets/models/ocr/ch_PP-OCRv4_det_mobile.onnx',
          ).absolute.path,
          recognition: File(
            'assets/models/ocr/ch_PP-OCRv4_rec_mobile.onnx',
          ).absolute.path,
          dictionary: File('assets/models/ocr/ppocr_keys_v1.txt').absolute.path,
        );
        final whiteImage = im.Image(width: 320, height: 96);
        im.fill(whiteImage, color: im.ColorRgb8(255, 255, 255));
        final whiteFrame = File(
          '${root.path}${Platform.pathSeparator}white.jpg',
        );
        await whiteFrame.writeAsBytes(im.encodeJpg(whiteImage));
        final blackImage = im.Image(width: 320, height: 96);
        im.fill(blackImage, color: im.ColorRgb8(0, 0, 0));
        final blackFrame = File(
          '${root.path}${Platform.pathSeparator}black.jpg',
        );
        await blackFrame.writeAsBytes(im.encodeJpg(blackImage));

        final textImage = im.Image(width: 640, height: 128);
        im.fill(textImage, color: im.ColorRgb8(255, 255, 255));
        im.drawString(
          textImage,
          'OCR subtitle 123',
          font: im.arial48,
          x: 20,
          y: 30,
          color: im.ColorRgb8(0, 0, 0),
        );
        for (final pair in [
          ['ch_PP-OCRv4_rec_mobile.onnx', 'ppocr_keys_v1.txt'],
          ['en_PP-OCRv4_rec_mobile.onnx', 'en_dict.txt'],
          ['japan_PP-OCRv4_rec_mobile.onnx', 'japan_dict.txt'],
          ['korean_PP-OCRv4_rec_mobile.onnx', 'korean_dict.txt'],
          ['latin_PP-OCRv3_rec_mobile.onnx', 'latin_dict.txt'],
        ]) {
          final engine = OcrInferenceEngine(
            OcrModelFiles(
              detection: files.detection,
              recognition: File('assets/models/ocr/${pair[0]}').absolute.path,
              dictionary: File('assets/models/ocr/${pair[1]}').absolute.path,
            ),
          );
          try {
            final result = await engine.recognizeImage(textImage);
            expect(
              result.text,
              contains('123'),
              reason: '${pair[0]}: ${result.text}',
            );
            if (pair[0].startsWith('en_')) {
              expect(result.text, contains('OCR'));
            }
          } finally {
            await engine.dispose();
          }
        }

        worker = await OcrProcessingWorker.start(files);
        final first = await worker.analyzeFrame(whiteFrame.path, 5000);
        expect(first.candidate, isFalse);
        expect(first.backend, isNotEmpty);

        final unchanged = await worker.analyzeFrame(whiteFrame.path, 5100);
        expect(unchanged.candidate, isTrue);
        expect(unchanged.boundaryMs, 5000);

        final throttledChange = await worker.analyzeFrame(
          blackFrame.path,
          5200,
        );
        expect(throttledChange.candidate, isFalse);
        final stableCandidate = await worker.analyzeFrame(
          blackFrame.path,
          5300,
        );
        expect(stableCandidate.candidate, isFalse);
        final confirmedCandidate = await worker.analyzeFrame(
          blackFrame.path,
          5400,
        );
        expect(confirmedCandidate.candidate, isTrue);
        expect(confirmedCandidate.boundaryMs, 5200);

        final forcedCheck = await worker.analyzeFrame(blackFrame.path, 7300);
        expect(forcedCheck.candidate, isFalse);
        final confirmedForcedCheck = await worker.analyzeFrame(
          blackFrame.path,
          7400,
        );
        expect(confirmedForcedCheck.candidate, isTrue);
        expect(confirmedForcedCheck.boundaryMs, 7300);
      } finally {
        await worker?.close();
        if (await root.exists()) await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('FFmpeg showinfo PTS is parsed as exact millisecond samples', () {
    const logs = '''
[Parsed_showinfo_4 @ 000001] n:0 pts:0 pts_time:0
[Parsed_showinfo_4 @ 000001] n:1 pts:1 pts_time:0.1
[Parsed_showinfo_4 @ 000001] n:2 pts:2 pts_time:0.233
''';
    expect(parseOcrFrameTimes(logs), <int>[0, 100, 233]);
  });

  test('OCR filter mirrors first and crops only the selected region', () {
    const region = NormalizedOcrRegion(
      left: 0.25,
      top: 0.5,
      right: 0.75,
      bottom: 0.75,
    );
    final filter = buildOcrFrameFilter(
      region: region,
      mirrorHorizontal: true,
      mirrorVertical: true,
    );
    expect(
      filter,
      startsWith('hflip,vflip,crop=iw*0.5:ih*0.25:iw*0.25:ih*0.5'),
    );
    expect(filter.indexOf('crop='), lessThan(filter.indexOf('scale=')));
  });

  test('OCR progress stays monotonic independently of ETA', () {
    final tracker = OcrTaskProgressTracker(totalMs: 60000);
    expect(tracker.progressFor(0), 0);
    expect(tracker.shouldPublish(0), isTrue);
    expect(tracker.shouldPublish(100), isFalse);
    expect(tracker.shouldPublish(1000), isTrue);

    expect(tracker.progressFor(60000), 0.99);
    expect(tracker.progressFor(30000), 0.5);
    expect(tracker.progressFor(30000), greaterThan(tracker.progressFor(10000)));
  });

  test('OCR style profile rejects small text outside subtitle geometry', () {
    final filter = OcrSubtitleStyleFilter();
    const subtitle = OcrTextLineResult(
      text: 'main subtitle',
      confidence: 0.9,
      left: 30,
      top: 50,
      right: 290,
      bottom: 74,
    );
    for (var i = 0; i < 4; i++) {
      filter.filter(
        const OcrTextResult('main subtitle', 0.9, [subtitle]),
        320,
        100,
      );
    }
    const tinyUiText = OcrTextLineResult(
      text: 'UI',
      confidence: 0.95,
      left: 5,
      top: 4,
      right: 24,
      bottom: 10,
    );
    final result = filter.filter(
      const OcrTextResult('UI\nmain subtitle', 0.92, [tinyUiText, subtitle]),
      320,
      100,
    );
    expect(result.text, 'main subtitle');
    expect(result.lines, [subtitle]);
  });

  test('tiny pre-roll UI text cannot become the subtitle profile', () {
    final filter = OcrSubtitleStyleFilter();
    const tinyUiText = OcrTextLineResult(
      text: 'UI',
      confidence: 0.95,
      left: 5,
      top: 4,
      right: 24,
      bottom: 10,
    );
    for (var i = 0; i < 8; i++) {
      filter.filter(const OcrTextResult('UI', 0.95, [tinyUiText]), 320, 100);
    }
    const subtitle = OcrTextLineResult(
      text: 'main subtitle',
      confidence: 0.9,
      left: 30,
      top: 50,
      right: 290,
      bottom: 74,
    );
    final result = filter.filter(
      const OcrTextResult('main subtitle', 0.9, [subtitle]),
      320,
      100,
    );
    expect(result.text, 'main subtitle');
  });
}
