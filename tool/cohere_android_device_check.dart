// Explicit maintainer entrypoint. Never called by the normal application.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/cohere_asr_runtime.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/model_adapters.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/subtitle_word_timing_store.dart';
import '../test/support/cohere_candidate.dart';

class _Center extends ModelCenterService {
  _Center(this.weights, {required super.storage});
  final Directory weights;
  final states = <Map<String, dynamic>>[];
  Directory folder(ModelArtifact model) => Directory(
    p.join(weights.path, '${model.id}-${model.revision.substring(0, 12)}'),
  );
  @override
  Future<void> recordAsrState(String id, Map<String, dynamic> state) async {
    states.add(state);
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
        if (File(p.join(folder(model).path, file.name)).lengthSync() !=
            file.bytes)
          throw StateError('Prepared weights missing: $id');
      }
    }
  }

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
}

Uint8List _wave(Float32List samples) {
  final bytes = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int at, String value) =>
      bytes.setRange(at, at + value.length, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(
      44 + i * 2,
      (samples[i] * 32768).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return bytes;
}

String _stamp(Duration d) =>
    '${'${d.inHours}'.padLeft(2, '0')}:${'${d.inMinutes % 60}'.padLeft(2, '0')}:${'${d.inSeconds % 60}'.padLeft(2, '0')},${'${d.inMilliseconds % 1000}'.padLeft(3, '0')}';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const modelId = String.fromEnvironment(
    'JAPANESE_ASR_MODEL',
    defaultValue: 'cohere-transcribe-03-2026-q8',
  );
  const fullAudio = bool.fromEnvironment('JAPANESE_FULL_AUDIO');
  const provisionResult = bool.fromEnvironment('JAPANESE_SAVE_REVIEW_RESULT');
  final parakeet = modelId == 'parakeet-ja-0.6b-q8';
  final label = parakeet ? 'Parakeet' : 'Cohere';
  final prefix = parakeet ? 'parakeet-device' : 'cohere-device';
  final progress = ValueNotifier<String>('正在测试 $label 日语转录流水线');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (_, text, _) => Text(text, textAlign: TextAlign.center),
          ),
        ),
      ),
    ),
  );
  final documents = await getApplicationDocumentsDirectory();
  final support = await getApplicationSupportDirectory();
  final cache = await getTemporaryDirectory();
  final root = await Directory(
    p.join(
      cache.path,
      'cohere-device-${DateTime.now().microsecondsSinceEpoch}',
    ),
  ).create(recursive: true);
  final report = <String, dynamic>{
    'platform': 'Android',
    'os': Platform.operatingSystemVersion,
    'model': modelId,
    'tests': <String, dynamic>{},
  };
  final tests = report['tests'] as Map<String, dynamic>;
  Future<void> save() => File(
    p.join(support.path, '$prefix-report.json'),
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  Future<void> step(
    String name,
    Future<Map<String, dynamic>> Function() work,
  ) async {
    progress.value = name;
    final watch = Stopwatch()..start();
    try {
      tests[name] = {
        ...await work(),
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
    await save();
  }

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
  final center = _Center(
    Directory(p.join(documents.path, 'local_models')),
    storage: storage,
  )..catalog = [...await loadModelCatalog(), cohereComparisonCandidate()];
  try {
    final audio = decodeModelWave(
      await File(
        p.join(
          cache.path,
          fullAudio ? 'cohere-device/full.wav' : 'cohere-device/current.wav',
        ),
      ).readAsBytes(),
    );
    final model = center.artifact(modelId)!;
    await step('$label CPU cancellation and fresh owner', () async {
      CohereAsrDecoder decoder() => CohereAsrDecoder(
        model: p.join(center.folder(model).path, model.files.single.name),
        kind: model.engine,
        component: parakeet ? 'parakeet_ja' : 'cohere_asr',
        label: label,
        nativeTokenTiming: parakeet,
        identity: model.identity,
        threads: 4,
        onLoad: () {},
        onState: (_) {},
      );
      final first = decoder();
      try {
        final active = first.decode(
          Float32List.sublistView(audio, 0, 7 * 16000),
          () {},
          language: 'ja',
        );
        final rejected = active.then<bool>(
          (_) => false,
          onError: (Object e) => e.toString().contains('取消'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await first.release();
        if (!await rejected)
          throw StateError('Cancelled ASR result was accepted');
      } finally {
        await first.close();
      }
      final second = decoder();
      try {
        final result = await second.decode(
          Float32List.sublistView(audio, 10 * 16000, 14 * 16000),
          () {},
          language: 'ja',
        );
        if ((result['text'] as String).isEmpty)
          throw StateError('Fresh owner did not recognize speech');
        return {'recovered': true, 'text': result['text']};
      } finally {
        await second.close();
      }
    });
    for (final denoise in [false, true]) {
      await step('Japanese production pipeline denoise=$denoise', () async {
        final options = AsrEnhancementOptions(denoise: denoise);
        final spec = ModelJobSpec(
          profile: ModelServiceProfile(
            id: 'cohere-device',
            name: model.name,
            kind: TranscriptionServiceKind.local,
            model: model.id,
            language: 'ja',
          ),
          artifactIdentity: model.identity,
          asrTokenTiming: asrTokenTimingOverride(model.id, model.engine),
          asrTextProcessingVersion: currentAsrTextProcessingVersion,
          asrCpuThreads: 4,
          asrAcceleration: AsrAcceleration.cpu,
          asrExecution: AsrExecutionMode.pipeline,
          asrEnhancements: options,
          subtitleSegmentation: SubtitleSegmentationOptions.natural,
          enhancementModels: {
            for (final id in options.requiredModels(
              model.languages,
              'ja',
              textProcessingVersion: currentAsrTextProcessingVersion,
              recognitionEngine: model.engine,
            ))
              id: center.artifact(id)!.identity,
          },
        );
        var preparations = 0, batches = 0;
        final phases = <String>{};
        final runner = ModelTranscriptionRunner(center: center);
        Future<List<SubtitleItem>> run() => runner.run(
          spec: spec,
          sourceIdentity: 'cohere-device-video-$denoise',
          duration: Duration(microseconds: audio.length * 1000000 ~/ 16000),
          onProgress: (v) {
            phases.add(v.stage.name);
            progress.value = '$label 日语 · 降噪 $denoise\n${v.message}';
          },
          onStableBatch: (b) async {
            batches++;
          },
          prepareAudio: (start, count, pcm, update) async {
            final begin = (start.inMicroseconds * 16000 ~/ 1000000).clamp(
              0,
              audio.length,
            );
            final end = math.min(
              audio.length,
              begin + count.inMicroseconds * 16000 ~/ 1000000,
            );
            final file = File(p.join(root.path, 'input-${++preparations}.wav'));
            await file.writeAsBytes(
              _wave(Float32List.sublistView(audio, begin, end)),
            );
            return file.path;
          },
        );
        final watch = Stopwatch()..start();
        final cues = await run();
        final elapsed = watch.elapsedMilliseconds / 1000;
        if (cues.isEmpty || batches == 0)
          throw StateError('Missing subtitle output or stable batches');
        for (final cue in cues) {
          if (cue.endTime <= cue.startTime ||
              cue.timedSpans.any((s) => s.endTime <= s.startTime))
            throw StateError('Invalid subtitle times');
        }
        final before = preparations;
        final resumed = await run();
        if (preparations != before ||
            jsonEncode(resumed.map((c) => c.toTimingJson()).toList()) !=
                jsonEncode(cues.map((c) => c.toTimingJson()).toList()))
          throw StateError('Checkpoint resume changed');
        final srt = File(p.join(support.path, '$prefix-denoise-$denoise.srt'));
        await srt.writeAsString(
          [
            for (final cue in cues)
              '${cue.index}\n${_stamp(cue.startTime)} --> ${_stamp(cue.endTime)}\n${cue.text}\n',
          ].join('\n'),
        );
        return {
          'audioSeconds': audio.length / 16000,
          'elapsedSeconds': elapsed,
          'preparations': preparations,
          'stableBatches': batches,
          'phases': phases.toList(),
          'resumeWithoutNewInference': true,
          'cues': cues.map((c) => c.toTimingJson()).toList(),
          'states': center.states,
        };
      });
    }
    if (parakeet &&
        fullAudio &&
        provisionResult &&
        tests.values.every((v) => v['passed'] == true)) {
      await step('Prepare tested model and separate subtitle track', () async {
        final installed = ModelCenterService();
        try {
          await installed.initialize();
          final previousProfile = installed.asrProfileId;
          final previousLanguage = installed.selectedLanguage;
          await installed.importFiles(model.id, center.folder(model));
          if (installed.asrProfileId != previousProfile ||
              installed.selectedLanguage != previousLanguage) {
            throw StateError('Prepared model changed the saved selection');
          }
          final result =
              tests['Japanese production pipeline denoise=true'] as Map;
          final cues = (result['cues'] as List)
              .map((c) => SubtitleItem.fromTimingJson(c as Map))
              .toList();
          final data = await AppStorageService.instance.resolveDataRoot();
          final directory = await Directory(
            p.join(
              data.path,
              'subtitles',
              'bilibili',
              'BV1ajb3zGEi3_31607492065',
            ),
          ).create(recursive: true);
          final file = File(
            p.join(
              directory.path,
              'subtitle.asr.ja.parakeet.${DateTime.now().microsecondsSinceEpoch}.srt',
            ),
          );
          await File(
            p.join(support.path, '$prefix-denoise-true.srt'),
          ).copy(file.path);
          await SubtitleWordTimingStore.write(file.path, cues);
          return {
            'installedModel': model.identity,
            'savedSubtitle': file.path,
            'savedSelectionPreserved': true,
          };
        } finally {
          await installed.shutdown();
          installed.dispose();
        }
      });
    }
  } catch (error, stack) {
    report['error'] = '$error';
    report['stack'] = '$stack';
  } finally {
    await center.shutdown();
    center.dispose();
    report['completed'] = true;
    report['passed'] =
        report['error'] == null &&
        tests.values.every((v) => v['passed'] == true);
    await save();
    progress.value = '$label 流水线测试结束：${report['passed']}';
  }
}
