import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/ocr_duration_estimator.dart';
import 'package:video_player_app/services/ocr_frame_pipeline.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'downloadable presets cover every existing language and share components',
    () async {
      final models = await loadOcrPresets();
      final components = await loadModelCatalog();
      for (final model in models.where((m) => !m.legacy)) {
        expect(model.bytes(components), greaterThan(1000000));
        for (final id in model.componentIds) {
          final component = components.firstWhere((m) => m.id == id);
          expect(component.purpose, ModelPurpose.ocr);
          for (final file in component.files) {
            expect(
              file.sources.keys,
              containsAll(['official', 'mainland', 'mirror', 'mirror_proxy']),
            );
            expect(file.sha256, matches(RegExp(r'^[a-f0-9]{64}$')));
            expect(file.sources['official'], contains(component.revision));
            expect(file.sources['mainland'], isNot(contains('/master/')));
          }
        }
      }
      for (final language in OcrSubtitleLanguage.values) {
        expect(
          models.where((m) => !m.legacy && m.supports(language)),
          isNotEmpty,
        );
      }
      expect(models.any((m) => m.id == 'ppocr-v6-tiny'), isFalse);
      expect(components.any((m) => m.id == 'ocr-v6-tiny-rec'), isFalse);
      for (final id in ['ppocr-v5-en', 'ppocr-v5-korean', 'ppocr-v5-latin']) {
        expect(
          models.firstWhere((m) => m.id == id).detection,
          'ocr-v6-tiny-det',
        );
      }
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      expect(
        manifest.listAssets().where(
          (path) => path.startsWith('assets/models/ocr/'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'Xiaomi tablet recommendation stays advisory and respects language and headroom',
    () {
      final device = DeviceResourceSnapshot(
        platform: 'android',
        processors: 8,
        memoryBytes: 12 * 1073741824,
        availableMemoryBytes: 6 * 1073741824,
        capturedAt: DateTime.now(),
      );
      expect(
        recommendedOcrPreset(device, OcrSubtitleLanguage.chinese),
        'ppocr-v6-small',
      );
      expect(
        recommendedOcrPreset(null, OcrSubtitleLanguage.chinese),
        'ppocr-v5-mobile',
      );
      expect(
        recommendedOcrPreset(device, OcrSubtitleLanguage.korean),
        'ppocr-v5-korean',
      );
      Map<String, dynamic> measured(
        String model,
        double rate, {
        String reference = 'same-video',
      }) => {
        'device': ocrDeviceKey(device),
        'language': 'chinese',
        'modelId': model,
        'runtime': '1.21.0',
        'reference': reference,
        'realTimeFactor': rate,
        'mediaMs': 2160000,
        'testedAt': DateTime.now().toUtc().toIso8601String(),
      };
      expect(
        recommendedOcrPreset(
          device,
          OcrSubtitleLanguage.chinese,
          measurements: [
            measured('ppocr-v6-small', .6),
            measured('ppocr-v5-mobile', .2),
          ],
        ),
        'ppocr-v5-mobile',
      );
      expect(
        recommendedOcrPreset(
          device,
          OcrSubtitleLanguage.chinese,
          measurements: [
            measured('ppocr-v6-small', .6),
            measured('ppocr-v5-mobile', .2, reference: 'other-video'),
          ],
        ),
        'ppocr-v6-small',
      );
      expect(
        recommendedOcrPreset(
          device,
          OcrSubtitleLanguage.chinese,
          measurements: [
            measured('ppocr-v6-small', .6),
            measured('ppocr-v6-tiny', .01),
          ],
        ),
        'ppocr-v6-small',
      );
      const track = OcrSubtitleTrack(
        number: 1,
        region: NormalizedOcrRegion.subtitleDefault(),
        language: OcrSubtitleLanguage.chinese,
        modelId: 'ppocr-v6-small',
        modelIdentity: 'pinned-revision',
      );
      final restored = OcrSubtitleTrack.fromJson(track.toJson());
      expect(restored.modelId, track.modelId);
      expect(restored.modelIdentity, track.modelIdentity);
      expect(
        restored
            .copyWith(region: const NormalizedOcrRegion.subtitleDefault())
            .modelId,
        track.modelId,
      );
    },
  );

  test(
    'interleaved raw branch logs retain exact timestamps and byte offsets',
    () {
      const logs = '''
[showinfo@ocr_1 @ 001] n: 0 pts: 0 pts_time:0 fmt:rgb24 s:640x120
[showinfo@ocr_2 @ 002] n: 0 pts: 0 pts_time:0 fmt:rgb24 s:320x80
[showinfo@ocr_1 @ 001] n: 1 pts: 3 pts_time:0.3 fmt:rgb24 s:640x120
[showinfo@ocr_2 @ 002] n: 1 pts: 20 pts_time:2.0 fmt:rgb24 s:320x80
''';
      final frames = parseOcrRawFrames(logs, Directory('frames'), 15000);
      expect(frames[1]!.last.atMs, 15300);
      expect(frames[2]!.last.atMs, 17000);
      expect(frames[1]!.last.offset, 640 * 120 * 3);
      expect(frames[2]!.last.offset, 320 * 80 * 3);
      expect(
        () => parseOcrRawFrames(
          logs.replaceFirst('n: 1', 'n: 4'),
          Directory('frames'),
          0,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'raw buffer stays bounded as regions grow, and geometry is mirrored before cropping',
    () {
      final tracks = List.generate(
        4,
        (i) => OcrSubtitleTrack(
          number: i + 1,
          region: const NormalizedOcrRegion.subtitleDefault(),
          language: OcrSubtitleLanguage.chinese,
        ),
      );
      final duration = ocrRawChunkMilliseconds(
        sourceWidth: 3840,
        sourceHeight: 2160,
        tracks: tracks,
        bufferBytes: 64 * 1024 * 1024,
      );
      expect(duration, inInclusiveRange(100, 15000));
      final one = ocrRawChunkMilliseconds(
        sourceWidth: 3840,
        sourceHeight: 2160,
        tracks: [tracks.first],
        bufferBytes: 64 * 1024 * 1024,
      );
      expect(duration, lessThanOrEqualTo(one));
      final filter = buildOcrRawFilter(
        OcrSubtitleJob(
          videoId: 'v',
          videoPath: 'v.mp4',
          tracks: tracks,
          start: Duration.zero,
          end: const Duration(seconds: 30),
          mirrorHorizontal: true,
        ),
      );
      expect(filter, contains('split=4'));
      expect(filter, contains('hflip,crop='));
      expect(filter, contains('showinfo@ocr_4'));
    },
  );

  test(
    'OCR recognition and decode share one resource ceiling and queue cancellation does not release another AI',
    () async {
      final governor = InferenceResourceGovernor(
        DeviceResourceSnapshot(
          platform: 'android',
          processors: 8,
          memoryBytes: 12 * 1073741824,
          availableMemoryBytes: 6 * 1073741824,
          capturedAt: DateTime.now(),
        ),
      );
      final session = InferenceResourceSession(governor);
      final decode = await session.acquire(InferenceLane.videoDecode);
      final ocr = await session.acquire(InferenceLane.ocr);
      expect(
        session.activeThreads,
        lessThanOrEqualTo(session.decision.totalThreads),
      );
      ocr.release();
      decode.release();
      await session.close();
      final scheduler = InferenceScheduler();
      final owner = await scheduler.acquire();
      final cancelled = Completer<void>();
      final waiter = scheduler.acquire(cancelSignal: cancelled.future);
      final assertion = expectLater(waiter, throwsStateError);
      cancelled.complete();
      await assertion;
      expect(scheduler.busy, isTrue);
      owner();
      expect(scheduler.busy, isFalse);
    },
  );

  test(
    'installed legacy models migrate once and deletion does not silently reinstall them',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('ocr-migration-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(root.path, 'support')),
          documents: Directory(p.join(root.path, 'documents')),
          defaultData: Directory(p.join(root.path, 'data')),
          executable: Directory(p.join(root.path, 'executable')),
        ),
      );
      await storage.initialize();
      final center = ModelCenterService(storage: storage);
      final manager = OcrModelManager(rootOverride: root, center: center);
      try {
        final directory = await manager.modelDirectory();
        await directory.create(recursive: true);
        for (final name in [
          'ch_PP-OCRv4_det_mobile.onnx',
          'ch_PP-OCRv4_rec_mobile.onnx',
          'ppocr_keys_v1.txt',
        ]) {
          await File(
            'assets/models/ocr/$name',
          ).copy(p.join(directory.path, name));
        }
        await manager.initialize();
        expect(await manager.isInstalled(OcrSubtitleLanguage.chinese), isTrue);
        final track = await manager.freeze(
          const OcrSubtitleTrack(
            number: 1,
            region: NormalizedOcrRegion.subtitleDefault(),
            language: OcrSubtitleLanguage.chinese,
          ),
        );
        expect(track.modelId, 'legacy-chinese');
        expect(track.modelIdentity, isNotEmpty);
        final preset = await manager.preset(track.modelId);
        final release = center.retainModel(preset.recognition);
        await expectLater(manager.remove(preset), throwsStateError);
        release();
        await manager.remove(preset);
        await manager.initialize();
        expect(manager.ready(preset), isFalse);
        expect(
          await File(
            p.join(directory.path, 'ch_PP-OCRv4_rec_mobile.onnx'),
          ).exists(),
          isTrue,
        );
        await expectLater(manager.freeze(track), throwsStateError);
      } finally {
        await center.shutdown();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'pipeline ETA observes actual overlap and separates model/back-end histories',
    () {
      var now = 1;
      final history = OcrPerformanceHistory(mobile: true);
      const a = OcrSubtitleTrack(
        number: 1,
        region: NormalizedOcrRegion.subtitleDefault(),
        language: OcrSubtitleLanguage.chinese,
        modelIdentity: 'mobile@1',
      );
      final b = a.copyWith(modelIdentity: 'small@1');
      history.useExecutionProfile(a, 'CPU:2:raw-v1');
      history.recordChunk(
        videoId: 'video',
        track: a,
        mediaMs: 15000,
        extractionMs: 100,
        frames: 15,
        steadyFrames: 15,
        recognitionMs: 150,
      );
      expect(history.hasMeasurements('video', [a]), isTrue);
      expect(history.hasMeasurements('video', [b]), isFalse);
      history.useExecutionProfile(a, 'DirectML:raw-v1');
      expect(history.hasMeasurements('video', [a]), isFalse);
      final runtime = OcrRuntimeEstimate(
        history: history,
        videoId: 'video',
        tracks: [a],
        spanMs: 60000,
        elapsedMs: () => now,
        pipeline: true,
      );
      runtime.pipelineStarted();
      now = 1001;
      runtime.pipelineChunkCompleted(15000, 1000);
      expect(runtime.remaining.inMilliseconds, lessThan(15000));
      now = 2001;
      runtime.pipelineChunkCompleted(30000, 1000);
      expect(runtime.remaining.inMilliseconds, lessThan(10000));
    },
  );
}
