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
import 'package:video_player_app/models/subtitle_stream.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/ocr_compute_service.dart';
import 'package:video_player_app/services/ocr_model_manager.dart';
import 'package:video_player_app/services/ocr_subtitle_manager.dart';
import 'package:video_player_app/utils/ffmpeg_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const models = String.fromEnvironment('OCR_RUNTIME_ROOT');
  const helper = String.fromEnvironment('OCR_WORKER_EXECUTABLE');
  const benchmark = bool.fromEnvironment('OCR_STREAM_BENCHMARK');
  const report = String.fromEnvironment(
    'OCR_STREAM_REPORT',
    defaultValue: '.artifacts/ocr-stream-20261027/native-results.json',
  );
  test(
    'incremental OCR is visible before completion and resumes identical bilingual SRT',
    () async {
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'ocr-stream-native-',
      );
      final previousStorage = AppStorageService.instance;
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
      final modelManager = OcrModelManager(center: center);
      final image = im.Image(width: 1920, height: 1080);
      im.fill(image, color: im.ColorRgb8(28, 32, 40));
      for (final item in {'chinese': 500, 'english': 790}.entries) {
        final source = im.decodePng(
          await File(
            '.artifacts/ocr-upgrade/fixture/${item.key}.png',
          ).readAsBytes(),
        )!;
        im.compositeImage(
          image,
          im.copyResize(source, width: 1280, height: 256),
          dstX: 320,
          dstY: item.value,
        );
      }
      final png = '${directory.path}/1080p.png',
          video = '${directory.path}/1080p.mp4';
      await File(png).writeAsBytes(im.encodePng(image));
      final encode = await Process.run(await FFmpegUtils.ffmpegPath, [
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-loop',
        '1',
        '-framerate',
        '10',
        '-i',
        png,
        '-t',
        '60',
        '-vf',
        "drawbox=x=320:y=500:w=1280:h=256:color=0x1c2028:t=fill:enable='gte(mod(t,4),3)',"
            "drawbox=x=320:y=790:w=1280:h=256:color=0x1c2028:t=fill:enable='gte(mod(t,5),4)'",
        '-c:v',
        'libx264',
        '-threads',
        '1',
        '-pix_fmt',
        'yuv420p',
        video,
      ]);
      expect(encode.exitCode, 0, reason: '${encode.stderr}');
      final library = _Library(directory, video);
      final managers = <OcrSubtitleManager>[];
      final records = <Map<String, dynamic>>[];
      OcrSubtitleManager manager(bool incremental) {
        final result = OcrSubtitleManager(
          library: library,
          modelManager: modelManager,
          computeService: OcrComputeService(workerExecutable: helper),
          incrementalOutput: incremental,
        );
        managers.add(result);
        return result;
      }

      final request = OcrSubtitleJob(
        videoId: 'stream-native',
        videoPath: video,
        start: Duration.zero,
        end: const Duration(seconds: 60),
        compute: const OcrComputePreferences(mode: OcrComputeMode.cpu),
        tracks: [
          for (final item in {
            OcrSubtitleLanguage.chinese: 500,
            OcrSubtitleLanguage.english: 790,
          }.entries)
            OcrSubtitleTrack(
              number: item.key == OcrSubtitleLanguage.chinese ? 1 : 2,
              modelId: 'ppocr-v6-small',
              language: item.key,
              region: NormalizedOcrRegion(
                left: 320 / 1920,
                right: 1600 / 1920,
                top: item.value / 1080,
                bottom: (item.value + 256) / 1080,
              ),
            ),
        ],
      );
      Future<List<String>> result(OcrSubtitleManager value) async {
        await value.start(request);
        expect(
          value.job!.status,
          OcrSubtitleJobStatus.completed,
          reason: value.job!.error,
        );
        records.add({
          'incremental': value.incrementalOutput,
          ...value.lastPerformance,
        });
        return Future.wait(
          value.job!.outputPaths.map((path) => File(path).readAsString()),
        );
      }

      try {
        await modelManager.initialize();
        for (final id in ['ocr-v6-small-det', 'ocr-v6-small-rec']) {
          await center.importFiles(id, Directory('$models/$id'));
        }
        final baseline = await result(manager(false));
        final interrupted = manager(true);
        Future<void>? stopped;
        List<String>? partialPaths;
        final subscription = interrupted.subtitleUpdates.listen((update) {
          if (update.phase == SubtitleStreamPhase.generating &&
              update.cueCount > 0 &&
              stopped == null) {
            expect(update.autoSelectSuppressed, isTrue);
            expect(interrupted.job!.status, OcrSubtitleJobStatus.recognizing);
            partialPaths = update.paths;
            stopped = interrupted.stopStreamForPath(update.primaryPath);
          }
        });
        final running = interrupted.start(request);
        interrupted.preserveSubtitleSelection(video, videoId: request.videoId);
        await running;
        await stopped;
        await subscription.cancel();
        expect(
          stopped,
          isNotNull,
          reason: 'No partial subtitle appeared while OCR was recognizing',
        );
        expect(interrupted.job!.status, OcrSubtitleJobStatus.cancelled);
        expect(partialPaths, hasLength(2));
        expect(await File(partialPaths!.first).readAsString(), isNotEmpty);
        interrupted.dispose();
        managers.remove(interrupted);
        final restored = manager(true);
        await restored.initialize();
        expect(
          restored.subtitleStreams.single.phase,
          SubtitleStreamPhase.paused,
        );
        bool resumable(Duration end) => restored.canResumeConfiguration(
          videoId: request.videoId,
          tracks: request.tracks,
          start: request.start,
          end: end,
          mirrorHorizontal: request.mirrorHorizontal,
          mirrorVertical: request.mirrorVertical,
        );
        expect(resumable(request.end), isTrue);
        expect(resumable(request.end - const Duration(seconds: 1)), isFalse);
        expect(restored.subtitleStreams.single.autoSelectSuppressed, isTrue);
        final resumed = await result(restored);
        expect(resumed, baseline);
        expect(restored.job!.outputPaths, partialPaths);
        expect(restored.lastPerformance['resumedFromMs'], greaterThan(0));
        expect(resumed[0], contains('简体中文字幕识别测试'));
        expect(resumed[1], contains('English subtitle test'));
        if (benchmark) {
          // Warm both paths, then alternate their order; do not assert wall time
          // against a loaded workstation. The report is the performance gate.
          await result(manager(true));
          for (final enabled in [false, true, true, false, false, true]) {
            expect(await result(manager(enabled)), baseline);
          }
        }
        // Simulate a process exit after all SRTs were finalized but before the
        // coarse job-preferences record acknowledged completion. No inference
        // or new output generation is needed on the next launch.
        final last = managers.last;
        final finalPaths = List<String>.from(last.job!.outputPaths);
        await last.stopStreamForPath(finalPaths.first);
        final preferences = await SharedPreferences.getInstance();
        final stale =
            jsonDecode(preferences.getString('ocrSubtitleActiveJobV1')!) as Map;
        stale['status'] = 'recognizing';
        stale['outputPaths'] = <String>[];
        await preferences.setString(
          'ocrSubtitleActiveJobV1',
          jsonEncode(stale),
        );
        final finalized = manager(true);
        await finalized.initialize();
        expect(finalized.job!.status, OcrSubtitleJobStatus.completed);
        expect(finalized.job!.outputPaths, finalPaths);
        expect(center.hasModelLeases, isFalse);
        expect(InferenceScheduler.instance.busy, isFalse);
        await File(report).parent.create(recursive: true);
        await File(report).writeAsString(
          const JsonEncoder.withIndent(
            '  ',
          ).convert({'runs': records, 'outputs': baseline}),
        );
      } finally {
        for (final value in managers) {
          value.dispose();
        }
        library.dispose();
        await center.shutdown();
        AppStorageService.instance = previousStorage;
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || models.isEmpty || helper.isEmpty,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

class _Library extends ChangeNotifier implements LibraryService {
  _Library(this.root, this.path);
  final Directory root;
  final String path;
  int next = 0;
  @override
  VideoItem? getVideo(String id) => VideoItem(
    id: id,
    path: path,
    title: 'OCR streaming',
    durationMs: 60000,
    lastUpdated: 0,
  );
  @override
  Future<String> allocateSubtitleFile(String videoId, String name) async {
    final folder = await Directory(
      '${root.path}/outputs',
    ).create(recursive: true);
    return '${folder.path}/${next++}-$name';
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
