import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/asr_native_enhancer.dart';
import 'package:video_player_app/features/model_center/local_asr_worker.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/model_center/model_center_service.dart';
import 'package:video_player_app/features/model_center/model_transcription.dart';
import 'package:video_player_app/features/model_center/asr_acceleration.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/models/subtitle_model.dart';
import 'support/prepared_local_models.dart';

class _Center extends ModelCenterService with PreparedLocalModels {
  _Center({required super.storage});
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
    Directory(p.absolute('.artifacts/model-center/native', spec.profile.model)),
    {
      for (final id in spec.enhancementModels.keys)
        id: p.absolute(
          '.artifacts/model-center',
          id == AsrEnhancementOptions.alignmentQwenId ||
                  id == AsrEnhancementOptions.languageId
              ? 'native'
              : 'enhancements',
          id,
        ),
    },
  );
}

Duration _time(String text) {
  final parts = text.split(RegExp('[:,]')).map(int.parse).toList();
  return Duration(
    hours: parts[0],
    minutes: parts[1],
    seconds: parts[2],
    milliseconds: parts[3],
  );
}

String _stamp(Duration time) {
  String two(int v) => '$v'.padLeft(2, '0');
  return '${two(time.inHours)}:${two(time.inMinutes % 60)}:${two(time.inSeconds % 60)},${'${time.inMilliseconds % 1000}'.padLeft(3, '0')}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const audio = String.fromEnvironment('QWEN_CPU_AUDIO');
  const subtitles = String.fromEnvironment('QWEN_CPU_SUBTITLES');
  const output = String.fromEnvironment('QWEN_CPU_OUTPUT');
  const pipelineSeconds = int.fromEnvironment('QWEN_CPU_SECONDS');
  test(
    'Qwen CPU production pipeline on supplied video',
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
      final temp = await Directory.systemTemp.createTemp('qwen-cpu-video-');
      final storage = AppStorageService(
        locations: () async => StorageLocations(
          platform: StoragePlatform.linux,
          support: Directory(p.join(temp.path, 'support')),
          documents: Directory(p.join(temp.path, 'documents')),
          defaultData: Directory(p.join(temp.path, 'data')),
          executable: Directory(p.join(temp.path, 'exe')),
        ),
      );
      await storage.initialize();
      final center = _Center(storage: storage)
        ..catalog = await loadModelCatalog();
      final model = center.artifact('qwen3-asr-0.6b-f16')!;
      const enhancements = AsrEnhancementOptions();
      final spec = ModelJobSpec(
        profile: ModelServiceProfile(
          id: 'cpu-video',
          name: model.name,
          kind: TranscriptionServiceKind.local,
          model: model.id,
          language: 'auto',
        ),
        artifactIdentity: model.identity,
        asrTextProcessingVersion: 2,
        asrCpuThreads: 0,
        asrAcceleration: AsrAcceleration.cpu,
        asrEnhancements: enhancements,
        subtitleSegmentation: SubtitleSegmentationOptions.natural,
        enhancementModels: {
          for (final id in enhancements.requiredModels(
            model.languages,
            'auto',
            recognitionEngine: model.engine,
            textProcessingVersion: 2,
          ))
            id: center.artifact(id)!.identity,
        },
      );
      final trace = <Map<String, Object>>[];
      final workers = <LocalAsrWorker>[];
      final watch = Stopwatch()..start();
      try {
        final runner = ModelTranscriptionRunner(
          center: center,
          createLocalWorker: () {
            final w = LocalAsrWorker(
              libraryDirectory: libraries,
              qwenWorkerExecutable: p.absolute(
                'native/qwen_asr/prebuilt/windows-x64/qwen_asr_worker.exe',
              ),
            );
            workers.add(w);
            return w;
          },
        );
        final stable = <SubtitleItem>[];
        final result = await runner.run(
          spec: spec,
          sourceIdentity: 'cpu-supplied-video',
          duration: Duration(seconds: pipelineSeconds),
          onProgress: (value) {
            if (trace.isEmpty || trace.last['stage'] != value.stage.name) {
              trace.add({
                'seconds': watch.elapsedMilliseconds / 1000,
                'stage': value.stage.name,
                'message': value.message,
              });
            }
            File(p.join(output, 'cpu-pipeline-live.jsonl')).writeAsStringSync(
              '${jsonEncode(trace.last)}\n',
              mode: FileMode.append,
            );
          },
          prepareAudio: (start, count, _, _) async {
            final path = p.join(temp.path, 'audio-${start.inMilliseconds}.wav');
            final ff = await Process.run('ffmpeg', [
              '-hide_banner',
              '-loglevel',
              'error',
              '-y',
              '-ss',
              '${start.inMilliseconds / 1000}',
              '-i',
              audio,
              '-t',
              '${count.inMilliseconds / 1000}',
              '-ac',
              '1',
              '-ar',
              '16000',
              '-c:a',
              'pcm_s16le',
              path,
            ]);
            if (ff.exitCode != 0) throw StateError('${ff.stderr}');
            return path;
          },
          onStableBatch: (batch) async {
            stable.addAll(batch.cues);
          },
        );
        expect(result, isNotEmpty);
        expect(stable, isNotEmpty);
        expect(result.every((c) => c.endTime > c.startTime), isTrue);
        final before = workers.fold<int>(0, (n, w) => n + w.modelLoads);
        await File(p.join(output, 'cpu-pipeline.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'audioSeconds': pipelineSeconds,
            'elapsedSeconds': watch.elapsedMilliseconds / 1000,
            'modelLoads': before,
            'cues': result.map((c) => c.toTimingJson()).toList(),
            'trace': trace,
          }),
        );
      } finally {
        await center.shutdown();
        center.dispose();
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || audio.isEmpty || pipelineSeconds == 0,
    timeout: const Timeout(Duration(minutes: 10)),
  );
  test(
    'English CTC gives long Qwen sentences real acoustic subtitle cuts',
    () async {
      DynamicLibrary.open(p.absolute('windows/runtime/onnxruntime.dll'));
      final samples = decodeModelWave(await File(audio).readAsBytes());
      final original = <SubtitleItem>[];
      for (final block in (await File(
        subtitles,
      ).readAsString()).trim().split(RegExp(r'\r?\n\s*\r?\n'))) {
        final lines = block.split(RegExp(r'\r?\n'));
        if (lines.length < 3) continue;
        final times = lines[1].split(' --> ');
        original.add(
          SubtitleItem(
            index: original.length + 1,
            startTime: _time(times[0]),
            endTime: _time(times[1]),
            text: lines.skip(2).join(' '),
          ),
        );
      }
      final enhancer = AsrNativeEnhancer(
        options: const AsrEnhancementOptions(
          denoise: false,
          punctuation: false,
          trimSilence: false,
        ),
        directories: {
          AsrEnhancementOptions.alignmentEnglishId: p.absolute(
            '.artifacts/model-center/enhancements',
            AsrEnhancementOptions.alignmentEnglishId,
          ),
        },
        threads: 1,
        language: 'en',
        recognitionEngine: 'qwen3-asr',
        textProcessingVersion: 2,
        retainModels: true,
        checkCancelled: () {},
        progress: (_, _, _) {},
      );
      try {
        final watch = Stopwatch()..start();
        final aligned = await enhancer.enhance(original, samples);
        final captions = segmentAsrSubtitles(
          aligned,
          SubtitleSegmentationOptions.natural,
        );
        String lexical(List<SubtitleItem> items) =>
            items.map((c) => c.text).join().replaceAll(RegExp(r'\s'), '');
        expect(lexical(captions), lexical(original));
        expect(
          captions.where((c) => c.text.length > 160).length,
          lessThan(original.where((c) => c.text.length > 160).length),
        );
        expect(
          captions.every(
            (c) =>
                c.endTime > c.startTime &&
                c.timedSpans.every((s) => s.endTime > s.startTime),
          ),
          isTrue,
        );
        final folder = await Directory(output).create(recursive: true);
        await File(p.join(folder.path, 'english-refined.srt')).writeAsString(
          [
            for (var i = 0; i < captions.length; i++)
              '${i + 1}\n${_stamp(captions[i].startTime)} --> ${_stamp(captions[i].endTime)}\n${captions[i].text}\n',
          ].join('\n'),
        );
        await File(p.join(folder.path, 'english-refined.json')).writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'seconds': watch.elapsedMilliseconds / 1000,
            'originalCues': original.length,
            'captions': captions.length,
            'alignedCues': aligned.where((c) => c.timedSpans.isNotEmpty).length,
            'longOriginal': original.where((c) => c.text.length > 160).length,
            'longCaptions': captions.where((c) => c.text.length > 160).length,
            'lexicalTextUnchanged': true,
            'cues': captions.map((c) => c.toTimingJson()).toList(),
          }),
        );
      } finally {
        await enhancer.dispose();
      }
    },
    skip:
        !Platform.isWindows ||
        audio.isEmpty ||
        subtitles.isEmpty ||
        output.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
