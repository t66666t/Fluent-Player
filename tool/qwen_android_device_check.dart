// Explicit maintainer device entrypoint; not used by the shipped app startup.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/asr_benchmark.dart';
import 'package:video_player_app/features/model_center/device_resource_snapshot.dart';
import 'package:video_player_app/features/model_center/inference_resource_governor.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/qwen_asr_runtime.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/app_storage_service.dart';

class _Center extends ModelCenterService {
  _Center(this.weights, {required super.storage});
  final Directory weights;
  final states = <Map<String, dynamic>>[];
  @override
  Future<void> recordAsrState(
    String modelId,
    Map<String, dynamic> state,
  ) async {
    states.add(state);
  }

  @override
  Future<void> initialize() async {}
  Directory folder(ModelArtifact m) =>
      Directory(p.join(weights.path, '${m.id}-${m.revision.substring(0, 12)}'));
  @override
  Future<T> usingModel<T>(
    String id,
    Future<T> Function(ModelArtifact, Directory) action,
  ) => action(artifact(id)!, folder(artifact(id)!));
  @override
  Future<T> usingAsrModels<T>(
    ModelJobSpec spec,
    Future<T> Function(ModelArtifact, Directory, Map<String, String>) action,
  ) => action(
    artifact(spec.profile.model)!,
    folder(artifact(spec.profile.model)!),
    {
      for (final id in spec.enhancementModels.keys)
        id: folder(artifact(id)!).path,
    },
  );
  @override
  Future<void> prepareAsrEnhancements(
    ModelJobSpec spec, {
    Future<void>? cancelSignal,
    void Function(String)? onProgress,
  }) async {
    for (final id in [spec.profile.model, ...spec.enhancementModels.keys]) {
      final model = artifact(id)!;
      for (final file in model.files) {
        if (await File(p.join(folder(model).path, file.name)).length() !=
            file.bytes) {
          throw StateError('Prepared file missing: $id');
        }
      }
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final progress = ValueNotifier<String>('正在测试 Android Qwen 与字幕增强');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (_, value, _) => Text(value, textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  );
  final files = await getApplicationSupportDirectory();
  final cache = await getTemporaryDirectory();
  final documents = await getApplicationDocumentsDirectory();
  final external = await getExternalStorageDirectory();
  final root = await Directory(
    p.join(
      cache.path,
      'qwen-device-check-${DateTime.now().microsecondsSinceEpoch}',
    ),
  ).create(recursive: true);
  final report = <String, dynamic>{
    'os': Platform.operatingSystemVersion,
    'systemTemp': Directory.systemTemp.path,
    'tests': <String, dynamic>{},
  };
  final tests = report['tests'] as Map<String, dynamic>;
  Future<void> record() async {
    final contents = jsonEncode(report);
    await File(
      p.join(files.path, 'qwen-device-report.json'),
    ).writeAsString(contents);
    if (external != null) {
      await File(
        p.join(external.path, 'qwen-device-report.json'),
      ).writeAsString(contents);
    }
  }

  Future<void> step(
    String name,
    Future<Map<String, dynamic>> Function() body,
  ) async {
    progress.value = name;
    final watch = Stopwatch()..start();
    try {
      tests[name] = {
        ...await body(),
        'passed': true,
        'seconds': watch.elapsedMilliseconds / 1000,
      };
    } catch (error, stack) {
      tests[name] = {
        'passed': false,
        'error': '$error',
        'stack': '$stack',
        'seconds': watch.elapsedMilliseconds / 1000,
      };
    }
    await record();
  }

  final weights = Directory(p.join(documents.path, 'local_models'));
  final storage = AppStorageService(
    locations: () async => StorageLocations(
      platform: StoragePlatform.android,
      support: Directory(p.join(root.path, 'support')),
      documents: Directory(p.join(root.path, 'docs')),
      defaultData: Directory(p.join(root.path, 'data')),
      executable: root,
    ),
  );
  await storage.initialize();
  final center = _Center(weights, storage: storage)
    ..catalog = await loadModelCatalog();
  final actual = File(p.join(cache.path, 'qwen-native-probe/current.wav'));
  final samples = decodeModelWave(await actual.readAsBytes());
  final small = Float32List.sublistView(samples, 10 * 16000, 22 * 16000);
  final asr = center.artifact('qwen3-asr-0.6b-f16')!;
  const pipelineOnly = bool.fromEnvironment('QWEN_DEVICE_PIPELINE_ONLY');
  if (!pipelineOnly) {
    await step('Qwen CPU real Japanese', () async {
      final decoder = QwenAsrDecoder(
        model: p.join(center.folder(asr).path, asr.files.first.name),
        identity: asr.identity,
        language: 'ja',
        hotwords: '',
        onLoad: () {},
        onState: (_) {},
        threads: 4,
        mode: 'cpu',
      );
      try {
        final value = await decoder.decode(small, () {});
        if ((value['text'] as String).isEmpty) {
          throw StateError('Empty Japanese transcript');
        }
        return value;
      } finally {
        await decoder.close();
      }
    });
    await step('Qwen GPU fault then CPU recovery', () async {
      final states = <Map<String, dynamic>>[];
      final decoder = QwenAsrDecoder(
        model: p.join(center.folder(asr).path, asr.files.first.name),
        identity: asr.identity,
        language: 'ja',
        hotwords: '',
        onLoad: () {},
        onState: states.add,
        threads: 4,
        mode: 'auto',
      );
      try {
        final value = await decoder.decode(
          Float32List.sublistView(samples, 0, 25 * 16000),
          () {},
        );
        if ((value['text'] as String).isEmpty) {
          throw StateError('No recovery result');
        }
        return {'states': states, 'result': value};
      } finally {
        await decoder.close();
      }
    });
  }
  Future<Map<String, dynamic>> pipeline(
    String modelId,
    Float32List audio, {
    double? cap,
    bool forceAlignment = false,
    String language = 'auto',
    AsrAcceleration acceleration = AsrAcceleration.cpu,
  }) async {
    final model = center.artifact(modelId)!;
    final options = AsrEnhancementOptions(alwaysAlign: forceAlignment);
    final spec = ModelJobSpec(
      profile: ModelServiceProfile(
        id: 'probe-$modelId',
        name: model.name,
        kind: TranscriptionServiceKind.local,
        model: modelId,
        language: language,
      ),
      artifactIdentity: model.identity,
      asrTextProcessingVersion: currentAsrTextProcessingVersion,
      asrAcceleration: acceleration,
      asrExecution: AsrExecutionMode.pipeline,
      asrEnhancements: options,
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
    final phases = <String>{};
    int preparations = 0, batches = 0;
    InferenceResourceSession? resource;
    if (cap != null) {
      resource = InferenceResourceSession(
        InferenceResourceGovernor(
          DeviceResourceSnapshot(
            platform: 'android',
            processors: 8,
            memoryBytes: 15847739392,
            availableMemoryBytes: (cap * 1073741824).floor(),
            capturedAt: DateTime.now(),
          ),
        ),
      );
    }
    final runner = ModelTranscriptionRunner(center: center);
    Future<List<SubtitleItem>> run() => runner.run(
      spec: spec,
      sourceIdentity:
          'device-$modelId-${audio.length}-$cap-$forceAlignment-${acceleration.name}',
      duration: Duration(microseconds: audio.length * 1000000 ~/ 16000),
      resourceSession: resource,
      onProgress: (v) {
        phases.add(v.stage.name);
        progress.value = '$modelId\n${v.message}';
      },
      onStableBatch: (b) async {
        batches++;
      },
      prepareAudio: (start, count, pcm, onProgress) async {
        final from = (start.inMicroseconds * 16000 ~/ 1000000).clamp(
          0,
          audio.length,
        );
        final until = math.min(
          audio.length,
          from + count.inMicroseconds * 16000 ~/ 1000000,
        );
        final file = File(p.join(root.path, 'input-${++preparations}.wav'));
        await file.writeAsBytes(
          _wave(Float32List.sublistView(audio, from, until)),
        );
        return file.path;
      },
    );
    try {
      final result = await run();
      if (result.isEmpty || result.every((c) => c.text.isEmpty)) {
        throw StateError('No subtitle result');
      }
      if (audio.length > 120 * 16000 && (preparations < 2 || batches < 2)) {
        throw StateError('Multiple pipeline pieces were not exercised');
      }
      if (forceAlignment &&
          cap != null &&
          cap < 2 &&
          !result.any((c) => c.asrInfo.notes.any((n) => n.contains('内存')))) {
        throw StateError('Missing low-memory review');
      }
      final before = preparations;
      // InferenceScheduler closes even an explicitly supplied session. Replay
      // uses a fresh monitored session and the same isolated checkpoint.
      resource = null;
      final resumed = await run();
      if (preparations != before ||
          jsonEncode(resumed.map((c) => c.toTimingJson()).toList()) !=
              jsonEncode(result.map((c) => c.toTimingJson()).toList())) {
        throw StateError('Checkpoint replay changed');
      }
      return {
        'headroomCapGiB': cap,
        'requestedAcceleration': acceleration.name,
        'phases': phases.toList(),
        'preparations': preparations,
        'stableBatches': batches,
        'resumedWithoutRecognition': true,
        'cues': result.map((c) => c.toTimingJson()).toList(),
      };
    } finally {
      await resource?.close();
    }
  }

  if (pipelineOnly) {
    await step(
      'Qwen explicit benchmark preserves completed CPU checks',
      () async {
        final messages = <String>[];
        await benchmarkLocalAsr(
          center: center,
          model: asr,
          cancelSignal: Completer<void>().future,
          onProgress: messages.add,
        );
        if (center.states.isEmpty) throw StateError('No benchmark result');
        return {'states': center.states, 'messages': messages};
      },
    );
  }
  await step(
    'Qwen Japanese bounded pipeline',
    () => pipeline(asr.id, samples, acceleration: AsrAcceleration.auto),
  );
  final chinese = decodeModelWave(
    (await rootBundle.load(
      'assets/models/asr/speech_probe_zh.wav',
    )).buffer.asUint8List(),
  );
  await step(
    'SenseVoice auto Chinese at 4.87 GiB',
    () => pipeline(
      'sensevoice-small-int8',
      chinese,
      cap: 4.87,
      forceAlignment: true,
    ),
  );
  await step(
    'SenseVoice Japanese optional alignment under pressure',
    () => pipeline(
      'sensevoice-small-int8',
      small,
      cap: 1.2,
      forceAlignment: true,
      language: 'ja',
    ),
  );
  report['completed'] = true;
  report['passed'] = tests.values.every((v) => v['passed'] == true);
  await record();
  progress.value = '测试结束：${report['passed']}';
  // ignore: avoid_print
  print('QWEN_DEVICE_CHECK_DONE ${report['passed']}');
}

Uint8List _wave(Float32List samples) {
  final bytes = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(bytes);
  void label(int at, String s) =>
      bytes.setRange(at, at + s.length, s.codeUnits);
  label(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  label(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  label(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(
      44 + i * 2,
      (samples[i].clamp(-1, 1) * 32767).round(),
      Endian.little,
    );
  }
  return bytes;
}
