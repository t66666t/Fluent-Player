import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/models/managed_subtitle_asset.dart';
import 'package:video_player_app/models/ocr_compute_preferences.dart';
import 'package:video_player_app/models/ocr_subtitle_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/ocr_compute_service.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const root = String.fromEnvironment('OCR_RUNTIME_ROOT');
  const helper = String.fromEnvironment('OCR_WORKER_EXECUTABLE');
  const fault = String.fromEnvironment('OCR_FAULT_WORKER_EXECUTABLE');
  const report = String.fromEnvironment(
    'OCR_CRASH_REPORT',
    defaultValue: '.artifacts/om26/crash-recovery.json',
  );
  final markerPath = Platform.environment['OCR_TEST_FAULT_MARKER'];
  final startupMarkerPath =
      Platform.environment['OCR_TEST_STARTUP_FAULT_MARKER'];
  test(
    'two Small regions on 1080p video survive CPU process exit near 56 percent with identical SRT',
    () async {
      SharedPreferences.setMockInitialValues({});
      final previousStorage = AppStorageService.instance;
      final directory = await Directory.systemTemp.createTemp(
        'ocr-crash-recovery-',
      );
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
      // Use a task-local model center; no user's installed models/preferences.
      final modelManager = OcrModelManager(center: center);
      final image = im.Image(width: 1920, height: 1080);
      im.fill(image, color: im.ColorRgb8(28, 32, 40));
      for (final e in {'chinese': 500, 'english': 790}.entries) {
        final source = im.decodePng(
          await File(
            '.artifacts/ocr-upgrade/fixture/${e.key}.png',
          ).readAsBytes(),
        )!;
        im.compositeImage(
          image,
          im.copyResize(source, width: 1280, height: 256),
          dstX: 320,
          dstY: e.value,
        );
      }
      final imagePath = '${directory.path}/1080p.png',
          videoPath = '${directory.path}/1080p.mp4';
      await File(imagePath).writeAsBytes(im.encodePng(image));
      final encode = await Process.run(await FFmpegUtils.ffmpegPath, [
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-loop',
        '1',
        '-framerate',
        '5',
        '-i',
        imagePath,
        '-t',
        '12',
        '-c:v',
        'libx264',
        '-threads',
        '1',
        '-pix_fmt',
        'yuv420p',
        videoPath,
      ]);
      expect(encode.exitCode, 0, reason: '${encode.stderr}');
      final library = _Library(directory, videoPath);
      final managers = <OcrSubtitleManager>[];
      try {
        final marker = File(markerPath!);
        expect(marker.uri.pathSegments.last, 'ocr-fault-once.marker');
        if (await marker.exists()) await marker.delete();
        if (startupMarkerPath != null) {
          final startupMarker = File(startupMarkerPath);
          expect(
            startupMarker.uri.pathSegments.last,
            'ocr-startup-fault-once.marker',
          );
          if (await startupMarker.exists()) await startupMarker.delete();
        }
        await modelManager.initialize();
        for (final id in ['ocr-v6-small-det', 'ocr-v6-small-rec']) {
          await center.importFiles(id, Directory('$root/$id'));
        }
        final outputs = <List<String>>[];
        final records = <Map<String, Object?>>[];
        for (final scenario in [
          (helper, OcrComputeMode.cpu, 'auto', 2),
          (helper, OcrComputeMode.accelerated, 'DirectML', 2),
          (helper, OcrComputeMode.accelerated, 'Vulkan', 2),
          (helper, OcrComputeMode.accelerated, 'OpenCL', 2),
          // A CPU native crash deliberately persists conservative mode for
          // this model. Inject it last so later GPU cases remain independent.
          (fault, OcrComputeMode.cpu, 'auto', 2),
          if (startupMarkerPath != null) (fault, OcrComputeMode.cpu, 'auto', 1),
        ]) {
          if (scenario.$1 == fault && startupMarkerPath != null) {
            if (await marker.exists()) await marker.delete();
            final startupMarker = File(startupMarkerPath);
            if (await startupMarker.exists()) await startupMarker.delete();
          }
          final manager = OcrSubtitleManager(
            library: library,
            modelManager: modelManager,
            computeService: OcrComputeService(workerExecutable: scenario.$1),
          );
          managers.add(manager);
          final progress = <double>[];
          final recognition = <OcrSubtitleJob>[];
          var recoveredStartup = false;
          manager.addListener(() {
            if (manager.job?.statusMessage == '正在恢复 OCR 识别进程') {
              recoveredStartup = true;
            }
            if (manager.job != null) progress.add(manager.job!.progress);
            if (manager.job?.status == OcrSubtitleJobStatus.recognizing) {
              recognition.add(manager.job!);
            }
          });
          await manager.start(
            OcrSubtitleJob(
              videoId: 'crash-fixture',
              videoPath: videoPath,
              start: Duration.zero,
              end: const Duration(seconds: 12),
              compute: OcrComputePreferences(
                mode: scenario.$2,
                provider: scenario.$3,
              ),
              tracks: [
                for (final e in {
                  OcrSubtitleLanguage.chinese: 500,
                  OcrSubtitleLanguage.english: 790,
                }.entries.take(scenario.$4))
                  OcrSubtitleTrack(
                    number: e.key == OcrSubtitleLanguage.chinese ? 1 : 2,
                    modelId: 'ppocr-v6-small',
                    language: e.key,
                    region: NormalizedOcrRegion(
                      left: 320 / 1920,
                      right: 1600 / 1920,
                      top: e.value / 1080,
                      bottom: (e.value + 256) / 1080,
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
          outputs.add(
            await Future.wait(
              manager.job!.outputPaths.map((p) => File(p).readAsString()),
            ),
          );
          records.add({
            ...manager.lastPerformance,
            'startupRecovered': recoveredStartup,
            'regionCount': scenario.$4,
          });
          if (scenario.$1 == fault && startupMarkerPath != null) {
            expect(recoveredStartup, isTrue);
            expect(await File(startupMarkerPath).exists(), isTrue);
            expect(await marker.exists(), isTrue);
          }
          for (var i = 1; i < progress.length; i++) {
            expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
          }
          expect(recognition.first.progress, 0);
          final coverage = {
            for (final track in manager.job!.tracks) track.number: 0,
          };
          for (final update in recognition) {
            final state = update.recognitionProgress!;
            for (final entry in state.completedByTrack.entries) {
              expect(
                entry.value.inMilliseconds,
                greaterThanOrEqualTo(coverage[entry.key]!),
              );
              coverage[entry.key] = entry.value.inMilliseconds;
            }
            final fraction =
                coverage.values.reduce((a, b) => a + b) /
                (state.total.inMilliseconds * coverage.length);
            expect(update.progress, closeTo(fraction.clamp(0, .99), 1e-9));
          }
          expect(
            manager.job!.recognitionProgress!.completedByTrack.values,
            everyElement(const Duration(seconds: 12)),
          );
          expect(InferenceScheduler.instance.busy, isFalse);
          expect(center.hasModelLeases, isFalse);
        }
        expect(await File(markerPath).exists(), isTrue);
        if (startupMarkerPath != null) {
          expect(await File(startupMarkerPath).exists(), isTrue);
        }
        expect(outputs[1], outputs[0]);
        expect(outputs[2], outputs[0]);
        expect(outputs[3], outputs[0]);
        expect(outputs[4], outputs[0]);
        if (startupMarkerPath != null) {
          expect(outputs[5], [outputs[0].first]);
        }
        expect(outputs[1][0], contains('简体中文字幕识别测试'));
        expect(outputs[1][1], contains('English subtitle test'));
        expect(records[1]['backends'], contains('DirectML'));
        await File(report).parent.create(recursive: true);
        await File(report).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'runs': records,
            'outputs': outputs,
            'scenario':
                '1080p, two Small regions, fatal CPU process exit at 6600ms',
            'startupExitInjected': startupMarkerPath != null,
          }),
        );
        expect(records[2]['backends'], contains('Vulkan'));
        expect(records[3]['backends'], contains('OpenCL'));
        expect(records[4]['recoveredTracks'], isNotEmpty);
      } finally {
        for (final manager in managers) {
          manager.dispose();
        }
        library.dispose();
        await center.shutdown();
        AppStorageService.instance = previousStorage;
        await directory.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        root.isEmpty ||
        helper.isEmpty ||
        fault.isEmpty ||
        markerPath == null,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

class _Library extends ChangeNotifier implements LibraryService {
  _Library(this.root, this.videoPath);
  final Directory root;
  final String videoPath;
  @override
  VideoItem? getVideo(String id) => VideoItem(
    id: id,
    path: videoPath,
    title: 'OCR crash test',
    durationMs: 12000,
    lastUpdated: 0,
  );
  @override
  Future<String> allocateSubtitleFile(
    String id,
    String preferredFileName,
  ) async {
    final directory = Directory('${root.path}/outputs');
    await directory.create(recursive: true);
    return '${directory.path}/$preferredFileName';
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
  }) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
