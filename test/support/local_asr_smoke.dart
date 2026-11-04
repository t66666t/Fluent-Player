import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/inference_scheduler.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/app_storage_service.dart';

/// Streams prepared weights through the real download queue on desktop. The
/// device variant uses the same files served over an explicitly supplied URL.
class _PreparedFiles implements HttpClientAdapter {
  _PreparedFiles(this.root, this.requests);
  final String root;
  final List<String> requests;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    final path = options.uri.pathSegments;
    final file = File(p.join(root, path[path.length - 2], path.last));
    requests.add(file.path);
    return ResponseBody(
      file.openRead().map(Uint8List.fromList),
      200,
      headers: {
        'content-length': ['${await file.length()}'],
        'etag': ['"fixture-v1"'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<Map<String, Object?>> runLocalAsrSmoke({
  String? modelRoot,
  String? fixtureBase,
  String? libraryDirectory,
}) async {
  SharedPreferences.setMockInitialValues({});
  final temporary = await Directory.systemTemp.createTemp(
    'community-asr-smoke-',
  );
  final storage = AppStorageService(
    locations: () async => StorageLocations(
      platform: StoragePlatform.linux,
      support: Directory(p.join(temporary.path, 'support')),
      documents: Directory(p.join(temporary.path, 'documents')),
      defaultData: Directory(p.join(temporary.path, 'data')),
      executable: Directory(p.join(temporary.path, 'exe')),
    ),
  );
  final requests = <String>[];
  final catalog = (await loadModelCatalog())
      .where(
        (m) => [
          'sensevoice-small-int8',
          'dolphin-base-int8',
          asrVadModelId,
        ].contains(m.id),
      )
      .map(
        (m) => ModelArtifact(
          id: m.id,
          name: m.name,
          engine: m.engine,
          revision: m.revision,
          parameters: m.parameters,
          quantization: m.quantization,
          languages: m.languages,
          description: m.description,
          license: m.license,
          homepage: m.homepage,
          purpose: m.purpose,
          suggestedRamGb: m.suggestedRamGb,
          memoryNote: m.memoryNote,
          files: [
            for (final f in m.files)
              ModelFile(
                name: f.name,
                bytes: f.bytes,
                sha256: f.sha256,
                sources: {
                  'fixture':
                      '${fixtureBase ?? 'https://fixture.invalid'}/${m.id}/${f.name}',
                },
              ),
          ],
        ),
      )
      .toList();
  ModelCenterService openCenter() => ModelCenterService(
    storage: storage,
    catalogLoader: () async => catalog,
    createDio: () {
      final dio = Dio();
      if (fixtureBase == null) {
        dio.httpClientAdapter = _PreparedFiles(modelRoot!, requests);
      }
      return dio;
    },
  );
  var center = openCenter();
  final report = <String, Object?>{'platform': Platform.operatingSystem};
  try {
    final sample = await rootBundle.load(
      'assets/models/asr/speech_probe_zh.wav',
    );
    final audio = File(p.join(temporary.path, 'speech.wav'));
    await audio.writeAsBytes(
      sample.buffer.asUint8List(sample.offsetInBytes, sample.lengthInBytes),
    );
    final duration = Duration(
      microseconds:
          (decodeModelWave(await audio.readAsBytes()).length / 16000 * 1000000)
              .round(),
    );
    for (final id in ['sensevoice-small-int8', 'dolphin-base-int8']) {
      await center.initialize();
      center.asrEnhancements = AsrEnhancementOptions.disabled;
      center.asrCpuThreads = 2;
      center.asrAccelerationOptions[id] = AsrAcceleration.cpu;
      await center.selectAsr(center.artifact(id)!);
      expect(center.installed(id), isFalse);
      final spec = await center.captureTranscription();
      expect(spec.artifactIdentity, center.artifact(id)!.identity);
      final progress = <ModelProcessingProgress>[];
      var preparedPieces = 0;
      ModelTranscriptionRunner runner() => ModelTranscriptionRunner(
        center: center,
        createLocalWorker: () =>
            LocalAsrWorker(libraryDirectory: libraryDirectory),
      );
      Future<List<SubtitleItem>> run(
        String source, {
        bool restored = false,
        Future<void>? cancel,
        void Function()? onAudio,
      }) => runner().run(
        spec: spec,
        sourceIdentity: source,
        duration: duration,
        cancelSignal: cancel,
        onProgress: progress.add,
        prepareAudio: (_, _, _, _) async {
            if (restored) {
            fail('Completed checkpoints must not extract audio again');
            }
          onAudio?.call();
          return (await audio.copy(
            p.join(temporary.path, 'piece-${preparedPieces++}.wav'),
          )).path;
        },
      );
      final clock = Stopwatch()..start();
      final first = await run(id);
      expect(first, isNotEmpty, reason: id);
      expect(
        first.map((c) => c.text).join(),
        matches(RegExp(r'[\u4e00-\u9fff]')),
      );
      for (final cue in first) {
        expect(cue.endTime, greaterThan(cue.startTime));
        expect(cue.startTime, greaterThanOrEqualTo(Duration.zero));
        expect(
          cue.endTime.inMilliseconds,
          lessThanOrEqualTo(duration.inMilliseconds + 100),
        );
      }
      expect(
        progress.any((e) => e.stage == ModelProcessingStage.downloading),
        isTrue,
      );
      expect(center.installed(asrVadModelId), isTrue);
      final repeat = await run('$id-repeat');
      expect(
        repeat.map((c) => c.toTimingJson()).toList(),
        first.map((c) => c.toTimingJson()).toList(),
      );
      final cancelled = Completer<void>();
      await expectLater(
        run(
          '$id-cancel',
          cancel: cancelled.future,
          onAudio: cancelled.complete,
        ),
        throwsStateError,
      );
      expect(InferenceScheduler.instance.busy, isFalse);
      await center.shutdown();
      center.dispose();
      center = openCenter();
      await center.initialize();
      expect(center.installed(id), isTrue);
      final restored = await run(id, restored: true);
      expect(
        restored.map((c) => c.toTimingJson()).toList(),
        first.map((c) => c.toTimingJson()).toList(),
      );
      report[id] = {
        'text': first.map((c) => c.text).join(' '),
        'cues': first.map((c) => c.toTimingJson()).toList(),
        'elapsedMs': clock.elapsedMilliseconds,
        'downloadedThroughModelQueue': true,
        'repeat': true,
        'cancelledAndReleased': true,
        'restoredCheckpoint': true,
      };
    }
    if (fixtureBase == null) {
      expect(
        requests.where((path) => p.basename(path) == asrVadFileName),
        hasLength(1),
      );
    }
    return report;
  } finally {
    await center.shutdown();
    center.dispose();
    final resolved = await temporary.resolveSymbolicLinks();
    if (!p.isWithin(
      Directory.systemTemp.resolveSymbolicLinksSync(),
      resolved,
    )) {
      throw StateError('Smoke cleanup outside temporary storage');
    }
    await temporary.delete(recursive: true);
  }
}
