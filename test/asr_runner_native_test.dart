import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_device_info.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'support/prepared_local_models.dart';

String _projectPath(String relative) {
  const project = String.fromEnvironment('ASR_PIPELINE_ROOT');
  return p.join(project.isEmpty ? Directory.current.path : project, relative);
}

class _Center extends ModelCenterService with PreparedLocalModels {
  _Center({required super.storage});
  @override
  Future<void> initialize() async {}
  @override
  Future<void> prepareAsrEnhancements(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) async {}
  @override
  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => action(
    artifact(spec.profile.model)!,
    Directory(
      _projectPath('.artifacts/model-center/native/${spec.profile.model}'),
    ),
    {
      for (final id in spec.enhancementModels.keys)
        id: _projectPath('.artifacts/model-center/enhancements/$id'),
    },
  );
}

Uint8List _wave(Float32List samples) {
  final out = Uint8List(44 + samples.length * 2),
      data = ByteData(44 + samples.length * 2);
  void tag(int at, String value) {
    out.setRange(at, at + value.length, value.codeUnits);
  }

  tag(0, 'RIFF');
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  tag(36, 'data');
  data.setUint32(4, out.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(
      44 + i * 2,
      (samples[i] * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  for (var i = 0; i < out.length; i++) {
    if (i < 4 || i >= 8 && i < 16 || i >= 36 && i < 40) continue;
    out[i] = data.getUint8(i);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('ASR_PIPELINE_NATIVE');
  test(
    'production runner overlaps real native stages and resumes complete checkpoints without preparing audio',
    () async {
      SharedPreferences.setMockInitialValues({});
      DynamicLibrary.open(_projectPath('windows/runtime/onnxruntime.dll'));
      final root = await Directory.systemTemp.createTemp('asr-runner-native-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(root.path, 'support')),
          documents: Directory(p.join(root.path, 'documents')),
          defaultData: Directory(p.join(root.path, 'data')),
          executable: Directory(p.join(root.path, 'exe')),
        ),
      );
      await storage.initialize();
      final center = _Center(storage: storage)
        ..catalog = await loadModelCatalog();
      final model = center.artifact('parakeet-v3-int8')!;
      const options = AsrEnhancementOptions();
      final spec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'native',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
          language: 'en',
        ),
        artifactIdentity: model.identity,
        asrCpuThreads: 0,
        asrEnhancements: options,
        subtitleSegmentation: SubtitleSegmentationOptions.natural,
        enhancementModels: {
          for (final id in options.requiredModels(['en'], 'en'))
            id: center.artifact(id)!.identity,
        },
      );
      final probe = decodeModelWave(
        await File('assets/models/asr/speech_probe.wav').readAsBytes(),
      );
      final audio = Float32List(130 * 16000);
      for (final second in [0, 30, 60, 90]) {
        audio.setRange(second * 16000, second * 16000 + probe.length, probe);
      }
      final workers = <LocalAsrWorker>[];
      var prepared = 0;
      final runner = ModelTranscriptionRunner(
        center: center,
        loadDeviceInfo: () async => const ModelDeviceInfo(
          memoryBytes: 32 * 1073741824,
          availableMemoryBytes: 24 * 1073741824,
          processors: 8,
        ),
        createLocalWorker: () {
          final w = LocalAsrWorker(
            libraryDirectory:
                '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev/sherpa_onnx_windows-1.12.12/windows',
          );
          workers.add(w);
          return w;
        },
      );
      final progress = <double>[];
      var overlapped = false;
      final captured = DateTime.now();
      Future<List<Map<String, dynamic>>> run() async => (await runner.run(
        spec: spec,
        resourceSession: InferenceResourceSession(
          InferenceResourceGovernor(
            DeviceResourceSnapshot(
              platform: 'windows',
              processors: 8,
              memoryBytes: 32 * 1073741824,
              availableMemoryBytes: 24 * 1073741824,
              capturedAt: captured,
            ),
            now: () => captured,
          ),
          onBudget: (budget) {
            final active =
                budget.activeAsrThreads +
                budget.activeAuxiliaryThreads +
                budget.activeTranslationThreads;
            expect(active, lessThanOrEqualTo(budget.totalThreads));
            if (budget.activeAsrThreads > 0 &&
                budget.activeAuxiliaryThreads > 0) {
              overlapped = true;
            }
          },
        ),
        sourceIdentity: 'native-pipeline-fixture',
        duration: const Duration(seconds: 130),
        prepareAudio: (start, count, _, _) async {
          prepared++;
          final file = File(
            p.join(root.path, 'audio-${start.inMilliseconds}.wav'),
          );
          await file.writeAsBytes(
            _wave(
              Float32List.fromList(
                audio.sublist(
                  start.inMicroseconds * 16000 ~/ 1000000,
                  (start + count).inMicroseconds * 16000 ~/ 1000000,
                ),
              ),
            ),
          );
          return file.path;
        },
        onProgress: (value) {
          progress.add(value.fraction);
        },
      )).map((c) => c.toTimingJson()).toList();
      try {
        final result = await run();
        expect(result, isNotEmpty);
        expect(
          RegExp(
            r'\bcountry\b',
            caseSensitive: false,
          ).allMatches(result.map((c) => c['t']).join(' ')).length,
          8,
        );
        expect(prepared, 3);
        expect(workers.first.modelLoads, 1);
        expect(
          overlapped,
          isTrue,
          reason:
              'real native owners must overlap, not only display a pipeline label',
        );
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
        }
        progress.clear();
        overlapped = false;
        expect(await run(), result);
        expect(
          overlapped,
          isFalse,
          reason: 'complete checkpoints must not run native work again',
        );
        expect(prepared, 3);
        expect(
          await Directory(
            root.path,
          ).list().where((f) => f.path.endsWith('.wav')).isEmpty,
          isTrue,
        );
      } finally {
        await center.shutdown();
        await root.delete(recursive: true);
      }
    },
    skip: !enabled || !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
