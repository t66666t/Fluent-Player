import 'dart:ffi';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/models/ocr_model_files.dart';
import 'package:video_player_app/services/ocr_inference_engine.dart';
import 'package:video_player_app/services/ocr_model_catalog.dart';

// Explicit prepared-weights check. No downloads or runtime changes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('OCR_RUNTIME_ROOT');
  const noiseFrame = String.fromEnvironment('OCR_NOISE_FRAME');
  const wideFrames = String.fromEnvironment('OCR_WIDE_FRAME_MANIFEST');
  const provider = String.fromEnvironment(
    'OCR_GEOMETRY_PROVIDER',
    defaultValue: 'CPU',
  );
  final enabled = root.isNotEmpty && Platform.isWindows;
  if (enabled) {
    DynamicLibrary.open(File('windows/runtime/onnxruntime.dll').absolute.path);
  }

  im.Image sample({
    bool subtitle = true,
    bool noise = false,
    bool sideNoise = false,
  }) {
    final image = im.Image(width: 640, height: 160);
    im.fill(image, color: im.ColorRgb8(28, 32, 40));
    if (subtitle) {
      im.drawString(
        image,
        'Main subtitle 123',
        font: im.arial48,
        x: 40,
        y: 75,
        color: im.ColorRgb8(255, 255, 255),
      );
    }
    if (noise) {
      im.drawString(
        image,
        'TINY SHOP SIGN',
        font: im.arial24,
        x: 5,
        y: 3,
        color: im.ColorRgb8(255, 255, 255),
      );
    }
    if (sideNoise) {
      im.drawString(
        image,
        'Jaylc',
        font: im.arial14,
        x: 550,
        y: 104,
        color: im.ColorRgb8(255, 255, 255),
      );
    }
    return image;
  }

  test(
    'a real device subtitle crop excludes the separate Jaylo side label',
    () async {
      final image = im.decodePng(await File(noiseFrame).readAsBytes())!;
      final engine = OcrInferenceEngine(
        const OcrModelFiles(
          detection: '$root/ocr-v6-small-det/inference.onnx',
          detectionConfig: '$root/ocr-v6-small-det/inference.yml',
          recognition: '$root/ocr-v6-small-rec/inference.onnx',
          dictionary: '$root/ocr-v6-small-rec/inference.yml',
          legacy: false,
        ),
        cpuThreads: 2,
        provider: provider,
      );
      try {
        final result = await engine.recognizeImage(image);
        expect(result.text, contains('Chain'));
        expect(result.text, contains('做的这类产品发布视频'));
        expect(result.text, endsWith('视频'));
        expect(result.lines.single.right, lessThan(image.width * .9));
      } finally {
        await engine.dispose();
      }
    },
    skip: !enabled || noiseFrame.isEmpty,
  );

  test(
    'original-width crops retain whole subtitles beside smaller side labels',
    () async {
      final cases = jsonDecode(await File(wideFrames).readAsString()) as List;
      final engine = OcrInferenceEngine(
        const OcrModelFiles(
          detection: '$root/ocr-v6-small-det/inference.onnx',
          detectionConfig: '$root/ocr-v6-small-det/inference.yml',
          recognition: '$root/ocr-v6-small-rec/inference.onnx',
          dictionary: '$root/ocr-v6-small-rec/inference.yml',
          legacy: false,
        ),
        cpuThreads: 2,
        provider: provider,
      );
      try {
        for (final dynamic item in cases) {
          final image = im.decodePng(
            await File(item['path'] as String).readAsBytes(),
          )!;
          final result = await engine.recognizeImage(
            image,
            geometry: const OcrSubtitleGeometry(
              height: 22 / 36,
              center: 22 / 36,
            ),
          );
          expect(
            result.text.replaceAll(RegExp(r'\s+'), ''),
            item['expected'],
            reason: item['path'] as String,
          );
        }
      } finally {
        await engine.dispose();
      }
    },
    skip: !enabled || wideFrames.isEmpty,
  );

  test(
    'all current and legacy presets reject small background with native models',
    () async {
      final presets = await loadOcrPresets();
      final catalog = await loadModelCatalog();
      for (final preset in presets) {
        final component = catalog.firstWhere((m) => m.id == preset.recognition);
        final files = preset.legacy
            ? OcrModelFiles(
                detection: File(
                  'assets/models/ocr/ch_PP-OCRv4_det_mobile.onnx',
                ).absolute.path,
                recognition: File(
                  'assets/models/ocr/${component.files.firstWhere((f) => f.name.endsWith('.onnx') && !f.name.contains('_det_')).name}',
                ).absolute.path,
                dictionary: File(
                  'assets/models/ocr/${component.files.firstWhere((f) => f.name.endsWith('.txt')).name}',
                ).absolute.path,
              )
            : OcrModelFiles(
                detection: '$root/${preset.detection}/inference.onnx',
                recognition: '$root/${preset.recognition}/inference.onnx',
                dictionary: '$root/${preset.recognition}/inference.yml',
                detectionConfig: '$root/${preset.detection}/inference.yml',
                identity: preset.id,
                legacy: false,
              );
        final engine = OcrInferenceEngine(
          files,
          cpuThreads: 2,
          batchLimit: 4,
          provider: provider,
        );
        try {
          final clean = await engine.recognizeImage(sample());
          expect(clean.lines, isNotEmpty, reason: preset.id);
          final line = clean.lines.reduce(
            (a, b) => a.height > b.height ? a : b,
          );
          final geometry = OcrSubtitleGeometry(
            height: line.height / 160,
            center: (line.top + line.bottom) / 320,
          );
          final noisy = await engine.recognizeImage(
            sample(noise: true),
            geometry: geometry,
          );
          // Adding a sign can change detector padding and correct a baseline
          // recognition typo. Assert the known subtitle and absence of labels,
          // rather than requiring the clean model's typo to be reproduced.
          expect(noisy.text, contains('123'), reason: preset.id);
          expect(noisy.lines.length, clean.lines.length, reason: preset.id);
          expect(
            (noisy.lines.single.top - line.top).abs(),
            lessThanOrEqualTo(12),
            reason: '${preset.id}: the label must not enlarge the subtitle box',
          );
          expect(
            noisy.text.toUpperCase(),
            isNot(contains(RegExp('TINY|SHOP|SIGN'))),
            reason: preset.id,
          );
          final backgroundOnly = await engine.recognizeImage(
            sample(subtitle: false, noise: true),
            geometry: geometry,
          );
          expect(backgroundOnly.text, isEmpty, reason: preset.id);
          final sameBaseline = await engine.recognizeImage(
            sample(sideNoise: true),
            geometry: geometry,
          );
          expect(sameBaseline.text, contains('123'), reason: preset.id);
          expect(
            sameBaseline.text.toUpperCase(),
            isNot(contains('JAY')),
            reason: preset.id,
          );
          expect(
            engine.activeBackend,
            provider == 'CPU' ? startsWith('CPU') : equals(provider),
            reason: preset.id,
          );
        } finally {
          await engine.dispose();
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
