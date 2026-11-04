import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'support/cohere_candidate.dart';
import 'support/prepared_local_models.dart';

class _Center extends ModelCenterService with PreparedLocalModels {
  _Center({required super.storage});
  final states = <Map<String, dynamic>>[];
  @override
  Future<void> recordAsrState(
    String modelId,
    Map<String, dynamic> state,
  ) async {
    states.add(state);
  }

  String folder(String id) {
    for (final kind in ['native', 'enhancements']) {
      final directory = p.absolute('.artifacts/model-center', kind, id);
      if (Directory(directory).existsSync()) return directory;
    }
    throw StateError('Prepared native weights missing: $id');
  }

  @override
  Future<void> prepareAsrEnhancements(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) async {
    for (final id in [spec.profile.model, ...spec.enhancementModels.keys]) {
      final model = artifact(id)!;
      for (final file in model.files) {
        if (File(p.join(folder(id), file.name)).lengthSync() != file.bytes) {
          throw StateError('Incomplete native weight: $id');
        }
      }
    }
  }

  @override
  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => action(
    artifact(spec.profile.model)!,
    Directory(folder(spec.profile.model)),
    {for (final id in spec.enhancementModels.keys) id: folder(id)},
  );
}

Uint8List _wave(Float32List audio) {
  final bytes = Uint8List(44 + audio.length * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int at, String text) => bytes.setRange(at, at + 4, text.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, audio.length * 2, Endian.little);
  for (var i = 0; i < audio.length; i++) {
    data.setInt16(
      44 + i * 2,
      (audio[i] * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return bytes;
}

String _stamp(Duration d) =>
    '${'${d.inHours}'.padLeft(2, '0')}:${'${d.inMinutes % 60}'.padLeft(2, '0')}:${'${d.inSeconds % 60}'.padLeft(2, '0')},${'${d.inMilliseconds % 1000}'.padLeft(3, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const audioPath = String.fromEnvironment('COHERE_AUDIO');
  const output = String.fromEnvironment('COHERE_OUTPUT');
  const language = String.fromEnvironment(
    'COHERE_LANGUAGE',
    defaultValue: 'auto',
  );
  const denoise = bool.fromEnvironment('COHERE_DENOISE', defaultValue: true);
  const seconds = int.fromEnvironment('COHERE_SECONDS');
  const optionsFile = String.fromEnvironment('COHERE_OPTIONS_FILE');
  const executionName = String.fromEnvironment(
    'COHERE_EXECUTION',
    defaultValue: 'pipeline',
  );
  const modelId = String.fromEnvironment(
    'JAPANESE_ASR_MODEL',
    defaultValue: 'cohere-transcribe-03-2026-q8',
  );
  test(
    'Cohere real production pipeline: language, stable batches, alignment and resume',
    () async {
      SharedPreferences.setMockInitialValues({});
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
      final packages =
          jsonDecode(
                await File('.dart_tool/package_config.json').readAsString(),
              )
              as Map;
      final sherpa = (packages['packages'] as List).cast<Map>().singleWhere(
        (v) => v['name'] == 'sherpa_onnx_windows',
      );
      final libraries = p.join(
        File(
          '.dart_tool/package_config.json',
        ).absolute.uri.resolve(sherpa['rootUri'] as String).toFilePath(),
        'windows',
      );
      final temp = await Directory.systemTemp.createTemp('cohere-pipeline-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(temp.path, 'support')),
          documents: Directory(p.join(temp.path, 'docs')),
          defaultData: Directory(p.join(temp.path, 'data')),
          executable: Directory(p.join(temp.path, 'exe')),
        ),
      );
      await storage.initialize();
      final center = _Center(storage: storage)
        ..catalog = [...await loadModelCatalog(), cohereComparisonCandidate()];
      final source = decodeModelWave(await File(audioPath).readAsBytes());
      final length = math.min(
        source.length,
        seconds > 0 ? seconds * 16000 : source.length,
      );
      final duration = Duration(microseconds: length * 1000000 ~/ 16000);
      final options = optionsFile.isEmpty
          ? AsrEnhancementOptions(denoise: denoise)
          : AsrEnhancementOptions.fromJson(
              jsonDecode(await File(optionsFile).readAsString()),
            );
      final model = center.artifact(modelId)!;
      final spec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'cohere-device',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
          language: language,
        ),
        artifactIdentity: model.identity,
        asrTokenTiming: asrTokenTimingOverride(model.id, model.engine),
        asrTextProcessingVersion: currentAsrTextProcessingVersion,
        asrCpuThreads: 4,
        asrAcceleration: AsrAcceleration.cpu,
        asrExecution: AsrExecutionMode.values.singleWhere(
          (v) => v.name == executionName,
        ),
        asrEnhancements: options,
        subtitleSegmentation: SubtitleSegmentationOptions.natural,
        enhancementModels: {
          for (final id in options.requiredModels(
            model.languages,
            language,
            textProcessingVersion: currentAsrTextProcessingVersion,
            recognitionEngine: model.engine,
          ))
            id: center.artifact(id)!.identity,
        },
      );
      final workers = <LocalAsrWorker>[];
      var preparations = 0;
      var batches = 0;
      final published = <Map<String, dynamic>>[];
      final trace = <Map<String, dynamic>>[];
      final watch = Stopwatch()..start();
      final report = <String, dynamic>{
        'platform': 'Windows',
        'model': model.identity,
        'language': language,
        'denoise': options.denoise,
        'enhancementOptions': options.toJson(),
        'execution': executionName,
        'audioSeconds': duration.inMicroseconds / 1e6,
        'threadsRequested': 4,
      };
      Directory(output).createSync(recursive: true);
      try {
        final runner = ModelTranscriptionRunner(
          center: center,
          createLocalWorker: () {
            final worker = LocalAsrWorker(
              libraryDirectory: libraries,
              qwenWorkerExecutable: p.absolute(
                'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',
              ),
              cohereWorkerExecutable: p.absolute(
                'native/cohere_asr/prebuilt/windows-x64/cohere_asr_worker.exe',
              ),
              parakeetJapaneseWorkerExecutable: p.absolute(
                'native/parakeet_ja/prebuilt/windows-x64/parakeet_ja_worker.exe',
              ),
            );
            workers.add(worker);
            return worker;
          },
        );
        Future<String> prepare(
          Duration start,
          Duration count,
          bool pcm,
          void Function(double) progress,
        ) async {
          preparations++;
          final lo = (start.inMicroseconds * 16000 ~/ 1000000).clamp(0, length);
          final hi = math.min(
            length,
            lo + count.inMicroseconds * 16000 ~/ 1000000,
          );
          final path = p.join(
            temp.path,
            'audio-${start.inMilliseconds}-$preparations.wav',
          );
          await File(
            path,
          ).writeAsBytes(_wave(Float32List.sublistView(source, lo, hi)));
          return path;
        }

        void progress(ModelProcessingProgress v) {
          if (trace.isEmpty || trace.last['stage'] != v.stage.name) {
            trace.add({
              'seconds': watch.elapsedMilliseconds / 1000,
              'stage': v.stage.name,
              'message': v.message,
            });
            File(p.join(output, 'live.jsonl')).writeAsStringSync(
              '${jsonEncode(trace.last)}\n',
              mode: FileMode.append,
            );
          }
        }

        final result = await runner.run(
          spec: spec,
          sourceIdentity: 'cohere-supplied-video',
          duration: duration,
          prepareAudio: prepare,
          onProgress: progress,
          onStableBatch: (batch) async {
            batches++;
            published.addAll(batch.cues.map((cue) => cue.toTimingJson()));
          },
        );
        report.addAll({
          'elapsedSeconds': watch.elapsedMilliseconds / 1000,
          'preparations': preparations,
          'stableBatches': batches,
          'states': center.states,
          'trace': trace,
          'cues': result.map((c) => c.toTimingJson()).toList(),
          'primaryLoads': workers.fold<int>(0, (n, w) => n + w.modelLoads),
        });
        expect(result, isNotEmpty);
        expect(batches, greaterThan(0));
        expect(
          published,
          result.map((cue) => cue.toTimingJson()).toList(),
          reason:
              'Stable batches handed to translation must exactly equal the final subtitle output',
        );
        report['stableBatchesMatchFinalOutput'] = true;
        expect(
          result.every(
            (c) =>
                c.endTime > c.startTime &&
                c.startTime >= Duration.zero &&
                c.endTime <= duration,
          ),
          isTrue,
        );
        expect(
          result
              .expand((c) => c.timedSpans)
              .every((s) => s.endTime > s.startTime),
          isTrue,
        );
        final before = preparations;
        final resumed = await runner.run(
          spec: ModelJobSpec.fromJson(spec.toJson()),
          sourceIdentity: 'cohere-supplied-video',
          duration: duration,
          prepareAudio: prepare,
          onProgress: (_) {},
          onStableBatch: (_) async {},
        );
        expect(
          resumed.map((c) => c.toTimingJson()).toList(),
          result.map((c) => c.toTimingJson()).toList(),
        );
        expect(preparations, before);
        report['resumeWithoutNewInference'] = true;
        await File(p.join(output, 'subtitles.srt')).writeAsString(
          [
            for (final cue in result)
              '${cue.index}\n${_stamp(cue.startTime)} --> ${_stamp(cue.endTime)}\n${cue.text}\n',
          ].join('\n'),
        );
        report['passed'] = true;
      } catch (error, stack) {
        report.addAll({
          'passed': false,
          'error': '$error',
          'stack': '$stack',
          'trace': trace,
        });
        rethrow;
      } finally {
        await File(
          p.join(output, 'pipeline.json'),
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
        await center.shutdown();
        center.dispose();
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || audioPath.isEmpty || output.isEmpty,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
